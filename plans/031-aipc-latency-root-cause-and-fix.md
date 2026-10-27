# Plan 031 - AIPC #1 latency: re-verified root causes and the fix set

**Date:** 2026-10-26
**Priority:** P0
**Effort:** ~1 day (two bind-mount patches, one Rust change, three gates)
**Depends on:** nothing - 0.2.6 is running and the stack is healthy
**Status:** **F1 + F2 IMPLEMENTED AND VERIFIED (2026-10-26).** F3-F6 remain open.
Every number below was measured on this machine on 2026-10-26. Nothing is taken
from the AIPC #1 audit.

**Verified result of F1 + F2:** the memory lane's prompt prefix is now stable, so
consecutive updates hit the cache. Measured at production scale (35 k-token
conversation, memory block changing between calls):

| | Before | After |
| --- | --- | --- |
| update #1 (cold) | 77.7 s | 68.9 s |
| update #2 (memory changed) | **68.7 s** | **1.3 s** |
| update #3 (memory changed) | **68.7 s** | **1.2 s** |

That is a **~53x** reduction on every memory update after the first, and it
removes the cache eviction that was costing the chat lane its warm prefix.

---

## 0. Why this plan exists

AIPC #1 filed a 1145-line audit naming five root causes for slow chat. Acting on
it as written would have shipped three fixes for defects that do not exist here,
and skipped the two that do.

The audit is not dishonest - it is **unreproducible**. Its cited run IDs
(`2973e30d`, `2f4c00f5`) do not appear anywhere in this machine's 96-hour log, and
its headline run (162.6 minutes, 70 calls, 2,517,526 input tokens) has no
counterpart here. The longest run measured on this box is 561 s. So the audit
describes a real experience on a machine we cannot see, and diagnoses it with a
mechanism that this machine's evidence contradicts.

This plan does three things:

1. Separates the audit's claims into CONFIRMED / FALSIFIED / CORRECTED, each with
   the measurement that decides it.
2. Replaces the falsified mechanism with the one the evidence supports.
3. Orders the fixes by measured return, and records the rejected fixes so they are
   not re-proposed.

---

## 1. Ground truth at the time of writing

| Fact | Value | How verified |
| --- | --- | --- |
| Branch / HEAD | `main` @ `337fb9d` | `git log`, clean tree, in sync with `origin/main` |
| Stack | 8/8 containers healthy, all `0.2.6` | `docker ps -a` |
| Host | 61.6 GiB RAM, 30.7 GiB free | `Get-CimInstance Win32_OperatingSystem` |
| Ollama | 0.40.11, `n_slots = 1`, `n_ctx_slot = 65536` | `server.log` |
| Resident model | `gemma4:12b-it-qat`, 8.8 GB, 100% GPU, ctx 65536 | `ollama ps` |
| LLM calls, 96 h | **315** | `deer-flow` log, `LLM token usage:` lines |
| Cold calls (`cache_read=0`) | **10 (3.2%)** | same |
| Cold calls with input > 20 k | **5** | same |
| Prompt cache ceiling | **8192 MiB** (reached 6671 MiB at 4 prompts / 172 k tokens) | `server.log` `cache state:` |
| Per-prompt cache cost | ~24.8 MiB per 1 k tokens | 35 008 tok -> 867 MiB; 36 936 tok -> 898 MiB |
| Warm decode, 35 k prompt | **25.3 tok/s** | direct `/v1/chat/completions` probe |
| Cold prefill, 35 k prompt | **~70 s** (460-467 tok/s) | same |
| Memory updates, 96 h | **20** (15 success, 5 parse-fail) | `deer-flow` log |
| Memory-lane LLM time | **1 756 s** total, median ~85 s | same |
| Memory updates overlapping a user run | **5 of 20** | timestamp intersection |
| `MatterMemoryOutOfScope` (422) | **0** | `deer-flow` log |
| Document 409s | **0** | `deer-flow` log |
| Documents `pending` | **24** (19 in matter `8f963544-…`, 14 older than 24 h) | `pacgate-db` |
| Documents `sanitized` | 26 | same |
| MCP transports, 2 h | 240 created / 240 deleted | `pacgate-mcp` log |
| Sandbox commands, 96 h | **220** (142 ad-hoc shell/python) | `[SandboxAudit]` events |
| Deferred-tool promotions, 96 h | **1** | `deferred_tool_filter_middleware` |

---

## 2. Verdict on the audit's claims

| # | Audit claim | Verdict | Deciding measurement |
| --- | --- | --- | --- |
| 1 | KV cache never hits; the prefix is rewritten every turn | **FALSIFIED** | 315 calls, 10 cold (3.2 %). Only 5 cold calls exceeded 20 k input in 96 h. |
| 2 | `DynamicContextMiddleware` rewrites the first `HumanMessage` every turn | **FALSIFIED** | 5 injections across 5 threads in 96 h - once per thread, then `return None`. |
| 3 | Tool results / schemas are written at the front and invalidate the prefix | **FALSIFIED** | Adding 1 tool, then 2, then removing all: each change cost one cold prefill, then cached normally (70.1 s -> 0.9 s). |
| 4 | Only one runner slot, so all lanes queue | **CONFIRMED, not dominant** | `n_slots = 1` is real. But 15 of 20 memory updates never overlapped a user run, so queueing cannot explain the long runs. |
| 5 | Memory lane always fails 422 and burns 60 s per turn | **FALSIFIED** | 0 `MatterMemoryOutOfScope` in 96 h; 15 of 20 memory updates succeeded. The 40 "422" log matches are `POST /api/v1/auth/login/local`. |
| 6 | 157 documents stuck pending, agent hits 409 | **CORRECTED** | 24 pending (not 157), 19 in the deployment's own matter, 0 409s in the window. |
| 7 | MCP rebuilds a session every 30 s | **CONFIRMED, benign** | 240 created / 240 deleted over 2 h - that is the healthcheck, balanced, 62.85 MiB RSS. |

**Net:** two of five causes falsified, one corrected, two confirmed but neither
dominant. The audit's recommended fix #3 (`num_ctx: 32768` to reduce prefill) is
also wrong - see section 5.

---

## 3. The replacement root causes

### RC-1 - The long runs are decode-bound, not prefill-bound

The three worst runs on this machine:

| Wall | Calls | Input tok | Output tok | Cold calls | Output/call |
| --- | --- | --- | --- | --- | --- |
| 561 s | 56 | 1 655 171 | **40 781** | 1 | 728 |
| 427 s | 64 | 1 722 854 | **48 227** | 0 | 754 |
| 379 s | 76 | 1 725 802 | **30 397** | 1 | 400 |

At the measured 25.3 tok/s warm decode, 40 781 output tokens is **1 611 s of pure
generation**. The 561 s wall time is *less* than the decode floor, which means the
run was not blocked on prefill at all - it was generating, and the cache was
already warm (0-1 cold calls).

This is the single most important correction to the audit. A cache-miss theory
cannot explain a run with zero cache misses.

### RC-2 - The agent does not use the MCP tools

220 sandbox commands in 96 h, categorised:

| Category | Count |
| --- | --- |
| Ad-hoc shell / python (file editing, PDF page counting, docx unzipping, nginx config grepping) | 142 |
| PDF render (`pandoc` / `weasyprint`) | 33 |
| `ls` / shell listing | 16 |
| Python HTTP probe (`urllib` / `requests`) against `pacgate-api` | 16 |
| nginx config grep | 6 |
| Source-file read via python | 6 |
| `openapi.json` introspection | 1 |

Only **one** deferred-tool promotion fired in 96 h. The agent reverse-engineers the
platform through `bash` instead of calling `pacgate_*`. Every probe is a full LLM
turn at ~25 k input tokens, and several runs spent 10+ consecutive turns probing
`/openapi.json`, `nginx.conf`, and raw JSON-RPC against `pacgate-mcp:8000/mcp`.

This is the largest **step-count** lever. It is not a cache problem and the audit
does not mention it.

### RC-3 - The memory lane is a 25 % wasted-prefill tax

20 memory updates in 96 h, 1 756 s of LLM time. Five of them (25 %) failed with:

```
Failed to parse LLM response for memory update:
No valid memory update JSON object found: line 1 column 1 (char 0)
```

That is an empty response body - the full prefill was paid and the result thrown
away. `reasoning_effort: none` is correctly wired and does work (measured: 9.6 s,
70 tokens, 0 reasoning chars), so this is the model returning prose instead of
JSON, not a reasoning burn.

### RC-4 - The memory prompt prefix is unstable by construction

`MEMORY_UPDATE_PROMPT` places `{current_memory}` **before** `{conversation}`:

```
Current Memory State:
<current_memory>
{current_memory}
</current_memory>

New Conversation to Process:
<conversation>
{conversation}
</conversation>
```

`current_memory` changes on every successful update. So the prefix changes on every
update, and llama.cpp can never reuse it. Measured directly, holding the 35 k
conversation constant and changing only the memory block:

| Prompt | Wall | Cached |
| --- | --- | --- |
| memory update #1 (cold) | 77.7 s | 0 |
| memory update #2 (memory changed) | **68.7 s** | **0** |
| memory update #3 (memory changed) | **68.7 s** | **0** |
| memory update #3 again (identical) | **0.5 s** | 35 028 |

Three consecutive updates, three full cold prefills. The identical re-run is 137x
faster. This is the mechanism the audit was reaching for - it is real, but it is
confined to the memory lane, not the chat lane.

### RC-5 - The prompt cache is memory-bound, not token-bound

The log line reads `limits: 8192.000 MiB, 65536 tokens`, which invites the reading
that 65 536 tokens is the ceiling. It is not. The cache reached:

```
cache state: 4 prompts, 6671.516 MiB (limits: 8192.000 MiB, 65536 tokens, 172082 est)
```

**172 082 tokens held at 6 671 MiB.** The binding constraint is the 8 192 MiB RAM
budget, at ~24.8 MiB per 1 k tokens. Raising the token ceiling would buy nothing;
the cache already holds 2.6x more tokens than the nominal limit.

### RC-6 - 24 documents are permanently pending

| State | Count |
| --- | --- |
| `sanitized` | 26 |
| `pending` | **24** |

19 of the 24 belong to matter `8f963544-4408-47c7-9817-d95c89e0d140`, which is this
deployment's own `PACGATE_MATTER_ID`. 14 are older than 24 hours.

There is **no background worker** in `pacgate-api` - grep for
`tokio::spawn|interval|sweep|worker` across `main.rs` and `lib.rs` returns nothing -
and `upload_document` never calls sanitize. A document stays `pending` until
someone calls `POST /api/documents/:id/sanitize`. The download gate in
`documents.rs:206-238` then refuses it with 409. The agent has not hit that wall in
this window, but the trap is armed and permanent.

---

## 4. Fixes, ordered by measured return

### F1 - Bound the memory lane's input (P0, highest ROI) - **DONE**

`format_conversation_for_update` (`deerflow/agents/memory/prompt.py:442`) truncated
each message to 1 000 chars but capped **neither message count nor total size**.
`filter_messages_for_memory` keeps every human message and every final AI message.
So the memory prompt grew with the conversation and reached chat-sized (~35 k).

**Change:** `MEMORY_CONVERSATION_MAX_CHARS = 16000` and
`MEMORY_CONVERSATION_MAX_MESSAGES = 40`. Keeps the most recent turns, then trims
from the front so the newest context survives.

**Effect:** memory prompt 35 k -> ~4 k tokens. Its prefill drops ~9x, it stops
evicting the chat lane's cache entry, and it stops competing for the 8 GiB budget.

**Surface:** `deploy/client-bundle/patches/deer-flow-memory-prompt.py`, mounted in
both `compose.bundle.yaml` and `compose.prod.yaml`. No image rebuild.

### F2 - Stabilize the memory prompt prefix (P0) - **DONE**

**Change:** moved `{current_memory}` **after** `{conversation}` in
`MEMORY_UPDATE_PROMPT`. The conversation is append-only within a thread, so it
becomes the stable prefix; the volatile memory block moves to the tail where a
prefix cache does not care about it.

**Effect:** measured 68.7 s -> 1.3 s per memory update once the conversation prefix
is warm (see the table at the top). Combined with F1 this is the single biggest
latency win in the plan.

**Surface:** same patch as F1.

### F3 - Stop paying for the 25 % parse failure (P1)

Five of twenty updates returned empty content. Two options, in order of preference:

1. Add an explicit "respond with JSON only, no prose, no code fence" instruction and
   strip a leading ```` ```json ```` fence before parsing.
2. On parse failure, retry once with a stricter prompt. F1 and F2 make the retry
   cheap, so this is only worth doing after they land.

**Surface:** `deerflow/agents/memory/updater.py` (`_parse_memory_update_response`).

### F4 - Make the agent use the MCP tools (P1)

142 of 220 sandbox commands are ad-hoc shell. The deferral machinery works (1
promotion, 0 filtered-schema events), so this is a prompt/affordance problem, not a
middleware bug.

**Change:** strengthen the lead-agent system prompt to prefer `pacgate_*` tools over
`bash` for any pacgate-api interaction, and name the specific anti-patterns observed
(`/openapi.json` probing, raw JSON-RPC to `pacgate-mcp:8000/mcp`, reading
`nginx.conf` to find a body-size limit).

**Effect:** the largest step-count lever. 56-76 calls per run at ~25 k input each.

**Surface:** `deploy/client-bundle/patches/deer-flow-prompt.py`.

### F5 - Auto-sanitize on upload (P1)

**Change:** call the sanitize job from `upload_document`, or add a bounded background
sweep. Without it the 409 gate is a permanent trap and 24 documents are dead weight.

**Surface:** `pacgate-ai/crates/pacgate-api/src/documents.rs` (upload handler) or
`main.rs` (sweep). This one needs a Rust rebuild.

### F6 - Cap output tokens per step (P2)

The long runs are decode-bound at 30-48 k output tokens. The chat lane's
`max_tokens` is 8192 per call, but nothing bounds the number of calls. A step budget
would bound the tail.

**Surface:** `deploy/client-bundle/deer-flow-config.yaml`.

---

## 5. Rejected fixes - do not re-propose

| Rejected | Why |
| --- | --- |
| Lower `num_ctx` to 32768 to reduce prefill (audit fix #3) | **Measured no effect.** 46 663-token prompt: 460.5 tok/s at ctx 65536, 466.7 tok/s at ctx 131072. Prefill throughput is independent of context width. |
| Send `options.num_ctx` in the request body | **Ignored by Ollama 0.40.11.** Sending `num_ctx: 8192` still logged `n_ctx_slot = 65536`. Only `OLLAMA_CONTEXT_LENGTH` / the app's `db.sqlite` `context_length` controls it. |
| Raise `OLLAMA_CONTEXT_LENGTH` above 65536 | The cache is **memory-bound at 8 GiB**, not token-bound - it already holds 172 k tokens. Raising the token ceiling buys nothing and risks the host-memory budget. |
| Switch background lanes to `ornith-1.5:9b` | Would break the one-resident-model pin and add reload churn. F1 and F2 remove the need. |
| Fix per-turn prefix rewriting | The prefix is not rewritten per turn. 96.8 % cache hit rate. |
| Fix the memory 422 loop | 0 occurrences in 96 h. |
| Fix the MCP session leak | 240 created / 240 deleted - balanced. |

---

## 6. Gate plan

| Gate | Current coverage | Assertion to add |
| --- | --- | --- |
| `test-memory-lane.ps1` | memory lane round-trip | **two pre-existing bugs fixed** (see below) |
| `test-memory-bound.ps1` | memory size bound | unchanged |
| `test-ollama-context-scope.ps1` | context scope | unchanged |
| `test-host-memory-budget.ps1` | host RAM | unchanged |
| `test-summarization-treadmill.ps1` | trigger/keep | unchanged |
| **new** `test-memory-prompt-stability.ps1` | - | **DONE** - prefix order, input cap, cap actually applied, compose mount parity |
| **new** `test-document-sanitize-on-upload.ps1` | - | upload -> `sanitized` without an explicit sanitize call (F5) |

`test-memory-prompt-stability.ps1` was mutation-tested three ways before it counted,
per the precedent set in plan 030:

| Mutation | Result |
| --- | --- |
| Revert the template order | **FAIL** - "the memory block precedes the conversation block" |
| Declare the cap but never apply it | **FAIL** - "len=35778 cap=16000" |
| Drop the mount from `compose.prod.yaml` | **FAIL** - "mounts deer-flow-memory-storage.py but NOT deer-flow-memory-prompt.py" |

### Two pre-existing gate bugs found and fixed

`test-memory-lane.ps1` was failing on this machine **before** any change in this
plan (proven by stashing the working tree and re-running). Both bugs are in the
gate, not the product:

1. **Nested-quoting false negative.** The check ran
   `docker exec deer-flow sh -c 'grep -c "REFUSING to fall back" ...'`. From a
   PowerShell script the inner double quotes survive into the container's shell,
   which then searches for the literal string `"REFUSING` (with a quote) and
   returns `0` on a correctly patched file. Fixed by passing the pattern as a
   direct argv element, removing the second shell entirely.
2. **Native stderr promoted to a terminating error.** The probe imports
   `langgraph`, which emits a deprecation warning on stderr. Under
   `$ErrorActionPreference = 'Stop'`, PowerShell 5.1 promotes native stderr to a
   terminating error, so the gate died before reading the verdict it had just
   produced. Fixed by scoping the preference to `Continue` around that one call.

Both are the same class of defect plan 030 named: a gate that cannot see the
failure it exists to catch.

---

## 7. What the client-facing report must not repeat

If any of this plan is summarised for AIPC #1, the following audit claims must be
dropped or corrected:

- "KV cache never hits" - it hits 96.8 % of the time.
- "The prefix is rewritten every turn" - it is not.
- "Tool schemas invalidate the prefix every turn" - they invalidate it once per
  tool-set change.
- "The memory lane always fails 422" - it succeeded 15 of 20 times.
- "157 documents stuck pending" - 24, and 19 are in our own matter.
- "162.6 minutes / 70 calls / 2.5 M tokens" - not reproducible on this machine.
- "Lower `num_ctx` to speed up prefill" - measured to have no effect.

What the report **should** say: the long runs are decode-bound, the agent is
bypassing the MCP tools, and the memory lane pays a guaranteed cold prefill because
its prompt puts the volatile memory block in front of the stable conversation.

---

## 8. Execution order

1. ~~F1 + F2 as one patch~~ - **DONE.** Verified live: 68.9 s -> 1.3 s -> 1.2 s at
   35 k tokens with the memory block changing between calls.
2. ~~`test-memory-prompt-stability.ps1` + mutation tests~~ - **DONE.** Three
   mutations, three catches. Registered in `run-all-checks.ps1`.
3. F3 (parse hardening) - open.
4. F4 (prompt). Verify by counting sandbox commands per run before/after - open.
5. F5 (Rust rebuild + gate) - open.
6. F6 (config) - open.

Steps 1-4 need no image rebuild. Step 5 does.

### Files changed by F1 + F2

| File | Change |
| --- | --- |
| `deploy/client-bundle/patches/deer-flow-memory-prompt.py` | **new** - patched `prompt.py` (template order + input cap) |
| `deploy/client-bundle/compose.bundle.yaml` | mount the new patch |
| `deploy/client-bundle/compose.prod.yaml` | mount the new patch |
| `scripts/test-memory-prompt-stability.ps1` | **new** gate |
| `scripts/run-all-checks.ps1` | register the gate |
| `scripts/test-memory-lane.ps1` | fix two pre-existing gate bugs |
| `plans/031-aipc-latency-root-cause-and-fix.md` | **new** - this plan |
| `plans/README.md` | index row |

### Rollback

Remove the two `deer-flow-memory-prompt.py` mount lines from the compose files and
recreate `deer-flow`. The patch is a bind mount, so the image is untouched and the
upstream `prompt.py` returns immediately.
