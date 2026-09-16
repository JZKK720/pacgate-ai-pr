# qm-pacgate integration map

Evidence-backed. Every claim cites `path:line`. Written after discovering two real
defects by reading the files rather than trusting the documentation — the docs
disagreed with the code in both cases.

## 1. What qm is, and how it is deployed

`deploy/qm-pacgate/` is a **separate deployment definition** for the QM
co-working workspace. It is tracked in git; the runtime copy under
`deploy/client-bundle/qm-pacgate/` is gitignored (`.gitignore:62`) because `qm`
writes generated files into its deployment directory.

Bootstrap: `deploy/client-bundle/setup-qm.ps1`. It checks Node 24+/npm/Docker,
stages the deployment, runs `npm ci`, generates five signing secrets, prompts for
the admin email and the Pacgate bridge service account, writes `.env`, runs
`qm check`, then `qm sandbox build` (`setup-qm.ps1:120-166`).

It deliberately does **not** run `qm up` — the operator verifies config first
(`setup-qm.ps1:14`).

## 2. Topology — qm does NOT join the main stack's network

This is the single most important structural fact, and it is easy to assume wrong.

| Stack | Compose file | Network |
| --- | --- | --- |
| Main (pacgate-api, deer-flow, nginx, openviking, db) | `deploy/client-bundle/compose.prod.yaml` | `client-bundle_default` |
| qm (core, web-ui, portal, auth, admin, mailpit, pg) | `deploy/qm-pacgate/compose.qm.yaml` | `qm-pacgate`, declared `external: true` (`compose.qm.yaml:215-218`) |

There are **zero** references to `client-bundle` in `compose.qm.yaml`. qm reaches
the main stack only through **published host ports** via
`host.docker.internal`:

| qm needs | Address | Main-stack publish | Verified |
| --- | --- | --- | --- |
| pacgate-api (metadata, workflows) | `http://host.docker.internal:8089/pacgate` (`qm.config.jsonc:75`) | nginx `8089:80` (`compose.prod.yaml:151`) | ✅ matches |
| OpenViking (memory) | `http://host.docker.internal:1933` (`qm.config.jsonc:76`) | openviking `1933:1933` (`compose.prod.yaml:139`) | ✅ matches |
| Ollama (model inference) | `http://host.docker.internal:11434/v1` (`qm.config.jsonc:63`) | Windows-native Ollama | ✅ |
| qm core (from sandboxes) | `http://host.docker.internal:8180` (`compose.qm.yaml:53`) | qm's own `8180:8080` | ✅ |

**Consequence worth knowing:** because the coupling is by host port, changing a
published port in `compose.prod.yaml` silently breaks qm's sandbox tools. Nothing
validates that agreement today. The `/pacgate` path prefix matters too: nginx
routes root `/` to the deer-flow frontend, so qm's sandbox tools must use
`/pacgate` or they reach the frontend instead of the API (`compose.qm.yaml:60-63`
records this as the `7528e49` fix).

## 3. The sandbox — what qm agents can actually do

`sandbox/Dockerfile` builds on `ghcr.io/yc-software/qm/sandbox-base@sha256:52cb44a6…`
(an **upstream** image, pinned by digest) and adds two tools plus three skills.

| Tool | Binary | Purpose |
| --- | --- | --- |
| `pacgate-qm` | `pacgate_qm.py` | bridge back to pacgate-api |
| `firecrawl-qm` | `firecrawl_qm.py` | web search |

| Skill | |
| --- | --- |
| `pacgate-workflow` | |
| `pacgate-workflow-reference` | |
| `firecrawl-web` | |

The sandbox image itself is pinned **by digest** in two places —
`qm.config.jsonc:73` and `compose.qm.yaml:57`, both
`localhost:5000/pacgate-sandboxes@sha256:207a779d…`. `localhost:5000` is a
**machine-local registry**: this image cannot be pulled, only rebuilt with
`npm exec qm -- sandbox build`. `scripts/qm-sandbox-fingerprint.ps1` detects when
`sandbox/` has changed but the digest has not, which is otherwise silent.

`secretEnv` (`qm.config.jsonc:78`) requires seven values reachable by the sandbox:
`PACGATE_API_EMAIL`, `PACGATE_API_PASSWORD`, `OPENVIKING_ROOT_API_KEY`,
`OPENVIKING_API_KEY`, `OPENVIKING_ACCOUNT`, `OPENVIKING_USER`,
`FIRECRAWL_API_KEY`.

## 4. `patch/pi-models.ts` — why a patch file exists for a dependency

Mounted over `/app/src/model/pi-models.ts` (`compose.qm.yaml:79-81`). The comment
says it overrides the pi model registry so the configured Ollama model
(`glm-5.3-flash:cloud`) points at `MODEL_BASE_URL` instead of the hardcoded
`api.openai.com` catalog entry — durable across container recreation. Without it,
the pi harness would try to bill OpenAI for a model that only exists in local
Ollama.

## 5. The deer-flow ↔ QM ↔ OpenViking loop

Three services, two directions, memory as the shared substrate:

1. **deer-flow** (research) reads OpenViking for matter memory via
   `deer-flow-extensions-config.json`, which is rendered from a template by
   `install.ps1` and mounted read-only (`compose.prod.yaml:67`).
2. **qm** (collaboration) reaches both pacgate-api and OpenViking over host ports,
   and its sandbox tools (`pacgate-qm`, `firecrawl-qm`) call them during agent runs.
3. **OpenViking** serves both, with the important credential asymmetry: `/mcp`
   authenticates with the **ROOT** key and the app key returns 401
   (`compose.qm.yaml:68-70`, `deer-flow-extensions-config.template.json`).

The loop is therefore: qm agent → `pacgate-qm` tool → `/pacgate/` on nginx →
pacgate-api; and qm agent → `firecrawl-qm` / ov-* → OpenViking for recall and
persistence.

## 6. GAPS AND RISKS — ranked by client impact

### FIXED in this pass

**G1 — `setup-qm.ps1` claimed to stage the deployment but never did.** The header
said "Copies qm-pacgate/ to the target directory" and `.gitignore` described the
runtime copy as "staged by setup-qm.ps1", but no `Copy-Item` existed. A fresh
machine hit `qm-pacgate directory not found` at the default path, and a client
engineer was told to copy manually with no stated source. Now stages from the
tracked `deploy/qm-pacgate`, excluding `.env` so a re-run cannot destroy generated
secrets, and fails loudly if the source is absent. Guarded by
`scripts/audit-qm-bootstrap.ps1`.

**G2 — the generated `.env` omitted five required values.** compose substitutes an
**empty string** for an unset `${VAR}`, so these fail late and obscurely:

| Missing | Consequence |
| --- | --- |
| `POSTGRES_PASSWORD` | `DATABASE_URL` becomes `postgres://postgres:@pg:5432/qm` — empty password, no default in compose (`compose.qm.yaml:52`) |
| `OPENVIKING_ROOT_API_KEY` | the ov-* sandbox tools return 401; the app key is not accepted at `/mcp` |
| `OPENVIKING_API_KEY` | sandbox OpenViking access |
| `FIRECRAWL_API_KEY` | `firecrawl-qm` tool unusable |
| `AUTH_ALLOWED_EMAILS` | who may sign in is undefined |

Now generated: `POSTGRES_PASSWORD` is randomly generated; the OpenViking and
Firecrawl keys are read from the main bundle's `.env`, which `install.ps1` already
produced — they must match because qm talks to the **same** OpenViking instance.

**G3 — the workflow's GHCR namespace was inferred, not pinned.** A `v0.1.*` tag
pushed on origin would have published to `ghcr.io/jzkk720/*`, a namespace nothing
pulls from: a release that succeeds, publishes nowhere useful, and leaves clients
on the old image with no error. Now a committed `GHCR_NAMESPACE: pacgate-ai`
constant with a warning if the resolved namespace is not the pinned one, guarded by
`scripts/test-workflow-namespace.ps1` (13 assertions, including that all 8 compose
pins agree).

### OPEN — not fixed here

**R1 — host-port coupling is unvalidated.** qm hardcodes `8089`, `1933`, `11434`,
`8180`. If any published port in `compose.prod.yaml` changes, qm's sandbox tools
break silently. Nothing checks the agreement. *Suggested fix: extend
`audit-qm-bootstrap.ps1` to parse both files and assert the ports line up.*

**R2 — qm is outside the update path.** `install.ps1 -Update` does not touch qm:
it does not rebuild the sandbox, restart qm containers, or update
`deploy/client-bundle/qm-pacgate`. The repo refresh does update the tracked
`deploy/qm-pacgate/`, but the **runtime copy** in the bundle is a separate
directory that nothing re-stages. So a qm config change reaching a deployed
machine requires re-running `setup-qm.ps1`. **This is the largest remaining gap in
the "unattended update" goal** — plan 014 covers the main stack and reports qm
sandbox drift, but does not deliver qm changes.

**R3 — no recorded sandbox fingerprint on any machine.** `qm-sandbox-fingerprint.ps1`
reports `NOT_RECORDED` until someone rebuilds the sandbox, repins the digest, and
runs `-Write`. Honest, but it means the sandbox's provenance is currently
unverifiable on both AIPCs.

**R4 — `compose.qm.yaml` and `qm up` can fight.** The header warns that bringing
the stack up with `docker compose -f compose.qm.yaml up -d` and *also* running
`qm up` in the same directory would contend for the same named volumes and
network. Both paths look valid to a new operator.

**R5 — local test box cannot run qm.** This dev box has no Node 24/npm qm
deployment present, so none of the above was verified by executing qm — only by
reading its configuration and comparing it against the main stack's published
ports. The port comparisons were done against the real compose files, but
"the addresses agree" is not the same as "the loop works end to end".
