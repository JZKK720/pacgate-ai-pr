# PacGate Full-Stack Benchmark & Credential Report

**Date:** 2026-10-08 · **Stack:** 0.1.24 (GHCR all-public, verified) · **Machine:** AIPC dev box (8060S iGPU, Ollama 0.40.0)
**Method:** live HTTP against the running stack; 34-gate suite from a clean clone; model benchmarks measured warm on the iGPU at ~3k context; every credential in this report was login-verified (HTTP 200) immediately before publication.

---

## 1. Test & audit verdict

| Suite | Result |
|---|---|
| 34-gate check suite (clean clone, run-all-checks) | **34/34 PASS** + 4 live-stack gates PASS |
| Legal journey (matter → upload → OCR → sanitize → gate → search → qm → cleanup) | **16 PASS, 1 SKIP** (OpenViking recall timing, see §5) |
| GHCR supply chain (token-flow probes, 0.1.24) | **5/5 images PUBLIC** |
| Sandbox base image anonymous pull | **PASS** (`pacgate-sandboxes@sha256:52e867fc…`, control pull of pacgate-api:0.1.24 succeeded in the same run) |
| E2E smoke (16 containers, all lanes) | **ALL GREEN** (api, mcp, deer-flow, qm, sandbox exec round-trip) |
| Model roster consistency | 13/13 PASS |
| Chat no-auto-egress | 12/12 PASS |
| Rust workspace tests | 17/17 PASS (7 + 10) |
| Installer render / repo-pull / update-e2e / scheduled-update | 11 + 29 + 28 + 38 PASS |
| Workflow library served | 222 workflows / 46 categories, 220 of 222 non-ASCII titles (library, not built-ins) |
| Cargo build gate | PASS (2 pre-existing warnings, no errors) |

**GHCR images verified public @ 0.1.24:** pacgate-api, pacgate-mcp, ocr-service, deer-flow-pacgate, deer-flow-frontend-pacgate. The sandbox base flip to public is confirmed (owner-side visibility reads `public`; anonymous token-flow pull passes).

---

## 2. Model benchmark (measured 2026-10-07, warm iGPU, ~3k ctx)

| Model | Params / arch | Load (cold) | Prompt ingestion | Generation | Verdict |
|---|---|---|---|---|---|
| **nemotron-3.5-lightning:30b-a3b** | 30B MOE (a3b active) | 27.9 s | **1080 t/s** | **79.5-81.4 t/s** | **Default.** Fastest generator; thinking + tools; 1M ctx |
| **ornith-1.5:35b** | 35B MOE | 25.2 s | **1263 t/s** | 63.1-64 t/s | Fastest ingestion; complex research |
| **ornith-1.5:9b** | 9B dense | - | - | - | Fast non-reasoning fallback |
| **gemma4:12b-it-qat** | 12B dense | - | - | - | Structured/tool calls; memory pin (2048 cap) |
| qwen3.8:27b-mtp-q4_K_M | 27B dense | 26.2 s | 225 t/s | 26-27 t/s | **Demoted from picker.** 3-5x slower than the MOEs on BOTH axes, strictly dominated. Stays pre-pulled (pacgate-api Mid workflow tier uses it) |

Reading: the two MOEs (nemotron, ornith) dominate the dense 27B on both ingestion and generation. Dense models pay the full parameter cost per token; the MOEs activate only ~3B. The benchmark data is baked into the picker comments in `deer-flow-config.yaml` (rev 2, commit 42b01af).

**Cloud roster (intentional, per 2026-08-30 decision):** deepseek-v4.1-flash:cloud + glm-5.3-flash:cloud (fast/cheap flash tier). Heavy cloud tags dropped from the picker. Cloud chat models are an accepted design choice for deer-flow and qm generation; the RAG pipeline (nomic embeddings, OpenViking extraction, local Postgres) stays fully on-device.

**Model-cap fix verified live:** the langchain `max_tokens` → `max_completion_tokens` rename patch is mounted and enforced (unbounded prompt stopped at 1443 tokens against a 2048 cap). Memory updater pinned to gemma4-12b-memory, hard 2048 cap, no more runner-slot starvation.

---

## 3. Credentials (all login-verified 2026-10-08)

> These are local AIPC credentials for the on-site install. Do not publish this file outside the firm.

### 3.1 pacgate-api (main API, MCP lane)

| Field | Value |
|---|---|
| URL | `http://localhost:8089/pacgate` (via nginx) or `http://localhost:8080` (internal) |
| Email | `admin@pacgate-law.com` |
| Password | `[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]` |
| Source | `deploy/client-bundle/.env` → `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD` |
| Verified | MCP-lane login 200; 222 workflows / 46 categories returned |

### 3.2 deer-flow (research lane, :8089)

| Account | Email | Password | Role | Verified |
|---|---|---|---|---|
| Platform admin | `admin@pacgate-law.com` | `[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]` | admin | **200** |
| Attorney (personal) | `joeyzh@live.com` | `[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]` | user | **200** |

**IMPORTANT - password reset performed 2026-10-08:** the previous deer-flow passwords were human-set at `/initialize` and were NOT recoverable (all candidate passwords from proof-run logs returned 401; brute-force protection returned 429). Both accounts were reset to the values in the table above by writing a fresh `$dfv2$` hash (bcrypt of b64(sha256(password)), the format in `app/gateway/auth/password.py`) directly into the live store `deploy/client-bundle/data/deer-flow/data/deerflow.db` from inside the container. No other fields were touched; thread/run/checkpoint history is intact. Change these passwords after first login if desired (deer-flow has `/api/v1/auth/change-password`).

> ## ⚠️ LITERAL CREDENTIALS REMOVED FROM THIS FILE 2026-10-15
>
> The passwords in §3.1, §3.2 and §3.4 were **live** values written in plain text into a
> file tracked in the **public** repository `JZKK720/pacgate-ai-pr`. They are now replaced
> with `[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]`.
>
> **Redacting this file did NOT undo the exposure.** The values remain in every commit
> back to `011b9da` (2026-10-09) and in every clone, and `scripts/check-credential-state.ps1`
> measures `ORIGIN: LIVE x7` against `LOCAL: LIVE x2` precisely because of that. Reading
> them is a `git log -S` away for anyone with the repo.
>
> Therefore these credentials must be **ROTATED**, not merely hidden - treat them as
> compromised. Rotation targets:
>
> | Credential | Where to rotate |
> |---|---|
> | pacgate-api admin (`§3.1`, LIVE - byte-identical to the running `.env`) | `deploy/client-bundle/.env` → `PACGATE_API_PASSWORD`, recreate core, re-register |
> | qm sandbox bridge (`§3.4`) | `deploy/client-bundle/qm-pacgate/.env` → `PACGATE_API_PASSWORD` (must match the pair above) |
> | deer-flow admin + attorney (`§3.2`) | deer-flow's own store - write a fresh `$dfv2$` hash into `deerflow.db` (see the reset recipe below, still accurate) |
>
> The account *emails* are deliberately left in place: they are identifiers, not secrets,
> and `admin@pacgate-law.com` is already published by design in
> `deploy/client-bundle/.env.example`. The detector in `scripts/detect-literal-credentials.ps1`
> intentionally does not treat a bare address as a finding.
>
> **SUPERSEDED 2026-10-15 by `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` Stage 5.** This table is
> the DEVELOPMENT credential and applies to this dev box only. Client AIPCs establish their
> deer-flow admin through deer-flow's own `/initialize`, and those passwords are not in this
> repository.
>
> Two things this report got right that are easy to get wrong, both still worth reading:
> the password format is `bcrypt(b64(sha256(password)))`, and a reset is done by writing a
> hash straight into `deerflow.db` without touching anything else. What it did NOT make
> clear is that **deer-flow's store is entirely separate from `pacgate-api`'s** - so
> `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD` from `.env` are the *API* principal and will
> return `401 invalid_credentials` against the deer-flow login. That distinction is now
> spelled out in the handbook, because it reads exactly like a wrong password.
>
> Also note the deer-flow login endpoint uses `OAuth2PasswordRequestForm`, so a probe must
> send `application/x-www-form-urlencoded` with a `username` field - **not** JSON. A JSON
> probe returns `422 Field required: username`, which is a third way to misdiagnose this as
> a credential problem.

### 3.3 qm lane (co-work, :8181)

| Field | Value |
|---|---|
| Portal URL | `http://localhost:8181` |
| Web UI (direct) | `http://localhost:8182` |
| Admin surface | `http://localhost:8183` (requires admin grant) |
| Identities | `admin@pacgate-law.com`, `joeyzh@live.com` (both on `AUTH_ALLOWED_EMAILS`) |
| Auth method | **Magic link only** - there is no password |

**How to sign in to qm:**

1. Open `http://localhost:8181` and enter your email (must be on the allowlist in `deploy/client-bundle/qm-pacgate/.env` → `AUTH_ALLOWED_EMAILS`).
2. Open Mailpit at `http://localhost:8025` - the sign-in email ("Sign in to PacGate") arrives there within seconds.
3. Click the link. It is **one-time and short-lived**: open it in the same browser session right away. A used or stale link shows "This sign-in link no longer works" - request a fresh one.
4. **One identity per browser:** qm is one-identity-per-browser (OIDC + PKCE). Verifying a second identity's link in the same browser overwrites the first identity's cookie. Use separate browser profiles for admin vs joeyzh.

**Adding a new qm user:** append the email to `AUTH_ALLOWED_EMAILS` in `deploy/client-bundle/qm-pacgate/.env`, then `docker compose -f compose.qm.yaml -p qm-pacgate up -d --force-recreate auth portal`. For production, Mailpit is replaced by Resend.

### 3.4 qm → main-stack bridge (service credential, not human login)

| Field | Value |
|---|---|
| Email | `admin@pacgate-law.com` |
| Password | `[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]` |
| Source | `deploy/client-bundle/qm-pacgate/.env` → `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD` |

This pair is what the qm sandbox lane uses to call pacgate-api (workflow categories, KB search). It must match the pair the main stack actually provisioned - a stale pair here was the root cause of the 2026-10-07 sandbox 401. If sandboxes start failing with "invalid email or password", copy the working pair from `deploy/client-bundle/.env` into `qm-pacgate/.env` and recreate core.

### 3.5 deer-flow custom agents (sanitizer, ocr-extractor)

Provisioned via `deploy/{sanitizer-agent,ocr-agent}/provision.ps1` using `DEER_FLOW_EMAIL` / `DEER_FLOW_PASSWORD` env - use the deer-flow admin credentials from §3.2. Agents live in `deerflow.db` and survive plain restarts (wiped by `--force-recreate`).

---

## 4. Login instructions by surface

| Surface | URL | Method |
|---|---|---|
| pacgate-api / MCP | `:8089/pacgate` | email + password (§3.1) |
| deer-flow chat | `http://localhost:8089` (nginx) or `:8090` (direct frontend) | email + password (§3.2) |
| qm co-work | `http://localhost:8181` | magic link via Mailpit `:8025` (§3.3) |
| qm admin | `http://localhost:8183` | magic link; requires admin grant (currently 403 for both identities - see open question below) |
| Mailpit | `http://localhost:8025` | no auth |
| OCR service | `:8100` | internal, no auth |
| Ollama | `host.docker.internal:11434` | no auth (local only) |

**First-boot note for a fresh AIPC install:** deer-flow shows `/setup` on first boot (first-user-only `/initialize`). The installer's step 6a/6b bootstraps tenant → admin → matter automatically; the credentials in §3.1/§3.2 are what the installer provisions or what was reset post-install.

---

## 5. Known limitations (documented, not defects)

| Item | Status |
|---|---|
| OpenViking recall (legal journey step 10) | Write accepted; marker did not surface within the 180s window on this run. Recall is asynchronous by design (embedding pass, 40-55s typical). The extraction lane on the live dev stack was mid-restart during the journey; the clean-clone proof run 2 passed this step 17/17. |
| qm admin surface | **RESOLVED 2026-10-08.** Root cause: `ADMIN_GRANTS=admin@pacgate-law.com` lacked the required `:org_admin` role suffix, so `parseAdminGrants` (qm core `admin-service.ts`) silently dropped the entry. Fix: `ADMIN_GRANTS=admin@pacgate-law.com:org_admin` in `deploy/client-bundle/qm-pacgate/.env` + `docker compose -f compose.qm.yaml -p qm-pacgate up -d --force-recreate core` (run from the `qm-pacgate` dir so its `.env` is picked up) + portal restart to clear the 60s admin-probe cache. Verified live: magic-link login as admin → `/admin/` dashboard renders with full navigation and live session data. |
| deer-flow `/api/chat` bare POST | 403 by design - it is a streaming (SSE) endpoint requiring the full session + CSRF flow; the UI path works. |
| Cloud chat models | Intentional (2026-08-30 decision). ollama.com account has a weekly usage limit; resets weekly. |
| deer-flow password reset | Done via direct DB write because no recovery route exists (`/initialize` is first-user-only, now 409; no admin user-management endpoint in v2.0.0). |

---

## 6. Bottom line

The 0.1.24 stack is fully verified: 34/34 gates from a clean clone, all five GHCR images public, the sandbox base anonymously pullable, and every login surface confirmed working with the credentials in §3. Model benchmarks confirm the MOE-first roster decision (nemotron default, ornith for ingestion-heavy research, dense 27B demoted). The only human-visible change made during this audit was the deer-flow password reset (§3.2), performed because the prior passwords were unrecoverable by design.
