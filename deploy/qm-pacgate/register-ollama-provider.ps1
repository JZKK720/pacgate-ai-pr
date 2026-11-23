# Register the Ollama model lane with qm 0.1.18+ via its admin API.
#
# WHY THIS EXISTS
#
# qm passes the selected model id to the provider VERBATIM. With modelProvider=openai and
# OPENAI_BASE_URL pointing at Ollama, qm sends whatever id the org base model names straight
# to Ollama. Verified both ways against a live 0.1.18 stack:
#
#   gpt-5.6-sol               -> {"error":{"message":"model 'gpt-5.6-sol' not found",...}}
#   minimax-m3.1-flash:cloud  -> {"id":"chatcmpl-...", choices:[...], usage:{...}}
#
# In 0.1.4 this was solved by bind-mounting a whole replacement for
# /app/src/model/pi-models.ts. 0.1.18 does not need that: a CUSTOM PROVIDER is the supported
# mechanism, configured through the admin API at runtime.
#
# THE ID FORM IS THE WHOLE TRICK
#
# Register the BARE model id (colons are fine), and qm prefixes it internally as
# custom/<providerId>/<bareId> (custom-providers.ts toRuntimeModel). Referencing the bare id,
# or a path with a second `custom/` inside it, fails with "unknown model id" or "not approved".
#
#   register : models[].id           = minimax-m3.1-flash:cloud
#   reference: scopes/.../base-model = custom/ollama/minimax-m3.1-flash:cloud
#
# TWO CONFIG PREREQUISITES, both easy to miss:
#   1. PRIVATE_NETWORK_ALLOWED_ORIGINS must include http://host.docker.internal:11434.
#      0.1.18 refuses a custom provider whose baseUrl resolves to a private address (an SSRF
#      control). Without it the provider saves fine, and then every turn fails with a bare
#      "Connection error." that never mentions the origin.
#   2. /var/run/docker.sock must be mounted with group_add ["0"], or sandbox turns fail.
#
# USAGE
#   .\register-ollama-provider.ps1
#   .\register-ollama-provider.ps1 -Model deepseek-v4.1-flash:1017-cloud
#   .\register-ollama-provider.ps1 -WhatIf
#
# Exit codes: 0 = registered and base model set; 1 = a step failed; 2 = cannot check.

[CmdletBinding()]
param(
    # Bare Ollama model id (colons allowed, no `custom/` prefix).
    [string]$Model = 'minimax-m3.1-flash:cloud',
    [string]$Provider = 'ollama',
    [string]$OllamaBaseUrl = 'http://host.docker.internal:11434/v1',
    # Admin identity. Defaults to the first email in ADMIN_GRANTS.
    [string]$Email = '',
    # Left empty on purpose: derived from qm.config.jsonc, because `qm admin-login` builds the
    # token audience from that same file and the two MUST agree.
    [string]$PublicUrl = '',
    # Core API port (basePort). Derived from config when not supplied.
    [int]$CorePort = 0,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
# This script lives IN the deployment directory, so qm.config.jsonc and .env are beside it.
$deployDir = $PSScriptRoot

function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

Write-Host '=== register Ollama model lane with qm ==='

$cfgPath = Join-Path $deployDir 'qm.config.jsonc'
if (-not (Test-Path $cfgPath)) { Write-Host "SKIP: CANNOT CHECK - $cfgPath not found" -ForegroundColor Yellow; exit 2 }
$cfgTxt = Get-Content $cfgPath -Raw

if (-not $PublicUrl) {
    $PublicUrl = ([regex]::Match($cfgTxt, '"publicUrl"\s*:\s*"(?<v>[^"]+)"')).Groups['v'].Value
    if (-not $PublicUrl) { Fail 'could not read publicUrl from qm.config.jsonc' }
}
if ($CorePort -le 0) {
    $bp = ([regex]::Match($cfgTxt, '"basePort"\s*:\s*(?<v>\d+)')).Groups['v'].Value
    $CorePort = if ($bp) { [int]$bp } else { 8180 }
}
$orgId = ([regex]::Match($cfgTxt, '"orgId"\s*:\s*"(?<v>[^"]+)"')).Groups['v'].Value
if (-not $orgId) { Fail 'could not read orgId from qm.config.jsonc' }

if (-not $Email) {
    $envFile = Join-Path $deployDir '.env'
    if (-not (Test-Path $envFile)) { Write-Host "SKIP: CANNOT CHECK - $envFile not found" -ForegroundColor Yellow; exit 2 }
    $Email = ([regex]::Match((Get-Content $envFile -Raw), '(?m)^\s*ADMIN_GRANTS\s*=\s*(?<v>[^:\r\n]+)')).Groups['v'].Value.Trim()
    if (-not $Email) { Fail 'ADMIN_GRANTS is not set in .env - cannot sign in' }
}

# `qm admin-login` SIGNS the token with a key from the env file it resolves. Without --env-file
# it uses the current directory's .env, so the token is signed with one deployment's key and
# presented to another - the front door then 303s with session cookies that 401 on every admin
# call, with an empty body. Pass the SAME .env the deployment uses.
$envPath = Join-Path $deployDir '.env'
if (-not (Test-Path $envPath)) { Write-Host "SKIP: CANNOT CHECK - $envPath not found" -ForegroundColor Yellow; exit 2 }

$qmDir = Join-Path $deployDir 'node_modules/@yc-software/qm'
if (-not (Test-Path $qmDir)) { Write-Host 'SKIP: CANNOT CHECK - the pinned qm CLI is not installed (run npm ci)' -ForegroundColor Yellow; exit 2 }

Write-Host "         publicUrl: $PublicUrl  core: localhost:$CorePort" -ForegroundColor DarkGray
Write-Host "         admin: $Email  org: $orgId" -ForegroundColor DarkGray
Write-Host "         model: $Model" -ForegroundColor DarkGray

function Get-AdminCookieJar {
    # Use CURL'S COOKIE JAR, not a hand-built Cookie header.
    #
    # This cost hours. A hand-assembled "portal_session=...; portal_session_x=..." string,
    # even byte-identical to one that works from another code path, is rejected with a bare
    # 401 and an EMPTY body. curl's jar is accepted for the same token. The server also marks
    # both cookies HttpOnly, which curl records as "#HttpOnly_" lines - naively filtering jar
    # lines starting with '#' drops exactly the cookies that matter, which makes an empty jar
    # look correct.
    #
    # So: mint the token, let curl perform the exchange and persist the jar, then pass the jar
    # to curl for every subsequent call. Do not reimplement it.
    $raw = & node (Join-Path $qmDir 'dist/bin/qm.js') admin-login --email $Email --config $cfgPath --env-file $envPath 2>$null | Out-String
    $candidate = @($raw -split "`r?`n" | Where-Object { $_ -match '/auth/admin-login#token=' } | Select-Object -Last 1)
    if ($candidate.Count -eq 0) {
        Write-Host '         admin-login produced no token URL. Raw output:' -ForegroundColor DarkGray
        ($raw -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) | ForEach-Object { Write-Host "           $_" -ForegroundColor DarkGray }
        return $null
    }
    $tok = ($candidate[0] -split '#token=')[1].Trim()

    $jar = Join-Path ([IO.Path]::GetTempPath()) ("qm-admin-{0}.jar" -f [guid]::NewGuid().ToString('N'))
    Remove-Item -LiteralPath $jar -ErrorAction SilentlyContinue
    $code = & curl.exe -s -o NUL -w '%{http_code}' -c $jar -X POST "$PublicUrl/auth/admin-login" `
        -H 'Content-Type: application/x-www-form-urlencoded' -H "Origin: $PublicUrl" `
        --data-urlencode "token=$tok" 2>&1
    $code = "$code".Trim()
    if ($code -notmatch '^(200|302|303)$') {
        Write-Host "         admin-login exchange returned $code" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $jar -ErrorAction SilentlyContinue
        return $null
    }
    return $jar
}

$jar = Get-AdminCookieJar
if (-not $jar) { Fail "could not obtain an admin session from $PublicUrl - is the stack up and ADMIN_GRANTS correct?" }

# Verify the session before doing any work: a 401 here means the jar/token flow is wrong, and
# every later step would fail with a misleading message.
$probe = & curl.exe -s -b $jar -o NUL -w '%{http_code}' "http://localhost:$CorePort/v1/admin/whoami" -H "Origin: $PublicUrl" 2>&1
if ("$probe".Trim() -ne '200') { Fail "admin session not usable (whoami -> $("$probe".Trim()))" }

# ── 1. Register the provider, with the BARE model id ─────────────────────────────────────
$spec = @{
    name     = 'Ollama'
    protocol = 'openai'
    baseUrl  = $OllamaBaseUrl
    models   = @(@{ id = $Model; name = $Model; contextWindow = 131072; maxTokens = 8192 })
    apiKey   = 'ollama-local'
    # Verification sends a real billable request. Ollama is local and free, but keep it off by
    # default so this script cannot surprise anyone - the turn itself proves the lane.
    validate = $false
} | ConvertTo-Json -Depth 6 -Compress

$providerBody = Join-Path ([IO.Path]::GetTempPath()) 'qm-provider.json'
Set-Content -LiteralPath $providerBody -Value $spec -Encoding ASCII -NoNewline
try {
    if ($WhatIf) {
        Write-Host "  [whatif] PUT /v1/admin/custom-providers/$Provider" -ForegroundColor Yellow
        Write-Host "           $spec" -ForegroundColor DarkGray
    }
    else {
        $code = & curl.exe -s -b $jar -o NUL -w '%{http_code}' -X PUT `
            "http://localhost:$CorePort/v1/admin/custom-providers/$Provider" `
            -H 'Content-Type: application/json' -H "Origin: $PublicUrl" `
            --data-binary "@$providerBody" 2>&1
        $code = "$code".Trim()
        if ($code -ne '200') { Fail "provider registration failed (HTTP $code)" }
        Write-Host "  [ok] provider '$Provider' registered ($code)" -ForegroundColor Green
    }
}
finally { Remove-Item -LiteralPath $providerBody -ErrorAction SilentlyContinue }

# ── 2. Point the org base model at it, using qm's prefixed id ────────────────────────────
$fullId = "custom/$Provider/$Model"
$baseBody = Join-Path ([IO.Path]::GetTempPath()) 'qm-basemodel.json'
Set-Content -LiteralPath $baseBody -Value ("{`"modelId`":`"$fullId`"}") -Encoding ASCII -NoNewline
try {
    if ($WhatIf) {
        Write-Host "  [whatif] PUT /v1/admin/scopes/org:$orgId/base-model -> $fullId" -ForegroundColor Yellow
    }
    else {
        $code = & curl.exe -s -b $jar -o NUL -w '%{http_code}' -X PUT `
            "http://localhost:$CorePort/v1/admin/scopes/org:$orgId/base-model" `
            -H 'Content-Type: application/json' -H "Origin: $PublicUrl" `
            --data-binary "@$baseBody" 2>&1
        $code = "$code".Trim()
        if ($code -ne '200') {
            Fail ("base-model update failed (HTTP $code). If this says 400 'unknown model id', check that " +
                  "PRIVATE_NETWORK_ALLOWED_ORIGINS includes " + ($OllamaBaseUrl -replace '/v1$', '') +
                  " and that the BARE model id was registered (no custom/ prefix).")
        }
        Write-Host "  [ok] org base model -> $fullId ($code)" -ForegroundColor Green
    }
}
catch {
    $msg = ''
    try { $msg = $_.ErrorDetails.Message } catch { }
    Fail ("could not set the base model: $msg" + [Environment]::NewLine +
          "       'unknown model id' here means the provider registration did not land." +
          " Check that PRIVATE_NETWORK_ALLOWED_ORIGINS includes " + ($OllamaBaseUrl -replace '/v1$', '') +
          " and that the BARE id was registered (no custom/ prefix).")
}
finally { Remove-Item -LiteralPath $baseBody -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'RESULT: Ollama lane registered and selected.' -ForegroundColor Green
Write-Host '  To switch the session model later:' -ForegroundColor DarkGray
Write-Host '    .\register-ollama-provider.ps1 -Model deepseek-v4.1-flash:1017-cloud' -ForegroundColor DarkGray
exit 0

