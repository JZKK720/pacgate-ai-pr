# Assigned-user authentication for the deer-flow frontend

**Date:** 2026-09-21
**Status:** DESIGN — architecture chosen (Option D: one identity on the AIPC, many
in qm). Open items are the qm prerequisites in §2A/§2B, not the architecture.
**Related:** `deploy/DEER-FLOW-UPSTREAM-DRIFT-ASSESSMENT-2026-09-21.md`,
`plans/023-deer-flow-2.1-upgrade.md`, `deploy/qm-pacgate/`

## 1. The finding, confirmed

`v2.0.0` (our pinned base) has **no registration gate of any kind**. Upstream
added one in 2.1.0; our release predates it.

### 1.1 Code evidence

`backend/app/gateway/routers/auth.py` at `v2.0.0`:

```python
@router.post("/register", response_model=UserResponse, status_code=201)
async def register(request: Request, response: Response, body: RegisterRequest):
    """Register a new user account (always 'user' role)."""
    try:
        user = await get_local_provider().create_user(
            email=body.email, password=body.password, system_role="user")
    except ValueError:
        raise HTTPException(status_code=400, detail=... "Email already registered" ...)

    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)   # <-- auto-login
    return UserResponse(...)
```

- No admin check, no invite token, no email-domain allowlist, no config flag.
- The response **sets the session cookie**, so registering logs you straight in.
- `auth/config.py` at `v2.0.0` models only `jwt_secret`, `token_expiry_days`, and
  GitHub OAuth. There is no `allow_registration` field to set.

`backend/app/gateway/auth_middleware.py` at `v2.0.0`:

```python
_PUBLIC_EXACT_PATHS = frozenset({
    "/api/v1/auth/login/local",
    "/api/v1/auth/register",
    "/api/v1/auth/logout",
    "/api/v1/auth/setup-status",
    "/api/v1/auth/initialize",     # <-- also unauthenticated
})
```

### 1.2 Live proof (non-destructive)

POSTing to `/api/v1/auth/register` with a deliberately invalid payload (which
fails Pydantic validation and therefore **creates nothing**) reached the endpoint
and returned a validation error rather than a denial:

```
POST /api/v1/auth/register        -> HTTP 422  (field validation only)
GET  /api/v1/auth/setup-status    -> HTTP 200  {"needs_setup":false}
```

Both through nginx `:8089` and directly against the frontend `:8090`. A 422 means
the route is reachable and the handler ran; combined with the code above (no gate),
a valid payload creates an account. No account was created during this probe.

### 1.3 Why this is worse than "outsiders can make an account"

The frontend's MCP tools authenticate to pacgate-api with a **shared service
identity** — from `compose.prod.yaml`:

```yaml
PACGATE_JWT_TOKEN:   ${PACGATE_JWT_TOKEN}
PACGATE_TENANT_ID:   ${PACGATE_TENANT_ID:-default-firm}
PACGATE_MATTER_ID:   ${PACGATE_MATTER_ID}
```

The MCP server holds one credential for one tenant and one matter. It does not
receive the deer-flow user's identity. So **any account that can open the chat can
query firm data** through `pacgate_*` tools — the account is not a per-user
identity boundary for the knowledge base.

Also worth knowing:

- **`/api/v1/auth/initialize` is public.** It creates the first **admin** and is
  only refused once an admin exists (`409 SYSTEM_ALREADY_INITIALIZED`). On a
  **freshly installed but not yet initialised** AIPC, anyone who reaches the URL
  can create the admin account and own the deployment. Our `install.ps1` does not
  create the admin, so this window is real and lasts until a human completes
  setup. Current machine shows `needs_setup: false`, i.e. already initialised —
  but the window exists on every new install.
- **The frontend port bypasses nginx.** `8090:3000` is published directly, so the
  gateway is reachable without going through the ingress that carries the
  `GATEWAY_CORS_ORIGINS` guard discussed in earlier notes. Any fix applied only in
  nginx is bypassable on that port.
- **There is no admin user-management endpoint.** Neither `v2.0.0` nor `v2.1.0`
  exposes one — verified by enumerating every `@router.` decorator in both. The
  only account-creation paths are `/register`, `/initialize`, and OAuth. The only
  operational tool is `auth/reset_admin.py`, which resets an **existing** admin's
  password and cannot create users.

### 1.4 Upstream's fix

2.1.0 changelog (#4311): *"Deployments can close local self-registration to
restrict new accounts to SSO/OIDC provisioning."* Implementation:

```python
def _local_registration_enabled() -> bool:
    try:
        return get_app_config().auth.local.allow_registration
    except FileNotFoundError:
        return True     # absent config => still open, deliberately
```

Config key: `auth.local.allow_registration`. Our fix should mirror this name and
semantics so it **drops away at the 2.1.0 upgrade** instead of drifting.

## 2. The design problem

Closing registration is easy. The hard part is the user's actual requirement:
*assign users so they can log in and use the frontend remotely.*

Two facts constrain the design:

1. **deer-flow owns its own account store** (SQLite `deerflow.db`, with its own
   password hashing and JWT). Closing `/register` means the only remaining way to
   create an account is `/initialize` (admin-only, once).
2. **A per-user deer-flow account does not, by itself, give per-user data
   isolation**, because MCP uses the shared service credential (§1.3). Per-user
   accounts fix *who can get in*; they do not yet fix *whose data they see*.

Being explicit about that gap matters — otherwise we ship an access control that
looks like data isolation and is not.

## 2A. Division of labour: one identity on the AIPC, many in qm

**This is the simplest architecture that meets the requirement, and it uses a
multi-user stack we already have.** Rather than building user provisioning for
deer-flow, split the surfaces:

| Surface | Who signs in | Identity model |
| --- | --- | --- |
| deer-flow research workspace (the AIPC web URL) | **one account**, the Pacgate AI user | single credential gate |
| qm co-working team space | **many named users** | per-person email allowlist |

qm already ships real multi-user authentication, so the "assign users" problem is
largely solved there rather than something we build:

- **Assignment is an exact-match email allowlist.** `AUTH_ALLOWED_EMAILS` is a
  plain comma-separated list; the `auth` broker and the `portal` both do an exact
  match on the submitted email. `env.auth.AUTH_ALLOWED_EMAIL_DOMAIN` admits a
  whole domain. There is also `ADMIN_GRANTS=<email>:org_admin` for the first
  administrator.
- **Sign-in is a one-time emailed link — no passwords to manage.** The `auth`
  broker mails a link per attempt; the `portal` mints `x-portal-identity` tokens
  that `web-ui` and `core` verify. We never store or reset a user password. This
  removes the largest piece of custom work Option A implied.
- **The `portal` is the front door** (`basePort+1` = **8181**), proxying to
  `web-ui` and `admin`. `core` is 8180, `web-ui` 8182.

Verified on our own deployment:

- `deploy/qm-pacgate/qm.config.jsonc` already runs the full set:
  `"services": ["core", "web-ui", "portal", "auth", "admin"]`.
- All five pinned images are **anonymously pullable** from GHCR (checked by
  digest), so a client AIPC can deploy this stack the same way it pulls ours.
- `qm.config.jsonc` states that `NODE_ENV=development` on portal/auth exists only
  to permit `http://localhost` URLs, and that "every other security mechanism (JWT
  identity, one-time links, allow-list, signed source-auth) stays active". So the
  dev flag is not an auth bypass — but see the caveat in §2B.

### The one real prerequisite: an email transport

One-time links must be *delivered*, so a working email transport is mandatory
(not optional polish). `env.auth.AUTH_EMAIL_TRANSPORT` is `smtp` or `resend`:

- **SMTP is the recommendation** — any existing mail account or relay works
  (Google Workspace, Postmark, SES, Fastmail, the firm's own server) and needs no
  DNS work. `qm setup` collects host/username/password. `SMTP_TLS=none` is
  **refused in production**, which is correct — do not weaken it to make a local
  test pass.
- **Resend requires DNS control over a sending domain** and can take hours to
  verify; sending from an unverified domain fails at delivery, not at setup.

This is the item most likely to stall a deployment, and it needs the operator's
mail credentials. Decide the transport before building anything.

### What the operator controls

- **Who is in qm**: edit `AUTH_ALLOWED_EMAILS` / `AUTH_ALLOWED_EMAIL_DOMAIN`, then
  re-run the deploy. Assignment is declarative, reviewable, and in git-adjacent
  config rather than scattered accounts.
- **Who reaches the AIPC at all**: the single deer-flow credential.

## 2B. Caveats worth knowing before committing

1. **qm's auth stack is built and configured but not currently running here.**
   No qm containers exist on this box and the runtime copy
   (`deploy/client-bundle/qm-pacgate/`) is not staged. An internal task list
   (`deploy/qm-pacgate/tasks/plan.md`, dated 2026-09-04) records qm core/web-ui as
   having run in **dev/cookie mode, unauthenticated**, with "restore production
   auth" as task 1. The config has since moved to the full five-service topology,
   but that state has **not been proven on a real machine** in this session. Until
   it is, the multi-user surface should not be presented to a client as ready.
2. **qm is outside `install.ps1 -Update`.** Its runtime config is a separate
   directory that nothing re-stages, so a qm auth or allowlist change requires
   re-running `setup-qm.ps1` by hand. Adding `AUTH_ALLOWED_EMAILS` therefore creates
   a recurring manual step, not a one-off.
3. **Two front doors to harden, not one.** With this split there are two browser
   surfaces (the AIPC's deer-flow URL and qm's portal). Both need the same
   decisions about exposure, TLS, and rate limiting. That is more surface area
   than Option A, and it should be a conscious trade rather than an accident.
4. **qm's client-facing URL will need a real public origin.** `publicUrl` is
   currently `http://localhost:8181` and the service URLs derive from it, so remote
   sign-in needs a resolvable host and TLS configuration.

## 3. Options

### Option A — Close registration, provision accounts per user (recommended)

1. **Gate `/register`** with a 9th mounted patch to
   `backend/app/gateway/routers/auth.py`, mirroring upstream: if
   `auth.local.allow_registration` is false, return `403`. Default it **false** in
   our `deer-flow-config.yaml`. Keep the key name identical to upstream.
2. **Provision users explicitly.** Create accounts with deer-flow's own
   `create_user()` by running a small script **inside the deer-flow container**
   (the same pattern `auth/reset_admin.py` already uses). This avoids reimplementing
   deer-flow's password hashing or writing to its SQLite schema by hand. Wrap it as
   `scripts/provision-deer-flow-user.ps1` so an operator assigns users one by one.
3. Users then sign in remotely through the normal login page with their assigned
   credentials.

- **Pros:** small, mirrors upstream (removable at upgrade), no new user store, no
  duplication of credentials, real per-user accounts.
- **Cons:** provisioning is operator-driven (by design — "assigned" is the
  requirement); no self-service password reset; does not by itself isolate data
  (§5).

### Option B — Per-user front door via an authenticating proxy

Reuse the `auth-gate` pattern already in the repo (see §4) as a per-user front
door in front of the frontend.

- **Pros:** full control of the user list, independent of deer-flow's account
  model, easy to put behind a VPN.
- **Cons:** it cannot mint deer-flow identities — either users still need a
  deer-flow account (so we need Option A anyway), or everyone shares one account
  and we lose attribution. Adds a second session layer. **Does not replace A.**

### Option C — Bring the 2.1.0 upgrade forward

The vulnerability is *fixed by* the upgrade.

- **Pros:** no local patch; we get the real fix plus the rest of 2.1.0.
- **Cons:** 2.1.0 is a release candidate still receiving ~17 commits/day, and the
  upgrade is a rebase project (see plan 023). Not a this-week answer.

### Option D — One identity on the AIPC, many in qm (recommended)

Close `/register` on deer-flow and keep **one** account there (the Pacgate AI
user). Route multi-user co-working to the **qm portal**, which already does
per-person email-allowlist sign-in with one-time links (§2A).

- **Pros:** least custom code — assignment is `AUTH_ALLOWED_EMAILS`, and there is
  **no password management to build or operate**. Two clearly separated surfaces:
  research workspace vs team space. Reuses a stack we already deploy.
- **Cons:** qm's production auth has not been proven on a real machine (§2B.1);
  qm sits outside the automated update path (§2B.2); two front doors to secure
  (§2B.3); needs an email transport and a public origin (§2A, §2B.4).
- **Depends on:** the `/register` gate from Option A regardless — D does not
  replace A, it *reduces* A to "one account, gated".

**Recommendation: Option D, with the Option A gate as its first step.** D removes
most of A's operational burden (no per-user provisioning, no passwords) while
keeping the same security outcome for the AIPC surface. The remaining A work is
just: gate `/register`, keep one account, remove the direct `8090` publication.

## 4. What already exists: `auth-gate` is not the answer

The repo has a tracked `auth-gate/` (`server.py`, `Dockerfile`) — but it is **not**
usable as-is for this, and should not be mistaken for a solution:

- It authenticates a **single** username/password pair from
  `PACGATE_VIEWER_USERNAME` / `PACGATE_VIEWER_PASSWORD` (env vars), not a user list.
- It **does not proxy.** `do_GET` serves `/healthz`, `/auth/check`, `/logout`,
  `/login` and returns **404 for everything else**. There is no upstream forwarding.
- It was built as a viewer gate for a public landing/demo surface, and
  `compose.yaml` (repo root, a separate stack) is the only place it is wired.

Useful as a *pattern* for session signing (HMAC-signed cookie, `compare_digest`,
`safe_next` open-redirect guard). Not reusable as the deer-flow front door without
adding proxy logic and a multi-user store — i.e. building Option B.

## 5. The gap Option A does not close

Once registration is closed and accounts are assigned, **every authenticated user
still reaches the same firm data** via the shared MCP service credential. Closing
registration is a gate on *entry*, not on *scope*.

Closing that gap is a separate piece of work. The shape of it: per-user identity
must reach the tool layer so `pacgate_*` tools are scoped to the calling user's
tenant/matter rather than a fixed `PACGATE_MATTER_ID`. That is a design of its own
(mapping a deer-flow user to a pacgate tenant/matter, and passing identity through
the MCP boundary), and it is the thing that turns "assigned users" into "assigned
*access*".

Given the product is legal-client data, this deserves an explicit decision rather
than being assumed to follow from per-user logins.

## 6. Recommended sequence

**Now (closes the hole on the AIPC surface):**

1. Gate `/register` mirroring `auth.local.allow_registration`, default false.
2. Set `GATEWAY_CORS_ORIGINS` correctly (already done on this box via install.ps1
   step 4c) — note this is a CSRF control, **not** an access control.
3. Remove the direct `8090:3000` publication, or bind it to loopback, so the
   frontend cannot be reached bypassing nginx. Otherwise any nginx-side control is
   bypassable.
4. Keep **one** deer-flow account for the Pacgate AI user. No provisioning script
   needed under Option D.
5. Prove it: `POST /register` -> 403 on both `:8089` and `:8090`; the single
   account logs in and works.

**Then (bring qm up as the team space):**

6. **Choose the email transport** (SMTP strongly preferred) and obtain the
   operator's mail credentials. This is the blocking prerequisite — do it first.
7. Set `AUTH_ALLOWED_EMAILS` (or `AUTH_ALLOWED_EMAIL_DOMAIN`) and
   `ADMIN_GRANTS=<email>:org_admin`, then run `qm setup`.
8. Set a real `publicUrl` with TLS for remote sign-in rather than `localhost:8181`.
9. **Prove production auth end to end**: portal sign-in with an allowlisted email
   delivers a link, the link produces a session, an email NOT on the list is
   refused, and core rejects unauthenticated requests. This is the acceptance test
   that closes the 2026-09-04 dev-mode finding.

**Then (fresh installs):**

10. Close the `/initialize` window. Either have `install.ps1` create the admin
    non-interactively (it currently does not), or bind the stack to loopback until
    setup is complete. Today a not-yet-initialised AIPC can be claimed by anyone
    who reaches it.

**Later (scope, not entry):**

11. Decide the per-user data-scoping design (§5). Note qm carries real per-user
    identity (`x-portal-identity`) into its sandbox tools, so qm is the better
    surface for anything requiring per-user attribution.

## 7. Decisions and remaining items

**Decided by the operator (2026-09-21):**

1. **Surface split accepted.** One deer-flow account for the Pacgate AI user on
   each AIPC; multi-user co-working moves to the qm portal rather than deer-flow.
   This removes per-user provisioning and password handling from our side.

**Remaining, in priority order:**

1. **Email transport for qm one-time links** (§2A). Blocking prerequisite; needs
   the operator's mail credentials. SMTP preferred over Resend to avoid DNS work.
2. **Prove qm production auth on a real machine** (§2B.1). Until portal sign-in is
   demonstrated, the team space is not client-ready regardless of config.
3. **Exposure decision.** The earlier question (public internet vs LAN/VPN) now
   applies to **two** front doors. A single answer covering both is less work than
   two separate stories.
4. **Is per-user data scoping (§5) required for launch?** Still open, and now
   sharper: qm carries per-user identity into its tools, deer-flow does not. If
   per-user attribution matters, the work belongs on the qm side.

## Appendix — evidence index

| Claim | Source |
| --- | --- |
| `/register` has no gate at `v2.0.0` | `git show v2.0.0:backend/app/gateway/routers/auth.py` lines 305-323 |
| No `allow_registration` field at `v2.0.0` | `git show v2.0.0:backend/app/gateway/auth/config.py` |
| `/register` and `/initialize` are public | `git show v2.0.0:backend/app/gateway/auth_middleware.py` lines 41-49 |
| `/register` reachable live | `POST :8089` / `:8090` -> 422 (invalid payload, nothing created) |
| Upstream fix + exact key | `origin/main` `auth.py` `_local_registration_enabled()`; changelog line 623 (#4311) |
| No admin user-management endpoint | enumerated all `@router.` decorators at `v2.0.0` and `origin/main` |
| MCP uses a shared service identity | `deploy/client-bundle/compose.prod.yaml` MCP env (`PACGATE_JWT_TOKEN`, `PACGATE_MATTER_ID`) |
| Frontend bypasses nginx | `compose.prod.yaml` `ports: - "8090:3000"`; live `docker ps` |
| `reset_admin.py` resets, cannot create | `git show v2.0.0:backend/app/gateway/auth/reset_admin.py` |
| `auth-gate` is single-user and does not proxy | `auth-gate/server.py` lines 12-13, 343-370 |
| qm runs the full multi-user services set | `deploy/qm-pacgate/qm.config.jsonc` line 42 `"services": ["core","web-ui","portal","auth","admin"]` |
| qm assignment is an exact-match email allowlist | `deploy/qm-pacgate/.env.example` lines 14-21 (`AUTH_ALLOWED_EMAILS`), `ADMIN_GRANTS` |
| qm sign-in is one-time emailed links (no passwords) | `deploy/qm-pacgate/deployment.md` lines 103-117; `.codex/skills/deploy-qm/references/email.md` |
| qm needs a real email transport | `references/email.md` (SMTP or Resend; `SMTP_TLS=none` refused in production) |
| qm portal is the front door on 8181; core 8180, web-ui 8182 | `qm.config.jsonc` lines 9-16, 34-41 |
| All five qm images anonymously pullable | `docker buildx imagetools inspect` on each pinned digest -> ok |
| qm dev flag is not an auth bypass | `qm.config.jsonc` lines 58-62 (NODE_ENV only permits `http://localhost`; JWT/one-time-links/allow-list/signed source-auth stay active) |
| qm auth not proven running; previously dev-mode | `deploy/qm-pacgate/tasks/plan.md` lines 13-20 (2026-09-04: core/web-ui in dev mode, task 1 = restore production auth); no qm containers present on this box |
| qm runtime config not staged / outside `-Update` | `deploy/client-bundle/qm-pacgate/` absent; `qm` excluded from `install.ps1 -Update` |
