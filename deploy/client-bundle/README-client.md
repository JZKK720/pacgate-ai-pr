# Pacgate-ai Client Bundle v0.1.3

## Quick start

1. Install Docker Desktop (https://docs.docker.com/desktop/)
2. Install Ollama (https://ollama.com) and run `ollama signin` (the research
   chat models route through ollama.com; see `ollama-models.txt`)
3. Clone the repo: `git clone https://github.com/JZKK720/pacgate-ai-pr.git`
   and work in `pacgate-ai-pr\deploy\client-bundle`
4. Copy `.env.example` to `.env` and fill in all five values — DB password,
   JWT secret, tenant id, and **both OpenViking keys** (32-char hex each; the
   installer stops without them)
5. Run: `.\install.ps1` (pulls public GHCR images — no docker login — and the
   Ollama models, and renders the OpenViking configs)
6. Open browser: `http://localhost:8089`

Full step-by-step (tenant seeding, model overrides, qm, acceptance):
see `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`.

## What runs

| Service | Port | Description |
|---------|------|-------------|
| nginx | 8089 (external) | Entry point — routes to API and research |
| pacgate-api | 8080 (internal) | Metadata API, auth, matters, workflows, documents |
| deer-flow | 8001 (internal) | Legal research workspace |
| OpenViking | 1933 | Long-term memory lane (MCP) |
| Postgres | 5432 (internal) | Metadata database |

QM (co-working workspace) runs **separately** via `qm up` on port 8182.

## Setting up qm (co-working workspace)

qm runs separately from the main Docker Compose stack. To set it up:

1. First, start the main stack: `.\install.ps1`
2. Register a service account in pacgate-api:
   ```powershell
   $body = @{email="qm-bridge@pacgate.local"; password="<generate-a-strong-password>"} | ConvertTo-Json
   Invoke-RestMethod -Uri "http://localhost:8089/api/auth/register" -Method POST -Body $body -ContentType "application/json"
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

## Smoke testing the deer-flow outputs listing

The deer-flow workspace surfaces every file the agent wrote to
`/mnt/user-data/outputs` (docx, pdf, md, csv, …) via
`GET /api/threads/{id}/outputs`, and lets users download each one via
`GET /api/threads/{id}/artifacts/mnt/user-data/outputs/<file>`.

To confirm these are reachable **and** downloadable for a logged-in admin
through the real access path (frontend proxy `:8090` or nginx `:8089`), run:

```powershell
# From deploy/client-bundle/ (defaults to http://localhost:8090)
.\smoke-deer-flow-outputs.ps1

# Against the nginx entry point instead
.\smoke-deer-flow-outputs.ps1 -BaseUrl "http://localhost:8089"

# Pin a specific thread (skips auto-discovery)
.\smoke-deer-flow-outputs.ps1 -ThreadId <thread-uuid>
```

The script:

1. Logs in as the admin (reads `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD`
   from `.env`, or override with `-Email` / `-Password`).
2. Discovers a thread the admin owns (or uses `-ThreadId`).
3. Creates a temporary `smoke-test-output.md` in that thread's outputs dir.
4. Calls the listing endpoint and verifies each file is enriched with
   `virtual_path` + `artifact_url`.
5. Downloads the file through the artifact route and checks it returns 200
   with content.
6. Removes the temporary file.

Exit code `0` = pass, `1` = fail. Use `-KeepTestFile` to leave the temp file
in place for manual inspection.

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
- `curl http://localhost:8089/health` — is the API healthy? (returns `ok`)