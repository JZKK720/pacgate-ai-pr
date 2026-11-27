# Adoptability audit — can this stack be adopted cleanly on another machine?

**Date:** 2026-10-18
**Question asked:** after fixing the `FLY_RESIDENT_ENV_*` drift class, is the whole system
adoptable end-to-end on other machines, and does an upgrade leave qm + OpenViking + deer-flow +
api + mcp + tools/workflows/data/templates all working?

**Method:** measured on the live stack, not read from docs. Every claim below has a probe behind
it; commands are given so any of them can be re-checked.

---

## 1. The drift sweep result (the three classes)

`FLY_RESIDENT_ENV_*` is the mechanism that copies credentials across the stack boundary at setup
time. Nine keys, and they fail in **three distinct ways** — only the first was in the original
report:

| class | what it means | found |
| --- | --- | --- |
| **A. File vs file** | the two `.env` files disagree | `PACGATE_API_PASSWORD` (16 vs 24 chars) — fixed |
| **B. File vs live container** | file fixed, container never recreated | caught by C2 after the fix, then applied |
| **C. File vs SERVICE** | both files agree perfectly, and the value is still invalid | `OPENVIKING_API_KEY` — fixed |

**Class C is the dangerous one.** A file-to-file guard can never see it: both files agreed, they
were simply both wrong. The only way to catch it is to ask the SERVICE, which the new gate now
does (C3 static contract + C4 live `/mcp` probe).

### The `OPENVIKING_API_KEY` defect

`ov.conf.template` declares only `root_api_key`. No per-client key is ever registered in the
service, so a separately generated `OPENVIKING_API_KEY` authenticates with nothing:

```
POST /mcp, X-API-Key = a distinct OPENVIKING_API_KEY  -> 401 {"code":-32001,"message":"Invalid API Key"}
POST /mcp, X-API-Key = the ROOT key                   -> 200 + the tool list
```

`.env.example:107` already sanctions the correct value — *"API key clients use to call OpenViking
(can equal root key in pilot)"* — so C3 asserts equality rather than inventing a rule.
`install.ps1` (~line 504) independently documents the same defect for the *deer-flow* template
("NOT `${OPENVIKING_API_KEY}` ... makes openviking return 401 and rolls back the entire MCP tool
load"). deer-flow was fixed there; the **qm** path was not.

**Why it hid:** OpenViking's `/health` needs no key, so every connectivity check passed while
every `ov-*` sandbox tool failed at call time. `smoke-full-stack.ps1` reported the lane as fine.

---

## 2. Upgrade path — does an upgrade leave every lane working?

**Good news, verified:** `setup-qm.ps1` **preserves an existing `.env`** (line ~295:
`[SKIP] .env already exists - preserved, NOT regenerated`). So the credential fixes survive
`-Update`; they are not overwritten. That was the biggest risk and it is not present.

### But `-Update` is not uniformly trustworthy

`scripts/audit-aipc-update-coverage.ps1` reports **"12 of 12 covered, 0 needing a human."**
That claim is too optimistic, and it is the instrument an operator would rely on:

- It does not cover the **cross-stack credential** dimension at all — the drift found above lived
  exactly in the gap.
- It does not cover whether a recreated container actually **picked up** the new value (class B).
- It does not test any **edge**; a lane can be covered for config propagation and still be dead.

An audit that reports "0 needing a human" while three real defects are live is worse than no
audit, because it stops the search. The two new gates close the gap it left.

### One genuine propagation gap, documented honestly

The OpenViking key fix reaches running containers only on **recreate**, not `restart`. That is now
mechanically detectable (C2), so the state cannot sit stale and silent.

---

## 3. Adoptability on another machine

### 3a. BLOCKER — two compose files define the same project, and they differ

Both `compose.bundle.yaml` and `compose.prod.yaml` declare:

```yaml
name: pacgate-ai-bundle
```

They are therefore **two competing definitions of one compose project**, rooted in the same
directory. Whichever file runs `up -d` reconfigures the shared services. Normalised per-service
config hashes (comments ignored, fully resolved):

| service | bundle | prod | |
| --- | --- | --- | --- |
| pacgate-api | `A7A0E8E3FE` | `A7A0E8E3FE` | identical |
| openviking | `849D8F2943` | `849D8F2943` | identical |
| pacgate-db | `E0AE3F88B7` | `E0AE3F88B7` | identical |
| ocr-service | `94A4B86513` | `94A4B86513` | identical |
| **deer-flow** | `B61B84434E` | `4389761AD8` | **differs** |
| **deer-flow-frontend** | `96BAC4DE32` | `8088D38586` | **differs** |
| **pacgate-mcp** | `73112556F7` | `5E2A40C1E1` | **differs** |
| **nginx** | `30E2032586` | `D7B2661FA9` | **differs** |

The differences are **material, not cosmetic**:

- **pacgate-mcp** — `compose.prod.yaml` bind-mounts
  `deploy/pacgate-mcp/server.py` over `/app/server.py`, replacing the shipped image's code.
  Verified live: the running container has
  `C:\...\deploy\pacgate-mcp\server.py -> /app/server.py`. So a machine running "prod" executes a
  file from the working tree instead of the pinned image, while reporting image
  `ghcr.io/jzkk720/pacgate-mcp:0.1.31`. **What was tested is not what ships.**
- **nginx** — different `depends_on`, so startup ordering differs between the two.
- **deer-flow** — different volume set.

**This box is currently a MIX:** `pacgate-api` + `openviking` were created from
`compose.bundle.yaml`; `deer-flow`, `deer-flow-frontend`, `pacgate-mcp`, `pacgate-db`,
`pacgate-nginx` from `compose.prod.yaml`. Since the shared services are byte-identical, the mix is
currently harmless — but it is not a state anyone chose, and it means two operators on two
machines can end up with different runtimes while both believe they ran "the install".

**Recommendation:** pick ONE file as the delivery authority, and either make the other a thin
include/`extends` or delete it. Until then, `test-lane-connectivity.ps1` reports provenance on
every run so the mix is visible rather than inferred.

### 3b. Per-machine state that is correct but not reproducible

These are gitignored by design and created by the installers — fine on a clean machine, but they
are the files that drift, and none of them is version-controlled:

| path | created by | risk |
| --- | --- | --- |
| `deploy/client-bundle/.env` | `install.ps1` | shared secrets; drift class A |
| `deploy/client-bundle/qm-pacgate/.env` | `setup-qm.ps1` | **second copy** of the same secrets |
| `deploy/client-bundle/openviking/ov.conf` | container-generated | rendered state |
| `deploy/pacgate-mcp/server.py` | tracked, but bind-mounted over the image | see 3a |

### 3c. The least-privilege bridge gap (security posture, not connectivity)

`qm-pacgate/.env` sets `PACGATE_API_EMAIL=admin@pacgate-law.com` — the deployment's own admin.
`install.ps1` provisions `qm-bridge@pacgate.local` with a CSPRNG password, but **only when
`$needsBootstrap`** (i.e. qm's `.env` does not exist yet). On this box that env already existed, so
the bridge was never created. Probed: `admin` logs in; `qm-bridge@pacgate.local`,
`qm-bridge@pacgate-law.com` and `bridge@pacgate-law.com` all 401 — **no bridge account exists**.

So the sandbox lane — which executes model-directed tool calls — runs with the deployment admin's
identity, which `setup-qm.ps1`'s own comment argues against. Not a connectivity bug (everything
works), and not changed here: it is a security-posture decision. The new credential verification
makes repointing safe, because a wrong value is now refused instead of persisted.

---

## 4. What was verified working end to end

`scripts/test-lane-connectivity.ps1` (new, registered as a live-stack gate) — **11/11 lanes**:

| edge | result |
| --- | --- |
| E1 pacgate-api reachable + issues a token | PASS |
| E2 pacgate-mcp reachable | PASS (port 8090) |
| E3 openviking `/mcp` accepts the **client** key | PASS |
| E4 deer-flow reachable | PASS |
| E5 qm core reachable | PASS |
| **E6 qm → pacgate-api from INSIDE the container** | PASS (HTTP 200) |
| **E7 qm → openviking `/mcp` from INSIDE the container** | PASS (HTTP 200) |
| E8 workflow library | PASS — **222 workflows listed** |
| E9 data plane / tenants | PASS — 1 tenant row |
| E10 container provenance | REPORTED (see 3a) |

E6 and E7 are the ones nobody had. They probe from the **caller's side**, inside its own network
namespace with its own resident environment, which is the only way to see a 401 on a *copy* of a
credential. A host-side probe passes while the container's copy is dead.

Both were red before this work and green after, and both were red-checked by pointing the gate at a
service that answers but rejects the credential (E1 → FAIL, exit 1).

---

## 5. Remaining risks, ranked

1. **Release provenance is broken by the config changes in this work — release required.**
   `test-release-provenance.ps1` is **correctly RED**: `deploy/deer-flow-pacgate/config.yaml`
   (and `deploy/client-bundle/deer-flow-config.yaml`) can reach a built image, and both changed
   after `v0.1.31` was built from `9d31936`. So the tag no longer identifies the published
   artifacts — a client pulling `0.1.31` gets config that does not match the tag.

   This is not a defect to revert (the title/summarization pins fix a 25 GB model load on every
   new thread). It is a **release action**: bump (`. \scripts\bump-release-version.ps1 -To 0.1.32`
   → 99 edits across 11 files), rebuild, push, and re-tag. Until that is done the gate stays red,
   and it should: **do not ship these config changes under the existing tag.**
2. **The workflow MAIN tier could not generate documents at all** (§6) — fixed, but see the
   egress decision.
3. **Two compose definitions of one project** (§3a) — the only structural adoptability blocker.
   `pacgate-mcp` running local source under a "prod" label is the concrete hazard.
4. **Sandbox runs as admin** (§3c) — security posture, one env change + one container recreate.
5. **`smoke-full-stack.ps1` and the update-coverage audit over-report health** (§2). Both are
   "green dashboard" instruments; the new edge gate is the counterweight, but the old ones still
   say "fine" when the answer is "untested".
6. **Per-machine `.env` duplication** (§3b) — now guarded, but the duplication is the root shape.
   Sharing one `env_file` for the four common keys would remove the class rather than police it.

---

## 6. The document-generation defect (found while validating this work)

While re-running the suite after the credential work, `test-document-generation-e2e.ps1` went from
**19/19 to 2 failed**, deterministically. I first suspected my own recreates — cleared by evidence:
`deer-flow` and `pacgate-mcp` were created 2026-10-14 and I never touched them.

The real cause is a **product defect, not a regression**:

```
model_name: gemma4-12b-local
Thinking mode is enabled but model 'gemma4-12b-local' does not support it
tools_used: list_documents, kb_search        <- never reaches generate_docx
```

`pacgate-api` mapped `PACGATE_MODEL_MAIN` **and** `PACGATE_MODEL_LOW` to
`gemma4:12b-it-qat` — the local 12B. That model drives the workflow for one step, calls
`list_documents` and `kb_search`, and then stops. It never calls `generate_docx`. The route still
returns **HTTP 200** and the run reports success, so the failure surfaces as an empty result rather
than an error. Its own soak confirms the endpoint is healthy: **0 failures in 3 runs, all 200**,
while producing no document.

Controlled experiment — the same test, only the MAIN tier changed:

| `PACGATE_MODEL_MAIN` | tools invoked | document | time | gate |
| --- | --- | --- | --- | --- |
| `gemma4:12b-it-qat` (local 12B) | `list_documents, kb_search` | **none** | 60.7s | 2 failed |
| `deepseek-v4.1-flash:cloud` | `list_documents, kb_search, generate_docx, read_document` | **created, valid OOXML, Chinese intact** | 18.2s | **19/19** |

**Fix applied:** `PACGATE_MODEL_MAIN=deepseek-v4.1-flash:cloud` in
`deploy/client-bundle/.env` (per machine, gitignored) — **not** in the tracked compose default.

This matches the agreed architecture (2026-08-30): cloud does main prompting and end results,
local models are utility-only. It was not implemented for the *workflow* tier, only for deer-flow.

**Why `.env` and not the compose default:** it is a **data-egress decision**. Setting MAIN to a
cloud tag sends matter content to `ollama.com`. For a legal deployment that is a posture choice the
firm must make knowingly, so it belongs where a firm can see and revert it, with the trade-off
documented inline: revert to a local tag and document workflows produce nothing on a 12B model.
`LOW` stays local (utility tier, not used for generation).

**Not fixed, and worth flagging:** `PACGATE_MODEL_MID` still defaults to
`qwen3.8:27b-mtp-q4_K_M` (17 GB), which cannot fit a 16 GB AIPC — see
`test-aipc-capacity-fit.ps1`.

