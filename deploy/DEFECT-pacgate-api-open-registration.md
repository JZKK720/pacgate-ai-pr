# FINDING: `POST /api/auth/register` is unauthenticated and mints an `attorney` account

**Found:** 2026-10-01, while verifying a claim I had previously got wrong.
**Severity:** HIGH — unauthenticated account creation with a working role in the
default tenant.
**Status:** ✅ **RESOLVED IN 0.1.22** (commits `ebac082` + `fc5c6af`, released
2026-10-03). Superseded by the *RESOLVED* section at the end of this file, which
is the current state. The body below is kept as the record of the finding.

> This supersedes an **incorrect** claim I had recorded in
> `DEFECT-initialize-bootstrap-token.md`: that this endpoint is gated by
> `auth.local.allow_registration` and therefore refuses registration. It is not
> gated, and it does not refuse. I had attributed **deer-flow's** gate to
> **pacgate-api**'s differently-named route on a different service, without
> checking that the Rust route was gated at all.

## What is true (read from the handler, then confirmed live)

`pacgate-ai/crates/pacgate-api/src/auth.rs:73`, routed at `lib.rs:156`:

```rust
/// POST /api/auth/register — create a new user within the configured default tenant
pub async fn register(
    State(state): State<AppState>,
    Json(req):    Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
    let tenant = state.tenant_store.get_by_slug(&state.config.default_tenant).await ...;
    let user_id = state.auth.register(&tenant.id, &req.email, &req.password, "attorney", ...).await ...;
```

Two properties, both load-bearing:

1. **No auth extractor and no registration gate.** No `Extension<Claims>`, no
   allowlist check, no feature flag. `allow_registration` appears **nowhere** in
   the Rust crates (grep: 0 hits). The `allow_registration: false` that I
   previously cited lives in `deer-flow-config.yaml` and gates **deer-flow's**
   `/api/v1/auth/register` — a different service, a different route, a different
   user store.
2. **The role is hardcoded `"attorney"`.** Not a guest or pending role.

## Live evidence

| Step | Result |
|---|---|
| `POST /pacgate/api/auth/register` (no credentials) | **200**, returned a `user_id` |
| `POST /pacgate/api/auth/login` as that account | **token obtained** |
| `GET /pacgate/api/matters` with that token | **200** — **148 KB of matter records** |
| `GET /pacgate/api/workflows` with that token | **200** |

**The matters response is real tenant data, not an empty list.** It begins:

```json
[{"id":"36a4004a-...","tenant_id":"e10c8cca-...","name":"journey-0a6668af","description":"legal-journey acceptan...
```

So a self-registered account reads **matter names, ids, tenant ids and
descriptions** for the whole tenant. Matter names in a legal practice are
client-identifying on their own. This is materially worse than the
"is it empty or not?" question the first version of this file left open.

Reachable through the normal client ingress (`:8089/pacgate/`), which is the path
an AIPC exposes on the LAN and nginx does **not** restrict.

### Exposure scope (verified 2026-10-02)

| Control | State |
|---|---|
| `pacgate-nginx` bind | `0.0.0.0:8089->80/tcp, [::]:8089->80/tcp` — **all interfaces** |
| IP `allow`/`deny` on `location /pacgate/` | **none** (the only `deny`/`allow`/`internal` hits in `default.conf` are unrelated comments) |
| Intended access | LAN — `USER-MANUAL.md:29` tells users to browse to `http://<your-ai-pc-ip>:8089` |

**Probe accounts were deleted after each test; the user table was verified back
to its original three rows (`seed@`, `attorney-e2e@`, `admin@pacgate-law.com`).**
No probe account remains.

## Deployment consequence — do NOT pull this to a client LAN as-is

This is the reason a deployment gate is being held on 0.1.21. The release itself
carries two genuine client fixes (the MCP 24-hour 401 self-heal and the PaddleOCR
volume), and the exposure is **pre-existing in the API**, not introduced by
0.1.21 — 0.1.20 has the identical route. But deploying to a **new** machine
creates the exposure there, and the two fixes do not justify handing a legal-matter
system to open self-registration.

**Cheapest mitigation needs no image rebuild:** `nginx/default.conf` is
bind-mounted (`compose.prod.yaml:242`) and `install.ps1 -Update` runs
`git pull --ff-only`, so a route-level block ships by pull + nginx reload. The
constraint is that `install.ps1:682` bootstraps the admin **through that same
route**, so a blanket 403 breaks first-run creation unless the install path is
changed to use an in-network call.

## Why this matters for this product specifically

This is a legal-matter system. The dev box currently holds **408 matters** and
**24 documents**. `GET /api/matters` returning 200 to a self-registered account
means the tenant's matter metadata is reachable by anyone who can reach the
ingress. I did **not** dump the response body — the count is what matters for
severity, and dumping it would have re-exposed client data to a transcript.

Note the contrast with the deer-flow side, which is correctly locked down: its
`/register` returns **403** (`scripts/test-auth-registration-gate.ps1`, 8/8) and
its `/initialize` requires a token once one is configured. pacgate-api has no
equivalent control at all — so "self-registration is disabled" is true of one
service and **false of the one holding the data**.

## Interacts with the other open item

`/initialize` (see `DEFECT-initialize-bootstrap-token.md`) and this are the same
class: **the first-install / unauthenticated surface is wider than intended.**
They should be triaged together because a fix for one changes the assumptions of
the other — e.g. arming the `/initialize` token while leaving this route open
would close the admin door and leave the attorney door ajar.

## What a fix has to decide (not mechanical)

Do not patch this by copying deer-flow's gate without deciding the model:

- **Intended bootstrap?** If the on-site engineer is meant to create the first
  attorney this way, the route needs to be *first-user-only* (like
  `/initialize`'s `admin_count > 0` check), not open forever.
- **Or closed by default?** If accounts come from `/initialize` + an admin flow,
  this route should refuse unauthenticated calls outright.
- Either way, add a **committed test**, in the shape of
  `test-auth-registration-gate.ps1`: register anonymously, assert NOT 2xx, assert
  the user count is unchanged. That test does not exist for pacgate-api.

## Not verified (do not assume)

- Whether an `attorney` JWT can reach **document content** (download/extract),
  not just matter metadata. That needs its own probe and should be done
  deliberately, not incidentally.
- Whether any per-tenant scoping limits the listing to the caller's own matters.
  The tenant is a single `default` in this deployment, so scoping may be moot
  here while still mattering at a multi-tenant client.

---

## RESOLVED (2026-10-03) — plus the defect the fix itself introduced

The gate is implemented as "intended bootstrap, first-user-only": `register`
refuses once any user exists unless the deployment opts in via
`PACGATE_ALLOW_REGISTRATION`. Verified both directions on a throwaway database
(first user 200, second 403, count exactly 1).

**The gate alone was not the fix, and shipping only the gate would have broken
the install.** Following the gate through to the client bundle surfaced two
further defects and one of my own:

1. **The 403 told the operator to do something impossible.** Its message read
   "An administrator must create further accounts", but the route table had only
   `login`, `register`, and `me` — there was no user-creation route at all, so
   `register` was the ONLY provisioning path. Closing it removed the only way to
   create an account. The documented install step for the qm co-working runtime
   — a separate least-privilege service account, `qm-bridge@pacgate.local`,
   referenced in 15 files including the client-facing handbooks — would return
   403. Fixed by adding `POST /api/auth/users`, admin-gated on
   `Claims.system_role` from the verified JWT and scoped to the caller's tenant.

2. **`register` never created an administrator.** It hardcoded
   `role = "attorney"` and left `system_role` to the column default of `'user'`.
   So `install.ps1` step 6a, whose comment says it bootstraps "the FIRST admin"
   and which logs `[OK] admin '<email>' registered`, actually produced an
   attorney. Every account in the dev database carries `system_role='user'` for
   this reason — `seed@`, `attorney-e2e@`, `admin@pacgate-law.com`, and
   `qm-bridge@` alike. Consequence: the new admin route would have been
   unreachable by **every principal that could exist**, i.e. the remedy for
   defect 1 would have been dead code. Fixed: first account gets
   `admin`/`admin`, later ones stay `attorney`/`user`.

3. **My own regression.** While reasoning from `.env.example`'s note that
   deer-flow and pacgate-mcp share `PACGATE_API_EMAIL`, I concluded the bridge
   should reuse the deployment identity and edited both `setup-qm.ps1` and the
   live qm `.env` accordingly. That was wrong: the bridge is a deliberate
   boundary — the sandbox runs model-directed tool calls, so it gets its own
   attorney-scoped credential rather than the deployment's own principal. The
   edit also **destroyed the bridge password** (overwriting it with the admin's),
   leaving `qm-bridge@pacgate.local` unable to authenticate. Reverted; the
   account was deleted (it owned 0 matters) and reprovisioned with a fresh
   CSPRNG password, verified 200 from inside `qm-pacgate-core`. Lesson: the
   "second account is impossible" premise was only true *because of defect 1* —
   a bug is not an architecture.

Also found while wiring this up: `setup-qm.ps1` overwrote `.env` on every run,
contradicting the rule it states 20 lines earlier. That regenerates
`POSTGRES_PASSWORD` while the pg volume keeps the old one, and rotates
`AUTH_TOKEN_SECRET` / `AUTH_SIGNING_JWK` so every live session is invalidated
mid-use. Now guarded.

### Release ordering — still load-bearing

**This fix is inert until 0.1.22 ships.** Verified against the RUNNING 0.1.21
image: `POST /api/auth/users` returns **404** and an admin login returns
`role=attorney`. The compose wiring (`PACGATE_ALLOW_REGISTRATION: "false"` in
`compose.prod.yaml` and `compose.bundle.yaml`) is present but does nothing —
the 0.1.21 binary has no such config key. Until the rebuilt image is deployed,
the original unrestricted registration remains live on any AIPC.

### Tests

`auth.rs` carries four unit tests over `bootstrap_roles`, and they were proven
to fail when the grant is reverted. One caveat worth keeping: the first version
of those tests compared against the same `"admin"/"admin"` literals the
implementation used, so a mutation that broke the grant broke the expectation
too and the tests **passed while the behaviour was wrong**. Expectations are now
spelled out in the test module independently of the implementation.

