# Audit outcome - the three open items, after systematic debugging

**Date:** 2026-10-15 · **Host:** `PACGATE-AI02` · **Images:** 0.1.31 (`9d319366`)

Three items were left open at the end of the first audit. Each was taken back to
Phase 1 (root cause) rather than patched again.

---

## 1. Document generation - NOT a regression, and NOT fixable by prompting

**Status:** root cause is a MODEL BEHAVIOUR difference. No code changed.

### My original claim was wrong, and here is the error

I reported a "0.1.31 regression, 466 lines changed in the generation path". That
compared a gate PASS recorded in `REGRESSION-REPORT-2026-10-14-v0.1.29.md` on host
`LAPTOP-HH9V75MK` against a gate FAIL I measured on `PACGATE-AI02`. Two machines.

The report I was reading warns about exactly this, about this exact box, in its own
section 2: *"this lane cannot detect a 5x difference on this box, so it must not be
used to claim either an improvement or a regression."*

### Why the window was wrong

- `d86a2e84` (the passing gate, 18/18) sits **before v0.1.29**. Between it and the
  0.1.31 revision lie `e0190c52` and `349f0ac5` - but `e0190c52` is inside
  v0.1.29, which **PASSED 19/19 with 14 of 14 direct drives returning 200**. My
  window swallowed a working release.
- The true window is v0.1.29 -> v0.1.31, containing **one** commit touching this
  path: `349f0ac5`, first shipped in v0.1.30.
- Even that commit cannot explain it. The diff's first hunk (line 657) adds two
  loop-local variables; the first production change at or after the first
  `llm.complete` is line 677. Everything up to and including the call that chooses
  ROUND-0 tools - prompt, tools list, model - is byte-identical to v0.1.29.

### What the difference actually is

Measured directly against Ollama on this host, with the real tool set and the real
prompt:

| condition | tool_calls emitted |
| --- | --- |
| `gemma4:12b-it-qat` (the configured tier model), round 0 | `list_documents` |
| `qwen3.8:27b-mtp-q4_K_M`, round 0 | `list_documents`, `kb_search` |
| `gemma4:12b-it-qat`, round 1 (after `list_documents` -> `[]`) | `kb_search` |
| `gemma4:12b-it-qat` + explicit "call generate_docx now, do not ask" directive | **NONE** (no tool call at all) |

So: **neither model ever selects the `generate_docx` tool for this workflow.** The
model loops on read-only discovery tools and then narrates. That is the whole
symptom, and it is independent of the 0.1.29 -> 0.1.31 code delta.

### Why prompting is not the fix

The "B + explicit directive" row above is the falsification. Telling the model in
plain language to call the tool did not produce the call - it produced no tool call
at all. Workflow-level prompt text is not a lever here.

### The remaining structural defect (this one is real and is code)

`WorkflowStep.tool` is loaded from YAML, logged (`workflow_executor.rs:153`), and
copied into `StepResult.tool` (line 175) - but it is **never passed to the agent**.
`execute_with_router` calls `run_with_router(router, vec![], &user_message,
combined_prompt, matter_id)` and the declared tool appears in no argument. The
step's `system_prompt` DOES reach the model (as the system prompt, via
`compose_combined_prompt`), so this is not "the workflow text is missing" - it is
that a declared step tool is advisory text, not a constraint.

Whether to enforce it is a product decision: force the declared tool for a
single-tool step, or accept that the workflow library describes intent and the
model chooses.

### To settle the host question

Not done, and not doable safely from here: pre-`349f0ac5` is v0.1.28, which
predates a v0.1.29 DB change, so running the old image against this migrated DB
risks corrupting a working stack. The clean experiment is to run the gate on
`LAPTOP-HH9V75MK` - the host that recorded the PASS.

---

## 2. deer-flow skills - root cause found, fix CONFIRMED, durable fix blocked

**Status:** root cause proven and remediated live; the shipped fix needs a decision.

`SkillsConfig.get_skills_path()` resolves to `/app/backend/skills`. The layout
expects a **category level** beneath it - `get_skill_container_path()` builds
`"<container_path>/<category>/<skill_name>"` with category defaulting to `public`.
Nothing creates that tree, so `/api/skills` served **0 of 22**.

**Verified by experiment:** placing the 22 committed skills at
`/app/backend/skills/public` took the endpoint from **0 to 22**, via the running
deer-flow and an authenticated session.

**Why the fix is not simply a bind mount:** those skills live in
`deploy/client-bundle/deer-flow-src/`, which is **gitignored, with zero tracked
files** - a developer checkout, not part of the shipped bundle.
(`git check-ignore -v` -> `.gitignore:65`.) There is nothing in the repo for a
client AIPC to mount. The committed copy has to come from somewhere that ships.

Decision needed: vendor a tracked `skills/public` tree into the bundle and mount it
at `/app/backend/skills/public` (and at `container_path` for the sandbox view), or
accept that deer-flow ships without the public skill library.

---

## 3. test-model-picker-e2e.ps1 - FIXED and verified

**Status:** fixed and now passing in the full suite.

The gate reported `CANNOT CHECK (exit 2)` on every run against a healthy stack.
Exit 2 is the suite's "not a failure" carve-out, so it kept appearing in suite
output while asserting nothing. Two gate defects - the same pair that made
`run-benchmark.ps1` report `ERR 401` for a healthy deer-flow:

1. `-Password` was a hardcoded literal superseded by
   `deploy/client-bundle/.deer-flow-credentials` (which records a 2026-10-09
   rotation). Now resolved from that file, still overridable.
2. The login posted a JSON object to `/api/v1/auth/login/local`, which is an
   `OAuth2PasswordRequestForm` - it returns 422 even with a CORRECT password,
   which is why the symptom read as "stack down". Now form-encoded with the
   `Origin` header the CSRF gate expects.

**Measured:** `RESULT: 13 passed, 0 failed` (was `CANNOT CHECK`, exit 2);
roster of 7 entries; generation delivered in 30.1s, reply `PONG`. Confirmed
inside the full suite on the re-run.

---

## Suite delta after these changes

| | before | after |
| --- | --- | --- |
| `test-model-picker-e2e.ps1` | SKIP (CANNOT CHECK) | **PASS** 13/0 |
| `test-document-generation-e2e.ps1` | FAIL | FAIL (model behaviour, see 1) |
| `test-release-provenance.ps1` | FAIL | FAIL (local `deploy/pacgate-mcp/server.py`, disclosed) |

The suite gained one genuinely working gate; the two remaining failures are
unchanged and both are understood.
