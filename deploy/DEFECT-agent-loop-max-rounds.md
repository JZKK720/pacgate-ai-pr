# DEFECT: the agent round cap returned HTTP 500 for work that had succeeded

**Severity: HIGH.** It produced the exact symptom the user reported - *"the model
generated fine - but my HTTP request got 500"* - on the single route that produces
client deliverables.

**Found:** 2026-10-13, while building `scripts/test-document-generation-e2e.ps1`.
**Status:** root-caused, fixed, unit-tested, proven live, and **shipped in 0.1.29**
(revision `672194d1d78c`, all 5 images PUBLIC). Before that it was present in every
0.1.28 and earlier deployment.

## Symptom

`POST /api/workflows/:id/execute` intermittently answered:

```json
{"error":{"code":"internal_error","message":"LLM error: agent loop exceeded max_rounds=10"}}
```

on **1 run in 3** (measured; 3 of 8 in a later sample). The document the workflow
was asked to produce had already been written to disk.

## The log that makes it unambiguous

```
13:19:32.505452Z  INFO workflow_executor: workflow execution complete
                        workflow=项目概况表编制 steps_completed=1 has_output=true
13:19:32.784905Z ERROR tower_http::trace::on_failure: response failed
                        classification=Status code: 500 Internal Server Error latency=0 ms
```

`has_output=true`, then a 500 **276 ms later**, with `latency=0 ms` - the handler
reported success and the failure came from mapping the error afterwards. The other
class of 500 in the same logs carries `latency=74066 ms` / `88519 ms`, i.e. the whole
~85 s generation, then the 500. In both shapes the work was done and discarded.

## Root cause

`AgentLoop` caps the tool-call rounds to stop a runaway loop:

```rust
// crates/pacgate-agent/src/lib.rs
pub max_rounds: u32,          // = 10

for round in 0..self.max_rounds {
    let (content, tool_calls) = llm.complete(...).await?;
    if tool_calls.is_empty() { return Ok(AgentTurnResult { ... }); }   // closed normally
    ...execute each tool...
}

// ── the defect ──
Err(PacgateError::LlmError(format!(
    "agent loop exceeded max_rounds={}", self.max_rounds
)))
```

Reaching the cap is **not** a failure of the turn. By then the tools have run and
their side effects are committed - `generate_docx` has written the file. What is
missing is only the model's *closing summary*. The `Err` discarded the entire
`AgentTurnResult`, and `WorkflowExecutor` propagates with `?`
(`workflow_executor.rs`, `.run_with_router(...).await?`), so one step hitting the cap
aborted the whole workflow and the API mapped it to `internal_error` -> HTTP 500.

## Why the model hits the cap on a routine task

It is not the model being lazy; the task invites iteration. Measured
`tools_used` for a *single* step of a **one-step** workflow:

```
run A: list_documents, generate_docx, read_document
run B: list_documents, generate_docx, generate_docx, generate_docx,
       read_document, read_document, read_document
```

Run B is 7 tool calls in one step. The loop allows 10. The model reads the document
back to verify it, decides something is missing, regenerates - and a
"generate, verify, improve" loop burns rounds by design. A model that iterates (the
better answer) is *more* likely to be punished than one that answers immediately.

## Fix

`AgentTurnResult` carries a `max_rounds_reached: bool` instead of the loop returning
`Err`. At the cap the turn is returned **with what it produced**:

- `content: None` (there genuinely is no closing message)
- `citations: []`
- `tool_calls_made` still lists every dispatched tool
- `max_rounds_reached: true`

The flag propagates through `StepResult` -> `ExecuteStepResult`, so it is **serialized
in the API response** on every step. `WorkflowExecutor` logs a `warn!` at the step
that hit it.

The flag is deliberately not swallowed at the API boundary: a client can now say
*"the document was created, but the summary was truncated"* instead of showing a
bare success, and this state is never again mistaken for a failed generation.

## Verification

**Unit (red-checked).** `crates/pacgate-agent/src/lib.rs` drives a **real**
`AgentLoop` against a **real** local HTTP server that always answers with a tool
call, so the actual loop, the actual OpenAI-compatible parse, and the actual cap are
exercised. Restoring the old `Err` makes the test fail with:

```
hitting the round cap must NOT be an error - the turn's tools already ran and its
side effects are committed; discarding them is the reported defect:
LlmError("agent loop exceeded max_rounds=3")
```

A companion test asserts the converse - a normal turn reports
`max_rounds_reached=false` - because a flag that is always `true` carries no
information. Workspace: **all tests pass**.

**Live, against a rebuilt image** (`pacgate-api:maxrounds-test`, built from the
same commit):

| | before | after |
| --- | --- | --- |
| 8 consecutive `execute` runs | 3 of 8 returned 500 | **8 of 8 returned 200** |
| `max_rounds_reached` on the response | field did not exist | present on every step |

Run 6 of those 8 reported `max_rounds_reached=true` **and still returned 200** - so
the cap really did fire during the proof, and the run that would previously have
been a 500 was delivered instead.

**End to end.** `scripts/test-document-generation-e2e.ps1`: **19/19 PASS**, including
a real .docx read back off disk with correct Chinese text.

**On the PUBLISHED 0.1.29 images** (not a local build), the final proof:

| | before (0.1.28 and earlier) | after (0.1.29, revision 672194d) |
| --- | --- | --- |
| 8 consecutive `execute` runs | 3 of 8 returned 500 | 8 of 8 returned 200 |
| 6 consecutive `execute` runs | - | **6 of 6 returned 200** |
| `max_rounds_reached` on the response | field did not exist | present on every step |
| runs in which the cap FIRED and were still delivered | 0 (each was a 500) | **2 of those 6** |

The last row is the one that matters: the cap firing is not a rare event - it
happened in a third of the proof runs - and every one of those is a request that
0.1.28 answered with a 500 while the document sat on disk.

Confirmed in the published binary itself:

```
max_rounds_reached symbol : 1
"agent loop exceeded max_rounds" string : 0
```

**Full suite against the published 0.1.29: ALL 37 GATES PASSED** (7 live-stack).

## Residual

- **`max_rounds` is left at 10.** A higher cap would reduce how often the flag is
  set, but it treats the symptom: the number was never the defect, the `Err` was.
- **The flag is not yet surfaced in any client UI.** The frontend shows the run's
  assistant message; a truncated run has no closing message, so a user could still
  see "no answer" with a 200. The API now makes the state observable; consuming it
  is a frontend change, not made here.
- **`content: None` on a capped step means `final_content` can be `null`** for a
  single-step workflow. That is now an honest `null` (the document exists, the
  narration does not) rather than an error - but a caller that requires prose must
  read `max_rounds_reached` to tell "nothing happened" from "the tools ran".
- The live proof used a locally built image, not a published tag. Reaching clients
  needs the normal release path.

---

# 2026-10-14: the fix was incomplete — it turned a loud 500 into a silent blank

The section above shipped in 0.1.29. **Measuring it afterwards changed the
conclusion**, and this is recorded here rather than quietly patched.

## The measurement that broke it

Driving `POST /api/workflows/:id/execute` repeatedly on the shipped 0.1.29:

| metric | 0.1.29 | |
| --- | --- | --- |
| HTTP 200 delivered | 8 / 8 | the 500 was genuinely gone |
| document row exists | 7 / 8 | |
| **`content: EMPTY` (no reply)** | **5 / 8** | **62%** |
| round cap fired | 5 / 8 | |
| tool calls per run | 3, **10, 1, 10, 10, 10**, 7, **10** | |

A single step's `tools_used`, verbatim:

```
list_documents, generate_docx, generate_docx, generate_docx, generate_docx,
generate_docx, generate_docx, generate_docx, read_document, generate_docx
```

**Nine `generate_docx` calls.** Each one SUCCEEDS - it really does write another
document - so nothing errors, the loop never converges, and `generate_docx` is still
the tool in flight when the cap stops it. The result is HTTP 200 with
`"content": null` and `"final_content": null`.

That is worse than what it replaced. A 500 tells the caller something is wrong. A
200 with a blank answer tells them nothing, and the client UI renders it as "no
response" with no error to report.

The root cause of the *original* defect was still correctly identified (returning
`Err` discarded committed work). The mistake was treating "do not error" as the whole
fix. Not erroring is not the same as answering.

## Two further changes

**1. A forced final-answer pass.** When the loop stops without a natural close
(cap reached, or the new loop-break below), the model is asked once more **with the
tools withheld**, so it cannot call another tool and must answer in text. A failure
there is non-fatal: the turn's work is already done and its tool log is intact.

**2. Runaway-regeneration detection.** Before dispatching a round, the calls are
compared with the previous round's. A repeated identical `tool + arguments` is not
progress, so the loop breaks and goes straight to the forced-answer pass. Two
consecutive identical rounds is the threshold: a legitimate workflow does not call an
identical tool-with-arguments twice in a row.

Raising `max_rounds` was considered and rejected - it buys more duplicate documents,
not an answer.

## Verified

Unit (red-checked): with the detector disabled the loop burns all **50** rounds and
the test fails with `identical calls must stop the loop early, not consume the whole
cap; made 50 calls`. Two new tests pin both halves - a repeated identical call stops
the loop, and distinct calls are **not** mistaken for one (or the detector would just
be counting rounds). Agent suite 9/9; full workspace green.

Live, on a rebuilt image:

| metric | 0.1.29 as shipped | after the loop fix |
| --- | --- | --- |
| HTTP 200 | 8 / 8 | 22 / 22 |
| **`content: EMPTY`** | **5 / 8 (62%)** | **0 / 22** |
| document row exists | 7 / 8 | 21 / 22 |
| round cap fired | 5 / 8 | 10 / 22 |

The empty-answer class is gone across 22 consecutive runs.

## Residual, still open

- **Duplicate documents are NOT prevented.** The model can still call `generate_docx`
  several times with *different* arguments before converging; runs produced up to 4
  rows. Loop detection keys on an **identical** `tool + arguments` pair, so a
  varying-argument loop is untouched. A user can therefore still be shown a matter
  containing several near-identical documents. Fixing this means deciding whether
  repeated generation is a legitimate iteration or a mistake, which is a product
  decision about how workflows should behave - not a code change to make silently.
- **One 500 was observed in an earlier 10-run sample** and its body was not captured
  (the probe discarded non-200 bodies at the time). It did not reproduce in the
  following 22 runs, so it is recorded as unexplained rather than fixed. The probe now
  prints the body for any non-200.
- **`content` can be non-null while the document row count is 0** (runs 1, 4, 11 in the
  12-run sample): the model narrated a document it did not manage to create. The
  answer is confident and wrong. Nothing in the API currently distinguishes that.

---

# 2026-10-14 (later): two more findings from the format audit

## A third failure shape: the intermittent 500 that will not reproduce

`test-format-coverage-e2e.ps1` hit a **HTTP 500 on `POST /api/documents/:id/extract`
for an `.xlsx`**. It then did not reproduce:

| attempt | result |
| --- | --- |
| the original run | **500** |
| a single targeted retry | 200, correct text |
| 12 consecutive runs of the same fixture through upload -> extract | **12 x 200, 0 failures** |

The log signature was `response failed classification=Status code: 500 latency=1-3 ms`
- i.e. the failure happened **before any extraction work**, so it is not a slow path,
a timeout, or a PaddleOCR problem. No panic, no `ERROR` beyond the tower_http
classification line, and the error body was not captured because the gate's helper
discarded non-200 bodies at that moment.

Recorded as **reproduced once, not diagnosed**, which is the honest status. The gate now
captures the body of every non-200 so the next occurrence is diagnosable instead of
anecdotal. A 1-in-13 failure is also the same class as the round-cap defect: a
single-run assertion passes a broken build most of the time, which is why
`test-document-generation-e2e.ps1` grew its `-FailureRateRuns` soak.

## Document versions are counted per STEM, not per document

Not a crash, but a real design detail the format gate exposed and worth writing down.

`latest_version` is keyed on `(matter_id, name)` where **`name` is the extension-less
stem**, while `rel_path` also carries the format:

```rust
let version = self.latest_version(matter_id, stem).await?;   // stem only
let rel_path = Self::rel_path(&tenant_id, matter_id, stem, version, format);
```

So `report.docx` and `report.xlsx` uploaded into the same matter share one version
counter: the second gets `version = 2` even though it is not a second version of the
first. Uploading `report.docx` again then produces `version = 3`, making the docx
versions non-contiguous (1, 3) and leaving `version = 2` pointing at a different format.

Consequences:

- **Nothing errors.** Each row keeps its own format, so retrieval by
  `(matter, stem, version)` still resolves, and `list_versions` works.
- **But "version" reads as "revision of this document" and is not.** A user asking for
  version 2 of `report.docx` is asking for a number that was assigned to a spreadsheet.
- A test fixture using the same stem for several formats (which is exactly what the
  format gate did) sees versions 1..N across unrelated files, which looks alarming and
  is not - a false alarm this note exists to prevent someone re-investigating.

**Not changed.** Making the counter per `(stem, format)` is a one-line key change but it
alters the numbering of existing rows' meaning, so it needs a migration decision rather
than a silent edit.
- The **client-side rollout is not yet exercised**: no clean clone has been taken and
  upgraded through `install.ps1 -Update` to 0.1.29. The dev box was upgraded and is
  green, but a fresh-clone proof is the only valid test for install-path changes and
  that has not been run for this release.
