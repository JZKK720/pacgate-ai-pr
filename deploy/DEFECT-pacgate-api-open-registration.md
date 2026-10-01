# FINDING: `POST /api/auth/register` is unauthenticated and mints an `attorney` account

**Found:** 2026-10-01, while verifying a claim I had previously got wrong.
**Severity:** HIGH — unauthenticated account creation with a working role in the
default tenant.
**Status:** VERIFIED PRESENT. Not fixed. Needs an owner decision on the intended
first-run model before a fix is written.

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
| `GET /pacgate/api/matters` with that token | **200** |
| `GET /pacgate/api/workflows` with that token | **200** |

Reachable through the normal client ingress (`:8089/pacgate/`), which is the path
an AIPC exposes on the LAN.

**Probe accounts were deleted immediately after each test; the user table was
verified back to its original three rows (`seed@`, `attorney-e2e@`,
`admin@pacgate-law.com`).** No probe account remains.

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
