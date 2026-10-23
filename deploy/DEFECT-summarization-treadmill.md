# DEFECT (HIGH): summarization treadmill - "42 steps and no report"

**Found:** 2026-10-23, from a live user report: a PDF was uploaded, extraction
and a brief report were requested, and after 42 steps the cloud model produced
no result and stopped responding.

**Status:** FIXED in `deploy/client-bundle/deer-flow-config.yaml`. Gated by
`scripts/test-summarization-treadmill.ps1`.

## The observation

Two runs on the live AIPC never terminated:

| thread | request | attachment | status | messages | LLM calls | lead-agent input tokens |
|---|---|---|---|---|---|---|
| `d46320fd` | 解析一下这份文档， 生成一份总结报告 | `deer-flow-openviking-pacgate-handbook.zh.pdf` (613 KB) | `interrupted` | 110 | 66 | **1,000,467** |
| `bb71ff66` | 解析一下这个文档的内容 | `Day_1_v3.pdf` (9.97 MB) | `running` (frozen) | - | - | - |

Both had `last_ai_message: None`. Decoding the LangGraph checkpoints showed the
step counter still incrementing - `d46320fd` reached **step 446**, `bb71ff66`
reached **step 133+** - while producing no new user-visible messages.

The report itself *was* produced
(`.../threads/d46320fd.../user-data/outputs/pacgate-handbook-report.pdf`,
912,762 bytes), but the run never emitted a closing message, so the user never
saw it. From the user's side the request simply hung.

## Root cause

`summarization.trigger` was **12000 tokens**, which is *below the unremovable
per-call token floor*.

`SummarizationMiddleware._should_summarize` fires on either of two conditions:

```python
if kind == "tokens" and total_tokens >= value:
    return True
if kind == "tokens" and self._should_summarize_based_on_reported_tokens(messages, value):
    return True
```

The second one compares the **provider-reported** `usage_metadata.total_tokens`
against the trigger. That number is the whole request: system prompt + tool
schemas + messages. Measured on this box:

| component | tokens |
|---|---|
| system prompt (`lead_agent` `SYSTEM_PROMPT_TEMPLATE`) | 3,220 |
| 45 tool schemas (`get_available_tools`, subagent on) | 11,508 |
| **unremovable floor** | **14,728** |

Observed live floor across `d46320fd`: **10,018 .. 13,889** tokens. The 14,728
figure is authoritative - it is what the request actually carries, measured from
the live tool set rather than inferred from a delta.

Summarization can only remove *messages*. It cannot remove the system prompt or
the tool schemas. With `trigger = 12000` the reported total was over the trigger
on **every** call - including immediately after a summarization pass. So the
lane fired, replaced the history with a summary, and the very next call was
still over 12000. It fired again. Forever.

Measured on `d46320fd`:

```
step 402  total=15097  cutoff=2  -> summarize
step 410  total=15196  cutoff=3  -> summarize
step 419  total=15315  cutoff=4  -> summarize
step 428  total=17007  cutoff=16 -> summarize
step 437  total=15353  cutoff=5  -> summarize
step 446  total=15425  cutoff=4  -> summarize   (still going)
```

Six passes, each one a full extra LLM call on the **same single Ollama runner
slot** as the user's chat (`OLLAMA_NUM_PARALLEL` defaults to 1). That is the
"hang while another lane works" signature: the user's own request is queued
behind its own summarizer.

## `keep` is not the lever

The shipped config also had `keep: 12000`, equal to the trigger. That is a real
second-order bug, but fixing it alone does **not** fix the hang. Replaying the
real middleware against the live checkpoint at step 446, with the
reported-token path active:

| keep | post-summarization tokens | fires again? |
|---|---|---|
| 12000 | 16,289 | yes |
| 8000 | 11,392 | yes |
| 6000 | 10,699 | yes |
| 4000 | 5,093 | yes |

All four are under the 12000 trigger on the *counter* path, yet all four still
fire, because `reported = counter + floor` and the floor alone exceeds 12000.
Lowering `keep` only shrinks the preserved suffix; it cannot shrink the floor.

## How it was isolated

1. `docker ps` + `pacgate-api` logs: stack healthy, LLM tiers resolved.
2. `deer-flow` logs: `Create Agent(default) -> model_name:
   deepseek-v4.1-flash-cloud, is_plan_mode: True`.
3. `runs` table in `/data/deer-flow/data/deerflow.db`: identified the two
   non-terminating runs and their token totals.
4. `checkpoints` table in `/data/deer-flow/checkpoints.db`, decoded with
   `JsonPlusSerializer` (must use `/app/backend/.venv/bin/python` - the system
   `python3` has no `langgraph`): counted `RemoveMessage` writes and
   `name="summary"` HumanMessages. Four summaries at steps 410/419/428/437 on
   `d46320fd`, three at 61/70/79 on `bb71ff66`.
5. Read `SummarizationMiddleware` source from the container venv and found the
   reported-token path.
6. Measured the floor: `approx_msgs=15097` vs `reported_input=29167` on the
   first call; steady-state 10,018..13,889.
7. Simulated 40 agent steps with the **real** middleware, `reported = counter +
   floor`, counting summarization passes (40 = treadmill):

```
trigger  keep | floor 10k  14.7k  18k  22k
-------  ---- | ---------  -----  ---  ---
 12000   6000 |   40 TREAD  40 T   40T  40T
 24000   6000 |    7        40T   40T  40T
 28000   6000 |    5         6    40T  40T
 32000   6000 |    4         5     6   40T
 36000   6000 |    3         4     4    5
```

## Proven end-to-end, not just simulated

Thread `bb71ff66` (the 9.5 MB `Day_1_v3.pdf` run) was **still mid-flight** when
the fixed config hot-reloaded at 10:37:30 UTC. It summarised once at step 62 and
then ran to completion at **10:43:54** with a real Chinese report
(`last_ai_message` populated, status `success`, 37 LLM calls, 463,226 total
tokens).

Replaying its **147 real post-summarization states** (steps 62..208) through the
middleware:

| config | would fire on |
|---|---|
| `trigger=12000 keep=12000` (shipped) | **147 of 147** |
| `trigger=12000 keep=6000` (keep-only fix) | **147 of 147** |
| `trigger=36000 keep=6000` (applied) | **0 of 147** |

This is also the direct refutation of "just lower `keep`": it changes nothing.

## Why `LoopDetectionMiddleware` did not stop it

The loop is **semantic**, not syntactic. Max consecutive identical tool-call-set
was only **2** (warn=3, hard=5), and per-tool frequency (`bash` 71 calls,
warn=30/hard=50) emitted a single warning at 09:17:13. The model was not
repeating a call - it was re-deriving the same plan after each summarization
wiped its memory of having already done it.

## The fix

`deploy/client-bundle/deer-flow-config.yaml`:

| key | before | after | why |
|---|---|---|---|
| `trigger` | 12000 | **36000** | must clear the unremovable floor (11,094 measured, up to 22k worst case) |
| `keep` | 12000 | **6000** | a pass must buy real headroom, not just dip under the trigger |
| `trim_tokens_to_summarize` | 8000 | **36000** | the summarized span grows with the trigger; at 8000 the summarizer saw only the tail of a 32,614-token span and dropped the oldest ~24k - on a document task, the part read first |

36000 is not a new regime: the 2026-10-09 note in the same file already measured
"next model call input bounded 32,770" as the intended post-summarization size.

Context headroom: deer-flow sends no `num_ctx`, so Ollama loads `gemma4` at
262144. A 36k trigger plus an 8k completion is ~44k, well inside that.

Verified with the real middleware across the full plausible floor range
(10k..22k): 3-5 passes per 40 steps instead of 40, and `trim=36000` covers the
worst measured span (32,614).

## Residual risk

- The floor is **measured, not enforced**. Adding tools or lengthening the
  system prompt raises it. `scripts/test-summarization-treadmill.ps1` S1 pins
  `trigger > 14728 + 8000`, so a future tool set that pushes the floor past
  28,000 will fail the gate rather than silently reintroduce the treadmill.
- A **runtime** guard is not available: `deploy/deer-flow-pacgate/Dockerfile`
  explicitly "never forks deer-flow source" - it layers the adapter on the
  published upstream image. The static gate is the only enforcement point.
- `trim_tokens_to_summarize` is a **cap, not a target**. At 36000 it is a no-op
  for spans under 36k (verified: a real 8,968-token span passed all 14 messages
  through unchanged at trim 8000/16000/36000). It only bites on spans above it,
  which is exactly the case it exists to protect.
- The two stuck runs are **not** live. `5331936e` ended `interrupted` at
  09:23:18, `6005867a` and `2cd6fe41` ended `error`, and `6beb638b` ended
  `success` at 10:43:54. Nothing needs cancelling.
