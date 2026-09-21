#!/usr/bin/env bash
#
# Delete GitHub Actions artifacts that are already PAST their `expires_at`.
#
# ── Why this exists ───────────────────────────────────────────────────────────
# GitHub reclaims expired artifacts LAZILY. An artifact whose `expires_at` has
# passed is not deleted on time — it lingers for weeks and keeps counting against
# the storage quota the whole time.
#
# That quota is often small and always SHARED, not per-repo:
#   - GitHub Free   : 500 MB, shared across every repo in the account/org
#   - GitHub Pro    : 1 GB
#   - Team          : 2 GB
#   - Enterprise    : 50 GB
#
# So a handful of large artifacts (Playwright reports, coverage HTML, build
# bundles) can fill it on their own, and then every `upload-artifact` step starts
# failing with:
#
#     ##[error]Failed to CreateArtifact: Artifact storage quota has been hit.
#
# Deleting the already-expired artifacts breaks that deadlock immediately. On one
# real repo, 123 artifacts / 1387.6 MB were sitting against a 500 MB limit, 97%
# of them already past expiry; this script reclaimed 1348.5 MB in one run.
#
# ── Safety ────────────────────────────────────────────────────────────────────
# By default only artifacts whose `expires_at` is in the PAST are removed. Any
# artifact still inside its retention window is left alone, so the report from a
# currently-failing run is never destroyed. Deletion is permanent — an artifact
# cannot be recovered once removed — so the narrow default matters.
#
# It is idempotent: a second run finds nothing to do and exits 0.
#
# Requires: gh (authenticated), jq, and GNU date (coreutils). On macOS,
# `brew install coreutils` and use `gdate` — see README.
#
# Usage:
#   ./prune-expired-artifacts.sh                    # current repo
#   ./prune-expired-artifacts.sh owner/repo         # a specific repo
#   DRY_RUN=1 ./prune-expired-artifacts.sh          # report only, delete nothing
#   INCLUDE_ACTIVE=1 ./prune-expired-artifacts.sh   # also delete live artifacts
#
# Both modes end with a summary report: max storage, current usage, the amount
# saved, and the size remaining. Set MAX_STORAGE_MB to match your plan (default
# 500, i.e. GitHub Free) so the headroom figures are accurate.
#
# Exit codes: 0 = success (including "nothing to do"), 1 = an error occurred.

set -euo pipefail

REPO="${1:-${GH_REPO:-}}"
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

DRY_RUN="${DRY_RUN:-0}"
INCLUDE_ACTIVE="${INCLUDE_ACTIVE:-0}"
# Storage limit used only to report headroom. GitHub's billing API no longer
# exposes this (the old /settings/billing/* endpoints return HTTP 410), and the
# limit varies by plan — Free 500 MB, Pro 1 GB, Team 2 GB, Enterprise 50 GB — so
# it is an input rather than a guess. Override with MAX_STORAGE_MB.
MAX_STORAGE_MB="${MAX_STORAGE_MB:-500}"
API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI is required." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required." >&2; exit 1; }

# `date -d` is GNU-only. Detect it once and fail with a useful message rather
# than silently classifying every artifact as "expired" and deleting everything.
if date -u -d "@0" +%s >/dev/null 2>&1; then
  date_to_epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
elif command -v gdate >/dev/null 2>&1; then
  date_to_epoch() { gdate -u -d "$1" +%s 2>/dev/null || echo 0; }
else
  echo "error: GNU date is required (try 'brew install coreutils' and use gdate)." >&2
  exit 1
fi

echo "Repository : $REPO"
echo "Mode       : $([ "$DRY_RUN" = "1" ] && echo 'DRY RUN (nothing will be deleted)' || echo 'DELETE')"
echo "Scope      : $([ "$INCLUDE_ACTIVE" = "1" ] && echo 'expired AND active' || echo 'expired only')"
echo

# ── Fetch every artifact (paginated) ──────────────────────────────────────────
artifacts_tsv="$(
  gh api --paginate --header "$API_VERSION_HEADER" \
    "repos/$REPO/actions/artifacts?per_page=100" \
    --jq '.artifacts[] | [.id, .name, .size_in_bytes, .created_at, .expires_at] | @tsv'
)"

if [ -z "$artifacts_tsv" ]; then
  echo "No artifacts found in $REPO. Nothing to do."
  exit 0
fi

now_epoch="$(date -u +%s)"

total_count=0; total_bytes=0
expired_count=0; expired_bytes=0
active_count=0; active_bytes=0
targets=""

# IFS=TAB so artifact names containing spaces survive the read.
while IFS=$'\t' read -r id name size created expires; do
  [ -n "${id:-}" ] || continue

  total_count=$((total_count + 1))
  total_bytes=$((total_bytes + size))

  exp_epoch="$(date_to_epoch "$expires")"

  # Guard: an unparseable date must never look "expired". Epoch 0 < now would
  # mark it expired, so treat 0 as "unknown" and keep it, unless it really is 0.
  if [ "$exp_epoch" -eq 0 ] && [ "$expires" != "1970-01-01T00:00:00Z" ]; then
    echo "warning: could not parse expiry '$expires' for artifact $id — leaving it alone." >&2
    active_count=$((active_count + 1)); active_bytes=$((active_bytes + size))
    continue
  fi

  if [ "$exp_epoch" -lt "$now_epoch" ]; then
    expired_count=$((expired_count + 1)); expired_bytes=$((expired_bytes + size))
    targets="${targets}${id}"$'\t'"${name}"$'\t'"${size}"$'\t'"${expires}"$'\n'
  else
    active_count=$((active_count + 1)); active_bytes=$((active_bytes + size))
    if [ "$INCLUDE_ACTIVE" = "1" ]; then
      targets="${targets}${id}"$'\t'"${name}"$'\t'"${size}"$'\t'"${expires}"$'\n'
    fi
  fi
done <<< "$artifacts_tsv"

# Bytes -> MB, one decimal. awk avoids depending on bc.
mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

# Render a "used / max (pct%)" cell for the report table.
pct() { awk -v u="$1" -v m="$2" 'BEGIN { if (m > 0) printf "%.1f%%", (u / m) * 100; else print "n/a" }'; }
max_bytes() { awk -v m="$1" 'BEGIN { printf "%.0f", m * 1048576 }'; }

echo "── Inventory ────────────────────────────────────────────────"
printf '  total      %5d artifacts   %10s MB\n' "$total_count" "$(mb "$total_bytes")"
printf '  expired    %5d artifacts   %10s MB   <- reclaimable\n' "$expired_count" "$(mb "$expired_bytes")"
printf '  active     %5d artifacts   %10s MB   <- inside retention window\n' "$active_count" "$(mb "$active_bytes")"
echo

if [ -z "$targets" ]; then
  echo "Nothing to delete — no artifacts past their expiry."
  exit 0
fi

# ── Report-only mode ──────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN — the following artifacts WOULD be deleted:"
  echo
  printf '  %-12s %12s  %-22s  %s\n' "ID" "SIZE" "EXPIRED AT" "NAME"
  printf '  %-12s %12s  %-22s  %s\n' "------------" "------------" "----------------------" "----"
  while IFS=$'\t' read -r id name size expires; do
    [ -n "${id:-}" ] || continue
    printf '  %-12s %9s MB  %-22s  %s\n' "$id" "$(mb "$size")" "$expires" "$name"
  done <<< "$targets"
  echo

  projected=$(printf '%s' "$targets" | awk -F'\t' 'NF {s+=$3} END {print s+0}')
  final_bytes=$((total_bytes - projected))

  echo "── Summary (dry run — nothing was deleted) ──────────────────"
  printf '  max storage      %12s MB\n' "$MAX_STORAGE_MB"
  printf '  current usage    %12s MB   (%s of max)\n' "$(mb "$total_bytes")" "$(pct "$total_bytes" "$(max_bytes "$MAX_STORAGE_MB")")"
  printf '  would be saved   %12s MB   (%d artifacts)\n' "$(mb "$projected")" "$(printf '%s' "$targets" | awk -F'\t' 'NF {n++} END {print n+0}')"
  printf '  after cleanup    %12s MB   (%s of max)\n' "$(mb "$final_bytes")" "$(pct "$final_bytes" "$(max_bytes "$MAX_STORAGE_MB")")"
  echo
  echo "  Re-run without DRY_RUN=1 to delete."
  exit 0
fi

# ── Delete ────────────────────────────────────────────────────────────────────
deleted=0; failed=0; reclaimed=0; failures=""
deleted_list=""

while IFS=$'\t' read -r id name size expires; do
  [ -n "${id:-}" ] || continue
  if gh api -X DELETE --header "$API_VERSION_HEADER" \
       "repos/$REPO/actions/artifacts/$id" >/dev/null 2>&1; then
    deleted=$((deleted + 1)); reclaimed=$((reclaimed + size))
    deleted_list="${deleted_list}${id}"$'\t'"${name}"$'\t'"${size}"$'\t'"${expires}"$'\n'
  else
    failed=$((failed + 1))
    failures="${failures}  ${id}  ${name}  (expired ${expires})"$'\n'
  fi
done <<< "$targets"

echo "── Deleted $( [ "$deleted" -eq 1 ] && echo 'artifact' || echo 'artifacts' ) ──────────────────────────────────────────"
if [ "$deleted" -gt 0 ]; then
  echo
  printf '  %-12s %12s  %-22s  %s\n' "ID" "SIZE" "EXPIRED AT" "NAME"
  printf '  %-12s %12s  %-22s  %s\n' "------------" "------------" "----------------------" "----"
  while IFS=$'\t' read -r id name size expires; do
    [ -n "${id:-}" ] || continue
    printf '  %-12s %9s MB  %-22s  %s\n' "$id" "$(mb "$size")" "$expires" "$name"
  done <<< "$deleted_list"
  echo
fi

if [ "$failed" -gt 0 ]; then
  printf '  FAILED     %5d artifacts (not deleted)\n' "$failed"
  echo "$failures"
  echo "::error::Failed to delete $failed artifact(s) — see the list above." >&2
  exit 1
fi

# ── Report what remains ───────────────────────────────────────────────────────
remaining_tsv="$(
  gh api --paginate --header "$API_VERSION_HEADER" \
    "repos/$REPO/actions/artifacts?per_page=100" \
    --jq '.artifacts[] | [.id, .size_in_bytes] | @tsv'
)"
remaining_count=0; remaining_bytes=0
while IFS=$'\t' read -r id size; do
  [ -n "${id:-}" ] || continue
  remaining_count=$((remaining_count + 1)); remaining_bytes=$((remaining_bytes + size))
done <<< "${remaining_tsv:-}"

echo
echo "── Summary ──────────────────────────────────────────────────"
printf '  max storage      %12s MB\n' "$MAX_STORAGE_MB"
printf '  usage before     %12s MB   (%s of max)\n' "$(mb "$total_bytes")" "$(pct "$total_bytes" "$(max_bytes "$MAX_STORAGE_MB")")"
printf '  saved            %12s MB   (%d artifacts deleted)\n' "$(mb "$reclaimed")" "$deleted"
printf '  usage after      %12s MB   (%s of max)\n' "$(mb "$remaining_bytes")" "$(pct "$remaining_bytes" "$(max_bytes "$MAX_STORAGE_MB")")"
echo
if [ "$remaining_bytes" -lt "$(max_bytes "$MAX_STORAGE_MB")" ]; then
  printf '  Headroom: %s MB below the %s MB limit.\n' \
    "$(mb $(( $(max_bytes "$MAX_STORAGE_MB") - remaining_bytes )))" "$MAX_STORAGE_MB"
else
  printf '  STILL OVER the %s MB limit by %s MB.\n' \
    "$MAX_STORAGE_MB" "$(mb $(( remaining_bytes - $(max_bytes "$MAX_STORAGE_MB") )))"
  echo "  Storage is shared across the account, so check other repos too."
fi
echo
echo "Note: artifact storage is shared across the whole account/org, not per-repo,"
echo "so other repos' artifacts count against the same limit. This script prunes"
echo "only the repo named above; pass another as \$1 to prune that one too."
