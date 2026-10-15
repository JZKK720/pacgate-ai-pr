# Production readiness — when can client AIPCs be upgraded?

**Question asked:** when are we 100% ready to deploy?
**Answer:** **0.1.31 is now deployable and is the frozen release.** The sanitizer blocker
is fixed and proven on the published artifact, the two remaining findings from the 0.1.29
audit are closed, and the whole update path has been exercised end to end on a real
machine. What remains is not engineering — it is *your* decision to schedule the window,
because the last step is a per-machine remediation pass that needs the admin credentials.

**Date:** 2026-10-14 (updated after 0.1.31 published, audit findings closed, and a live
update rehearsal)

---

## 0. Current state, measured

| item | state |
| --- | --- |
| version | **0.1.31**, 5 images public on GHCR, revision `9d3193666bb2` |
| `test-release-provenance.ps1` | PASSED - the tag identifies the artifacts clients pull |
| sanitizer fix | in the published binary (`reingest` present; absent in 0.1.30) |
| `/initialize` gate | **ARMED** by default in both compose files |
| compose healthchecks | **7 added** to each file; all 8 services report `(healthy)` |
| `install.ps1 -Update` | **exercised for real** on this box: completed, all services healthy |
| running `/version` | `0.1.31` rev `9d3193666bb2` |
| this machine's database | **remediated**: 37 documents repaired, audit now returns 0 |
| full gate suite | 38 static + live gates; the new one is `test-compose-healthchecks.ps1` |

### The three things fixed since the last revision of this document

1. **The sanitizer blocker**, proven by controlled A/B on the *published* images: the
   same gate and fixture return `FAIL (4)` on 0.1.30 and `PASS` on 0.1.31.
2. **`/initialize` was publicly claimable on a fresh install.** The gate existed in the
   deer-flow patch but nothing armed it. Now proven live by discrimination - without a
   token the API returns `403 setup_token_required`, with the log-printed token it
   returns `409 system_already_initialized` (i.e. it passed the token check).
3. **No compose declared a healthcheck.** Seven added per file, chosen against a measured
   inventory of what each image actually has, and each verified verbatim against its
   container under **both** `pwsh` 7 and Windows PowerShell 5.1.

**Neither fix needed an image rebuild.** One is a compose `environment:` entry, the other
is compose only. That is why 0.1.31 can be frozen rather than superseded — the answer to
"we keep building instead of shipping".

### What is still NOT done, stated plainly

- **No client AIPC has been updated.** Everything above is proven on the dev box. The
  highest proof that exists for the install *path* is clean-clone run 4 at 0.1.30, and the
  update path is now rehearsed once at 0.1.31 on this machine.
- **37 documents on THIS box needed remediation and got it.** On AIPC 1 and AIPC 2 the
  same class of rows almost certainly exists, because the defect shipped in v0.1.18
  through v0.1.30 and those machines ran within that range. That pass needs the admin
  password and must be run per machine.
- **The qm sandbox digest is pinned, so a repo update does not rebuild it.** Deliberate,
  but it means qm keeps running old skills until someone repins.
- **`test-update-end-to-end.ps1` cannot run under PowerShell 5.1** — it uses
  `ProcessStartInfo.ArgumentList`, absent on .NET Framework. Pre-existing; the gate
  verifying the update path cannot itself run on client hardware.

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
| **v0.1.31** | **NOT PROVEN by clean clone** | carries the sanitizer fix; the fix itself is proven against the published image (see §0) |

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

### 🔴 BLOCKING - sanitized chunks kept their RAW text, so chat was served raw PII

**Root-caused, FIXED in code, and PROVEN end to end on a local build - but the fix is
not in 0.1.30.** Read `DEFECT-sanitized-content-not-served.md` for the evidence.

Measured on the live 0.1.30 stack, three ways:

1. `GET /api/documents/:id/download` serves the original bytes with the raw identifiers,
   on all seven formats.
2. **25 rows in `kb_chunks` were labelled `sanitized` while holding the raw ID card and
   phone number** - and the RAG gate is
   `WHERE sanitization_state IN ('sanitized','never')`, so the label was the *selection
   key* for serving them.
3. Reachable through the product's own API: a same-tenant user's `kb_search` returned
   `content=['11010519491231002X\n13812345678']`.

**An earlier version of this document recorded this as a product decision. That was
wrong and is retracted.** The design spec
(`docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md`) is explicit that
`sanitized` means the chunk *content* is redacted - chat runs "over already-sanitized
chunks, so its inputs are already clean" - and `restore` takes the sanitized text and
un-redacts it, which presupposes the placeholder rendering is what was stored. There was
never a reading under which serving raw PII to the agent's own retrieval lane was
intended.

**What is fixed:** the promote step now *replaces* the chunk text with the job's redacted
rendering (`ChunkIngestor::reingest_sanitized_chunks`) instead of flipping a flag, so a
`sanitized` row is redacted by construction.

**Proof, A/B, same fixture and same gate.** `test-sanitizer-e2e.ps1` was run against the
published 0.1.30 image and against a local build carrying the fix:

| image | result |
|---|---|
| `ghcr.io/jzkk720/pacgate-api:0.1.30` | **FAIL (4)** - the four content assertions |
| local build with the fix | **PASS** - all 22 assertions |

The decisive comparison is at the database level, two documents created 45 seconds
apart by those two runs:

```
doc 0290b895 (fixed)   sanitized   00000000000000000X \n [CN_MOBILE_0D9D26FB_2]
doc 56b5ca5f (0.1.30)  sanitized   11010519491231002X \n 13812345678
```

Both rows claim `sanitized`. Only one of them is telling the truth, and the old gate's
`chunk_states -eq 'sanitized'` assertion passes on both - which is exactly why the
defect shipped.

**Remediation of already-poisoned rows is proven too.** Re-running the sanitize job on a
real historical document with the fixed build: `1` raw hit before, `0` after, **and the
document kept a chunk** carrying real placeholders. An earlier version of the fix could
not do this at all - it selected only `pending` rows, so the job returned
`chunks_promoted=0` and the leak survived the repair attempt.

**What is NOT fixed by any image upgrade:** rows already mislabelled on 0.1.28..0.1.30.
No version bump rewrites them. Each affected machine needs
`scripts/audit-sanitized-chunk-egress.ps1` (read-only, names the documents) and then a
per-document choice: re-sanitize (proven, preserves coverage), or delete the rows
removes the leak but loses RAG coverage until re-sanitized. Neither option works on
0.1.30 or earlier, where re-running the job is a no-op.

**Download is a separate, still-open question.** Serving the matter's original is a real
export-policy decision - a redacted `.docx` is not the executed contract - and it is
narrower than the above, because download is an export while RAG is what the agent quotes.
It is no longer concealable behind "the analysis lane is protected", because that lane is
what was broken.

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

**0.1.31 is the frozen release. Ship it, then run one remediation pass per machine.**

The earlier version of this section offered a choice between deploying 0.1.30 now and
holding for the fix. That choice is gone: 0.1.31 carries the fix, is published, and is
proven on the published artifact. There is no reason to deploy a version that is known to
be wrong on a CRITICAL item.

### The deployment, in order

**On the dev machine (done, as the rehearsal):**

```powershell
# 1. Update. Pulls 0.1.31, re-renders config, restarts the bind-mounted services.
cd C:\pacgate-ai-pr\deploy\client-bundle
.\install.ps1 -Update

# 2. Confirm the running binary, not the compose pin.
curl.exe -s http://localhost:8089/version      # {"version":"0.1.31","revision":"9d3193666bb2"}

# 3. Count the damage BEFORE repairing anything - this is read-only.
.\..\..\scripts\audit-sanitized-chunk-egress.ps1

# 4. Repair. Re-runs the sanitize job per affected document.
.\..\..\scripts\remediate-sanitized-chunk-egress.ps1 -WhatIf   # see the list first
.\..\..\scripts\remediate-sanitized-chunk-egress.ps1

# 5. Prove it. Must end "no raw Tier-1 match found in a sanitized chunk", exit 0.
.\..\..\scripts\audit-sanitized-chunk-egress.ps1
```

**On AIPC 1 and AIPC 2:** the same five steps. The only difference is that step 3 will
report a number that is not zero, because those machines ran a release in the
v0.1.18..v0.1.30 window. Expect it; it is not a new fault, and step 4 is the fix.

Two ordering constraints that matter:

- **Step 4 needs 0.1.31 or later running.** On 0.1.30 and earlier the sanitize job has no
  rewrite path at all, so re-running it changes nothing and the audit will still report
  the same count. Update first, repair second.
- **Step 5 is not optional.** Step 4 reports what it did; step 5 measures what is true. On
  this machine those two disagreed twice, both times because of a defect in the audit
  rather than in the repair, and the disagreement is what exposed it.

### What "100%" means now

The engineering is done: fix present in the published image, gate armed by default,
healthchecks in place, update path exercised live, this machine's data clean and verified.

What is left is not engineering:

- **Scheduling the window.** `-Update` restarts deer-flow and the frontend, so a lawyer
  mid-run loses that run. It is a few minutes, but it needs to be chosen, not assumed.
- **Having the admin password to hand** for step 4. It logs in as `PACGATE_API_EMAIL` from
  the bundle `.env`; without it the script exits 2 and says so rather than half-working.
- **Accepting that step 4 re-embeds each repaired document.** Cost is proportional to
  document size, not to how much leaked. On this box, 37 documents was quick; on a busier
  machine, allow for it.

Everything else on the earlier list - duplicate documents, the qm-sandbox repin, the
cloud `reasoning` trap, the PS 5.1 harness defects - is quality work that can follow
without holding the deploy. None of it is a reason a client's compliance review would
reject the machine.

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
| "chunks sanitized" | it read the **state column** - the one thing a flag flip does set |

One more, found while red-checking the fix above and worth its own line because it defeated
the *runner* rather than a single assertion:

| the defect | why nothing caught it |
| --- | --- |
| a `docker inspect --format '{{...}}{{"\n"}}{{end}}'` probe returns the network under PowerShell 7 but an **empty string** under 5.1 | the gate then exited 2 "SKIP: the stack is not running" and its 20+ assertions never ran. `run-all-checks.ps1` falls back to `powershell.exe` when `pwsh` is absent - the client AIPC arrangement - so this only ever worked on a developer box. The same idiom appears in `test-version-marker-against-image.ps1` |

The gates added for each now assert the property, and each was red-checked by
reintroducing the defect. The remaining structural gap is that **no gate measures a
failure RATE** - the 1-in-3 defects passed a single-run suite two times in three. The
`-FailureRateRuns` soak exists for that and belongs in the release checklist.
