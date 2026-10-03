# DEFECT: the `/initialize` bootstrap guard is present but INERT

**Found:** 2026-10-01, during the 0.1.21 release (upstream port of two AIPC fixes).
**Severity:** HIGH on a fresh install; not exploitable on an initialised one.
**Status:** OPEN — fix identified, deliberately NOT bundled into 0.1.21. See *Why this
did not ship* below.

## The defect

`POST /api/v1/auth/initialize` creates the first admin account. On a freshly
installed AIPC — no admin yet — it is reachable by anyone who can reach the URL,
and the first caller becomes admin.

A guard was added to close this, and it is correct where it exists:

`deploy/client-bundle/patches/deer-flow-auth.py:631`

```python
required_token = _current_setup_token()
if required_token is not None:
    # ...403 unless the caller presents the token
```

**The guard only arms when a token EXISTS.** `_current_setup_token()` returns
`None` unless the token is explicitly configured:

`deploy/client-bundle/patches/deer-flow-auth.py:140-150`

```python
def _current_setup_token() -> str | None:
    configured = os.environ.get("PACGATE_SETUP_TOKEN", "").strip()
    if configured:
        return configured
    if os.environ.get("PACGATE_GENERATE_SETUP_TOKEN", "").strip() not in ("1", "true", "yes"):
        return None
```

The in-code comment states this is intentional:

> "It is a separate switch so that merely having the variable unset never silently arms it."

That reasoning is sound as a *safety* property — an unset variable should not
arm a gate that locks out a legitimate installer. The consequence, however, is
that **the gate is disabled by default**, and nothing in the install path turns
it on.

## Why it matters

The window is exactly the first-install window, which is when a machine is most
likely to be sitting on a LAN, unattended, before the on-site engineer has
created the admin account. Once an admin exists the endpoint returns 409 and the
exposure ends. `/register` is separately gated (403) and does **not** close this
path — it is a different route.

## Evidence (measured, not inferred)

### Static (source)

| Check | Command | Result |
|---|---|---|
| Token provisioned anywhere in the bundle? | `Select-String -Path deploy/client-bundle/** -Pattern 'PACGATE_SETUP_TOKEN'` | **0 matches** |
| Installer arms it? | `Select-String -Path deploy/client-bundle/install.ps1 -Pattern 'SETUP_TOKEN'` | **0 matches** |
| Guard exists in code? | `Select-String -Pattern '_current_setup_token'` | **3 matches** |
| Disabled-path behaviour | read of L150-151 | returns `None` → `required_token is None` → guard skipped |

### Live (running 0.1.20 stack, 2026-10-01)

| Check | Command | Result |
|---|---|---|
| Is the token armed in the running gateway? | `docker exec deer-flow sh -c 'test -n "$PACGATE_SETUP_TOKEN"'` | **UNSET** |
| Is the generate-switch armed? | `docker exec deer-flow sh -c 'test -n "$PACGATE_GENERATE_SETUP_TOKEN"'` | **UNSET** |
| Does an admin already exist here? | `curl :8089/api/v1/auth/setup-status` | `{"needs_setup":false}` |

So: the code path exists, the configuration that activates it does not, and the
running deployment confirms both switches are unset.

**Scope of the risk, stated precisely:** this dev box is already initialised
(`needs_setup: false`), so `/initialize` returns 409 here and the box is NOT
currently claimable. The exposure is the **fresh-install window** — a newly
installed AIPC before the on-site engineer creates the admin account. That is
the state in which a machine sits on a LAN, unattended, with a public
admin-creation endpoint.

## THE FIX IS NOT A ONE-LINE CONFIG CHANGE — PROVEN 2026-10-01

**Arming `PACGATE_SETUP_TOKEN` on its own BREAKS first-run admin creation.**
This was measured, not reasoned about. The earlier draft of this file called it a
"one-line arming switch"; that was wrong.

The frontend's setup page posts email + password and **no token**:

`deploy/deer-flow-src/frontend/src/app/(auth)/setup/page.tsx:75`

```ts
await fetch("/api/v1/auth/initialize", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  credentials: "include",
  body: JSON.stringify({ email, password: newPassword }),   // <- no token field
});
```

There is no setup-token input anywhere in the UI (grepped for `setup_token` /
`setupToken` / `PACGATE_SETUP` across the frontend and the frontend patches:
**0 hits**). The router is in `.env.example`: no `PACGATE_SETUP_TOKEN` key exists.

### The proof (gate armed via a temporary compose override, then reverted)

| # | Condition | Request | Result |
|---|---|---|---|
| 1 | gate **unarmed** (shipped) | UI payload, no token | `409 system_already_initialized` |
| 2 | gate **armed** | UI payload, no token | **`403 setup_token_required`** |

Row 2 is the defect the "fix" would introduce. Note the observable: the token
check runs *before* the admin-count probe (by design, so an unauthenticated
caller is told nothing about whether an admin exists), so arming the gate changes
the response from 409 to 403. On a **fresh** install — no admin — that 403 means
**the first admin can never be created through the UI**. It replaces a
claimable-admin window with an unbootstrappable install.

The override used for row 2 was deleted and `deer-flow` recreated from the real
compose; verified afterwards: token `UNSET`, response back to `409`, user count
unchanged (3), and no probe account created.

## The fix, done properly

Arming the gate requires **two coordinated changes**, not one:

1. **Provision the token**, e.g. `PACGATE_SETUP_TOKEN` in the deer-flow service
   environment in **both** `compose.prod.yaml` and `compose.bundle.yaml`, sourced
   from `.env` — the same pattern the installer already uses for
   `PACGATE_DB_PASSWORD` / `PACGATE_JWT_SECRET` / `OPENVIKING_ROOT_API_KEY`.
   `install.ps1` should generate it on first install and **print it to the
   operator** (it should not be left for them to invent). `PACGATE_GENERATE_SETUP_TOKEN=1`
   is the alternative that generates-and-logs per process, but it still needs
   step 2.
2. **Teach the setup page to send it.** Without this, step 1 bricks the flow.
   `setup/page.tsx` needs a token field, and whatever hands the operator the
   token (install output, or `docker logs deer-flow` for the generate-and-log
   variant) must tell them to enter it there.

Doing only (1) is strictly worse than doing nothing.

### Suggested shape of (2)

Keep it narrow: add an optional token input to the setup form, send it as a
header or body field, and leave the form working unchanged when the gate is
disabled. The endpoint already tolerates both states — `required_token is None`
means the check is skipped entirely — so the UI change is additive and should not
need a feature flag.

**Verify on a FRESH CLONE, both branches.** The standing rule for this repo is
that no install-path change is validated until a clean clone proves it. This dev
box accumulates credentials, pulled models, and rendered gitignored configs, so it
masks clean-machine failures. Specifically prove:
- gate **off** → first-run setup still works exactly as before (no regression)
- gate **on** → setup succeeds when the operator supplies the printed token, and
  fails 403 when they do not

## A second, separate finding — CORRECTED 2026-10-01, my first version was WRONG

> **Correction.** An earlier revision of this file claimed the installer's admin
> bootstrap "cannot succeed" and that "pacgate-api's user store ends up with no
> admin". **That was wrong**, and the error was exactly the kind this repo's notes
> warn about: I attributed *deer-flow's* `auth.local.allow_registration: false`
> gate to **pacgate-api**, whose registration endpoint is a **different route on a
> different service with no gate at all**. I never verified that the Rust route
> was gated before asserting it was. Verified now, by reading the handler and
> probing live.

`install.ps1:721` bootstraps against `http://localhost:8089/pacgate` — that is
**pacgate-api**, whose own registration route is:

`pacgate-ai/crates/pacgate-api/src/auth.rs:73` (wired at `lib.rs:156`)

```rust
/// POST /api/auth/register — create a new user within the configured default tenant
pub async fn register(
    State(state): State<AppState>,
    Json(req):    Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
```

Two facts from that body:

1. **It has no auth extractor and no registration gate.** `allow_registration`
   appears nowhere in the Rust crates (grep: 0 hits). The `false` value lives in
   `deer-flow-config.yaml` and gates **deer-flow's** `/api/v1/auth/register`, a
   different service entirely.
2. **It hardcodes the role `"attorney"`** (`&req.password, "attorney", ...`).

Live confirmation: `POST /pacgate/api/auth/register` returned **200** and created
an account (the probe account was deleted immediately; user count returned to 3).
So the installer's admin bootstrap **works** — pacgate-api's `/health` is 200, so
`-ApiUp` is true and the branch is reached.

**The real finding, which is the opposite of what I first wrote:** pacgate-api's
`/api/auth/register` is reachable **unauthenticated through nginx** and creates a
working **`attorney`** account in the default tenant. Anything a JWT grants that
store is obtainable without credentials. That belongs with the `/initialize`
issue as the same class of first-install exposure.

> **RESOLVED 2026-10-03, in 0.1.22.** That route is now first-user-only (`403`
> once any user exists) and is covered by `scripts/test-auth-provisioning-gate.ps1`.
> See `DEFECT-pacgate-api-open-registration.md`. **This does not close the
> `/initialize` defect above** — a different route on a different service, still
> open and still unarmed. Do not read the sibling's resolution as this one's.

**Verified again on the running 0.1.22 stack (2026-10-03):** the sibling fix
changed nothing here. `PACGATE_SETUP_TOKEN` and `PACGATE_GENERATE_SETUP_TOKEN`
are both `UNSET` in the live `deer-flow`, `SETUP_TOKEN` appears **0 times** in
the client bundle, and the setup page still sends no token field (`setup/page.tsx`
posts only `{ email, password }`; 0 hits across the frontend and patches). Both
halves of the two-part fix are still missing.

## Why this did not ship in 0.1.21

0.1.21 carries two fixes that were **verified end-to-end on AIPC #1**
(`deploy/HANDOFF-UPSTREAM-RELEASE-0.1.21.md`). This defect was found during that
release, is unrelated to either fix, and changes the **install path** — the one
class of change this repo requires be proven against a fresh clone before release.
Bundling it would have shipped an unvalidated installer change under cover of a
validated release. It is recorded here instead so it is not lost.

## Related

- `deploy/HANDOFF-UPSTREAM-RELEASE-0.1.21.md` — the release this was found during.
- `deploy/AUTH-ASSIGNED-USERS-DESIGN.md` — user provisioning design context.
- `scripts/test-auth-registration-gate.ps1` — the committed gate for `/register`.
- Repo memory `ghcr-jzkk720-authority.md` — the earlier analysis of this endpoint;
  its note that the endpoint is "unguarded" is superseded: the guard exists but is
  inert, which is the subtler failure.
