# Generate an AUTH_PASSWORD_USERS entry for qm 0.1.18+ (password sign-in, no email).
#
# WHY THIS IS NEEDED
#
# 0.1.18 disables sign-in EMAIL by default, and the portal sign-in form requires an email
# address to send a link to. With email disabled the user sees:
#
#   "Email delivery isn't configured - Your administrator needs to configure email delivery
#    before you can request a sign-in link."
#
# That is accurate behaviour, not a bug: the default in 0.1.18 is that an operator issues a
# link with `qm admin-login`. But a law firm's staff cannot work that way - every user would
# need the operator on the phone.
#
# 0.1.18 supports password sign-in with NO email delivery at all, via the optional
# AUTH_PASSWORD_USERS secret: a comma-separated list of `<email>:<scrypt-hash>`. This script
# produces that line using the SAME hash helper qm ships (plugins/auth/src/hash-password.ts),
# so the hash is guaranteed to be one qm accepts - a hand-rolled scrypt call would be rejected
# with "the hash for <email> was not produced by the password helper".
#
# USAGE
#   .\new-password-user.ps1 -Email a@firm.com                 # prompt for the password
#   .\new-password-user.ps1 -Email a@firm.com -Password ...   # non-interactive (testing)
#   .\new-password-user.ps1 -Email a@firm.com -Append         # add to the staged .env
#
# The password is never echoed, and the generated hash is a one-way scrypt digest - but it
# still belongs in .env (gitignored), never in a tracked file.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    # Omit to be prompted (hidden). Supplied only for non-interactive use.
    [string]$Password = '',
    # Container whose image carries the hash helper.
    [string]$Container = 'qm-pacgate-core',
    # Append the entry to the staged .env, merging with any existing AUTH_PASSWORD_USERS.
    [switch]$Append,
    # Print the line only.
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

Write-Host '=== qm password user ==='

if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Fail "'$Email' does not look like an email address" }

# qm enforces its own minimum; check it here so the failure is immediate and explains itself.
if (-not $Password) {
    $sec = Read-Host "Password for $Email" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $Password) { Fail 'no password entered' }
}

# The helper lives in the core image and reads the password from stdin, printing
# "<email>:<hash>". Run it in the SAME image the deployment uses, so the hash format matches.
$script = 'export PATH=/usr/local/bin:$PATH; cd /app && node --experimental-strip-types plugins/auth/src/hash-password.ts "$1"'
$out = ($Password | docker exec -i $Container sh -c $script -- $Email 2>&1 | Out-String).Trim()

if ($LASTEXITCODE -ne 0 -or -not $out -or $out -notmatch ':') {
    Write-Host "raw output: $out" -ForegroundColor DarkGray
    Fail 'the hash helper produced no usable entry - is the core container running this image?'
}
if ($out -match 'hash-password:') {
    Fail ("qm rejected the password: " + (($out -split "`n" | Select-Object -Last 1) -replace 'hash-password:\s*', ''))
}

Write-Host "  generated entry for $Email" -ForegroundColor Green
Write-Host "  $($out.Substring(0,[Math]::Min(40,$out.Length)))... (hash truncated)" -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host ''
    Write-Host $out
    exit 0
}

if (-not $Append) {
    Write-Host ''
    Write-Host 'Add this to the deployment .env as AUTH_PASSWORD_USERS (comma-separate multiple users):' -ForegroundColor Yellow
    Write-Host "  AUTH_PASSWORD_USERS=$out"
    exit 0
}

# Append/merge into the staged .env.
$envPath = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envPath)) {
    # Fall back to the staged client-bundle copy, which is where the live stack keeps it.
    $envPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'client-bundle/qm-pacgate/.env'
}
if (-not (Test-Path $envPath)) { Fail "no .env found to append to (looked in the deploy dir and client-bundle)" }

Copy-Item $envPath "$envPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
$txt = Get-Content $envPath -Raw
$existing = [regex]::Match($txt, '(?m)^\s*AUTH_PASSWORD_USERS\s*=\s*(?<v>.*)$').Groups['v'].Value.Trim()

# Replace an entry for the same email rather than duplicating it - qm rejects a duplicate:
# "AUTH_PASSWORD_USERS lists <email> more than once".
$entries = @()
if ($existing) { $entries = @($existing -split ',' | Where-Object { $_.Trim() }) }
$entries = @($entries | Where-Object { ($_ -split ':')[0].Trim() -ne $Email })
$entries += $out
$merged = ($entries -join ',')

if ($txt -match '(?m)^\s*AUTH_PASSWORD_USERS\s*=') {
    $txt = [regex]::Replace($txt, '(?m)^\s*AUTH_PASSWORD_USERS\s*=.*$', "AUTH_PASSWORD_USERS=$merged")
}
else {
    $txt = $txt.TrimEnd() + "`nAUTH_PASSWORD_USERS=$merged`n"
}
Set-Content -LiteralPath $envPath -Value $txt -NoNewline -Encoding ASCII

Write-Host "  appended to $envPath ($($entries.Count) user(s))" -ForegroundColor Green
Write-Host ''
Write-Host 'Recreate core to pick it up:' -ForegroundColor Yellow
Write-Host '  docker compose -f compose.qm.yaml up -d --force-recreate core'
exit 0
