<#
.SYNOPSIS
    Register (or remove) the Windows scheduled task that runs the unattended update.

.DESCRIPTION
    Plan 014 step 6. Pairs with scripts/scheduled-update.ps1, which is what the
    task actually runs - not install.ps1 directly, because install.ps1 exits 0 even
    when the repo half of the update was skipped.

    Requires elevation: registering a task under \ requires an administrator
    token. This script checks and tells you, rather than failing obscurely.

.PARAMETER Time
    Local time to run, HH:mm. Default 03:30 - overnight, because the update pulls
    images and restarts containers.

.PARAMETER MaintenanceWindowStart
.PARAMETER MaintenanceWindowEnd
    Quiet-hours range passed through to scheduled-update.ps1. Defaults 22 -> 06.

.PARAMETER BundleDir
    deploy/client-bundle. Defaults to the repo layout.

.PARAMETER Remove
    Unregister the task instead of creating it.

.PARAMETER WhatIf
    Show the action without performing it.

.EXAMPLE
    .\register-scheduled-update.ps1
    Registers a daily 03:30 update with a 22-06 quiet window.

.EXAMPLE
    .\register-scheduled-update.ps1 -Time 02:00 -MaintenanceWindowStart 1 -MaintenanceWindowEnd 5
#>
[CmdletBinding()]
param(
    [string]$Time = '03:30',
    [int]$MaintenanceWindowStart = 22,
    [int]$MaintenanceWindowEnd = 6,
    [string]$BundleDir,
    [switch]$Remove,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$taskName = 'PacgateAIPCUpdate'
$wrapper = Join-Path $PSScriptRoot 'scheduled-update.ps1'

if (-not (Test-Path -LiteralPath $wrapper)) {
    throw "scheduled-update.ps1 not found next to this script ($wrapper)"
}

# ── elevation check ─────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($WhatIf) {
    Write-Host "[WhatIf] would $(if ($Remove) { 'remove' } else { 'register' }) task '$taskName'"
    if (-not $Remove) {
        Write-Host "  action : pwsh -NoProfile -File `"$wrapper`" -MaintenanceWindowStart $MaintenanceWindowStart -MaintenanceWindowEnd $MaintenanceWindowEnd"
        Write-Host "  trigger: daily at $Time"
    }
    exit 0
}

if (-not $isAdmin) {
    Write-Host 'ERROR: registering a scheduled task requires an administrator shell.' -ForegroundColor Red
    Write-Host '  Re-run this from an elevated PowerShell, or register it by hand:' -ForegroundColor Yellow
    Write-Host '' -ForegroundColor Yellow
    Write-Host "    Program: pwsh.exe" -ForegroundColor Gray
    Write-Host "    Arguments: -NoProfile -File `"$wrapper`" -MaintenanceWindowStart $MaintenanceWindowStart -MaintenanceWindowEnd $MaintenanceWindowEnd" -ForegroundColor Gray
    Write-Host "    Trigger: Daily at $Time" -ForegroundColor Gray
    Write-Host '' -ForegroundColor Yellow
    Write-Host '  (This script cannot elevate itself: a UAC prompt cannot be answered' -ForegroundColor DarkGray
    Write-Host '   from an automated context, and routing a password through it would be' -ForegroundColor DarkGray
    Write-Host '   worse than asking you to open an elevated shell.)' -ForegroundColor DarkGray
    exit 1
}

if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "[OK] Task '$taskName' is not registered - nothing to remove." -ForegroundColor Green
        exit 0
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "[OK] Removed scheduled task '$taskName'." -ForegroundColor Green
    exit 0
}

# ── register ────────────────────────────────────────────────────────────────
if (-not $BundleDir) {
    $BundleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle'
}

$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    $pwsh = (Get-Command powershell).Source
    Write-Host '[WARN] pwsh (PowerShell 7) not found; using Windows PowerShell 5.1.' -ForegroundColor Yellow
    Write-Host '       The scripts are written for 7; 5.1 may differ on some cmdlets.' -ForegroundColor Yellow
}

$argList = @(
    '-NoProfile'
    '-NonInteractive'
    '-File', "`"$wrapper`""
    '-BundleDir', "`"$BundleDir`""
    '-MaintenanceWindowStart', $MaintenanceWindowStart
    '-MaintenanceWindowEnd', $MaintenanceWindowEnd
)
$action = New-ScheduledTaskAction -Execute $pwsh -Argument ($argList -join ' ') -WorkingDirectory (Split-Path -Parent $wrapper)

$trigger = New-ScheduledTaskTrigger -Daily -At $Time

# Run whether or not the user is logged in, and start late if the machine was
# asleep at the trigger time (a laptop-class machine may well have been). The
# latter is the common case for an overnight window.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

# SYSTEM: this must run when nobody is logged in. It needs Docker Desktop, which
# is a per-user app, so the task may legitimately fail if Docker is not running -
# that is a FAILED outcome in the log, which is the correct signal.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Write-Host "[..] Task '$taskName' exists - replacing it." -ForegroundColor Cyan
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal `
    -Description 'Pacgate AIPC unattended update. Runs scheduled-update.ps1, which classifies the result as SUCCESS/DEGRADED/FAILED. DEGRADED means images updated but repo content did not - see plans/014.' | Out-Null

Write-Host "[OK] Registered '$taskName'." -ForegroundColor Green
Write-Host ''
Write-Host '  Runs        : daily at ' -NoNewline; Write-Host $Time -ForegroundColor White
Write-Host '  Quiet hours : ' -NoNewline; Write-Host "$MaintenanceWindowStart-$MaintenanceWindowEnd" -ForegroundColor White
Write-Host "  Command     : $pwsh -NoProfile -File `"$wrapper`"" -ForegroundColor Gray
Write-Host ''
Write-Host '  Exit codes (visible in the Task Scheduler "Last Run Result" column):' -ForegroundColor Cyan
Write-Host '    0x0  SUCCESS   everything landed' -ForegroundColor Green
Write-Host '    0x2  DEGRADED  images landed, repo did NOT - needs a human' -ForegroundColor Yellow
Write-Host '    0x1  FAILED    the update errored' -ForegroundColor Red
Write-Host ''
Write-Host '  Check it now:' -ForegroundColor Cyan
Write-Host "    Start-ScheduledTask -TaskName $taskName" -ForegroundColor Gray
Write-Host "    Get-Content `"$BundleDir\logs\last-update-status.json`"" -ForegroundColor Gray
Write-Host ''
Write-Host '  Remove it:' -ForegroundColor Cyan
Write-Host "    .\scripts\register-scheduled-update.ps1 -Remove" -ForegroundColor Gray
