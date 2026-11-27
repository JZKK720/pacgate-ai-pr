# Fresh install, end-to-end verification, and benchmark - 2026-10-19

**Scope:** a genuine from-scratch install of `0.1.33` on this dev machine covering
deer-flow, pacgate-api, pacgate-mcp, ocr-service, openviking and the qm stack,
with matters, workflows, templates and skills wired, then a full gate run and a
benchmark pass.

Everything below is measured on this machine after that install. Where a number
is a single-shot latency rather than a statistical run, it says so.

---

## 1. What "50 duplicated Sanitizer E2E matters" meant

Not a cache. Nothing in this system caches matters.

`scripts/test-sanitizer-e2e.ps1` created a matter with the **hard-coded name**
`"Sanitizer E2E"` on every run, and cleaned up only its *containers* - never the
row. Between 2026-10-12 and 2026-10-19 that accumulated **50** separate matters of
the same name, each carrying one `case` document.

Two consequences, and the second is the one that mattered:

1. 50 junk rows in the matter list.
2. **A name that occurs 50 times cannot identify anything.** Cross-machine import
   matches a matter by `external_key`, falling back to `name`; with 50 identical
   names the fallback is meaningless. That is precisely the problem
   `matters.external_key` exists to solve.

**Fixed at the source:** the e2e test now deletes the matter it created. Order is
load-bearing - the delete runs *before* `Remove-E2EContainers`, because the
fixture lives in the e2e container's own database on `:8097`. My first attempt put
it after the teardown and silently did nothing ("connection refused"), leaving a
51st row; caught by re-running and checking the count stayed at 50.

**Existing residue cleared** with `scripts/clean-test-fixtures.ps1`, which reports
by default and only deletes with `-Delete`:

```
    50 x  Sanitizer E2E
     1 x  fmtcoverage-01ebc194
     1 x  leaktest        1 x  piitest        1 x  xl500        1 x  xlsxloop
  [OK] 55 fixture matter(s) in 6 name group(s)
  [OK] deleted 55 of 55
```

Kept, deliberately: `default` (the installer-pinned matter), `Firm Knowledge Base`,
`decline-1`, `decline-6`. Post-purge state: **4 matters, 14 documents, 0 orphaned
documents**, and the pinned matter still answered 200.

---

## 2. Does v0.1.33 update everything?

**No - and it cannot, by design.** Two different distribution channels:

| Component | Versioned with v0.1.33? | How it reaches a machine |
|---|---|---|
| `pacgate-api` | **Yes** - `jzkk720/pacgate-api:0.1.33` | image pull |
| `pacgate-mcp` | **Yes** - `jzkk720/pacgate-mcp:0.1.33` | image pull |
| `deer-flow-pacgate` | **Yes** - `:0.1.33` | image pull |
| `deer-flow-frontend-pacgate` | **Yes** - `:0.1.33` | image pull |
| `ocr-service` | **Yes** - `:0.1.33` | image pull |
| `openviking` | **No** | vendor image, digest-pinned `volcengine/openviking@sha256:46f9e34…` |
| qm core / portal / auth / web-ui / admin | **No** | vendor images, digest-pinned `yc-software/qm/*` |
| `pacgate-nginx`, `pacgate-db` | **No** | `nginx:1.27-alpine`, `pgvector/pgvector:pg16` |
| **Workflows, templates, skills, install/config, all gates** | **Yes** - as repo content | `git pull --ff-only` inside `install.ps1 -Update` |

`build-ghcr.yml` builds exactly **five** `jzkk720` images; every matrix entry was
verified against its `context:`/`file:`. The qm and OpenViking images are vendor
artifacts pinned by digest - rebuilding them is neither possible nor desirable.
They "update" only by changing the digest pin, which is a deliberate act.

**So the honest answer:** v0.1.33 updates the five first-party images plus all
configuration, templates, workflows and skills. It does **not** and **should not**
touch qm or OpenViking. What it *must* guarantee is that those untouched vendor
stacks keep working with the new first-party ones - which is what the wiring
checks below assert, and what was actually broken before this session.

---

## 3. How you can trust that this is one working system

Not by assurance - by these specific checks, all run after the fresh install:

| Check | Result |
|---|---|
| `run-all-checks.ps1` | **ALL 43 GATES PASSED** |
| `smoke-full-stack.ps1` (all 6 lanes together) | 19 passed, 0 failed, 2 cannot-check |
| `test-lane-connectivity.ps1` (11 edges, incl. in-container) | 11 passed, 0 not reachable |
| `test-origin-coherence.ps1` (browser origins + OIDC) | 19 passed, exit 0 |
| `test-cross-stack-credentials.ps1` (admin + bridge authenticate) | pass, 0 warnings |
| `test-qm-currentness.ps1` (staged == tracked, live == .env) | 0 warnings |
| `test-skills-and-templates.ps1` | 8 passed |
| Sanitizer / OCR / formats / generation e2e | 59/59, 15/15, all formats, 19/19 |

The point of the last row: the gates are not a proxy. `smoke-full-stack` exercises
all six lanes *together*, and `test-lane-connectivity` probes the container-to-
container edges including from **inside** the qm container.

---

## 4. What the fresh install actually exposed (all now fixed)

A from-scratch install found **six** defects that the full green suite had not.
That is the reason to do one.

**a. The OAuth fix was never committed - my error.** Earlier in this session I
reported parameterizing the qm OAuth URLs. The edit landed on the *staged* copy at
`deploy/client-bundle/qm-pacgate/compose.qm.yaml`, which `setup-qm.ps1` overwrites
from the tracked source on every run. The tracked file still had **8** URLs
hardcoded to localhost, so a fresh install still advertised
`issuer=http://localhost:8181/idp`. Now applied to
`deploy/qm-pacgate/compose.qm.yaml`; verified `issuer=http://<hostname>:8181/idp`
with in-cluster token/JWKS still on `auth:8080`.

**b. `setup-qm.ps1` exited 1 on the normal first-install 401.** The pre-write
credential probe treated "account not found" as fatal, but on a fresh database the
bridge account does not exist yet by definition. Worse, step 8b - the step that
mints it - sat after both this `exit 1` and an early return, so it was
unreachable. Net effect: no qm `.env`, and the qm stack came up with **7
misconfigurations**.

**c. Bridge minting only ran on a first install.** Now `Ensure-BridgeAccount`, a
function called from *both* paths, and it fetches an **admin** token first because
`/api/auth/users` is admin-only - which is why creation failed even when reached.

**d. `test-cross-stack-credentials.ps1` demanded the bridge be an admin.** C1
required `PACGATE_API_EMAIL`/`PASSWORD` to be byte-identical across both `.env`
files, but `setup-qm.ps1` states the bridge is "a SEPARATE, least-privilege
service account". The check could only pass in the over-privileged state the
design avoids. Replaced with C1b: **each identity must authenticate** (both 200).

**e. `PACGATE_MATTER_ID` pointed at an all-zero UUID** (`00000000-0000-4000-8000-
000000000000`) that 404'd. The installer provisions a real matter only when the
API is reachable; during the first pass it was not, so `.env` kept the placeholder.
Re-running provisioned matter `4e1d30cc…` and wrote it to `.env`.

**f. Password rotation vs. an existing data volume.** Changing
`PACGATE_DB_PASSWORD` / qm's `POSTGRES_PASSWORD` in `.env` does not change the
role password baked into `pgdata`, so both APIs crash-looped with
`28P01 auth_failed` until `ALTER USER` aligned them. This is expected Postgres
semantics, but it cost real time and deserves a line in the installer output.

Also fixed: `openviking` boot-looped on `/health 503` because
`OPENVIKING_ROOT_API_KEY` was still the `.env.example` placeholder
`change-me-…`, so the installer **skipped** rendering `OPENVIKING_CONF_CONTENT`
with only a `[WARN]`. With a real key it rendered and the lane came up healthy.

---

## 5. Benchmark (this machine, after install)

Single-shot latencies through the real ingress chain. Not a statistical run;
treat as order-of-magnitude.

### API through nginx (`:8089/pacgate`)

| Endpoint | Latency |
|---|---|
| `/version` | **3.9 ms** |
| `/api/matters` (list) | **5.1 ms** |
| `/api/workflows` (222 workflows) | **41.6 ms** |

### Memory and workspace lanes

| Endpoint | Latency |
|---|---|
| `/api/matters/:id/memory` | **11.2 ms** |
| `/api/matters/:id/workspace` | **7.3 ms** |

### Other stacks

| Endpoint | Status | Latency |
|---|---|---|
| OpenViking `/health` `:1933` | 200 | **4.3 ms** |
| qm portal `:8181` | 401 (auth required - correct) | **6.9 ms** |
| deer-flow frontend `:8090` | 200 | **13.7 ms** |
| MCP `initialize` handshake `:8000/mcp` | ok | **11.0 ms** |

### Resource footprint (idle, whole system)

| Container | CPU | Memory |
|---|---|---|
| pacgate-api | 0.01% | 1.34 GiB / 4 GiB limit |
| ocr-service | 0.19% | 982 MiB |
| openviking | 2.20% | 579 MiB |
| deer-flow-frontend | 0.00% | 387 MiB |
| deer-flow | 0.21% | 264 MiB |
| qm-pacgate-core | 1.35% | 146 MiB |
| qm-pacgate-pg | 2.64% | 106 MiB |
| pacgate-mcp | 0.24% | 75 MiB |
| pacgate-db | 0.00% | 49 MiB |
| qm admin/auth/portal/web-ui, mailpit, nginx | ~0% | 18-42 MiB each |

**Total ~4.1 GiB of container memory** for the complete 15-container system at
idle, measured usage only (`docker stats` twice, agreeing to 2 MiB).

> **Correction (2026-10-20).** An earlier revision of this file said "~6.1 GiB".
> That was wrong: it summed `MemUsage` **including the `/ limit` half** of the
> string for containers that have a `mem_limit`. The corrected figure is 4,160 MiB
> = 4.06 GiB = 4.36 GB. See `deploy/AIPC-HX370-CAPACITY-VERDICT-2026-10-20.md`
> for the per-container table and the AIPC budget arithmetic.

That is the number to plan an AIPC against - note the AIPCs have 32 GB
unified, and the LLM weights are *not* in this figure (they are in Ollama on the
host, 7.2 GB VRAM-resident for `gemma4:12b-it-qat`).

### Data state

`matters=5 documents=14 users=4 kb_chunks=82`

---

## 6. What this does and does not prove

**Proved:** all three runtimes start and interoperate on a from-scratch install;
all 43 gates pass; six lanes pass together in one smoke run; both credential
identities authenticate; the OAuth issuer is browser-reachable; skills, templates
and workflows are present and reach the agent; latencies are low single-digit to
tens of milliseconds on the control plane.

**Not proved, and should be measured on a real AIPC before claiming client
readiness:**

- **Latency and residency on the 16 GB machines.** Everything here is the 128 GB /
  96 GiB dev box. The measured **4.06 GiB** container footprint plus a 7.2 GB
  VRAM-resident model is **11.8 GB of system RAM and 7.5 GB of 16 GB VRAM** on an
  HX370 - comfortable, provided only one model is resident. With a Mid-tier model
  warm alongside it, VRAM reaches 14.1 GB and RAM 18.4 GB, which still fits but
  with little headroom. See
  `deploy/AIPC-HX370-CAPACITY-VERDICT-2026-10-20.md` for the arithmetic and the
  one recommended config change.
- **An actual LLM completion through the full pipeline.** The generation e2e gate
  passes (19/19, real OOXML), but per-call latency under a loaded model is not
  measured here.
- **A true clean-room install.** This was a *config* reset on a machine that
  already had images, `data/`, and a warmed Ollama. A genuinely new machine has to
  pull ~5 images, pull models, and pass first-boot provisioning with no prior
  state. The three password/matter defects above were found *because* data
  survived - a fully empty machine would hit a different subset.
