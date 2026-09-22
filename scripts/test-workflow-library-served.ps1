# Assert the firm's legal workflow LIBRARY is actually served, not the built-ins.
#
# WHY THIS EXISTS
#
# The 15 workflow YAMLs were bind-mounted into `deer-flow` while `pacgate-api` -
# the service that owns GET /api/workflows - had no mount and no WORKFLOWS_DIR.
# The API therefore fell back to its 10 built-in Rust definitions and silently
# served a different, smaller, generic set. Nothing errored. A client opening the
# workflow list saw the wrong data.
#
# See deploy/DEFECT-workflow-mount-wrong-service.md.
#
# The reason a guard is REQUIRED rather than optional: the failure is invisible
# from the outside. A missing mount and a missing env var both produce a
# well-formed 200 response with plausible content. Only a count (or the language
# of the titles) distinguishes the library from the fallback.
#
# THE DISCRIMINATOR
#
# Built-ins are 10 English workflows ("Contract Review", "Due Diligence
# Review"). The library is ~222 and its titles are Chinese. So asserting a count
# well above 10 catches BOTH faults - the wrong service and the missing variable -
# without needing to inspect compose, which would test the config rather than the
# outcome.
#
# Usage:
#   pwsh -File scripts/test-workflow-library-served.ps1
#   pwsh -File scripts/test-workflow-library-served.ps1 -BaseUrl http://localhost:8089/pacgate
#
# Exit codes: 0 = library served, 1 = only the built-ins (the defect), 2 = could
# not check (unreachable / unauth) - never reported as a pass.

[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8089/pacgate',
    [string]$EnvFile = '',
    # 10 built-ins is the failure state; require clearly more than that.
    [int]$MinimumWorkflows = 50
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }

Write-Host '=== workflow library is served ===' -ForegroundColor Cyan
Write-Host "  base: $BaseUrl"

if (-not (Test-Path $EnvFile)) {
    Write-Host "  .env not found: $EnvFile" -ForegroundColor Red
    Write-Host 'RESULT: ERROR - cannot authenticate, so cannot check.' -ForegroundColor Red
    exit 2
}

# Read credentials without echoing them (repo rule: never print a secret).
$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) {
    Write-Host 'RESULT: ERROR - credentials missing from .env.' -ForegroundColor Red
    exit 2
}

$body = @{ email = $email; password = $password } | ConvertTo-Json -Compress
$token = $null
foreach ($p in @("$BaseUrl/api/auth/login", "$BaseUrl/auth/login")) {
    try {
        $login = Invoke-RestMethod $p -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
        $token = $login.token
        break
    } catch { }
}
if (-not $token) {
    Write-Host 'RESULT: ERROR - login failed; the stack may be down.' -ForegroundColor Red
    Write-Host 'Not reported as a pass: an unreachable stack is not a served library.' -ForegroundColor Yellow
    exit 2
}

$hdr = @{ Authorization = "Bearer $token" }

$workflows = $null
try {
    $workflows = Invoke-RestMethod "$BaseUrl/api/workflows" -Headers $hdr -TimeoutSec 25
} catch {
    Write-Host "RESULT: ERROR - /api/workflows failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

$count = @($workflows).Count
Write-Host ''
Write-Host "  workflows served: $count  (built-ins alone = 10; library ~222)"

# THE ASSERTION. Anything at or below the built-in count means WORKFLOWS_DIR is
# unset or the mount is missing - the exact defect this guards.
if ($count -le 10) {
    Fail "only $count workflows served - this is the built-in fallback, not the library"
    Write-Host ''
    Write-Host '  This means one of:' -ForegroundColor Yellow
    Write-Host '    - WORKFLOWS_DIR is not set on pacgate-api, or' -ForegroundColor Yellow
    Write-Host '    - ./workflows is not mounted into pacgate-api.' -ForegroundColor Yellow
    Write-Host '  See deploy/DEFECT-workflow-mount-wrong-service.md.' -ForegroundColor Yellow
    Write-Host 'RESULT: FAIL - the legal workflow library is NOT being served.' -ForegroundColor Red
    exit 1
}

Pass "served $count workflows (above the 10 built-ins)"

if ($count -lt $MinimumWorkflows) {
    Fail "only $count served; expected at least $MinimumWorkflows - the library may be partially mounted or a file failed to parse"
    Write-Host 'RESULT: FAIL - library looks incomplete.' -ForegroundColor Red
    exit 1
}
Pass "at least $MinimumWorkflows served"

# Coverage sanity: the library is domain-specific and multi-area, so a healthy
# library has many categories. A single-category response means one file loaded
# and the rest silently failed.
$cats = @($workflows | ForEach-Object { $_.category } | Sort-Object -Unique)
Pass "$($cats.Count) distinct categories"
if ($cats.Count -lt 5) {
    Fail "only $($cats.Count) categories - files may have failed to parse"
    Write-Host 'RESULT: FAIL - library looks truncated.' -ForegroundColor Red
    exit 1
}
Write-Host ("  categories: {0}" -f (($cats | Select-Object -First 10) -join ', '))

# The strongest single discriminator, and it is cheap: the library is the firm's
# Chinese legal content while the built-ins are English. If every title is ASCII,
# we are almost certainly looking at the fallback with a count that slipped past
# the threshold. Reported as info rather than a hard failure, so a future
# English-language deployment does not get a false red - but it IS printed,
# because a silent language flip is exactly the kind of drift worth seeing.
$nonAscii = @($workflows | Where-Object { $_.name -match '[^\x00-\x7F]' }).Count
Write-Host ("  titles with non-ASCII characters: {0} of {1}" -f $nonAscii, $count)
if ($nonAscii -eq 0 -and $count -gt 10) {
    Write-Host '  [NOTE] every title is ASCII - unusual for this firm library. Verify the' -ForegroundColor Yellow
    Write-Host '         content is the intended set and not a larger fallback.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "RESULT: the legal workflow library is served ($count workflows, $($cats.Count) categories)." -ForegroundColor Green
exit 0
