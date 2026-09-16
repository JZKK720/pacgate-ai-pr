<#
.SYNOPSIS
    Unattended wrapper around `install.ps1 -Update` for a scheduled task.

.DESCRIPTION
    Plan 014 step 6. This is the step that removes the human, so it is built to do
    one thing above all: make a DEGRADED update loud.

    WHY NOT JUST SCHEDULE install.ps1 DIRECTLY

    Because `install.ps1 -Update` can succeed while doing half its job, and the
    half it skipped is the invisible half. Concretely:

      - "Repo has local changes - skipping the repo update."  -> exit code 0
      - "Repo has diverged ... not fast-forwardable."         -> exit code 0
      - "Repo is not a git checkout"                          -> exit code 0

    In every one of those cases the images still pull, the containers still
    restart, and the command returns success. The machine then drifts behind on
    ALL repo content - compose pins, patches, workflows, nginx config - with no
    error anywhere. Scheduling install.ps1 directly would reproduce exactly the
    silent failure this plan exists to eliminate, but at machine speed on two
    machines, which is the outcome plan 014 explicitly warns against:

        "Do not skip ahead to this step. Automating the update BEFORE fixing 1-5
         would propagate silent failures at machine speed across both AIPCs."

    So this wrapper classifies the run into three outcomes and records which one
    happened, in a file the operator can read and in the Windows event log:

        SUCCESS   everything landed
        DEGRADED  images landed, repo did NOT - needs a human, machine is drifting
        FAILED    the update itself errored

    DEGRADED is the important one. It is not an error by install.ps1's standards,
    so nothing else in the system would ever report it.

.PARAMETER BundleDir
    Path to deploy/client-bundle. Defaults to this script's sibling.

.PARAMETER LogDir
    Where run logs go. Defaults to <bundle>\logs.

.PARAMETER KeepRuns
    How many run logs to retain. Default 30. A client machine runs for months;
    an unbounded log directory is a slow disk leak with no error.

.PARAMETER MaintenanceWindowStart
.PARAMETER MaintenanceWindowEnd
    Optional hour range (0-23) outside which the update is SKIPPED rather than
    run. A `-Update` pulls images and restarts containers, so running it mid-afternoon
    would interrupt whoever is working. Empty (the default) means run any time.

.PARAMETER Force
    Run even outside the maintenance window.

.EXAMPLE
    # Interactive, any time:
    .\scheduled-update.ps1

.EXAMPLE
    # What the scheduled task runs (03:30, quiet hours 22-06):
    pwsh -NoProfile -File C:\pacgate-ai-pr\scripts\scheduled-update.ps1 -MaintenanceWindowStart 22 -MaintenanceWindowEnd 6
#>
[CmdletBinding()]
param(
    [string]$BundleDir,
    [string]$LogDir,
    [int]$KeepRuns = 30,
    [int]$MaintenanceWindowStart = -1,
    [int]$MaintenanceWindowEnd = -1,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $BundleDir) {
    # This script lives in <repo>\scripts, and the bundle in <repo>\deploy\client-bundle.
    $BundleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle'
}
if (-not $LogDir) { $LogDir = Join-Path $BundleDir 'logs' }

$installer = Join-Path $BundleDir 'install.ps1'
if (-not (Test-Path -LiteralPath $installer)) {
    throw "install.ps1 not found at $installer - pass -BundleDir"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "update-$stamp.log"
$statusFile = Join-Path $LogDir 'last-update-status.json'

function Write-Log {
    param([string]$Line)
    # Written to both the console (for a manual run) and the log file.
    Write-Output $Line
    Add-Content -LiteralPath $logFile -Value $Line -Encoding UTF8
}

# ── maintenance window ──────────────────────────────────────────────────────
# Evaluated BEFORE running, so a skipped run is recorded deliberately rather than
# looking like a failure. Handles a window that wraps midnight (22 -> 6).
if (-not $Force -and $MaintenanceWindowStart -ge 0 -and $MaintenanceWindowEnd -ge 0) {
    $hour = (Get-Date).Hour
    $inWindow = if ($MaintenanceWindowStart -le $MaintenanceWindowEnd) {
        $hour -ge $MaintenanceWindowStart -and $hour -lt $MaintenanceWindowEnd
    }
    else {
        $hour -ge $MaintenanceWindowStart -or $hour -lt $MaintenanceWindowEnd
    }

    if (-not $inWindow) {
        Write-Log "SKIPPED: outside the maintenance window ($MaintenanceWindowStart-$MaintenanceWindowEnd, now $hour)."
        Write-Log "  A -Update restarts containers, so it does not run while people are working."
        Write-Log "  Pass -Force, or widen the window, to override."
        $rec = [pscustomobject]@{
            timestamp = (Get-Date).ToString('o'); outcome = 'SKIPPED'; reason = 'outside maintenance window'
            exitCode = $null; logFile = $logFile; degradedReasons = @()
        }
        [System.IO.File]::WriteAllText($statusFile, ($rec | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
        exit 0
    }
}

Write-Log "=== scheduled update: $stamp ==="

# ── run the real installer ──────────────────────────────────────────────────
# 6>&1 is required: install.ps1 uses Write-Host, which goes to the Information
# stream, and a plain 2>&1 would capture nothing - so the classification below
# would see an empty string and always report SUCCESS. That is the same trap that
# made an earlier test pass for the wrong reason.
$output = & pwsh -NoProfile -File $installer -Update 6>&1 2>&1 | Out-String
$exit = $LASTEXITCODE

$output.TrimEnd() -split "`r?`n" | ForEach-Object { Add-Content -LiteralPath $logFile -Value $_ -Encoding UTF8 }

# ── classify ────────────────────────────────────────────────────────────────
#
# Patterns, not exit codes. install.ps1 exits 0 for every condition below, so the
# exit code alone cannot distinguish "everything landed" from "the repo half was
# silently skipped".
$degradedPatterns = @(
    @{ Re = 'Repo has local changes - skipping the repo update'; Why = 'repo is dirty, so the repo refresh was SKIPPED' }
    @{ Re = 'Repo has diverged from .* not fast-forwardable';    Why = 'repo has diverged from the remote and was NOT updated' }
    @{ Re = 'git not found - cannot refresh the repo';           Why = 'git is missing, so repo content cannot be updated' }
    @{ Re = 'is not a git checkout - cannot refresh';            Why = 'this is not a git checkout, so repo content cannot be updated' }
    @{ Re = 'git fetch failed \(offline\?\)';                    Why = 'could not reach the remote (offline); repo not checked' }
    @{ Re = 'qm sandbox source has CHANGED';                     Why = 'qm sandbox is stale - the agent runs old skills and tools' }
    @{ Re = 'qm sandbox image is digest-pinned with no recorded'; Why = 'qm sandbox provenance is unverifiable' }
)

$reasons = @()
foreach ($p in $degradedPatterns) {
    if ($output -match $p.Re) { $reasons += $p.Why }
}
$reasons = @($reasons | Select-Object -Unique)

$outcome = if ($exit -ne 0) { 'FAILED' }
           elseif ($reasons.Count -gt 0) { 'DEGRADED' }
           else { 'SUCCESS' }

# ── record ──────────────────────────────────────────────────────────────────
$rec = [pscustomobject]@{
    timestamp       = (Get-Date).ToString('o')
    outcome         = $outcome
    exitCode        = $exit
    degradedReasons = $reasons
    logFile         = $logFile
    host            = $env:COMPUTERNAME
}
[System.IO.File]::WriteAllText($statusFile, ($rec | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))

Write-Log "OUTCOME: $outcome (installer exit $exit)"
if ($reasons.Count -gt 0) {
    Write-Log "  The update ran but did NOT fully land. Reasons:"
    $reasons | ForEach-Object { Write-Log "    - $_" }
    Write-Log "  Images were still updated, so this machine keeps working - but repo"
    Write-Log "  content (compose pins, patches, workflows, nginx config) did not move."
    Write-Log "  This is the failure that has no error of its own, which is why it is"
    Write-Log "  reported here. See plans/013 for the re-clone procedure if the repo"
    Write-Log "  was force-pushed, and plans/014 step 6 for this wrapper."
}
Write-Log "  status file: $statusFile"

# ── event log (best effort) ─────────────────────────────────────────────────
# Makes the outcome visible to Windows tooling rather than only to someone who
# thinks to read a log file. Failure here must not fail the update.
try {
    $evtType = switch ($outcome) { 'SUCCESS' { 'Information' } 'DEGRADED' { 'Warning' } default { 'Error' } }
    # Built as a plain variable rather than an inline if-expression: an `if`
    # statement used as a sub-expression inside `+` is not reliably valid
    # PowerShell, and it is not worth the ambiguity for one string.
    $detail = 'All components updated.'
    if ($reasons.Count -gt 0) { $detail = $reasons -join '; ' }
    $msg = "Pacgate update: $outcome. $detail"

    if (Get-Command Write-EventLog -ErrorAction SilentlyContinue) {
        if (-not [System.Diagnostics.EventLog]::SourceExists('PacgateUpdate')) {
            New-EventLog -LogName Application -Source 'PacgateUpdate' -ErrorAction SilentlyContinue
        }
        Write-EventLog -LogName Application -Source 'PacgateUpdate' -EventId 1000 -EntryType $evtType -Message $msg -ErrorAction SilentlyContinue
    }
}
catch {
    Add-Content -LiteralPath $logFile -Value "  (could not write to the event log: $($_.Exception.Message))" -Encoding UTF8
}

# ── rotate logs ─────────────────────────────────────────────────────────────
# Keep the newest $KeepRuns run logs. Unbounded growth on a machine nobody logs
# into is a slow disk leak that surfaces as an unrelated failure months later.
$old = @(Get-ChildItem -LiteralPath $LogDir -Filter 'update-*.log' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepRuns)
if ($old.Count -gt 0) {
    $old | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log ("  rotated out {0} old log(s), keeping the newest {1}" -f $old.Count, $KeepRuns)
}

# Exit code carries the outcome so the Task Scheduler "last result" column is
# meaningful: 0 = everything landed, 2 = degraded, 1 = failed.
exit $(switch ($outcome) { 'SUCCESS' { 0 } 'DEGRADED' { 2 } default { 1 } })
