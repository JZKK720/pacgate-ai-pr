# Measurement wrapper: calibrate the context-pressure band from REAL history.
#
# Thin on purpose. The decoding and maths live in
# scripts/calibrate_context_band.py, which must pull LangGraph checkpoints through
# the container venv - a PowerShell re-implementation would test the test.
#
# WHY THIS IS A MEASUREMENT AND NOT A GATE. The band's correctness is a property of
# the WORKLOAD, not of the code. A box whose longest thread peaks at 17k tokens is
# healthy, and the correct output is "the band never fires, and that is right".
# Failing a suite because traffic is short would train people to lower the band to
# manufacture a green - which is the opposite of the point.
#
# MEASURED 2026-11-08, 15 busiest threads: peak tokens median 16,847 / max 24,910
# against a 36,000 trigger -> 0 of 15 reach it. Retouch ratio median 1.0, so the
# re-read loops this patch targets are not present on current traffic either.
#
# Exit codes, matching the rest of this repo:
#   0 = calibrated from real history
#   1 = the tool itself broke
#   2 = CANNOT CHECK - no checkpoint DB access; never read as a pass

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root 'scripts/calibrate_context_band.py'

if (-not (Test-Path $py)) {
    Write-Host "CANNOT CHECK: $py not found" -ForegroundColor Yellow
    exit 2
}

$python = $null
foreach ($candidate in @('python', 'python3', 'py')) {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) { $python = $candidate; break }
}
if (-not $python) {
    Write-Host 'CANNOT CHECK: no python on PATH' -ForegroundColor Yellow
    exit 2
}

& $python $py @args
exit $LASTEXITCODE
