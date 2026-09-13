# Pacgate-ai client installer
# Usage: .\install.ps1            (first install)
#        .\install.ps1 -Update     (pull new images, restart)

param([switch]$Update)

$ErrorActionPreference = "Stop"
$DataDir = ".\data"

Write-Host "=== Pacgate-ai Installer ===" -ForegroundColor Cyan

# 1. Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Docker Desktop not found. Install from https://docs.docker.com/desktop/" -ForegroundColor Red
    exit 1
}
docker info *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Docker daemon not running. Start Docker Desktop." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Docker detected" -ForegroundColor Green

# 2. Check Ollama
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Ollama not found. Install from https://ollama.com" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Ollama detected" -ForegroundColor Green

# 3. Check .env
if (-not (Test-Path .env)) {
    if (Test-Path .env.example) {
        Write-Host "ERROR: .env not found. Copy .env.example to .env and fill in passwords." -ForegroundColor Red
        Write-Host "  copy .env.example .env" -ForegroundColor Yellow
        Write-Host "  # then edit .env with your values" -ForegroundColor Yellow
        exit 1
    }
}

# 4. Create data directories
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Write-Host "[OK] Created $DataDir" -ForegroundColor Green
}
$OvDir = ".\openviking"
if (-not (Test-Path $OvDir)) {
    New-Item -ItemType Directory -Path $OvDir -Force | Out-Null
    Write-Host "[OK] Created $OvDir" -ForegroundColor Green
}

# 4b. Render OpenViking config (OPENVIKING_CONF_CONTENT) from template + secrets
$envPath = ".\.env"
$ovTemplate = ".\openviking\ov.conf.template"
if ((Test-Path $envPath) -and (Test-Path $ovTemplate)) {
    $envVars = @{}
    Get-Content $envPath | ForEach-Object {
        if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $envVars[$Matches[1]] = $Matches[2]
        }
    }
    $needsRender = -not (Test-Path env:OPENVIKING_CONF_CONTENT) -and
        (-not ($envVars.ContainsKey('OPENVIKING_CONF_CONTENT') -and $envVars['OPENVIKING_CONF_CONTENT']))
    if ($needsRender -and $envVars.ContainsKey('OPENVIKING_ROOT_API_KEY') -and
        $envVars['OPENVIKING_ROOT_API_KEY'] -notmatch '^change-me') {
        $conf = Get-Content $ovTemplate -Raw
        $conf = $conf.Replace('${OPENVIKING_ROOT_API_KEY}', $envVars['OPENVIKING_ROOT_API_KEY'])
        $minified = ($conf -replace '(?m)^\s*//.*$', '' -replace '\r?\n', '' -replace '\s{2,}', ' ')
        # Append with an explicit leading newline: PowerShell 5.1's Add-Content
        # glues the new line onto the last line when .env has no trailing
        # newline, fusing e.g. OPENVIKING_API_KEY=<val> with
        # OPENVIKING_CONF_CONTENT=<json> on one line (corrupting both).
        $rawEnv = [System.IO.File]::ReadAllText((Resolve-Path $envPath))
        $prefix = if ($rawEnv.Length -eq 0 -or $rawEnv.EndsWith("`n")) { '' } else { "`r`n" }
        [System.IO.File]::AppendAllText(
            (Resolve-Path $envPath),
            "$prefix" + "OPENVIKING_CONF_CONTENT=$minified`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host "[OK] Rendered OPENVIKING_CONF_CONTENT into .env" -ForegroundColor Green
    }

    # Render deer-flow MCP extensions config (gitignored; compose mounts it :ro).
    # Without this, a fresh clone gets a Docker-created directory at the mount
    # path and deer-flow's OpenViking recall (OV-2a) silently fails.
    $dfTemplate = ".\deer-flow-extensions-config.template.json"
    $dfRendered = ".\deer-flow-extensions-config.json"
    if ((Test-Path $dfTemplate) -and -not (Test-Path $dfRendered)) {
        # The template's openviking entry uses ${OPENVIKING_ROOT_API_KEY} (the
        # server's root key), NOT ${OPENVIKING_API_KEY}. Replacing the wrong
        # placeholder is a no-op and leaves a literal ${...} in the rendered
        # file, which makes openviking return 401 and rolls back the entire MCP
        # tool load (deer-flow uses asyncio.gather). See handbook finding #2.
        if ($envVars['OPENVIKING_ROOT_API_KEY'] -and $envVars['OPENVIKING_ROOT_API_KEY'] -notmatch '^change-me') {
            $df = Get-Content $dfTemplate -Raw
            $df = $df.Replace('${OPENVIKING_ROOT_API_KEY}', $envVars['OPENVIKING_ROOT_API_KEY'])
            # Write BOM-free UTF-8. PowerShell 5.1's `Set-Content -Encoding UTF8`
            # prepends a UTF-8 BOM, which deer-flow's JSON parser rejects
            # ("Unexpected UTF-8 BOM"). Use .NET WriteAllText with a no-BOM
            # UTF8Encoding so the rendered config is valid JSON.
            [System.IO.File]::WriteAllText(
                (Join-Path $PWD $dfRendered),
                $df,
                [System.Text.UTF8Encoding]::new($false)
            )
            Write-Host "[OK] Rendered $dfRendered from template" -ForegroundColor Green
        } else {
            Write-Host "ERROR: $dfRendered missing and OPENVIKING_ROOT_API_KEY is unset or still 'change-me'." -ForegroundColor Red
            Write-Host "  Set OPENVIKING_ROOT_API_KEY in .env, then re-run. compose.prod.yaml mounts this" -ForegroundColor Yellow
            Write-Host "  file :ro, so a missing file breaks deer-flow memory recall (OV-2a)." -ForegroundColor Yellow
            exit 1
        }
    }
}

# 5. Pull models (first install only)
if (-not $Update) {
    Write-Host "`nPulling Ollama models (this takes a while on first run)..." -ForegroundColor Cyan
    foreach ($model in Get-Content ollama-models.txt) {
        if ($model -and -not $model.StartsWith("#")) {
            Write-Host "  Pulling $model..." -ForegroundColor Yellow
            ollama pull $model
        }
    }
    Write-Host "[OK] Models pulled" -ForegroundColor Green
}

# 6. Pull Docker images
Write-Host "`nPulling Docker images..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml pull
Write-Host "[OK] Images pulled" -ForegroundColor Green

# 7. Start stack
Write-Host "`nStarting Pacgate-ai..." -ForegroundColor Cyan
docker compose -f compose.prod.yaml up -d
Write-Host "[OK] Stack running" -ForegroundColor Green

# 7b. Reload nginx config if it changed. The nginx service uses the stock
# nginx:1.27-alpine image with a BIND-MOUNTED ./nginx/default.conf, so `git
# pull` brings in a new config but `up -d` does NOT recreate the container or
# reload the file. Reloading makes AIPC2 pick up ingress/proxy changes (e.g.
# the resolver + variable proxy_pass fix) without a full recreate.
Write-Host "`nReloading nginx config..." -ForegroundColor Cyan
docker exec pacgate-nginx nginx -t *>$null
if ($LASTEXITCODE -eq 0) {
    docker exec pacgate-nginx nginx -s reload
    Write-Host "[OK] nginx config reloaded" -ForegroundColor Green
} else {
    Write-Host "[WARN] nginx config test failed; leaving running config unchanged" -ForegroundColor Yellow
}

# 8. Wait for health
Write-Host "`nWaiting for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# 9. Show status
Write-Host "`n=== Status ===" -ForegroundColor Cyan
docker compose -f compose.prod.yaml ps

Write-Host "`n=== Pacgate-ai is running ===" -ForegroundColor Green
Write-Host "Open browser to: http://localhost:8089" -ForegroundColor White
Write-Host "  /          - Landing page" -ForegroundColor Gray
Write-Host "  /api/      - Metadata API (internal)" -ForegroundColor Gray
Write-Host "  /research/  - Legal research (deer-flow)" -ForegroundColor Gray
Write-Host ""
Write-Host "QM (co-working workspace) runs separately:" -ForegroundColor Cyan
Write-Host "  1. Run .\setup-qm.ps1 to bootstrap qm" -ForegroundColor Gray
Write-Host "  2. Then: cd qm-pacgate && npm exec qm -- up" -ForegroundColor Gray
Write-Host "  3. Access: http://localhost:8182" -ForegroundColor Gray
Write-Host ""
Write-Host "Manage:" -ForegroundColor Cyan
Write-Host "  docker compose -f compose.prod.yaml logs -f    (view logs)" -ForegroundColor Gray
Write-Host "  docker compose -f compose.prod.yaml down       (stop)" -ForegroundColor Gray
Write-Host "  .\install.ps1 -Update                            (update to new version)" -ForegroundColor Gray