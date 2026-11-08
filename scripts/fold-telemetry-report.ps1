# Measurement wrapper: fold telemetry + re-read ratio.
#
# Thin on purpose. The maths lives in scripts/fold_telemetry_report.py, which needs
# to parse JSONL and compute ratios - a PowerShell re-implementation would test the
# test, not the sensor.
#
# WHY THIS IS A MEASUREMENT AND NOT A GATE. The context-pressure hint is advisory
# text, so it cannot be asserted the way a clamp can. What CAN be asserted is that
# the SENSOR works: every summarization pass writes a row, and the row carries the
# pressure plus a re-read signal. Whether the hint then changed model behaviour is
# read per run from those rows - never against a fixed threshold, because
# retouch_ratio is structural on this stack (the killed run on bcb69ff8 made 111
# calls over 15 distinct payloads, ratio 7.4, and was NOT thrashing).
#
# Exit codes, matching the rest of this repo:
#   0 = telemetry read successfully
#   1 = the reader itself broke (a real defect in the tooling)
#   2 = CANNOT CHECK - no fold recorded yet. This is the NORMAL state on a quiet
#       box, because the file fills on the first summarization pass, not on
#       install. Exit 2 must never be read as a pass OR as a failure.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root 'scripts/fold_telemetry_report.py'

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
