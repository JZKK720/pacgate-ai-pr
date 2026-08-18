# Pacgate-ai QM bootstrap script
# Run this AFTER install.ps1 has started the main Docker Compose stack.
#
# This script:
#   1. Checks prerequisites (Node 24+, npm, Docker, Ollama)
#   2. Copies qm-pacgate/ to the target directory
#   3. Generates signing secrets (openssl rand -hex 32)
#   4. Creates .env from .env.example with generated secrets
#   5. Prompts for admin email + Pacgate bridge credentials
#   6. Validates config with `qm check`
#   7. Builds the sandbox image with `qm sandbox build`
#
# It does NOT run `qm up` — the engineer should verify config first.

param(
    [string]$QmDir = ".\qm-pacgate",
    [string]$PacgateApiUrl = "http://localhost:8081"
)

$ErrorActionPreference = "Stop"

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

# 2. Check qm-pacgate directory
if (-not (Test-Path $QmDir)) {
    Write-Host "ERROR: qm-pacgate directory not found at $QmDir" -ForegroundColor Red
    Write-Host "  Copy the qm-pacgate/ directory from the client bundle to this location." -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] qm-pacgate directory found" -ForegroundColor Green

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

    $envContent = @"
ADMIN_GRANTS=$adminEmail
ANTHROPIC_API_KEY=
MODEL_API_KEY=ollama
CAPABILITY_SECRET=$($secrets.CAPABILITY_SECRET)
CONNECTOR_SECRET_KEY=$($secrets.CONNECTOR_SECRET_KEY)
CORE_SIGNING_SECRET=$($secrets.CORE_SIGNING_SECRET)
PORTAL_IDENTITY_SECRET=$($secrets.PORTAL_IDENTITY_SECRET)
SKILL_SIGNING_SECRET=$($secrets.SKILL_SIGNING_SECRET)
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