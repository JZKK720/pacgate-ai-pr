# Guard: the bind-mounted adapter files must match the adapter package.
#
# WHY THIS EXISTS
#
# deploy/client-bundle/compose.*.yaml bind-mounts individual files from
# deploy/client-bundle/patches/ over the adapter package that is pip-installed
# into the deer-flow image. That is deliberate (ship a fix without a rebuild),
# but it means the patches/ copies are hand-synced with
# pacgate-adapters/python/pacgate_deerflow_adapter/ and NOTHING checked that.
#
# Measured 2026-11-24: copying the package over the patches/ directory during
# the deer-flow 2.2.0 adapter work removed 102 and 109 lines (the shape
# normalisation and the 401 re-login) from the two live files, and no gate
# objected. The stack would have booted with an adapter that silently lost the
# memory-card fix and the token-refresh fix.
#
# WHAT IS ASSERTED
#   A1  Every bind-mounted pacgate_deerflow_adapter/*.py in either compose lane
#       exists on disk (a missing source makes Docker create a directory).
#   A2  Every bind-mounted adapter file is byte-identical to its counterpart in
#       pacgate-adapters/python/pacgate_deerflow_adapter/, OR is listed in the
#       explicit allow-list of files that intentionally differ.
#   A3  The set of mounted adapter modules is the same in both lanes.
#
# Exit codes: 0 pass, 1 defect, 2 cannot check.

[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$script:failures = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }

# Files whose patches/ copy intentionally differs from the package tree.
# Each entry MUST carry the reason and the date it was last checked.
$allowedDivergence = @{
    # client.py: patches/ carries the 401 re-login wrapper; the package copy is
    # the same file as of 2026-11-24, kept identical. Listed only if they ever
    # diverge deliberately; empty today.
}

Write-Host '=== adapter bind-mount parity ===' -ForegroundColor Cyan

$lanes = @('compose.prod.yaml', 'compose.bundle.yaml') | ForEach-Object {
    Join-Path $RepoRoot "deploy/client-bundle/$_"
}
$pkgDir = Join-Path $RepoRoot 'pacgate-adapters/python/pacgate_deerflow_adapter'
$patchDir = Join-Path $RepoRoot 'deploy/client-bundle/patches'

foreach ($lane in $lanes) { if (-not (Test-Path $lane)) { Write-Host "  exit 2 - missing $lane" -ForegroundColor Yellow; exit 2 } }
if (-not (Test-Path $pkgDir)) { Write-Host "  exit 2 - missing $pkgDir" -ForegroundColor Yellow; exit 2 }

$mountRe = 'pacgate_deerflow_adapter/([A-Za-z0-9_]+)\.py:'
$perLane = @{}

foreach ($lane in $lanes) {
    $laneName = Split-Path $lane -Leaf
    $mounts = @{}
    foreach ($line in Get-Content -LiteralPath $lane -Encoding utf8) {
        $t = $line.Trim()
        if ($t.StartsWith('#')) { continue }
        if ($t -match '^-\s+(\./patches/[^:]+):') {
            $rel = $Matches[1] -replace '^\./patches/', ''
            $leaf = [System.IO.Path]::GetFileName($rel)
            if ($leaf -match '^pacgate-adapter-(.+)\.py$') {
                $module = ($Matches[1] -replace '-', '_')
                $mounts[$module] = Join-Path $patchDir $rel
            }
        }
    }
    $perLane[$laneName] = $mounts
    if ($mounts.Count -eq 0) { Write-Host '  exit 2 - no adapter mounts found; is the compose layout unchanged?' -ForegroundColor Yellow; exit 2 }

    foreach ($module in $mounts.Keys | Sort-Object) {
        $patchFile = $mounts[$module]
        $pkgFile = Join-Path $pkgDir "$module.py"
        if (-not (Test-Path -LiteralPath $patchFile)) {
            Fail "$laneName mounts $module but $patchFile does not exist (Docker would create a directory)"
            continue
        }
        if (-not (Test-Path -LiteralPath $pkgFile)) {
            Fail "$laneName mounts $module.py but there is no package counterpart at $pkgFile"
            continue
        }
        $a = (Get-FileHash -Algorithm SHA256 -LiteralPath $patchFile).Hash
        $b = (Get-FileHash -Algorithm SHA256 -LiteralPath $pkgFile).Hash
        if ($a -eq $b) {
            Pass "$laneName $module.py matches the package source"
        } elseif ($allowedDivergence.ContainsKey("$module.py")) {
            Write-Host "  [WARN] $laneName $module.py differs from the package (allowed: $($allowedDivergence["$module.py"]))" -ForegroundColor Yellow
        } else {
            Fail "$laneName $module.py differs from pacgate-adapters/python/pacgate_deerflow_adapter/$module.py - the image and the package have drifted"
        }
    }
}

$a = ($perLane['compose.prod.yaml'].Keys | Sort-Object) -join ','
$b = ($perLane['compose.bundle.yaml'].Keys | Sort-Object) -join ','
if ($a -eq $b) { Pass "both lanes mount the same adapter modules ($a)" }
else { Fail "lane mount sets differ: prod=[$a] bundle=[$b]" }

Write-Host ''
if ($script:failures -gt 0) { Write-Host "FAILED: $($script:failures) adapter parity defect(s)" -ForegroundColor Red; exit 1 }
Write-Host 'PASSED: bind-mounted adapters match the package' -ForegroundColor Green
exit 0
