# AIPC capacity verdict - AMD HX370, 32 GB unified, 16 GB RX 7600 XT

**Question:** after all the fixes, does this still deploy and run on the actual
AIPC hardware (Ryzen AI HX370, 32 GB DDR5 unified, M890 iGPU + RX 7600 XT 16 GB
dGPU), rather than only on this 128 GB dev box?

**Short answer: yes, with one specific change needed and one number in my own
previous report corrected.** The arithmetic below is from measurements taken on
the assembled stack, not estimates.

---

## 0. Correction: the container footprint I reported was wrong

I reported "~6.1 GiB idle footprint" in
`deploy/REINSTALL-AND-BENCHMARK-2026-10-19.md`. That figure was wrong: it summed
`MemUsage` **including the `/ limit` half of the string** for containers that have
a limit. Re-measured twice, usage only:

| Container | MiB |
|---|---|
| pacgate-api | 1373.2 |
| ocr-service | 981.1 |
| openviking | 577.8 |
| deer-flow-frontend | 387.4 |
| deer-flow | 265.5 |
| qm-pacgate-core | 148.7 |
| qm-pacgate-pg | 115.7 |
| pacgate-mcp | 75.4 |
| qm-pacgate-admin | 42.3 |
| pacgate-db | 38.6 |
| qm-pacgate-web-ui | 36.9 |
| pacgate-nginx | 36.0 |
| qm-pacgate-auth | 34.0 |
| qm-pacgate-portal | 28.5 |
| qm-mailpit | 17.6 |
| **TOTAL** | **4,160 MiB = 4.06 GiB = 4.36 GB** |

`docker stats` was taken twice and agreed to 2 MiB. The corrected figure is used
throughout below; the old report is superseded on this point.

---

## 1. The arithmetic for a 32 GB unified machine

Windows on a 32 GB machine realistically leaves **~24 GB** for Docker + Ollama
(8 GB to the OS, compositor, driver working set). Budgeting 25% is the
conservative end of the usual 20-25%.

### VRAM is shared with the host

This is the part that is easy to get wrong on an APU. The HX370 has **unified
memory**: the iGPU and the OS draw from the same 32 GB, and the 16 GB RX 7600 XT
is a separate discrete pool. So:

- **16 GB dGPU** = dedicated VRAM, models land here first.
- **32 GB system RAM** = containers + OS + whatever the dGPU cannot hold.

### Scenario A - one utility model resident (the normal steady state)

All three utility lanes (title, memory, summarization) and OpenViking's VLM are
pinned to `gemma4:12b-it-qat`; embeddings use `nomic-embed-text`; chat is cloud.

| Component | GB |
|---|---|
| Containers (measured) | 4.36 |
| `gemma4:12b-it-qat` weights | 7.20 |
| `nomic-embed-text` | 0.27 |
| **Total system RAM** | **11.83 GB of ~24 GB (49%)** |
| **VRAM used** | **7.47 GB of 16 GB** |

**Fits comfortably.** ~12 GB free for page cache and burst.

### Scenario B - utility model + Mid tier resident together

Ollama keeps models loaded (`OLLAMA_KEEP_ALIVE=30m` machine-wide on this box) and
its default `OLLAMA_MAX_LOADED_MODELS` allows more than one. If a Mid-tier
`ornith-1.5:9b` run happens while the utility model is warm, both stay resident.

| Component | GB |
|---|---|
| Containers | 4.36 |
| `gemma4:12b-it-qat` | 7.20 |
| `ornith-1.5:9b` | 6.60 |
| `nomic-embed-text` | 0.27 |
| **Total system RAM** | **18.43 GB of ~24 GB (77%)** |
| **VRAM used** | **14.07 GB of 16 GB** |

**Still fits, on both axes** - 14.07 GB of 16 GB VRAM, 77% of system RAM. But the
margins are thin enough that it is worth pinning behaviour rather than relying on
luck (see §3).

### Where it would NOT fit

For reference, the models this session withdrew would have broken both axes:

| Model | GB | Verdict on 16 GB dGPU |
|---|---|---|
| `qwen3.8:27b-mtp-q4_K_M` | 17.00 | over 16 GB VRAM - spills |
| `ornith-1.5:35b` | 22.00 | over 16 GB VRAM - spills |
| `nemotron-3.5-lightning:30b-a3b` | 25.00 | over 16 GB VRAM - spills |

With `gemma4` at 7.2 GB, adding any one of these puts VRAM at 24.5-32.5 GB against
a 16 GB card. That is the stall the earlier work removed, and the capacity gate now
blocks it in the suite.

---

## 2. What is genuinely at risk on the AIPC (and is not on this box)

Measured facts, not speculation:

**a. `pacgate-api` is the largest container at 1.37 GiB** and it carries a **4 GiB
`mem_limit`** in both compose files. That limit is fine on the dev box; on a
32 GB machine it caps at 4 GiB while usage is 1.37 GiB, so it is not the
constraint. But note the API loads **389 MB of NER weights** into that budget, and
NER is the kind of thing that grows with document size. Watch it, do not cap it
lower.

**b. `ocr-service` at 981 MiB** holds PaddleOCR weights baked into the image. Its
memory is steady-state, not per-document growth. Fine.

**c. Ollama residency is the real lever, and it was unset in the repo.**
`OLLAMA_KEEP_ALIVE` and `OLLAMA_MAX_LOADED_MODELS` appear **nowhere** in the repo -
this dev box has `OLLAMA_KEEP_ALIVE=30m` set at machine level. On a fresh AIPC,
Ollama's own defaults apply. See §3 for what those defaults are and why they are
wrong here.

---

## 3. CORRECTED 2026-10-20: what the residency knobs should actually be

This section previously recommended `OLLAMA_MAX_LOADED_MODELS=1`. **That was
wrong, and the client asked the right question.** Everything below is measured on
Ollama 0.40.6 rather than reasoned from the docs.

### 3.1 `OLLAMA_MAX_LOADED_MODELS=1` is not the lever - and it is harmful

Two facts kill the old recommendation:

**The default is already 3, not 1.** In `server/sched.go` (v0.40.6, line 127):

```go
var defaultModelsPerGPU = 3
```

and at line 335 it is applied as `defaultModelsPerGPU * max(len(g), 1)`. So the
cap is *already* 3 per GPU before anyone sets anything.

**The binding limit is a memory-fit check, not this cap.** From the scheduler's own
log on this box while loading a second 6.2 GiB model:

```
msg="llama-server model predicted to exceed available memory, evicting"
predicted="6.2 GiB" predicted_num_ctx=8192 num_batch=512
available="6.0 GiB" gpu_free="100.6 GiB" system_free="6.0 GiB"
system_limited=true
```

`gpu_free` was **100.6 GiB** - VRAM was never the constraint. `system_limited=true`
says system memory was.

**Proof that forcing 1 causes eviction that would not otherwise happen:** with an
isolated server at `MAX_LOADED_MODELS=1`, loading `gemma4` (7.1 GiB) evicted a
resident `ornith-1.5:9b` (5.35 GiB) even though free VRAM was ~100 GiB. At
`MAX_LOADED_MODELS=2` the pair still had to pass the memory-fit test, but the cap
stopped being the reason. Setting `1` makes eviction *unconditional* - the
opposite of what was intended.

### 3.2 The two things that actually were wrong: context and parallel slots

**`OLLAMA_CONTEXT_LENGTH` was unset, so it auto-picked each model's own maximum.**
Nothing we ship ever sends `num_ctx`: deer-flow sends only `max_tokens`/`temperature`,
and `pacgate-llm` posts to `/v1/chat/completions`, whose request body has no
`num_ctx` field. Measured residency of the *same* weights:

| `num_ctx` | `ornith-1.5:9b` | `gemma4:12b-it-qat` |
|---|---|---|
| 8192 | 5.35 GB | 7.60 GB |
| 16384 | 5.61 GB | 7.61 GB |
| 32768 | 6.12 GB | 7.63 GB |
| 65536 | 7.15 GB | 7.66 GB |
| **262144 (the auto default)** | **13.34 GB** | ~7.9 GB |

The KV cache alone was **8 GB of avoidable residency** on the Mid tier. gemma4 is
QAT/weight-dominated and barely moves, which is why context tuning looked useless
when only gemma4 was measured.

`OLLAMA_CONTEXT_LENGTH` **does** apply to the OpenAI-compatible endpoint our two
clients use - verified by watching `context_length` go `262144 -> 16384` in
`ollama ps` after a `/v1/chat/completions` call. It is the only lever that reaches
both `pacgate-api` and `deer-flow`.

**`OLLAMA_NUM_PARALLEL` defaulted to 1 - one server slot per model.** Three
concurrent utility calls were strictly serialised:

| Configuration | wall | result |
|---|---|---|
| `NUM_PARALLEL=1` (default) | **5.35 s** | 1.63 / 3.02 / 4.32 s, queued |
| `NUM_PARALLEL=3` | **2.88 s** | 1.99 / 1.99 / 1.92 s, overlapped |

That serialisation *is* the "hangs with no generation" symptom: a title call, a
memory update and a summarizer queue behind the user's own chat on one slot.

### 3.3 The dominant cause of "no generation" was neither knob

It was a missing request field. gemma4 is thinking-capable, and **neither client
suppressed the reasoning channel on local models**. deer-flow's two *cloud* entries
have carried `reasoning_effort: none` since 2026-10-09; the three *local* entries
never did, and `pacgate-llm` had no such field at all.

Measured on `gemma4:12b-it-qat`, title-shaped prompt, `max_tokens=200`:

| request | wall | tokens | content |
|---|---|---|---|
| no `reasoning_effort` | **7.7 s** | 200/200 | **"" (`finish=length`)** |
| `reasoning_effort: "none"` | **0.48 s** | 9 | clean title |

16x the latency for **zero output**, on every title, memory and summarization
call - and it holds the Ollama slot for all 7.7 s, so concurrent lanes queue behind
a call that produces nothing. A four-lane burst (title + memory + summarizer +
embed) that took **10.75 s and returned three empty strings** now completes in
**2.51 s with real output**.

### 3.4 What is now shipped

Two layers, deliberately separated so Pacgate does not reconfigure a **shared**
Ollama server that other tools also use:

**Layer 1 - machine-wide env vars** (`install.ps1` step 2b, user-level, then one
Ollama restart). These are genuine server-tuning knobs, not model policy:

| Tier | OS-visible RAM | MAX_LOADED | NUM_PARALLEL |
|---|---|---|---|
| high | >= 56 GiB | 3 | 2 |
| standard | 24-55 GiB | 2 | 2 |
| constrained | < 24 GiB | 1 | 1 |

plus `OLLAMA_KEEP_ALIVE=15m`. The AIPCs land in **standard**.

**Layer 2 - per-model context pin.** This is the part that changed, and the
first version of it was wrong in an important way.

*The trap:* the Ollama **desktop app** stores a machine-wide `context_length` in
`%LOCALAPPDATA%\Ollama\db.sqlite` and passes it to the server it spawns, where it
**overrides** `OLLAMA_CONTEXT_LENGTH`. Verified both directions on this box:
`env=32768, db=131072` -> server started at **131072**; `env=32768, db=32768` ->
server started at **32768**. So writing only the env var is a **no-op** on any
machine where the app has been run.

*What not to do:* rewriting that shared value works, but it silently changes
behaviour for **every other consumer** of that Ollama server. Pacgate is not the
only thing on these machines. That was the wrong boundary to cross.

*What is done instead:* `ollama create` a derived tag with `PARAMETER num_ctx`
baked in. Verified scope:

| tag | ctx | size | effect on others |
|---|---|---|---|
| `pacgate-mid` (from `ornith-1.5:9b`) | 32768 | 6.12 GB | none |
| `pacgate-low` (from `gemma4:12b-it-qat`) | 32768 | 7.63 GB | none |
| `ornith-1.5:9b` (shared, unchanged) | 131072 | 9.22 GB | keeps the app's setting |
| `gemma4:12b-it-qat` (shared, unchanged) | 131072 | 7.72 GB | keeps the app's setting |

The shared app value stayed at **131072** across the whole change. The derived
tags share the base models' blobs, so they cost no extra disk.

**Why a pinned tag is needed at all:** the OpenAI-compatible endpoint that both
`pacgate-llm` and `deer-flow` use accepts **no** per-request context control.
Verified: `options.num_ctx` and a top-level `num_ctx` on `/v1/chat/completions`
were both **ignored** (model still loaded at 131072, 9.22 GB). `/api/generate`
does honour `num_ctx`, but neither client can use that endpoint.

**Where the pinned tag is configured:** `install.ps1` writes
`PACGATE_MODEL_MID` / `PACGATE_MODEL_LOW` into `.env`, not into the repo defaults.
A derived tag exists only on a machine where the installer has run, and it cannot
be pre-pulled from any registry - so a repo default naming it would 404 on a
machine that never ran the installer. `test-model-roster-consistency.ps1` caught
exactly that when the first version put the pinned tag in the compose default.

**32768, not 16384**, because deer-flow escalates local->local at a
`message_token_threshold` of 40000; a 16k cap would make that escalation
structurally unreachable, while 32k still fires it just before the window fills.

### 3.5 The hardware label was the trap

The dev box is documented as "128 GB". Its DIMMs really are 8 x 16 GiB at
8000 MT/s, and the iGPU's registry entry really is 96 GiB dedicated. But **Windows
only ever sees 31.65 GiB**, because the UMA carve-out is taken before the OS boots:

```
Win32_OperatingSystem.TotalVisibleMemorySize : 31.65 GiB
Win32_ComputerSystem.TotalPhysicalMemory      : 31.65 GiB
systeminfo: Total Physical Memory: 32,407 MB
Win32_PhysicalMemoryArray.MaxCapacity         : 64 GiB  (8 devices)
bcdedit: no truncatememory / removememory limit
```

So the "128 GB dev box" and a "32 GB AIPC" are in the **same** residency bucket.
Any tiering keyed on DIMM total would have sized the dev box as 4x the AIPC and
shipped the wrong profile. This is also why the earlier arithmetic in §1 - which
assumed ~24 GB usable on the AIPC and treated the dev box as roomy - needs reading
with that correction in mind: both classes are ~32 GB to Ollama.

This is a **configuration** change, not code, so it reaches machines via
`install.ps1 -Update` without an image rebuild. The reasoning-suppression fix is
code (it is in `pacgate-llm`), so that half does need 0.1.34 images.

**Still not measured, therefore not claimed:** I have not run any of this on an
HX370. The model sizes and container footprint are measured; the HX370's actual
Windows reservation and its 16 GB discrete-card behaviour are not. One benchmark on
AIPC 1 remains the step that turns this from arithmetic into validation.


---

## 4. What this means for the earlier claims

| Earlier claim | Status after this check |
|---|---|
| "~6.1 GiB idle footprint" | **Wrong.** Measured 4.06 GiB usage-only. My error, corrected above. |
| "Most of a 16 GB card's budget on an AIPC" | **Overstated for scenario A.** 7.47 GB of 16 GB VRAM is comfortable. It becomes tight only in scenario B (14.07 GB). |
| "Set `OLLAMA_MAX_LOADED_MODELS=1`" | **Wrong, and withdrawn.** The default is already 3, the binding limit is a memory-fit check (`system_limited=true`), and forcing 1 makes eviction unconditional. See §3.1. |
| "Ollama residency is the one gap" | **Incomplete.** The larger cause of "no generation" was a missing `reasoning_effort` field, giving 7.7 s and empty content instead of 0.48 s and a result. See §3.3. |
| "The dev box is a 128 GB machine, the AIPCs are 32 GB" | **Wrong for sizing purposes.** Windows only sees 31.65 GiB of the dev box's 128 GiB, because the iGPU UMA carve-out is taken pre-boot. Both classes are ~32 GB to Ollama. See §3.5. |
| Five `jzkk720` images + repo content ship in 0.1.33 | Unchanged, still correct. |
| qm and OpenViking are digest-pinned vendor images | Unchanged, still correct - and this is why their **containers** count toward the 4.06 GiB but their **weights** do not exist. |
| All 43 gates pass | Unchanged, plus one new gate (`test-installer-self-update.ps1`, 11 assertions) for the stale-script defect in §6. |

---

## 5. Found while implementing §3: `-Update` could not deliver early steps

While wiring the residency step in, a separate defect surfaced that affects every
future installer change:

**PowerShell parses an entire script before executing line 1.** `install.ps1 -Update`
refreshes the repo at step 3b, which *replaces the file on disk* - but the run
continues executing the old body from memory. Every step defined **before** the
refresh (1, 2, 2b, 3, 3b itself) therefore ran from the **previous** version.

Consequence: install-logic fixes were non-deliverable in one command. The Ollama
residency step in this change would have been **skipped on the very update that
introduced it**, and an operator would have had to run `install.ps1 -Update` a
second time by hand.

Fixed with a hash-keyed one-shot handoff (step 3c): the script stamps the hash of
the body it is running at entry, compares it to the file now on disk after the
refresh, and re-execs once when they differ. It cannot loop because the handoff is
keyed to content, and the refresh only ever fast-forwards a clean tree.

`scripts/test-installer-self-update.ps1` proves it with a control that reproduces
the loss, so the test cannot pass vacuously:

| scenario | log | outcome |
|---|---|---|
| without handoff (control) | `gen1 early \| gen1 late` | the new step is **LOST** |
| with handoff (fix) | `gen1 early \| gen2 early \| gen2 late` | the new step **RUNS** |

---

## 6. Bottom line

- **Containers:** 4.36 GB measured. Not a problem on 32 GB.
- **Models:** the shipped set (7.2 GB + 6.6 GB + 0.27 GB) fits a 16 GB dGPU
  whether one or two are resident.
- **The 25/22/17 GB models that would have broken it are gone**, and enforced gone.
- **`OLLAMA_MAX_LOADED_MODELS=1` was the wrong answer** and is withdrawn. The
  real levers are `OLLAMA_CONTEXT_LENGTH` (auto-picked 262144, costing 8 GB of
  KV cache on the Mid tier) and `OLLAMA_NUM_PARALLEL` (default 1, serialising
  every concurrent utility call).
- **The biggest single defect was not a residency knob at all**: local models
  received no `reasoning_effort: none`, so they burned the full token budget on
  hidden reasoning and returned empty content after ~16x the latency.
- **Everything above is arithmetic over measured inputs, not a run on an HX370.**
  One benchmark on AIPC 1 is the remaining step to call this validated.

