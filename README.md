<div align="center">

# opes-janitor

**Reclaim tens of gigabytes from developer tool caches on Windows.**
Dry run by default. Allowlist-only deletion. Zero dependencies.

[![CI](https://github.com/vaibhavkothari33/opes-janitor/actions/workflows/ci.yml/badge.svg)](https://github.com/vaibhavkothari33/opes-janitor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](CHANGELOG.md)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)
[![Dry run by default](https://img.shields.io/badge/dry%20run-by%20default-success.svg)](#safety-model)
[![Stars](https://img.shields.io/github/stars/vaibhavkothari33/opes-janitor?style=flat&color=yellow)](https://github.com/vaibhavkothari33/opes-janitor/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/vaibhavkothari33/opes-janitor)](https://github.com/vaibhavkothari33/opes-janitor/commits/main)

</div>

---

## The problem

If you write code on Windows, your disk is quietly being eaten by caches that
nothing ever prunes — yarn, npm, pnpm, pip, uv, Go modules, Cargo, Docker
layers, Puppeteer's downloaded browsers. Each is individually reasonable.
Together they take tens of gigabytes and never give them back.

This is worse than "some wasted space." Below roughly 10% free, an SSD runs out
of spare blocks for wear-levelling, writes degrade into read-modify-write, and
throughput collapses. Windows also starts failing Volume Shadow Copy operations,
so **System Restore points silently stop being created**. The machine feels
broken long before anything reports an error.

The tool that prompted this was written on a laptop sitting at **5.5% free**,
already throwing `Volsnap` errors. First run returned **23 GB**.

## What it looks like

```
  opes-janitor 1.0.0  [DRY-RUN]  level=deep

  discovered  pnpm-store             D:\.pnpm-store\v3
  discovered  yarn-cache             C:\Users\...\AppData\Local\Yarn\Cache\v6
  discovered  go-modcache            C:\Users\...\go\pkg\mod

  C:    13.8 GB free of  248.1 GB     5.6% free
  D:    22.5 GB free of  226.6 GB     9.9% free

  TARGET                             HOLDING       FREED  STATUS
  ------------------------------ ----------- -----------  -----------------------------
  yarn-cache                        15.21 GB    15.21 GB  would clean
  npm-cache                          3.83 GB     3.83 GB  would clean
  go-modcache                        3.15 GB     3.15 GB  would clean
  puppeteer-cache                    2.30 GB     2.30 GB  would clean
  windows-temp                       1.98 GB     1.98 GB  would clean
  docker-prune                       1.64 GB     1.64 GB  would clean
  recycle-bin                        1.02 GB     1.02 GB  would clean
  crash-dumps                       173.9 MB    173.9 MB  would clean
  dism-componentstore                   0 B               skip: needs admin
  REVIEW-huggingface                 1.48 GB              REVIEW - not enabled

  Would reclaim: 30.42 GB
  Re-run with -Apply to actually clean.
```

## Quick start

```powershell
git clone https://github.com/vaibhavkothari33/opes-janitor.git
cd opes-janitor

.\janitor.ps1                  # report only - deletes nothing
.\janitor.ps1 -Apply           # clean the safe targets
```

If you downloaded a ZIP instead of cloning, Windows marks the files
web-downloaded and refuses to run them:

```powershell
Get-ChildItem -Recurse *.ps1 | Unblock-File
```

If script execution is blocked entirely, either bypass for one run:

```powershell
powershell -ExecutionPolicy Bypass -File .\janitor.ps1
```

or allow local scripts for your account once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Requirements

PowerShell 5.1 or later — ships with Windows 10 and 11. Tested in CI on both
Windows PowerShell 5.1 and PowerShell 7.

No modules. No dependencies. No build step. No network access. No telemetry.

## Usage

```powershell
.\janitor.ps1                                  # dry run, safe level
.\janitor.ps1 -Level deep                      # dry run, everything
.\janitor.ps1 -ListTargets                     # what's configured, and where each cache was found
.\janitor.ps1 -Apply                           # clean safe targets
.\janitor.ps1 -Apply -Level deep               # full clean (run elevated)
.\janitor.ps1 -Apply -Confirm                  # prompt before each target
.\janitor.ps1 -Apply -Only yarn-cache,npm-cache
.\janitor.ps1 -Apply -Level deep -Skip go-modcache
```

| Flag | Effect |
|---|---|
| `-Apply` | Actually delete. **Without this, nothing is touched.** |
| `-Level safe\|deep` | `safe` = caches, temp, crash dumps, recycle bin. `deep` adds DISM, docker prune, Go modcache, Windows Update payloads. Default `safe`. |
| `-Force` | Run even when every drive is already above the free-space threshold. |
| `-Only a,b` | Run only these target ids. Overrides `enabled:false` and the level filter — never the safety guard. |
| `-Skip a,b` | Exclude these target ids. |
| `-NoProbe` | Skip cache discovery; use configured paths verbatim. |
| `-ListTargets` | Print the target table and exit. |
| `-Quiet` | No console table. Log still written. Used by the scheduled task. |
| `-NoToast` | Suppress the completion notification. |
| `-Config <path>` | Use a specific config file. |
| `-WhatIf` / `-Confirm` | Standard PowerShell. `-WhatIf` is equivalent to the default dry run. |

## Cache discovery

Hardcoding `%LOCALAPPDATA%\npm-cache` is wrong often enough to matter. People
relocate caches via `.npmrc`, `CARGO_HOME`, `GOMODCACHE`, `YARN_CACHE_FOLDER`,
or by moving them off a small C: drive entirely.

So opes-janitor asks each tool where its cache actually is:

| Target | Probe |
|---|---|
| `npm-cache` | `npm config get cache` |
| `yarn-cache` | `yarn cache dir` |
| `pnpm-store` | `pnpm store path` |
| `pip-cache` | `pip cache dir` |
| `go-modcache` | `go env GOMODCACHE` |
| `cargo-registry-cache` | `$env:CARGO_HOME` + `registry/cache` |

This is not cosmetic. On the development machine, `pnpm store path` returned
`D:\.pnpm-store\v3` holding **958 MB**, while the hardcoded default reported
`already empty`.

A discovered path is allowlisted **for that one target only**, and is still
subject to the depth check and to `protectedPaths` — discovery can never unlock
a protected directory. Probes that fail, return nothing, or return something
implausible are ignored in favour of the configured default. Disable the whole
mechanism with `-NoProbe`.

## Scheduling

```powershell
.\install-task.ps1                        # daily safe clean at 13:00
.\install-task.ps1 -Level deep -At 02:30  # daily deep clean (run elevated)
.\install-task.ps1 -Uninstall
```

A **daily** trigger is deliberate even though cleanup is rarely needed. The
script reads drive free space first and exits in well under a second when every
drive is above `skipRunAboveFreePercent` (default 25%). It costs nothing on
quiet days and reacts within 24 hours when space gets tight, instead of waiting
for a weekly slot.

## Safety model

Deletion is **allowlist-only**. `Test-SafeToDelete` gates every destructive path
operation, and a path must clear **all four** checks:

1. exists and is a directory
2. at least two segments below the drive root — blocks `C:\`, `D:\`, `C:\Users`
3. not inside any `protectedPaths` entry
4. inside an `allowedPrefixes` entry, or inside this target's own discovered path

Check 3 runs **before** check 4, so no allowlist entry and no discovered path
can re-open a protected directory. Anything that fails is reported as `REFUSED`
and logged; it is not an error and does not stop the run.

Beyond the guard:

- 🔒 **Dry run is the default.** `-Apply` is required before anything is deleted.
- 🔗 **Junctions and symlinks are skipped, never traversed.** A reparse point
  planted inside a cache directory cannot redirect deletion into real data.
- 📁 **Only children are deleted, never the target directory itself,** so tools
  that expect their cache root to exist keep working.
- 🔓 **Locked files are counted and reported, not fatal.** A running dev server
  holding a temp file does not abort the run.
- 📝 **Every deletion is logged** to `janitor.log` with byte counts.
- 🐳 **`docker system prune` omits `--volumes`.** Named volumes — where database
  data lives — are preserved.
- 🌐 **No network access, no telemetry.** Probes run local CLI tools; nothing
  leaves the machine.

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
`%TEMP%` expands to `C:\Users\ALICE~1\AppData\Local\Temp` while `%LOCALAPPDATA%`
expands to the long form, and `Resolve-Path` preserves whichever form it was
handed. Comparing the two directly fails — which would let a short-form path
slip past a long-form `protectedPaths` entry.

CI runs these tests on every push, under both PowerShell 5.1 and PowerShell 7.

## Reading dry-run numbers

Dry-run totals are an **upper bound**, not a promise:

- Age-filtered targets (`user-temp`, `windows-temp`, `cbs-logs`) report the whole
  folder, but only files past the cutoff are removed.
- `docker-prune` only removes unused layers, and the WSL `docker_data.vhdx` does
  not shrink on its own — reclaimed space may not appear on C: right away. To
  actually shrink it: `wsl --shutdown`, then `Optimize-VHD` (Hyper-V module,
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
| `windows-update-cache` | Windows re-downloads if it ever needs the payload again |
| `dism-componentstore` | ⚠️ **irreversible** — installed Windows updates can no longer be uninstalled |

`dism-componentstore` is the only one not fixed by re-downloading. It is `deep`
level and admin-gated for exactly that reason.

## Why not just delete `%temp%`

That advice is everywhere, and it is not wrong — it is just **small**. On the
machine this was written for, `%temp%` held 84 MB. The dev caches held 23 GB.

`%temp%` is covered here as the `user-temp` target, in a better form: files
newer than 7 days are kept, and files held open by a running process are skipped
instead of throwing errors at you.

Some popular neighbours of that tip are actively harmful, and are deliberately
**not** included:

| Common advice | Why it is not here |
|---|---|
| Clear `C:\Windows\Prefetch` | It is a *performance* feature. Boot and app launch get **slower** until it rebuilds. |
| Defragment the drive | On an SSD this adds write wear for no gain. TRIM is the SSD equivalent, and Windows already runs it. |
| Registry cleaners | No measurable speed benefit, non-zero chance of breaking an install. |
| "RAM cleaner" utilities | Forces Windows to drop caches it deliberately kept. Makes things slower. |

## Configuration

Edit `janitor.config.json`. To keep changes across updates, copy it to
`%APPDATA%\opes-janitor\config.json` — that location wins when present.

Paths use `%VAR%` tokens and **forward slashes**. The engine normalizes them,
which keeps the JSON free of escape sequences.

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
  executable that must be on PATH, or the target is skipped. The tool performs
  its own deletion, so the guard does not apply — only add commands you trust.
- **`builtin`** — `recyclebin` or `dism`.

Any target may set `requiresAdmin: true`; it is skipped, not failed, when the
session is not elevated.

If a new `pathContents` target lives outside the existing `allowedPrefixes`, add
its prefix there too, or the engine will refuse it. That refusal is the system
working correctly.

## What this does not cover

Windows **Storage Sense** (Settings → System → Storage) handles the OS side —
Downloads age-out, old update files, Recycle Bin. Turn it on alongside this. The
two are complementary: Storage Sense does OS junk, opes-janitor does dev junk.

To see *where* space went visually, use [WizTree](https://diskanalyzer.com/) —
it reads the NTFS MFT directly and scans a full drive in seconds.

## Contributing

Issues and pull requests welcome. Before opening a PR:

```powershell
.\test-guard.ps1        # must be 0 failures
.\janitor.ps1 -Level deep   # dry run must not error
```

New cleanup targets should ship `enabled: true` only if clearing them is
recoverable by re-downloading. Anything irreversible belongs at `deep` level
with `requiresAdmin`, or as a `REVIEW-` target that is off by default.

## License

[MIT](LICENSE) © Vaibhav Kothari
