# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-21

First public release.

### Added

- Allowlist-gated cleanup engine with dry run as the default. `-Apply` is
  required before anything is deleted.
- 21 cleanup targets across two levels: `safe` (package manager caches, temp
  folders, crash dumps, recycle bin) and `deep` (DISM component store, docker
  prune, Go module cache, Windows Update payloads).
- **Cache discovery.** Probes ask each tool where its cache actually lives
  (`npm config get cache`, `yarn cache dir`, `pnpm store path`, `pip cache dir`,
  `go env GOMODCACHE`, `$CARGO_HOME`) instead of assuming defaults. A discovered
  path is allowlisted for that one target only and can never unlock a
  `protectedPaths` entry. Disable with `-NoProbe`.
- `drives: "auto"` enumerates every fixed disk rather than hardcoding letters.
- `-WhatIf` and `-Confirm` via `SupportsShouldProcess`.
- Config search order: `-Config` argument, then
  `%APPDATA%\opes-janitor\config.json`, then the shipped `janitor.config.json`.
  The `%APPDATA%` copy survives updates.
- `install-task.ps1` registers a daily Scheduled Task. The script exits in under
  a second when free space is already above threshold, so a daily trigger is
  nearly free.
- `test-guard.ps1`: 18 assertions covering the safety guard and path
  canonicalization.
- Append-only `janitor.log`, auto-trimmed to `logRetentionDays`.

### Safety

- Deletion is allowlist-only, gated by four checks: exists and is a directory,
  at least two segments below the drive root, not inside `protectedPaths`,
  and inside an `allowedPrefixes` entry. Protected is evaluated before allowed,
  so an allowlist entry can never re-open a protected path.
- Reparse points (junctions and symlinks) are skipped, never traversed. A
  junction planted inside a cache directory cannot redirect deletion elsewhere.
- Only the children of a target directory are removed, never the directory
  itself, so tools that expect their cache root to exist keep working.
- Locked and in-use files are counted and reported rather than aborting the run.
- `docker system prune` deliberately omits `--volumes`; named volumes, where
  database data lives, are preserved.

### Notes

- Requires PowerShell 5.1 or later. Developed and tested on Windows 11 with
  PowerShell 5.1. Not yet verified on PowerShell 7.
- Path handling canonicalizes 8.3 short names. On profiles whose name contains
  a space, `%TEMP%` expands to the short form (`C:\Users\ALICE~1\...`) while
  `%LOCALAPPDATA%` expands long, and `Resolve-Path` preserves whichever form it
  was given. Comparing the two forms directly would let a short-form path slip
  past a long-form `protectedPaths` entry.
