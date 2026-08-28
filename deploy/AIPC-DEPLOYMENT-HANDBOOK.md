# Pacgate AI - Two-AIPC Deployment Handbook

> Clone the repo on each machine, run the same install steps, and both machines become fully operational with deer-flow research and qm collaboration.
> Version 0.1.1 - 2026-08-19
> Prerequisites: Docker Desktop, Ollama, Node.js 24+, and all models already installed on both AIPCs.

## Architecture: two identical machines

Both AIPCs run the complete stack:

```
Each AIPC machine:
  nginx :8081  -> pacgate-api :8080 (Rust metadata API)
                -> deer-flow  :8001 (research workspace)
  Postgres :5432 (local metadata DB)
  qm :8182 (co-working workspace, runs via `qm up`)
  Ollama :11434 (native, GPU/NPU)
```

Each machine is self-contained and independently operational. Lawyers on either machine can use both research mode (deer-flow at `http://localhost:8081/research/`) and collaboration mode (qm at `http://localhost:8182`) without depending on the other machine.

If you later want shared matter data across both machines, connect them with a private mesh (Tailscale or WireGuard) and decide on a sync or single-authority model. That is a post-pilot decision, not a deployment prerequisite.

## What you need before starting

- GitHub access to `JZKK720/pacgate-ai-pr` (private repo)
- Docker Desktop running on both AIPCs
- Ollama running on both AIPCs with models pre-pulled
- Node.js 24+ installed on both AIPCs (for qm)
- The `pacgate-api` GHCR image rebuilt with connector fixes (see Stage 0)

## Stage 0: Rebuild the API image (dev machine, one-time)

The current `ghcr.io/jzkk720/pacgate-api:0.1.1` image has a container-networking bug: the LLM router hardcodes `localhost:11434`, which fails inside Docker. Version `0.1.2` fixes this (router honors `OLLAMA_BASE_URL`, per-tenant model overrides are applied). Rebuild before deploying so both AIPCs pull the corrected runtime.

On your dev machine:

```powershell
cd c:\Users\cubecloud-io\github-pr\pacgate-ai-pr

docker build -t ghcr.io/jzkk720/pacgate-api:0.1.2 -f pacgate-ai/Dockerfile ./pacgate-ai
docker push ghcr.io/jzkk720/pacgate-api:0.1.2
```

The `compose.prod.yaml` in this repo now references `pacgate-api:0.1.2`.

The `deer-flow-pacgate:0.1.0` image does not need rebuilding. It is a thin wrapper on top of the upstream deer-flow backend image, and the wrapper layer has not changed.

> **Port conflict note:** the stack binds nginx to host port `8081`. If that port is already in use on the machine, edit the `ports:` entry for `nginx` in `deploy/client-bundle/compose.prod.yaml` (e.g. `"8089:80"`) and use the new port in all verification URLs below.

## Stage 1: Clone the repo on each AIPC

On both machines:

```powershell
cd C:\
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
```

If the repo is private and GitHub prompts for credentials, use a personal access token or the GitHub CLI (`gh auth login`).

## Stage 2: Deploy the core stack (both machines, identical steps)

Run these steps on each AIPC. The Docker Compose stack starts pacgate-api, Postgres, nginx, and deer-flow.

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
copy .env.example .env
notepad .env
```

Fill in these values:

```
PACGATE_DB_PASSWORD=<generate a strong password>
PACGATE_JWT_SECRET=<generate a random hex string>
PACGATE_TENANT_ID=pacgate-law
```

Generate secrets if you need them:

```powershell
# DB password
-join ((1..16) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })

# JWT secret
-join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
```

Run the installer:

```powershell
.\install.ps1
```

The installer pulls GHCR images, starts the Docker Compose stack, and pulls Ollama models listed in `ollama-models.txt`. If models are already pulled, this step is fast.

Verify the core stack:

```powershell
docker compose -f compose.prod.yaml ps
curl http://localhost:8081/health
```

Expected: all four containers running (pacgate-db, pacgate-api, deer-flow, nginx) and `/health` returns `ok`.

## Stage 3: Seed the tenant and register users (both machines)

On each machine, seed the default tenant and register the admin user:

```powershell
# Seed the tenant
docker exec pacgate-db psql -U pacgate -c "INSERT INTO tenants (name, slug) VALUES ('Pacgate Law', 'pacgate-law');"

# Register the admin user
$body = @{email="admin@pacgate-law.com"; password="<strong-password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8081/api/auth/register" -Method POST -Body $body -ContentType "application/json"
```

Register a qm bridge service account (needed by qm to authenticate with pacgate-api):

```powershell
$body = @{email="qm-bridge@pacgate.local"; password="<strong-bridge-password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8081/api/auth/register" -Method POST -Body $body -ContentType "application/json"
```

## Stage 4: Bootstrap qm (both machines, identical steps)

qm runs separately from the Docker Compose stack. Bootstrap it on each machine after the core stack is healthy.

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\setup-qm.ps1
```

The script prompts for:
- Administrator work email (lowercased)
- Pacgate bridge email: `qm-bridge@pacgate.local`
- Pacgate bridge password: the one you registered in Stage 3

The script generates signing secrets, creates `.env` in the qm-pacgate directory, validates the config with `qm check`, and builds the sandbox image with `qm sandbox build`.

Start qm:

```powershell
cd C:\pacgate-ai-pr\deploy\qm-pacgate
npm exec qm -- up
```

Verify qm:

```powershell
# Open http://localhost:8182
# Sign in with the admin email
# Send a test message
# Ask: "List available pacgate workflows"
```

## Stage 5: Verify deer-flow (both machines)

On each machine, verify the research workspace:

```powershell
# Open http://localhost:8081/research/
# Select or create a matter
# Ask: "Summarize recent force majeure case law in China"
# Verify: response includes citations
# Verify: response is saved to matter memory
```

## Stage 6: Smoke test checklist (both machines)

Run this checklist on each AIPC independently.

### Core stack

- [ ] `docker compose -f compose.prod.yaml ps` shows 4 services up
- [ ] `curl http://localhost:8081/health` returns `ok`
- [ ] Postgres has the `pacgate-law` tenant
- [ ] Admin user can log in at `http://localhost:8081/api/auth/login`
- [ ] deer-flow returns a real research response at `http://localhost:8081/research/`

### qm collaboration

- [ ] `npm exec qm -- status` shows qm running
- [ ] `http://localhost:8182` loads the qm web UI
- [ ] Admin can sign in
- [ ] qm can list Pacgate workflow categories
- [ ] qm can execute one Pacgate workflow through the bridge

### Ollama

- [ ] `ollama list` shows the required models
- [ ] deer-flow can call Ollama for inference
- [ ] qm can call Ollama for inference

### Data

- [ ] `./data/tenants/` directory exists and is writable
- [ ] Document upload works through the API
- [ ] Matter memory persists after a deer-flow research run

## Managing the stack after deployment

### Start and stop

```powershell
# Start core stack
docker compose -f compose.prod.yaml up -d

# Stop core stack
docker compose -f compose.prod.yaml down

# Start qm
cd C:\pacgate-ai-pr\deploy\qm-pacgate
npm exec qm -- up

# Stop qm
npm exec qm -- down
```

### Update to a new version

```powershell
cd C:\pacgate-ai-pr
git pull
cd deploy\client-bundle
.\install.ps1 -Update
```

The update pulls new GHCR images and restarts containers. Data is preserved:
- `./data/tenants/` (volume mount) - matters, documents, memory
- Postgres data (named volume) - metadata database

### Switch models

deer-flow (research workspace):
1. Edit `deer-flow-config.yaml` - reorder the `models` list (first entry = default)
2. Restart: `docker compose -f compose.prod.yaml restart deer-flow`

qm (co-working workspace):
1. Edit `qm-pacgate/qm.config.jsonc` - change `MODEL_NAME`
2. Restart: `cd qm-pacgate && npm exec qm -- down && npm exec qm -- up`

### Register new users

```powershell
$body = @{email="<user>@pacgate-law.com"; password="<password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8081/api/auth/register" -Method POST -Body $body -ContentType "application/json"
```

### Backup the database

```powershell
docker exec pacgate-db pg_dump -U pacgate pacgate > backup.sql
```

### Check logs

```powershell
docker compose -f compose.prod.yaml logs -f pacgate-api
docker compose -f compose.prod.yaml logs -f deer-flow
```

## Known limitations

- Each machine has its own independent Postgres and `./data/tenants/` directory. Matter data is not shared between machines unless you later add a private mesh and a sync or single-authority model.
- The PkuLaw connector token is expired. Regenerate it at `https://mcp.pkulaw.com` and set `PKULAW_API_KEY` in `.env` if China-law search is needed during the pilot.
- Four WASM crates (citation-check, clause-parser, doc-validator, rule-engine) remain stubs. These are future-blueprint work and do not affect Phase 1 pilot functionality.
- **Model selection:** the API defaults to models that may not exist on the target machine. After Stage 3, apply per-tenant model overrides so the LLM tiers point at models actually present in `ollama list` on that machine. Recommended pilot set (benchmarked 2026-08-28): `gemma4:12b-it-qat` (Main — 13s/tool-round, schema-valid tool calls, verified end-to-end), `qwen3.8:27b-mtp-q4_K_M` (Mid — 73s/tool-round, stronger quality for batch tabular review), `nomic-embed-text:latest` (embeddings). Avoid reasoning-mode models (e.g. nemotron) for interactive tiers — they can hang long docx generations. See `plans/007-aipc-full-installation-handoff.md` Appendix A for the SQL template.

## Files referenced

| File | Purpose |
|------|---------|
| `deploy/client-bundle/compose.prod.yaml` | Docker Compose for pacgate-api + deer-flow + Postgres + nginx |
| `deploy/client-bundle/install.ps1` | One-click Windows installer for the core stack |
| `deploy/client-bundle/setup-qm.ps1` | qm bootstrap script (secrets, config, sandbox build) |
| `deploy/client-bundle/.env.example` | Template for client secrets |
| `deploy/client-bundle/ollama-models.txt` | Models to pre-pull |
| `deploy/client-bundle/deer-flow-config.yaml` | Multi-model deer-flow config (5 models, switchable) |
| `deploy/qm-pacgate/qm.config.jsonc` | qm local deployment config |
| `deploy/SETUP-AND-OPERATIONS.md` | Full 3-day on-site install guide (reference) |
| `deploy/DEPLOYMENT-GUIDE.md` | Engineer-level deployment details (reference) |