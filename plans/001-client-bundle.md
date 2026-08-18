# Plan 001: Check in client bundle files

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- deploy/DEPLOYMENT-GUIDE.md`
> If the deployment guide changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx / delivery
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The DEPLOYMENT-GUIDE contains the client bundle templates as inline markdown
code blocks — `compose.prod.yaml`, `install.ps1`, `nginx/default.conf`,
`.env.example`, `ollama-models.txt`. No `deploy/client-bundle/` directory
exists. Without these as actual files, the client bundle cannot be zipped and
shipped to the AIPC machines. This plan materializes them.

## Current state

- `deploy/DEPLOYMENT-GUIDE.md` lines 130-420 contain all templates as code blocks
- `file_search deploy/client-bundle/**` returns 0 results — directory does not exist
- The actual Dockerfile at `pacgate-ai/Dockerfile` uses `rust:1.94-bookworm` and
  binary name `pacgate-server` (NOT `pacgate-api` as the guide says)
- GHCR images exist: `ghcr.io/jzkk720/pacgate-api:0.1.0` and
  `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0`
- The qm-pacgate image does NOT exist as a standalone Docker image — qm runs
  via `qm up` from `deploy/qm-pacgate/`, not via `docker compose`

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify dir created | `Test-Path deploy/client-bundle/compose.prod.yaml` | True |
| Verify nginx | `Test-Path deploy/client-bundle/nginx/default.conf` | True |
| Verify install | `Test-Path deploy/client-bundle/install.ps1` | True |
| Verify env | `Test-Path deploy/client-bundle/.env.example` | True |
| Verify models | `Test-Path deploy/client-bundle/ollama-models.txt` | True |
| Validate compose | `docker compose -f deploy/client-bundle/compose.prod.yaml config` | exit 0 |

## Scope

**In scope** (the only files you should create):
- `deploy/client-bundle/compose.prod.yaml`
- `deploy/client-bundle/nginx/default.conf`
- `deploy/client-bundle/install.ps1`
- `deploy/client-bundle/.env.example`
- `deploy/client-bundle/ollama-models.txt`
- `deploy/client-bundle/README-client.md` (one-page quick start)

**Out of scope** (do NOT touch):
- `deploy/DEPLOYMENT-GUIDE.md` — plan 004 fixes its stale references
- `deploy/qm-pacgate/` — plan 003 handles qm bootstrap
- `deploy/deer-flow-pacgate/config.yaml` — plan 002 handles model config
- `compose.yaml` (repo root) — that's the docs/auth-gate stack, not the runtime

## Git workflow

- Branch: `advisor/001-client-bundle`
- Commit message: `feat: check in client bundle files for AIPC delivery`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Create directory structure

Create `deploy/client-bundle/` and `deploy/client-bundle/nginx/`.

**Verify**: `Test-Path deploy/client-bundle/nginx` → True

### Step 2: Create compose.prod.yaml

Create `deploy/client-bundle/compose.prod.yaml` based on the template in
`deploy/DEPLOYMENT-GUIDE.md` lines 132-188, with these corrections:

1. Remove the `qm` service block entirely. qm does NOT run as a docker-compose
   service — it runs via `qm up` from a separate deployment directory. Adding
   a `qm` service with a non-existent image (`ghcr.io/jzkk720/qm-pacgate:0.1.0`
   does not exist) would break `docker compose up`.
2. Keep `pacgate-db`, `pacgate-api`, `deer-flow`, and `nginx` services.
3. The compose file must reference the real GHCR images that exist:
   `ghcr.io/jzkk720/pacgate-api:0.1.0` and
   `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0`.
4. Add a comment at the top explaining qm runs separately.

**Verify**: `docker compose -f deploy/client-bundle/compose.prod.yaml config`
→ exit 0, no errors

### Step 3: Create nginx/default.conf

Create `deploy/client-bundle/nginx/default.conf` based on
`deploy/DEPLOYMENT-GUIDE.md` lines 192-220. This is the runtime nginx that
routes:
- `/` → pacgate-api (landing)
- `/api/` → pacgate-api (metadata API)
- `/research/` → deer-flow (research workspace)

Do NOT include a `/collab/` route to qm — qm runs on its own port (8180/8182)
via `qm up`, not behind this nginx. Add a comment explaining this.

**Verify**: Read the file back and confirm the three location blocks exist.

### Step 4: Create .env.example

Create `deploy/client-bundle/.env.example` based on
`deploy/DEPLOYMENT-GUIDE.md` lines 232-244. Include:

```
PACGATE_DB_PASSWORD=change-me-to-a-strong-password
PACGATE_JWT_SECRET=change-me-to-a-random-hex-string
PACGATE_TENANT_ID=default-firm
PACGATE_COOKIE_SECURE=false
```

Add comments explaining each variable and how to generate the secrets
(`openssl rand -hex 32` for JWT, strong password for DB).

**Verify**: `Test-Path deploy/client-bundle/.env.example` → True

### Step 5: Create ollama-models.txt

Create `deploy/client-bundle/ollama-models.txt` with the actual models
available on the user's AIPC machines. Based on `ollama list` output, the
recommended models for the Phase 1 pilot are:

```
# Pacgate-ai required Ollama models
# Pull these before starting the stack:
#   ollama pull <model-name>

# Primary legal execution model (local, GPU-accelerated)
deepseek-v4-flash:0731-cloud

# Heavier model for complex research (local, GPU-accelerated)
deepseek-v4-pro:0813-cloud

# Embedding model for RAG (required by pacgate-api)
nomic-embed-text:latest

# Alternative models (uncomment to use)
# qwen3.8:27b-mtp-q4_K_M
# qwen3.6:35b-a3b-mtp-q4_K_M
# nemotron-3.5-lightning:30b-a3b
```

**Verify**: `Test-Path deploy/client-bundle/ollama-models.txt` → True

### Step 6: Create install.ps1

Create `deploy/client-bundle/install.ps1` based on
`deploy/DEPLOYMENT-GUIDE.md` lines 248-415. This is the one-click Windows
installer. Key requirements:
- Check Docker Desktop is installed and running
- Check Ollama is installed
- Check `.env` exists (copy from `.env.example` if not, then tell user to edit)
- Create `./data` directory
- Pull Ollama models from `ollama-models.txt` (first install only, not on -Update)
- `docker compose -f compose.prod.yaml pull`
- `docker compose -f compose.prod.yaml up -d`
- Wait 10 seconds, show `docker compose ps` status
- Print access URLs: `http://localhost:8081` for research, explain qm runs
  separately on port 8182

**Verify**: `Test-Path deploy/client-bundle/install.ps1` → True

### Step 7: Create README-client.md

Create `deploy/client-bundle/README-client.md` — a one-page quick start for
the client IT person who receives the bundle. Content:

```markdown
# Pacgate-ai Client Bundle v0.1.0

## Quick start
1. Install Docker Desktop (https://docs.docker.com/desktop/)
2. Install Ollama (https://ollama.com)
3. Unzip this bundle to C:\pacgate
4. Copy .env.example to .env and fill in passwords
5. Run: .\install.ps1
6. Open browser: http://localhost:8081

## What runs
- pacgate-api (metadata API, port 8080 internal)
- deer-flow (research workspace, port 8001 internal)
- nginx (entry point, port 8081)
- Postgres (metadata database)
- qm (co-working workspace, runs separately via qm up, port 8182)

## Updating
Run: .\install.ps1 -Update

## Troubleshooting
See deploy/DEPLOYMENT-GUIDE.md Part 5
```

**Verify**: `Test-Path deploy/client-bundle/README-client.md` → True

## Done criteria

- [ ] `Test-Path deploy/client-bundle/compose.prod.yaml` → True
- [ ] `Test-Path deploy/client-bundle/nginx/default.conf` → True
- [ ] `Test-Path deploy/client-bundle/install.ps1` → True
- [ ] `Test-Path deploy/client-bundle/.env.example` → True
- [ ] `Test-Path deploy/client-bundle/ollama-models.txt` → True
- [ ] `Test-Path deploy/client-bundle/README-client.md` → True
- [ ] `docker compose -f deploy/client-bundle/compose.prod.yaml config` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:
- The DEPLOYMENT-GUIDE content at the cited line numbers doesn't match what's
  described here (the guide has been edited since this plan was written).
- `docker compose config` fails for a reason other than missing .env values.
- You discover that `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` no longer exists.

## Maintenance notes

- When GHCR image versions are bumped, update `compose.prod.yaml` image tags
  and the install.ps1 pull command.
- When new Ollama models are recommended, update `ollama-models.txt`.
- The qm service is intentionally absent from compose — it runs via `qm up`
  from `deploy/qm-pacgate/`. If qm later gets a standalone Docker image, add
  it as a compose service here.