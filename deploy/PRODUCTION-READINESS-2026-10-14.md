# Production readiness — when can client AIPCs be upgraded?

**Question asked:** when are we 100% ready to deploy?
**Answer:** 0.1.30 is the first release that is **deployable**. It is not yet "100%",
because two known issues are unresolved and one is CRITICAL by our own definition.

**Date:** 2026-10-14

---

## 1. Which releases are actually proven?

Measured from `CLEAN-CLONE-PROOF-LOG.md` - not from memory:

| release | clean-clone proven | note |
| --- | --- | --- |
| v0.1.24 | PROVEN | run 2 |
| v0.1.27 | PROVEN | run 3 |
| **v0.1.28** | **NOT PROVEN** | shipped, never proved on a clean machine |
| **v0.1.29** | **NOT PROVEN** | shipped, never proved; also incomplete (see §3) |
| **v0.1.30** | **PROVEN** | run 4, the first genuinely isolated run |

Two releases went out with no clean-machine proof. That is the process gap that let a
1-in-3 HTTP 500 ship twice, and it is why the answer below is evidence-based rather than
"it feels done".

## 2. What 0.1.30 has proven

**Clean clone, isolated volumes (`COMPOSE_PROJECT_NAME=pacgate-proof`), fresh database
and fresh secrets:**

| # | check | result |
| --- | --- | --- |
| 1 | `install.ps1` on **Windows PowerShell 5.1** | exit 0 |
| 2 | `/version` at the nginx ROOT | `0.1.30` rev `4c0b2ca` |
| 3 | `/setup`, the browser first-admin surface | 200 |
| 4 | containers | 8, all first-party images at 0.1.30 |
| 5 | workflow library | 222 workflows / 46 categories |
| 6 | **full legal journey** | **19 / 19, NO SKIP** |
| 7 | first-time DB | `tenants=1 users=1 matters=1` |
| 8 | all 5 images PUBLIC, anonymously pullable from a clean credential store | PASS |
| 9 | release provenance (tag identifies the published artifacts) | PASS |
| 10 | full gate suite | **37 static + 9 live = 46 gates, all PASS** |

And on the dev box, on the published artifact:

| metric | 0.1.28 | 0.1.29 | **0.1.30** |
| --- | --- | --- | --- |
| HTTP 500 on `workflows/:id/execute` | 3 of 8 | 0 of 8 | **0 of 12** |
| HTTP 200 with `content: null` | n/a | **5 of 8** | **0 of 12** |
| `generate_docx` calls per step | up to 10 | up to 10 | **3-6** |
| format coverage (upload->extract->sanitize->convert) | untested | untested | **8/8 cases, 40 assertions** |

## 3. What 0.1.29 was, and why 0.1.30 exists

0.1.29 fixed a real defect correctly - it stopped returning HTTP 500 for work that had
already succeeded - and in doing so made the failure **quieter and more common**. It
returned HTTP 200 with a blank answer on 5 of 8 runs. 0.1.30 completes it.

**Do not deploy 0.1.29 to client machines.** 0.1.28 is also superseded. 0.1.30 is the one
to deploy.

## 4. The blockers that remain

### 🔴 BLOCKING - sanitized documents download as the ORIGINAL

Measured on all seven formats. After a `verdict=pass` sanitization whose response is
correctly redacted, `GET /api/documents/:id/download` serves the original file with the
raw identifiers, because the sanitizer persists a state flag rather than a sanitized
artifact. `pacgate_convert_document` (the agent's read/convert path) returns the same
raw bytes.

**This needs a product decision, not a patch**, which is why it is still open:

- *Serve sanitized* -> store a sanitized rendering per version and re-render redactions
  back into docx/xlsx/pptx/pdf. A real feature, not a small change.
- *Keep the original, correct the claim* -> sanitization governs the **analysis lane**
  (what the agent reads, what the KB stores); the file you download is the matter's own.
  A one-word change in the UI and docs, no behaviour change.

Evidence for the second reading is real: `restore` exists precisely to hand an admin the
original, which would be redundant if download already served redacted content.
**But nobody has decided, and until they do, no client should be told "documents are
sanitized" without the qualifier.** Either decision is cheap to implement; leaving it
ambiguous is not.

### 🟠 Duplicate documents are not prevented

The model can call `generate_docx` several times with *different* arguments before
converging - runs produced up to 4 near-identical documents in one matter. Loop detection
keys on an **identical** `tool + arguments` pair, so a varying-argument loop is untouched.
A user can be shown a matter containing several copies. Fixing it means deciding whether
repeated generation is legitimate iteration or a mistake.

### 🟠 No compose healthcheck anywhere

7 of the 8 first-party containers are unmonitored. `restart: unless-stopped` cannot
rescue a wedged-but-running container, so a client sees a live-looking stack that answers
nothing. Adding healthchecks changes client restart semantics and needs its own review.

### 🟡 Not blocking, recorded

- Image-only PDFs convert to `ok: true, chars: 0` with no reason, so the agent is told
  nothing about needing the OCR lane - and scans are the norm in legal work.
- Document versions count per **stem**, not per document, so `report.docx` and
  `report.xlsx` share a counter and docx versions can be non-contiguous.
- An intermittent HTTP 500 on extract was reproduced **once** and then 0 of 12 runs.
- Memory aging and supersession are untested; qm-team, team users and cross-user data
  sharing have no test at all.

## 5. The answer

**Deploy 0.1.30 to AIPC 1 and 2 now, with one qualifier.** It is proven on a clean
machine, on PowerShell 5.1, with isolated volumes and a fresh database; all 46 gates
pass; the delivery, OCR, sanitizer, format and document-generation lanes are covered;
and the release that made things worse (0.127.x -> 0.1.29) is superseded.

The qualifier is the sanitizer: **until someone decides what "sanitized" means for
download**, every client conversation should say *"sanitization governs what the agent
reads and what the knowledge base stores; it does not alter the file you download."*
That is one sentence, and it is honest.

**To answer "100%"**: not while a CRITICAL finding about client PII is open. Closing that
single item - whichever way it is decided - is what moves this from "deployable with a
caveat" to "fully functional". Duplicate documents and healthchecks are quality work that
can follow a release; the sanitizer question cannot, because it is the one a client's own
compliance review would find.

## 6. The process fix that stops this recurring

Every defect found in this series was a test asserting the thing that was **easy to
observe** rather than the property that **mattered**:

| the assertion | what it missed |
| --- | --- |
| "the weights volume IS mounted" | the volume **shadowed** the baked weights |
| "download allowed post-sanitize -> 200" | the bytes were the **original** |
| "the model returned 200" | the answer was **empty** |
| "the picker 401s" | 401 means *authenticate*, and the credential was documented |
| "recall found the marker" | a semantic memory **summarizes**; a random token is noise |
| "the tag exists" | the tag pointed at the **wrong build** |

The gates added for each now assert the property, and each was red-checked by
reintroducing the defect. The remaining structural gap is that **no gate measures a
failure RATE** - the 1-in-3 defects passed a single-run suite two times in three. The
`-FailureRateRuns` soak exists for that and belongs in the release checklist.
