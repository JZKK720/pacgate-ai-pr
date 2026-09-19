# Create (or refresh) the 'ocr-extractor' agent in deer-flow.
# Pattern: deploy/sanitizer-agent/provision.ps1. Idempotent - an existing
# agent is updated, not duplicated.
#
# PS 5.1 traps encoded here (all found live, see the sanitizer agent):
# 1. Non-BOM files parse as ANSI -> build the ZH description from
#    codepoints so this file stays ASCII-only.
# 2. .Count on a single Where-Object result is null -> wrap in @().
# 3. A string -Body is sent as ANSI -> send UTF-8 byte arrays.
# Usage:
#   powershell -File deploy/ocr-agent/provision.ps1 [-DeerFlowUrl http://localhost:8089] `
#     [-Email <admin>] [-Password <secret>]
param(
    [string]$DeerFlowUrl = "http://127.0.0.1:8089",
    [string]$Email = $env:DEER_FLOW_EMAIL,
    [string]$Password = $env:DEER_FLOW_PASSWORD
)
$ErrorActionPreference = 'Stop'

if (-not $Email -or -not $Password) {
    Write-Error 'deer-flow credentials required: pass -Email/-Password or set DEER_FLOW_EMAIL/DEER_FLOW_PASSWORD.'
}

$loginBody = "username=$([uri]::EscapeDataString($Email))&password=$([uri]::EscapeDataString($Password))"
$login = Invoke-WebRequest -Uri "$DeerFlowUrl/api/v1/auth/login/local" -Method Post `
    -Body $loginBody -ContentType 'application/x-www-form-urlencoded' `
    -TimeoutSec 15 -SessionVariable session -UseBasicParsing
if ($login.StatusCode -ne 200) {
    Write-Error "deer-flow login failed (HTTP $($login.StatusCode))."
}

# CSRF double-submit: echo the csrf_token cookie on every state-changing call.
$csrf = $session.Cookies.GetCookies($DeerFlowUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1
$csrfHeaders = @{ }
if ($csrf) { $csrfHeaders['X-CSRF-Token'] = $csrf.Value }

$soul = Get-Content -Raw (Join-Path $PSScriptRoot 'SOUL.md')
# Single bilingual description (deer-flow has one description field, no
# per-locale split): EN line + ZH line. ZH built from codepoints (ASCII-only file).
$descEn = 'OCR extractor: runs PaddleOCR on stored documents (PDF/scan/image) and returns text + coordinates. Plain perception - no redaction.'
$descZh = -join [char[]](0x004F,0x0043,0x0052,0x63D0,0x53D6,0x5668,0xFF1A,0x5BF9,0x5DF2,0x5B58,0x50A8,0x6587,0x6863,0xFF08,0x0050,0x0044,0x0046,0x002F,0x626B,0x63CF,0x4EF6,0x002F,0x56FE,0x7247,0xFF09,0x6267,0x884C,0x0050,0x0061,0x0064,0x0064,0x006C,0x0065,0x004F,0x0043,0x0052,0x63D0,0x53D6,0xFF0C,0x8FD4,0x56DE,0x6587,0x672C,0x4E0E,0x5750,0x6807,0x3002,0x7EAF,0x611F,0x77E5,0xFF0C,0x4E0D,0x8131,0x654F,0x3002)
$description = "$descEn`n$descZh"

$body = @{
    name        = 'ocr-extractor'
    description = $description
    soul        = [string]$soul
} | ConvertTo-Json -Depth 4

$existing = Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -WebSession $session -Headers $csrfHeaders -TimeoutSec 10 -ErrorAction SilentlyContinue
$hasAgent = $false
if ($existing -and $existing.agents) {
    # @() wrapper: PS 5.1 .Count on a single PSCustomObject is null.
    $matches = @($existing.agents | Where-Object { $_.name -eq 'ocr-extractor' })
    $hasAgent = $matches.Count -gt 0
}

# PS 5.1 sends a string -Body as ANSI; byte arrays go out as UTF-8 verbatim.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
if ($hasAgent) {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents/ocr-extractor" -Method Put -WebSession $session -Headers $csrfHeaders -Body $bodyBytes -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: ocr-extractor agent updated'
} else {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -Method Post -WebSession $session -Headers $csrfHeaders -Body $bodyBytes -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: ocr-extractor agent created'
}