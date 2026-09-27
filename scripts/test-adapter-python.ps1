# Gates the Python adapter layer, which nothing previously did.
#
# WHY THIS GATE EXISTS: the same gap test-rust-workspace.ps1 closed for Rust.
# Measured 2026-09-27: run-all-checks.ps1 registered 32 gates and NONE of them ran
# a Python test. So the 8 assertions in
# pacgate-adapters/python/tests/test_memory_revision.py - including the 409/422
# distinction, which is the whole point of the adapter's error handling - passed
# only when a human typed the command. There was no mechanism whose job was to
# notice if they broke.
#
# That matters more here than in most places, because the 409-vs-422 distinction
# was added precisely BECAUSE the two were previously collapsed and a caller
# could not tell "retry after reloading" from "never retry this content". A test
# that guards a distinction nobody automated is a distinction that erodes.
#
# SCOPE: unittest discovery over pacgate-adapters/python/tests. The suite is
# stdlib-only (unittest + unittest.mock, with deerflow stubbed via `types`), so
# the interpreter is discovered rather than pinned - requiring the repo venv
# would make this gate fail on a clean machine for no reason.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== python adapter tests ===' -ForegroundColor Cyan

$suiteDir = 'pacgate-adapters/python/tests'
if (-not (Test-Path $suiteDir)) {
    Write-Host "  exit 2 - $suiteDir not found; the adapter suite moved and this gate is checking nothing" -ForegroundColor Yellow
    exit 2
}

# Discover an interpreter that can actually run the suite. Ordered: the repo
# venv first (it is what the render/PDF tooling uses and is the documented
# environment), then PATH.
$candidates = @(
    '.venv/Scripts/python.exe'
    'pacgate-adapters/python/.venv/Scripts/python.exe'
)
foreach ($c in @('python', 'python3')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
}

$python = $null
foreach ($c in $candidates) {
    # Resolve BEFORE any Push-Location, and store the absolute path. A relative
    # candidate like '.venv/Scripts/python.exe' stops resolving once the working
    # directory moves into the suite folder.
    $resolved = if (Test-Path $c) { (Resolve-Path $c).Path } else { $null }
    if (-not $resolved) { continue }
    $ver = & $resolved -c "import sys; print(sys.version_info[0])" 2>$null
    if ($LASTEXITCODE -eq 0 -and "$ver".Trim() -eq '3') { $python = $resolved; break }
}

if (-not $python) {
    Write-Host '  exit 2 - no Python 3 interpreter found; cannot run the adapter suite' -ForegroundColor Yellow
    Write-Host '         (install Python 3, or create .venv, then re-run)' -ForegroundColor Yellow
    exit 2
}

# The adapter package is imported by path, because it is not installed. The test
# files already stub `deerflow` themselves via `types`, so only the adapter root
# needs to be on the path.
$adapterRoot = (Resolve-Path 'pacgate-adapters/python').Path
$env:PYTHONPATH = $adapterRoot

Push-Location $suiteDir
try {
    $out = & $python -m unittest discover -s . -v 2>&1 | Out-String
    $code = $LASTEXITCODE
}
finally {
    Pop-Location
    Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue
}

# Report the counts from the summary line, so a zero-test run is visible rather
# than silently green - the mirror of the vacuous-pass trap this codebase keeps
# hitting.
$ran = [regex]::Match($out, 'Ran (\d+) tests?')
$count = if ($ran.Success) { [int]$ran.Groups[1].Value } else { 0 }

if ($code -ne 0) {
    $out -split "`n" | Where-Object { $_ -match 'FAIL|ERROR|Traceback|AssertionError' } | Select-Object -First 12 | ForEach-Object { Write-Host "        $($_.Trim())" -ForegroundColor Gray }
    Fail "the adapter suite failed (exit $code)"
}
elseif ($count -eq 0) {
    Fail 'the adapter suite reported 0 tests - discovery found nothing, so this gate would pass vacuously'
}
else {
    Pass "all $count adapter tests pass (unittest discovery, $python)"
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) adapter check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the Python adapter suite is green' -ForegroundColor Green
exit 0
