# AIPC Handoff Prompt — PacGate stack, first install on a new machine

> For: the on-site engineer installing Pacgate AI on AIPC #1 and/or AIPC #2.
> Source of truth: `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` (stages in full detail).
> This prompt is the ordered runbook; the handbook is the reference.
> Works for any release: the compose files pin the images, so the version you
> verify is whatever `compose.prod.yaml` pins today — check it with `/version`.

## Identity facts (do not get these wrong)

- **Clone `JZKK720/pacgate-ai-pr`. NOT the `pacgate-ai` fork.** The fork is
  26 commits behind and serves 10 built-in workflows instead of the firm's
  222, with no error shown anywhere. Every compose file pins
  `ghcr.io/jzkk720/*`.
- **Images are PUBLIC. Never run `docker login ghcr.io` on a client machine.**
  A failed anonymous pull means the package visibility flipped private or the
  tag does not exist — check with
  `python scripts/check-ghcr-anon.py <tag>` from the dev box, not with a login.
- Cloud chat models (`deepseek-*-cloud`) are INTENTIONAL. They route through
  ollama.com; auth rides the `ollama signin` OAuth session. Do not "fix" this.
- The two machines are independent: own Postgres, own data dir, no sync.

## Stage 0 — prerequisites (each machine)

- Docker Desktop running
- Ollama installed; **`ollama signin` completed** (needed by the cloud tags)
- Node.js 24+ (for qm, Stage 4)
- No Rust, no cargo, no build tools needed — the AIPC only pulls images.

## Stage 1 — clone

```powershell
cd C:\
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
git remote -v   # origin MUST be JZKK720/pacgate-ai-pr
```

## Stage 2 — core stack

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
copy .env.example .env
notepad .env    # set the five secrets per the handbook (DB pw, JWT secret,
                # PACGATE_TENANT_ID, both OpenViking keys)
.\install.ps1
```

The installer does the first-install work automatically:

- pulls the public GHCR images pinned by compose
- renders `deer-flow-extensions-config.json` + OpenViking config from `.env`
- pulls the Ollama models in `ollama-models.txt`
- **step 6a bootstrap:** creates the tenant and registers the admin —
  watch for `[OK] tenant 'default-firm' present` and `[OK] admin '...' registered`
- **step 4c:** derives `GATEWAY_CORS_ORIGINS` so LAN sign-in/register work

> **Tenant slug rule:** the seeded slug MUST equal `PACGATE_TENANT_ID`
> (default `default-firm`). If you changed that var in `.env`, the installer
> handles it; if you seed the tenant by hand, use the same value. A mismatch
> fails registration with `default tenant not found: matter not found` —
> it reads like a database fault and is a naming mismatch.

### Verify the core stack (wire-verified paths)

```powershell
docker compose -f compose.prod.yaml ps        # 5 services up incl. openviking
curl http://localhost:8089/version            # {"version":"<release>","revision":"<sha>"}
curl http://localhost:8089/pacgate/health     # ok
```

> **Do NOT probe `/health` at the nginx root.** nginx routes `/` to the
> deer-flow frontend, so `:8089/health` returns the frontend's 404 page and
> reads as a failure. `/version` is at the root; the API lives under `/pacgate/`.
> An OLD image answers `/version` with 401 (auth middleware), not 404.

## Stage 3 — service accounts (installer normally covers this)

`install.ps1` step 6a registers the admin. If it reported success, skip to
Stage 4. For recovery, register by hand — **the `/pacgate` prefix is required**:

```powershell
$body = @{email="qm-bridge@pacgate.local"; password="<strong-bridge-password>"} | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8089/pacgate/api/auth/register" -Method POST -Body $body -ContentType "application/json"
```

The un-prefixed `/api/auth/register` is routed to the frontend and rejected
with 403 "Cross-site auth request denied" — that is a missing path segment,
not a CORS or credentials fault.

## Stage 4 — qm (co-work lane; needs a client credential)

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\setup-qm.ps1
cd C:\pacgate-ai-pr\deploy\qm-pacgate
node_modules\.bin\qm.cmd up
```

- Sign-in email uses **Resend** (`AUTH_EMAIL_TRANSPORT=resend`), NOT Outlook
  SMTP (Microsoft retired Basic Auth for Exchange Online). Get a
  `RESEND_API_KEY` + verified sender from the client BEFORE this stage.
- Web-ui (`:8182`) is only reachable through the portal (`:8181`).
- qm is optional for the core surfaces; if the key is missing, skip qm,
  record it as a known gap, and finish the rest — do not block the install.

## Stage 5 — per-machine model overrides

The API defaults may name models absent from that machine. After Stage 3,
point the LLM tiers at models actually present in `ollama list` on THAT box
(model choice belongs to the client; never treat a tier set as fixed).
Reference set (benchmark 2026-08-28): `gemma4:12b-it-qat` main,
`qwen3.8:27b-mtp-q4_K_M` mid, `nomic-embed-text:latest` embeddings.
SQL template: `plans/007-aipc-full-installation-handoff.md` Appendix A.

## Stage 6 — first-install-only: register unattended updates

This is a FIRST-INSTALL step, not an update step — run it once per machine:

```powershell
cd C:\pacgate-ai-pr
pwsh -File scripts\register-scheduled-update.ps1 -BundleDir C:\pacgate-ai-pr\deploy\client-bundle
```

Creates scheduled task `PacgateAIPCUpdate` (daily 03:30 by default). After
this, future releases arrive via `install.ps1 -Update` unattended.

## Stage 7 — acceptance verification (run on EACH machine)

From the repo root:

```powershell
# 1. Version + revision compiled into the running binary
curl.exe -s http://localhost:8089/version

# 2. The whole legal journey: matter -> workflows -> upload -> OCR ->
#    sanitize -> review gate -> search -> cleanup. Exits non-zero on the
#    FIRST broken step; optional lanes print SKIP with a reason, never a
#    fake pass.
pwsh -File scripts\test-legal-journey.ps1
# expect: 15 assertions pass (2 lanes may SKIP: qm not running, OpenViking
#         recall needs an account-USER key)

# 3. Workflow library actually served (the clone-source trap detector)
#    expect 222 workflows across 46 categories via MCP:
#    pacgate_list_workflows inside an agent chat, or scripts\mcp-probe.py

# 4. Safety audit for pre-existing false `sanitized` documents
pwsh -File scripts\audit-false-sanitized.ps1
# expect: NO EXPOSURE, exit 0. If it reports exposure, STOP and escalate —
# do not delete or un-sanitize anything yourself.
```

## Stage 8 — smoke checklist (per machine, from the handbook Stage 6)

- [ ] 5 containers up: `docker compose -f compose.prod.yaml ps`
- [ ] `/version` returns the pinned release; `/pacgate/health` returns `ok`
- [ ] OpenViking healthy: `curl http://localhost:1933/health`
- [ ] LAN sign-in works from another device on the firm network
      (this exercises the step 4c CORS derivation)
- [ ] deer-flow answers a research request with citations at
      `http://localhost:8089/research/`
- [ ] upload a PDF -> OCR extract -> sanitize -> download
- [ ] scheduled task exists: `Get-ScheduledTask PacgateAIPCUpdate`

## Known traps (read before debugging anything)

| Symptom | Real cause |
|---|---|
| `:8089/health` returns a 404 HTML page | correct routing (nginx sends `/` to the frontend). Probe `/version` + `/pacgate/health` |
| `/version` returns 401 | the running image predates the version marker; the image is stale, the probe is fine |
| register returns 500 `default tenant not found` | tenant slug does not match `PACGATE_TENANT_ID` |
| register returns 403 "Cross-site auth request denied" | missing `/pacgate` prefix (or Origin not allowlisted — step 4c derives it; never hand-edit over an operator value) |
| only 10 workflows visible | cloned the fork instead of JZKK720 — reclone |
| login works on localhost but 403 from a LAN browser | `GATEWAY_CORS_ORIGINS` missing the LAN origin; re-run step 4c derivation |
| `docker compose pull` "reverts" behavior | expected — it restores the pinned published images over any local retag |
| MCP tools = 0 in agent chat | the rendered extensions config is stale; `install.ps1` step 2 re-renders it, then `docker compose restart deer-flow` |

## Post-install notes for the client

- Data residency: everything on-device except the intentional cloud chat
  models (deepseek-*-cloud) and the qm sign-in email (Resend). RAG, OCR,
  embeddings, and all matter data stay local.
- Backups: `docker exec pacgate-db pg_dump -U pacgate pacgate > backup.sql`
  plus the `./data/tenants/` directory.
- Updates are unattended after Stage 6; `/version` answers "am I current?"