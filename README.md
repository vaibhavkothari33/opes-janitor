# opes-janitor

Reclaims disk space from developer tool caches on Windows. Dry run by default.

If you write code on Windows, your disk is slowly being eaten by caches nothing
ever prunes: yarn, npm, pnpm, pip, uv, Go modules, Cargo, Docker layers,
Puppeteer's downloaded browsers. Each one is individually reasonable. Together
they quietly take tens of gigabytes.

This matters more than "some wasted space". Below roughly 10% free, an SSD runs
out of spare blocks for wear-levelling, writes turn into read-modify-write, and
throughput collapses. Windows starts failing Volume Shadow Copy operations, so
System Restore points stop being created — silently. The machine feels broken
long before anything reports an error.

```
  opes-janitor 1.0.0  [DRY-RUN]  level=deep

  discovered  pnpm-store             D:\.pnpm-store\v3
  discovered  yarn-cache             C:\Users\...\AppData\Local\Yarn\Cache\v6

  C:    13.8 GB free of  248.1 GB     5.6% free

  TARGET                             HOLDING       FREED  STATUS
  yarn-cache                        15.21 GB    15.21 GB  would clean
  npm-cache                          3.83 GB     3.83 GB  would clean
  puppeteer-cache                    2.30 GB     2.30 GB  would clean
  go-modcache                        3.15 GB     3.15 GB  would clean
  ...
  Would reclaim: 30.42 GB
```

## Why not just delete `%temp%`

That advice is everywhere, and it is not wrong — it is just small. On the
machine this tool was written for, `%temp%` held 84 MB. The dev caches held
23 GB.

`%temp%` is covered here as the `user-temp` target, in a better form: files
newer than 7 days are kept, and files held open by a running process are
skipped instead of throwing errors at you.

Some popular neighbours of that tip are actively bad, and are deliberately
**not** included:

| Common advice | Why it is not here |
|---|---|
| Clear `C:\Windows\Prefetch` | It is a *performance* feature. Boot and app launch get slower until it rebuilds. |
| Defragment the drive | On an SSD this adds write wear for no gain. TRIM is the SSD equivalent and Windows already runs it. |
| Registry cleaners | No measurable speed benefit, non-zero chance of breaking an install. |
| "RAM cleaner" utilities | Forces Windows to drop caches it deliberately kept. Makes things slower. |

## Requirements

PowerShell 5.1 or later (ships with Windows 10 and 11). No modules, no
dependencies, no build step.

## Install

```powershell
git clone https://github.com/YOUR-USERNAME/opes-janitor.git
cd opes-janitor
```

If you downloaded a ZIP instead of cloning, Windows marks the files as
web-downloaded and refuses to run them. Clear that first:

```powershell
Get-ChildItem -Recurse *.ps1 | Unblock-File
```

If script execution is blocked entirely, either run with an explicit bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\janitor.ps1
```

or allow local scripts for your user account once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Usage

```powershell
# see what is there - deletes nothing
.\janitor.ps1

# include deep targets in the report
.\janitor.ps1 -Level deep

# list targets and show where each cache was discovered
.\janitor.ps1 -ListTargets

# actually clean the safe targets
.\janitor.ps1 -Apply

# full clean - run from an ELEVATED prompt so admin-gated targets work
.\janitor.ps1 -Apply -Level deep

# prompt before each target
.\janitor.ps1 -Apply -Confirm

# clean specific targets only
.\janitor.ps1 -Apply -Only yarn-cache,npm-cache

# everything except one
.\janitor.ps1 -Apply -Level deep -Skip go-modcache
```

### Flags

| Flag | Effect |
|---|---|
| `-Apply` | Actually delete. **Without this nothing is touched.** |
| `-Level safe\|deep` | `safe` = caches, temp, crash dumps, recycle bin. `deep` adds DISM, docker prune, Go modcache, Windows Update payloads. Default `safe`. |
| `-Force` | Run even when all drives are already above the free-space threshold. |
| `-Only a,b` | Run just these target ids. Overrides `enabled:false` and the level filter — but never the safety guard. |
| `-Skip a,b` | Exclude these target ids. |
| `-NoProbe` | Skip cache discovery, use configured paths verbatim. |
| `-ListTargets` | Print the target table and exit. |
| `-Quiet` | No console table. Log still written. Used by the scheduled task. |
| `-NoToast` | Suppress the completion notification. |
| `-Config <path>` | Use a specific config file. |
| `-WhatIf` / `-Confirm` | Standard PowerShell. `-WhatIf` is equivalent to the default dry run. |

## Cache discovery

Hardcoding `%LOCALAPPDATA%\npm-cache` is wrong often enough to matter. People
relocate caches with `.npmrc`, `CARGO_HOME`, `GOMODCACHE`, `YARN_CACHE_FOLDER`,
or by moving them off a small C: drive entirely.

So the janitor asks:

| Target | Probe |
|---|---|
| `npm-cache` | `npm config get cache` |
| `yarn-cache` | `yarn cache dir` |
| `pnpm-store` | `pnpm store path` |
| `pip-cache` | `pip cache dir` |
| `go-modcache` | `go env GOMODCACHE` |
| `cargo-registry-cache` | `$env:CARGO_HOME` + `registry/cache` |

This is not cosmetic. On the development machine, `pnpm store path` returned
`D:\.pnpm-store\v3` holding 958 MB, while the hardcoded default reported
"already empty".

A discovered path is allowlisted **for that one target only**. It is still
subject to the depth check and to `protectedPaths` — discovery can never unlock
a protected directory. Probes that fail, return nothing, or return something
implausible are ignored and the configured default is used. Turn the whole
mechanism off with `-NoProbe`.

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
drive is above `skipRunAboveFreePercent` (default 25%). It costs nothing on
quiet days and reacts within 24 hours when space actually gets tight, instead of
waiting for a weekly slot.

## Safety model

Deletion is allowlist-only. `Test-SafeToDelete` gates every destructive path
operation, and a path must clear **all four** checks:

1. exists and is a directory
2. at least two segments below the drive root — blocks `C:\`, `D:\`, `C:\Users`
3. not inside any `protectedPaths` entry
4. inside an `allowedPrefixes` entry, or inside this target's own discovered path

Check 3 runs **before** check 4, so no allowlist entry and no discovered path
can re-open a protected directory.

Anything failing is reported as `REFUSED` and logged. It is not an error and
does not stop the run.

Beyond the guard:

- **Dry run is the default.** `-Apply` is required to delete anything.
- **Junctions and symlinks are skipped, never traversed.** A reparse point
  planted inside a cache directory cannot redirect deletion into real data.
- **Only children are deleted, never the target directory itself.** Tools that
  expect their cache root to exist keep working.
- **Locked files are counted and reported, not fatal.** A running dev server
  holding a temp file does not abort the run.
- **Every deletion is logged** to `janitor.log` with byte counts.
- **`docker system prune` does not pass `--volumes`.** Named volumes — where
  database data lives — are preserved.
- **No network access, no telemetry.** The probes run local CLI tools; nothing
  is sent anywhere.

Targets prefixed `REVIEW-` ship with `enabled: false`. They exist to surface
space in the report so you can decide. `REVIEW-downloads` additionally sits in
`protectedPaths`, so the engine refuses it even if you flip the flag.

### Verifying the guard

```powershell
.\test-guard.ps1
```

18 assertions: that the guard refuses `C:\`, `D:\`, `C:\Windows`, `C:\Users`,
the profile root, Desktop, Documents, Downloads, `Program Files` and `.ssh`;
that it permits the real cache directories; and that 8.3 short paths and long
paths canonicalize to the same string.

That last one is not theoretical. On a profile whose name contains a space,
`%TEMP%` expands to `C:\Users\ALICE~1\AppData\Local\Temp` while
`%LOCALAPPDATA%` expands to the long form, and `Resolve-Path` preserves
whichever it was handed. Comparing them directly fails — which would let a
short-form path slip past a long-form `protectedPaths` entry.

## Reading dry-run numbers

Dry-run totals are an **upper bound**, not a promise:

- Age-filtered targets (`user-temp`, `windows-temp`, `cbs-logs`) report the
  whole folder, but only files past the cutoff are removed.
- `docker-prune` only removes unused layers, and the WSL `docker_data.vhdx`
  does not shrink on its own — reclaimed space may not appear on C: right away.
  To actually shrink it: `wsl --shutdown`, then `Optimize-VHD` (Hyper-V module,
  admin) or `diskpart` → `compact vdisk`.
- Locked and in-use files are skipped.

## Cost of cleaning

Nothing here loses work, but some targets trade disk for time later:

| Target | Cost of clearing |
|---|---|
| `yarn-cache`, `npm-cache`, `pnpm-store`, `pip-cache`, `uv-cache` | next install re-downloads |
| `go-modcache` | next build re-downloads all modules |
| `cargo-registry-cache` | next build re-downloads crates |
| `puppeteer-cache` | next run re-downloads a browser (~200 MB) |
| `docker-prune` | next build re-pulls base images, no layer cache |
| `windows-update-cache` | Windows re-downloads if it ever needs the payload |
| `dism-componentstore` | **irreversible** — installed Windows updates can no longer be uninstalled |

`dism-componentstore` is the only one not fixed by re-downloading. It is `deep`
level and admin-gated for that reason.

## Configuration

Edit `janitor.config.json`. To keep your changes across updates, copy it to
`%APPDATA%\opes-janitor\config.json` — that location is preferred when present.

Paths use `%VAR%` tokens and **forward slashes**. The engine normalizes them,
which keeps the JSON free of escape sequences.

Add a target:

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

- **`pathContents`** — delete the children of `path`. Optional `olderThanDays`.
  Subject to the safety guard.
- **`command`** — run `command` via `cmd`. Optional `requires` names an
  executable that must be on PATH or the target is skipped. The tool does its
  own deletion, so the guard does not apply — only add commands you trust.
- **`builtin`** — `recyclebin` or `dism`.

Any target may set `requiresAdmin: true`; it is skipped, not failed, when the
session is not elevated.

If a new `pathContents` target lives outside the existing `allowedPrefixes`,
add its prefix there too, or the engine will refuse it. That refusal is the
system working correctly.

## What this does not cover

Windows Storage Sense (Settings → System → Storage) handles the OS side —
Downloads age-out, old update files, Recycle Bin. Turn it on alongside this.
The two are complementary: Storage Sense does OS junk, opes-janitor does dev
junk.

To see *where* space went visually, use [WizTree](https://diskanalyzer.com/) —
it reads the NTFS MFT directly and scans a full drive in seconds.

## License

MIT. See [LICENSE](LICENSE).
