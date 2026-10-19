# AIPC capacity verdict - AMD HX370, 32 GB unified, 16 GB RX 7600 XT

**Question:** after all the fixes, does this still deploy and run on the actual
AIPC hardware (Ryzen AI HX370, 32 GB DDR5 unified, M890 iGPU + RX 7600 XT 16 GB
dGPU), rather than only on this 128 GB dev box?

**Short answer: yes, with one specific change needed and one number in my own
previous report corrected.** The arithmetic below is from measurements taken on
the assembled stack, not estimates.

---

## 0. Corection: the container footprint I reported was wrong

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

**c. Ollama residency is the real lever, and it is currently unset in the repo.**
`OLLAMA_KEEP_ALIVE` and `OLLAMA_MAX_LOADED_MODELS` appear **nowhere** in the repo -
this dev box has `OLLAMA_KEEP_ALIVE=30m` set at machine level. On a fresh AIPC,
Ollama's own defaults apply and are not chosen for a 16 GB card. Scenario B only
fits *because* the two models are 7.2 and 6.6 GB; a third resident model, or a
larger Mid tier, flips it over.

---

## 3. The one change recommended before shipping to AIPC

**Set the residency knobs explicitly, so behaviour is not left to Ollama's
defaults.** Two lines in the client env documentation, applied by the installer:

```
# Ollama keeps a model warm for 30m by default on this dev box, and by default
# will hold more than one resident. On a 16 GB AIPC that is the difference
# between 7.5 GB and 14.1 GB of VRAM. Pin it.
OLLAMA_KEEP_ALIVE=15m
OLLAMA_MAX_LOADED_MODELS=1
```

Rationale for each:

- `OLLAMA_MAX_LOADED_MODELS=1` guarantees a Mid-tier run **evicts** the utility
  model rather than stacking on top of it. Eviction costs a reload (~2-4 s for
  7.2 GB from page cache) and saves 6.6 GB of VRAM. On a 16 GB card that trade is
  correct: a reload is a pause, an over-committed card is a stall.
- `OLLAMA_KEEP_ALIVE=15m` halves the idle hold time. The utility lanes fire on
  message boundaries, so 15m still catches bursts without pinning 7.2 GB for half
  an hour after someone stops typing.

This is a **configuration** change, not code, so it reaches machines via
`install.ps1 -Update` without an image rebuild.

**Not measured, therefore not claimed:** I have not run this on an HX370. The
arithmetic above is sound because both inputs (container footprint, model sizes)
are measured, but the *behaviour* - reload latency under `MAX_LOADED_MODELS=1`,
and whether Windows reserves closer to 20% or 25% - needs one run on real hardware
before it is called validated.

---

## 4. What this means for the earlier claims

| Earlier claim | Status after this check |
|---|---|
| "~6.1 GiB idle footprint" | **Wrong.** Measured 4.06 GiB usage-only. My error, corrected above. |
| "Most of a 16 GB card's budget on an AIPC" | **Overstated for scenario A.** 7.47 GB of 16 GB VRAM is comfortable. It becomes tight only in scenario B (14.07 GB). |
| Five `jzkk720` images + repo content ship in 0.1.33 | Unchanged, still correct. |
| qm and OpenViking are digest-pinned vendor images | Unchanged, still correct - and this is why their **containers** count toward the 4.06 GiB but their **weights** do not exist. |
| All 43 gates pass | Unchanged. Note the capacity gate now enforces the model-size half of this analysis on every run. |

---

## 5. Bottom line

- **Containers:** 4.36 GB measured. Not a problem on 32 GB.
- **Models:** the shipped set (7.2 GB + 6.6 GB + 0.27 GB) fits a 16 GB dGPU
  whether one or two are resident.
- **The 25/22/17 GB models that would have broken it are gone**, and enforced gone.
- **One gap remains:** Ollama residency limits are unset in the repo, so an AIPC
  inherits defaults that are not tuned for a 16 GB card. Pin them.
- **Everything above is arithmetic over measured inputs, not a run on an HX370.**
  One benchmark on AIPC 1 is the remaining step to call this validated.
