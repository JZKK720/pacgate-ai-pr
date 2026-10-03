# Pacgate-ai QM bootstrap script
# Run this AFTER install.ps1 has started the main Docker Compose stack.
#
# This script:
#   1. Checks prerequisites (Node 24+, npm, Docker, Ollama)
#   2. Stages qm-pacgate/ into the target directory (from the tracked source)
#   3. Generates signing secrets (openssl rand -hex 32)
#   4. Creates .env with the generated secrets plus the values qm requires
#   5. Prompts for admin email + Pacgate bridge credentials
#   6. Validates config with `qm check`
#   7. Builds the sandbox image with `qm sandbox build`
#
# It does NOT run `qm up` — the engineer should verify config first.

param(
    # Where to stage the deployment. Defaults to <bundle>\qm-pacgate.
    [string]$QmDir,
    # Tracked source of the deployment definition.
    [string]$QmSourceDir,
    # Base URL the bridge account is verified against, from the HOST.
    # 8089 is what compose.prod.yaml publishes for nginx; the /pacgate prefix is
    # nginx's route to pacgate-api (it strips the prefix before proxying).
    # This said 8081 until 2026-10-03 - a port from the old dev layout - so the
    # verification curl at the end of this script pointed at nothing and read as
    # "the bridge account is missing" when it was a wrong URL. It must agree with
    # qm.config.jsonc's PACGATE_API_URL (http://host.docker.internal:8089/pacgate).
    [string]$PacgateApiUrl = "http://localhost:8089/pacgate",

    # --- non-interactive inputs (OPTIONAL) ---------------------------------
    # Left unset, the script prompts exactly as before. When supplied, the three
    # Read-Host prompts are skipped, which makes this script usable from a
    # headless bring-up or a test harness. Additive on purpose: the interactive
    # path an on-site engineer uses is unchanged, because a wrong default here
    # would silently create an account nobody chose.
    [string]$AdminEmail,
    [string]$BridgeEmail,
    # Plain text on the command line is a real exposure (shell history, process
    # list). It exists for automated bring-up only; an operator should let the
    # script prompt, which reads it as a SecureString and never echoes it.
    [string]$BridgePassword
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot = <repo>\deploy\client-bundle, so the repo root is two levels up
# and the tracked deployment definition lives in deploy/qm-pacgate.
if (-not $QmSourceDir) { $QmSourceDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'deploy/qm-pacgate' }
if (-not $QmDir) { $QmDir = Join-Path $PSScriptRoot 'qm-pacgate' }

Write-Host "=== Pacgate-ai QM Bootstrap ===" -ForegroundColor Cyan

# 1. Check prerequisites
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Node.js not found. Install Node.js 24+ from https://nodejs.org" -ForegroundColor Red
    exit 1
}
$nodeVersion = (node --version 2>$null)
if ($nodeVersion -and [int]($nodeVersion -replace 'v(\d+).*', '$1') -lt 24) {
    Write-Host "ERROR: Node.js 24+ required, found $nodeVersion" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Node.js $nodeVersion" -ForegroundColor Green

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: npm not found" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] npm detected" -ForegroundColor Green

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker not found" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Docker detected" -ForegroundColor Green

# 2. Stage the qm-pacgate deployment.
#
# THIS WAS DOCUMENTED BUT NEVER IMPLEMENTED. The header said the script "Copies
# qm-pacgate/ to the target directory" and .gitignore described the runtime copy
# as "staged by setup-qm.ps1" - but no Copy-Item existed, so a fresh machine hit
# 'qm-pacgate directory not found' at the default path and the operator was told
# to copy it by hand. The tracked source is deploy/qm-pacgate/; the runtime copy
# lives in the (gitignored) bundle path because `qm` writes generated files into
# its deployment directory.
if (-not (Test-Path $QmSourceDir)) {
    Write-Host "ERROR: qm deployment source not found at $QmSourceDir" -ForegroundColor Red
    Write-Host "  Expected the tracked definition at <repo>\deploy\qm-pacgate." -ForegroundColor Yellow
    Write-Host "  Pass -QmSourceDir <path> if your checkout differs." -ForegroundColor Yellow
    exit 1
}

if (Test-Path $QmDir) {
    # Re-staging an existing deployment must not silently discard local edits to
    # the config, so only the tracked definition files are refreshed and .env and
    # node_modules are left alone.
    Write-Host "[OK] $QmDir already exists - refreshing the deployment definition" -ForegroundColor Green
}
else {
    Write-Host "`nStaging qm-pacgate into $QmDir..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $QmDir | Out-Null
}

# Copy the deployment definition, excluding anything machine-local or generated.
# .env holds the generated secrets and must never be overwritten by a re-run.
$exclude = @('.env', 'node_modules', '.generated')
Get-ChildItem -LiteralPath $QmSourceDir -Force | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $QmDir -Recurse -Force
}
Write-Host "[OK] Deployment definition staged from $QmSourceDir" -ForegroundColor Green

# 3. Install dependencies
Write-Host "`nInstalling qm dependencies..." -ForegroundColor Cyan
Push-Location $QmDir
try {
    if (Test-Path package-lock.json) {
        npm ci
    } else {
        npm install
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: npm install failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Dependencies installed" -ForegroundColor Green

    # 4. Generate signing secrets
    Write-Host "`nGenerating signing secrets..." -ForegroundColor Cyan

    function New-SecretHex {
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        return -join ($bytes | ForEach-Object { $_.ToString("x2") })
    }

    $secrets = @{
        CAPABILITY_SECRET      = New-SecretHex
        CONNECTOR_SECRET_KEY   = New-SecretHex
        CORE_SIGNING_SECRET    = New-SecretHex
        PORTAL_IDENTITY_SECRET = New-SecretHex
        SKILL_SIGNING_SECRET   = New-SecretHex
    }

    # 5. Prompt for admin email + Pacgate bridge credentials (or take the --params)
    Write-Host "`n=== Configuration ===" -ForegroundColor Cyan

    $adminEmail = if ($AdminEmail) { $AdminEmail } else { Read-Host "Enter the administrator's work email (lowercased)" }
    if (-not $adminEmail) {
        Write-Host "ERROR: Admin email is required" -ForegroundColor Red
        exit 1
    }
    $adminEmail = $adminEmail.ToLowerInvariant()

    $bridgeEmail = if ($BridgeEmail) { $BridgeEmail } else { Read-Host "Enter the Pacgate bridge service-account email (e.g. qm-bridge@pacgate.local)" }
    if (-not $bridgeEmail) {
        Write-Host "ERROR: Bridge email is required" -ForegroundColor Red
        exit 1
    }

    if ($BridgePassword) {
        # Non-interactive: the value arrived as plain text, so it is already a
        # string. Never echoed, never written to a log.
        $plainPassword = $BridgePassword
    }
    else {
        $bridgePassword = Read-Host "Enter the Pacgate bridge service-account password" -AsSecureString
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($bridgePassword)
        )
    }
    if (-not $plainPassword) {
        Write-Host "ERROR: Bridge password is required" -ForegroundColor Red
        exit 1
    }

    # 6. Create .env
    Write-Host "`nCreating .env..." -ForegroundColor Cyan

    # Postgres password for the qm stack's own database. Generated, not prompted:
    # it is internal to the deployment and never typed by a human. compose.qm.yaml
    # has NO default for POSTGRES_PASSWORD, so an unset value substitutes an EMPTY
    # string into DATABASE_URL and qm fails to reach its own database.
    $pgPassword = New-SecretHex

    # OpenViking credentials. Required because qm's sandbox declares them in
    # secretEnv and compose has no default. The ROOT key matters specifically:
    # compose notes that "/mcp authenticates with the ROOT key; the app key returns
    # 401 there", so providing only the app key leaves the ov-* sandbox tools
    # broken. Both are read from the main bundle's .env, which install.ps1 already
    # generated - the qm stack talks to the SAME OpenViking instance over the host
    # port, so the keys must match.
    $mainEnv = Join-Path $PSScriptRoot '.env'
    $ovRoot = ''; $ovApi = ''; $fcKey = ''
    if (Test-Path $mainEnv) {
        foreach ($line in (Get-Content -LiteralPath $mainEnv)) {
            if ($line -match '^\s*OPENVIKING_ROOT_API_KEY\s*=\s*(.+)$') { $ovRoot = $Matches[1].Trim() }
            elseif ($line -match '^\s*OPENVIKING_API_KEY\s*=\s*(.+)$') { $ovApi = $Matches[1].Trim() }
            elseif ($line -match '^\s*FIRECRAWL_API_KEY\s*=\s*(.+)$') { $fcKey = $Matches[1].Trim() }
        }
    }
    if (-not $ovRoot) {
        Write-Host "[WARN] OPENVIKING_ROOT_API_KEY not found in $mainEnv" -ForegroundColor Yellow
        Write-Host "  The qm sandbox ov-* tools will return 401 until it is set." -ForegroundColor Yellow
        Write-Host "  Run install.ps1 first, or add the key to $mainEnv and re-run." -ForegroundColor Yellow
    }

    # Nine further variables that compose.qm.yaml requires as BARE `${VAR}` (no
    # default), so an unset value substitutes an EMPTY string and fails later as
    # an auth error rather than at bootstrap. Found 2026-10-03 - audit-qm-bootstrap
    # had been suppressing all nine via a by-name "optional" allowlist, so nothing
    # reported them until that checker was corrected. See that script's comment.
    #
    # The self-issuable ones are generated here, exactly like the signing secrets
    # above: they are per-deployment, never typed by a human, and a weak or shared
    # value would be a real weakness (AUTH_TOKEN_SECRET signs sessions).
    $authTokenSecret      = New-SecretHex
    $portalSessionSecret  = New-SecretHex
    $authClientSecret     = New-SecretHex
    # A JWK for signing. The auth broker enforces the exact shape at boot:
    #   "[auth] FATAL: AUTH_SIGNING_JWK must be a P-256 private JSON Web Key
    #    (kty EC, crv P-256, with d)"
    # RSA-2048 was tried first and crash-looped qm-pacgate-auth on that line.
    # So: EC P-256, and `crv` must be present - a plain `privateKey.export({format:'jwk'})`
    # includes it, but assert it anyway so a future node change fails loudly here
    # rather than as a restart loop in the auth container.
    # NOTE on the quoting: this MUST stay a single-line -e argument. An earlier
    # version used a PowerShell here-string (@"..."@) INSIDE the double-quoted
    # argument, which PowerShell does not nest - it failed with "unrecognized
    # token". One line with single-quoted JS strings avoids the problem entirely.
    $jwkJs = "const c=require('node:crypto');const{privateKey}=c.generateKeyPairSync('ec',{namedCurve:'P-256'});const j=privateKey.export({format:'jwk'});if(j.kty!=='EC'||j.crv!=='P-256'||!j.d){console.error('unexpected jwk shape');process.exit(1)}process.stdout.write(JSON.stringify({kty:j.kty,crv:j.crv,x:j.x,y:j.y,d:j.d}));"
    $authSigningJwk = (& node -e $jwkJs 2>&1 | Out-String).Trim()
    if (-not $authSigningJwk -or $authSigningJwk -notmatch '"crv":"P-256"') {
        Write-Host "[WARN] could not generate a P-256 AUTH_SIGNING_JWK with node - the qm auth broker will refuse to start" -ForegroundColor Yellow
    }

    # Email transport. Local Mailpit accepts ANY credentials
    # (MP_SMTP_AUTH_ACCEPT_ANY=1, MP_SMTP_AUTH_ALLOW_INSECURE=1) with SMTP_TLS=none,
    # so placeholders are correct for a local bring-up and the mail is captured at
    # http://localhost:8025. For a real deployment these MUST be replaced with the
    # firm's SMTP account - the values are non-empty so nothing silently 401s.
    $smtpUser = if ($env:QM_SMTP_USERNAME) { $env:QM_SMTP_USERNAME } else { 'pacgate-local' }
    $smtpPass = if ($env:QM_SMTP_PASSWORD) { $env:QM_SMTP_PASSWORD } else { 'pacgate-local' }

    # OpenViking scope. Account = the tenant slug qm's sandbox writes under; user =
    # the attorney id. Defaults match the stack's tenant so the sandbox is scoped
    # rather than blank; operators with a different tenant override via the env vars.
    $ovAccount = if ($env:OPENVIKING_ACCOUNT) { $env:OPENVIKING_ACCOUNT } else { 'default-firm' }
    $ovUser    = if ($env:OPENVIKING_USER)    { $env:OPENVIKING_USER }    else { $adminEmail }

    $envContent = @"
ADMIN_GRANTS=$adminEmail
AUTH_ALLOWED_EMAILS=$adminEmail
ANTHROPIC_API_KEY=
MODEL_API_KEY=ollama
CAPABILITY_SECRET=$($secrets.CAPABILITY_SECRET)
CONNECTOR_SECRET_KEY=$($secrets.CONNECTOR_SECRET_KEY)
CORE_SIGNING_SECRET=$($secrets.CORE_SIGNING_SECRET)
PORTAL_IDENTITY_SECRET=$($secrets.PORTAL_IDENTITY_SECRET)
SKILL_SIGNING_SECRET=$($secrets.SKILL_SIGNING_SECRET)
AUTH_TOKEN_SECRET=$authTokenSecret
PORTAL_SESSION_SECRET=$portalSessionSecret
AUTH_CLIENT_SECRET=$authClientSecret
AUTH_SIGNING_JWK=$authSigningJwk
AUTH_EMAIL_FROM=$adminEmail
SMTP_USERNAME=$smtpUser
SMTP_PASSWORD=$smtpPass
OPENVIKING_ACCOUNT=$ovAccount
OPENVIKING_USER=$ovUser
POSTGRES_PASSWORD=$pgPassword
OPENVIKING_ROOT_API_KEY=$ovRoot
OPENVIKING_API_KEY=$ovApi
FIRECRAWL_API_KEY=$fcKey
PUBLIC_API_URL=http://localhost:8180
PACGATE_API_EMAIL=$bridgeEmail
PACGATE_API_PASSWORD=$plainPassword
"@

    $envContent | Out-File -FilePath ".env" -Encoding utf8 -NoNewline

    # Secure the file
    if ($IsLinux -or $IsMacOS) {
        chmod 600 .env
    }

    Write-Host "[OK] .env created (secrets generated, NOT printed)" -ForegroundColor Green

    # 7. Validate config
    Write-Host "`nValidating qm config..." -ForegroundColor Cyan
    npm exec qm -- check
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: qm check failed. Review the errors above." -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] qm check passed" -ForegroundColor Green

    # 8. Build sandbox
    Write-Host "`nBuilding sandbox image..." -ForegroundColor Cyan
    npm exec qm -- sandbox build
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: qm sandbox build failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Sandbox built" -ForegroundColor Green

    # 9. Next steps
    Write-Host "`n=== QM Bootstrap Complete ===" -ForegroundColor Green
    Write-Host "`nNext steps:" -ForegroundColor Cyan
    Write-Host "  1. Verify the Pacgate bridge account exists in pacgate-api:" -ForegroundColor White
    Write-Host "     curl $PacgateApiUrl/api/auth/login -d '{`"email`":`"$bridgeEmail`",`"password`":`"...`"}'" -ForegroundColor Gray
    Write-Host "  2. Start qm:" -ForegroundColor White
    Write-Host "     npm exec qm -- up" -ForegroundColor Gray
    Write-Host "  3. Open: http://localhost:8181" -ForegroundColor White
    Write-Host "     (8181 is the portal FRONT DOOR - sign in there; it proxies to" -ForegroundColor Gray
    Write-Host "      web-ui 8182 and admin 8183. Opening 8182 directly skips auth.)" -ForegroundColor Gray
    Write-Host "  4. Sign in with: $adminEmail" -ForegroundColor White

}
finally {
    Pop-Location
}