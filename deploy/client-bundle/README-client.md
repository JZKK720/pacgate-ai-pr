# Pacgate-ai Client Bundle v0.1.1

## Quick start

1. Install Docker Desktop (https://docs.docker.com/desktop/)
2. Install Ollama (https://ollama.com)
3. Unzip this bundle to `C:\pacgate`
4. Copy `.env.example` to `.env` and fill in passwords
5. Run: `.\install.ps1`
6. Open browser: `http://localhost:8081`

## What runs

| Service | Port | Description |
|---------|------|-------------|
| nginx | 8081 (external) | Entry point — routes to API and research |
| pacgate-api | 8080 (internal) | Metadata API, auth, matters, workflows, documents |
| deer-flow | 8001 (internal) | Legal research workspace |
| Postgres | 5432 (internal) | Metadata database |

QM (co-working workspace) runs **separately** via `qm up` on port 8182.

## Setting up qm (co-working workspace)

qm runs separately from the main Docker Compose stack. To set it up:

1. First, start the main stack: `.\install.ps1`
2. Register a service account in pacgate-api:
   ```powershell
   $body = @{email="qm-bridge@pacgate.local"; password="<generate-a-strong-password>"} | ConvertTo-Json
   Invoke-RestMethod -Uri "http://localhost:8081/api/auth/register" -Method POST -Body $body -ContentType "application/json"
   ```
   This account is used by the qm sandbox bridge tool to authenticate with pacgate-api.
3. Copy the `qm-pacgate/` directory next to this bundle
4. Run the qm bootstrap: `.\setup-qm.ps1`
   - This generates signing secrets, creates `.env`, and validates the config
5. Start qm: `cd qm-pacgate && npm exec qm -- up`
6. Access qm at: `http://localhost:8182`

## Switching models

### deer-flow (research workspace)
1. Edit `deer-flow-config.yaml` — reorder the `models` list (first entry = default)
2. Restart: `docker compose -f compose.prod.yaml restart deer-flow`

### qm (co-working workspace)
1. Edit `qm-pacgate/qm.config.jsonc` — change `MODEL_NAME`
2. Restart: `cd qm-pacgate && npm exec qm -- down && npm exec qm -- up`

## Updating

Run: `.\install.ps1 -Update`

This pulls new GHCR images and restarts containers. Your data is preserved:
- `./data/tenants/` (volume mount) — matters, documents, memory
- Postgres data (named volume) — metadata database

## Troubleshooting

See `deploy/DEPLOYMENT-GUIDE.md` Part 5 for detailed troubleshooting.

Quick checks:
- `docker compose -f compose.prod.yaml ps` — are all services running?
- `docker compose -f compose.prod.yaml logs <service>` — check logs
- `ollama list` — are models available?
- `curl http://localhost:8081/api/health` — is the API healthy?