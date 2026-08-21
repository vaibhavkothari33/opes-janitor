<#
.SYNOPSIS
    Registers (or removes) the opes-janitor Scheduled Task.

.DESCRIPTION
    Creates a daily task that runs janitor.ps1 -Apply. The script itself exits
    immediately when every drive is already above the configured free-space
    threshold, so a daily trigger costs nothing on days when there is no work.

    Run this from an ELEVATED PowerShell prompt if you want -Level deep
    (DISM component-store cleanup needs administrator).

.PARAMETER Level
    safe (default) or deep - passed through to janitor.ps1.

.PARAMETER At
    Time of day to run, HH:mm. Default 13:00.

.PARAMETER Uninstall
    Remove the scheduled task instead of creating it.

.EXAMPLE
    .\install-task.ps1
    Daily safe clean at 13:00, running as the current user.

.EXAMPLE
    .\install-task.ps1 -Level deep -At 02:30
    Daily deep clean at 02:30. Needs an elevated prompt.

.EXAMPLE
    .\install-task.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet('safe','deep')]
    [string] $Level = 'safe',
    [ValidatePattern('^\d{2}:\d{2}$')]
    [string] $At = '13:00',
    [switch] $Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TaskName  = 'opes-janitor'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Target    = Join-Path $ScriptDir 'janitor.ps1'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- uninstall ----------------------------------------------------------

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "Task '$TaskName' is not registered. Nothing to do." -ForegroundColor Yellow
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    exit 0
}

# --- preflight ----------------------------------------------------------

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Error "janitor.ps1 not found next to this script: $Target"
    exit 2
}

$isAdmin = Test-IsAdmin
if ($Level -eq 'deep' -and -not $isAdmin) {
    Write-Host ''
    Write-Host '  WARNING: -Level deep includes the DISM component-store cleanup,' -ForegroundColor Yellow
    Write-Host '  which requires administrator. Registering from a non-elevated' -ForegroundColor Yellow
    Write-Host '  prompt means that one target will be skipped on every run.' -ForegroundColor Yellow
    Write-Host '  Re-run this installer as administrator to enable it.' -ForegroundColor Yellow
    Write-Host ''
}

# --- build task ---------------------------------------------------------

$psExe = (Get-Command powershell.exe).Source

$argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Apply -Level {1} -Quiet' -f $Target, $Level

$action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $ScriptDir

$trigger = New-ScheduledTaskTrigger -Daily -At $At

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstances IgnoreNew

$runLevel = if ($isAdmin) { 'Highest' } else { 'Limited' }
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel $runLevel

# --- register -----------------------------------------------------------

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Replacing existing task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'Reclaims disk space from developer tool caches. Exits immediately when free space is already above threshold.' | Out-Null

Write-Host ''
Write-Host "  Registered scheduled task '$TaskName'" -ForegroundColor Green
Write-Host "    runs      : daily at $At"
Write-Host "    level     : $Level"
Write-Host "    runlevel  : $runLevel"
Write-Host "    command   : $psExe $argLine"
Write-Host ''
Write-Host '  Verify with : Get-ScheduledTask -TaskName opes-janitor'
Write-Host '  Run now with: Start-ScheduledTask -TaskName opes-janitor'
Write-Host '  Remove with : .\install-task.ps1 -Uninstall'
Write-Host ''
