# Guard: are the credentials this stack ACTUALLY USES live and correct?
#
# WHY THIS EXISTS (2026-11-05)
#
# test-cross-stack-credentials.ps1 answers a different question: "do the Pacgate
# and QM env files agree with each other?" It is about AGREEMENT ACROSS STACKS,
# and it passes on this box. Nothing answered "is each credential this stack's
# services depend on still VALID, right now?", so an audit for e2e readiness had
# to be done by hand - which is how a stale key survives until a run fails
# somewhere downstream with a misleading error.
#
# The distinction matters because the two failure shapes are different:
#
#   disagreement   -> one side 401s while the other works (cross-stack gate)
#   staleness      -> every side 401s at once         (this gate)
#
# WHAT IT DOES
#   For each credential the client-bundle lane consumes, prove it against the
#   live consumer rather than checking that it is merely non-empty:
#
#   A1  the deployment admin identity authenticates to pacgate-api
#   A2  that identity issues a JWT the API accepts
#   A3  PACGATE_JWT_SECRET is the key the API actually SIGNS/VERIFIES with
#       (forge a token with it; also forge with a wrong key to prove the test
#       can discriminate - a test that always passes is not a test)
#   A4  PACGATE_MATTER_ID names a matter this identity can read
#   A5  PACGATE_DB_PASSWORD opens the pacgate database
#   A6  PACGATE_SANITIZER_KEY is present and long enough to be real key material
#   A7  OPENVIKING_ROOT_API_KEY is accepted by OpenViking /mcp
#   A8  connector keys: report which are absent, and map them to the connectors
#       that go unavailable - a missing key is a PRODUCT DECISION, not a defect,
#       so this WARNS rather than fails. The exception is a key that is present
#       but REJECTED, which is a real failure.
#
# NEVER PRINTS A SECRET. Lengths and tags only. A tag is a short hash, not the
# value; printing values in a terminal puts them in scrollback, screenshots and
# CI logs, which is how the 2026-10-15 password leak happened.
#
# Exit: 0 = every required credential is valid; 1 = a required credential is
#       invalid; 2 = CANNOT CHECK (stack down / env file absent).

[CmdletBinding()]
param(
    [string]$EnvFile = '',
    [string]$BaseUrl = 'http://localhost:8089/pacgate',
    [string]$OllamaUrl = 'http://localhost:11434',
    # Connector keys are optional by design. -RequireAllConnectors turns the
    # A8 warnings into failures for a deployment that sells those connectors.
    [switch]$RequireAllConnectors
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

$script:pass = 0; $script:fail = 0; $script:warn = 0

function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warn++ }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }
function Section($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }

# A tag is a truncated SHA256 of the value: enough to tell two values apart in a
# report, useless for reconstructing either.
function Get-Tag([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return '--------' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($v))
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 12)
}

function Read-EnvFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $h = @{}
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            $h[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $h
}

Write-Host '=== credential audit for the pacgate-ai e2e ===' -ForegroundColor Cyan
Write-Host "    env : $EnvFile" -ForegroundColor DarkGray
Write-Host "    api : $BaseUrl" -ForegroundColor DarkGray

$envVars = Read-EnvFile $EnvFile
if ($null -eq $envVars) {
    Write-Host ''
    Write-Host "CANNOT CHECK: $EnvFile not present (gitignored, per-machine)." -ForegroundColor Yellow
    exit 2
}

# ── stack reachable? ─────────────────────────────────────────────────────────
$api = try { & curl.exe -s -o NUL -w '%{http_code}' --max-time 10 "$BaseUrl/health" } catch { '000' }
$api = "$api".Trim()
if ($api -eq '000') {
    Write-Host ''
    Write-Host 'CANNOT CHECK: pacgate-api is not reachable - start the stack first.' -ForegroundColor Yellow
    exit 2
}
Note "pacgate-api /health -> HTTP $api"

$email = $envVars['PACGATE_API_EMAIL']
$password = $envVars['PACGATE_API_PASSWORD']

# ── A1/A2: identity + token ──────────────────────────────────────────────────
Section 'A1  the deployment admin identity authenticates'

$token = $null
if (-not $email -or -not $password) {
    Fail 'PACGATE_API_EMAIL / PACGATE_API_PASSWORD are not both set - the e2e cannot authenticate'
} else {
    $bodyJson = @{ email = $email; password = $password } | ConvertTo-Json -Compress
    $resp = [string](& curl.exe -s -X POST "$BaseUrl/api/auth/login" -H 'content-type: application/json' -d $bodyJson 2>&1 | Out-String)
    try {
        $parsed = $resp | ConvertFrom-Json
        $token = $parsed.token
    } catch { }

    if ($token) {
        Pass "PACGATE_API_EMAIL (tag $(Get-Tag $email)) + PACGATE_API_PASSWORD (tag $(Get-Tag $password)) -> login 200, JWT issued ($($token.Length) chars)"
    } else {
        Fail "login REJECTED for PACGATE_API_EMAIL (tag $(Get-Tag $email)) - the password does not match this account, or the account does not exist"
    }
}

# ── A3: the JWT secret is the one the API verifies with ─────────────────────
Section 'A3  PACGATE_JWT_SECRET is the key the API actually verifies with'

function New-TestJwt([string]$secret, [hashtable]$claims) {
    function B64Url([byte[]]$b) {
        [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $h = B64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"HS256","typ":"JWT"}'))
    $p = B64Url ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress)))
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($secret)
    $s = B64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$h.$p")))
    return "$h.$p.$s"
}

$jwtSecret = $envVars['PACGATE_JWT_SECRET']
if (-not $jwtSecret) {
    Fail 'PACGATE_JWT_SECRET is unset - tokens cannot be verified consistently across restarts'
} elseif (-not $token) {
    Warn 'skipped: no valid identity to build claims from'
} else {
    # Claims must match the Claims struct (sub, tenant_id, role, system_role, exp).
    # A thin token 401s for a reason unrelated to the secret, which reads as a
    # mismatch - that false signal is why this uses the real identity's ids.
    $me = $null
    try {
        $meRaw = [string](& curl.exe -s "$BaseUrl/api/auth/me" -H "Authorization: Bearer $token" 2>&1 | Out-String)
        $me = $meRaw | ConvertFrom-Json
    } catch { }

    if (-not $me -or -not $me.tenant_id) {
        Warn 'skipped: /api/auth/me did not return a tenant_id to build claims from'
    } else {
        $claims = @{
            sub         = [string]$me.user_id
            tenant_id   = [string]$me.tenant_id
            role        = 'admin'
            system_role = 'admin'
            exp         = [DateTimeOffset]::UtcNow.AddMinutes(5).ToUnixTimeSeconds()
        }
        $good = New-TestJwt $jwtSecret $claims
        $goodCode = "$(& curl.exe -s -o NUL -w '%{http_code}' "$BaseUrl/api/auth/me" -H "Authorization: Bearer $good")".Trim()

        # NEGATIVE CONTROL. Without this, a 200 would not prove the secret was
        # used - it could mean the route does not verify signatures at all.
        $wrong = New-TestJwt ('x' * 64) $claims
        $wrongCode = "$(& curl.exe -s -o NUL -w '%{http_code}' "$BaseUrl/api/auth/me" -H "Authorization: Bearer $wrong")".Trim()

        if ($goodCode -eq '200' -and $wrongCode -eq '401') {
            Pass "token signed with PACGATE_JWT_SECRET (tag $(Get-Tag $jwtSecret)) -> 200; signed with a wrong key -> 401 (test discriminates)"
        } elseif ($goodCode -eq '200' -and $wrongCode -eq '200') {
            Fail 'a token signed with an ARBITRARY secret was accepted - the API is not verifying signatures'
        } else {
            Fail "token signed with PACGATE_JWT_SECRET -> HTTP $goodCode (expected 200). The env value is not the key this API verifies with"
        }
    }
}

# ── A4: the matter id resolves for this identity ─────────────────────────────
Section 'A4  PACGATE_MATTER_ID names a matter this identity can read'

$matterId = $envVars['PACGATE_MATTER_ID']
if (-not $matterId) {
    Warn 'PACGATE_MATTER_ID is unset - the adapter refuses to write rather than guessing a matter (by design)'
} elseif (-not $token) {
    Warn 'skipped: no token'
} else {
    $code = "$(& curl.exe -s -o NUL -w '%{http_code}' "$BaseUrl/api/matters/$matterId" -H "Authorization: Bearer $token")".Trim()
    if ($code -eq '200') {
        Pass "PACGATE_MATTER_ID ($matterId) -> 200"
    } else {
        Fail "PACGATE_MATTER_ID ($matterId) -> HTTP $code. 404 = the matter does not exist here (a matter id is NOT portable between deployments); 403 = exists but is another tenant's"
    }
}

# ── A5: the database password ────────────────────────────────────────────────
Section 'A5  PACGATE_DB_PASSWORD opens the pacgate database'

$dbPass = $envVars['PACGATE_DB_PASSWORD']
$dbCtr = (& docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq 'pacgate-db' })
if (-not $dbPass) {
    Fail 'PACGATE_DB_PASSWORD is unset'
} elseif (-not $dbCtr) {
    Warn 'skipped: pacgate-db container is not running'
} else {
    # Passed via PGPASSWORD so the value is never in the command line, where it
    # would land in shell history and in `docker inspect` of the exec session.
    $out = [string](& docker exec -e "PGPASSWORD=$dbPass" pacgate-db psql -h 127.0.0.1 -U pacgate -d pacgate -tAc 'select 1' 2>&1 | Out-String)
    if ($out.Trim() -eq '1') {
        Pass "PACGATE_DB_PASSWORD (tag $(Get-Tag $dbPass)) -> psql authenticated"
    } else {
        Fail "PACGATE_DB_PASSWORD (tag $(Get-Tag $dbPass)) was REJECTED by pacgate-db - the volume's role password is what counts, and .env does not change an existing volume"
    }
}

# ── A6: sanitizer key shape ──────────────────────────────────────────────────
Section 'A6  PACGATE_SANITIZER_KEY is real key material'

$san = $envVars['PACGATE_SANITIZER_KEY']
if (-not $san) {
    Fail 'PACGATE_SANITIZER_KEY is unset - the sanitizer falls back to a per-process random key, so cross-document token correlation silently stops working'
} elseif ($san.Length -lt 32) {
    Fail "PACGATE_SANITIZER_KEY is only $($san.Length) chars - too short to be key material"
} elseif ($san -match '^change-me') {
    Fail "PACGATE_SANITIZER_KEY is still the .env.example placeholder - set looks satisfied but no key exists"
} else {
    Pass "PACGATE_SANITIZER_KEY present, $($san.Length) chars (tag $(Get-Tag $san))"
}

# ── A7: OpenViking ──────────────────────────────────────────────────────────
Section 'A7  OPENVIKING_ROOT_API_KEY is accepted by OpenViking'

$ovKey = $envVars['OPENVIKING_ROOT_API_KEY']
$ovCtr = (& docker ps --format '{{.Names}}' 2>$null | Where-Object { $_ -eq 'openviking' })
if (-not $ovKey) {
    Fail 'OPENVIKING_ROOT_API_KEY is unset'
} elseif (-not $ovCtr) {
    Warn 'skipped: openviking container is not running'
} else {
    # Mirrors test-cross-stack-credentials.ps1 C4 exactly, because the shape
    # matters and two of my earlier attempts failed on it:
    #   * MCP requires `Accept: application/json, text/event-stream`; without it
    #     the server answers 406 and the key looks bad.
    #   * OpenViking authenticates this endpoint with `X-API-Key`, not a Bearer.
    #   * Port 1933 is published on the host, so no `docker exec` and no nested
    #     quoting are needed - which is what mangled the secret in those attempts.
    $mcpBody = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    $code = $null
    try {
        $resp = Invoke-WebRequest -Uri 'http://localhost:1933/mcp' -Method Post -Body $mcpBody `
            -ContentType 'application/json' `
            -Headers @{ 'Accept' = 'application/json, text/event-stream'; 'X-API-Key' = $ovKey } `
            -TimeoutSec 12 -UseBasicParsing
        $code = $resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
    }

    if ($code -eq 200) {
        Pass "OPENVIKING_ROOT_API_KEY (tag $(Get-Tag $ovKey)) -> /mcp 200"
    } elseif ($code -eq 401) {
        Fail "OPENVIKING_ROOT_API_KEY (tag $(Get-Tag $ovKey)) -> /mcp 401 Invalid API Key"
    } else {
        Warn "OpenViking /mcp returned HTTP $code - not reachable in the expected shape; key not evaluated"
    }
}

# ── A8: optional connector keys ────────────────────────────────────────────
Section 'A8  connector keys (optional by design)'

# key -> connector name as pacgate-api reports it in /api/search/connectors
#
# ANSVAR IS DELIBERATELY ABSENT. `pacgate-search` reads ANSVAR_API_KEY, but that
# catalog entry is `implemented: false` (a self-hosted MCP server not deployed in
# this stack) and compose no longer forwards the var in either lane. Setting the
# key cannot enable anything, so listing it here would imply otherwise.
$connectorKeys = [ordered]@{
    'PKULAW_API_KEY'         = 'pkulaw'
    'VAQUILL_API_KEY'        = 'vaquill'
    'OPENCORPORATES_API_KEY' = 'opencorporates'
    'FIRECRAWL_API_KEY'      = 'firecrawl'
}

# WHAT `available` ACTUALLY MEANS, and why this block is written around it:
#
#   Every keyed connector reports availability as `self.api_key.is_some()`, and no
#   route calls `health_check()` - /api/search/connectors and /api/search/health
#   both read the presence flag. So:
#
#     available=false -> no key. Deterministic; fixing it here is the whole job.
#     available=true  -> a NON-EMPTY key exists. It may still be rejected upstream.
#
#   That makes "set but available=false" almost unreachable, and "set and
#   available=true" only proof of presence. Reporting the latter as a pass would be
#   the same vacuous-green failure this repo has been bitten by before, so the
#   wording below says which claim each case actually supports. A real per-key
#   validation needs a network call per connector, which is why it is NOT asserted
#   here; the legal-journey e2e exercises search for real.
$live = @{}
if ($token) {
    try {
        $raw = [string](& curl.exe -s "$BaseUrl/api/search/connectors" -H "Authorization: Bearer $token" 2>&1 | Out-String)
        foreach ($c in ($raw | ConvertFrom-Json)) { $live[$c.name] = [bool]$c.available }
    } catch { }
}

foreach ($k in $connectorKeys.Keys) {
    $conn = $connectorKeys[$k]
    $set = [bool]$envVars[$k]
    $up = if ($live.ContainsKey($conn)) { $live[$conn] } else { $null }
    if (-not $set) {
        $suffix = if ($up -eq $false) { "connector '$conn' reports available=false" } else { "connector '$conn' not reported live" }
        Warn "$k ABSENT -> $suffix"
    } elseif ($up -eq $false) {
        Fail "$k is set (tag $(Get-Tag $envVars[$k])) but connector '$conn' reports available=false - the api container is not seeing the var; restart pacgate-api after editing .env"
    } else {
        # Presence only. Say so, so nobody reads this as proof the key is valid.
        Pass "$k set (tag $(Get-Tag $envVars[$k])) -> connector '$conn' reports available (PRESENCE only - a rejected key also reports available=true; a search is what proves it)"
    }
}

$keyedUp = @($live.Keys | Where-Object { $live[$_] })
Note "keyless connectors that work without any credential: $(($keyedUp | Where-Object { $_ -in @('courtlistener','sec_edgar','gleif','eur-lex') }) -join ', ')"

# ── summary ─────────────────────────────────────────────────────────────────
Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "RESULT: $($script:pass) passed, $($script:fail) FAILED, $($script:warn) warning(s)" -ForegroundColor Red
    Write-Host '  A required credential is not valid. Fix these before blaming a later step.' -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: every required credential for the e2e is valid. ($($script:pass) passed, $($script:warn) warning(s))" -ForegroundColor Green
if ($RequireAllConnectors -and $script:warn -gt 0) {
    Write-Host '  -RequireAllConnectors: connector warnings treated as failures.' -ForegroundColor Red
    exit 1
}
exit 0
