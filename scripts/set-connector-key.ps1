# Provision a connector API key into deploy/client-bundle/.env, safely.
#
# WHY THIS EXISTS
#   The five keyed connectors (pkulaw, vaquill, opencorporates, firecrawl, and the
#   unwired ansvar) each need a credential issued by that provider. Nobody can mint
#   them from here, and a key typed on a shell command line lands in shell history
#   and in the process list. Hand-editing .env also has a trap: `docker compose`
#   refuses a BOM, and PS 5.1's Set-Content adds one by default, so a Windows edit
#   can leave the whole file unparseable by compose.
#
#   This takes the key from a FILE (or a prompt), writes it with no BOM, preserves
#   every other line including comments and secrets, and never echoes the value.
#
# USAGE
#   # from a file, the recommended path
#   pwsh -File scripts/set-connector-key.ps1 -Connector pkulaw -FromFile C:\keys\pkulaw.txt
#
#   # or let it prompt (typing is not echoed)
#   pwsh -File scripts/set-connector-key.ps1 -Connector firecrawl
#
#   # then restart the api so compose re-reads .env
#   docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-api
#
#   # and prove it with a real search, because `available=true` only means a key
#   # is PRESENT - no route calls health_check(), so a wrong key also reads true
#   pwsh -File scripts/audit-e2e-credentials.ps1
#
# Exit: 0 = written; 1 = refused or failed; 2 = cannot check (no .env).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('pkulaw', 'vaquill', 'opencorporates', 'firecrawl', 'yuandian', 'qcc', 'fyopen')]
    [string]$Connector,

    # Preferred: a file holding just the key (trailing newline tolerated).
    # Keeping it out of argv keeps it out of shell history and the process list.
    [string]$FromFile,

    [string]$EnvFile = '',

    # Write the line even if the key is already present. Default is to refuse,
    # because silently rotating a working key is how a deployment breaks itself.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repo 'deploy/client-bundle/.env' }

$varName = switch ($Connector) {
    'pkulaw' { 'PKULAW_API_KEY' }
    'vaquill' { 'VAQUILL_API_KEY' }
    'opencorporates' { 'OPENCORPORATES_API_KEY' }
    'firecrawl' { 'FIRECRAWL_API_KEY' }
    'yuandian' { 'YUANDIAN_API_KEY' }
    'qcc' { 'QCC_API_KEY' }
    'fyopen' { 'FYOPEN_API_KEY' }
}

function Fail2($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Host "CANNOT CHECK: $EnvFile not found. Run install.ps1 once to create it from .env.example." -ForegroundColor Yellow
    exit 2
}

# ── read the key ─────────────────────────────────────────────────────────────
$key = $null
if ($FromFile) {
    if (-not (Test-Path -LiteralPath $FromFile)) { Fail2 "key file not found: $FromFile" }
    # -Raw then trim: a key file from Windows Notepad ends CRLF, and a trailing
    # newline inside the value is invalid in every one of these APIs.
    $key = ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $FromFile))).Trim()
} else {
    Write-Host "Paste the $Connector API key (input is not echoed):" -ForegroundColor Cyan
    $secure = Read-Host -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $key = "$key".Trim()
}

if (-not $key) { Fail2 'the key is empty - nothing written' }
if ($key.Length -lt 8) { Fail2 "the key is only $($key.Length) chars - that is almost certainly a paste error, nothing written" }
# Keys are opaque bearer values. Whitespace or quotes usually mean the value was
# copied with surrounding text, and both corrupt the header it is sent in.
if ($key -match '\s') { Fail2 'the key contains whitespace - it was probably copied with line wrapping; nothing written' }
if ($key -match '^["'']|["'']$') { Fail2 'the key is wrapped in quotes - strip them; nothing written' }

# ── read .env preserving everything else ─────────────────────────────────────
$raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $EnvFile))
$hadBom = ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $EnvFile))[0..2] -join ',') -eq '239,187,191'

$pattern = "(?m)^[ \t]*#?[ \t]*$varName[ \t]*=.*$"
$alreadyActive = [regex]::IsMatch($raw, "(?m)^[ \t]*$varName[ \t]*=[ \t]*\S")
$alreadyCommented = [regex]::IsMatch($raw, "(?m)^[ \t]*#[ \t]*$varName[ \t]*=")

if ($alreadyActive -and -not $Force) {
    # Report the tag, never the value, so this is safe to paste in a ticket.
    Write-Host "[SKIP] $varName is already set in $EnvFile. Re-run with -Force to replace it." -ForegroundColor Yellow
    exit 0
}

$newLine = "$varName=$key"
if ($alreadyActive -or $alreadyCommented) {
    # Replace IN PLACE, commented or not. Appending would leave the old line
    # above the new one, and compose's last-one-wins would make that appear to
    # work while the file accumulated a stale duplicate on every run.
    $raw = [regex]::Replace($raw, $pattern, $newLine)
} else {
    if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $raw += "`r`n" }
    $raw += $newLine + "`r`n"
}

# UTF8 without BOM. `docker compose` rejects a .env starting with a BOM, and
# Set-Content adds one by default on Windows PowerShell.
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $EnvFile), $raw, (New-Object System.Text.UTF8Encoding($false)))

# ── verify the write without printing the value ─────────────────────────────
$check = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $EnvFile))
$m = [regex]::Match($check, "(?m)^[ \t]*$varName[ \t]*=[ \t]*(.*)$")
$written = if ($m.Success) { $m.Groups[1].Value } else { '' }

$sha = [System.Security.Cryptography.SHA256]::Create()
$tag = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($written))) -replace '-', '').Substring(0, 12)
$bomAfter = ([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $EnvFile))[0..2] -join ',') -eq '239,187,191'

Write-Host ''
Write-Host "[OK]   $varName written to $EnvFile" -ForegroundColor Green
Write-Host "       value tag $tag, $($written.Length) chars, BOM=$bomAfter (was $hadBom)" -ForegroundColor DarkGray
if ($bomAfter) { Write-Host '       WARNING: the file has a BOM - docker compose will fail to parse it.' -ForegroundColor Red }

Write-Host ''
Write-Host 'Next, and BOTH steps matter:' -ForegroundColor Cyan
Write-Host "  1. docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-api" -ForegroundColor DarkGray
Write-Host '     A .env change does NOT reach a running container.' -ForegroundColor DarkGray
Write-Host '  2. run a real search - `available=true` only proves a key is PRESENT.' -ForegroundColor DarkGray
Write-Host '     No route calls health_check(), so a wrong key also reports true.' -ForegroundColor DarkGray
exit 0
