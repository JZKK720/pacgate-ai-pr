# Builds (and optionally pushes) the Pacgate deer-flow frontend wrapper image.
#
# Clones the bytedance/deer-flow frontend source at a pinned tag, then builds
# the Next.js UI with DEER_FLOW_INTERNAL_GATEWAY_BASE_URL baked in at build time
# so the /api/* rewrites target the pacgate backend (deer-flow:8001).
#
# Usage (from repo root):
#   .\deploy\build-frontend.ps1                      # build only (tagged ghcr.io/<namespace>/deer-flow-frontend-pacgate)
#   .\deploy\build-frontend.ps1 -Push                # build + push to GHCR (needs docker login)
#   .\deploy\build-frontend.ps1 -Tag 0.1.1           # custom tag
#   .\deploy\build-frontend.ps1 -GatewayUrl http://deer-flow:8001
#
# NAMESPACE: defaults to `GHCR_NAMESPACE` in .github/workflows/build-ghcr.yml,
# which README-BUILD.md declares the single source of truth. This file previously
# hardcoded `ghcr.io/pacgate-ai/*` - the READ-ONLY MIRROR that publishes NO
# images. build-images.ps1 passes the resolved value in explicitly.

param(
    [switch]$Push,
    [string]$Tag = "0.1.0",
    [string]$GatewayUrl = "http://deer-flow:8001",
    [string]$DeerFlowVersion = "v2.0.0",
    [string]$Namespace = ""
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot = c:\pacgate-ai-pr\deploy; repo root is one level up.
$Root = Split-Path -Parent $PSScriptRoot
$SrcDir = Join-Path $Root "deploy/deer-flow-src"
$FrontendDir = Join-Path $SrcDir "frontend"

# Resolve the GHCR namespace from its declared single source of truth.
function Resolve-GhcrNamespace([string]$RepoRoot, [string]$Override) {
    if ($Override) { return $Override }
    $wf = Join-Path $RepoRoot ".github/workflows/build-ghcr.yml"
    if (Test-Path $wf) {
        $m = Select-String -Path $wf -Pattern '^\s*GHCR_NAMESPACE:\s*(\S+)' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    Write-Host "WARN: could not read GHCR_NAMESPACE from $wf; using fallback 'jzkk720'." -ForegroundColor Yellow
    return "jzkk720"
}

$Ns = Resolve-GhcrNamespace $Root $Namespace
$Image = "ghcr.io/$Ns/deer-flow-frontend-pacgate:$Tag"

Write-Host "=== Pacgate deer-flow frontend build ===" -ForegroundColor Cyan
Write-Host "  Repo root : $Root"
Write-Host "  Source dir: $SrcDir"
Write-Host "  Version   : $DeerFlowVersion"
Write-Host "  Tag       : $Tag"
Write-Host "  Namespace : $Ns  (from GHCR_NAMESPACE)"
Write-Host "  Gateway   : $GatewayUrl"

# 1. Ensure docker is available
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: docker not found." -ForegroundColor Red
    exit 1
}

# 2. Clone the upstream deer-flow frontend source at the pinned tag.
if (-not (Test-Path $FrontendDir)) {
    Write-Host "[1/3] Cloning bytedance/deer-flow $DeerFlowVersion (frontend only)..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $SrcDir -Force | Out-Null
    git clone --depth 1 --branch $DeerFlowVersion --filter=blob:none --sparse https://github.com/bytedance/deer-flow.git $SrcDir
    git -C $SrcDir sparse-checkout set frontend
} else {
    Write-Host "[1/3] Frontend source already present at $FrontendDir" -ForegroundColor Cyan
}

# 2b. Apply PacGate frontend source overrides (persist across re-clones of the
# source tree). We copy tracked files over the cloned tree because these
# changes contain long Chinese strings that break git-patch parsing. Each file
# under deploy/frontend-patches/files/ mirrors the path in src/.
$PatchFiles = Join-Path $Root "deploy/frontend-patches/files"
if (Test-Path $PatchFiles) {
    Write-Host "[1b/3] Applying PacGate frontend source overrides..." -ForegroundColor Cyan
    $overrides = Get-ChildItem -Path $PatchFiles -Recurse -File
    foreach ($file in $overrides) {
        $rel = $file.FullName.Substring($PatchFiles.Length).TrimStart('\', '/')
        $target = Join-Path $FrontendDir $rel
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($file.FullName))
        Write-Host "  OK: $rel" -ForegroundColor Green
    }
}

# 3. Build the image.
Write-Host "[2/3] Building $Image ..." -ForegroundColor Cyan
docker build `
    -f (Join-Path $Root "deploy/deer-flow-frontend-pacgate/Dockerfile") `
    --build-arg "DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=$GatewayUrl" `
    -t $Image `
    $Root
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: docker build failed." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Built $Image" -ForegroundColor Green

# 4. Push if requested.
if ($Push) {
    Write-Host "[3/3] Pushing to GHCR..." -ForegroundColor Cyan
    docker push $Image
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: docker push failed. Ensure you are logged in: docker login ghcr.io" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Pushed $Image" -ForegroundColor Green
} else {
    Write-Host "[3/3] Skipping push (use -Push to push)." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
