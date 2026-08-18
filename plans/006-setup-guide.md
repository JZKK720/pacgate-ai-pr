# Plan 006: Comprehensive setup + operational guide

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- deploy/ docs/`
> If these directories changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-client-bundle.md, 002-deer-flow-multi-model.md,
  003-qm-bootstrap.md, 004-fix-deployment-guide.md, 005-workflow-packaging.md
- **Category**: docs / delivery
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The existing docs are fragmented: `deploy/DEPLOYMENT-GUIDE.md` is for
Cubecloud engineers, `deploy/USER-MANUAL.md` is for attorneys, and the
client bundle will have a `README-client.md` quick-start. What's missing is a
single comprehensive guide that ties everything together — the full setup
sequence, operational procedures, model switching, troubleshooting, and
architecture overview — written for the Cubecloud engineer who does the 3-day
on-site installation. This plan creates that guide.

## Current state

- `deploy/DEPLOYMENT-GUIDE.md` — engineer guide (has stale references, fixed by plan 004)
- `deploy/USER-MANUAL.md` — attorney guide (describes research + collaboration modes)
- `deploy/PLANS.md` — architecture memo (from 2026-08-12, pre-client redefinition)
- `deploy/ARCHITECTURE-DIAGRAMS.md` — Mermaid diagrams
- `deploy/COPILOT_CONTEXT.md` — compact context for AI agents
- `deploy/client-bundle/README-client.md` — quick-start (created by plan 001)
- `CONTINUE-FROM-OTHER-MACHINE.md` — development handoff notes (not client-facing)
- No single document covers the full install-day sequence end-to-end

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify guide | `Test-Path deploy/SETUP-AND-OPERATIONS.md` | True |
| Word count | `(Get-Content deploy/SETUP-AND-OPERATIONS.md).Count` | > 200 lines |

## Scope

**In scope** (the only file you should create):
- `deploy/SETUP-AND-OPERATIONS.md`

**Out of scope** (do NOT touch):
- `deploy/DEPLOYMENT-GUIDE.md` — plan 004 fixes it; this guide supplements it
- `deploy/USER-MANUAL.md` — attorney guide stays separate
- `deploy/client-bundle/README-client.md` — quick-start stays separate
- All source code, Dockerfiles, configs

## Git workflow

- Branch: `advisor/006-setup-guide`
- Commit message: `docs: comprehensive setup + operational guide for AIPC delivery`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Create deploy/SETUP-AND-OPERATIONS.md

Create a comprehensive guide with the following sections. This is written for
the Cubecloud engineer performing the 3-day on-site installation at
Pacgate-law's office.

#### Document structure:

```markdown
# Pacgate-ai Setup & Operations Guide

> For Cubecloud engineers — 3-day on-site installation at Pacgate-law
> Version 0.1.0 — Phase 1 pilot

## 1. Overview

### 1.1 What gets installed
- Two AIPC machines with Cubecloud agent OS surface
- Pacgate-ai runtime stack (pacgate-api + deer-flow + Postgres + nginx)
- qm co-working workspace (runs separately via qm up)
- Ollama with pre-pulled legal models
- 220 legal workflow templates + 30 personas (pre-loaded in pacgate-api)

### 1.2 Architecture (brief)
[Mermaid diagram showing the runtime stack]

### 1.3 What lives where
| Component | Location | Owner |
|---|---|---|
| pacgate-api | Docker container (GHCR image) | Cubecloud |
| deer-flow | Docker container (GHCR image) | Cubecloud |
| qm | Docker containers (qm up) | Cubecloud |
| Postgres | Docker container (named volume) | Client data |
| ./data/tenants/ | Host filesystem (volume mount) | Client data |
| Ollama | Native Windows (not Docker) | Client |
| Agent OS surface | Native (Hermes, Open WebUI, etc.) | Cubecloud |

## 2. Pre-installation (Day 1, before arriving on-site)

### 2.1 Build + verify GHCR images
- docker build + push pacgate-api:0.1.0
- docker build + push deer-flow-pacgate:0.1.0
- Verify both pull: docker pull ghcr.io/jzkk720/pacgate-api:0.1.0

### 2.2 Prepare the client bundle
- Zip deploy/client-bundle/ → pacgate-client-bundle-v0.1.0.zip
- Include: compose.prod.yaml, nginx/, install.ps1, .env.example,
  ollama-models.txt, README-client.md, deer-flow-config.yaml,
  workflows/, personas/
- Verify the zip contains all files

### 2.3 Prepare the qm deployment
- Copy deploy/qm-pacgate/ to the bundle (separate directory)
- Run qm check + qm sandbox build locally to verify
- Note: setup-qm.ps1 generates secrets on-site, not before

## 3. Installation Day 1 — Hardware + base software

### 3.1 Unbox and configure AIPC machines
- Connect GPU docks
- Enable virtualization in BIOS
- Install Windows 11 updates
- Install AMD Adrenalin drivers (for GPU)
- Install Docker Desktop (WSL2 backend)
- Install Ollama (native Windows)
- Install Node.js 24+ (for qm)

### 3.2 Pull Ollama models
- ollama pull deepseek-v4-flash:0731-cloud
- ollama pull deepseek-v4-pro:0813-cloud
- ollama pull nomic-embed-text:latest
- Verify: ollama list

### 3.3 Deploy the client bundle
- Copy pacgate-client-bundle-v0.1.0.zip to C:\pacgate
- Expand-Archive
- Copy .env.example to .env
- Generate secrets: openssl rand -hex 32 (or PowerShell equivalent)
- Fill in .env: PACGATE_DB_PASSWORD, PACGATE_JWT_SECRET, PACGATE_TENANT_ID
- Run: .\install.ps1
- Verify: docker compose ps (all services running)
- Verify: curl http://localhost:8081/api/health → {"status":"ok"}

### 3.4 Seed the default tenant
- docker exec pacgate-db psql -U pacgate -c "INSERT INTO tenants (name, slug) VALUES ('Pacgate Law', 'pacgate-law');"
- Register admin user: POST http://localhost:8081/api/auth/register

## 4. Installation Day 2 — qm + agent OS surface

### 4.1 Set up qm co-working workspace
- Copy qm-pacgate/ to C:\pacgate\qm-pacgate
- Register a Pacgate bridge service account in pacgate-api
- Run: .\setup-qm.ps1 (generates secrets, creates .env)
- Verify: cd qm-pacgate && npm exec qm -- check
- Start: cd qm-pacgate && npm exec qm -- up
- Verify: open http://localhost:8182 → qm web UI loads
- Sign in with admin email
- Verify the pacgate-qm sandbox tool works:
  - In qm chat, ask: "list available pacgate workflows"
  - The agent should call pacgate-qm and return workflow categories

### 4.2 Configure Cubecloud agent OS surface
- Hermes: configure memory + task tracking to point to pacgate-api
- Open WebUI: connect to Ollama, configure legal system prompts
- OpenSpace: set up team workspace with matter visibility
- IronClaw: configure security boundaries + approval paths
- (These are Cubecloud-internal tools, not in this repo)

### 4.3 Verify deer-flow research workspace
- Open http://localhost:8081/research/
- Select a matter
- Ask a research question: "Summarize recent force majeure case law in China"
- Verify the response includes citations
- Verify the response is saved to the matter's memory

## 5. Installation Day 3 — Training + handoff

### 5.1 Admin training
- Show the IT admin how to:
  - Start/stop the stack: docker compose up/down
  - Update: .\install.ps1 -Update
  - Check logs: docker compose logs
  - Switch deer-flow model: edit deer-flow-config.yaml, restart container
  - Switch qm model: edit qm.config.jsonc MODEL_NAME, qm down + qm up
  - Register new users: POST /api/auth/register

### 5.2 Attorney training
- Walk through the USER-MANUAL.md
- Demo research mode (deer-flow)
- Demo co-working mode (qm)
- Demo document upload + workflow execution

### 5.3 Handoff checklist
- [ ] Both AIPC machines running
- [ ] Docker stack healthy (docker compose ps)
- [ ] qm running (npm exec qm -- status)
- [ ] Ollama models pulled
- [ ] Default tenant seeded
- [ ] Admin user registered
- [ ] Bridge service account registered
- [ ] Firewall rule for port 8081 (if LAN access needed)
- [ ] Agent OS surface configured
- [ ] Attorneys trained
- [ ] .env backed up securely (NOT in git)

## 6. Operations

### 6.1 Switching models (deer-flow)
1. Edit C:\pacgate\deer-flow-config.yaml
2. Reorder the models list (first entry = default)
3. Restart: docker compose -f compose.prod.yaml restart deer-flow
4. Verify: open http://localhost:8081/research/ and send a test message

### 6.2 Switching models (qm)
1. Edit C:\pacgate\qm-pacgate\qm.config.jsonc
2. Change MODEL_NAME to the desired Ollama model
3. Restart: cd C:\pacgate\qm-pacgate && npm exec qm -- down && npm exec qm -- up
4. Verify: open http://localhost:8182 and send a test message

### 6.3 Adding a new attorney user
1. POST http://localhost:8081/api/auth/register
   {"email": "new.attorney@pacgate-law.com", "password": "<temp-password>"}
2. The user can now log in to both research (deer-flow) and co-working (qm)
3. Assign a SOUL persona if needed (via pacgate-api admin endpoint)

### 6.4 Updating the stack
1. Cubecloud ships a new client bundle version
2. On the client AIPC: .\install.ps1 -Update
3. This pulls new GHCR images and restarts containers
4. ./data/tenants/ is preserved (volume mount)
5. Postgres data is preserved (named volume)

### 6.5 Backup
- Critical data: C:\pacgate\data\tenants\ (volume mount)
- Database: docker exec pacgate-db pg_dump -U pacgate pacgate > backup.sql
- qm state: C:\pacgate\qm-pacgate\.env (contains signing keys — back up securely)

## 7. Troubleshooting

### Containers won't start
- Check .env has real values (not placeholders)
- Check Docker Desktop is running
- Check port 8081 is not in use: netstat -an | findstr 8081
- Check logs: docker compose -f compose.prod.yaml logs <service>

### Ollama not reachable
- Verify: ollama list (should show models)
- Test: docker run --rm curlimages/curl http://host.docker.internal:11434/api/tags
- If failed: check Ollama is running as a Windows service

### GPU not detected
- ollama ps (should show GPU in output)
- Check AMD Adrenalin driver is installed
- Check virtualization is enabled in BIOS

### qm won't start
- cd C:\pacgate\qm-pacgate && npm exec qm -- check
- Check .env has all required secrets (no blank values)
- Check signing secrets are 64-char hex strings
- Check PACGATE_API_EMAIL/PASSWORD are correct (test login via curl)

### deer-flow returns errors
- Check pacgate-api is healthy: curl http://localhost:8081/api/health
- Check the deer-flow config model is valid: ollama show <model-name>
- Check deer-flow logs: docker compose logs deer-flow

## 8. Architecture reference

### 8.1 Component map
[Reference deploy/ARCHITECTURE-DIAGRAMS.md]

### 8.2 Data flow
1. Attorney opens http://localhost:8081 → nginx → pacgate-api (landing)
2. Attorney goes to /research/ → nginx → deer-flow (research workspace)
3. deer-flow calls pacgate-api for matter memory + document storage
4. deer-flow calls Ollama for model inference
5. Attorney goes to http://localhost:8182 → qm (co-working workspace)
6. qm agent calls pacgate-qm CLI → pacgate-api (workflow execution)

### 8.3 What's in each GHCR image
| Image | Contains | Size |
|---|---|---|
| ghcr.io/jzkk720/pacgate-api:0.1.0 | Rust binary + migrations | ~50MB |
| ghcr.io/jzkk720/deer-flow-pacgate:0.1.0 | deer-flow + Python adapter | ~2GB |

### 8.4 What's NOT in any image (client data)
- ./data/tenants/{tenant_id}/ — matters, documents, memory
- Postgres data volume — metadata database
- .env — secrets
- qm .env — signing keys + bridge credentials
```

**Verify**: `Test-Path deploy/SETUP-AND-OPERATIONS.md` → True
**Verify**: `(Get-Content deploy/SETUP-AND-OPERATIONS.md).Count` → > 200

## Done criteria

- [ ] `deploy/SETUP-AND-OPERATIONS.md` exists
- [ ] Document has all 8 sections (overview, pre-install, day 1-3, operations, troubleshooting, architecture)
- [ ] Document references the actual file paths from plans 001-005
- [ ] Document includes the model-switching procedures from plan 002 + 003
- [ ] Document includes the qm bootstrap sequence from plan 003
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:
- Plans 001-005 have not been executed yet — this guide depends on their
  outputs (file paths, config formats). If executing out of order, use the
  plan descriptions to write the guide against the intended final state.
- The USER-MANUAL.md or DEPLOYMENT-GUIDE.md have been significantly restructured
  since this plan was written.

## Maintenance notes

- This guide should be updated whenever:
  - A new GHCR image version is shipped (update image tags)
  - The install.ps1 or setup-qm.ps1 scripts change (update procedures)
  - New Ollama models are recommended (update model names)
  - The qm config format changes (update qm sections)
- This guide is the single source of truth for the on-site installation
  sequence. The DEPLOYMENT-GUIDE.md remains as the technical reference; this
  guide is the operational playbook.