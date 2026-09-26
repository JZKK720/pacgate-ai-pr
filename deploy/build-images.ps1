# Builds (and optionally pushes) all Pacgate GHCR images in the right order.
#
# Produces the images the client compose references. Pushing requires
# `docker login ghcr.io` (or a GHCR token in CI). See deploy/README-BUILD.md.
#
# NAMESPACE: read from `.github/workflows/build-ghcr.yml` (`GHCR_NAMESPACE`),
# which README-BUILD.md declares the single source of truth and requires every
# compose pin to match. Do NOT hardcode it here. This file previously hardcoded
# `ghcr.io/pacgate-ai/*` - the READ-ONLY MIRROR that publishes NO images - so
# `-Push` sent images to a namespace no compose file pulls from. It was written
# 2026-09-16, one day before plans/016 inverted the roles on 2026-09-18, and
# nothing re-checked it afterwards.
#
# Images built:
#   ghcr.io/<namespace>/pacgate-api:<Tag>              - Rust metadata gateway (12 crates + WASM)
#   ghcr.io/<namespace>/deer-flow-pacgate:<Tag>        - deer-flow backend + Python adapter
#   ghcr.io/<namespace>/deer-flow-frontend-pacgate:<Tag> - deer-flow Next.js research UI (gateway baked in)
#   ghcr.io/<namespace>/pacgate-mcp:<Tag>              - pacgate-api MCP bridge (documents/templates/workflows)
#
# Usage (from repo root):
#   .\deploy\build-images.ps1 -Push            # build + push all four
#   .\deploy\build-images.ps1                  # build only (no push)
#   .\deploy\build-images.ps1 -Tag 0.1.3 -Push
#   .\deploy\build-images.ps1 -Only api,mcp    # build only pacgate-api + pacgate-mcp

param(
    [switch]$Push,
    [string]$Tag = "0.1.3",
    [string]$Only = "",  # comma-separated subset: api,mcp,deerflow,frontend
    # Deliberate override. Empty = read GHCR_NAMESPACE from the workflow.
    [string]$Namespace = ""
)

$ErrorActionPreference = "Stop"
# $PSScriptRoot = c:\pacgate-ai-pr\deploy; repo root is one level up.
$Root = Split-Path -Parent $PSScriptRoot

# Resolve the GHCR namespace from its declared single source of truth.
#
# `GHCR_NAMESPACE` in the release workflow is authoritative: README-BUILD.md says
# "every compose pin must match it", and test-workflow-namespace.ps1 enforces the
# compose side. Reading it here closes the remaining gap instead of introducing a
# second copy of the value that can drift.
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
$Prefix = "ghcr.io/$Ns"

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
Write-Host "  Namespace: $Ns  (from GHCR_NAMESPACE)"
Write-Host "  Selected: $($Selected -join ', ')"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: docker not found." -ForegroundColor Red
    exit 1
}

# ── 1. pacgate-api (Rust) ────────────────────────────────────────────────────
if ($Selected -contains "api") {
    Invoke-Step "pacgate-api" {
        docker build -f (Join-Path $Root "pacgate-ai/Dockerfile") -t "$Prefix/pacgate-api:$Tag" (Join-Path $Root "pacgate-ai")
    }
    if ($Push) { Invoke-Step "push pacgate-api" { docker push "$Prefix/pacgate-api:$Tag" } }
}

# ── 2. pacgate-mcp (Python bridge) ───────────────────────────────────────────
if ($Selected -contains "mcp") {
    Invoke-Step "pacgate-mcp" {
        docker build -f (Join-Path $Root "deploy/pacgate-mcp/Dockerfile") -t "$Prefix/pacgate-mcp:$Tag" (Join-Path $Root "deploy/pacgate-mcp")
    }
    if ($Push) { Invoke-Step "push pacgate-mcp" { docker push "$Prefix/pacgate-mcp:$Tag" } }
}

# ── 3. deer-flow-pacgate (backend + adapter) ────────────────────────────────
if ($Selected -contains "deerflow") {
    Invoke-Step "deer-flow-pacgate" {
        docker build -f (Join-Path $Root "deploy/deer-flow-pacgate/Dockerfile") -t "$Prefix/deer-flow-pacgate:$Tag" $Root
    }
    if ($Push) { Invoke-Step "push deer-flow-pacgate" { docker push "$Prefix/deer-flow-pacgate:$Tag" } }
}

# ── 4. deer-flow-frontend-pacgate (Next.js research UI) ─────────────────────
if ($Selected -contains "frontend") {
    & (Join-Path $PSScriptRoot "build-frontend.ps1") -Push:$Push -Tag $Tag -Namespace $Ns
}

Write-Host "`n=== Build complete ===" -ForegroundColor Green
