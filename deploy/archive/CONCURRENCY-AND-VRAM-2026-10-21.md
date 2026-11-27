# Concurrency and VRAM: root cause, refuted hypothesis, and the correct fix

**Date:** 2026-10-21
**Machine:** HX370 (`CUBECLOUD01`) — **RX 7600 XT 15.98 GB** VRAM, 61.6 GiB RAM,
Docker VM 24 CPU / 30.17 GiB, Ollama 0.40.6
**Residency:** `NUM_PARALLEL=2`, `MAX_LOADED_MODELS=2`, `KEEP_ALIVE=15m`,
`KV_CACHE_TYPE` and `FLASH_ATTENTION` **unset** (fp16 KV cache)

**This supersedes the capacity section of
`MODEL-REGRESSION-AND-CAPACITY-2026-10-21-v0.1.34.md`.** That report's *measurement*
was right, but its *conclusion* — "pick one local model; let cloud carry
concurrency" — was derived from a premise I had not tested. It is corrected below.

---

## 1. What was wrong with the first conclusion

The first report said:

> `pacgate-mid` (6.7 GB) + `pacgate-low` (9.7 GB) = 16.4 GB against 15.98 GB.
> Therefore only one local chat model can be resident. Pick one.

Two problems:

1. **The sum is not a budget.** It assumed `ollama ps` sizes are additive and
   complete. §4 shows they are neither.
2. **It answered the wrong question.** Concurrency never required two resident
   models. §5 measures concurrency that already works with one.

The measured *symptom* was real — `pacgate-mid` genuinely is evicted when
`pacgate-low` loads. The *prescription* was wrong.

---

## 2. Phase 1 — reproduced the anomaly that started this

`pacgate-low` (derived, `PARAMETER num_ctx 32768`) reported **9.7 GB**.
`gemma4:12b-it-qat` (its base, machine-wide ctx 65536) reported **8.2 GB**.

Same blobs — verified with `ollama show … --modelfile`; the *only* difference is the
`num_ctx` line. **Requesting less context used 1.5 GB more.** That inverts the naive
KV-cache model, so I could not accept either the 9.7 figure or a plan built on it
until it was explained.

Re-measured with everything unloaded (`ollama stop` each), one model at a time.
**Reproduced in isolation** — so contamination was ruled out.

---

## 3. Phase 2 — the context→memory curve

Swept `options.num_ctx` on `gemma4:12b-it-qat`, unloading between each:

| `num_ctx` | 2048 | 4096 | 8192 | 16384 | **32768** | **65536** |
| --- | --- | --- | --- | --- | --- | --- |
| resident size | 8.2 | 8.6 | 8.6 | 8.7 | **9.7 GB** | **8.2 GB** |

**Non-monotonic, and 32768 is the worst point on the curve.** Going from 32768 to
65536 *releases* 1.5 GB.

Same sweep on `ornith-1.5:9b` (no vision) scales sanely:

| `num_ctx` | 8192 | 32768 | 65536 |
| --- | --- | --- | --- |
| size | 5.9 | 6.7 | 7.7 GB |

So the anomaly is **specific to gemma4**, which carries `vision` capability and a
**projector** (`ollama show` reports `Capabilities: completion, vision, audio,
tools, thinking` plus a `Projector` section). The most likely mechanism is that the
vision projector and the KV allocation interact, and the allocator rounds
differently at different `num_ctx` values. I have **not** proven that mechanism —
only that the reported footprint is not a monotonic function of context, which is
enough to invalidate planning arithmetic based on it.

---

## 4. Phase 3 — hypothesis tested and REFUTED

**Hypothesis:** if 32768 costs 9.7 GB but 65536 costs 8.2 GB, then pinning at 65536
saves 1.5 GB, and `mid (6.7) + low-64k (8.2) = 14.9 GB` fits in 15.98 GB — so both
models could coexist.

**Test:** built a candidate tag `pacgate-low-64k` (`PARAMETER num_ctx 65536`),
without touching the shipped pin.

| step | result |
| --- | --- |
| candidate alone | **8.2 GB**, ctx 65536 ✅ (the 1.5 GB saving is real) |
| shipped pin alone | 9.7 GB, ctx 32768 |
| `mid` alone | 6.7 GB |
| **`mid` + candidate** | **`mid` EVICTED** ❌ |

**The hypothesis was wrong.** 6.7 + 8.2 = 14.9 GB "should" fit and does not.

**What that proves:** `ollama ps` **under-reports** actual GPU allocation. The real
footprint includes the vision projector, KV for **both** `NUM_PARALLEL` slots, and
allocator granularity — none of which appear in the `SIZE` column. Treating those
numbers as additive is the mistake that produced the original bad advice.

> **Operational rule: never plan VRAM capacity by summing `ollama ps` sizes.**
> Measure coexistence empirically, by loading the combination.

---

## 5. Phase 4 — the lever that actually matters

If two resident models were never the mechanism for concurrency, what is?

`NUM_PARALLEL=2` lets **one** resident model serve two requests at once. Measured on
`pacgate-low`, warm, after excluding load time:

| Test | Result |
| --- | --- |
| 2 calls **sequential** | 3.6 s + 4.2 s = **7.8 s wall** |
| 2 calls **parallel** | 3.9 s + 5.0 s = **5.0 s wall** → **1.57× speed-up** |
| 3 calls parallel | 6.6 s wall (third queues onto the 2nd slot, as designed) |
| chat **+** embedding together | chat 4.4 s, embed 3.1 s, **4.4 s wall**, both `100% GPU` |

So **concurrency already works**, with a single local model resident. The
`.env.example` rationale for `NUM_PARALLEL=2` is exactly right: at `NUM_PARALLEL=1`
three concurrent utility calls serialised to 5.35 s wall.

This is the correction that matters: **"pick one local model" was not a sacrifice.**
One model with 2 slots *is* the concurrency design, and two resident models were
never needed for it.

---

## 6. The corrected guidance

Replace the earlier "pick one model" with:

1. **Keep `NUM_PARALLEL=2`.** It is the concurrency mechanism, proven at 1.57×.
   Do not lower it to 1.
2. **Route by role, not by residency.** Local models are utility (title, memory
   update, summarizer, VLM); cloud carries main prompting. This is the documented
   architecture, and cloud adds **zero local VRAM** — measured at 2.9 s wall while a
   local model stayed resident.
3. **Expect one resident local chat model.** That is normal and sufficient. Do not
   try to keep `pacgate-mid` and `pacgate-low` resident simultaneously; the pair is
   evicted regardless of pin.
4. **Do not lower `OLLAMA_MAX_LOADED_MODELS` to 1 to "prevent" eviction.** The repo's
   own notes record that `MAX=1` evicted a resident model *with 100 GiB free*,
   because the binding limit is a memory-fit check, not the cap. Leave it at 2 and
   let the scheduler decide.
5. **If VRAM is tight and the VLM is only used intermittently**, the 9.7 GB
   `pacgate-low` is the most expensive resident. Pinning it at 65536 saves 1.5 GB
   **in isolation** — a real saving, but it does *not* buy a second resident model.
6. **Never sum `ollama ps` sizes.** Measure coexistence by loading the pair.

---

## 7. Tooling gap

`scripts/test-aipc-capacity-fit.ps1` checks **single-model** fit against the tier
budget. Nothing in the suite checks:

* whether a *pairing* of shipped tiers can coexist, and
* that `ollama ps` sizes are not additive.

Given this box ships a 6.7 GB and a 9.7 GB tier that look like they sum to 16.4 GB,
a gate that asserted "the two shipped local tiers must coexist" would have caught my
own wrong recommendation before it reached a report. Suggested: extend the capacity
check to load the paired combination and fail if one evicts.

---

## 8. What remains true from the first report

* Local chat **34–45 tok/s** at 100% GPU.
* Cloud **~2.9 s**, **zero VRAM**.
* Embeddings **768-dim**, matching `kb_chunks vector(768)`, **~2.1 s** warm.
* Embedding + resident chat coexists (9.7 + 0.3 GB reported).
* VLM transcribes images correctly.
* The eviction of `pacgate-mid` when `pacgate-low` loads — real and reproduced.

## 9. What is now corrected

* ~~"Pick one local model; let cloud carry concurrency."~~
  → **One model with `NUM_PARALLEL=2` already provides concurrency (1.57×). Cloud
  supplements it; it was never compensating for a local deficiency.**
* ~~"6.7 + 9.7 = 16.4 GB > 15.98, therefore they cannot fit."~~
  → The arithmetic coincidentally matched the symptom, but **`ollama ps` sizes are
  not additive**, and 6.7 + 8.2 = 14.9 GB *also* fails to fit. The sum is not the
  reason.
* ~~"32768 is the safe pin."~~
  → 32768 is the **worst point** on gemma4's memory curve; 65536 is 1.5 GB smaller.
  This does not make the pin unsafe — the pin is what keeps the VLM at a bounded
  context — but it is not the memory *optimum*, and the numbers must not be used as
  a budget.
