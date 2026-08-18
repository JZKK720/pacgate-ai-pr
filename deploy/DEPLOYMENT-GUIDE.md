# Pacgate-ai Deployment Guide

> For Cubecloud engineers deploying to client AI PCs
> Phase 1 — two-machine pilot

This document describes the target client runtime bundle. It does not reflect the workspace root `compose.yaml` and `nginx/default.conf`, which currently only run the static docs surface plus `pacgate-auth`.

## Prerequisites

### On your dev machine (build side)

- Rust 1.88+ (`rustup default stable` — dependencies require 1.88+)
- Docker Desktop with Buildx
- GitHub CLI (`gh`) authenticated to `jzkk720` org
- This repo cloned: `c:\Users\cubecloud-io\github-pr\pacgate-ai-pr`
- Python 3.12+ with `graphifyy` (`pip install graphifyy`) and `openai` (`pip install openai`)
- Ollama running locally for graphify code analysis (see "Running graphify" below)

### On client AI PC (deploy side)

- Windows 11 (AMD GPU or NPU enabled in BIOS)
- Docker Desktop (WSL2 backend, virtualization enabled in BIOS)
- Ollama (native Windows installer from ollama.com)
- Network: LAN accessible from attorney desktops

## Part 1: Build images on your dev machine

### 1.1 Build pacgate-api (Rust)

```powershell
cd c:\Users\cubecloud-io\github-pr\pacgate-ai-pr

# Build the Rust binary in Docker (multi-stage)
docker build -t ghcr.io/jzkk720/pacgate-api:0.1.0 `
  -f pacgate-ai/Dockerfile `
  ./pacgate-ai
```

The Dockerfile is at `pacgate-ai/Dockerfile`. It uses `rust:1.94-bookworm`
(Rust 1.88+ required by dependencies: `time` 0.3.55 and `idna_adapter` 1.2.2
need rustc 1.88+; `zeroize_derive` 1.5.0 uses edition2024 = Rust 1.85+) and
produces the `pacgate-server` binary.

### 1.2 Build deer-flow wrapper

```powershell
# Create the wrapper Dockerfile
# deploy/deer-flow-pacgate/Dockerfile:
#   FROM ghcr.io/bytedance/deer-flow-backend:2.1.0
#   COPY pacgate-adapters/python /app/adapters
#   RUN pip install --no-cache-dir /app/adapters
#   # Install the Pacgate adapter package, then opt in from DeerFlow config.yaml:
#   # memory:
#   #   manager_class: deermem
#   #   backend_config:
#   #     storage_class: pacgate_deerflow_adapter.storage:PacgateMemoryStorage
#   ENV PACGATE_API_URL=http://pacgate-api:8080
#   CMD ["sh", "-c", "cd backend && PYTHONPATH=. uv run --no-sync uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001"]

docker build -t ghcr.io/jzkk720/deer-flow-pacgate:0.1.0 `
  -f deploy/deer-flow-pacgate/Dockerfile `
  .
```

### 1.3 qm — no Docker image to build

qm does NOT run as a Docker Compose service. It runs via `qm up` from the
`deploy/qm-pacgate/` deployment directory. The sandbox bridge tool
(`pacgate-qm`) and skill (`pacgate-workflow`) are already checked in and
validated (`qm check` + `qm sandbox build` pass). Use the `setup-qm.ps1`
script in the client bundle for first-run bootstrap. There is no
`ghcr.io/jzkk720/qm-pacgate` Docker image to build or push.

```powershell
# deploy/qm-pacgate/Dockerfile:
#   FROM ghcr.io/yc-software/qm/core:latest
#   COPY pacgate-adapters/typescript /app/adapters
#   ENV PACGATE_API_URL=http://pacgate-api:8080
#   ENV PACGATE_TENANT_ID=default-firm
#   CMD ["node", "src/index.ts"]
```

### 1.4 Push to GHCR

```powershell
# Login (first time only)
echo $env:GHCR_TOKEN | docker login ghcr.io -u jzkk720 --password-stdin

# Push the two images (qm runs via qm up, not as a Docker image)
docker push ghcr.io/jzkk720/pacgate-api:0.1.0
docker push ghcr.io/jzkk720/deer-flow-pacgate:0.1.0
```

## Part 2: Prepare the client bundle

### 2.1 Directory structure

Create `deploy/client-bundle/` with:

```
client-bundle/
├── compose.prod.yaml
├── nginx/
│   └── default.conf
├── .env.example
├── install.ps1
├── ollama-models.txt
└── README-client.md          ← see User Manual (separate file)
```

### 2.2 compose.prod.yaml

```yaml
services:
  pacgate-db:
    image: postgres:16-alpine
    container_name: pacgate-db
    environment:
      POSTGRES_DB: pacgate
      POSTGRES_USER: pacgate
      POSTGRES_PASSWORD: ${PACGATE_DB_PASSWORD}
    volumes:
      - pacgate-db-data:/var/lib/postgresql/data
    restart: unless-stopped

  pacgate-api:
    image: ghcr.io/jzkk720/pacgate-api:0.1.0
    container_name: pacgate-api
    depends_on: [pacgate-db]
    environment:
      DATABASE_URL: postgres://pacgate:${PACGATE_DB_PASSWORD}@pacgate-db:5432/pacgate
      DATA_DIR: /data/tenants
      PACGATE_JWT_SECRET: ${PACGATE_JWT_SECRET}
      OLLAMA_BASE_URL: http://host.docker.internal:11434
      RUST_LOG: info
    volumes:
      - ./data:/data
    restart: unless-stopped

  deer-flow:
    image: ghcr.io/jzkk720/deer-flow-pacgate:0.1.0
    container_name: deer-flow
    depends_on: [pacgate-api]
    environment:
      PACGATE_API_URL: http://pacgate-api:8080
      PACGATE_TENANT_ID: ${PACGATE_TENANT_ID:-default-firm}
      OLLAMA_BASE_URL: http://host.docker.internal:11434
    volumes:
      - ./data:/data
    restart: unless-stopped

  qm:
    image: ghcr.io/jzkk720/qm-pacgate:0.1.0
    container_name: qm
    depends_on: [pacgate-api]
    environment:
      PACGATE_API_URL: http://pacgate-api:8080
      PACGATE_TENANT_ID: ${PACGATE_TENANT_ID:-default-firm}
      QM_DATABASE_URL: postgres://pacgate:${PACGATE_DB_PASSWORD}@pacgate-db:5432/qm
    volumes:
      - ./data:/data
    restart: unless-stopped

  nginx:
    image: nginx:1.27-alpine
    container_name: pacgate-nginx
    depends_on: [pacgate-api, deer-flow, qm]
    ports:
      - "8081:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    restart: unless-stopped

volumes:
  pacgate-db-data:
```

### 2.3 nginx/default.conf

This is the target client-bundle ingress layout. It is separate from the workspace root `nginx/default.conf`, which currently protects only the static docs site behind `pacgate-auth`.

```nginx
server {
    listen 80;
    server_name _;

    # Landing page (static, served by pacgate-api or a simple index)
    location / {
        proxy_pass http://pacgate-api:8080/;
    }

    # Metadata API (machine-to-machine)
    location /api/ {
        proxy_pass http://pacgate-api:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Research surface -> deer-flow
    location /research/ {
        proxy_pass http://deer-flow:8001/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        # SSE support
        proxy_buffering off;
        proxy_read_timeout 300s;
    }

    # Collaboration surface -> qm
    location /collab/ {
        proxy_pass http://qm:8765/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_read_timeout 300s;
    }
}
```

### 2.4 .env.example

```env
# === Client fills these in ===

# Database password (generate a strong one)
PACGATE_DB_PASSWORD=change-me-to-a-strong-password

# JWT secret (generate: openssl rand -hex 32)
PACGATE_JWT_SECRET=change-me-to-a-random-hex-string

# Tenant ID for this law firm (lowercase, no spaces)
PACGATE_TENANT_ID=default-firm

# === Optional ===
PACGATE_COOKIE_SECURE=false
```

### 2.5 install.ps1

```powershell
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

# 4. Create data directory
if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Write-Host "[OK] Created $DataDir" -ForegroundColor Green
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

# 8. Wait for health
Write-Host "`nWaiting for services to start..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# 9. Show status
Write-Host "`n=== Status ===" -ForegroundColor Cyan
docker compose -f compose.prod.yaml ps

Write-Host "`n=== Pacgate-ai is running ===" -ForegroundColor Green
Write-Host "Open browser to: http://localhost:8081" -ForegroundColor White
Write-Host "  /research/  — Legal research (deer-flow)" -ForegroundColor Gray
Write-Host "  /collab/   — Collaboration (qm)" -ForegroundColor Gray
Write-Host "  /api/      — Metadata API (internal)" -ForegroundColor Gray
Write-Host ""
Write-Host "Manage:" -ForegroundColor Cyan
Write-Host "  docker compose -f compose.prod.yaml logs -f    (view logs)" -ForegroundColor Gray
Write-Host "  docker compose -f compose.prod.yaml down       (stop)" -ForegroundColor Gray
Write-Host "  .\install.ps1 -Update                            (update to new version)" -ForegroundColor Gray
```

### 2.6 ollama-models.txt

```text
# Pacgate-ai required Ollama models
# Pull these before starting the stack:
#   ollama pull nemotron3:33b
#   ollama pull qwen3.6:27b
#   ollama pull qwen3.5:9b

nemotron3:33b
qwen3.6:27b
qwen3.5:9b
```

## Part 3: Deploy to client AI PC

### 3.1 Ship the bundle

Zip `deploy/client-bundle/` and transfer to the client AI PC (USB drive, secure file transfer, or direct access).

### 3.2 On the client AI PC

```powershell
# 1. Install Docker Desktop (if not already)
#    Download from https://docs.docker.com/desktop/

# 2. Install Ollama (if not already)
#    Download from https://ollama.com

# 3. Unzip the bundle
Expand-Archive pacgate-client-bundle-v0.1.0.zip -DestinationPath C:\pacgate

# 4. Configure
cd C:\pacgate
copy .env.example .env
notepad .env    # fill in PACGATE_DB_PASSWORD, PACGATE_JWT_SECRET, PACGATE_TENANT_ID

# 5. Run installer
.\install.ps1
```

### 3.3 Verify

```powershell
# Check containers are running
docker compose -f compose.prod.yaml ps

# Check API health
curl http://localhost:8081/api/health

# Open browser
start http://localhost:8081
```

### 3.4 Firewall (if attorneys connect from other machines)

```powershell
# Open port 8081 for LAN access
New-NetFirewallRule -DisplayName "Pacgate-ai" -Direction Inbound -Protocol TCP -LocalPort 8081 -Action Allow
```

Attorneys then access `http://<ai-pc-ip>:8081` from their desktops.

## Part 4: Updates

When Cubecloud ships a new version:

```powershell
# On client AI PC:
cd C:\pacgate
.\install.ps1 -Update

# This:
# 1. Pulls new images from GHCR (pinned in compose.prod.yaml)
# 2. Restarts containers with new images
# 3. ./data/tenants/ is preserved (volume mount, not in image)
# 4. Postgres data is preserved (named volume)
```

### Bumping versions (Cubecloud side)

```powershell
# 1. Update wrapper Dockerfile FROM lines
#    deploy/deer-flow-pacgate/Dockerfile: FROM ghcr.io/bytedance/deer-flow-backend:2.2.0
#    deploy/qm-pacgate/Dockerfile: FROM ghcr.io/yc-software/qm/core:latest

# 2. Rebuild + push
docker build -t ghcr.io/jzkk720/deer-flow-pacgate:0.2.0 -f deploy/deer-flow-pacgate/Dockerfile .
docker push ghcr.io/jzkk720/deer-flow-pacgate:0.2.0

# 3. Update compose.prod.yaml version pins
#    image: ghcr.io/jzkk720/deer-flow-pacgate:0.2.0

# 4. Ship new bundle to client (or just the updated compose.prod.yaml)
# 5. Client runs: .\install.ps1 -Update
```

## Part 5: Troubleshooting

### Containers won't start

```powershell
# Check logs
docker compose -f compose.prod.yaml logs pacgate-api
docker compose -f compose.prod.yaml logs deer-flow
docker compose -f compose.prod.yaml logs qm

# Common issues:
# - .env missing or has placeholder values
# - Ollama not running (check: ollama list)
# - Port 8081 already in use
```

### Ollama not reachable from containers

```powershell
# Verify Ollama is running
ollama list

# Test from a container
docker run --rm curlimages/curl http://host.docker.internal:11434/api/tags
```

### GPU not detected by Ollama

```powershell
# Check AMD GPU
ollama ps    # should show GPU in the output

# If no GPU, check:
# - AMD Adrenalin driver installed
# - Virtualization enabled in BIOS
# - Docker Desktop WSL2 GPU support (may need preview features)
```

### Data directory issues

```powershell
# Verify data dir is mounted
docker exec pacgate-api ls /data/tenants/

# Should show tenant directories
# If empty, check volume mount in compose.prod.yaml
```

### Schema migration on update

If a new `pacgate-api` version includes a schema migration:

- `pacgate-api` runs the migration automatically on startup
- The migration reads `./data/tenants/` and upgrades in place
- Document this in release notes: "0.2.0 includes an automatic schema migration. No action needed; data is upgraded on first boot."

## Part 6: Running graphify (local Ollama backend)

graphify generates a knowledge graph of the pacgate-ai Rust crates for code navigation and architectural analysis. It uses the local Ollama instance for semantic extraction.

### Prerequisites

- Ollama running locally with at least one model loaded
- `pip install graphifyy openai`

### Windows proxy bypass (critical)

If your machine has a system proxy configured (Clash, V2Ray, etc.), the OpenAI SDK used by graphify will route localhost requests through the proxy and fail with `Error code: 502` or a timeout. You MUST set `NO_PROXY` before running:

```powershell
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = "localhost,127.0.0.1,::1"
```

### Running graphify

```powershell
# Set proxy bypass + Ollama config
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = "localhost,127.0.0.1,::1"
$env:OLLAMA_MODEL = "ornith:9b-q8_0"    # any locally available model
$env:OLLAMA_API_KEY = "ollama"          # dummy key, Ollama doesn't need one
$env:OLLAMA_BASE_URL = "http://localhost:11434/v1"

# Generate knowledge graph (code-only, no viz)
python -m graphify pacgate-ai/crates --no-viz --backend ollama

# Generate report with community names
python -m graphify cluster-only pacgate-ai/crates --backend ollama
```

### Output

```
pacgate-ai/crates/graphify-out/
├── graph.json          ← knowledge graph (nodes, edges, communities, layers, tour)
├── graph.html          ← interactive HTML visualization
├── GRAPH_REPORT.md     ← plain-language report with community hubs and surprising connections
├── manifest.json       ← corpus manifest
└── cache/              ← extraction cache (for incremental updates)
```

### Incremental updates

```powershell
# After code changes, re-extract only new/changed files
$env:NO_PROXY = "localhost,127.0.0.1,::1"; $env:no_proxy = "localhost,127.0.0.1,::1"
$env:OLLAMA_MODEL = "ornith:9b-q8_0"; $env:OLLAMA_API_KEY = "ollama"
$env:OLLAMA_BASE_URL = "http://localhost:11434/v1"
python -m graphify pacgate-ai/crates --update --backend ollama
```

### Verified working configuration

- Model: `ornith:9b-q8_0` (9.5GB)
- Corpus: 15 Rust code files + 1 text file
- Result: 297 nodes, 621 edges, 16 communities
- Cost: $0.00 (local Ollama, no API calls)
- The `offload-arch.exe` warning from ROCm SDK is cosmetic and does not affect output
