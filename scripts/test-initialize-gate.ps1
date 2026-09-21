# Prove the /initialize setup-token gate discriminates.
#
# WHY THIS EXISTS
#   POST /api/v1/auth/initialize creates the FIRST admin and is necessarily
#   public - it must work before any account exists. Its only upstream guard is
#   `admin_count > 0`, which is sufficient on an already-initialised box (409)
#   but NOT on a freshly installed AIPC: whoever reaches the URL first becomes
#   admin. Gating /register did not close this; they are separate endpoints.
#
#   deer-flow-auth.py now supports an OPT-IN token gate driven by
#   PACGATE_SETUP_TOKEN. This script proves it actually discriminates.
#
# WHY IT RUNS IN A THROWAWAY CONTAINER
#   The live deer-flow container cannot have env injected at runtime, and the
#   live DB already has an admin (so a successful create is unreachable).
#   A separate container from the same image can be started with the env var set
#   and has its own empty deerflow.db, so the happy path reaches 201 and actually
#   creates an admin - in a database discarded with the container.
#
# TWO TRAPS THIS SCRIPT ENCODES (both cost a wasted cycle)
#   1. THE PATCHES ARE NOT IN THE IMAGE. compose bind-mounts them at runtime, so
#      a bare `docker run` executes UNPATCHED upstream auth.py and the gate
#      cannot fire - it returns 201 with no token and looks like a broken gate.
#      The -v paths below MUST mirror deploy/client-bundle/compose.prod.yaml.
#   2. THE GATEWAY LISTENS ON 8001, NOT 8080 (pacgate-api uses 8080). Probing
#      8080 returns nothing and looks like a failed startup.
#
# Usage:  pwsh -NoProfile -File scripts/test-initialize-gate.ps1
#
# Exit codes: 0 = all cases behave as expected; 1 = a case diverged.

[CmdletBinding()]
param(
    [string]$Image  = 'ghcr.io/jzkk720/deer-flow-pacgate:0.1.17',
    [string]$Network = 'client-bundle_default',
    [string]$DbFrom = 'pacgate-api',
    [string]$Token  = 'test-gate-token-abc123'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:pass = 0
$script:fail = 0
function Check($name, $ok, $detail) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red; if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray } }
}

# ── preconditions ────────────────────────────────────────────────────────
Write-Host '=== 0. preconditions ===' -ForegroundColor Cyan
$dbUrl = (docker exec $DbFrom printenv DATABASE_URL 2>&1 | Out-String).Trim()
if (-not $dbUrl -or $dbUrl -match 'Error|No such') {
    Check 'DATABASE_URL readable from the stack' $false "docker exec $DbFrom printenv DATABASE_URL failed - is the stack up?"
    exit 1
}
Check 'DATABASE_URL readable from the stack' $true
Write-Host '       (value deliberately not printed)' -ForegroundColor DarkGray

# ── start the throwaway container ────────────────────────────────────────
Write-Host ''
Write-Host '=== 1. start a throwaway deer-flow with the gate armed ===' -ForegroundColor Cyan
$ctr = "initgate-$([guid]::NewGuid().ToString('n').Substring(0,6))"
$repo = (Get-Location).Path
$bodyDir = Join-Path $env:TEMP 'initgate-body'
New-Item -ItemType Directory -Force -Path $bodyDir | Out-Null

function Cleanup { docker rm -f $ctr 2>&1 | Out-Null }
trap { Cleanup }

& docker run -d --name $ctr --network $Network `
    -e "DATABASE_URL=$dbUrl" `
    -e 'PACGATE_JWT_SECRET=test-secret-not-real' `
    -e "PACGATE_SETUP_TOKEN=$Token" `
    -v "${repo}/deploy/client-bundle/patches/deer-flow-auth.py:/app/backend/app/gateway/routers/auth.py:ro" `
    -v "${repo}/deploy/client-bundle/patches/deer-flow-auth-errors.py:/app/backend/app/gateway/auth/errors.py:ro" `
    $Image 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) { Check "container starts from $Image" $false 'docker run failed'; Cleanup; exit 1 }
Check 'container starts with both auth patches mounted' $true

$ready = $false
for ($i = 0; $i -lt 45; $i++) {
    $code = (& docker run --rm --network $Network curlimages/curl:latest -s -o /dev/null -w '%{http_code}' `
            --retry 1 --retry-connrefused --max-time 3 "http://${ctr}:8001/api/v1/auth/setup-status" 2>&1 | Out-String).Trim()
    if ($code -match '200') { $ready = $true; Write-Host "       ready after $($i + 1)s" -ForegroundColor DarkGray; break }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    Check 'gateway became ready' $false 'no 200 from :8001/setup-status within 45s'
    (docker logs $ctr 2>&1 | Select-Object -Last 10) | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
    Cleanup; exit 1
}
Check 'gateway became ready' $true

# ── the gate must discriminate ───────────────────────────────────────────
Write-Host ''
Write-Host '=== 2. the token gate must discriminate ===' -ForegroundColor Cyan

function Invoke-Init {
    param([string]$BodyToken, [string]$HeaderToken)
    $payload = @{ email = 'gateprobe@example.com'; password = 'Zq7#vault-probe-9931' }
    # Note the domain: email-validator REJECTS RFC 2606 reserved TLDs
    # (.invalid / .test / .localhost) with 422 "special-use or reserved name".
    if ($BodyToken) { $payload['setup_token'] = $BodyToken }
    ($payload | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $bodyDir 'body.json') -NoNewline

    $hdrArgs = @()
    if ($HeaderToken) { $hdrArgs = @('-H', "X-Pacgate-Setup-Token: $HeaderToken") }

    # '@file' MUST be quoted - a bare @/b/body.json is parsed by PowerShell as a
    # SPLATTING token and fails with "unrecognized token".
    # Run curl in the SIDECAR, not inside deer-flow: that image has no curl.
    $out = (& docker run --rm --network $Network -v "${bodyDir}:/b:ro" curlimages/curl:latest `
            -s -o - -w "`nHTTP_STATUS:%{http_code}" -X POST `
            "http://${ctr}:8001/api/v1/auth/initialize" `
            -H 'Content-Type: application/json' @hdrArgs --data '@/b/body.json' 2>&1 | Out-String)
    if ($out -match 'HTTP_STATUS:(\d+)') { return @{ code = $Matches[1]; body = $out } }
    return @{ code = 'none'; body = $out }
}

# Order matters: the CORRECT-token case creates the admin, so the run that
# follows it correctly sees 409 (already initialised) rather than 201.
$cases = @(
    @{ name = 'no token at all';       body = $null;    hdr = $null;    expect = '403'; why = 'gate must refuse an anonymous caller' }
    @{ name = 'WRONG token in body';   body = 'nope';   hdr = $null;    expect = '403'; why = 'a bad token must not pass' }
    @{ name = 'CORRECT token in body'; body = $Token;   hdr = $null;    expect = '201'; why = 'happy path: first admin IS still creatable' }
    @{ name = 'CORRECT token via header'; body = $null; hdr = $Token;   expect = '409'; why = 'header path accepted the token; admin already exists' }
)

foreach ($c in $cases) {
    $r = Invoke-Init -BodyToken $c.body -HeaderToken $c.hdr
    Check "$($c.name) -> $($c.expect)" ($r.code -eq $c.expect) "$($c.why); got $($r.code). $($r.body.Trim())"
}

# ── the token must NOT leak ──────────────────────────────────────────────
Write-Host ''
Write-Host '=== 3. the token must never be exposed ===' -ForegroundColor Cyan
$ss = (& docker run --rm --network $Network curlimages/curl:latest -s "http://${ctr}:8001/api/v1/auth/setup-status" 2>&1 | Out-String)
Check '/setup-status does not return the token' (-not ($ss -match [regex]::Escape($Token))) 'the anonymous caller this gate excludes could read it'

# ── result ───────────────────────────────────────────────────────────────
Cleanup
Write-Host ''
Write-Host "  passed: $script:pass   failed: $script:fail"
if ($script:fail -gt 0) {
    Write-Host 'RESULT: the /initialize gate does NOT discriminate - do not ship this.' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: the setup-token gate refuses anonymous/wrong callers and still allows first-boot creation.' -ForegroundColor Green
exit 0
