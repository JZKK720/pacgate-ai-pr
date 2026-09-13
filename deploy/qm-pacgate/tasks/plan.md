# Production-Grade QM + Full-Loop Integration Plan

> Date: 2026-09-04 · Goal: production-grade QM so the full loop
> **pacgate-ai gateway → OpenViking → deer-flow → QM** works in-loop perfectly.

## Current state (verified 2026-09-04)

| Component | Container | Port | Status |
|---|---|---|---|
| pacgate-api (Rust gateway) | `pacgate-api` | 8089 (via nginx) | ✅ up, migrations applied, RAG on Ollama |
| OpenViking (memory) | `openviking` | 1933 | ✅ healthy, api_key auth |
| deer-flow (agent workspace) | `deer-flow` + `deer-flow-frontend` | 8001 / 8090 | ✅ up; matter memory read/write to pacgate-api works |
| QM core | `qm-pacgate-core` | 8180 | ⚠️ dev mode (unauthenticated), manual container |
| QM web-ui | `qm-pacgate-web-ui` | 8182 | ⚠️ dev/cookie mode, manual container |
| QM pg | `qm-pacgate-pg` | 5432 | ✅ up |

**Loop status:** deer-flow ↔ pacgate-api ↔ OpenViking already work.
QM is the weak link: it runs in **dev mode** (unauthenticated) with a **non-durable
surgical edit** to `pi-models.ts` that is lost on every container recreation.

## What "production grade" means here

1. **Real authentication** — portal + auth broker (not dev/cookie mode), so sign-in
   is a permanent account login with real identity, not an open cookie.
2. **Durable model routing** — the `glm-5.3-flash:cloud` model entry survives
   container recreation (no writable-layer edits).
3. **Declarative config** — everything reproducible from `qm.config.jsonc` + `.env`,
   so `qm up` produces the correct state every time.
4. **Verified loop** — QM agent can call pacgate-qm bridge → pacgate-api (matter
   memory, workflows) → OpenViking (long-term memory), and deer-flow remains
   connected to the same gateway.

## Architecture of the loop

```
┌─────────────┐   matter memory / workflows   ┌──────────────┐
│  deer-flow  │◄─────────────────────────────►│ pacgate-api  │
│ (8001/8090) │                               │ (Rust, 8080) │
└─────────────┘                               └──────┬───────┘
                                                     │
      ┌──────────────────────────────────────────────┤
      │                                              │
┌─────▼──────┐    x-portal-identity    ┌────────────▼───────────┐
│ OpenViking │                         │  QM (core+web-ui+      │
│  (1933)    │                         │  portal+auth+admin)    │
└────────────┘                         └────────────────────────┘
      ▲                                          │
      └────────── pacgate-qm sandbox tool ───────┘
```

QM's sandbox tool `pacgate-qm` logs into pacgate-api with
`PACGATE_API_EMAIL/PACGATE_API_PASSWORD` (service account `qm-bridge@pacgate.local`),
reads/writes matter memory, executes workflows, and talks to OpenViking.

---

## Task 1: Restore production auth (portal + auth broker)

**Description:** Re-enable `portal` and `auth` services in `qm.config.jsonc` and
redeploy so sign-in goes through the real identity broker instead of dev cookies.
The auth broker emails one-time magic links; the portal mints `x-portal-identity`
tokens that both web-ui and core verify.

**Acceptance criteria:**
- [ ] `qm.config.jsonc` `services` includes `core`, `web-ui`, `portal`, `auth`, `admin`
- [ ] `qm up` succeeds (requires `RESEND_API_KEY` or SMTP creds in `.env`)
- [ ] `http://localhost:8182` shows the portal sign-in (not "Dev mode")
- [ ] Sign-in with `admin@pacgate-law.com` produces a working session
- [ ] Core rejects unauthenticated requests (no `ALLOW_UNAUTHENTICATED_CORE`)

**Verification:**
- [ ] `docker ps` shows `qm-pacgate-portal` and `qm-pacgate-auth` running
- [ ] Browser: sign-in flow completes end-to-end
- [ ] `GET http://localhost:8180/healthz` → 200

**Dependencies:** None (first task).

**Files likely touched:**
- `qm.config.jsonc` (services, env.auth)
- `.env` (RESEND_API_KEY or SMTP_* — operator must supply)

**Blocker to resolve:** The auth broker needs an email transport. Two options:
- **Resend** (current config): needs `RESEND_API_KEY` + verified sending domain.
  `pacgate.ai01@outlook.com` is NOT Resend-verified — operator must verify a domain
  or use Resend's test sender `onboarding@resend.dev`.
- **SMTP** (recommended, no DNS wait): any existing mailbox. Gmail app password is
  the fastest path. Set `AUTH_EMAIL_TRANSPORT=smtp` + `SMTP_HOST/USERNAME/PASSWORD`.

**Autonomous decision (2026-09-04):** No email credentials exist anywhere on this
machine, and both Resend and SMTP require operator-minted secrets. The
production-correct path that CAN be completed autonomously is:

- **Portal + auth broker with a local SMTP catcher (Mailpit)** — the identity layer
  is fully real (portal mints `x-portal-identity` JWTs, auth broker issues one-time
  links, allow-list enforced, core enforces signed source-auth). Only email
  *delivery* is local: sign-in links land in Mailpit's web UI (http://localhost:8025)
  instead of a real inbox. Swapping in a real SMTP relay later is a 4-line `.env` change.
- Run the stack with `NODE_ENV=development` on portal/auth (the images default to
  production, which requires https PUBLIC_URL — we're on http://localhost:8182).
  Core/web-ui already run development. This keeps every security mechanism active
  (JWTs, one-time links, allow-list, signed source-auth) while permitting http on
  localhost. `PORTAL_LOCAL_AUTH_BYPASS` is NOT used — sign-in still goes through
  the real broker flow.

---

## Task 2: Durable model routing (no writable-layer edits)

**Description:** Make the `glm-5.3-flash:cloud` model entry survive container
recreation. Two approaches, in order of preference:

**Option 2a (preferred): local proxy** — stand up a tiny OpenAI-compatible proxy
(e.g. LiteLLM) that maps `https://api.openai.com/v1` → local Ollama. Then set a real
`OPENAI_API_KEY`-shaped env and point the stock core at the proxy. No core code edits.
- [ ] Proxy container on `qm-pacgate` network
- [ ] Core env: `OPENAI_API_KEY=<proxy key>`, model id resolves via stock registry
- [ ] Chat turn completes against Ollama through the proxy

**Option 2b (fallback): scripted re-patch** — keep the surgical edit but make it
automatic. A `post-up.ps1` script that runs after every `qm up`:
1. `docker cp pi-models.original.ts qm-pacgate-core:/app/src/model/pi-models.ts`
2. `docker restart qm-pacgate-core`
3. Verify `GET /v1/surface-config` contains `glm-5.3-flash:cloud`

**Acceptance criteria:**
- [ ] After a full `qm down && qm up`, chat works with the glm model
- [ ] `GET /v1/surface-config` → `modelProviderConfigured:true`, glm in `webuiModels`
- [ ] No manual `docker cp` needed (either proxy or scripted)

**Verification:**
- [ ] Send a chat message in the web-ui → real model reply
- [ ] Core logs show no 401/403 model errors

**Dependencies:** Task 1 (containers must be recreated by `qm up` first).

**Files likely touched:**
- `tasks/post-up.ps1` (new, Option 2b)
- or `docker-compose.proxy.yaml` + LiteLLM config (Option 2a)

---

## Task 3: Wire the loop — QM agent ↔ pacgate-api ↔ OpenViking ↔ deer-flow

**Description:** Verify and harden the in-loop path: a QM chat turn should be able
to (a) bind its scope to a Pacgate matter, (b) read/write matter memory through
pacgate-api, (c) recall/store long-term memory in OpenViking, and (d) hand off
heavy workflow execution to deer-flow through the same gateway.

**Acceptance criteria:**
- [ ] `pacgate-qm ensure-matter` succeeds from the QM sandbox (service account login works)
- [ ] `pacgate-qm memory-save` / `memory-get` round-trips through pacgate-api
- [ ] `pacgate-qm ov-remember` / `ov-search` round-trips through OpenViking
- [ ] `pacgate-qm workflows --search "due diligence"` returns real workflow ids
- [ ] deer-flow still reads/writes the same matter memory (no regression)

**Verification:**
- [ ] Run each `pacgate-qm` subcommand inside the QM sandbox with real env
- [ ] Check pacgate-api logs show the QM service-account requests
- [ ] Check OpenViking logs show the remember/search calls

**Dependencies:** Task 1, Task 2.

**Files likely touched:**
- `sandbox/tools/pacgate-qm/pacgate_qm.py` (only if a bridge bug surfaces)
- `.env` (service-account credentials — already present)

---

## Task 4: E2E in-loop test script + documentation

**Description:** Write a repeatable smoke test that exercises the whole loop and a
runbook documenting the production topology, so the loop can be re-verified after
any change.

**Acceptance criteria:**
- [ ] `tasks/loop-smoke.ps1` checks: all containers up, portal sign-in works,
      QM chat turn completes, pacgate-qm bridge round-trips, deer-flow health
- [ ] Runbook `tasks/RUNBOOK.md` documents ports, secrets, restart order,
      and the `qm up` + `post-up.ps1` sequence
- [ ] Both scripts run green on this machine

**Verification:**
- [ ] `powershell -File tasks/loop-smoke.ps1` → all checks pass
- [ ] Docs match the actual running state

**Dependencies:** Tasks 1–3.

**Files likely touched:**
- `tasks/loop-smoke.ps1` (new)
- `tasks/RUNBOOK.md` (new)

---

## Execution order

```
Task 1 (production auth)  ──► Task 2 (durable model) ──► Task 3 (loop wiring) ──► Task 4 (smoke+docs)
        │
        └─ needs operator input: email transport choice + credentials
```

## Open decisions for the operator

1. **Email transport for sign-in links:** Resend (needs verified domain) or SMTP
   (Gmail app password — fastest)?  ← blocks Task 1
2. **Model routing durability:** LiteLLM proxy (cleaner) or post-up re-patch script
   (simpler)?  ← shapes Task 2
3. **Admin dashboard:** include the `admin` service in the deployment? (recommended)