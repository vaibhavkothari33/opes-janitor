# opes-janitor

Reclaims disk space from developer tool caches on Windows. Dry run by default.

Built after C: hit 5.5% free and Windows started failing Volume Shadow Copy
operations. The recurring cause is dev tooling: yarn, npm, pip, uv, go, cargo,
docker and puppeteer caches grow without bound and nothing prunes them.

## Files

| File | Purpose |
|---|---|
| `janitor.ps1` | The engine. Scans, reports, and (with `-Apply`) cleans. |
| `janitor.config.json` | What to clean. Edit this, not the script. |
| `install-task.ps1` | Registers/removes the daily Scheduled Task. |
| `janitor.log` | Append-only record of every run. Auto-trimmed to 90 days. |

## Usage

```powershell
# see what's there - deletes nothing
.\janitor.ps1

# include deep targets in the report
.\janitor.ps1 -Level deep

# list configured targets
.\janitor.ps1 -ListTargets

# actually clean the safe targets
.\janitor.ps1 -Apply

# full clean - run from an ELEVATED prompt so DISM works
.\janitor.ps1 -Apply -Level deep

# clean specific targets only
.\janitor.ps1 -Apply -Only yarn-cache,npm-cache

# everything except one
.\janitor.ps1 -Apply -Level deep -Skip go-modcache
```

### Flags

| Flag | Effect |
|---|---|
| `-Apply` | Actually delete. **Without this nothing is touched.** |
| `-Level safe\|deep` | `safe` = caches, temp, recycle bin. `deep` adds DISM, docker prune, go modcache. Default `safe`. |
| `-Force` | Run even when all drives are already above the free-space threshold. |
| `-Only a,b` | Run just these target ids. Overrides both `enabled:false` and the level filter. |
| `-Skip a,b` | Exclude these target ids. |
| `-ListTargets` | Print the target table and exit. |
| `-Quiet` | No console table. Log still written. Used by the scheduled task. |
| `-NoToast` | Suppress the completion notification. |
| `-Config <path>` | Use a different config file. |

## Scheduling

```powershell
# daily safe clean at 13:00
.\install-task.ps1

# daily deep clean at 02:30 - run this elevated
.\install-task.ps1 -Level deep -At 02:30

.\install-task.ps1 -Uninstall
```

A **daily** trigger is deliberate even though cleanup is rarely needed. The
script reads drive free space first and exits in well under a second when every
drive is above `skipRunAboveFreePercent` (default 25%). So it costs nothing on
quiet days and reacts within 24h when space actually gets tight, rather than
waiting for a weekly slot.

## Safety model

Deletion is allowlist-only. `Test-SafeToDelete` gates every destructive path
operation, and a path must clear **all four** checks:

1. exists and is a directory
2. at least two segments below the drive root (blocks `C:\`, `D:\`, `C:\Users`)
3. not inside any `protectedPaths` entry
4. inside at least one `allowedPrefixes` entry

Anything failing this is reported as `REFUSED` and logged. It is not an error
and does not stop the run.

Additional guarantees:

- **Dry run is the default.** `-Apply` is required to delete anything.
- **Junctions and symlinks are skipped, never traversed.** Prevents a reparse
  point inside a cache dir from redirecting deletion somewhere real.
- **Only children are deleted, never the target directory itself.** Tools that
  expect their cache dir to exist keep working.
- **Locked files are counted and reported, not fatal.** A running dev server
  holding a temp file does not abort the run.
- **Every deletion is logged** to `janitor.log` with byte counts.
- **`docker system prune` does not pass `--volumes`.** Named volumes — where
  database data lives — are preserved.

The three `REVIEW-` targets ship with `enabled: false`. Two of them
(`REVIEW-orphan-ollama-blobs`, `REVIEW-downloads`) point outside
`allowedPrefixes` on purpose, so the engine refuses them even if you flip the
flag. They exist to surface the space in the report so you can act by hand.

## Reading dry-run numbers

Dry-run totals are an **upper bound**, not a promise:

- Age-filtered targets (`user-temp`, `windows-temp`) report the whole folder,
  but only files past the cutoff get removed.
- `docker-prune` only removes unused layers, and the WSL `docker_data.vhdx`
  does not shrink on its own — reclaimed space may not appear on C: right away.
  To actually shrink it: `wsl --shutdown`, then `Optimize-VHD` (Hyper-V
  module, admin) or `diskpart compact vdisk`.
- Locked / in-use files are skipped.

## Cost of cleaning

Nothing here loses work, but some targets trade disk for time later:

| Target | Cost of clearing |
|---|---|
| `yarn-cache`, `npm-cache`, `pnpm-store` | next `install` re-downloads |
| `go-modcache` | next build re-downloads all modules |
| `cargo-registry-cache` | next build re-downloads crates |
| `puppeteer-cache` | next puppeteer run re-downloads Chromium (~200MB) |
| `docker-prune` | next build re-pulls base images, no layer cache |
| `dism-componentstore` | **irreversible** — installed Windows updates can no longer be uninstalled |

`dism-componentstore` is the only one that is not reversible by simply
re-downloading. It is `deep` level and admin-gated for that reason.

## Adding a target

Append to `targets` in `janitor.config.json`. Use **forward slashes** — the
engine normalizes them, and it keeps the JSON free of escape sequences.

```json
{
  "id": "gradle-cache",
  "label": "Gradle build cache",
  "level": "deep",
  "enabled": true,
  "kind": "pathContents",
  "path": "%USERPROFILE%/.gradle/caches",
  "measure": "%USERPROFILE%/.gradle/caches",
  "olderThanDays": 30
}
```

`kind` is one of:

- `pathContents` — delete children of `path`. Optional `olderThanDays`.
  Subject to the allowlist.
- `command` — run `command` via cmd. Optional `requires` names an executable
  that must be on PATH or the target is skipped.
- `builtin` — `recyclebin` or `dism`. Add `requiresAdmin: true` if needed.

If a new `pathContents` target lives outside the existing `allowedPrefixes`,
add its prefix there too or the engine will refuse it.

## What this does not cover

Storage Sense (Settings > System > Storage) handles Windows' own junk —
Downloads, old update files, Recycle Bin age-out. Turn it on alongside this.
The two are complementary: Storage Sense does OS junk, janitor does dev junk.

For seeing *where* space went visually, use WizTree — it reads the NTFS MFT
directly and scans a full drive in seconds.
