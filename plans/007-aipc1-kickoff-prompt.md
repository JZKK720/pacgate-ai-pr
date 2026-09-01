# AIPC#1 Kickoff — Agent Run Prompt

> Copy everything in the fence below into a fresh Copilot agent session
> **running on AIPC#1** (or with shell access to it). Starting state: the machine
> is fresh — the `JZKK720/pacgate-ai-pr` repo is **NOT cloned yet**, so the prompt
> starts the agent from `C:\` and includes the clone itself.
>
> Prerequisites already verified for you: the two Pacgate GHCR images are published
> and set to **public** (no `docker login` needed — only the source repo is private),
> and all configs are final. If an anonymous pull 401s, the package was not flipped —
> see handbook Stage 0 and STOP. The only human-in-the-loop moments are `gh auth
> login` and `ollama signin` (both interactive); the prompt tells the agent to pause
> for them.

```markdown
# TASK: Install Pacgate AI on this AIPC (Plan 007 Phase 3 — pilot machine, FRESH setup)

You are installing the complete Pacgate AI stack on the client's AIPC:
pacgate-api (Rust gateway) + deer-flow (research) + OpenViking (memory lane)
+ qm (collaboration) + Postgres + nginx.

**This machine is FRESH — the repo is NOT cloned yet.** Start from `C:\` with
nothing prepared. Work top-to-bottom; never skip a stage.

Read FIRST, in this order (the repo — and these files — exist only after Stage 1):
1. `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` — the authoritative stage guide
2. `plans/007-aipc-full-installation-handoff.md` §0 (stage log) + §5 (this prompt's source) + Appendix A (model override SQL)
3. `deploy/COPILOT_CONTEXT.md` — architecture + memory boundary rules

## Preconditions — verify before touching anything
- [ ] `docker info` succeeds (Docker Desktop running)
- [ ] `curl http://localhost:11434/api/tags` returns model list (Ollama running)
- [ ] `ollama signin` status UNKNOWN on a fresh box — INTERACTIVE (opens a browser).
      PAUSE and have the human run it before install.ps1. Cloud-tagged deepseek
      models in `ollama-models.txt` route via ollama.com. Skip only if the client
      forbids cloud routing and configs were switched to local tags.
- [ ] `node --version` ≥ v24
- [ ] GitHub access to the private repo `JZKK720/pacgate-ai-pr` — verified in
      Stage 1; the agent pauses for the human on `gh auth login`
- [ ] Anonymous GHCR pull works (images must be public):
      `docker pull ghcr.io/jzkk720/pacgate-api:0.1.2` on a machine that has never
      logged in — expect success with no credential prompt.
- [ ] Port 8081 free (`netstat -ano | findstr :8081` empty). If occupied:
      remap nginx ports in `deploy/client-bundle/compose.prod.yaml` and use
      the new port in EVERY verification URL below.
- [ ] Disk space ≥ 60 GB free (images + models + data)

## Execution order

### Stage 1 — Authenticate + clone (private repo; the only human-in-the-loop step)
- Check `gh auth status`:
  - Authenticated → clone directly.
  - Not authenticated → PAUSE and ask the human to run `gh auth login`
    (browser/device flow — the agent cannot complete it) or supply a read-only
    PAT. NEVER place the PAT in a URL, a command, or a file.
- Clone and enter the repo:
  `cd C:\`
  `git clone https://github.com/JZKK720/pacgate-ai-pr.git`
  `cd pacgate-ai-pr`
- Verify: `git log --oneline -1` shows `65fdb38` or later. If older: `git pull`
  and re-check; still older → STOP and report.
- NOW read the three docs listed at the top before continuing.

### Stage 2 — Core stack
- `cd deploy\client-bundle`
- `copy .env.example .env` then fill in:
  - `PACGATE_DB_PASSWORD` (generate: `-join ((1..16) | % { '{0:x}' -f (Get-Random -Maximum 16) })`)
  - `PACGATE_JWT_SECRET` (32 hex chars)
  - `PACGATE_TENANT_ID=pacgate-law`  ← must match the tenant slug in Stage 3
  - `OPENVIKING_ROOT_API_KEY` and `OPENVIKING_API_KEY` (32 hex chars each)
- `.\install.ps1` — pulls 3 GHCR images (public, no login), starts 5 containers, pulls Ollama
  models, renders `OPENVIKING_CONF_CONTENT` into `.env` and `deer-flow-extensions-config.json`
  from the template. If the extensions-config render is skipped (warning: key still
  `change-me`), fix `.env` and re-run — deer-flow memory recall depends on it.
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
- `cd C:\pacgate-ai-pr\deploy\client-bundle` (be explicit — do not rely on cwd)
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
