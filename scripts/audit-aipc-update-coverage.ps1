# Measure the AIPC update gap: what actually updates unattended today?
#
# Read-only. Reports, for each component, whether `.\install.ps1 -Update` is
# sufficient, or whether a human must intervene. The end-goal is unattended
# updates, so every remaining GAP is a reason a developer still has to log in.
#
# IMPORTANT - this script was previously WRONG and that is why it now works the
# way it does. Its verdicts were hardcoded strings, so after plan 014 fixed
# three of the defects it still printed them as GAPs. A coverage tool that
# reports stale gaps trains you to ignore it. Every verdict below is DERIVED
# from install.ps1's actual text via the marker table, so closing a gap in
# install.ps1 closes it here with no edit to this file.
#
# Markers are deliberately specific ('--ff-only') rather than loose keywords
# ('git'), because a loose match reports coverage that does not exist - the
# same failure mode as the hardcoded strings, just automated.

[CmdletBinding()]
param(
    # Show the marker each verdict was derived from.
    [switch]$Explain
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'deploy/client-bundle/install.ps1'

if (-not (Test-Path $installer)) {
    throw "Cannot audit: install.ps1 not found at $installer"
}

# Read once. @() guards against Get-Content returning a bare [string] for a
# single-line file, which would make indexing return a character not a line.
$src = @(Get-Content -LiteralPath $installer)
$srcText = $src -join "`n"

function Test-Marker {
    param([string[]]$Any)
    foreach ($m in $Any) {
        if ($srcText.Contains($m)) { return $m }
    }
    return $null
}

# Component -> capability -> the literal marker proving install.ps1 does it.
# Adding a capability to install.ps1 makes this row go OK automatically.
#
# MARKERS MUST BE SPECIFIC. 'restart deer-flow' is used for two rows on purpose -
# one behaviour genuinely covers both - but a loose keyword like 'qm' would go OK
# the moment the word appears in a comment, which is how a coverage table starts
# lying. Where a capability arrived in a numbered step, the marker names the step.
$checks = @(
    [pscustomobject]@{ Component = 'GHCR images (4)';           Needs = 'pull + recreate';                     Any = @('compose.prod.yaml pull') }
    [pscustomobject]@{ Component = 'nginx/default.conf';        Needs = 'config reload';                       Any = @('nginx -s reload') }
    [pscustomobject]@{ Component = 'workflows/*.yaml (15)';     Needs = 'nothing (read per request)';          Any = @('__noop__') }
    [pscustomobject]@{ Component = 'personas/, patches/*.py';   Needs = 'container restart';                   Any = @('restart deer-flow') }
    [pscustomobject]@{ Component = 'deer-flow-config.yaml';     Needs = 'container restart';                   Any = @('restart deer-flow') }
    [pscustomobject]@{ Component = 'extensions-config.json';    Needs = 're-render + compare';                 Any = @('RENDER-AND-COMPARE', '$dfExisting') }
    [pscustomobject]@{ Component = 'repo working tree';         Needs = 'fast-forward pull';                   Any = @('git pull --ff-only') }
    # Step 7f re-stages the RUNTIME qm config from the tracked source. This is
    # the R2 gap: setup-qm.ps1 staged it once, and nothing refreshed it
    # afterwards, so a config change needed a manual re-run of an interactive
    # script. It also matters because qm-sandbox-fingerprint.ps1 inspects the
    # TRACKED file while qm runs the runtime copy - re-staging is what makes the
    # drift detector's answer meaningful.
    [pscustomobject]@{ Component = 'qm runtime config';         Needs = 're-stage from tracked source (7f)';   Any = @('Re-staging the qm runtime config') }
    [pscustomobject]@{ Component = 'qm stack (7 containers)';   Needs = 'restart after a config change';       Any = @('compose.qm.yaml restart') }
    [pscustomobject]@{ Component = 'qm sandbox image';          Needs = 'drift detected (plan 014 step 4)';    Any = @('qm-sandbox-fingerprint.ps1') }
    # Step 7e reads the RUNNING binary's version and compares it with the compose
    # pin. It queries the nginx front door, so the marker is the exact URL
    # assignment.
    #
    # It was the bare string '/version' first, and a mutation test caught why
    # that is too loose: breaking the probe URL still left '/version' in the
    # surrounding comments, so the row stayed OK while the code no longer used
    # the endpoint. A marker that a comment can satisfy does not measure the
    # behaviour it names - the same failure class as the checks that flagged
    # their own explanatory comments earlier in this work.
    [pscustomobject]@{ Component = 'staleness marker';          Needs = 'running version compared to the pin (7e)'; Any = @('$versionUrl = "http://localhost:$frontPort/version"') }
)

# Collect the report and emit it in ONE write. Mixing Write-Output with a
# Format-Table pipeline interleaves sections out of order, because the table
# is serialised on a different stream than the strings.
$report = [System.Collections.Generic.List[string]]::new()
$report.Add('=== AIPC update coverage: does `install.ps1 -Update` reach it? ===')
$report.Add('')
$report.Add(("  audit of: {0}" -f $installer))
$report.Add('')

$results = foreach ($c in $checks) {
    $isNoop = ($c.Any.Count -eq 1 -and $c.Any[0] -eq '__noop__')
    $hit = if ($isNoop) { $null } else { Test-Marker -Any $c.Any }
    [pscustomobject]@{
        Component = $c.Component
        Needs     = $c.Needs
        Verdict   = if ($isNoop -or $hit) { 'OK' } else { 'GAP' }
        Marker    = if ($isNoop) { '(no action needed)' } else { [string]$hit }
    }
}

$tableText = $results | Sort-Object @{E={$_.Verdict -eq 'GAP'}}, Component |
    Format-Table -AutoSize | Out-String -Width 140
$report.AddRange([string[]]($tableText -split "`r?`n"))

$gaps = @($results | Where-Object { $_.Verdict -eq 'GAP' })
$done = @($results | Where-Object { $_.Verdict -eq 'OK' })

$report.Add('=== Summary ===')
$report.Add(("  covered by -Update   : {0} of {1}" -f $done.Count, $results.Count))
$report.Add(("  still needing a human: {0}" -f $gaps.Count))
$report.Add('')

if ($gaps.Count -gt 0) {
    $report.Add('=== Remaining gaps (each is a reason a dev still logs in) ===')
    foreach ($g in $gaps) {
        $report.Add(("  {0,-28} needs {1}" -f $g.Component, $g.Needs))
    }
    $report.Add('')
}

if ($Explain) {
    $report.Add('=== Derivation (proof each verdict came from source, not a claim) ===')
    foreach ($r in $results) {
        $report.Add(("  {0,-28} {1,-4} <- {2}" -f $r.Component, $r.Verdict, $r.Marker))
    }
    $report.Add('')
}

$report | ForEach-Object { Write-Output $_ }

# Exit code carries the measurement so this can be used as a gate:
# 0 = fully unattended today, 1 = gaps remain. A non-zero exit is the answer,
# not a script failure.
exit ([int]($gaps.Count -gt 0))
