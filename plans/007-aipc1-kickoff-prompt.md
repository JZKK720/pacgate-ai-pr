# AIPC#1 Kickoff — Agent Run Prompt

> Copy everything in the fence below into a fresh Copilot agent session
> **running on AIPC#1** (or with shell access to it). Working directory: the
> cloned repo root (`C:\pacgate-ai-pr`).
>
> Prerequisites already verified for you: all GHCR images pullable, all
> configs final at commit `f2a956e`.

```markdown
# TASK: Install Pacgate AI on this AIPC (Plan 007 Phase 3 — pilot machine)

You are installing the complete Pacgate AI stack on the client's AIPC:
pacgate-api (Rust gateway) + deer-flow (research) + OpenViking (memory lane)
+ qm (collaboration) + Postgres + nginx.

Read FIRST, in this order:
1. `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` — the authoritative stage guide
2. `plans/007-aipc-full-installation-handoff.md` §0 (stage log) + §5 (this prompt's source) + Appendix A (model override SQL)
3. `deploy/COPILOT_CONTEXT.md` — architecture + memory boundary rules

## Preconditions — verify before touching anything
- [ ] `docker info` succeeds (Docker Desktop running)
- [ ] `curl http://localhost:11434/api/tags` returns model list (Ollama running)
- [ ] `node --version` ≥ v24
- [ ] `gh auth status` or a PAT works for the private repo `JZKK720/pacgate-ai-pr`
- [ ] Port 8081 free (`netstat -ano | findstr :8081` empty). If occupied:
      remap nginx ports in `deploy/client-bundle/compose.prod.yaml` and use
      the new port in EVERY verification URL below.
- [ ] Disk space ≥ 60 GB free (images + models + data)

## Execution order

### Stage 1 — Clone
- `cd C:\` ; `git clone https://github.com/JZKK720/pacgate-ai-pr.git` ; `cd pacgate-ai-pr`
- Verify: `git log --oneline -1` shows `f2a956e` or later.

### Stage 2 — Core stack
- `cd deploy\client-bundle`
- `copy .env.example .env` then fill in:
  - `PACGATE_DB_PASSWORD` (generate: `-join ((1..16) | % { '{0:x}' -f (Get-Random -Maximum 16) })`)
  - `PACGATE_JWT_SECRET` (32 hex chars)
  - `PACGATE_TENANT_ID=pacgate-law`  ← must match the tenant slug in Stage 3
  - `OPENVIKING_ROOT_API_KEY` and `OPENVIKING_API_KEY` (32 hex chars each)
- `.\install.ps1` — pulls 3 GHCR images, starts 5 containers, pulls Ollama
  models, renders `OPENVIKING_CONF_CONTENT` into `.env`.
- Verify: `docker compose -f compose.prod.yaml ps` → 5 services Up
- Verify: `curl http://localhost:8081/health` → `ok`
- Verify: `curl http://localhost:1933/health` → healthy JSON (OpenViking)

### Stage 3 — Tenant + users
- Seed tenant (slug MUST equal PACGATE_TENANT_ID):
  `docker exec pacgate-db psql -U pacgate -c "INSERT INTO tenants (name, slug) VALUES ('Pacgate Law', 'pacgate-law');"`
- Register admin:
  `$body = @{email="admin@pacgate-law.com"; password="<strong-password>"} | ConvertTo-Json`
  `Invoke-RestMethod -Uri "http://localhost:8081/api/auth/register" -Method POST -Body $body -ContentType "application/json"`
- Register bridge account the same way: `qm-bridge@pacgate.local`

### Stage 3.5 — Model overrides (CRITICAL — skip = every workflow 500s)
- `ollama list` — confirm `gemma4:12b-it-qat`, `qwen3.8:27b-mtp-q4_K_M`,
  `nomic-embed-text` are present; `ollama pull <tag>` any that are missing.
- Apply Appendix A SQL (from `plans/007-aipc-full-installation-handoff.md`)
  with MAIN=gemma4:12b-it-qat, MID=qwen3.8:27b-mtp-q4_K_M,
  LOW=gemma4:12b-it-qat, TENANT_SLUG=pacgate-law:
  - Write the SQL to a local file, `docker cp` it into pacgate-db, then
    `docker exec pacgate-db psql -U pacgate -f /tmp/overrides.sql`
- Verify: `docker exec pacgate-db psql -U pacgate -c "SELECT config_json->'model_overrides'->0->>'model_name' FROM tenants WHERE slug='pacgate-law';"`
  → `gemma4:12b-it-qat`
- Casing is snake_case: tiers `main`/`mid`/`low`, provider `ollama`.

### Stage 4 — qm
- `.\setup-qm.ps1` (prompts: admin email, bridge email `qm-bridge@pacgate.local`,
  bridge password from Stage 3)
- When prompted for OpenViking secrets (OPENVIKING_API_KEY / ACCOUNT / USER):
  API key = the value from `.env`; ACCOUNT = `pacgate-law`; USER = admin email
  or a pilot user id.
- `cd ..\qm-pacgate` ; `npm exec qm -- up`
- Verify: http://localhost:8182 loads; admin signs in.

### Stage 5 — deer-flow
- Open http://localhost:8081/research/ ; select or create a matter; run:
  "Summarize recent force majeure case law in China"
- Verify: response includes citations; matter memory persists.

### Stage 6 — Smoke checklist (handbook §Stage 6) + acceptance
Run ALL of these and record pass/fail:
- [ ] 5 containers Up; both health endpoints green
- [ ] Workflow execute (THE acceptance test):
      login → create matter →
      `POST /api/workflows/00000000-0000-0000-0000-000000000101/execute`
      with `{"matter_id":"<id>","input":"Review this sample contract clause for liability limitations."}`
      Expect 200 in <2 min, 3 steps, and a row in `documents`.
- [ ] OpenViking memory lane:
      `pacgate-qm ov-remember --content "Pilot test: <today's date> installation verified"`
      wait ~2 min, then `pacgate-qm ov-search --query "Pilot test installation"`
      → the fact is recalled.
- [ ] qm web UI sign-in + one workflow through the bridge
- [ ] deer-flow research round-trip with citations

## Ground rules
- NEVER modify Rust code or rebuild images on this machine — runtime comes
  from GHCR (pacgate-api:0.1.2, deer-flow-pacgate:0.1.0, OpenViking pinned
  digest).
- NEVER substitute a reasoning-mode model (nemotron etc.) for Main tier.
- Never commit secrets; `.env` files stay local.
- If any step fails twice: STOP, capture evidence (container logs, HTTP
  status, exact command), and report — do not improvise.

## Report back
Write results to `plans/007-delivery-log.md` (create it): per-checklist-item
pass/fail, image digests running
(`docker inspect pacgate-api --format {{.Image}}`), any deviations with
justification, and total install time.
```

---

## Post-pilot: replicating to AIPC#2

Once AIPC#1 passes fully, AIPC#2 is the same prompt with two differences:
1. Generate **fresh secrets** (DB password, JWT, OpenViking keys) — never copy #1's `.env`.
2. The delivery log gets its own section (one section per machine, dated).
