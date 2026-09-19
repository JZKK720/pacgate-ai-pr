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
# The agents gallery card shows this single string in both UI locales -
# deer-flow's agent model has one description field and no per-locale split,
# so the string carries EN + ZH lines for bilingual parity. The ZH line is
# built from escaped codepoints so this file stays ASCII-only (PS 5.1 parses
# non-BOM files as ANSI and garbles non-ASCII literals).
$descEn = 'Client-identity sanitizer: redacts party/project identifiers before cloud analysis. Review surface only - the mapping stays sealed.'
$descZh = -join [char[]](0x5BA2,0x6237,0x8EAB,0x4EFD,0x8131,0x654F,0xFF1A,0x4E91,0x7AEF,0x5206,0x6790,0x524D,0x5BF9,0x5F53,0x4E8B,0x65B9,0x002F,0x9879,0x76EE,0x6807,0x8BC6,0x7B26,0x8131,0x654F,0x3002,0x4EC5,0x5BA1,0x67E5,0x754C,0x9762,0x0020,0x002D,0x0020,0x6620,0x5C04,0x5C01,0x5B58,0x5728,0x672C,0x673A,0x3002)
$description = "$descEn`n$descZh"

$body = @{
    name        = 'sanitizer'
    description = $description
    # [string] cast: PS 5.1's ConvertTo-Json can serialize a raw Get-Content
    # string as an object wrapper {"value": "..."} - the API requires a plain
    # string for `soul`.
    soul        = [string]$soul
} | ConvertTo-Json -Depth 4

# deer-flow's agent create returns 400/409 when the name exists; use update then.
$existing = Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -WebSession $session -Headers $csrfHeaders -TimeoutSec 10 -ErrorAction SilentlyContinue
$hasSanitizer = $false
if ($existing -and $existing.agents) {
    # @() wraps the Where-Object OUTPUT: on PS 5.1 a single PSCustomObject has
    # NO Count property (null), so the unwrapped form reads as "not present"
    # and the script wrongly POSTs into a 409. The array subexpression makes
    # .Count always numeric. (Found live: PS 5.1 child run POSTed into 409.)
    $matches = @($existing.agents | Where-Object { $_.name -eq 'sanitizer' })
    $hasSanitizer = $matches.Count -gt 0
}

if ($hasSanitizer) {
    # PS 5.1 sends a string -Body as ANSI (system codepage), which garbles the
    # ZH description. A byte array is passed through verbatim as UTF-8.
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents/sanitizer" -Method Put -WebSession $session -Headers $csrfHeaders -Body $bodyBytes -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent updated'
} else {
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -Method Post -WebSession $session -Headers $csrfHeaders -Body $bodyBytes -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent created'
}
