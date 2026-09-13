# Plan 010 — QM single-stack migration (qm up → compose.qm.yaml)

Date: 2026-09-06. Status: **COMPLETED** on AIPC2. Mode: direct.

## Why
The QM stack was created by the `qm` CLI (`qm up`), which gives containers NO
`com.docker.compose.project` label → Docker Desktop showed 7 loose containers
instead of one grouped stack. Upstream added `deploy/qm-pacgate/compose.qm.yaml`
(86d8b91 + 84392dd) mirroring the exact topology with external network/volumes so
data survives. This plan migrated the live stack to that file.

## Pre-flight (all verified before touching containers)
- 12 secrets in `.env` all MATCH live container values (CORE_SIGNING_SECRET,
  PORTAL_IDENTITY_SECRET, AUTH_CLIENT_SECRET, CAPABILITY_SECRET, CONNECTOR_SECRET_KEY,
  SKILL_SIGNING_SECRET, PORTAL_SESSION_SECRET, AUTH_TOKEN_SECRET, SMTP_PASSWORD,
  AUTH_SIGNING_JWK, + web-ui/admin CORE_SIGNING_SECRET) → no session rotation.
- Image digests in compose.qm.yaml == running containers (core bee03e7f…, web-ui
  f037834f…, portal e245dfc2…, auth 27f2e146…, admin ec071338…).
- Mounts: core = qm-pacgate-coredata:/data + ./sandbox/skills:/layer/skills +
  ./sandbox/tools:/layer/tools (all present). pg = qm-pacgate-pgdata.
- Ports: core 8180, portal 8181, web-ui 8182, admin 8183, mailpit 8025, auth internal.
- Network `qm-pacgate` had exactly the 7 members (no orphaned sandboxes).
- mailpit: running `:latest`, compose pins `:v1.24` (different digest) — stateless,
  acceptable (drops captured emails only).

## .env gaps filled (gitignored, machine-specific)
- `POSTGRES_PASSWORD` (was absent → compose would default blank and break core→pg).
  Copied from live pg container (32-char).
- `FLY_BASE_IMAGE` (compose fallback was stale 207a779d…; live core runs 5da1e086…).
- `MODEL_API_KEY=ollama-local` (parity with live OPENAI_API_KEY; Ollama doesn't
  validate, but keeps parity). Deduped a duplicate MODEL_API_KEY line.

## Tracked changes (committed + pushed)
- `5cf8e29` feat(qm): pin container_name on all 7 services (so `docker exec
  qm-pacgate-core`, tasks/patch-pi-models.sh, handbooks keep exact names; compose
  would otherwise auto-suffix `-1`).
- `add296c` fix(qm): compose.qm.yaml sandbox env parity — FLY_RESIDENT_ENV_PACGATE_API_URL
  now `http://host.docker.internal:8089/pacgate` (nginx routes metadata under /pacgate/)
  + added FLY_RESIDENT_ENV_OPENVIKING_ROOT_API_KEY (mirrors upstream 7528e49 qm.config fix).

## Execution
1. `docker stop` + `docker rm` the 7 qm containers (named volumes + network persist).
2. `docker compose -f compose.qm.yaml up -d` → all 7 recreated, grouped.
3. **pi-models patch re-applied** (fresh core writable layer lost it):
   - `docker cp tasks/patch-pi-models.sh qm-pacgate-core:/tmp/`
   - **CRLF gotcha**: git Windows checkout converts the .sh to CRLF → container sh
     fails `set -e` ("illegal option -"). Convert to LF first.
   - `docker exec -u root qm-pacgate-core sh /tmp/patch-pi-models.sh` (file is
     root-owned, container runs as node).
   - `docker restart qm-pacgate-core` (NOT up/recreate — would wipe the patch).
   - Verify: `grep -c glm-5.3-flash /app/src/model/pi-models.ts` = 2, and
     `defaultModelForProvider('pi','openai')` = glm-5.3-flash:cloud.

## Verification (all green)
- All 7 containers `project=qm-pacgate` (Docker Desktop now groups them).
- Endpoints: portal 8181 (401 on bare GET = auth-gate, expected), web-ui 8182 200,
  admin 8183 200, mailpit 8025 200. Core logs: "listening on :8080 (store=postgres)".
- DB intact: full schema present, `base_model_configs` = org:pacgate →
  {"modelId":"glm-5.3-flash:cloud"}. Core /data volume intact (workspaces).
- **Magic-link login E2E**: portal → enter admin@pacgate-law.com → mailpit captures
  "Sign in to PacGate" → open link → confirm → QM web UI loads signed in, prior
  sessions ("Web chat, 19h ago"/"1d ago") intact.

## Gotchas learned
- PowerShell mangles inline `node -e`/`sh -c` with quotes → always write a script
  file, `docker cp` it, run it.
- `docker exec -d` + log redirect lost output earlier; run synchronously.
- Playwright click on the QM sign-in button times out on stability; use
  `form.requestSubmit()` via page.evaluate instead.
- After migration, lifecycle = `docker compose -f compose.qm.yaml up/down/ps/logs`.
  NEVER run `qm up` against this directory again (fights over same volumes/network).
- `qm down`/`compose down` keeps external volumes → data persists; rollback = down +
  `qm up` restores old shape.

## Deferred
- Fresh-clone `install.ps1` dry-run before client delivery (repo rule).
- Consider a `v0.1.8` tag if the EUR-Lex connector fix should ship in a published image.
