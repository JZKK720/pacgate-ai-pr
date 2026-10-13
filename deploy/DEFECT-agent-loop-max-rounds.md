# DEFECT: the agent round cap returned HTTP 500 for work that had succeeded

**Severity: HIGH.** It produced the exact symptom the user reported - *"the model
generated fine - but my HTTP request got 500"* - on the single route that produces
client deliverables.

**Found:** 2026-10-13, while building `scripts/test-document-generation-e2e.ps1`.
**Status:** root-caused, fixed, unit-tested, proven live. Awaiting the next image
build to reach clients (the fix is Rust, so it needs an image).

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

## Residual

- **`max_rounds` is left at 10.** A higher cap would reduce how often the flag is
  set, but it treats the symptom: the number was never the defect, the `Err` was.
  Raising it is now a tuning decision that can be made from the flag's frequency
  rather than blind.
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
