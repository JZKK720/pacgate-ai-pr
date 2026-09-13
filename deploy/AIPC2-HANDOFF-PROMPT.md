# AIPC #2 Handoff Prompt — PacGate Full-Stack Setup (v0.1.3)

> Copy everything below into a fresh agent session on **AIPC #2**. This is a
> self-contained setup prompt. It assumes AIPC #2 is a fresh Windows machine
> (Docker Desktop, Ollama, Node.js 24+ installed) and that you have the
> `pacgate-ai` GitHub credentials available.

---

## Mission

Set up the complete PacGate AI stack on this machine (AIPC #2), identical to
AIPC #1, using the **updated** code that carries all the 2026-09-02 fixes **and**
the 2026-09-04 delivery package + qm model fix.

## Critical: clone from the fork, not the old repo

The `pacgate-ai` account **cannot write** to `JZKK720/pacgate-ai-pr` (403, needs
2FA grant). The fixes live on the **`pacgate-ai/pacgate-ai-pr`** fork, which the
`pacgate-ai` account owns. **Clone from there:**

```powershell
cd C:\
git clone https://github.com/pacgate-ai/pacgate-ai-pr.git
cd pacgate-ai-pr
```

Verify you have the fixes — the handbook should be v0.1.3 and contain a
"Significant findings" section, and the delivery package should exist:
```powershell
Select-String -Path deploy\AIPC-DEPLOYMENT-HANDBOOK.md -Pattern "0.1.3|Significant findings"
Test-Path deploy\client-delivery\README.md
Test-Path deploy\handbooks\render_handbooks.py
```

If you must use `JZKK720/pacgate-ai-pr`, pull the `feat/deer-flow-pacgate-mcp`
branch (or `git am` the patches in `patches/`) to get the same fixes.

## The 6 fixes you MUST have (from the handbook)

1. **pacgate-mcp** — a new FastMCP service so the deer-flow agent can query
   pacgate's legal DBs (`pacgate_kb_search`, `pacgate_connector_search`,
   `pacgate_list_connectors`). Registered in `deer-flow-extensions-config.json`.
2. **openviking key fix** — `deer-flow-extensions-config.json` must use
   `OPENVIKING_ROOT_API_KEY` (not `OPENVIKING_API_KEY`). Wrong key → openviking
   401 → **no MCP tools load at all**.
3. **deer-flow recreate warning** — never `--force-recreate` deer-flow (wipes its
   local DB + admin user). Use `docker compose restart deer-flow`.
4. **QM uses Resend** — `AUTH_EMAIL_TRANSPORT=resend`, needs `RESEND_API_KEY`.
5. **QM web-ui can't self-auth** — always reach it via the portal (`:8181`).
6. **Git push via fork** — push to `pacgate-ai/pacgate-ai-pr`, not `JZKK720`.

## NEW (2026-09-04): qm model fix + portal topology

The checked-in `deploy/qm-pacgate/qm.config.jsonc` now sets:
- `PI_MODEL=glm-5.3-flash:cloud` (the pi harness reads `PI_MODEL`, not `MODEL_NAME`)
- `PI_DETECT_MODEL` / `PI_TITLE_MODEL` / `PI_JUDGE_MODEL` = `glm-5.3-flash:cloud`
  — **fixes the auxiliary-model 401** (security screen / title / judge calls were
  resolving to `gpt-5.6-luna` → real `api.openai.com` → 401 with dummy key).
- `modelProvider: openai` (OpenAI-compatible API = Ollama at `MODEL_BASE_URL`)
- `services: ["core","web-ui","portal","auth","admin"]` (portal front door topology)
- `publicUrl: http://localhost:8181` (portal, not web-ui)
- `auth` uses SMTP to the local **Mailpit** catcher (`SMTP_PORT=1025`), not Resend.

> **Note**: the handbook's "QM uses Resend" (#4) is superseded for the local
> topology — sign-in links now go to Mailpit (`http://localhost:8025`). Resend is
> only needed to deliver to real inboxes later.

## Setup steps (follow the handbook)

### Stage 2 — core stack
```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
copy .env.example .env
notepad .env
```
Fill in: `PACGATE_DB_PASSWORD`, `PACGATE_JWT_SECRET`, `PACGATE_TENANT_ID=pacgate-law`,
`OPENVIKING_ROOT_API_KEY`, `OPENVIKING_API_KEY` (generate 32-hex each). Then:
```powershell
.\install.ps1
docker compose -f compose.prod.yaml ps
curl http://localhost:8089/health
```
Expected: 5 containers up, `/health` returns `ok`.

### Stage 3 — seed tenant + users
```powershell
docker exec pacgate-db psql -U pacgate -c "INSERT INTO tenants (name, slug) VALUES ('Pacgate Law', 'pacgate-law');"
$body = @{email="admin@pacgate-law.com"; password="<strong-password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8089/api/auth/register" -Method POST -Body $body -ContentType "application/json"
$body = @{email="qm-bridge@pacgate.local"; password="<strong-bridge-password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8089/api/auth/register" -Method POST -Body $body -ContentType "application/json"
```

### Stage 4 — QM (portal topology, Mailpit sign-in)
```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\setup-qm.ps1
```
Then start qm:
```powershell
cd C:\pacgate-ai-pr\deploy\qm-pacgate
node_modules\.bin\qm.cmd up
```
> Use `node_modules\.bin\qm.cmd up` — `npm exec qm -- up` is blocked by the
> PowerShell execution policy.

**After `qm up`, re-apply the pi-models patch** (qm up wipes it from the container
writable layer):
```powershell
docker cp C:\temp\pi-models.ts qm-pacgate-core:/app/src/model/pi-models.ts
docker restart qm-pacgate-core
```
> `C:\temp\pi-models.ts` must contain BOTH the `glm-5.3-flash:cloud` entry AND the
> `defaultModelForProvider` export. If missing, extract from the running container
> before the next `qm up`.

**Seed the admin grant** (portal shows "not set up yet" otherwise):
```powershell
docker exec qm-pacgate-pg psql -U postgres -d qm -c "INSERT INTO admin_grants (principal_id, scope_id, role, granted_by, created_at) VALUES ('admin@pacgate-law.com','org:pacgate','org_admin','system', <epoch-ms>);"
```

**Sign in via portal** (`http://localhost:8181`):
1. Enter `admin@pacgate-law.com` → "Email me a sign-in link"
2. Fetch the link from Mailpit: `http://localhost:8025` (or
   `deploy/qm-pacgate/tasks/get_signin_link.ps1`)
3. Open the link in the **same browser** that started the flow → click Confirm.

### Stage 5 — verify deer-flow
```powershell
# Open http://localhost:8089/research/
# Ask: "Summarize recent force majeure case law in China"
# Verify: response includes citations + is saved to matter memory
```

## Verify the pacgate-mcp wiring (the key new feature)

After the stack is up, confirm the deer-flow agent can query pacgate's legal DBs:
```powershell
docker logs deer-flow --since=5m | Select-String "Configured MCP server: pacgate|Successfully loaded"
```
Expected: `Configured MCP server: pacgate` and `Successfully loaded N tool(s)`.
Then in the deer-flow chat, ask: "用你连接的法律数据库搜索 force majeure 判例" —
the agent should call `pacgate_connector_search` and return real case law.

## Verify the qm model fix (no more 401)

After qm is up, send a test message in the web-ui (`http://localhost:8181`):
```
Reply with exactly: PACGATE-OK
```
Expected: the assistant replies `PACGATE-OK` (via `glm-5.3-flash:cloud` → Ollama).
If you see `OpenAI API error (401): Incorrect API key provided: ollama-local`:
- The run used a real OpenAI model (e.g. `gpt-5.6-sol`). Set the org base model:
  ```
  PUT /admin/api/scopes/org:pacgate/base-model   body: {"modelId":"glm-5.3-flash:cloud"}
  ```
  (via the admin console at `http://localhost:8183`, or the portal's admin API).

## Client delivery package (for the client)

The client-facing docs are in `deploy/client-delivery/`:
- `docs/USER-MANUAL-ZH.pdf` / `USER-MANUAL.pdf` — end-user manual
- `docs/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf` / `.pdf` — deployment handbook
- `docs/deer-flow-openviking-pacgate-handbook.zh.pdf` — integration handbook
- `docs/qm-openviking-pacgate-handbook.zh.pdf` — integration handbook
- `README.md` — delivery index

Regenerate handbooks with `deploy/handbooks/render_handbooks.py` (needs the
puppeteer-cached Chrome; see `deploy/handbooks/.gitignore`).

## Environment gotchas (Windows AIPC)

- `python` is NOT in PATH — use `C:\Program Files\Python313\python.exe`.
- PowerShell blocks `.ps1`/`npm.ps1` — wrap in `cmd.exe /c "..."` or use
  `node_modules\.bin\qm.cmd`.
- Chinese Windows defaults to GBK — never `Get-Content`/`Set-Content` on UTF-8
  Chinese files (mojibake). Use `[System.IO.File]::ReadAllBytes`/`WriteAllBytes`.
- Headless Chrome: use legacy `--headless` (not `--headless=new`, which crashes).
- ollama.com downloads may be blocked on this box — use on-board models only
  (glm-5.3-flash:cloud, or the local models in `deer-flow-config.yaml`).

## When done

Verify all services healthy, sign-in works via portal, deer-flow research returns
citations, qm chat replies without 401, and the client delivery package is intact.
Then report back with the exact commands you ran and any deviations.
