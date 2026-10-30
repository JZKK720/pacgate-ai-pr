# Build the client-delivery bundle ZIP for an AIPC install.
#
# WHY THIS EXISTS
#
# The documented packaging step was:
#
#     Compress-Archive deploy/client-bundle/* pacgate-client-bundle-v0.1.0.zip
#
# Measured 2026-10-29, that sweeps in things that must NEVER leave the build
# machine. On Windows a leading dot does not make a file hidden, so `*` matches
# all of these:
#
#     .env                     live PACGATE_DB_PASSWORD, PACGATE_JWT_SECRET, keys
#     .deer-flow-credentials   live deer-flow admin password
#     qm-pacgate/.env          ~15 signing secrets (CORE_SIGNING_SECRET,
#                              AUTH_SIGNING_JWK, MODEL_API_KEY, ...)
#     openviking/ov.conf       this machine's live OpenViking config
#     openviking/workspace/    runtime index + sessions, 7.29 MB / 119 files
#     data/                    2.39 GB - run DB, matter docs, client threads
#
# A first draft of this script still leaked qm-pacgate/.env and openviking/ov.conf
# because it copied those directories wholesale and only checked a hand-written
# list of top-level names. The design below is the correction.
#
# DESIGN
#   1. ALLOWLIST, not denylist: fails closed on a new secret-bearing file.
#   2. Every allowlisted path is asserted to EXIST, so a typo cannot produce a
#      bundle that is missing something the install needs.
#   3. Nested excludes are applied per file while copying, not trusted.
#   4. A forbidden-path assertion runs against the STAGING copy and refuses to
#      write the zip, so even an allowlist edit cannot ship a secret.
#   5. A size ceiling catches "somebody re-added data/".
#   6. qm is taken from its TRACKED source (deploy/qm-pacgate), mirroring
#      setup-qm.ps1, instead of the dirty runtime copy.
#
# Exit codes: 0 = written (or a clean dry run); 1 = a real problem; 2 = cannot check
#
# Usage:
#   pwsh -File scripts/package-bundle.ps1 -WhatIf
#   pwsh -File scripts/package-bundle.ps1
#   pwsh -File scripts/package-bundle.ps1 -Version 0.2.7 -OutFile C:\temp\pacgate.zip

[CmdletBinding()]
param(
    [string]$Version,
    [string]$SourceDir = 'deploy/client-bundle',
    [string]$OutFile,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)
$repoRoot = (Get-Location).Path

if (-not (Test-Path $SourceDir)) {
    Write-Host "CANNOT CHECK: source dir not found: $SourceDir" -ForegroundColor Yellow
    exit 2
}

if (-not $Version) {
    $cargo = Join-Path $repoRoot 'pacgate-ai/Cargo.toml'
    if (Test-Path $cargo) {
        $m = [regex]::Match((Get-Content $cargo -Raw), '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"')
        if ($m.Success) { $Version = $m.Groups['v'].Value }
    }
}
if (-not $Version) {
    Write-Host 'CANNOT CHECK: no version in pacgate-ai/Cargo.toml; pass -Version' -ForegroundColor Yellow
    exit 2
}
if (-not $OutFile) { $OutFile = Join-Path $repoRoot "pacgate-client-bundle-v$Version.zip" }

$IncludeFiles = @(
    'install.ps1'
    'setup-qm.ps1'
    'smoke-deer-flow-outputs.ps1'
    'compose.prod.yaml'
    'compose.bundle.yaml'
    'deer-flow-config.yaml'
    'deer-flow-extensions-config.template.json'
    'ollama-models.txt'
    'README-client.md'
    '.env.example'
)

$IncludeDirs = @(
    'nginx'
    'patches'
    'personas'
    'workflows'
    # Pacgate 2026-10-30: the seeded legal skills deer-flow mounts at
    # .deer-flow/skills/public. Omitting this ships a compose file that mounts a
    # directory the client does not have, and the agent silently starts with no
    # skills - the exact failure this seed corpus exists to prevent.
    'deer-flow-skills'
    # openviking/ is deliberately NOT shipped: ov.conf and workspace/ are
    # git-ignored per-machine runtime state, created by the client's install.
    # qm-pacgate/ is staged from its tracked source - see $StagedDeployments.
)

$IncludeDirExcludes = @(
    'openviking\ov.conf'
    'openviking\ov.conf.bak'
    'openviking\ovcli.settings.conf'
    'openviking\workspace'
)

$StagedDeployments = @(
    @{ Name = 'qm-pacgate'; Source = 'deploy/qm-pacgate' }
)

$Forbidden = @(
    '.env'
    '.deer-flow-credentials'
    'data'
    'openviking\ov.conf'
    'openviking\ovcli.settings.conf'
    'openviking\workspace'
    'qm-pacgate\.env'
    'e2e-audit.py'
    'strength-doc-loop.py'
    'compose.e2e-override.yaml'
)

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('pacgate-bundle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Cleanup {
    if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
}

# Resolve a repo-relative source path (e.g. 'deploy/qm-pacgate').
function Resolve-RepoPath($rel) {
    return (Join-Path $repoRoot ($rel -replace '/', '\'))
}

# ── Preflight: every allowlisted path must exist ────────────────────────────
$missing = @()
foreach ($f in $IncludeFiles) { if (-not (Test-Path (Join-Path $SourceDir $f))) { $missing += $f } }
foreach ($d in $IncludeDirs) { if (-not (Test-Path (Join-Path $SourceDir $d))) { $missing += "$d/" } }
foreach ($dep in $StagedDeployments) { if (-not (Test-Path (Resolve-RepoPath $dep.Source))) { $missing += "$($dep.Source)/" } }
if ($missing.Count -gt 0) {
    Write-Host 'REFUSING: allowlist names paths that do not exist:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host '  A silently missing file produces a bundle that fails on the client.' -ForegroundColor Yellow
    exit 1
}

# ── Stage ───────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path $staging -Force | Out-Null

foreach ($f in $IncludeFiles) {
    Copy-Item (Join-Path $SourceDir $f) (Join-Path $staging $f) -Force
}

foreach ($d in $IncludeDirs) {
    $src = Join-Path $SourceDir $d
    foreach ($item in (Get-ChildItem -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $item.FullName.Substring($src.Length).TrimStart('\', '/')
        $relWithDir = "$d\$rel"
        $skip = $false
        foreach ($ex in $IncludeDirExcludes) {
            if ($relWithDir -eq $ex -or $relWithDir.StartsWith("$ex\")) { $skip = $true; break }
        }
        if ($skip) { continue }
        $dest = Join-Path $staging $relWithDir
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Force
        }
    }
}

foreach ($dep in $StagedDeployments) {
    $depSrc = Resolve-RepoPath $dep.Source
    $dstRoot = Join-Path $staging $dep.Name
    New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null
    $depExclude = @('.env', 'node_modules', '.generated', '.codex')
    foreach ($item in (Get-ChildItem -LiteralPath $depSrc -Force)) {
        if ($depExclude -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $dstRoot -Recurse -Force
    }
}

Set-Content -Path (Join-Path $staging 'VERSION') -Value $Version -Encoding ASCII

# ── Assert nothing forbidden reached the staging copy ───────────────────────
#
# Compare paths RELATIVE to the staging root, not leaf names. A leaf-name test
# flagged .env.example as a leak because its name ends in ".env"; a guard people
# learn to ignore is how a real leak ships.
$leaks = @()
foreach ($bad in $Forbidden) {
    if (Test-Path -LiteralPath (Join-Path $staging $bad)) { $leaks += $bad; continue }
    $hit = Get-ChildItem -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Substring($staging.Length).TrimStart('\', '/') -eq $bad }
    if ($hit) { $leaks += $bad }
}
if ($leaks.Count -gt 0) {
    Write-Host 'REFUSING TO PACKAGE: forbidden path(s) reached the staging copy:' -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host '  These carry live credentials or client data. Do not ship this zip.' -ForegroundColor Yellow
    Cleanup
    exit 1
}

$bytes = (Get-ChildItem $staging -Recurse -File -Force | Measure-Object Length -Sum).Sum
if ($bytes -gt 500MB) {
    Write-Host ('REFUSING TO PACKAGE: staging is {0:N1} MB - that is data, not config.' -f ($bytes / 1MB)) -ForegroundColor Red
    Cleanup
    exit 1
}

$fileCount = (Get-ChildItem $staging -Recurse -File -Force).Count
Write-Host '=== client bundle ===' -ForegroundColor Cyan
Write-Host "  version      : $Version"
Write-Host "  source       : $SourceDir"
Write-Host "  files        : $fileCount"
Write-Host ('  uncompressed : {0:N2} MB' -f ($bytes / 1MB))
Write-Host "  ships        : $($IncludeFiles.Count) file(s) + $($IncludeDirs.Count) dir(s) + staged qm"
Write-Host "  excluded     : $($Forbidden -join ', ')" -ForegroundColor DarkGray

if ($WhatIf) {
    Cleanup
    Write-Host ''
    Write-Host "DRY RUN: would write $OutFile (no staging left behind)." -ForegroundColor Yellow
    exit 0
}

if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
try {
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutFile -CompressionLevel Optimal -Force
} catch {
    Write-Host "FAILED to write the zip: $($_.Exception.Message)" -ForegroundColor Red
    Cleanup
    exit 1
}
Cleanup

if (-not (Test-Path $OutFile)) {
    Write-Host 'FAILED: the zip was not created.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ('  wrote        : {0} ({1:N2} MB)' -f $OutFile, ((Get-Item $OutFile).Length / 1MB)) -ForegroundColor Green
Write-Host '  no .env, no .deer-flow-credentials, no qm secrets, no data/ (asserted)' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, on the client machine:' -ForegroundColor Cyan
Write-Host "  Expand-Archive pacgate-client-bundle-v$Version.zip -DestinationPath C:\pacgate -Force"
Write-Host '  cd C:\pacgate'
Write-Host '  copy .env.example .env     # first install only; fill in YOUR secrets'
Write-Host '  .\install.ps1 -Update      # existing install: applies the new pins'
exit 0
