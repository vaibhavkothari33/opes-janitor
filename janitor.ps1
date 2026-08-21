#Requires -Version 5.1
<#
.SYNOPSIS
    opes-janitor - reclaims disk space from developer tool caches on Windows.

.DESCRIPTION
    Scans an allowlist of known-safe cache locations, reports how much each one
    holds, and (only when -Apply is passed) clears them.

    DRY RUN IS THE DEFAULT. Nothing is deleted unless you pass -Apply.

    Cache locations are discovered by asking each tool where its cache actually
    lives (npm config get cache, yarn cache dir, go env GOMODCACHE, ...) rather
    than assuming defaults, so relocated caches are still found. Use -NoProbe to
    skip discovery and use the configured defaults only.

    Every deletion is appended to janitor.log next to this script.

.PARAMETER Apply
    Actually perform the cleanup. Without this, the script only reports.

.PARAMETER Level
    safe  - package manager caches, temp files, crash dumps, recycle bin (default)
    deep  - everything in safe, plus DISM component store, docker prune,
            go modcache, Windows update payloads. Forces re-downloads later.

.PARAMETER Force
    Run even when free space is already above the configured threshold.

.PARAMETER Only
    Target ids to run exclusively. Overrides both enabled:false and the level
    filter, but never the safety guard.

.PARAMETER Skip
    Target ids to exclude.

.PARAMETER NoProbe
    Skip cache-location discovery. Uses the paths in the config verbatim.

.PARAMETER ListTargets
    Print the configured targets and exit.

.PARAMETER Quiet
    Suppress the console table. Log file is still written.

.PARAMETER NoToast
    Do not show the completion notification.

.PARAMETER Config
    Path to a config file. Default search order:
      1. -Config argument
      2. %APPDATA%\opes-janitor\config.json   (survives updates)
      3. janitor.config.json next to this script

.EXAMPLE
    .\janitor.ps1
    Dry run at safe level. Shows what would be freed.

.EXAMPLE
    .\janitor.ps1 -Apply
    Clean safe targets.

.EXAMPLE
    .\janitor.ps1 -Apply -Level deep
    Full clean. Run from an elevated prompt so the admin-gated targets work.

.EXAMPLE
    .\janitor.ps1 -Apply -Confirm
    Clean, prompting before each target.

.LINK
    https://github.com/vaibhavkothari33/opes-janitor
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch] $Apply,
    [ValidateSet('safe','deep')]
    [string] $Level = 'safe',
    [switch] $Force,
    [string[]] $Only,
    [string[]] $Skip,
    [switch] $NoProbe,
    [switch] $ListTargets,
    [switch] $Quiet,
    [switch] $NoToast,
    [string] $Config
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$JanitorVersion = '1.0.0'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogFile   = Join-Path $ScriptDir 'janitor.log'

# Preload CimCmdlets explicitly. Under -WhatIf, autoloading it mid-run makes
# PowerShell narrate every alias it registers ("What if: Set Alias gcim ..."),
# which buries the report. Import-Module has no -WhatIf parameter of its own,
# so drop the preference across the import and restore it.
$savedWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets -ErrorAction SilentlyContinue
$WhatIfPreference = $savedWhatIfPreference

# ---------------------------------------------------------------- helpers ---

function Get-CanonicalPath {
    # Normalizes a path to ONE canonical form so string prefix matching is sound.
    #
    # Why this exists: %TEMP% expands to the 8.3 short form ("C:\Users\ALICE~1\...")
    # whenever the profile name contains a space, while %LOCALAPPDATA% expands to
    # the long form. Resolve-Path preserves whichever form it was given, so a naive
    # StartsWith() between the two silently fails - which would let a short-form
    # path slip past a long-form protectedPaths entry.
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = ($Path -replace '/', '\').Trim().TrimEnd('\')
    # Get-Item resolves 8.3 -> long; [IO.Path]::GetFullPath cannot (it needs the
    # filesystem), so it is only the fallback for paths that do not exist yet.
    try {
        if (Test-Path -LiteralPath $p) {
            return (Get-Item -LiteralPath $p -Force).FullName.TrimEnd('\')
        }
    } catch { }
    try   { return [System.IO.Path]::GetFullPath($p).TrimEnd('\') }
    catch { return $p }
}

function Expand-PathToken {
    # Expands %VAR% tokens, normalizes forward slashes, then canonicalizes.
    # The config uses forward slashes so it needs no JSON escaping.
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return Get-CanonicalPath ([Environment]::ExpandEnvironmentVariables($Path))
}

function Format-Size {
    param([double] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0,7:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,7:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0,7:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0,7:N0} B ' -f $Bytes)
}

function Write-Log {
    param([string] $Message, [string] $Severity = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Severity, $Message
    # -WhatIf:$false - the log is a record of the run, including a -WhatIf run.
    # Without this the log write itself gets narrated and suppressed.
    try { Add-Content -Path $LogFile -Value $line -Encoding utf8 -WhatIf:$false } catch { }
}

function Say {
    param([string] $Message, [string] $Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

function Get-DirSize {
    # Total bytes under a path. Missing path -> 0. Never throws.
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [int64] 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64] 0 }
        return [int64] $sum
    } catch {
        return [int64] 0
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DriveInfo {
    param([string] $DriveId)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$DriveId'" -ErrorAction SilentlyContinue
    if (-not $disk -or -not $disk.Size) { return $null }
    return [PSCustomObject]@{
        Drive   = $DriveId
        FreeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
        TotalGB = [math]::Round($disk.Size / 1GB, 1)
        FreePct = [math]::Round($disk.FreeSpace / $disk.Size * 100, 1)
        FreeRaw = [int64] $disk.FreeSpace
    }
}

function Get-FixedDrives {
    # DriveType 3 = local fixed disk. Excludes removable, network, optical.
    return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
             Where-Object { $_.Size -gt 0 } |
             ForEach-Object { $_.DeviceID })
}

function Invoke-ExternalCommand {
    param([string] $CommandLine)
    try {
        $output = & cmd.exe /c "$CommandLine 2>&1"
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } catch {
        return @{ ExitCode = -1; Output = $_.Exception.Message }
    }
}

# ------------------------------------------------------- cache discovery ---

function Resolve-ProbePath {
    <#
        Asks a tool where its cache actually lives, instead of assuming the
        default location. Users relocate caches constantly (npmrc, CARGO_HOME,
        GOMODCACHE, YARN_CACHE_FOLDER), and a hardcoded default silently misses
        those - the janitor would report "already empty" while gigabytes sit
        somewhere else.

        Returns a canonical path, or $null if the tool is absent / said nothing
        useful. Never throws.
    #>
    param($Probe)

    try {
        if ($Probe.PSObject.Properties.Name -contains 'requires' -and $Probe.requires) {
            if (-not (Get-Command $Probe.requires -ErrorAction SilentlyContinue)) { return $null }
        }

        $raw = $null

        if ($Probe.PSObject.Properties.Name -contains 'envVar' -and $Probe.envVar) {
            $raw = [Environment]::GetEnvironmentVariable($Probe.envVar)
        }

        if (-not $raw -and $Probe.PSObject.Properties.Name -contains 'command' -and $Probe.command) {
            $r = Invoke-ExternalCommand $Probe.command
            if ($r.ExitCode -ne 0) { return $null }
            # tools sometimes emit warnings first - take the last non-empty line
            $raw = ($r.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        }

        if (-not $raw) { return $null }
        $raw = $raw.Trim().Trim('"')
        if (-not $raw) { return $null }

        if ($Probe.PSObject.Properties.Name -contains 'suffix' -and $Probe.suffix) {
            $raw = Join-Path $raw ($Probe.suffix -replace '/', '\')
        }

        $canon = Get-CanonicalPath $raw
        # a probe that returns something absurd (a bare drive, a relative
        # fragment) is treated as a failed probe, not as a target
        if (-not $canon) { return $null }
        $segments = @($canon -split '\\' | Where-Object { $_ -ne '' })
        if ($segments.Count -lt 3) { return $null }
        return $canon
    } catch {
        return $null
    }
}

# ----------------------------------------------------------------- safety ---

function Test-SafeToDelete {
    <#
        Gatekeeper for every destructive path operation. A path must clear ALL of:
          1. non-empty, exists, is a directory
          2. at least two segments below the drive root
          3. not inside (or equal to) any configured protectedPath
          4. inside at least one allowedPrefix, or equal to / inside this
             target's own probe-discovered path

        Check 3 is evaluated BEFORE check 4, so a protected path can never be
        unlocked by an allowlist entry or by cache discovery.
    #>
    param(
        [string] $Path,
        [string[]] $AllowedPrefixes,
        [string[]] $ProtectedPaths,
        [string] $ExtraAllowed,
        [ref] $Reason
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Reason.Value = 'empty path'; return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $Reason.Value = 'does not exist'; return $false
    }

    # canonical form only - see Get-CanonicalPath for why Resolve-Path is unsafe
    $full = Get-CanonicalPath $Path

    if (-not (Get-Item -LiteralPath $full -Force).PSIsContainer) {
        $Reason.Value = 'not a directory'; return $false
    }

    # depth guard: "C:\Windows\Temp" -> 3 segments. Anything shallower risks a root.
    $segments = @($full -split '\\' | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 3) {
        $Reason.Value = "too shallow: $full"; return $false
    }

    # protected wins over everything, including discovery
    foreach ($p in $ProtectedPaths) {
        if (-not $p) { continue }
        $pf = $p.TrimEnd('\')
        if ($full -eq $pf -or $full.StartsWith($pf + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $Reason.Value = "protected path: $pf"; return $false
        }
    }

    $candidates = @($AllowedPrefixes)
    if ($ExtraAllowed) { $candidates += $ExtraAllowed }

    foreach ($a in $candidates) {
        if (-not $a) { continue }
        $af = $a.TrimEnd('\')
        if ($full -eq $af -or $full.StartsWith($af + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $Reason.Value = "outside allowlist: $full"
    return $false
}

function Clear-DirectoryContents {
    # Deletes the CHILDREN of a directory, never the directory itself.
    # Skips reparse points (junctions/symlinks) rather than recursing through them.
    # Locked files are counted and reported, not fatal.
    param(
        [string] $Path,
        [int] $OlderThanDays = 0
    )

    $stats = @{ Deleted = 0; Skipped = 0; Locked = 0 }
    $cutoff = $null
    if ($OlderThanDays -gt 0) { $cutoff = (Get-Date).AddDays(-$OlderThanDays) }

    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    foreach ($child in $children) {

        # never traverse a junction/symlink
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $stats.Skipped++
            continue
        }

        if ($cutoff) {
            $stamp = $child.LastWriteTime
            if ($child.PSIsContainer) {
                # a folder counts as recent if anything inside it is recent
                $newest = Get-ChildItem -LiteralPath $child.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newest) { $stamp = $newest.LastWriteTime }
            }
            if ($stamp -gt $cutoff) { $stats.Skipped++; continue }
        }

        try {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
            $stats.Deleted++
        } catch {
            $stats.Locked++
        }
    }
    return $stats
}

function Show-Toast {
    param([string] $Title, [string] $Message)
    if ($NoToast) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.Visible = $true
        $icon.ShowBalloonTip(8000)
        Start-Sleep -Seconds 9
        $icon.Dispose()
    } catch {
        # notifications are cosmetic - never fail a run over one
    }
}

# --------------------------------------------------------- config loading ---

function Resolve-ConfigPath {
    param([string] $Explicit, [string] $ScriptDirectory)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "Config not found: $Explicit" }
        return (Get-Item -LiteralPath $Explicit).FullName
    }
    # a user copy in APPDATA survives updates that overwrite the shipped config
    $userCfg = Join-Path $env:APPDATA 'opes-janitor\config.json'
    if (Test-Path -LiteralPath $userCfg) { return $userCfg }

    $shipped = Join-Path $ScriptDirectory 'janitor.config.json'
    if (Test-Path -LiteralPath $shipped) { return $shipped }

    throw "No config found. Looked for: $userCfg and $shipped"
}

# ------------------------------------------------------------------- main ---

try {
    $configPath = Resolve-ConfigPath -Explicit $Config -ScriptDirectory $ScriptDir
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

try {
    $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Error "Config is not valid JSON: $configPath`n$($_.Exception.Message)"
    exit 2
}

$allowed   = @($cfg.allowedPrefixes | ForEach-Object { Expand-PathToken $_ } | Where-Object { $_ })
$protected = @($cfg.protectedPaths  | ForEach-Object { Expand-PathToken $_ } | Where-Object { $_ })

# --- cache discovery ----------------------------------------------------

$probed = @{}
if (-not $NoProbe -and ($cfg.PSObject.Properties.Name -contains 'probes')) {
    foreach ($probe in $cfg.probes) {
        $found = Resolve-ProbePath $probe
        if ($found) { $probed[$probe.targetId] = $found }
    }
}

# --- list mode ----------------------------------------------------------

if ($ListTargets) {
    Write-Host ''
    Write-Host "  opes-janitor $JanitorVersion" -ForegroundColor Cyan
    Write-Host "  config: $configPath" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ID                             LEVEL  ON   KIND          LABEL' -ForegroundColor Cyan
    Write-Host '  -----------------------------  -----  ---  ------------  ------------------------------'
    foreach ($t in $cfg.targets) {
        $on    = if ($t.enabled) { 'yes' } else { 'no ' }
        $color = if ($t.enabled) { 'Gray' } else { 'DarkGray' }
        Write-Host ('  {0,-29}  {1,-5}  {2}  {3,-12}  {4}' -f $t.id, $t.level, $on, $t.kind, $t.label) -ForegroundColor $color
        if ($probed.ContainsKey($t.id)) {
            Write-Host ("      discovered: $($probed[$t.id])") -ForegroundColor DarkCyan
        }
    }
    Write-Host ''
    exit 0
}

$runMode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
$isAdmin = Test-IsAdmin

Say ''
Say "  opes-janitor $JanitorVersion  [$runMode]  level=$Level" 'Cyan'
Say '  ---------------------------------------------------------------' 'DarkGray'
Write-Log "run start: v$JanitorVersion mode=$runMode level=$Level admin=$isAdmin config=$configPath"

if ($probed.Count -gt 0 -and -not $Quiet) {
    foreach ($k in $probed.Keys) {
        Say ("  discovered  {0,-22} {1}" -f $k, $probed[$k]) 'DarkCyan'
        Write-Log "discovered $k -> $($probed[$k])"
    }
    Say ''
}

# --- drive report -------------------------------------------------------

$driveList = @()
if ($cfg.drives -is [string] -and $cfg.drives -eq 'auto') {
    $driveList = Get-FixedDrives
} else {
    $driveList = @($cfg.drives)
}

$driveState = @()
foreach ($d in $driveList) {
    $info = Get-DriveInfo $d
    if (-not $info) { continue }
    $driveState += $info
    $color = 'Green'
    if ($info.FreePct -lt $cfg.thresholds.warnBelowFreePercent)        { $color = 'Red' }
    elseif ($info.FreePct -lt $cfg.thresholds.skipRunAboveFreePercent) { $color = 'Yellow' }
    Say ('  {0}  {1,6:N1} GB free of {2,6:N1} GB   {3,5:N1}% free' -f $info.Drive, $info.FreeGB, $info.TotalGB, $info.FreePct) $color
    Write-Log ('drive {0}: {1}GB free / {2}GB ({3}%)' -f $info.Drive, $info.FreeGB, $info.TotalGB, $info.FreePct)
}
Say ''

# --- threshold gate -----------------------------------------------------

$worstFree = ($driveState | Measure-Object -Property FreePct -Minimum).Minimum
if (-not $Force -and $null -ne $worstFree -and $worstFree -gt $cfg.thresholds.skipRunAboveFreePercent) {
    Say ('  All drives above {0}% free. Nothing to do. Use -Force to run anyway.' -f $cfg.thresholds.skipRunAboveFreePercent) 'Green'
    Write-Log "skipped: worst drive at $worstFree% free, above threshold"
    exit 0
}

# --- target selection ---------------------------------------------------

$levels = if ($Level -eq 'deep') { @('safe','deep') } else { @('safe') }

$selected = @()
foreach ($t in $cfg.targets) {
    if ($Only -and ($t.id -notin $Only)) { continue }
    if ($Skip -and ($t.id -in $Skip))    { continue }
    if ($Only) {
        # explicit -Only overrides the enabled flag and the level filter,
        # but never the safety guard
        $selected += ,@($t, 'run')
        continue
    }
    if (-not $t.enabled)         { $selected += ,@($t, 'report-only'); continue }
    if ($t.level -notin $levels) { continue }
    $selected += ,@($t, 'run')
}

# --- execute ------------------------------------------------------------

$results    = @()
$totalFreed = [int64] 0

foreach ($pair in $selected) {
    $t        = $pair[0]
    $itemMode = $pair[1]
    $hasProp  = $t.PSObject.Properties.Name

    # a discovered path overrides the configured default for this target
    $discovered  = $null
    if ($probed.ContainsKey($t.id)) { $discovered = $probed[$t.id] }

    $measurePath = if ($discovered) { $discovered } else { Expand-PathToken $t.measure }
    $before      = Get-DirSize $measurePath
    $status      = ''
    $freed       = [int64] 0

    $missingReq = $false
    if (($hasProp -contains 'requires') -and $t.requires) {
        if (-not (Get-Command $t.requires -ErrorAction SilentlyContinue)) { $missingReq = $true }
    }
    $needsAdmin = (($hasProp -contains 'requiresAdmin') -and $t.requiresAdmin)

    if ($missingReq) {
        $status = "skip: $($t.requires) not installed"
    }
    elseif ($itemMode -eq 'report-only') {
        $status = 'REVIEW - not enabled'
    }
    elseif ($needsAdmin -and -not $isAdmin) {
        $status = 'skip: needs admin'
    }
    elseif ($before -eq 0 -and $t.kind -ne 'builtin') {
        $status = 'already empty'
    }
    elseif (-not $Apply) {
        $status = 'would clean'
        $freed  = $before
    }
    elseif (-not $PSCmdlet.ShouldProcess($t.label, 'Clear')) {
        $status = 'skipped (WhatIf/declined)'
    }
    else {
        # ------------------- destructive from here -------------------
        switch ($t.kind) {

            'pathContents' {
                $p = if ($discovered) { $discovered } else { Expand-PathToken $t.path }
                $reason = ''
                if (-not (Test-SafeToDelete -Path $p -AllowedPrefixes $allowed -ProtectedPaths $protected -ExtraAllowed $discovered -Reason ([ref]$reason))) {
                    $status = "REFUSED: $reason"
                    Write-Log "REFUSED $($t.id): $reason" 'WARN'
                    break
                }
                $days = 0
                if ($hasProp -contains 'olderThanDays') { $days = [int] $t.olderThanDays }
                $st     = Clear-DirectoryContents -Path $p -OlderThanDays $days
                $after  = Get-DirSize $measurePath
                $freed  = [math]::Max([int64] 0, [int64] ($before - $after))
                $status = "cleaned ($($st.Deleted) removed"
                if ($st.Skipped) { $status += ", $($st.Skipped) kept" }
                if ($st.Locked)  { $status += ", $($st.Locked) locked" }
                $status += ')'
            }

            'command' {
                $r      = Invoke-ExternalCommand $t.command
                $after  = Get-DirSize $measurePath
                $freed  = [math]::Max([int64] 0, [int64] ($before - $after))
                if ($r.ExitCode -eq 0) {
                    $status = 'cleaned'
                } else {
                    $status = "command exit $($r.ExitCode)"
                    Write-Log "$($t.id) output: $($r.Output)" 'WARN'
                }
            }

            'builtin' {
                switch ($t.builtin) {
                    'recyclebin' {
                        try {
                            Clear-RecycleBin -Force -ErrorAction Stop
                            $after  = Get-DirSize $measurePath
                            $freed  = [math]::Max([int64] 0, [int64] ($before - $after))
                            $status = 'emptied'
                        } catch {
                            $status = 'already empty'
                        }
                    }
                    'dism' {
                        $freeBefore = (Get-DriveInfo 'C:').FreeRaw
                        $r = Invoke-ExternalCommand 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet'
                        $freeAfter  = (Get-DriveInfo 'C:').FreeRaw
                        $freed      = [math]::Max([int64] 0, [int64] ($freeAfter - $freeBefore))
                        $status     = if ($r.ExitCode -eq 0) { 'cleaned' } else { "dism exit $($r.ExitCode)" }
                    }
                    default { $status = "unknown builtin: $($t.builtin)" }
                }
            }

            default { $status = "unknown kind: $($t.kind)" }
        }
        if ($freed -gt 0) { Write-Log ('{0}: freed {1:N0} bytes ({2})' -f $t.id, $freed, $status) }
    }

    if ($status -notlike 'skip*' -and $status -notlike 'REVIEW*' -and $status -notlike 'REFUSED*') {
        $totalFreed += $freed
    }

    $results += [PSCustomObject]@{
        Target = $t.id
        Held   = Format-Size $before
        Freed  = if ($freed -gt 0) { Format-Size $freed } else { '' }
        Status = $status
    }
}

# --- report -------------------------------------------------------------

if (-not $Quiet) {
    Write-Host ''
    Write-Host ('  {0,-30} {1,11} {2,11}  {3}' -f 'TARGET','HOLDING','FREED','STATUS') -ForegroundColor Cyan
    Write-Host '  ------------------------------ ----------- -----------  -----------------------------'
    foreach ($r in $results) {
        $color = 'Gray'
        if     ($r.Status -like 'REFUSED*')  { $color = 'Red' }
        elseif ($r.Status -like 'REVIEW*')   { $color = 'Yellow' }
        elseif ($r.Status -like 'skip*')     { $color = 'DarkGray' }
        elseif ($r.Status -like 'already*')  { $color = 'DarkGray' }
        elseif ($r.Freed)                    { $color = 'Green' }
        Write-Host ('  {0,-30} {1,11} {2,11}  {3}' -f $r.Target, $r.Held, $r.Freed, $r.Status) -ForegroundColor $color
    }
    Write-Host ''
}

$verb    = if ($Apply) { 'Reclaimed' } else { 'Would reclaim' }
$summary = '{0}: {1}' -f $verb, (Format-Size $totalFreed).Trim()
Say ('  ' + $summary) 'Green'

if (-not $Apply -and $totalFreed -gt 0) {
    Say ''
    Say '  NOTE: dry-run figures are an UPPER BOUND, not a promise.' 'DarkYellow'
    Say '    - age-filtered targets show the whole folder, but only files past' 'DarkGray'
    Say '      their age cutoff are actually removed' 'DarkGray'
    Say '    - docker-prune only removes UNUSED layers, and the WSL vhdx does not' 'DarkGray'
    Say '      shrink on its own, so reclaimed space may not show up at once' 'DarkGray'
    Say '    - locked / in-use files are skipped' 'DarkGray'
    Say ''
    Say '  Re-run with -Apply to actually clean.' 'Yellow'
}

if ($Apply) {
    Say ''
    foreach ($d in $driveList) {
        $info = Get-DriveInfo $d
        if (-not $info) { continue }
        $color = if ($info.FreePct -lt $cfg.thresholds.warnBelowFreePercent) { 'Red' } else { 'Green' }
        Say ('  {0} now {1,6:N1} GB free  ({2:N1}%)' -f $info.Drive, $info.FreeGB, $info.FreePct) $color
    }
}
Say ''

Write-Log ('run end: {0} {1:N0} bytes' -f $verb, $totalFreed)

# --- log rotation -------------------------------------------------------

try {
    if (Test-Path -LiteralPath $LogFile) {
        $cut  = (Get-Date).AddDays(-[int] $cfg.logRetentionDays)
        $kept = Get-Content -LiteralPath $LogFile | Where-Object {
            if ($_ -match '^(\d{4}-\d{2}-\d{2})') { [datetime]::Parse($Matches[1]) -ge $cut } else { $true }
        }
        Set-Content -LiteralPath $LogFile -Value $kept -Encoding utf8 -WhatIf:$false
    }
} catch { }

if ($Apply -and $totalFreed -gt 0) {
    Show-Toast -Title 'opes-janitor' -Message $summary
}

exit 0
