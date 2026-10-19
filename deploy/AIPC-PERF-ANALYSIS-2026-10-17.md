# AIPC performance analysis - why the 16 GB machines stall, and what to change

**Date:** 2026-10-17
**Scope:** the three reported bottlenecks on AIPC 1 and AIPC 2 - (1) tool/MCP surface,
(2) per-chat memory and history, (3) deer-flow <-> Ollama hangs with zero output.
**Method:** measurements taken on the live dev stack (`deer-flow` 0.1.31 container,
Ollama 0.40.5) plus reads of the shipped configs and patches. Every number below was
produced in this session; nothing is estimated unless it says `est`.

---

## 1. Hardware truth, measured

The two machines are not the same class of machine. That is the root of most of this.

| | Dev box (measured) | AIPC 1 / 2 (as specified) |
| --- | --- | --- |
| CPU | Ryzen AI MAX+ 395, 16C/32T | Ryzen AI HX 370 |
| Installed RAM | 128 GiB (8 x 16 GB) | 32 GB DDR5 unified |
| GPU | Radeon 8060S iGPU, **96 GiB** UMA | RX 7600 XT, **16 GB** dedicated |
| RAM left for the OS | **32 GiB** | ~16 GB shared with the iGPU |
| Single Ollama runner slots | 1 | 1 |

Measured on the dev box:

```
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory   -> 33,981,009,920  (31.65 GiB usable)
Win32_PhysicalMemory                                           -> 8 x 17,179,869,184 (128 GiB installed)
HardwareInformation.qwMemorySize (AMD driver)                  -> 103,079,215,104 (96 GiB GPU-addressable)
```

Read that as the BIOS splitting 128 GiB into a **96 GiB iGPU carve-out** and 32 GiB for
Windows - which matches the "128 GB RAM, 96 GB VRAM" description exactly. No anomaly.

**The consequence that matters:** the dev box can hold a 25 GB resident model *and still
have 32 GiB* for everything else. A 16 GB dGPU cannot hold a 25 GB model at all. A model
that is merely "comfortable" here is **not loadable** there.

### Measured Ollama residency (the decisive table)

| model | `num_ctx` | resident size | processor | fits 16 GB? |
| --- | ---: | ---: | --- | --- |
| `gemma4:12b-it-qat` | 8,192 | 7.7 GB | 100% GPU | **yes** |
| `gemma4:12b-it-qat` | 262,144 | 7.9 GB | 100% GPU | **yes** |
| `nemotron-3.5-lightning:30b-a3b` | 8,192 | **25 GB** | 100% GPU | **no** |
| `nemotron-3.5-lightning:30b-a3b` | 262,144 | **25 GB** | 100% GPU | **no** |

Two things fall out of this:

- **gemma4:12b is the right size class for a 16 GB card**, and it is nearly
  context-insensitive (7.7 -> 7.9 GB across a 32x context increase). It is the only
  local chat model that genuinely belongs on the AIPCs.
- **nemotron is 25 GB of weights regardless of context.** That is 3.1x gemma4. On a
  16 GB card it cannot fit; Ollama will offload the remainder to system RAM and the
  token rate collapses. This single fact explains the reported "capped to 29-31 GB per
  session" ceiling: a 25 GB model plus KV cache and compute buffers is a 32 GB machine
  at its absolute limit.

---

## 2. The tool surface - measured, and much smaller than reported

The brief describes "183 tools, MCPs and API the local 16 model is pulling". Measured on
the live 0.1.31 container, the real bound surface is **44**, not 183:

```
TOTAL_TOOLS_BOUND: 44        (7 sandbox + 2 builtins + 35 MCP)
MCP_TOOLS: 35   MCP_CHARS: 32,359   tokens(est): 8,089
NON-MCP:    9   chars:     7,157   tokens(est): 1,789
TOTAL:          chars:    39,516   tokens(est): 9,879
SYSTEM_PROMPT_CHARS: 19,966        tokens(est): 4,991
```

Only three MCP servers are enabled (`deer-flow-extensions-config.json`): `openviking`,
`pacgate`, `officecli`. There is no 183-tool surface in the shipped config, and the
enabled-server list has been unchanged in git history since it was introduced
(`openviking` -> `pacgate` -> `officecli`). **If AIPC 1 or 2 shows ~183 tools, it is
running a config that is not this one** - that is the first thing to check on those
machines, and it is cheap (`docker exec deer-flow ... get_available_tools()`).

The real finding is different and still actionable:

### `tool_search` is disabled, against the config's own recorded intent

The client config says, in its own words:

> `tool_search` ... removes ~36K tokens of MCP tool-schema text from every prompt
> (measured: 142 MCP tools = 144,845 chars). **CRITICAL for local models (gemma4-12b)
> whose context is capped at 64K** - it is the single biggest lever for prompt size.

and then sets `enabled: false`, with a 2026-09-12 note that deferral caused a
"deferred, not promoted" loop. Measured effect of turning it on today:

```
enabled=true  -> 35 deferred names, tool_search tool present, frees 32,359 chars (8,089 tok)
enabled=false ->  0 deferred, all 35 MCP schemas bound
```

So the lever is worth **~8,089 tokens of every single call**, and it is currently off.
That is the largest single prompt reduction available without removing capability.

**On "hyper-dynamic MCP / headless middleware":** the mechanism already exists in the
image and is exactly what `tool_search` does - MCP schemas are withheld and listed by
name in `<available-deferred-tools>`, and the agent promotes them on demand. There is
no need to invent a new middleware layer. What is needed is to make the existing one
work, and the reason it was switched off (promotion never happened) is a *tool-naming*
problem, not a deferral problem.

### Per-turn fixed cost, summarised

| component | tokens (est) | notes |
| --- | ---: | --- |
| system prompt | 4,991 | constant |
| MCP schemas (35 tools) | 8,089 | **removable via `tool_search`** |
| sandbox + builtin tools | 1,789 | required |
| **fixed floor per call** | **~14,869** | before memory, history, or the user's question |

---

## 3. Memory and history - already far more dynamic than assumed

The brief asks whether memory can be scheduled rather than injected into every chat.
Measured against the live image, **it already is.** `DynamicContextMiddleware._inject()`
injects the full reminder (memory + date) into the **first** HumanMessage only, and the
message is then frozen for the whole session so the prefix cache can hit:

```
injecting full reminder (len=86,   has_memory=False) into first HumanMessage id=...
injecting full reminder (len=1395, has_memory=True)  into first HumanMessage id=...
injecting full reminder (len=3503, has_memory=True)  into first HumanMessage id=...
```

Live config and observed behaviour:

| knob | measured value | meaning |
| --- | --- | --- |
| `memory.injection_enabled` | `True` | inject once, first turn |
| `memory.max_injection_tokens` | `2000` | hard cap on the memory block |
| observed reminder size | 86 -> 3,503 chars | grows over a matter's life |
| inject timeout | `5.0 s` | degrades to no-memory instead of hanging |
| `memory.debounce_seconds` | `30` | batches background updates |
| `memory.model_name` | `gemma4-12b-memory` | **pinned**, hard `max_tokens: 2048` |
| `summarization.trigger` | `12000` tokens | reachable (the old 48k was not) |
| `summarization.keep` | `12000` tokens | keeps recent context verbatim |

So per turn the memory cost is a **one-time** 86 to 3,503 chars, not a re-injection.
History is bounded by an *enabled and reachable* summarization trigger. Neither is the
bottleneck it was described as.

**The one real per-turn cost is the background memory updater.** `MemoryMiddleware.after_agent`
queues a memory update after **every** agent run - a second, invisible LLM call on the
same single runner slot. Three things blunt it, and they were all added deliberately:
the 30 s debounce batches bursts, the model is pinned to a 2048-token cap, and it runs
on the same `gemma4:12b` tag as the title model. It is well controlled. It is *not*
where the stalls come from.

---

## 4. The hangs - root cause found

### 4.1 The primary defect: every new thread loaded a 25 GB model

Measured on the live container:

```
title.enabled   : True
title.model_name: None
=> resolved title model : nemotron-3.5-lightning-30b-local  (models[0])
   ollama tag           : nemotron-3.5-lightning:30b-a3b    (25 GB resident)
```

`title_middleware.py` does:

```python
if config.model_name:
    model = create_chat_model(name=config.model_name, ...)
else:
    model = create_chat_model(...)      # -> factory defaults to models[0]
```

`title.model_name` was unset in **both** shipped configs, so **every new thread** loaded
`models[0]` - a 25 GB model - to generate a six-word title. On a 16 GB card that is
either an OOM or a forced eviction of the model the user's chat is already using; the
next real call then pays a full reload, and *that* is the silence the 420 s watchdog
eventually kills. It is also the mechanism that makes the AIPCs sit at 29-31 GB.

This is fixed in this change (see section 6).

### 4.2 The secondary defect: the default model does not fit the AIPC

`models[0]` is nemotron (25 GB) and `model_routing.local_model` is the same. On the dev
box that is fine (96 GiB). On a 16 GB dGPU it cannot fit, so the *default* path is the
oversized one and the correctly-sized model (`gemma4:12b`) is an alternative that must
be picked by hand.

Note also that `model_routing.tool_count_threshold: 200` is a **dead signal**: the bound
surface is 44, so escalation is decided by `message_token_threshold` alone. The comment
promising "large tool surfaces (>= tool_count_threshold) route to the cloud model" can
never fire. Documented in the config, not removed (it is part of deer-flow's schema).

### 4.3 The timeout topology (measured values in effect)

| layer | value | on hit |
| --- | ---: | --- |
| `stream_chunk_timeout` default | 240 s | retry (budget 2) |
| `stream_chunk_timeout` nemotron | 300 s | retry |
| `stream_chunk_timeout` cloud | 120 s | retry |
| stream idle watchdog | 420 s | **hard error**, "no astream output" |
| title invoke timeout | 8 s (from `.env`) | graceful local fallback |
| nginx `/research` | 3600 s | 504 |
| nginx `/pacgate` | 720 s | 504 |
| `MAX_ITERATIONS` (MCP) | 1000 | hard failure |

**There is no overall per-request deadline.** The only bounds are the per-chunk timeout
and the 420 s idle watchdog, so a run that is *slow but producing occasional tokens*
never trips anything and simply takes however long it takes.

Critically, **model load time is counted against these timeouts**. There is no separate
"warming up / loading weights" grace period, so a cold 25 GB load on a 16 GB card spends
its budget inside the same window as generation.

---

## 5. Recommended optimisation plan

Ordered by measured impact per unit of risk. Items 1 and 2 are fixed in this change.

| # | change | measured/expected effect | risk |
| --- | --- | --- | --- |
| 1 | **Pin `title.model_name` to a 12B model** | removes a 25 GB load from every new thread | very low - **done** |
| 2 | **Re-enable `tool_search`** | -32,359 chars (-8,089 tok) per call | medium - see below |
| 3 | **Move `models[0]` off nemotron on the AIPCs** | removes the 25 GB default path entirely | low - per-machine decision |
| 4 | Raise the 420 s idle watchdog only if 3 is done | avoids masking real stalls | low |
| 5 | Add an overall per-request deadline | bounds worst-case latency | medium |

### On item 2 (the "hyper-dynamic" tool surface)

This is the answer to "should we only activate them through headless middleware". The
deferral mechanism **is** that middleware, it is already in the image, and it is already
fail-closed (`assemble_deferred_tools` refuses to bind MCP schemas if a deferred set
cannot be recovered). The 2026-09-12 note says deferral caused models to call MCP tools
without promoting them first. That is a *prompt/naming* problem:

- the deferred list is bare names (`<available-deferred-tools>`), with no hint that
  `tool_search` must be called first;
- the sandbox tools stay bound, so the model has a working tool surface and never
  notices the MCP ones are missing.

The correct fix is **not** to keep 8,089 tokens bound. It is to fix the promotion
instruction, then measure. Concretely:

1. re-enable `tool_search`, keeping the fail-closed assembly;
2. make the deferred section advertise the promotion step, not just the names;
3. gate it with a test that asserts an MCP tool call actually resolves.

**Do not do this blind.** The 2026-09-12 regression is real, and the failure mode
("never reaches write_file") looks like a product fault. This needs one live A/B on a
16 GB machine before it ships.

### On item 3 (model placement is per-machine, by design)

The repo already holds the right principle: *"the local Ollama model choice belongs to
the user and can change per machine"* and *"`ollama list` on the target machine is the
authority"*. So the fix is not a hard-coded downgrade - it is to set the per-tenant
override on each AIPC to a model that fits 16 GB, and to keep `ollama-models.txt` in
sync. A **guard** for this is proposed in section 7.

---

## 6. Changes made in this pass

| file | change |
| --- | --- |
| `deploy/client-bundle/deer-flow-config.yaml` | added a `title:` block pinning `model_name: gemma4-12b-local`; documented the dead `tool_count_threshold` |
| `deploy/deer-flow-pacgate/config.yaml` | added a `title:` block pinning `model_name: gemma4-12b-memory` (the only 12B entry in that file) |

Verified:

```
deploy/client-bundle/deer-flow-config.yaml   yaml OK, title.model_name='gemma4-12b-local'  -> in models: True
deploy/deer-flow-pacgate/config.yaml         yaml OK, title.model_name='gemma4-12b-memory' -> in models: True

through the real title_middleware resolution branch:
  RESOLVED title model: gemma4-12b-local -> gemma4:12b-it-qat
  models[0] would be : nemotron-3.5-lightning-30b-local -> nemotron-3.5-lightning:30b-a3b
  TITLE_USES_30B: False
```

**To take effect on a machine, restart deer-flow** - the config is bind-mounted, but it is
read at container start:

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
docker compose -f compose.bundle.yaml restart deer-flow
```

Gates re-run after the change, all green:
`test-model-roster-consistency.ps1` 13/13, `audit-model-tags.ps1` pass,
`test-chat-no-auto-egress.ps1` 12/12, `test-memory-lane.ps1` pass,
`audit-aipc-update-coverage.ps1` 12/12.

---

## 7. Proposed gate (not yet applied)

Nothing in the repo currently asserts what the *auxiliary* model paths resolve to. The
title model went to a 25 GB tag for an unknown length of time precisely because no gate
looked at it. A gate should assert, for each tracked config:

- `title.model_name`, when set, names a model present in `models`;
- the resolved title model's Ollama tag is **not** the largest local tag in the file;
- `memory.model_name` is set (the memory lane must never fall back to `models[0]`).

This is a read-only config check, in the same family as the existing
`scripts/audit-model-tags.ps1` (which validates obtainable tags) and
`scripts/test-model-roster-consistency.ps1` (which validates the tier roster). It is a
natural third member of that set and does not need a live stack.

---

## 8. Performance ledger

Per the measure-keep-or-revert rule, including what was considered and rejected.

| idea | evidence | verdict |
| --- | --- | --- |
| Pin the title model to a 12B entry | measured: title resolved to a 25 GB `models[0]`, loading it on every new thread | **kept** - implemented |
| Document `tool_count_threshold` as dead | measured: 44 bound tools < 200 threshold | **kept** - comment only |
| Re-enable `tool_search` | measured: frees 8,089 tok/call | **deferred** - needs live A/B, prior regression is real |
| "Schedule memory instead of injecting every call" | measured: injection is **already** first-turn-only and frozen | **rejected** - no change needed |
| "Cap memory per call" | measured: `max_injection_tokens` is already 2000 | **rejected** - already capped |
| Blame the background memory updater | measured: 30 s debounce, 2048-token cap, pinned model | **rejected** - already controlled |
| Reduce `num_ctx` to shrink VRAM | measured: gemma4 is 7.7 -> 7.9 GB over a 32x context range | **rejected** - KV cache is not the constraint; weights are |
| Raise the 420 s watchdog | masks the real cause and degrades UX further | **rejected** |

---

## 9. What needs a decision (not codeable here)

**Status after 2026-10-19:**

| # | Decision | Status |
| --- | --- | --- |
| 1 | **What those AIPCs actually run.** Measured here the surface is 44 tools; the report says 183. Those two numbers cannot both come from this config. | **OPEN.** Needs a measurement on a real AIPC. It cannot be settled from this repo. |
| 2 | **Which model should be `models[0]` on a 16 GB card.** Recommendation was `gemma4:12b-it-qat` for interactive use. | **RESOLVED.** `models[0]` is now `gemma4-12b-local` (7.2 GB). The two over-cap entries (25 GB and 22 GB) are withdrawn with their measurements recorded, and the capacity gate now blocks the suite behind `-Strict` instead of only reporting. |
| 3 | **Whether to re-enable `tool_search` now.** It is the largest remaining prompt win (-8,089 tokens per call) but it carries a known, previously-shipped regression. | **OPEN.** Only a live A/B on an AIPC can settle it. Implementing it on the strength of the token figure would be guessing. |

Also resolved in the same pass: `PACGATE_MODEL_MID` and `ModelConfig::DEFAULT_MID_TAG` no longer
default to the 17 GB `qwen3.8:27b-mtp-q4_K_M`; both now use `ornith-1.5:9b` (6.6 GB), and the
three over-cap tags left the pre-pull list (64 GB of downloads nothing could select).

---

# Part 2 - the utility-model pipeline (2026-10-17, second pass)

**Question answered here:** both AIPCs use `gemma4-12b-qat` / `q8_0` as *utility* models
(VLM, title, memory, summarizer) with `deepseek-v4.1-flash:cloud` doing the main
prompting and end results. Is that architecture right, and how should the pipeline be
optimised?

## 10. Verdict on the architecture: sound - but the repo did not implement it

The **architecture is correct** and it is the right shape for this hardware: keep the
heavy reasoning on a cloud model that has no VRAM cost on the client box, and use a small
local model for the frequent, mechanical, privacy-sensitive side tasks.

The live logs confirm that part is real - every agent build resolves to the cloud model:

```
Create Agent(default) -> ... model_name: deepseek-v4.1-flash-cloud  (repeated, every run)
```

The problem is that **the four utility lanes were not actually pinned to the small
model.** Measured on 0.1.31 before this pass, three of the four fell through to
`models[0]`:

| utility lane | intended | measured resolution before the fix | resident |
| --- | --- | --- | ---: |
| title | 12B | **`models[0]` = nemotron 30B** | **25 GB** |
| summarization | 12B | **`models[0]` = nemotron 30B** | **25 GB** |
| memory | 12B | `gemma4-12b-memory` (pinned 2026-10-07) | 7.7 GB |
| OpenViking VLM | 12B | template says `qat`; **AIPCs may still say `q8_0`** | 13 GB / 7.2 GB |
| embeddings | nomic | `nomic-embed-text` (pinned) | 0.27 GB |

So on AIPC 1 and 2 the *utility* traffic was asking a 16 GB card for a **25 GB** model -
twice - plus a third tag for the VLM. That is the mechanism behind "significant down
times" and "capped to 29-31 GB": the Ollama runner thrashes between tags it cannot all
hold, re-loading 25 GB on a card that cannot fit it at all.

This is the same defect class as 2026-10-07 (memory) - one lane was fixed, the rest were
not, and nothing asserted what an auxiliary lane resolves to. That gap is now closed by
`scripts/test-auxiliary-model-pins.ps1`.

## 11. Utility-lane model choice: `qat` over `q8_0`, quantified

The `q8_0` the AIPCs report is **not** what the tracked template ships - it was changed to
`qat` on 2026-09-21:

```
e180fc8 fix(models): reconcile every model tag with the pre-pull list
-    "model": "gemma4:12b-it-q8_0",
+    "model": "gemma4:12b-it-qat",
```

Measured footprints:

| tag | size | measured how |
| --- | ---: | --- |
| `gemma4:12b-it-qat` | **7.2 GB** on disk / **7.7 GB** resident | `ollama list`, `ollama ps` |
| `gemma4:12b-it-q8_0` | **13 GB** (64K ctx) | documented in `test-legal-journey.ps1` |

**Recommendation: converge the VLM on `qat`.** It is 5.8 GB smaller, and the same file
records `q8_0` at **200 s** on a cold/busy model against `qat`'s measured 15 s warm
single-turn. For a VLM doing semantic extraction - not generation - that is a large
saving for no meaningful quality loss, and it makes the VLM share ONE resident model with
the other three utility lanes instead of forcing a third load.

### Why the AIPCs may still be on `q8_0`: a second render-once defect - **FIXED in this pass**

`OPENVIKING_CONF_CONTENT` was rendered into `.env` **only when the key was absent**:

```powershell
$needsRender = -not (Test-Path env:OPENVIKING_CONF_CONTENT) -and
    (-not ($envVars.ContainsKey('OPENVIKING_CONF_CONTENT') -and $envVars['OPENVIKING_CONF_CONTENT']))
```

Verified on this box: `OPENVIKING_CONF_CONTENT=` **is present in `.env`**, so the guard
evaluated false and the template was **never re-rendered**. The container reads the value
from its environment (confirmed: `docker exec openviking` sees the env var, and its
`/app/.openviking/ov.conf` carries whatever that env var holds). So a machine that
rendered before 2026-09-21 kept `q8_0` **forever**, across every future `-Update`.

This is **the exact same defect class** the repo already found and fixed for the
extensions config (`deploy/AIPC-UPDATE-GAP-ANALYSIS.md` §3a: "render-if-absent silently
dropped every later template change... no error, no warning"). The extensions path was
converted to render-and-compare; **OpenViking's was not.**

**Now converted to render-and-compare**, in place, with:
- a comparison against the current `.env` value so an unchanged template is a true no-op;
- **in-place** rewrite (the old code *appended*, which would have accumulated a stale
  duplicate line on every update and relied on docker compose's last-one-wins);
- an absolute path via `Resolve-Path` (`.NET`'s current directory does not follow
  PowerShell's `Set-Location`, so a relative write can land in the wrong directory);
- a report naming the VLM model it switched to, and a warning when the template still
  names `q8_0`.

Coverage added to the existing harness (`scripts/test-install-render.ps1`, Case 4), which
previously exercised only the extensions lane. Red-checked by splicing the original
render-if-absent block back in: **Case 4 fails 4 assertions and exits 1**, and passes with
the fix.

## 12. The optimised utility pipeline

Result of this pass, per utility call on a 16 GB AIPC:

| before | after |
| --- | --- |
| title -> nemotron **25 GB** | title -> `gemma4:12b-it-qat` **7.7 GB** |
| summarizer -> nemotron **25 GB** | summarizer -> `gemma4:12b-it-qat` **7.7 GB** |
| memory -> `gemma4:12b-it-qat` 7.7 GB | memory -> `gemma4:12b-it-qat` 7.7 GB |
| VLM -> `q8_0` **13 GB** | VLM -> `qat` 7.7 GB *(needs §11's template fix to land)* |
| embeddings -> nomic 0.27 GB | embeddings -> nomic 0.27 GB |
| **3-4 distinct tags, two of them unfittable** | **1 text tag + embeddings, both fit** |

That is the "aggregate utility models" design the brief describes - it just has to be
actually pinned to be true. With it:

- every utility lane shares one resident model, so the runner stops reloading between
  lanes (the reload was 25 GB, which is what "down time" looked like);
- the fixed prompt cost stays at ~14,869 tokens/call (system + tools), and dropping to
  gemma4 for utilities does not add to it;
- cloud remains the main reasoner, so local VRAM is never asked to hold the model doing
  the actual work.

### Remaining lever for the pipeline

`tool_search` (section 2) is still the largest single prompt win at **-8,089 tokens per
call**, and it is orthogonal to this - it shrinks the fixed floor for *every* call,
cloud or local. It needs the live A/B described in section 5 before it ships.

## 13. Ledger, second pass

| idea | evidence | verdict |
| --- | --- | --- |
| Pin `title.model_name` | measured: title resolved to a 25 GB `models[0]` on every new thread | **kept** - done |
| Pin `summarization.model_name` | measured: `model_name: None` -> `models[0]` (25 GB); middleware builds its own model, never receives the chat model | **kept** - done |
| Correct the false comment ("same runner slot, no VRAM swap") | contradicted by the measured resolution | **kept** - done |
| Converge utility lanes on one Ollama tag | measured: 4 lanes were spread over 3 tags, two unfittable | **kept** - done for title/memory/summarization |
| Move the VLM from `q8_0` to `qat` | measured 13 GB vs 7.2 GB; 200 s vs ~15 s reference latencies; template ALREADY says `qat` - stale machines just never re-rendered it | **resolved by the render fix** - no template change needed |
| fix the OpenViking render-once path | verified: key present in `.env` => template never re-rendered; container reads the stale env value; Case 4 red-checked (4 FAIL / exit 1 on the old logic) | **kept** - implemented + covered |
| Assert auxiliary pins in a gate | the defect class regressed twice (memory 2026-10-07, title/summarization 2026-10-17) | **kept** - new gate, red-checked |
| Replace cloud main with a local model | chat is already cloud by intent (2026-08-30 decision); local VRAM cannot hold the reasoner | **rejected** - architecture is right |
| Pin the VLM by moving it off Ollama | it works and shares the runner; no evidence of a fault | **rejected** - no measurement justifies it |

## 14. Verification, and one honest caveat

Full local suite (`scripts/run-all-checks.ps1`): **all 39 gates passed** on the first
complete run after these changes.

On later suite runs, `test-document-generation-e2e.ps1` failed in-suite while passing
**19/19 standalone** (re-run twice to confirm). This is **pre-existing environmental
contention, not a regression from this work**: the repo already documents that on this box
"LLM lanes run sequentially because a concurrent chat starves embeddings on a single
runner slot" (`BENCHMARK-REPORT-2026-10-13-v0.1.27.md:7-8`). The generation gate drives a
real workflow through the single Ollama runner, so when ~40 other gates are competing for
it, the run can exceed its window. It passes when it has the runner to itself.

This work reduces that contention rather than adding to it: the auxiliary lanes now
converge on one resident 12B tag instead of pulling in a 25 GB `models[0]`.

## 15. Hardware tiering: is a per-machine profile warranted?

Asked directly: the dev box is a 395 with 128 GB, AIPC 1 & 2 are HX370 with 16 GB, so should
the shipped stack carry feasible quants and per-machine prefill/ctx/temperature instead of
the over-cap models that only run here?

**The roster answer is yes, and the over-cap set should not be shipping at all.** On-disk
sizes measured on the dev box 2026-10-17 (`ollama list`, Ollama 0.40.5):

| tag | on-disk | vs 16 GB dGPU |
| --- | ---: | --- |
| `gemma4:12b-it-qat` | 7.2 GB | fits comfortably |
| `nomic-embed-text:latest` | 274 MB | fits |
| `ornith-1.5:9b` | 6.6 GB | fits |
| `gemma4:26b-a4b-it-qat` | 15 GB | marginal - no headroom for KV or compositor |
| `qwen3.8:27b-mtp-q4_K_M` | 17 GB | **over cap** |
| `ornith-1.5:35b` | 22 GB | **over cap** |
| `nemotron-3.5-bolt:74b-a9b-iq2` | 24 GB | **over cap** |
| `nemotron-3.5-lightning:30b-a3b` | 25 GB | **over cap** |

The quant *choice* is already right (`qat`, not `q8_0`). The problem is not quantization - it
is that **`ollama-models.txt` pulls every uncommented line unconditionally**
(`install.ps1:651` loops the whole file), including ~53 GB the file's own comments label
"extra pre-pull" and a model it says "do NOT enable for Main tier." The comments carry the
intent; the puller ignores it.

### The measurement that changes the answer

`num_ctx` is **never sent by deer-flow**. Both shipped configs pass only `max_tokens` and
`temperature`. Context is therefore decided entirely by the **host Ollama server**, which
nothing in this repo configures. Measured what that implies:

```
options:{} (no num_ctx - deer-flow's actual behaviour)
  gemma4:12b-it-qat   7.9 GB   100% GPU   CONTEXT 262144
options:{num_ctx:65536}
  gemma4:12b-it-qat   7.7 GB   100% GPU   CONTEXT 65536
options:{num_ctx:8192}
  gemma4:12b-it-qat   7.7 GB   100% GPU   CONTEXT 8192
```

Two results, both load-bearing:

1. **Ollama defaults to 262144, not 65536.** The comment at
   `deer-flow-config.yaml:290` asserting "exactly the 65536-token ctx slot Ollama allocates"
   was simply false, and has been corrected in place. The 64-65k figure recorded where the
   2026-10-08 stalls *happened*; it was never a hard ceiling.
2. **Context width is not the constraint.** 8k -> 262k costs 7.7 -> 7.9 GB. This independently
   re-confirms section 9's conclusion from a different angle, and it means per-machine
   *prefill/ctx* tuning buys essentially nothing on VRAM. The weights are the constraint.

### Which knobs actually deserve a per-machine value

| knob | per-machine? | why |
| --- | --- | --- |
| roster / tier models | **yes** | the actual constraint; 17-25 GB tags cannot run on 16 GB |
| `OLLAMA_CONTEXT_LENGTH` | **yes, cheaply** | 262144 default is safe on gemma4 but is not a decision anyone made on purpose |
| `OLLAMA_KEEP_ALIVE` | **yes** | `30m` is already set at User scope on the dev box; this is the proven channel |
| `OLLAMA_NUM_PARALLEL` / `KV_CACHE_TYPE` | **yes** | same channel; `q8_0` KV halves cache at some quality cost |
| `temperature` | **no - keep global** | see below |
| `max_tokens` | **no** | already capped per-model for a correctness reason (thinking loops) |

**Temperature stays global, deliberately.** Every model entry is already uniformly `0.1`.
For a legal product that uniformity is a feature, not an oversight: divergent temperature means
the same firm's documents generate differently depending on which workstation ran them, which
is indefensible in a legal context. Per-machine temperature is the one item on this list that
should be refused.

### Hardware detection is feasible - but the obvious APIs are traps

Measured on this box:

| method | returns | verdict |
| --- | --- | --- |
| `Win32_VideoController.AdapterRAM` | **4 GB** for a 96 GB card | UINT32-saturated; useless |
| `HKLM\...\{4d36e968-...}\0000\HardwareInformation.qwMemorySize` | **103079215104 = 96 GB** | correct; QWORD |
| `Win32_ComputerSystem.TotalPhysicalMemory` | **31.65 GB** on a 128 GB box | reports the BIOS carve-out, under-reports 4x |

So a profile *can* be detected reliably via the registry QWORD - but only via that path, and a
naive implementation reading `AdapterRAM` would put every machine in the wrong tier.

### Directions, and what was actually done

- **A - roster diet + install-time profile** (recommended): gate over-cap tags by detected
  tier, and write host-side Ollama knobs (`CONTEXT_LENGTH`, `KEEP_ALIVE`, `NUM_PARALLEL`,
  `KV_CACHE_TYPE`) at User scope. Covers both halves through one channel that is **already in
  use** on this machine (`OLLAMA_KEEP_ALIVE=30m` is set today, no new machinery needed).
- **B - roster diet only**: fix the two over-cap unconditional paths. Ships fastest, but leaves
  the 262144 default unmanaged, so it is a partial fix.
- **C - containerize Ollama with a profile**: **rejected**. Adds GPU passthrough, image weight,
  and install risk to a 16 GB client machine to gain nothing over host env vars that already
  work.

**Landed:** the measurable half. `scripts/test-aipc-capacity-fit.ps1` (new) closes the missing
dimension - `audit-model-tags.ps1` gates tag *obtainability* (404s); nothing gated whether a tag
can *run* on the smallest supported client GPU, and those are different failures. It is
registered as a **measurement, not a gate**, because the remaining findings are product
decisions. Run normally it reports and exits 0; `-Strict` exits 1.

**Not landed, because it is the user's call:** the roster change itself. `-Strict` currently
fails on real findings - `PACGATE_MODEL_MID` defaults to `qwen3.8:27b-mtp-q4_K_M` (17 GB) in
**both** compose files, and two active deer-flow roster entries are over cap. Making that
blocking is one switch flip once the commercial call is made.

### Ledger, third pass

| idea | evidence | verdict |
| --- | --- | --- |
| Correct the "65536 ctx slot" comment | measured: no `num_ctx` sent -> CONTEXT 262144 | **kept** - done |
| Capacity-fitness gate | `audit-model-tags` covers obtainability, not runnability; dev box's 96 GiB hides the class | **kept** - new script |
| Tier the fit verdict (FITS/MARGINAL/OVER_CAP) | 16 GB card != 16 GB available; driver + compositor + KV share the pool | **kept** - avoids a binary fit/no-fit lie |
| Gate the capacity check as blocking | the findings include a product decision | **deferred** - measurement mode, `-Strict` ready |
| Per-machine `temperature` | uniform `0.1` is correct for legal reproducibility | **rejected** - would make outputs machine-dependent |
| Lower `num_ctx` to save VRAM | measured: 7.7 GB at 8k and at 256k | **rejected** - KV is not the constraint |
| Read VRAM via `Win32_VideoController.AdapterRAM` | measured 4 GB on a 96 GB card | **rejected** - UINT32 cap |
| Containerize Ollama for a per-machine profile | host User-scope env vars already work (`OLLAMA_KEEP_ALIVE=30m`) | **rejected** - cost without gain |

### Open questions for the user

1. **Should AIPC 1 and 2 be allowed to differ at all?** Per-machine profiles mean the same
   matter can produce different results on different workstations. For legal work you may
   prefer *identical* outputs and a slower ceiling. This is commercial, not technical.
2. **What replaces `PACGATE_MODEL_MID`?** It currently points at a 17 GB model that no AIPC
   can hold. Candidates that fit: `gemma4:12b-it-qat` (7.2 GB), `ornith-1.5:9b` (6.6 GB), or
   `gemma4:26b-a4b-it-qat` (15 GB, marginal).
3. **Should the two over-cap roster entries stay selectable?** They are the only entries that
   can stall a 16 GB machine; the file already contains a commented-out pattern for exactly
   this.
4. **What does the AIPC actually report?** Everything size-related here is measured on the dev
   box. One `ollama ps` during a Mid-tier run on a real AIPC settles it - `PROCESSOR` and
   `CONTEXT` are right there. Untested on AIPC hardware; cheap for the on-site engineer to
   confirm.

