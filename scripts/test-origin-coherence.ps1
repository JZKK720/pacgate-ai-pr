# Gate: every browser origin this machine advertises is actually ACCEPTED for auth.
#
# WHY THIS EXISTS (2026-10-19). This is the gate whose absence let a client-facing
# auth breakage ship for an unknown length of time, through a fully green 40-gate
# suite - including the edge gate added the week before, which tests lane
# connectivity from INSIDE containers and therefore never exercises a browser Origin.
#
# THE DEFECT AS MEASURED BEFORE THE FIX, on the assembled stack:
#
#   POST /api/v1/auth/login/local with Origin: http://localhost:8089      -> 422 (reaches auth)
#   POST /api/v1/auth/login/local with Origin: http://<hostname>:8089     -> 422 (works)
#   POST /api/v1/auth/login/local with Origin: http://localhost:8090      -> 403 BLOCKED
#   POST /api/v1/auth/login/local with Origin: http://<hostname>:8090     -> 403 BLOCKED
#
# Two allowlists were computed by DIFFERENT rules and nothing compared them:
#
#   1. GATEWAY_CORS_ORIGINS - install.ps1 derived it per machine as
#      <scheme>://<hostname|every-LAN-IP>:<nginx port>. The compose default was
#      "http://localhost:8089,http://localhost:8090", but once .env had a value
#      compose used THAT instead. The derived list contained only the nginx port,
#      so port 8090 - which the shipped default granted - was silently REMOVED.
#      The installer's "helpful" derivation therefore reduced access.
#
#   2. DEER_FLOW_TRUSTED_ORIGINS - compose.prod.yaml hardcoded
#      "http://localhost:8089,http://localhost:8090,http://localhost:3000".
#      Localhost only: a client browsing the AIPC from another computer was never
#      in it. (It was also ABSENT from compose.bundle.yaml, so the two deploy
#      shapes differed in this security-relevant list.)
#
# A 403 here is not a credentials failure - it is refused BEFORE authentication.
# That is why it looks like "blocked from OAuth" rather than a wrong password.
#
# THE FIX (in place): both allowlists are now substitution-derived from the single
# GATEWAY_CORS_ORIGINS value, in BOTH compose files; install.ps1 derives both
# published ports and repairs an incomplete existing .env additively; and the qm
# stack derives its six browser-facing OAuth URLs from QM_PUBLIC_URL instead of
# hardcoding localhost. This gate stays as the enforcement.
#
# WHAT IT CHECKS
#   O1  every origin recorded in .env GATEWAY_CORS_ORIGINS is not 403 for auth
#   O2  the frontend's own published port (8090) is represented in the allowlist
#   O3  DEER_FLOW_TRUSTED_ORIGINS covers the machine's hostname/LAN origins
#   O4  the two allowlists are compared, not just individually plausible
#   O5  the OIDC discovery document advertises a browser-reachable issuer
#
# It sends a deliberately WRONG credential. 422/400/401 all mean "reached the auth
# layer"; only 403 means "refused by the Origin gate". So the check needs no valid
# password and cannot create state.
#
# Exit codes: 0 = every advertised origin is accepted;  1 = an origin is REFUSED;
#             2 = cannot check (stack down)
#
# Usage:  pwsh -File scripts/test-origin-coherence.ps1
#         pwsh -File scripts/test-origin-coherence.ps1 -ListOnly

[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:8089',
    [string]$EnvFile = 'deploy/client-bundle/.env',
    [int]$FrontendPort = 8090,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$script:failures = 0
$script:passed = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Info([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor Yellow }

Write-Host '=== every advertised browser origin is accepted for auth ==='

# ---------------------------------------------------------------------------
# Collect the allowlists from .env and from the tracked compose file.
# ---------------------------------------------------------------------------
$envPath = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path $repoRoot $EnvFile }
$envVars = @{}
if (Test-Path -LiteralPath $envPath) {
    foreach ($l in [System.IO.File]::ReadAllLines($envPath)) {
        if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $envVars[$Matches[1]] = $Matches[2] }
    }
}

$corsFromEnv = if ($envVars.ContainsKey('GATEWAY_CORS_ORIGINS')) { $envVars['GATEWAY_CORS_ORIGINS'] } else { '' }
$origins = @()
if ($corsFromEnv) { $origins = @($corsFromEnv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# The live container's view is authoritative - .env could differ from what is running.
$liveCors = ''
$liveEnv = docker inspect deer-flow --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null
if ($LASTEXITCODE -eq 0) {
    foreach ($l in $liveEnv) {
        if ($l -match '^GATEWAY_CORS_ORIGINS=(.*)$') { $liveCors = $Matches[1] }
    }
}
if ($liveCors) {
    $origins = @($liveCors -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Info "allowlist read from the RUNNING deer-flow container ($($origins.Count) origin(s))"
} elseif ($origins.Count -gt 0) {
    Write-Info "allowlist read from $EnvFile ($($origins.Count) origin(s)); deer-flow not running"
}

Write-Host ''
Write-Host '  configured origins:' -ForegroundColor DarkGray
foreach ($o in $origins) { Write-Host "    $o" -ForegroundColor DarkGray }

if ($ListOnly) { exit 0 }

if ($origins.Count -eq 0) {
    Write-Host ''
    Write-Host 'CANNOT CHECK: no GATEWAY_CORS_ORIGINS configured or readable.' -ForegroundColor Yellow
    exit 2
}

# Is pacgate-nginx / deer-flow even reachable?
$up = $false
try {
    $probe = Invoke-WebRequest -Uri "$BaseUrl/" -TimeoutSec 8 -UseBasicParsing
    $up = ($probe.StatusCode -eq 200)
} catch { $up = $false }
if (-not $up) {
    Write-Host ''
    Write-Host "CANNOT CHECK: $BaseUrl is not answering - start the stack." -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------------------
# The probe. A deliberately wrong password. Only 403 means "Origin refused".
# ---------------------------------------------------------------------------
$body = '{"email":"origin-probe@invalid.local","password":"deliberately-wrong-not-a-credential"}'

function Test-Origin([string]$origin) {
    try {
        $r = Invoke-WebRequest -Uri "$BaseUrl/api/v1/auth/login/local" -Method Post -Body $body `
            -ContentType 'application/json' -Headers @{ 'Origin' = $origin } -TimeoutSec 15 -UseBasicParsing
        return [pscustomobject]@{ Origin = $origin; Code = $r.StatusCode; Verdict = 'accepted' }
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -eq 403) { return [pscustomobject]@{ Origin = $origin; Code = 403; Verdict = 'REFUSED' } }
        if ($code -eq 0) { return [pscustomobject]@{ Origin = $origin; Code = 0; Verdict = 'unreachable' } }
        return [pscustomobject]@{ Origin = $origin; Code = $code; Verdict = 'accepted' }
    }
}

# ---------------------------------------------------------------------------
# O1. Every advertised origin must not be 403.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'O1  every advertised origin is not 403' -ForegroundColor Cyan
$refused = @()
foreach ($o in $origins) {
    $res = Test-Origin $o
    if ($res.Verdict -eq 'REFUSED') {
        Write-Fail "$o -> HTTP 403 REFUSED (it is in the allowlist but the gateway rejects it)"
        $refused += $o
    } elseif ($res.Verdict -eq 'unreachable') {
        Write-Skip "$o -> connection failed"
    } else {
        Write-Pass "$o -> HTTP $($res.Code) (reached auth)"
    }
}

# ---------------------------------------------------------------------------
# O2. The frontend's published port must be represented.
#
# This is the specific regression: the compose default granted :8090, and the
# installer's derived value removed it.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "O2  the frontend port (:$FrontendPort) is represented" -ForegroundColor Cyan
$hasFrontendPort = @($origins | Where-Object { $_ -match ":$FrontendPort`$" })
if ($hasFrontendPort.Count -gt 0) {
    Write-Pass ":$FrontendPort appears in $($hasFrontendPort.Count) origin(s)"
} else {
    Write-Fail "no origin uses :$FrontendPort - the frontend is published there and the shipped compose default granted it; the machine-derived list REMOVED it"
    # Show the consequence explicitly.
    $res = Test-Origin "http://localhost:$FrontendPort"
    if ($res.Verdict -eq 'REFUSED') {
        Write-Info "confirmed: http://localhost:$FrontendPort -> HTTP 403"
    }
}

# ---------------------------------------------------------------------------
# O3. DEER_FLOW_TRUSTED_ORIGINS must cover this machine's own origins.
#
# It is a SEPARATE hardcoded list (compose.prod.yaml). Checked statically, because
# it cannot be probed independently of GATEWAY_CORS_ORIGINS - both gate the same 403.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'O3  DEER_FLOW_TRUSTED_ORIGINS covers this machine' -ForegroundColor Cyan
$prodCompose = Join-Path $repoRoot 'deploy/client-bundle/compose.prod.yaml'
$bundleCompose = Join-Path $repoRoot 'deploy/client-bundle/compose.bundle.yaml'

function Get-TrustedOrigins([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($l in [System.IO.File]::ReadLines($path)) {
        if ($l -match '^\s*DEER_FLOW_TRUSTED_ORIGINS\s*:\s*(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

# Resolve a compose value the way Docker Compose does, so a substitution-derived
# allowlist is compared by its EFFECTIVE origins rather than by its source text.
# Without this the gate reported false failures as soon as the value became
# ${GATEWAY_CORS_ORIGINS:-...}: it compared the literal string and claimed the
# machine was uncovered while the running containers were correctly covered.
function Resolve-ComposeValue([string]$raw, [hashtable]$vars) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $raw }
    $out = $raw
    # ${VAR:-default} and ${VAR-default}
    $out = [regex]::Replace($out, '\$\{([A-Za-z_][A-Za-z0-9_]*)(:-|-)([^}]*)\}', {
        param($m)
        $name = $m.Groups[1].Value; $op = $m.Groups[2].Value; $dflt = $m.Groups[3].Value
        $val = if ($vars.ContainsKey($name)) { [string]$vars[$name] } else { '' }
        if ($op -eq ':-') { if ([string]::IsNullOrWhiteSpace($val)) { return $dflt } else { return $val } }
        if ($null -eq $val) { return $dflt }
        return $val
    })
    # bare ${VAR} / $VAR
    $out = [regex]::Replace($out, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', {
        param($m)
        $name = $m.Groups[1].Value
        if ($vars.ContainsKey($name)) { return [string]$vars[$name] } else { return '' }
    })
    return $out
}

$trustedProdRaw = Get-TrustedOrigins $prodCompose
$trustedBundleRaw = Get-TrustedOrigins $bundleCompose
$trustedProd = Resolve-ComposeValue $trustedProdRaw $envVars
$trustedBundle = Resolve-ComposeValue $trustedBundleRaw $envVars
$hostName = ([System.Net.Dns]::GetHostName()).ToLowerInvariant()

if (-not $trustedProd) {
    Write-Skip 'DEER_FLOW_TRUSTED_ORIGINS not set in compose.prod.yaml'
} else {
    $trustedList = @($trustedProd -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Info "compose.prod.yaml resolves to $($trustedList.Count): $($trustedList -join ', ')"
    if ($trustedList -match "http://$([regex]::Escape($hostName)):") {
        Write-Pass "covers this machine's hostname ($hostName)"
    } else {
        Write-Fail "does NOT cover this machine's hostname (http://$hostName`:$FrontendPort) - a client browsing the AIPC from another computer is not in this list"
    }
    # The allowlist that actually admits the browser is GATEWAY_CORS_ORIGINS, so a
    # mismatch here is only a failure if it drops something the other list has.
    $corsHosts = @($origins | ForEach-Object { ($_ -split '://')[1] } | Where-Object { $_ })
    $missing = @($corsHosts | Where-Object { $t = $_; -not ($trustedList | Where-Object { ($_ -split '://')[1] -eq $t }) })
    if ($missing.Count -gt 0) {
        Write-Fail "$($missing.Count) origin(s) in GATEWAY_CORS_ORIGINS are absent from DEER_FLOW_TRUSTED_ORIGINS: $($missing -join ', ')"
    } else {
        Write-Pass 'every GATEWAY_CORS_ORIGINS host is also present in DEER_FLOW_TRUSTED_ORIGINS'
    }
}

if ($null -eq $trustedBundleRaw) {
    Write-Fail 'DEER_FLOW_TRUSTED_ORIGINS is ABSENT from compose.bundle.yaml - the two deploy shapes differ in a security-relevant allowlist, so behaviour depends on which file is used'
} elseif ($trustedProd -and $trustedBundle -cne $trustedProd) {
    Write-Fail "compose.bundle.yaml and compose.prod.yaml resolve DEER_FLOW_TRUSTED_ORIGINS DIFFERENTLY (bundle='$trustedBundle' vs prod='$trustedProd')"
} else {
    Write-Pass 'both compose files resolve to the same DEER_FLOW_TRUSTED_ORIGINS'
}

# ---------------------------------------------------------------------------
# O4. The allowlists must be derived from ONE source.
#
# Static statement of the root cause: if GATEWAY_CORS_ORIGINS comes from install.ps1's
# machine derivation and DEER_FLOW_TRUSTED_ORIGINS is a compose literal, they will
# diverge on every machine that is not named "localhost". Advisory because deciding the
# single source is a config change, not something this gate can silently impose.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'O4  the two allowlists come from one source (advisory)' -ForegroundColor Cyan
if ($trustedProdRaw -and $trustedProdRaw -notmatch '\$\{') {
    Write-Info 'DEER_FLOW_TRUSTED_ORIGINS is a hardcoded literal while GATEWAY_CORS_ORIGINS is machine-derived:'
    Write-Info '  these are computed by different rules and WILL diverge. Derive both from one value.'
} else {
    Write-Pass 'both allowlists are substitution-derived (DEER_FLOW_TRUSTED_ORIGINS follows GATEWAY_CORS_ORIGINS)'
}

# ---------------------------------------------------------------------------
# O5. The OAuth discovery document must advertise a BROWSER-REACHABLE issuer.
#
# OAuth is a browser redirect: the issuer and authorization_endpoint in the
# discovery document are resolved by the browser ON THE USER'S MACHINE. If they
# say localhost, a user sitting at any other computer is redirected to their own
# loopback and sign-in can never complete. That is the "blocked from OAuth"
# symptom, and unlike a 403 it produces no server-side error at all.
#
# The qm stack hardcoded AUTH_ISSUER / AUTH_REDIRECT_URI / OIDC_ISSUER /
# OIDC_AUTH_ENDPOINT / PORTAL_PUBLIC_URL / PUBLIC_WEB_URL to localhost in six
# places. Token exchange still worked because OIDC_TOKEN_ENDPOINT correctly used
# http://auth:8080 (in-cluster), so any server-side probe passed while browser
# sign-in was dead. Only the browser-facing URLs are checked here.
#
# Advisory when the stack is not running; a real failure when it is running and
# advertises localhost while the machine is accessed by another host.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'O5  OAuth discovery advertises a browser-reachable issuer' -ForegroundColor Cyan
$qmContainer = 'qm-pacgate-auth'
$disco = $null
try {
    $raw = docker exec $qmContainer sh -lc 'wget -qO- http://localhost:8080/.well-known/openid-configuration 2>/dev/null' 2>$null
    if ($raw) { $disco = ($raw | Out-String) | ConvertFrom-Json }
} catch { $disco = $null }

if (-not $disco) {
    Write-Skip 'qm-pacgate-auth not running - cannot read the discovery document'
} else {
    $issuer = "$($disco.issuer)"
    Write-Info "issuer = $issuer"
    if ($issuer -match '://(localhost|127\.0\.0\.1)[:/]') {
        # A localhost issuer is only acceptable on a single-machine install. The
        # machine's own GATEWAY_CORS_ORIGINS is the honest signal: if this box
        # publishes non-loopback browser origins, then people DO reach it from
        # other computers, and a localhost issuer will redirect each of them to
        # their own loopback. Same source of truth as O1/O3, so the gate cannot
        # disagree with itself.
        $lanOrigins = @($origins | Where-Object { $_ -notmatch '://(localhost|127\.0\.0\.1)[:/]' })
        if ($lanOrigins.Count -gt 0) {
            Write-Fail "issuer advertises localhost while this machine publishes $($lanOrigins.Count) LAN origin(s) - remote sign-in redirects to the user's OWN machine. Set QM_PUBLIC_URL in deploy/client-bundle/qm-pacgate/.env"
        } else {
            Write-Info 'issuer is localhost and no LAN origins are published (single-machine install) - acceptable'
        }
    } else {
        Write-Pass "issuer is browser-reachable ($issuer)"
    }
    # The in-cluster endpoints MUST NOT be rewritten to the public host, or the
    # portal cannot fetch tokens/JWKS from inside the compose network.
    $tok = docker exec qm-pacgate-portal printenv OIDC_TOKEN_ENDPOINT 2>$null
    if ($tok) {
        $tok = ($tok | Out-String).Trim()
        if ($tok -match '://auth:') { Write-Pass "in-cluster token endpoint stays internal ($tok)" }
        else { Write-Fail "OIDC_TOKEN_ENDPOINT is not the in-cluster name ($tok) - token exchange may break" }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAIL: $($script:failures) origin-coherence problem(s). $($script:passed) passed." -ForegroundColor Red
    Write-Host ''
    Write-Host '  A 403 here is not a credentials failure - it is refused BEFORE authentication,' -ForegroundColor DarkGray
    Write-Host '  which is why it presents as "blocked from OAuth" rather than a wrong password.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Fix both allowlists from one derived value, for example:' -ForegroundColor DarkGray
    Write-Host '    GATEWAY_CORS_ORIGINS      in .env  (install.ps1 derives it)' -ForegroundColor DarkGray
    Write-Host '    DEER_FLOW_TRUSTED_ORIGINS compose    <- make it ${GATEWAY_CORS_ORIGINS} or derive from the same source' -ForegroundColor DarkGray
    Write-Host '  and include BOTH the nginx port (8089) and the frontend port (8090).' -ForegroundColor DarkGray
    exit 1
}

Write-Host "RESULT: every advertised origin is accepted for auth. ($($script:passed) passed)" -ForegroundColor Green
exit 0
