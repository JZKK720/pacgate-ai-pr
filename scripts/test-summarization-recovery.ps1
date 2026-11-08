# Gate wrapper: the summarization recovery patch keeps a folded range recoverable.
#
# Thin on purpose. The assertions live in scripts/test_summarization_recovery.py
# because they need real LangChain message objects and a real
# SummarizationMiddleware instance to be meaningful - a PowerShell re-implementation
# of that would test the test, not the patch.
#
# WHY THIS GATE EXISTS AT ALL. The patch changes a THIRD-PARTY module inside the
# container venv. Nothing else in this repo would notice if a `pip install` moved
# the file, if the mount silently stopped resolving, or if an upstream refactor
# made _build_new_messages unreachable - summarization would keep working, just
# without the recovery index, and the loss would be invisible until a long
# document run re-read the same file for the 100th time.
#
# Exit codes, matching the rest of this repo:
#   0 = all assertions passed
#   1 = a real failure
#   2 = CANNOT CHECK (no python, or the container is down)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$py = Join-Path $root 'scripts/test_summarization_recovery.py'

if (-not (Test-Path $py)) {
    Write-Host "CANNOT CHECK: $py not found" -ForegroundColor Yellow
    exit 2
}

$python = $null
foreach ($candidate in @('python', 'python3', 'py')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $python = $candidate; break }
}
if (-not $python) {
    Write-Host 'CANNOT CHECK: no python on PATH (the gate drives the container venv through it)' -ForegroundColor Yellow
    exit 2
}

& $python $py
exit $LASTEXITCODE
