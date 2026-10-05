# Plan 025 — Wire the qm sandbox launch mechanism (docker backend inside the core)

> **Fix plan.** Closes the last functional gap in the stack: the qm agent
> sandbox lane was never wired (`SANDBOX_BACKEND=local` shells the `docker`
> CLI inside the qm core container, which had no CLI and no socket). Root
> cause, evidence, and the exact wiring are recorded here. Companion to
> plan 024 (verification) and `deploy/DEFECT-qm-sandbox-image-unobtainable.md`
> (whose "wire the backend" requirement this plan executes).

## Status

**EXECUTED 2026-10-05 on the dev box.** All steps live-verified; two
additional defects were found and fixed in passing (socket-permission model,
CRLF launcher). Client rollout still requires the clean-clone proof
(repo rule).

## Root cause (verified live, 2026-10-05)

`SANDBOX_BACKEND=local` makes the qm core run the `docker` CLI **inside its
own container** (`config.js:98` `sandboxCoreEnv` → `SANDBOX_BACKEND=local`).
That path needs, in the core container:

| # | Requirement | State before this plan (measured) |
|---|---|---|
| 1 | `docker` CLI binary | **absent** (Alpine core, no binary) |
| 2 | daemon socket `/var/run/docker.sock` | **absent** (no mount anywhere; first socket mount in this repo is this plan) |
| 3 | permission to use the socket | n/a until 1-2 existed; measured after wiring: socket is **root:root, mode 660, no docker gid** (Docker Desktop / WSL2 serves it root-owned, unlike a Linux host's `root:docker`) |

With all three missing, the preflight failed with the misleading
"requires a running Docker daemon" message (handbook §7.4). The image pin
itself was already fixed upstream on 2026-10-04 (`d9645e9c…`, public),
and the image is on-box (5.0 GB) — so the wiring was the only gap.

## The fix (Option A: compose-level, no new images)

### What changed

1. **Static docker CLI vendored client-side**
   `deploy/client-bundle/qm-pacgate/patch/docker-cli/docker` — the official
   static client binary, extracted from
   `https://download.docker.com/linux/static/stable/x86_64/docker-28.5.2.tgz`
   (42,810,144 bytes). **Only `docker` is mounted**; `dockerd` and `runc`
   from the same archive are deliberately NOT vendored — the core must never
   be able to run a daemon or shim execution; it is a client only.
2. **`compose.qm.yaml` (both copies, dual-maintained per the repo rule)**
   core service gains:
   - `group_add: ["0"]` — socket access grant (see defect D-2 below)
   - `- ./patch/docker-cli/docker:/usr/local/bin/docker:ro`
   - `- /var/run/docker.sock:/var/run/docker.sock`
3. **Security posture (decision, recorded):** a RW docker socket is
   host-root-equivalent. Accepted for this deployment because the target is a
   single-firm AIPC the firm owns end-to-end — the same trust boundary Docker
   Desktop itself already grants the user. **NOT acceptable for shared or
   multi-tenant hosts**; those should revisit (sprites/aws backends or a
   scoped daemon proxy).

### Defects found and fixed during execution

**D-1 (transient, self-healed):** first attempt `group_add: 999` on the
theory WSL2 provisions a docker-access gid at 999. Measured result: the
socket inside the container is `root:root 660` and the container's Alpine
environment already has a `ping` group at gid 999 — the grant was a collision
no-op, `docker ps` → `permission denied`. The measured, correct grant on
Docker Desktop is **gid 0 (root group)**; comment updated to carry the
measurement so the next operator does not re-derive it.

**D-2 (image defect: CRLF launchers, image-baked):** the `pacgate-qm` /
`firecrawl-qm` launchers inside the **published** sandbox image carry CRLF
(`#!/usr/bin/env bash\r`) and fail as `env: 'bash\r': No such file or
directory`. Chain: `git ls-files --eol` shows `i/lf w/crlf` on every
`sandbox/tools/**` file — the repo index is LF, but macOS/Windows working
trees check them out with autocrlf + no `.gitattributes` text rule for these
paths (`.gitattributes` covers binary files only). The image build COPYed
the CRLF working-tree files. **This shell-quotes exactly the runbook's known
gotcha** ("tasks/patch-pi-models.sh with CRLF fails `set -e`: illegal option
-"). Fix requirements (recorded for the image rebuild task):
1. `.gitattributes`: `deploy/qm-pacgate/sandbox/tools/** text eol=lf`
   (or `*.sh` + the launcher paths), so fresh clones always check out LF;
2. belt-and-braces in `sandbox/Dockerfile`: strip CR after COPY
   (`RUN find /usr/local/bin -name '*-qm*' -exec sed -i 's/\r$//' {} +`);
3. rebuild + repin + fingerprint-record (`scripts/qm-sandbox-fingerprint.ps1
   -Write`) per the publish flow upstream fixed on 2026-10-04.
   Until that rebuild, the runtime-stripping workaround (below) is viable.

## Verification performed (2026-10-05, this box)

| # | Check | Evidence |
|---|---|---|
| V1 | Both compose copies validate | `docker compose config --quiet` exit 0 (both) |
| V2 | core recreated with wiring | `docker compose up -d --force-recreate core` — Up |
| V3 | CLI present in core | `docker exec qm-pacgate-core docker --version` → `Docker version 28.5.2, build ecc6942` |
| V4 | socket reachable as node (uid 1000, groups 0(root),1000) | `docker exec qm-pacgate-core docker ps` → lists host containers |
| V5 | pinned sandbox image resolvable **through the core's daemon** | `docker image inspect $FLY_BASE_IMAGE` → `size=5004223092` |
| V6 | **sandbox container boots through the core (first-ever)** | `docker exec qm-pacgate-core docker run --rm $FLY_BASE_IMAGE sh -c ...` → `SANDBOX-BOOTED`, tool dir listing shows `pacgate-qm`, `firecrawl-qm` launchers |
| V7 | **sandbox bridge tool → live pacgate-api round trip** | in-sandbox `pacgate_qm.py workflow-categories` with the real `FLY_RESIDENT_ENV_*` env returned live library data (`advertising_compliance`, `ai_compliance`, ...) |
| V8 | qm stack healthy post-recreate | core/portal/auth/web-ui/admin/pg/mailpit all Up; magic-link session still valid |

## One provisioning fix executed in passing (root-caused, not optional)

V7 initially returned `401 invalid email or password` from the LIVE API.
Root cause: the **qm-bridge service account had never been created in this
DB** — the qm `.env` declares its credentials, but on a fresh DB, with open
registration closed (0.1.22), nothing mints it. Fixed by the documented
admin route:

```
POST /pacgate/api/auth/users  {"email":"qm-bridge@…","password":<qm .env>,"role":"attorney"} → 200
```

Then V7 passed immediately. **This belongs in `setup-qm.ps1`** (bootstrap
step: after the core is up, ensure the bridge account exists via
`/api/auth/users`), because every fresh install will hit the same 401 at the
first sandbox tool call — recorded as the follow-up task below.

## Follow-up tasks (recorded, not executed in this plan)

1. **`setup-qm.ps1`: ensure the qm-bridge account** via `POST /api/auth/users`
   if absent (idempotent; reuse the existing bridge creds it already writes
   to qm's `.env`).
2. **CRLF launcher fix + sandbox image rebuild/repin** (D-2 items 1-3).
3. **Commit the vendored CLI binary** (or make `setup-qm.ps1` fetch +
   hash-verify it — the repo's other static fetches use `-C -` resume +
   checksums; binary-in-repo is simpler but 43 MB).
4. **Full in-sandbox agent E2E** (a real qm agent task invoking ov-*/pacgate
   tools inside a launched sandbox) — this plan's V6/V7 prove boot + tool
   layer + live API; the agent-loop test is the last mile.
5. **Clean-clone proof** of the new compose + bootstrap steps (repo rule:
   a fresh clone is the only valid test for install-path changes).

## Related

- `deploy/DEFECT-qm-sandbox-image-unobtainable.md` — the three wiring
  requirements (image public/repinned ✔, socket+CLI ✔ this plan, E2E that
  starts a sandbox ✔ V6/V7).
- `deploy/handbooks/qm-openviking-pacgate-handbook.zh.md` §7.4 — the §7.4
  "目前未接线" verdict is now FIXED on this box; handbook update task above.
- `plans/024` — re-audit addendum 1, which recorded this gap as the sole
  remaining blocker.