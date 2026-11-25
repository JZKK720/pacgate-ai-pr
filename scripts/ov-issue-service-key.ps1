# Issue (or rotate) the OpenViking SERVICE key and write it into the bundle .env.
#
# WHY THIS EXISTS
#
# OpenViking v0.5.x refuses its ROOT key on every tenant-scoped data API. Measured
# 2026-11-25 against v0.5.6: POSTing /mcp with the root key returns
#
#   -32001  "ROOT API keys cannot access tenant-scoped data APIs in api_key mode.
#            Use a user/admin API key for data access, or trusted mode for
#            upstream identity assertion."
#
# The allow-list is narrow (openviking/server/auth/plugins/api_key.py):
#   _API_KEY_ROOT_ALLOWED_PATHS   = {/api/v1/system/status, /api/v1/system/wait,
#                                    /api/v1/debug/health}
#   _API_KEY_ROOT_ALLOWED_PREFIXES = (/api/v1/admin, /api/v1/observer,
#                                     /api/v1/console, /api/v1/tasks)
#
# So on 0.5.x the root key can still ADMINISTER but cannot read or write memory.
# deer-flow attaches that key to every OpenViking MCP call, which means a root key
# on 0.5.x silently disables memory recall for the whole agent - no error the model
# can see, just empty results.
#
# The supported replacement is a per-account user key. It is a credential the SERVER
# issues (salted per account/user), so it cannot be derived from the root key and
# cannot be committed to the repo. This script issues it through the running
# container - the one surface the root key may still use - and persists it.
#
# Idempotent: prints the key already in .env when it still authenticates, and only
# calls the admin API when it does not.
#
# Usage:
#   pwsh -File scripts/ov-issue-service-key.ps1
#   pwsh -File scripts/ov-issue-service-key.ps1 -Rotate     # force a new key
#   pwsh -File scripts/ov-issue-service-key.ps1 -WhatIf     # show, do not write
#
# Exit codes: 0 = a working service key is in .env, 1 = failed, 2 = cannot check.

[CmdletBinding()]
param(
    [string]$Container = 'openviking',
    [string]$EnvFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.env'),
    [string]$AccountId = 'default',
    [string]$UserId = 'pacgate-service',
    [switch]$Rotate,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function CannotCheck($m) { Write-Host "CANNOT CHECK: $m" -ForegroundColor Yellow; exit 2 }

# ── preconditions ───────────────────────────────────────────────────────────
$running = & docker ps --filter "name=^$Container$" --format '{{.Names}}' 2>$null
if (-not $running) { CannotCheck "container '$Container' is not running" }

if (-not (Test-Path $EnvFile)) { Fail "no .env at $EnvFile" }

$envText = Get-Content $EnvFile -Raw
if ($envText -notmatch '(?m)^\s*OPENVIKING_ROOT_API_KEY\s*=\s*(\S+)') {
    Fail "OPENVIKING_ROOT_API_KEY is not set in $EnvFile (the admin API needs it)"
}
$rootKey = $Matches[1]

# ── does the existing service key still work? ──────────────────────────────
function Test-ServiceKey([string]$key) {
    if (-not $key) { return $false }
    # initialize is the cheapest call that proves the credential: the auth plugin
    # rejects a bad/root key before any tool runs.
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ov-key-check","version":"1"}}}'
    $out = & docker exec $Container sh -c "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:1933/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'X-API-Key: $key' -d '$body'" 2>$null
    return ("$out".Trim() -eq '200')
}

$existing = if ($envText -match '(?m)^\s*OPENVIKING_SERVICE_KEY\s*=\s*(\S+)') { $Matches[1] } else { '' }

if (-not $Rotate -and (Test-ServiceKey $existing)) {
    Write-Host "[OK] OPENVIKING_SERVICE_KEY in .env already authenticates on $Container" -ForegroundColor Green
    exit 0
}

# ── issue (or rotate) through the admin API, inside the container ──────────
# Run curl INSIDE the container: it works before the port is published to the host,
# and the root key never leaves the compose network.
$issued = $null

if (-not $Rotate) {
    $createBody = '{"user_id":"' + $UserId + '","role":"admin"}'
    $raw = & docker exec $Container sh -c "curl -s -X POST http://127.0.0.1:1933/api/v1/admin/accounts/$AccountId/users -H 'Content-Type: application/json' -H 'X-API-Key: $rootKey' -d '$createBody'" 2>$null
    if ($raw) {
        try {
            $obj = $raw | ConvertFrom-Json
            if ($obj.result.user_key) { $issued = $obj.result.user_key }
            elseif ($obj.error) { Write-Host "  create: $($obj.error.message)" -ForegroundColor DarkGray }
        } catch { Write-Host "  create returned non-JSON: $raw" -ForegroundColor DarkGray }
    }
}

if (-not $issued) {
    # Already exists (or we were asked to rotate): regenerate. The old key is
    # invalidated immediately, which is why the result is written to .env before
    # anything else uses it.
    $raw2 = & docker exec $Container sh -c "curl -s -X POST http://127.0.0.1:1933/api/v1/admin/accounts/$AccountId/users/$UserId/key -H 'Content-Type: application/json' -H 'X-API-Key: $rootKey'" 2>$null
    if ($raw2) {
        try {
            $obj2 = $raw2 | ConvertFrom-Json
            if ($obj2.result.user_key) { $issued = $obj2.result.user_key }
            elseif ($obj2.error) { Write-Host "  rotate: $($obj2.error.message)" -ForegroundColor DarkGray }
        } catch { Write-Host "  rotate returned non-JSON: $raw2" -ForegroundColor DarkGray }
    }
}

if (-not $issued) {
    Fail "the admin API did not return a user_key. Is $Container v0.5.x or newer? On 0.4.16 the root key already works and no service key is needed."
}

# Prove the new credential before persisting it: writing a key that does not work
# would trade a loud failure for a silent one.
if (-not (Test-ServiceKey $issued)) {
    Fail "the issued key does not authenticate against /mcp - not writing it to .env"
}

if ($WhatIf) {
    Write-Host "[WhatIf] would write OPENVIKING_SERVICE_KEY=$($issued.Substring(0,12))... to $EnvFile" -ForegroundColor Yellow
    exit 0
}

$line = "OPENVIKING_SERVICE_KEY=$issued"
if ($envText -match '(?m)^\s*OPENVIKING_SERVICE_KEY\s*=') {
    $envText = [regex]::Replace($envText, '(?m)^\s*OPENVIKING_SERVICE_KEY\s*=.*$', $line.Replace('$', '$$$$'))
} else {
    $envText = $envText.TrimEnd() + "`r`n" + $line + "`r`n"
}
[System.IO.File]::WriteAllText($EnvFile, $envText, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[OK] Issued the OpenViking service key for account '$AccountId' / user '$UserId'" -ForegroundColor Green
Write-Host "     Written to $EnvFile as OPENVIKING_SERVICE_KEY." -ForegroundColor Gray
Write-Host "     Re-render the deer-flow extensions config so the MCP header picks it up:" -ForegroundColor Yellow
Write-Host "       pwsh -File deploy/client-bundle/install.ps1   (or re-run -Update)" -ForegroundColor Yellow
Write-Host "     Then restart deer-flow so the new config is mounted:" -ForegroundColor Yellow
Write-Host "       docker compose -f deploy/client-bundle/compose.bundle.yaml up -d --force-recreate deer-flow" -ForegroundColor Yellow
exit 0
