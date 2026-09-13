# PacGate AIPC — Sign-in status & access (2026-09-01)

> **Finding:** Neither deer-flow nor qm has a working browser sign-in because the
> frontend/auth surfaces aren't deployed. This is NOT a credential problem — the
> backends are healthy and programmatic login works.

## Root cause (proven)

| Surface | Symptom | Root cause |
|---|---|---|
| **deer-flow** `:8089/research/` | Browser shows raw JSON `{"detail":{"code":"not_authenticated"}}` | The `deer-flow-pacgate:0.1.0` image is **backend-only** (`uvicorn app.gateway.app:app --port 8001`). No `index.html`/static files. The web UI is a separate Next.js app (`deer-flow/frontend`) that isn't deployed. |
| **qm** `:8182` | "Your session ended" → "reached through the portal... Open the portal address directly" | `qm.config.jsonc` runs only `["core","web-ui"]`. The **`portal`** (sign-in front door) and **`auth`** (sign-in broker) services are not running. |

## Verified: backends work

**deer-flow API login** (OAuth2 form, `username=` not `email=`):
```
POST http://localhost:8089/research/api/v1/auth/login/local
  Content-Type: application/x-www-form-urlencoded
  body: username=admin@pacgate-law.com&password=<pw>
→ 200 {"expires_in":604800,"needs_setup":false}   (sets session + CSRF cookie)
```

**deer-flow research round-trip** (verified): create thread → `POST /api/threads`, then `POST /api/threads/{id}/runs/wait` → real LLM response with citations.

**qm API login** — requires the `portal`/`auth` services (not deployed).

## Why sign-in fails

1. **deer-flow:** No frontend. `:8089/research/` proxy-passes to the deer-flow backend which returns 401 JSON. There's no login UI.
2. **qm:** Only `core`+`web-ui` started. The web-ui must be reached *through* the portal for auth, but the portal isn't running.

## Access paths (current — WORKING)

| Surface | URL | Status |
|---|---|---|
| **deer-flow web UI** | **`http://localhost:8090`** | ✅ **FULLY WORKING** — login as `admin@pacgate-law.com` → authenticated workspace |
| pacgate-api (metadata) | `http://localhost:8089/` | ✅ API |
| pacgate-api health | `http://localhost:8089/health` | ✅ `ok` |
| qm web-ui | `http://localhost:8182` | ⚠️ loads, but sign-in blocked (needs email transport) |
| qm core | `http://localhost:8180` | ✅ API (401 = auth required) |
| OpenViking | `http://localhost:1933` | ✅ health OK |

## Fixes available

### deer-flow web UI — ✅ DONE
Deployed `ghcr.io/bytedance/deer-flow-frontend:latest` as `deer-flow-frontend` container on host port **8090**, connected to the `client-bundle_default` network. Backend URL wired to `http://deer-flow:8001`. **Bug fixed:** the prebuilt image baked `/api/*` proxy rewrites to `127.0.0.1:8001` (unreachable from inside the container) — patched the running container's `.next/routes-manifest.json` to `http://deer-flow:8001`. Login verified in browser → authenticated workspace loads.

### qm portal/auth — ⚠️ BLOCKED (needs email transport)
The qm `auth` service is a **magic-link sign-in broker** that emails one-time links. It hard-requires `env.auth.AUTH_EMAIL_TRANSPORT` = `"resend"` or `"smtp"` (config validation fails otherwise). Without an email provider (SMTP/Resend credentials), enabling `portal`+`auth` **breaks qm startup**. Options:
- **Configure SMTP**: set `env.auth.AUTH_EMAIL_TRANSPORT: smtp` + SMTP host/port/user/pass in qm config → enables email-link sign-in.
- **Use Resend API**: set `env.auth.AUTH_EMAIL_TRANSPORT: resend` + `RESEND_API_KEY`.
- **Alternative**: qm web-ui without the portal can only be reached *through* the portal for auth; there's no local password login path today.

**Recommendation:** the deer-flow web UI now provides the working user-facing research frontend. For qm, provide an SMTP/Resend key when available, then enable `portal`+`auth`.
