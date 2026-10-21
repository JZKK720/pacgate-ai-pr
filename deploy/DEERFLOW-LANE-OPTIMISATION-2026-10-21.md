# deer-flow lane optimisation: model selection, prompt surface, and the WSL ceiling

**Date:** 2026-10-21
**Machine:** HX370 (`CUBECLOUD01`) - RX 7600 XT 15.98 GB VRAM, 61.62 GiB RAM,
Docker VM 30.17 GiB, Ollama 0.40.6, deer-flow 0.1.34
**Supersedes:** the derived-tag recommendation in
`CONCURRENCY-AND-VRAM-2026-10-21.md` §6.5 and the `tool_search: enabled: false`
decision of 2026-09-12.

This report answers three questions that were open after the VRAM work. Each
answer is backed by a measurement on this box, and each produced a code change
with a gate.

---

## 1. Model selection: standard tags, chosen per machine

### What was wrong

`install.ps1` ran `ollama create` to build `pacgate-mid` / `pacgate-low` derived
tags with `PARAMETER num_ctx` baked in, then wrote those names into `.env`.

Three problems, all measured:

1. **They exist in no artifact.** Not in `origin/main`, not in any ghcr image, not
   in `ollama-models.txt`. They could not be pre-pulled, so every deployment
   diverged from the published bundle in a way nothing else could reproduce.

2. **They created a second name for the same weights.** `ollama show --modelfile`
   confirms `pacgate-low` and `gemma4:12b-it-qat` share blob
   `sha256-faff1a63667f`. Ollama keys residency by tag name, so the pair could not
   co-reside. Measured switching cost:

   | step | wall |
   | --- | --- |
   | `pacgate-low` resident → `gemma4:12b-it-qat` | **15.9 s** |
   | `gemma4:12b-it-qat` resident → `pacgate-low` | **15.4 s** |

   The day's log held **56 `llama-server` starts, 55 model loads, 13 evictions**,
   with the same weight set reloaded 32 times. That churn was the largest single
   latency source, and it was self-inflicted.

3. **They froze one context per tier**, so a machine with more VRAM could not run a
   wider window without the installer having decided in advance.

### What changed

The roster is now exactly the standard tags `ollama-models.txt` pre-pulls. The
installer reports what is installed and what the tier suggests, and writes nothing.
`Get-ModelSelectionReport` replaces `Ensure-OllamaContextPinnedTag`.

### Measured effect

deer-flow's chat model and pacgate-api's LOW tier are now the **same tag**, so they
share one runner:

| call | wall |
| --- | --- |
| deer-flow chat (cold, loads model) | 12.42 s |
| pacgate LOW tier (warm, same runner) | **2.40 s** |

No reload between them. `pacgate-api` logs
`LLM tiers: Main=deepseek-v4.1-flash:cloud Mid=ornith-1.5:9b Low=gemma4:12b-it-qat`.

### Caveat found while verifying

The Ollama desktop app's `db.sqlite` `context_length` **overrides**
`OLLAMA_CONTEXT_LENGTH`. The tier says 32768; `ollama ps` reports **65536**. That
app value is the operator's and is deliberately not touched, so the tier's number
is a *request*, not a guarantee. The installer now reads the effective value back
instead of asserting the tier value.

---

## 2. Prompt surface: deferral was disabled for the wrong reason

### The measurement

Every prompt bound 44 tool schemas:

| group | chars | ~tokens |
| --- | --- | --- |
| MCP (openviking + pacgate + officecli) | 32,023 | 8,005 |
| sandbox + builtins | 10,559 | 2,639 |
| **total** | **42,582** | **10,645** |

A **3-message** thread measured **13,049 input tokens**, so ~82% of the prompt was
schema, not conversation. At the measured **528 tok/s** prefill that is ~20 s of
fixed cost per call.

### Why deferral was off

`tool_search: enabled: false`, with this note:

> EVIDENCE (2026-09-12): deferral makes ALL models call MCP tools without promoting
> first -> "deferred, not promoted" loop, never reaching write_file.

That was a real failure, but the cause was the middleware, not the models. On a
blocked call it returned:

```
Error: Tool 'X' is deferred and has not been promoted yet.
Call tool_search first to expose and promote this tool's schema, then retry.
```

The model then had to (a) understand the instruction, (b) emit a second call to
`tool_search`, (c) wait for the schema, and (d) re-emit the original call with
correct arguments. Small local models (gemma4:12b, ornith-1.5:9b) routinely fail at
(b) or (d). The recorded symptom - "never reaching write_file" - is exactly that.

### The fix

`patches/deer-flow-deferred-tool-filter.py` promotes the tool on first call and
executes it **in the same turn**. The model never has to know deferral exists.

Verified behaviours (all four paths):

| case | result |
| --- | --- |
| deferred tool, sync | promoted **and** executed in one turn |
| non-deferred tool (`bash`) | passes through untouched |
| already-promoted tool | passes through, no re-promotion |
| deferred tool, async | promoted **and** executed |
| handler returns its own `Command` | updates **merged**, not replaced |

Reducer semantics also verified: promotions accumulate under the same catalog hash,
and a catalog change drops stale names.

### Measured effect

| | before | after |
| --- | --- | --- |
| bound tools | 44 | **10** |
| bound schema | 10,645 tok | **2,823 tok** |
| saving | - | **73%** |

The 10 always-bound tools are the sandbox surface the agent actually uses. Across
828 checkpoints and 2,664 tool calls on this box, `bash`/`read_file`/`write_file`/
`str_replace`/`present_files` carried 2,284 of them.

### What the research says

Anthropic's Tool Search Tool reports the same shape of result: ~85% token reduction
(77K → 8.7K) and **accuracy improvements**, not regressions - Opus 4 went 49% → 74%
on MCP evaluations. Their guidance is to use it when definitions exceed 10K tokens
and there are 10+ tools, which is exactly this case. The failure here was
implementation, not the technique.

---

## 3. WSL: the ceiling cannot be applied without a restart, and may not be needed

### The constraint

`wsl --shutdown` stops the `docker-desktop` distro, so Docker Desktop dies with it.
Confirmed: `wsl -l -v` shows `docker-desktop` **Running**, and
`docker info` reports kernel `6.18.54.1-microsoft-standard-WSL2`.

### What was measured

| metric | value |
| --- | --- |
| `vmmemWSL` private | 30.32 GiB |
| guest `MemTotal` | 30.9 GiB |
| guest **used** | **8.4 GiB** |
| guest free | 20.1 GiB |
| guest buff/cache | 2.3 GiB |
| all containers | 9.53 GiB |

So ~22 GiB is charged to Windows but used by nothing. `drop_caches` inside the
guest succeeded and **did not reduce `vmmemWSL`** - so this is not reclaimable guest
cache, it is the VM's allocated footprint.

**It is also not permanent.** Later in the same session, under ordinary load,
`vmmemWSL` fell from **30.32 to 20.56 GiB** on its own. Windows does reclaim it when
it needs the memory. The 30 GiB figure is headroom that had not yet been asked for,
not a leak.

### The correction that matters

The alarming reading was taken **during a workflow peak**. At steady state:

| metric | peak (earlier) | steady (now) |
| --- | --- | --- |
| Available | **0.03 MB** | **32.6 GiB** |
| Committed | 71.1 GB | 59.2 GB |
| Pages/sec | - | **9** |
| Pagefile usage | - | 35.8% |

**There is no memory pressure at steady state.** The 30 GiB VM footprint is
headroom Windows has not needed to reclaim, not a leak. The earlier "50 of 64 GB"
reading was commit charge during a peak, and it was real then - but it is not the
standing condition.

### What can be done without a restart

| option | works? | note |
| --- | --- | --- |
| `wsl --shutdown` | **no** | kills Docker Desktop |
| `drop_caches` in guest | **no** | verified: no effect on `vmmemWSL` |
| `.wslconfig` + restart | deferred | needs a maintenance window |
| Docker Desktop memory limit | **no** | `settings-store.json` has no memory key; WSL2 backend ignores it |
| VHDX compaction | n/a | frees disk (121 GB), not RAM |

**Recommendation:** treat the WSL ceiling as a maintenance-window task, not a
runtime fix. If the box pages during a heavy workflow, the operator can add

```ini
[wsl2]
memory=24GB
autoMemoryReclaim=gradual
```

and apply it at the next planned restart. Pacgate does not write `.wslconfig` - it
is per-user and machine-wide, governing every WSL distro, which is the same boundary
violation as rewriting Ollama's shared context setting.

---

## 4. What is still open

Each of these was **measured**, not estimated. Two of the three turned out to be
worse ideas than they looked, which is why they are not shipped.

### 4.1 Larger `-ub` batch size - measured SLOWER, rejected

**The idea.** Ollama picks `-b 512 -ub 512` when the context is 131072, and
`-b 2048` when it is 65536. A larger physical batch should raise prefill
throughput, and the extra cost looked small.

**How to set it.** `num_batch` IS a valid Modelfile parameter (confirmed: it
appears in the binary's parameter list, and `ollama create` accepts it). A derived
tag with `PARAMETER num_batch 2048` does take effect - the runner logged
`n_batch = 2048, n_ubatch = 2048`.

**What it actually cost.** Not the ~435 MiB I estimated. Measured:

| | ub=512 (default) | ub=2048 |
| --- | --- | --- |
| model | 6,637 MiB | 6,637 MiB |
| context (KV) | 3,008 MiB | 3,968 MiB |
| compute buffer | 185 MiB | **748 MiB** |
| **total** | **9,831 MiB** | **11,353 MiB** |

That is **+1,522 MiB**, not +435 MiB.

**What it actually bought.** Nothing - it was slower. Same 16,908-token prompt,
two runs each:

| config | prefill | throughput |
| --- | --- | --- |
| ub=512 | 25.94 s | **652 tok/s** |
| ub=2048 | 26.88 s | 629 tok/s |
| ub=512 (repeat) | 26.11 s | **648 tok/s** |
| ub=2048 (repeat) | 26.94 s | 628 tok/s |

**Verdict: rejected.** 1.5 GiB of VRAM for a 3% throughput *loss*. The likely
reason is that gemma4 is a sliding-window hybrid: a larger ubatch does not help
when attention is already windowed, and the bigger compute buffer costs cache
locality. Do not revisit this without a different model architecture.

### 4.2 `OLLAMA_KV_CACHE_TYPE=q8_0` - works, saves 2.7 GB, quality holds

**The idea.** Quantize the KV cache from f16 to q8_0 to halve it.

**Measured saving.** The KV cache is larger than the earlier report claimed -
**3,008 MiB**, not 3,008 total across both buffers as assumed. With q8_0:

| | f16 (default) | q8_0 |
| --- | --- | --- |
| KV buffer (non-SWA) | 2,048 MiB | **1,088 MiB** |
| KV buffer (SWA) | 960 MiB | **510 MiB** |
| context total | 3,008 MiB | **1,598 MiB** |
| compute | 185 MiB | 384 MiB |
| **total** | **9,831 MiB** | **8,620 MiB** |

**Saving: 1,211 MiB** (9,831 → 8,620). The env var is honoured - the runner logged
`K (q8_0): 544.00 MiB, V (q8_0): 544.00 MiB`.

**Quality test.** Four deterministic prompts (temperature 0), fp16 vs q8_0:

| test | result |
| --- | --- |
| structured JSON output | **identical** |
| arithmetic (90 + 12 − 5 + 8) | **identical** (`105`) |
| tool-call-shaped JSON | **identical** |
| 3-bullet instruction | wording differs, both valid |

**Long-context test.** KV quantization error accumulates with context length, so a
7,554-token document with one fact buried mid-document:

| | answer |
| --- | --- |
| fp16 | `4,750,000 RMB` ✅ |
| q8_0 | `4,750,000 RMB` ✅ |

**Verdict: viable, and now measured on a real corpus.** It is a real saving with no
observed quality loss. It is still not shipped, for one reason only: the box
currently has 6.4 GiB of VRAM free, so the saving buys nothing today. If VRAM ever
becomes the binding constraint, this is the first lever to pull.

**Real-corpus confirmation (2026-10-21, later the same day).** The 5-prompt test
above was not evidence enough to ship, so it was extended to a real document: the
8,002-character Chinese data-governance section actually stored in this deployment
(`data/tenants/.../docs/presented-data-governance-section_v1.md`). Eight
deterministic questions (temperature 0) that require reading the document - six
numeric retention/destruction facts spread across its length, one needle at the
tail, one principle stated near the top:

| KV type | runner size at ctx 32768 | quality |
| --- | --- | --- |
| f16 (default) | **9.7 GB** | 8/8 |
| q8_0 | **7.0 GB** | 8/8 |

**2.7 GB saved at identical context, 8/8 on both.** The runner-size figures are
`ollama ps` readings at the same `num_ctx`, which is a stronger measurement than
the buffer arithmetic above because it is what the scheduler actually reserves.

**How it was tested without touching the machine.** The first attempt set
`OLLAMA_KV_CACHE_TYPE` as a User environment variable - which is exactly the
machine-wide change this investigation exists to avoid, and it was reverted
immediately. The correct method is a second `ollama serve` on its own port with
the variable scoped to that process:

```powershell
$env:OLLAMA_KV_CACHE_TYPE = 'q8_0'
$env:OLLAMA_HOST = '127.0.0.1:11435'
ollama serve
```

The scoped server's own startup log confirms `OLLAMA_KV_CACHE_TYPE:q8_0`, and the
main server on 11434 is untouched. That is the pattern to use for any future
Ollama experiment on a shared machine.


### 4.3 Tool description compression - measured 47%, but the wrong lever now

**The idea.** Shorten tool descriptions to cut the bound schema.

**Measured.** Keeping only the first paragraph, capped at 240 chars:

| | chars | ~tokens |
| --- | --- | --- |
| current | 42,582 | 10,645 |
| first-paragraph only | 22,178 | 5,544 |
| **saving** | | **47%** |

**Why it is rejected.** The descriptions carry real usage guidance, not padding:

- `officecli` (4,002 chars) contains the **delivery gate** - validate clean, check
  `view issues`, then a visual screenshot audit - plus the `load_skill` routing
  table. Truncating it removes the instructions that stop the agent delivering a
  broken document.
- `openviking_add_resource` (2,395 chars) documents the async upload handshake and
  the `args={"site": true}` flag. Truncating it produces wrong calls.
- A duplicate-sentence scan found **zero** redundancy in 8 of 9 large descriptions.

**And it is now redundant.** Deferral already removes 73% of the bound surface
(10,645 → 2,823 tokens) **without losing any description text** - the full schema
is fetched on demand. Compression would save a further ~1,300 tokens while
destroying the guidance. That is the wrong trade.

**Verdict: rejected.** Deferral dominates it on both axes.

---

## 5. Recommended next steps

Ordered by value per unit of risk. Items 1–3 are already done and verified.

| # | action | status | why |
| --- | --- | --- | --- |
| 1 | Standard tags, no derived tags | **done** | removes 15.9 s reloads and 13 evictions/day |
| 2 | `tool_search` deferral + transparency patch | **done** | 73% of the prompt surface, no quality loss |
| 3 | Prompt-cache cap (`LLAMA_ARG_CACHE_RAM`) | **done** | bounds 6.5 GiB of host RAM |
| 4 | Run a real workflow end-to-end | **done** | see 5.1 - a live run called two deferred MCP tools with no promotion error |
| 5 | Extend the q8_0 quality test to a real corpus | **done** | 8/8 on both f16 and q8_0 against a real 8k Chinese document; 2.7 GB saved at ctx 32768. Still not shipped: VRAM is not the binding constraint today |
| 6 | WSL ceiling at a maintenance window | optional | not needed at steady state (32 GiB available) |
| 7 | Larger `-ub` | **do not** | measured slower, +1.5 GiB |
| 8 | Description compression | **do not** | dominated by deferral, destroys guidance |

### 5.1 The live end-to-end run (item 4, now closed)

The deferral patch had only unit-level proof. It has now carried a real workflow.

**Setup.** `POST /pacgate/api/workflows/00000000-0000-0000-0000-000000001002/execute`
against a freshly created matter, through nginx on 8089. HTTP 200.

**What the run did.** The response reported:

```
tools_used: list_documents, kb_search, kb_search
max_rounds_reached: False
```

Both are `pacgate-mcp` tools (`pacgate_list_documents`, `pacgate_kb_search` in
`pacgate-mcp:/app/server.py`), so both are MCP-sourced and therefore in the
deferred set. They executed. The response contains no "deferred, not promoted"
error, and the run did not hit the round cap.

**The schema reduction, measured against the real catalog.** The earlier 73%
figure came from the full bound surface including sandbox tools. Re-measured
inside the running container against the actual 19-tool `pacgate-mcp` catalog:

| | chars |
| --- | --- |
| all 19 MCP schemas + builtins bound | 11,514 |
| builtins + `tool_search` only | 840 |
| **reduction** | **92.7%** |

The 73% figure was conservative because it counted the sandbox tools as part of
what deferral removes; they are not removed, and should not be. Against the MCP
half alone the saving is 92.7%.

**Two corrections to earlier notes in this document:**

1. The `.env` password was never wrong. Login failed because the API is behind
   nginx at `http://localhost:8089/pacgate/...`, not `http://localhost:8080/...`.
   The credentials in `.env` work as shipped.
2. The bind mount is live without a container restart. Docker bind mounts are
   resolved at container creation, but the *file contents* are read at import
   time, so a running container picks up an edited patch on the next process
   start. Verified: the running container's middleware is the patched file
   (`grep -c _promotion_command` → 3) even though the container started before
   the mount was added to compose.


### Why the live run mattered

Everything shipped is verified at the unit level: the middleware promotes and
executes on all four paths, the reducer merges correctly, the bound set is 10 tools,
and five gates pass. What had **not** happened was a live agent run that calls a
deferred MCP tool and completes. That is the exact scenario the 2026-09-12 note said
was broken, so it deserved a real run rather than an inference from unit tests.

That run has now happened (5.1) and passed. The fallback if it had failed was one
line - set `tool_search.enabled: false` - and `test-tool-search-deferral.ps1` fails
loudly rather than letting the regression pass silently.

**CLOSED 2026-10-21.** The `Auto-promoting deferred tool ...` line never appeared
in the first live run, because the model called `tool_search` itself rather than
calling a deferred tool directly. That was not a middleware defect - the
middleware promoted correctly all along - it was a missing instruction. The
`<available-deferred-tools>` section rendered a bare list of names with no
instruction verb at all, and `tool_search`'s own description says a name is not
callable "until fetched", so the model fetched first. The transparent path
existed but was never selected.

`patches/deer-flow-tool-search-prompt.py` now renders both paths, direct first:

```
These tools are callable DIRECTLY by name, with their normal arguments.
Calling one promotes its schema automatically for later turns - there is no
need to fetch it first. Use `tool_search` only when you need to read a full
schema before calling, or to discover a tool not listed here.
```

Observed in a live run, 2026-10-21 13:31, deer-flow gateway, `gemma4:12b-it-qat`:

```
Auto-promoting deferred tool 'pacgate_pacgate_kb_search' on first call (tool_search deferral is transparent)
Auto-promoting deferred tool 'pacgate_pacgate_list_matters' on first call (tool_search deferral is transparent)
Auto-promoting deferred tool 'pacgate_pacgate_kb_search' on first call (tool_search deferral is transparent)
```

The run called three deferred tools directly and `tool_search` **zero** times, so
the path that had never fired is now the path the model chooses. `R7` in
`test-deferred-tool-runtime.ps1` asserts the rendered text so this cannot regress
silently; a middleware-only test could not have caught it.



---

## 6. Gates added

| gate | asserts |
| --- | --- |
| `scripts/test-tool-search-deferral.ps1` | deferral stays enabled; the patch keeps promote-and-execute on both sync and async paths; the old error message is gone; handler `Command` updates are merged; sandbox tools stay always-bound |
| `scripts/test-host-memory-budget.ps1` | the prompt cache stays capped in all four tiers; model selection stays report-only; the installer never writes `.wslconfig` or the shared Ollama setting |
| `scripts/measure-deerflow-lanes.ps1` | read-only probe: resident runners, host commit vs WSL ceiling, bound tool surface, llama.cpp prefill/decode/reuse, churn counters, recent run token totals |

`scripts/test-ollama-context-scope.ps1` was updated: it used to assert the derived-tag
mechanism existed, which is now the opposite of what is wanted.
