# Create (or refresh) the 'sanitizer' agent in deer-flow.
# Idempotent: an existing sanitizer agent is updated, not duplicated.
# The deer-flow agents API requires an authenticated session (Better-Auth
# JWT, POST /api/v1/auth/login/local). This script logs in with the
# DEER_FLOW_EMAIL / DEER_FLOW_PASSWORD env vars (or -Email/-Password params)
# and carries the session cookie through the list/create/update calls.
# Usage:
#   powershell -File deploy/sanitizer-agent/provision.ps1 [-DeerFlowUrl http://localhost:8089] `
#     [-Email pacgate.ai01@outlook.com] [-Password <secret>]
# Credentials may also come from env: DEER_FLOW_EMAIL / DEER_FLOW_PASSWORD.
param(
    [string]$DeerFlowUrl = "http://127.0.0.1:8089",
    [string]$Email = $env:DEER_FLOW_EMAIL,
    [string]$Password = $env:DEER_FLOW_PASSWORD
)
$ErrorActionPreference = 'Stop'

if (-not $Email -or -not $Password) {
    Write-Error 'deer-flow credentials required: pass -Email/-Password or set DEER_FLOW_EMAIL/DEER_FLOW_PASSWORD.'
}

# Login (OAuth2 form style) and keep the session for the agent calls.
# -UseBasicParsing: PS 5.1 otherwise prompts interactively (IE script parsing).
# The session object is passed with -WebSession on every call: PS 5.1 silently
# DROPS a manually-set Cookie header (restricted header), so a hand-built
# "Cookie:" header would authenticate nothing - the WebSession is the only
# reliable cookie carrier on this runtime.
$loginBody = "username=$([uri]::EscapeDataString($Email))&password=$([uri]::EscapeDataString($Password))"
$login = Invoke-WebRequest -Uri "$DeerFlowUrl/api/v1/auth/login/local" -Method Post `
    -Body $loginBody -ContentType 'application/x-www-form-urlencoded' `
    -TimeoutSec 15 -SessionVariable session -UseBasicParsing
if ($login.StatusCode -ne 200) {
    Write-Error "deer-flow login failed (HTTP $($login.StatusCode))."
}

if ($login.StatusCode -ne 200) {
    Write-Error "deer-flow login failed (HTTP $($login.StatusCode))."
}

# CSRF double-submit: the login response sets a csrf_token cookie; every
# state-changing call (POST/PUT) must echo it back in the X-CSRF-Token header
# or the gateway answers 403 "CSRF token missing".
$csrf = $session.Cookies.GetCookies($DeerFlowUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1
$csrfHeaders = @{ }
if ($csrf) { $csrfHeaders['X-CSRF-Token'] = $csrf.Value }

$soul = Get-Content -Raw (Join-Path $PSScriptRoot 'SOUL.md')
$description = 'Client-identity sanitizer: redacts party/project identifiers before cloud analysis. Review surface only - the mapping stays sealed.'

$body = @{
    name        = 'sanitizer'
    description = $description
    soul        = $soul
} | ConvertTo-Json -Depth 4

# deer-flow's agent create returns 400 when the name exists; use update then.
$existing = Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -WebSession $session -Headers $csrfHeaders -TimeoutSec 10 -ErrorAction SilentlyContinue
$hasSanitizer = $false
if ($existing -and $existing.agents) {
    $hasSanitizer = ($existing.agents | Where-Object { $_.name -eq 'sanitizer' }).Count -gt 0
}

if ($hasSanitizer) {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents/sanitizer" -Method Put -WebSession $session -Headers $csrfHeaders -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent updated'
} else {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -Method Post -WebSession $session -Headers $csrfHeaders -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent created'
}
