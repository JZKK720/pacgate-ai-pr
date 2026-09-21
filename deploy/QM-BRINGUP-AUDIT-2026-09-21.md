# qm-pacgate bring-up audit — what is genuinely true

**Date:** 2026-09-21
**Question:** can we build and initiate qm-pacgate, and genuinely audit and smoke
test it end to end?

> ## CORRECTION (added same day — read this first)
>
> **Two claims in the original audit below were wrong, and the operator was
> right.** Corrections:
>
> **1. Mailpit already exists in this repo, and it worked.** I claimed qm "ships
> no mailpit plugin", which is true of the *plugin* system but misses that a
> **complete Mailpit SMTP catcher is already implemented** in
> `deploy/qm-pacgate/compose.qm.yaml` (service `mailpit`, `axllent/mailpit:v1.24`,
> alias `mailpit`, port 8025) with `auth` wired to it (`SMTP_HOST: mailpit`,
> `SMTP_PORT: 1025`, `SMTP_TLS: none`). `plans/010` records the **magic-link login
> E2E passing** on AIPC2: portal → enter admin email → Mailpit captures
> "Sign in to PacGate" → open link → QM web UI loads signed in.
>
> **2. The qm CLI is NOT the deployment mechanism — and never needed to be.** The
> operator confirmed this. `plans/010` migrated the stack **off `qm up` onto plain
> `docker compose -f compose.qm.yaml`** (so containers group under a compose
> project). That path **bypasses the `qm` CLI entirely**, and therefore bypasses
> the `/bin/sh` defect in §3 below. Verified: `docker compose -f compose.qm.yaml
> config` → **exit 0, valid**.
>
> **Consequence: the SMTP blocker in §2 and the Windows blocker in §3 are both
> avoidable.** A local bring-up is genuinely feasible. The revised verdict is at
> §9.

**Original verdict (superseded on the two points above):** qm cannot be brought
up on these machines as they stand.

The original text is retained below because its evidence is still valid — the
`/bin/sh` defect is real, and it does affect `qm up`. It simply is not on the
critical path for deployment.

---

## 1. What was actually run (evidence)

| Command | Result | Genuine? |
| --- | --- | --- |
| `qm check` | **passed** — "config, sandbox layer, and plugins are valid"; 2 tools, 3 skills, Dockerfile present; lists 23 required secrets | Yes — qm's own validator, exit 0 |
| `qm conformance --static` | **passed** — `config.v1`, `sandbox.descriptors`, `secrets.computed-set` | Yes — exit 0 |
| `qm plan` (= `up --dry-run`) | resolved the full plan; **11 missing secrets**; exit 0 | Yes |
| `qm doctor` | **FAILED** — missing/placeholder required secrets; exit 1 | Yes |
| `qm status` | **FAILED** — `error: docker not found on PATH`; exit 1 | Yes, and **the message is wrong** (§3) |

So the config is *structurally* sound and the deployment has never been started.
`qm check` passing is a real, independent validation of our tracked
`qm-pacgate/qm.config.jsonc` — that much is genuine progress.

## 2. What is missing for a bring-up

`qm doctor` names 23 required secrets. The ones that block a *local* test:

| Category | Secrets | Notes |
| --- | --- | --- |
| Email transport (mandatory) | `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD` | one-time sign-in links must be delivered |
| Sign-in allowlist | `AUTH_ALLOWED_EMAILS` | who may sign in |
| Generated signing secrets | `AUTH_CLIENT_SECRET`, `AUTH_SIGNING_JWK`, `AUTH_TOKEN_SECRET`, `CAPABILITY_SECRET`, `CONNECTOR_SECRET_KEY`, `CORE_SIGNING_SECRET`, `PORTAL_IDENTITY_SECRET`, `PORTAL_SESSION_SECRET`, `SKILL_SIGNING_SECRET` | `setup-qm.ps1` generates these itself (CSPRNG, no openssl needed) |
| Pacgate bridge | `PACGATE_API_EMAIL`, `PACGATE_API_PASSWORD` | a service account in pacgate-api |
| OpenViking | `OPENVIKING_ROOT_API_KEY`, `OPENVIKING_API_KEY`, `OPENVIKING_ACCOUNT`, `OPENVIKING_USER` | |
| Other | `OPENAI_API_KEY`, `PUBLIC_API_URL`, `AUTH_EMAIL_FROM` | |

`deploy/qm-pacgate/.env` **does not exist** — only `.env.example`. That is
expected: it is gitignored and per-machine.

`setup-qm.ps1` already implements non-interactive secret **generation**
(`RandomNumberGenerator`), but still `Read-Host`s for the admin email, the bridge
email, and the bridge password. So a fully unattended bring-up needs those three
values supplied.

## 3. The blocker that stops everything: qm cannot drive Docker on Windows

### The defect

`@yc-software/qm@0.1.4`, `dist/src/util.js:255`:

```js
export function which(bin) {
  try {
    execFileSync("/bin/sh", ["-c", `command -v ${bin}`], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}
```

`requireDocker()` (`dist/src/backends/docker.js:20`) calls `which("docker")` and
dies with *"docker not found on PATH"* if it returns false.

`/bin/sh` is a **POSIX absolute path**. On native Windows there is no `C:\bin\sh`,
so the call throws `ENOENT` regardless of what is installed.

### Proof (not inference)

```
which('docker') = false            <-- qm's own probe, reproduced verbatim
docker version -f = 29.8.0  rc=0   <-- docker IS installed and the daemon IS up
C:\bin\sh.exe exists: False
resolved: NO  (spawnSync /bin/sh ENOENT)
node resolves `docker` itself: C:\Program Files\Docker\Docker\resources\bin\docker
```

The message is therefore **misleading**: Docker is present and healthy
(`docker info` → ServerVersion 29.8.0). qm's probe is what fails.

### Scope of the defect

Exactly **one** occurrence of `"/bin/sh"` exists in qm's dist. The blast radius is
narrow — it is `which()`, used for docker and fly CLI detection.

### What this means practically

`qm up` **cannot** run from the operator's native Windows machines. Options:

1. **Run the qm CLI where `/bin/sh` exists** — the CLI is a Node program, so this
   is mostly a Node question:
   - **WSL**: `sh` = `/usr/bin/sh` ✅, `docker` 29.8.0 ✅, `npm` 11.6.2 ✅, repo
     visible at `/mnt/c/...` ✅ — but **`node` is ABSENT** in the distro. Adding
     Node (or symlinking `/mnt/c/Program Files/nodejs/node`) would complete it.
   - **Git for Windows** provides `C:\Program Files\Git\bin\sh.exe` and
     `usr\bin\sh.exe` — but node will not resolve `/bin/sh` to it without a
     `C:\bin\sh` shim.
2. **File upstream.** This is a genuine cross-platform defect worth reporting:
   `which()` should not assume a POSIX shell on Windows.
3. **Deploy qm where Linux is normal** — its own `--target fly` / `--target aws`
   targets. This is arguably the *correct* answer anyway (§5).

## 4. The second, larger blocker: nothing to bring up *against*

qm is coupled to **its own host**:

```jsonc
"PACGATE_API_URL": "http://host.docker.internal:8089/pacgate",
"OPENVIKING_URL":  "http://host.docker.internal:1933"
```

`host.docker.internal` is same-machine only. And per
`MULTI-USER-ARCHITECTURE-PLAN.md` §5A, each AIPC holds its own:

- `./data:/data` — documents + Postgres (**gitignored, per machine**)
- `./openviking:/app/.openviking` — memories, sessions, resources
- `./data/deer-flow:/app/backend/.deer-flow` — deer-flow state

with **no sync mechanism anywhere in the repo**.

So a *successful* local bring-up would produce a demo, not the architecture. For
that reason I did **not** force one — see §6.

## 5. The topology question this exposes (re-evaluating the operator's ask)

The operator's instinct — *"Justin and Sylvie are both admin, one machine each;
we must not end up with a memory wall"* — is correct, and sharper than my first
plan credited.

There is **no permission wall** between two admins. There is a **partition wall**:
each AIPC is a complete, isolated copy of the firm's state. OpenViking
`account_id`/`user_id` scoping does **not** address this — it scopes *within one
instance*. Two correctly-scoped disconnected instances are still disconnected.

**So the real question is where the single source of truth lives.**

| Option | Shape | Assessment |
| --- | --- | --- |
| **A. Central data plane** | one host runs `pacgate-db` + `pacgate-api` + `openviking`; AIPCs point at it | removes the wall; `pacgate-api` already reads `DATABASE_URL` from env. But `./data` document bytes are filesystem — need shared storage too. One machine becomes a dependency. |
| **B. Central qm** | deploy qm via its native `fly`/`aws` targets as the shared multiplayer surface; AIPCs keep heavy compute local | **best fit**: qm is *designed* as the shared surface, and it sidesteps the Windows CLI defect entirely |
| **C. Federate between AIPCs** | replicate state | no mechanism exists; conflict resolution for a matter file is an ethics problem. Don't. |

**Recommendation: B, with A optional.** Centralise qm for team collaboration;
keep the AIPC heavy lanes (OCR, sanitize, long research) local. Add A only if the
firm requires every matter to be visible from every AIPC.

## 6. Explicitly NOT done, and why

I did **not**:
- Create `.env` with real credentials, or invent SMTP/bridge credentials.
  Fabricating them would produce a stack that starts and cannot sign anyone in —
  the exact "green but meaningless" failure this repo has been burned by.
- Run `qm up`. It cannot succeed (no `.env`; and on Windows the CLI dies before
  touching Docker), and `up` is an **apply** step that writes deployment state and
  starts containers. Attempting it to "see what happens" would be an unforced
  mutation of the machine.
- Claim any end-to-end test. **No bring-up occurred, so there is nothing to smoke
  test.** Anything I reported as "e2e verified" here would be false.

This is stated plainly because a green-looking summary with no bring-up behind it
is worse than an honest stop.

## 7. The honest audit result

| Question | Answer |
| --- | --- |
| Is our qm config valid? | **Yes** — `qm check` and `qm conformance --static` both pass (qm's own tooling) |
| Can qm be built/started on this machine today? | **No** — no `.env` (23 secrets), and the CLI cannot detect Docker on Windows |
| Is that our fault? | **No** — one environmental gap (missing `.env`, expected) and one upstream defect (`/bin/sh`) |
| Would a local bring-up prove the architecture? | **No** — per-machine state means it would demo an isolated copy, not the team model |
| What makes it genuinely testable? | an email transport + credentials, a Linux/WSL host (or the upstream fix), and the topology decision in §5 |

## 8. What would make a real e2e smoke test possible

**REVISED (see §9) — the compose path removes two of the three blockers.** The
original ordering assumed the qm CLI. Corrected path:

1. **`docker compose` route (§9)** — NOT `qm up`. No `/bin/sh`, no qm CLI.
2. **`.env`** — 22 required vars (23 minus the `VAR` scan false positive). The
   nine signing secrets can be generated; Mailpit needs **no real SMTP
   credentials** (`MP_SMTP_AUTH_ACCEPT_ANY: "1"`), so `SMTP_USERNAME`/`SMTP_PASSWORD`
   can be dummies for a local run.
3. **Pre-create the external resources** — network `qm-pacgate`, volumes
   `qm-pacgate-coredata` and `qm-pacgate-pgdata` (all declared `external: true`,
   and none currently exist on this box).
4. **pacgate-api bridge account** for `PACGATE_API_EMAIL`/`PASSWORD`.
5. **`docker compose up -d`**, then the e2e below.

**Then the e2e smoke test:** portal sign-in with an allowlisted email → the link
lands in Mailpit at `http://localhost:8025` → opening it yields a session; a
**non-allowlisted** email is refused. That closes the 2026-09-04 dev-mode finding.
This is exactly the test `plans/010` already ran successfully.

## 9. REVISED VERDICT — the compose path makes a local bring-up feasible

| Blocker | CLI path (`qm up`) | **compose path (`compose.qm.yaml`)** |
| --- | --- | --- |
| `/bin/sh` detection defect | **blocks** | **not used** — verified `docker compose config` exit 0 |
| Email transport | required | **Mailpit already wired** — no real credentials needed |
| `.env` secrets | 23 required | 22 required; signing secrets generatable, SMTP can be dummy |
| External network/volumes | auto-created by qm | must be pre-created (`external: true`, absent today) |

**So: yes, we can bring qm up locally — via compose, not the qm CLI.** And the
Mailpit + magic-link E2E has *already been proven once* on AIPC2 per `plans/010`.

What still cannot be claimed: **no bring-up has been performed in this session.**
The environment gap remains real — this box has none of qm's network/volumes, no
`.env`, and no pacgate bridge account. Those are inputs, not blockers.

**Recommended next step:** create the `.env` (with generated secrets and dummy
Mailpit SMTP values), pre-create the external network + volumes, then
`docker compose -f compose.qm.yaml up -d` and run the magic-link E2E reading the
link out of Mailpit. That is a genuine, end-to-end, verifiable smoke test.

## Appendix — evidence index

| Claim | Evidence |
| --- | --- |
| Our qm config is valid | `qm check` → "check passed"; exit 0 |
| Static conformance passes | `qm conformance --static` → 3/3 pass; exit 0 |
| 23 required secrets missing | `qm doctor` / `qm plan` output |
| `.env` absent | directory listing of `deploy/qm-pacgate/` shows only `.env.example` |
| qm's `which()` uses POSIX `/bin/sh` | `node_modules/@yc-software/qm/dist/src/util.js:255` |
| That makes docker detection fail on Windows | reproduced verbatim: `which('docker')=false` while `docker version -f` → `29.8.0` |
| Only one `/bin/sh` occurrence | repo scan of qm dist → 1 |
| Docker itself is healthy | `docker info` → ServerVersion 29.8.0, exit 0 |
| WSL lacks node, has sh/docker/npm | `wsl -d Ubuntu-24.04 -- bash -lc ...` |
| Git for Windows ships sh.exe | `C:\Program Files\Git\bin\sh.exe` exists |
| qm targets fly/aws | `qm --help`; `qm.config.jsonc` `"target": "docker"` |
| qm is same-host coupled | `qm.config.jsonc` `host.docker.internal` for both URLs |
| Per-machine state, no sync | compose bind mounts; `git ls-files deploy/client-bundle/data` = 0; gitignored; repo-wide sync search empty |
| setup-qm generates secrets, prompts for identities | `setup-qm.ps1` lines 106-151, 126-139 |
| **Mailpit SMTP catcher already implemented** | `deploy/qm-pacgate/compose.qm.yaml` service `mailpit` (`axllent/mailpit:v1.24`, alias `mailpit`, port 8025) |
| **auth already wired to Mailpit** | same file L153-157: `SMTP_HOST: mailpit`, `SMTP_PORT: 1025`, `SMTP_TLS: none` |
| **Magic-link E2E previously passed** | `plans/010-qm-single-stack-migration.md` "Magic-link login E2E" |
| **compose path bypasses the qm CLI** | `plans/010`: stack migrated from `qm up` to `docker compose -f compose.qm.yaml` |
| **compose validates without .env** | `docker compose -f compose.qm.yaml config` → exit 0 |
| qm code DOES accept `SMTP_TLS: none` (docs say otherwise) | `dist/src/preflight.js` `smtpTlsMode` returns `"none"`; only `starttls` enforces STARTTLS |
| 22 real required env vars (23rd was a scan false positive) | regex over `compose.qm.yaml`; `${VAR}` occurs only in a doc comment (L11) |
| External network + volumes absent on this box | `docker network ls` / `docker volume ls` → none |
| Plugins get a network alias on the qm network | `dist/src/backends/docker.js:524` `--network-alias p.name` |
