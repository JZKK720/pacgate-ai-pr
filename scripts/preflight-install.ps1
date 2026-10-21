# Pre-flight check for a machine that is about to install Pacgate-ai.
#
# WHY THIS EXISTS
#   The install itself is one command, but every failure it can hit is cheaper to
#   find BEFORE it starts: a missing prerequisite, a weak placeholder password, a
#   private package in GHCR, or hardware that will pick the wrong residency tier.
#   Finding those mid-install means a half-built stack and a confusing error;
#   finding them here means one line of output and no container churn.
#
#   This is read-only. It starts nothing, writes nothing, changes no setting.
#
# Usage:
#   pwsh -File scripts\preflight-install.ps1
#   pwsh -File scripts\preflight-install.ps1 -Tag 0.2.0
#
# Exit codes: 0 = ready;  1 = blocker found (read the FAIL lines);  2 = cannot check

[CmdletBinding()]
param(
    [string]$Tag = '',
    [string]$BundleDir = ''
)

$ErrorActionPreference = 'Continue'

$script:blockers = 0
$script:warnings = 0
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warnings++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:blockers++ }
function Info($m) { Write-Host "  $m" -ForegroundColor DarkGray }

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BundleDir) { $BundleDir = Join-Path $repoRoot 'deploy/client-bundle' }

# Default the tag to the one this checkout's compose files pin, so this cannot
# silently check the wrong release.
if (-not $Tag) {
    $prodCompose = Join-Path $BundleDir 'compose.prod.yaml'
    if (Test-Path $prodCompose) {
        $m = [regex]::Match((Get-Content $prodCompose -Raw), 'pacgate-api:([0-9]+\.[0-9]+\.[0-9]+)')
        if ($m.Success) { $Tag = $m.Groups[1].Value }
    }
}
if (-not $Tag) { $Tag = 'unknown' }

Write-Host ''
Write-Host "=== Pacgate-ai pre-flight  (target tag $Tag) ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. prerequisites ─────────────────────────────────────────────────────────
Write-Host '1. prerequisites' -ForegroundColor White
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { Bad 'docker not found - install Docker Desktop' }
else {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { Bad 'docker is installed but the daemon is not running - start Docker Desktop' }
    else { Ok 'docker present and daemon running' }
}

$ollama = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollama) { Bad 'ollama not found - install from https://ollama.com' }
else { Ok 'ollama present' }

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Warn 'git not found - install.ps1 -Update will not be able to refresh the repo' }
else { Ok 'git present' }

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Warn 'python not found - the installer will report the Ollama app context_length as unknown (it only READS it)'
} else { Ok 'python present (used read-only to inspect the Ollama app setting)' }
Write-Host ''

# ── 2. hardware and the residency tier it selects ────────────────────────────
Write-Host '2. hardware -> residency tier' -ForegroundColor White
$sysGiB = 0
try { $sysGiB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 1) } catch { }
$vramGiB = 0
try {
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $raw = $p.'HardwareInformation.qwMemorySize'
        if ($raw -and [int64]$raw -gt 0) {
            $g = [math]::Round([int64]$raw / 1GB, 1)
            if ($g -lt 64) { $vramGiB = [math]::Max($vramGiB, $g) }   # ignore UMA carve-outs
        }
    }
} catch { }

if ($sysGiB -ge 56) {
    if ($vramGiB -ge 24) { $tier='high'; $ctx=65536; $max=3 }
    else { $tier='big-ram-small-vram'; $ctx=32768; $max=2 }
} elseif ($sysGiB -ge 24) { $tier='standard'; $ctx=32768; $max=2 }
else { $tier='constrained'; $ctx=16384; $max=1 }

Info ("OS-visible RAM     : {0} GiB" -f $sysGiB)
Info ("discrete VRAM      : {0} GiB  (0 or huge = integrated/UMA, ignored)" -f $vramGiB)
Info ("selected tier      : {0}  -> ctx {1}, max {2} loaded models" -f $tier, $ctx, $max)
if ($sysGiB -lt 24) {
    Warn ("only {0} GiB visible to Windows - the stack needs roughly 4.1 GiB for containers plus one model" -f $sysGiB)
}
# Surface the UMA trap explicitly: a machine whose DIMMs are large but whose
# Windows view is small will look 'wrong' against its spec sheet.
if ($sysGiB -lt 56) {
    Info '  (If this machine has 64 GB+ of DIMMs, the iGPU UMA carve-out is taken before Windows boots and'
    Info '   the tier correctly follows what Windows sees, because that is what Ollama binds against.)'
}
Write-Host ''

# ── 3. Ollama: signed in, because the main model is cloud ────────────────────
Write-Host '3. ollama account' -ForegroundColor White
$ollamaUp = $false
try { $null = Invoke-RestMethod -Uri 'http://localhost:11434/api/version' -TimeoutSec 3; $ollamaUp = $true } catch { }
if (-not $ollamaUp) {
    Warn 'ollama server is not answering on 11434 - it usually starts with the desktop app; the installer restarts it anyway'
} else {
    Ok 'ollama server answering on 11434'
    # The MAIN model is a :cloud tag: no local weights, inference via ollama.com.
    $hasCloud = $false
    try {
        $list = & ollama list 2>$null | Out-String
        if ($list -match ':cloud') { $hasCloud = $true }
    } catch { }
    if ($hasCloud) { Ok 'at least one :cloud tag is present (sign-in appears done)' }
    else { Warn 'no :cloud tag present - run `ollama signin` before installing; the MAIN model is deepseek-v4.1-flash:cloud' }
}
Write-Host ''

# ── 4. .env: exists, and no placeholder passwords ────────────────────────────
Write-Host '4. .env' -ForegroundColor White
$envPath = Join-Path $BundleDir '.env'
if (-not (Test-Path $envPath)) {
    Bad "no .env at $envPath - copy .env.example to .env and fill in the passwords; the installer will not create it"
} else {
    Ok '.env exists'
    $envText = Get-Content $envPath -Raw
    $required = @('PACGATE_DB_PASSWORD', 'PACGATE_JWT_SECRET', 'PACGATE_API_PASSWORD')
    foreach ($k in $required) {
        $m = [regex]::Match($envText, "(?m)^\s*$k\s*=\s*(.*)$")
        if (-not $m.Success) { Bad "$k is missing from .env" }
        elseif ($m.Groups[1].Value.Trim() -eq '') { Bad "$k is empty in .env" }
        elseif ($m.Groups[1].Value -match 'change-me|changeme|password|^\s*$') {
            Bad "$k still holds a placeholder ('$($m.Groups[1].Value.Trim())') - generate a real value"
        }
        else { Ok "$k is set and not a placeholder" }
    }
    # OPENVIKING_ROOT_API_KEY at its placeholder makes OpenViking boot-loop 503.
    $ov = [regex]::Match($envText, "(?m)^\s*OPENVIKING_ROOT_API_KEY\s*=\s*(.*)$")
    if ($ov.Success -and $ov.Groups[1].Value -match 'change-me') {
        Warn 'OPENVIKING_ROOT_API_KEY is still the placeholder - OpenViking will boot-loop /health 503 until it is a real value'
    }
    # These two are written by the installer; a stale value from another machine
    # would point at a tag that does not exist here.
    foreach ($k in @('PACGATE_MODEL_MID', 'PACGATE_MODEL_LOW')) {
        $m = [regex]::Match($envText, "(?m)^\s*$k\s*=\s*(.*)$")
        if ($m.Success) { Info "$k = $($m.Groups[1].Value.Trim())  (installer-managed; will be re-pointed at this machine's pins)" }
    }
}
Write-Host ''

# ── 5. images: public, so no docker login is needed ──────────────────────────
Write-Host "5. GHCR images for $Tag (anonymous pull - the client path assumes no docker login)" -ForegroundColor White
$images = @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate', 'ocr-service')
$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
foreach ($img in $images) {
    $code = '000'
    $tmpBody = Join-Path ([System.IO.Path]::GetTempPath()) ("pf-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + ".json")
    try {
        $tok = (& curl.exe -s --max-time 15 "https://ghcr.io/token?scope=repository:jzkk720/${img}:pull" | ConvertFrom-Json).token
        if ($tok) {
            # Write the body to a temp file: `-o $null` does NOT suppress curl's
            # output under PowerShell (it writes the manifest to stdout), which
            # made the status code check silently useless.
            $code = (& curl.exe -s -o $tmpBody -w "%{http_code}" --max-time 20 `
                        -H "Authorization: Bearer $tok" -H "Accept: $accept" `
                        "https://ghcr.io/v2/jzkk720/${img}/manifests/$Tag")
        }
    } catch { } finally {
        Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
    }
    switch ("$code".Trim()) {
        '200' { Ok "$img :$Tag public" }
        '401' { Bad "$img :$Tag is PRIVATE - flip the package to public in the GitHub UI (the API /visibility route 404s even with write:packages)" }
        '404' { Bad "$img :$Tag not found - the build did not publish this tag" }
        default { Bad "$img :$Tag could not be verified (HTTP '$code') - do not assume it is pullable" }
    }
}
Write-Host ''

# ── 6. ports ─────────────────────────────────────────────────────────────────
Write-Host '6. host ports the stack binds' -ForegroundColor White
foreach ($p in @(8089, 8090, 8181, 11434)) {
    $inUse = $false
    try {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { $inUse = $true }
    } catch { }
    if ($p -eq 11434) {
        if ($inUse) { Ok "11434 in use (expected: Ollama)" } else { Warn '11434 is free - Ollama is not listening yet' }
    }
    elseif ($inUse) {
        # 8089 may legitimately be an older pacgate-api from a previous install.
        Warn "$p is already listening - if a previous Pacgate stack is running, stop it first or the new containers will fail to bind"
    }
    else { Ok "$p free" }
}
Write-Host ''

# ── summary ──────────────────────────────────────────────────────────────────
Write-Host '=== summary ===' -ForegroundColor Cyan
Write-Host ("  blockers: {0}    warnings: {1}" -f $script:blockers, $script:warnings)
if ($script:blockers -gt 0) {
    Write-Host '  NOT READY - fix the [FAIL] lines above before running install.ps1' -ForegroundColor Red
    exit 1
}
Write-Host '  READY - next:' -ForegroundColor Green
Write-Host '    cd deploy\client-bundle' -ForegroundColor DarkGray
Write-Host '    .\install.ps1' -ForegroundColor DarkGray
Write-Host '  then verify with:' -ForegroundColor Green
Write-Host '    pwsh -File scripts\run-all-checks.ps1' -ForegroundColor DarkGray
exit 0
