# qm-pacgate local bring-up runbook (compose path)

**Date:** 2026-09-21
**Purpose:** bring the qm team space up locally and run a genuine magic-link E2E
smoke test — the test `plans/010` already passed once on AIPC2.

**Use this, not `qm up`.** The `qm` CLI cannot detect Docker on native Windows
(its `which()` shells out to POSIX `/bin/sh` — see
`deploy/QM-BRINGUP-AUDIT-2026-09-21.md` §3). `compose.qm.yaml` bypasses the CLI
entirely; verified `docker compose -f compose.qm.yaml config` → exit 0.

---

## Why the compose path is the right one

| | `qm up` (CLI) | **`compose.qm.yaml`** |
| --- | --- | --- |
| Works on native Windows | **No** (`/bin/sh` defect) | **Yes** — verified config exit 0 |
| Mailpit SMTP catcher | would need the plugin system | **already wired** (`SMTP_HOST: mailpit`) |
| Real SMTP credentials needed | yes | **no** — Mailpit accepts any auth |
| Container grouping | no compose project label | yes (that is why plan 010 migrated) |
| Lifecycle | `qm up` / `qm down` | `docker compose -f compose.qm.yaml up/down/ps/logs` |

## Prerequisites (two of these are NOT optional)

1. **Docker Desktop running** with a Linux container engine.
2. **The external network and volumes must be pre-created.** `compose.qm.yaml`
   declares them `external: true`, so compose will NOT create them, and **none
   exist on this box** (verified absent).

```powershell
docker network create qm-pacgate
docker volume  create qm-pacgate-coredata
docker volume  create qm-pacgate-pgdata
```

3. **A `.env` in `deploy/qm-pacgate/`** — 22 required variables. It is gitignored
   and per-machine; only `.env.example` is tracked.

## Step 1 — generate the `.env`

Nine secrets are pure CSPRNG values and can be generated with no external input:

```powershell
function New-HexSecret {
    $b = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    ($b | ForEach-Object { $_.ToString('x2') }) -join ''
}
# CORE_SIGNING_SECRET, CAPABILITY_SECRET, CONNECTOR_SECRET_KEY, PORTAL_IDENTITY_SECRET,
# PORTAL_SESSION_SECRET, SKILL_SIGNING_SECRET, AUTH_TOKEN_SECRET, AUTH_CLIENT_SECRET,
# POSTGRES_PASSWORD  -> New-HexSecret
```

`setup-qm.ps1` already does this and also copies generated files; prefer running it
rather than hand-rolling. It still prompts for three values: the **admin email**,
the **Pacgate bridge email**, and the **bridge password**.

**Mailpit values for a local run** (no real provider needed):

```dotenv
SMTP_USERNAME=mailpit
SMTP_PASSWORD=mailpit
AUTH_EMAIL_FROM=no-reply@pacgate.local
```

That is sufficient because `compose.qm.yaml` sets
`MP_SMTP_AUTH_ACCEPT_ANY: "1"` — Mailpit accepts any credentials. Note that qm's
code **explicitly supports `SMTP_TLS: none`** (`preflight.js` `smtpTlsMode`), and
the compose file already sets it. qm's docs claim `none` is refused in production,
but the code does not enforce that; for a container-local catcher it is correct,
since there are no credentials to leak in cleartext.

**Allowlist** — who may sign in:

```dotenv
AUTH_ALLOWED_EMAILS=justin@yourfirm.example,sylvie@yourfirm.example
ADMIN_GRANTS=justin@yourfirm.example:org_admin
```

`ADMIN_GRANTS` takes `email:role`; `AUTH_ALLOWED_EMAILS` takes **plain emails**
(no `:role` suffix — the broker does an exact match).

**Pacgate bridge** (a service account in pacgate-api, used by the sandbox tool):

```dotenv
PACGATE_API_EMAIL=qm-bridge@pacgate.local
PACGATE_API_PASSWORD=<password>
```

**OpenViking** — see the memory-scoping caveat below before choosing these:

```dotenv
OPENVIKING_ROOT_API_KEY=<same as client-bundle .env>
OPENVIKING_API_KEY=<legacy app key, kept for compatibility>
OPENVIKING_ACCOUNT=default-firm     # should become the tenant slug
OPENVIKING_USER=<attorney user id>  # currently one fixed value for everyone
```

## Step 2 — validate before starting anything

```powershell
cd deploy/qm-pacgate
docker compose -f compose.qm.yaml config --quiet ; "config exit=$LASTEXITCODE"
```

`--quiet` returns 0 and prints nothing on success. Then confirm every required
variable resolved (no empty strings):

```powershell
docker compose -f compose.qm.yaml config | Select-String '^(      )?(POSTGRES_PASSWORD|AUTH_ALLOWED_EMAILS|SMTP_HOST|PACGATE_API_EMAIL|OPENVIKING_ROOT_API_KEY):'
```

Empty values here mean an unset var, and the stack will fail late rather than
early.

## Step 3 — bring it up

```powershell
docker compose -f compose.qm.yaml up -d
docker compose -f compose.qm.yaml ps
```

Expected host ports: **8180** core, **8181** portal (front door), **8182** web-ui,
**8183** admin, **8025** Mailpit. Give the images a moment — first pull is ~7
containers.

## Step 4 — the genuine E2E smoke test (this is the point)

Run these checks in order, and record the evidence:

1. **Health** — `curl.exe -s -o NUL -w "%{http_code}" http://localhost:8182/` → 200.
   Portal on 8181 returns **401 on a bare GET** (that is the auth gate working, not
   a failure). Mailpit 8025 → 200.
2. **Un-allowlisted email is refused.** POST a sign-in for an address NOT in
   `AUTH_ALLOWED_EMAILS`. It must be rejected — *this is the check that proves the
   allowlist is enforced*, and the one worth automating.
3. **Allowlisted email receives a link.** Sign in at `http://localhost:8181` with an
   allowlisted address.
4. **The link arrives in Mailpit** — open `http://localhost:8025` and confirm the
   message ("Sign in to PacGate" per plan 010). No real inbox required.
5. **Opening the link yields a session** — complete it **in the same browser** that
   started the sign-in (plan 010 notes this matters), and confirm the QM web UI
   loads signed in.
6. **Core rejects unauthenticated requests** — the check that closes the 2026-09-04
   dev-mode finding. Do not accept `NODE_ENV: development` as evidence either way;
   test the request.

Steps 2 and 6 are the two that distinguish a *real* auth deployment from a
dev-mode one. If both pass, the qm team space is genuinely authenticated.

## Step 5 — what this does and does not prove

**Does prove:** qm's portal + auth broker run, the email allowlist is enforced,
one-time links are delivered and redeemable, and core rejects unauthenticated
requests. That is a real, client-relevant capability.

**Does not prove:**
- Anything about **multi-machine** behaviour. This is one machine with its own
  network, volumes and Postgres. Two AIPCs still hold two disconnected brains
  (`MULTI-USER-ARCHITECTURE-PLAN.md` §5A). Bringing qm up locally does **not**
  remove the partition wall — it demonstrates the team surface, not a shared firm.
- That **per-user memory is isolated.** `OPENVIKING_USER` is currently one fixed
  value for all qm traffic, so every member's agent writes to the same OpenViking
  user space (gap G9). Realising per-person memory needs
  `ScopeContext.personal_user_id` wired into `OPENVIKING_USER`.
- That OpenViking ACLs work — they are disabled by default and our workspace has a
  single `default` account (gap G8).

## Step 6 — teardown

```powershell
docker compose -f compose.qm.yaml down
```

Named volumes and the external network persist (that is deliberate — data survives
a down/up cycle). Remove them explicitly only when you intend to lose state:

```powershell
docker network rm qm-pacgate
docker volume  rm qm-pacgate-coredata qm-pacgate-pgdata
```

## Known gotchas (from plan 010, still applicable)

- **CRLF**: git on Windows checks out `tasks/patch-pi-models.sh` with CRLF, and
  container `sh` fails `set -e` with "illegal option -". Convert to LF before use.
- **pi-models patch is a writable-layer edit** and is lost on recreate. Re-apply
  and `docker restart qm-pacgate-core` (**not** `up`/recreate, which wipes it).
  `grep -c glm-5.3-flash /app/src/model/pi-models.ts` should be 2.
- **PowerShell mangles inline `node -e` / `sh -c` quoting** — write a script file,
  `docker cp` it, run it.
- **Playwright** click on the sign-in button times out on stability; use
  `form.requestSubmit()` via `page.evaluate` instead.
- qm's runtime config is **outside `install.ps1 -Update`** — the runtime copy
  (`deploy/client-bundle/qm-pacgate/`) is not re-staged by anything, so a config or
  allowlist change needs a manual re-run (gap G12).

## The remaining decision this runbook does NOT settle

Bringing qm up locally is worth doing for verification. It is **not** the topology
answer. Before any client deployment, decide where the single source of truth lives
(`MULTI-USER-ARCHITECTURE-PLAN.md` §5A): centralise qm via its native
`fly`/`aws` targets (recommended), and/or centralise the pacgate-api data plane.
Otherwise Justin and Sylvie each get a working, correctly-authenticated team space
that cannot see the other's work.
