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

## The fix (not applied)

Either of these arms the guard; pick one and test it on a fresh clone:

**Option A — operator-supplied token (explicit, preferred for an on-site install)**

Add `PACGATE_SETUP_TOKEN` to the deer-flow service environment in
`deploy/client-bundle/compose.prod.yaml` **and** `compose.bundle.yaml`, sourced
from `.env`, and have `install.ps1` generate a value on first install and print
it to the operator (the same pattern used for the pacgate-db and auth secrets).

**Option B — generate-and-log (no operator step)**

Set `PACGATE_GENERATE_SETUP_TOKEN=1` on the deer-flow service. The gateway
generates a token per process and logs it at WARNING level:

```
PACGATE SETUP TOKEN: <value>  -- required by POST /api/v1/auth/initialize
to create the first admin. Read it from the container logs.
```

This closes the race without an install-time step, at the cost of the operator
reading the token from `docker logs deer-flow` at setup time.

**Either way, verify on a FRESH CLONE.** The standing rule for this repo is that
no install-path change is considered validated until a clean clone proves it —
this dev box accumulates credentials, pulled models, and rendered gitignored
configs, so it masks clean-machine failures.

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
- Repo memory `ghcr-jzkk720-authority.md` — the earlier analysis of this endpoint;
  its note that the endpoint is "unguarded" is superseded: the guard now exists
  but is inert, which is the subtler failure.
