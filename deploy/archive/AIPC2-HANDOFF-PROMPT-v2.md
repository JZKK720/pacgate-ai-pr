# AIPC #2 Handoff Prompt — PacGate Full-Stack Setup (v0.2, 2026-09-05)

> # 🛑 DO NOT FOLLOW THIS PROMPT AS WRITTEN — TWO ERRORS (2026-09-23)
>
> **1. It tells you to clone the fork. That is wrong and silently loses data.**
> Clone **`JZKK720/pacgate-ai-pr`**. The fork (`pacgate-ai/pacgate-ai-pr`) is
> 26 commits behind and still carries the original workflow-wiring defect, so a
> machine cloned from it serves **10 built-in workflows instead of the firm's
> 222**, with no error. See the "clone from the fork" section below, now marked.
>
> **2. It says `--force-recreate` on deer-flow "wipes its local DB + admin user".**
> That is **FALSE**. deer-flow's state (`checkpoints.db`, `.jwt_secret`, `users/`,
> `channels/`) lives in the **bind-mounted `./data/deer-flow`** on the host, which
> survives container recreation by definition — verified, not assumed. Following
> this claim would have blocked the correct CORS fix.
>
> It also **inverts the namespace model**: it calls `pacgate-ai/*` "the published
> release" and `jzkk720` "upstream/developer". The reverse is true — **every
> compose file pins `ghcr.io/jzkk720/*`** and all five images are anonymous-200
> there.
>
> **Canonical procedure: `deploy/HANDOFF-AIPC-0.1.17.md`.** Use that instead.
> The historical content below is retained only as a record.

> Copy everything below into a fresh agent session on **AIPC #2**.

---

## Mission

Set up the complete PacGate AI stack on this machine (AIPC #2), identical to
AIPC #1, using the **latest** code that carries all 2026-09-02 fixes, the
2026-09-04 delivery package + qm model fix, and the **deer-flow pacgate-layer**
reconstruction (2026-09-05).

## ⚠️ Topology — read first (2026-09-05)

The repo topology was clarified. There are **two distinct things**:

| Path | What it is | GitHub remote |
|---|---|---|
| `C:\pacgate-ai-pr` | **The REAL implementation/deploy repo** | `JZKK720/pacgate-ai-pr` (push via fork `pacgate-ai/pacgate-ai-pr`) |
| `C:\Users\pacga\github-pr\pacgate-law` | **LOCAL docs wrapper** — NOT a repo, no remote, no commits | none (leave it) |

**Clone from `C:\pacgate-ai-pr` = the `pacgate-ai-pr` repo.** Do **not** create or sync
`pacgate-law` as a GitHub repo. It is a local docs folder only.

## ~~Critical: clone from the fork, not the old repo~~ ❌ WRONG — see header

> **This entire section was backwards and is retained only as a record.**
> Clone **`JZKK720/pacgate-ai-pr`**. The fork is 26 commits behind and still
> carries the workflow-wiring defect (10 built-in workflows instead of 222).
> The remote you clone from determines whether the firm's legal template library
> is present — nothing warns you if it is missing.
>
> ```powershell
> cd C:\
> git clone https://github.com/JZKK720/pacgate-ai-pr.git
> cd pacgate-ai-pr
> git remote -v   # origin must be JZKK720, NOT pacgate-ai
> ```
>
> The original (incorrect) text follows, for reference only:

The `pacgate-ai` account **cannot write** to `JZKK720/pacgate-ai-pr` (403, needs
2FA grant). The fixes live on the **`pacgate-ai/pacgate-ai-pr`** fork, which the
`pacgate-ai` account owns. **Clone from there:**

> The original text printed a runnable `git clone` of the fork at this point.
> That command has been **removed deliberately** so it cannot be copy-pasted:
> cloning the fork deploys the workflow defect. Clone `JZKK720/pacgate-ai-pr`.
> (The write-permission claim above is also stale — the fork's own fixes were
> later superseded upstream.)

Verify you have the fixes:
```powershell
Select-String -Path deploy\AIPC-DEPLOYMENT-HANDBOOK.md -Pattern "0.1.4|Significant findings"
Test-Path deploy\client-delivery\README.md
Test-Path deploy\handbooks\render_handbooks.py
```

If you must use `JZKK720/pacgate-ai-pr`, pull the `feat/deer-flow-pacgate-mcp`
branch (or `git am` the patches in `patches/`) to get the same fixes.

## The 6 fixes you MUST have (from the handbook)

1. **pacgate-mcp** — FastMCP service so deer-flow can query pacgate's legal DBs
   (`pacgate_kb_search`, `pacgate_connector_search`, `pacgate_list_connectors`).
   Registered in `deer-flow-extensions-config.json`.
2. **openviking key fix** — use `OPENVIKING_ROOT_API_KEY` (not `OPENVIKING_API_KEY`).
   Wrong key → openviking 401 → **no MCP tools load at all**.
3. ~~**deer-flow recreate warning** — never `--force-recreate` deer-flow (wipes
   its local DB + admin user). Use `docker compose restart deer-flow`.~~
   **❌ CORRECTED 2026-09-23: this is FALSE.** `--force-recreate` on deer-flow is
   **safe and sometimes required** (compose will not recreate a container when
   only an env var changed). deer-flow stores its state in the bind-mounted
   `./data/deer-flow` on the host — `checkpoints.db`, `.jwt_secret`, `users/`,
   `channels/` — and bind-mounted data survives container recreation by
   definition. Verified against the live stack: the only named volume in the
   project is `pacgate-db-data` (Postgres). Use `--force-recreate` when an env
   change must take effect; plain `restart` only if you specifically want to
   avoid recreating.
4. **QM sign-in** — local topology uses Mailpit SMTP (not Resend). Sign-in links go
   to `http://localhost:8025`.
5. **QM web-ui can't self-auth** — always reach it via the portal (`:8181`).
6. **Git push via fork** — push to `pacgate-ai/pacgate-ai-pr`, not `JZKK720`.

## NEW (2026-09-04): qm model fix + portal topology

The checked-in `deploy/qm-pacgate/qm.config.jsonc` now sets:
- `PI_MODEL=glm-5.3-flash:cloud` (pi harness reads `PI_MODEL`, not `MODEL_NAME`)
- `PI_DETECT_MODEL` / `PI_TITLE_MODEL` / `PI_JUDGE_MODEL` = `glm-5.3-flash:cloud`
  — **fixes the auxiliary-model 401**.
- `modelProvider: openai` (OpenAI-compatible = Ollama at `MODEL_BASE_URL`)
- `services: ["core","web-ui","portal","auth","admin"]` (portal front door topology)
- `publicUrl: http://localhost:8181` (portal, not web-ui)
- `auth` uses SMTP to the local **Mailpit** catcher (`SMTP_PORT=1025`), not Resend.

## NEW (2026-09-05): deer-flow pacgate-layer

The deer-flow PacGate layer was **reconstructed** on the latest upstream
(`bytedance/deer-flow`) as the branch **`pacgate-layer`** (PR #1 on
`pacgate-ai/deer-flow`). It is a clean layer — NOT a rebase of old patches.

If you are building the deer-flow image from source (instead of pulling the
pre-built `ghcr.io/pacgate-ai/deer-flow-pacgate`, the published release), use the
`pacgate-layer` branch. It contains:
- 34 legal skills (`skills/public/`)
- `pacgate_config.py` (3-axis routing + 5 hard gates)
- `pacgate_routing_middleware.py` + `pacgate_hard_gates_middleware.py`
- `docker/Dockerfile.pacgate` + `docker-compose.prod.yaml` + GHCR build workflow
- `matters` router + frontend

Build it with:
```powershell
# from the deer-flow repo (pacgate-layer branch)
docker build -f docker/Dockerfile.pacgate -t ghcr.io/pacgate-ai/deer-flow-pacgate:local .
```

> Tag it `:local`, not `:latest`. **❌ CORRECTED 2026-09-23 — the namespace
> claims in this note are inverted.** The published namespace is **`jzkk720`**:
> every compose file pins `ghcr.io/jzkk720/*`, and all five images return
> anonymous-200 there. `pacgate-ai/*` is the client-delivery MIRROR — and it has
> never actually mirrored, because `GHCR_MIRROR_PAT` is unset. Overwriting
> `jzkk720`'s `:latest` locally still makes the machine disagree with the release
> and with every other AIPC, so the tagging advice holds; only the account names
> were wrong. A local build is a scratch artifact — keep it on a tag the registry
> never serves.

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
Expected: containers up, `/health` returns `ok`.

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
> `defaultModelForProvider` export.

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
