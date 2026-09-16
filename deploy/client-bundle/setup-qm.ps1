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
    [string]$PacgateApiUrl = "http://localhost:8081"
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

    # 5. Prompt for admin email + Pacgate bridge credentials
    Write-Host "`n=== Configuration ===" -ForegroundColor Cyan

    $adminEmail = Read-Host "Enter the administrator's work email (lowercased)"
    if (-not $adminEmail) {
        Write-Host "ERROR: Admin email is required" -ForegroundColor Red
        exit 1
    }
    $adminEmail = $adminEmail.ToLowerInvariant()

    $bridgeEmail = Read-Host "Enter the Pacgate bridge service-account email (e.g. qm-bridge@pacgate.local)"
    if (-not $bridgeEmail) {
        Write-Host "ERROR: Bridge email is required" -ForegroundColor Red
        exit 1
    }

    $bridgePassword = Read-Host "Enter the Pacgate bridge service-account password" -AsSecureString
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($bridgePassword)
    )
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
    Write-Host "  3. Open: http://localhost:8182" -ForegroundColor White
    Write-Host "  4. Sign in with: $adminEmail" -ForegroundColor White

}
finally {
    Pop-Location
}