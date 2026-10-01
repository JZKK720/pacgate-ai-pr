# Gates the pacgate-mcp 401-retry behaviour test, which nothing ran.
#
# WHY THIS GATE EXISTS: the same gap test-adapter-python.ps1 closed for the
# adapter layer. scripts/test-mcp-401-retry.py proves that pacgate-mcp recovers
# from pacgate-api's 24-hour JWT expiry, but a .py file registered in no suite
# passes only when a human types the command - there is no mechanism whose job
# is to notice if it breaks.
#
# That gap matters here specifically: the 401 retry is INVISIBLE until the
# 24-hour mark. A regression would not show up in any smoke test, in any
# deployment check, or on any freshly restarted machine - it would appear one
# day later, as every agent tool call failing. Nothing else in this repo covers
# it, so if this gate is absent the defect can silently return.
#
# SCOPE: the test stubs the MCP SDK (not installed on a dev box) and drives
# PacgateApi against a scripted httpx transport, so it needs neither pacgate-api
# nor Docker. It does need httpx.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. Cannot-check is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

Write-Host '=== pacgate-mcp 401-retry behaviour ===' -ForegroundColor Cyan

$test = 'scripts/test-mcp-401-retry.py'
if (-not (Test-Path $test)) {
    Write-Host "  exit 2 - $test not found; the suite moved and this gate is checking nothing" -ForegroundColor Yellow
    exit 2
}

# Discover an interpreter. Ordered: the repo venv first (it is the documented
# environment and is what carries httpx), then PATH.
$candidates = @('.venv/Scripts/python.exe')
foreach ($c in @('python', 'python3')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
}

$python = $null
foreach ($c in $candidates) {
    $resolved = if (Test-Path $c) { (Resolve-Path $c).Path } else { $null }
    if (-not $resolved) { continue }
    $ver = & $resolved -c "import sys; print(sys.version_info[0])" 2>$null
    if ($LASTEXITCODE -eq 0 -and "$ver".Trim() -eq '3') { $python = $resolved; break }
}

if (-not $python) {
    Write-Host '  exit 2 - no Python 3 interpreter found; cannot run the behaviour test' -ForegroundColor Yellow
    exit 2
}

# httpx is a real dependency of the test (it drives the transport). Its absence
# is an environment problem, not a code failure - exit 2, never a false green.
& $python -c "import httpx" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  exit 2 - httpx not importable in the discovered interpreter; cannot run the behaviour test' -ForegroundColor Yellow
    exit 2
}

& $python $test
$code = $LASTEXITCODE
if ($code -eq 0) {
    Write-Host '  PASS  401-retry behaviour verified' -ForegroundColor Green
} else {
    Write-Host "  FAIL  behaviour test exited $code" -ForegroundColor Red
}
exit $code
