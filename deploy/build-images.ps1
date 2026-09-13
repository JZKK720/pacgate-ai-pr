# Builds (and optionally pushes) all Pacgate GHCR images in the right order.
#
# Produces the images the client compose references. Pushing requires
# `docker login ghcr.io` (or a GHCR token in CI). See deploy/README-BUILD.md.
#
# Images built:
#   ghcr.io/pacgate-ai/pacgate-api:<Tag>              — Rust metadata gateway (12 crates + WASM)
#   ghcr.io/pacgate-ai/deer-flow-pacgate:<Tag>        — deer-flow backend + Python adapter
#   ghcr.io/pacgate-ai/deer-flow-frontend-pacgate:<Tag> — deer-flow Next.js research UI (gateway baked in)
#   ghcr.io/pacgate-ai/pacgate-mcp:<Tag>              — pacgate-api MCP bridge (documents/templates/workflows)
#
# Usage (from repo root):
#   .\deploy\build-images.ps1 -Push            # build + push all four
#   .\deploy\build-images.ps1                  # build only (no push)
#   .\deploy\build-images.ps1 -Tag 0.1.3 -Push
#   .\deploy\build-images.ps1 -Only api,mcp    # build only pacgate-api + pacgate-mcp

param(
    [switch]$Push,
    [string]$Tag = "0.1.3",
    [string]$Only = ""  # comma-separated subset: api,mcp,deerflow,frontend
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot = c:\pacgate-ai-pr\deploy; repo root is one level up.
$Root = Split-Path -Parent $PSScriptRoot

function Invoke-Step([string]$Label, [scriptblock]$Cmd) {
    Write-Host "=== $Label ===" -ForegroundColor Cyan
    & $Cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: $Label failed (exit $LASTEXITCODE)." -ForegroundColor Red
        exit 1
    }
}

$Selected = if ($Only) { $Only.Split(',') | ForEach-Object { $_.Trim() } } else { @("api", "mcp", "deerflow", "frontend") }

Write-Host "=== Pacgate GHCR build ($Tag) ===" -ForegroundColor Cyan
Write-Host "  Root: $Root"
Write-Host "  Selected: $($Selected -join ', ')"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: docker not found." -ForegroundColor Red
    exit 1
}

# ── 1. pacgate-api (Rust) ────────────────────────────────────────────────────
if ($Selected -contains "api") {
    Invoke-Step "pacgate-api" {
        docker build -f (Join-Path $Root "pacgate-ai/Dockerfile") -t "ghcr.io/pacgate-ai/pacgate-api:$Tag" (Join-Path $Root "pacgate-ai")
    }
    if ($Push) { Invoke-Step "push pacgate-api" { docker push "ghcr.io/pacgate-ai/pacgate-api:$Tag" } }
}

# ── 2. pacgate-mcp (Python bridge) ───────────────────────────────────────────
if ($Selected -contains "mcp") {
    Invoke-Step "pacgate-mcp" {
        docker build -f (Join-Path $Root "deploy/pacgate-mcp/Dockerfile") -t "ghcr.io/pacgate-ai/pacgate-mcp:$Tag" (Join-Path $Root "deploy/pacgate-mcp")
    }
    if ($Push) { Invoke-Step "push pacgate-mcp" { docker push "ghcr.io/pacgate-ai/pacgate-mcp:$Tag" } }
}

# ── 3. deer-flow-pacgate (backend + adapter) ────────────────────────────────
if ($Selected -contains "deerflow") {
    Invoke-Step "deer-flow-pacgate" {
        docker build -f (Join-Path $Root "deploy/deer-flow-pacgate/Dockerfile") -t "ghcr.io/pacgate-ai/deer-flow-pacgate:$Tag" $Root
    }
    if ($Push) { Invoke-Step "push deer-flow-pacgate" { docker push "ghcr.io/pacgate-ai/deer-flow-pacgate:$Tag" } }
}

# ── 4. deer-flow-frontend-pacgate (Next.js research UI) ─────────────────────
if ($Selected -contains "frontend") {
    & (Join-Path $PSScriptRoot "build-frontend.ps1") -Push:$Push -Tag $Tag
}

Write-Host "`n=== Build complete ===" -ForegroundColor Green
