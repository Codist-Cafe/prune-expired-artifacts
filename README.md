# prune-expired-artifacts

Reclaim GitHub Actions artifact storage by deleting artifacts that are **already past their `expires_at`**.

A CLI script plus an optional daily workflow. No secrets, no configuration, no dependencies beyond `gh` and `jq`.

---

## The problem

GitHub reclaims expired artifacts **lazily**. When an artifact's `expires_at` passes, it is not deleted on time — it lingers, often for weeks, and keeps counting against your storage quota the entire time.

That quota is also **shared, not per-repo**:

| Plan | Included artifact storage |
|---|---|
| GitHub Free | 500 MB |
| GitHub Pro | 1 GB |
| GitHub Team | 2 GB |
| GitHub Enterprise Cloud | 50 GB |

So a handful of big artifacts — Playwright reports, coverage HTML, build bundles — can fill it on their own. Once full, **every** `upload-artifact` step in **every** repo on the account starts failing:

```
##[error]Failed to CreateArtifact: Artifact storage quota has been hit.
Unable to upload any new artifacts. Usage is recalculated every 6-12 hours.
```

The frustrating part: your `retention-days` setting can be completely correct and you still hit this, because the *expired* artifacts were never actually collected.

**Real example.** One repo had 123 artifacts totalling 1387.6 MB against a 500 MB limit. 119 of them — 1348.5 MB, or **97%** — were already past their expiry date. Deleting those dropped usage to 39.0 MB in a single run.

---

## Quick start

```bash
# 1. Report what would be deleted. Deletes nothing.
DRY_RUN=1 ./scripts/prune-expired-artifacts.sh

# 2. Delete them.
./scripts/prune-expired-artifacts.sh
```

Prune a different repo without cloning it:

```bash
./scripts/prune-expired-artifacts.sh some-owner/some-repo
```

### Requirements

- [`gh`](https://cli.github.com/) — authenticated (`gh auth login`)
- `jq`
- **GNU date** (coreutils). macOS ships BSD `date`, which lacks `-d`; run `brew install coreutils` and the script will automatically use `gdate`. It detects this and fails with a clear message rather than misbehaving.

---

## Usage

```
./scripts/prune-expired-artifacts.sh [owner/repo]

  (no argument)        Prune the repo of the current working directory
  owner/repo           Prune that repo
  DRY_RUN=1            Report only — delete nothing
  INCLUDE_ACTIVE=1     Also delete artifacts still inside their retention window
  MAX_STORAGE_MB=500   Your plan's artifact storage limit (default 500 = Free)
```

Typical output:

```
Repository : Codist-Cafe/Abide-ID-2026
Mode       : DELETE
Scope      : expired only

── Inventory ────────────────────────────────────────────────
  total          4 artifacts         39.0 MB
  expired        3 artifacts         38.8 MB   <- reclaimable
  active         1 artifacts          0.2 MB   <- inside retention window

── Deleted artifacts ──────────────────────────────────────────

  ID                   SIZE  EXPIRED AT              NAME
  ------------ ------------  ----------------------  ----
  10355646589        0.7 MB  2026-09-21T15:33:01Z    playwright-report

── Summary ──────────────────────────────────────────────────
  max storage               500 MB
  usage before             39.0 MB   (7.8% of max)
  saved                    38.8 MB   (3 artifacts deleted)
  usage after               0.2 MB   (0.0% of max)

  Headroom: 499.8 MB below the 500 MB limit.

Note: artifact storage is shared across the whole account/org, not per-repo,
so other repos' artifacts count against the same limit. This script prunes
only the repo named above; pass another as $1 to prune that one too.
```

**Exit codes:** `0` on success (including "nothing to do"), `1` on error.

---

## The report

Both modes end with a summary giving **max storage**, **current usage**, the amount **saved**, and the **size remaining** — plus a per-artifact listing naming exactly what was (or would be) deleted.

### `DRY_RUN=1` — nothing is deleted

```
DRY RUN — the following artifacts WOULD be deleted:

  ID                   SIZE  EXPIRED AT              NAME
  ------------ ------------  ----------------------  ----
  4546051500        21.7 MB  2026-02-10T16:59:02Z    function-app
  4454406537        21.1 MB  2026-02-01T21:04:15Z    function-app

── Summary (dry run — nothing was deleted) ──────────────────
  max storage               500 MB
  current usage           415.8 MB   (83.2% of max)
  would be saved          129.6 MB   (6 artifacts)
  after cleanup           286.2 MB   (57.2% of max)

  Re-run without DRY_RUN=1 to delete.
```

### Real run

```
── Deleted artifacts ──────────────────────────────────────────

  ID                   SIZE  EXPIRED AT              NAME
  ------------ ------------  ----------------------  ----
  4546051500        21.7 MB  2026-02-10T16:59:02Z    function-app
  4454406537        21.1 MB  2026-02-01T21:04:15Z    function-app

── Summary ──────────────────────────────────────────────────
  max storage               500 MB
  usage before            415.8 MB   (83.2% of max)
  saved                   129.6 MB   (6 artifacts deleted)
  usage after             286.2 MB   (57.2% of max)

  Headroom: 213.8 MB below the 500 MB limit.
```

If usage is still above the limit after a run, the summary says so and points you at the other repos sharing the quota.

### About `MAX_STORAGE_MB`

The limit defaults to **500** (GitHub Free) and only affects the reported percentages and headroom — it never changes what is deleted. Set it to your plan's figure:

| Plan | `MAX_STORAGE_MB` |
|---|---|
| Free | `500` *(default)* |
| Pro | `1024` |
| Team | `2048` |
| Enterprise Cloud | `51200` |

```bash
MAX_STORAGE_MB=2048 ./scripts/prune-expired-artifacts.sh
```

Why is this an input rather than something the script detects? Because it cannot. GitHub's billing API no longer exposes the storage limit — the old `/orgs/{org}/settings/billing/*` endpoints now return **HTTP 410 Gone** — so any "detected" number would be a guess. An explicit input is honest about that.

Deleting an artifact is **permanent** — GitHub does not provide a recovery path. The defaults reflect that:

- **Only artifacts past `expires_at` are removed.** Anything still inside its retention window is left alone, so the report attached to a *currently failing* run is never destroyed. This is the core safety property.
- **Idempotent.** Running it twice is harmless; the second run finds nothing to do and exits `0`.
- **Unparseable expiry dates are skipped, not deleted.** A date the script cannot parse is treated as "unknown" and the artifact is kept, with a warning. This prevents a parsing bug from emptying your storage.
- **`INCLUDE_ACTIVE=1` is opt-in.** It also deletes artifacts that have not expired yet. Only use it when you genuinely want to purge everything.
- **No secrets.** The workflow uses the default `GITHUB_TOKEN`, which can delete artifacts in its own repository.

---

## Running it on a schedule

Copy both files into the target repo:

```
your-repo/
├── .github/workflows/prune-artifacts.yml
└── scripts/prune-expired-artifacts.sh     # chmod +x
```

Then commit. That's the whole setup — no secrets, no variables.

The workflow runs daily at **03:17 UTC** and can also be triggered by hand from **Actions → Prune expired artifacts → Run workflow**, with a `dry_run` toggle that defaults to `true`.

Why `03:17` and not `03:00`? GitHub's scheduler queues behind load on the hour, so off-hour crons fire closer to their scheduled time. It's also why the job runs on `ubuntu-latest` rather than any self-hosted runner — housekeeping shouldn't queue behind your test suites.

### Using it as a reusable workflow

If you'd rather keep one copy instead of vendoring into every repo, call it from another repository:

```yaml
jobs:
  prune:
    uses: Codist-Cafe/prune-expired-artifacts/.github/workflows/prune-artifacts.yml@main
```

Add `permissions: { actions: write, contents: read }` to the calling job. Note that the **calling** repo's artifacts are pruned in that case, because the reusable workflow receives the caller's `github.repository`.

---

## If you are still over quota after pruning

Pruning one repo may not be enough, because the limit is account-wide:

1. **Find where the storage actually is.** List artifact totals per repo:

   ```bash
   gh repo list YOUR-ORG --limit 100 --json name --jq '.[].name' | while read -r r; do
     total=$(gh api --paginate "repos/YOUR-ORG/$r/actions/artifacts?per_page=100" \
       --jq '[.artifacts[].size_in_bytes] | add // 0' 2>/dev/null || echo 0)
     printf '%12d  %s\n' "$total" "$r"
   done | sort -rn | head -20
   ```

2. **Prune the heavy ones** with the repo argument:
   ```bash
   ./scripts/prune-expired-artifacts.sh YOUR-ORG/heavy-repo
   ```

3. **Lower retention** on the biggest uploads, so future accumulation is slower:
   ```yaml
   - uses: actions/upload-artifact@v4
     with:
       name: playwright-report
       path: playwright-report
       retention-days: 7
   ```

4. **Wait.** GitHub recalculates usage every 6-12 hours, so the quota error can persist briefly after storage is genuinely freed.

---

## Frequently asked

**I already set `retention-days`. Why did this happen?**
Because retention is applied at *upload* time and expiry is not the same as deletion. GitHub collects expired artifacts lazily, so ones from before — or during a period of heavy CI — accumulate anyway. `retention-days: 7` is still the right setting; this script enforces the part GitHub defers.

**Will this delete the artifact from a run that just failed?**
No — not by default. That artifact is still inside its retention window, so it is classified `active` and skipped. Use `DRY_RUN=1` first if you want to confirm before a first real run.

**Can I get an artifact back?**
No. Deletion is permanent.

**Does it need a personal access token?**
No. The `GITHUB_TOKEN` created for each workflow run can delete artifacts in its own repo when `permissions: actions: write` is granted. The only scope needed for the CLI path is the `repo` scope your `gh auth login` already has.

**Does it work for organizations, or only personal accounts?**
Both. Storage limits and shared accounting apply to the account or organization that owns the repos.

**Why is `MAX_STORAGE_MB` not detected automatically?**
Because GitHub's billing API no longer exposes it. The former `/settings/billing/actions` and `/settings/billing/shared-storage` endpoints return HTTP 410 Gone, and the replacement requires `admin:org` scope for a figure that GitHub also surfaces inconsistently. The script prints the figure you give it rather than inventing a plausible-looking one — it only affects the reported percentages, never what gets deleted.

---

## License

MIT
