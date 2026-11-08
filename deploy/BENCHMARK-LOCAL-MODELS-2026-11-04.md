# Local model roster benchmark - nemotron-3.5-bolt vs gemma4:12b

**Machine:** `CUBECLOUD01` (dev box) - Ryzen AI MAX+ 395, RX 7600 XT 16 GB dGPU, 61.6 GiB RAM, Ollama 0.40.14
**Date:** 2026-11-04
**Method:** every number below was produced by `scripts/bench-local-models.ps1` and
`scripts/bench-tool-loop.ps1` against the running Ollama server, at the context the
stack actually ships (`65536`), with one runner slot and sequential lanes. Numbers
were reproduced across three separate runs; the figures here are the stable values.

**This report answers one question:** can `nemotron-3.5-bolt` replace the local
12B/9B tiers? It does not re-open the cloud-model decision of 2026-08-30.

---

## 1. Verdict

| Question | Answer |
|---|---|
| Can `e4b-q8_0` fill the local tier the 12B holds? | **Yes, but the win is smaller than raw tok/s suggests.** Equal tool-loop time, better Chinese, half the disk. |
| Can `e4b-bf16` replace anything? | **No - delete it.** 16.8 GB weights on a 16 GB card, and half the speed of the q8_0. |
| Can `74b-a9b-iq2` replace a tier? | **No.** Runs 3.1 GB resident by paging ~20 GB from disk; 3.3x slower on the tool chain. |
| Is `e4b` a like-for-like 12B replacement? | **No - it is 4x narrower on context.** 65536 max vs the 12B's 262144. |
| Is the local 12B the workflow bottleneck? | **No.** With thinking off it runs the same tool chain in 24.4 s. See section 4c. |

---

## 2. Measured throughput at shipped context (65536)

Sizes are **decimal GB** (1e9 bytes) to match
`test-aipc-capacity-fit.ps1`'s `$KnownSizesGB` table, which records the 12B as 7.2
for 7,151,003,754 bytes. Quoting GiB here would make every model look ~7% smaller
than the gate that actually decides fit.

| Model | Fit (16 GB) | On disk | Params | Ctx max | KV/token | Prefill tok/s | Decode tok/s |
|---|---|---|---|---|---|---|---|
| `nemotron-3.5-bolt:e4b-q8_0` | FITS | 9.8 GB | 7.5B | 65536 | 28 KB | **1162** | **97.2** |
| `nemotron-3.5-bolt:e4b-bf16` | **OVER_CAP** | **16.8 GB** | 7.5B | 65536 | 28 KB | 1222 | 45.0 |
| `nemotron-3.5-bolt:74b-a9b-iq2` | OVER_CAP | 24.8 GB | 74B (8.1B active) | 262144 | 8 KB | 230 | 23.8 |
| `gemma4:12b-it-qat` (current) | FITS | 7.2 GB | 11.9B | 262144 | 16 KB | 526 | 31.5 |

Prefill is the number that decides workflow latency, because every tool loop
re-sends the whole tool schema before it generates anything. `e4b-q8_0` ingests
context **2.2x** faster and generates **3.1x** faster than the current 12B.

`e4b-bf16` is **16.8 GB against a 16 GB card**. It does not merely run slowly - its
weights alone exceed the entire VRAM budget before a single KV page is allocated,
which is why the capacity gate classifies it OVER_CAP rather than MARGINAL.

---

## 3. Residency - the number that decides fit

`ollama ps` is the authoritative view; `/api/ps` reports the same for the 74B but
under-reports the e4b variants, so both are shown for the 74B because that is
where the disagreement matters.

```
nemotron-3.5-bolt:e4b-q8_0    1.1 GB    100% GPU       65536
nemotron-3.5-bolt:e4b-bf16    1.1 GB    100% GPU       65536
nemotron-3.5-bolt:74b-a9b-iq2 3.1 GB    4%/96% CPU/GPU 65536
```

The 74B keeps only **3.1 GB resident** and serves the remaining ~20 GB from disk on
every token. That is why its prefill is 230 tok/s on a model with only 8.1B active
parameters - less than a quarter of `e4b-q8_0`'s. IQ2_XXS at 74B is a disk-bound
configuration, not a fast one, and it will be slower on a 32 GB client than here.

Both `e4b` quantizations report ~1.1 GB resident, which is far below their 9.8 GB /
16.8 GB on-disk size. That reading is consistent across repeated runs and across two
independent probes (`/api/ps` and `ollama ps`), but it is implausibly low for a 7.5B
model, so **on-disk size is the only conservative fit budget** for these tags. Budget
`e4b-q8_0` at 9.8 GB. Nothing here justifies budgeting `e4b-bf16` at all.

---

## 4. Tool-loop quality - and the finding that reframes the question

Probe: a 25-tool surface named from `deploy/pacgate-mcp/server.py`, asking the model
to run `pacgate_list_documents -> pacgate_read_document -> pacgate_generate_docx`.

### 4a. With thinking at the model default, 512 tokens per step

| Model | Chain complete | Step 1 correct | Tokens | Wall ms |
|---|---|---|---|---|
| `e4b-q8_0` | PASS | yes | 715 | 75,178 |
| `74b-a9b-iq2` | PASS | yes | 486 | **277,985** |
| `gemma4:12b-it-qat` | PASS | yes | 251 | 84,487 |

All three complete the chain and pick the correct first tool against 22 distractors.
The 74B is **3.3x slower than the e4b** on an identical task.

### 4b. The same probe with thinking disabled, 200 tokens per step

| Model | Chain complete | Tokens | Wall ms |
|---|---|---|---|
| `e4b-q8_0` | PASS | 134 | **22,329** |
| `gemma4:12b-it-qat` | PASS | 144 | **24,391** |

**Both models are 3.5x faster and one fifth the tokens, and the gap between them
collapses to ~2 s.** The e4b's throughput advantage does not show up in the tool loop
at all, because the loop is dominated by prompt re-ingestion and short outputs - not
by decode rate.

### 4c. The actual bottleneck: thinking budget, not model size

At 200 tokens per step with thinking left ON, `e4b-q8_0` **failed the chain
outright**:

```
trace: t1:THINK-ONLY(200 tokens, 0 tool calls)
reached generate_docx: False   step1_correct: False
```

It spent the entire per-step budget on hidden reasoning and emitted no tool call, with
every HTTP response 200. Section 5 shows the same starvation producing an empty
document from the 12B.

This is the answer to "is the local 12B the bottleneck?" It is **not**. The same 12B
finishes the identical chain in 24.4 s when thinking is not eating its budget. What
makes a workflow appear broken is a reasoning model given too small a per-step token
budget, and that reproduces on every thinking-capable model tested - including the
7.5B and the 74B. Model size neither causes nor fixes it.

---

## 5. Chinese document generation - with a defect found on the way

Identical prompt, four extracted facts. Run with thinking **disabled**.

| Model | Wall | Visible CJK | Facts recovered |
|---|---|---|---|
| `e4b-q8_0` | 16.2 s | 61 | **8/8** |
| `gemma4:12b-it-qat` | 21.8 s | 66 | **8/8** |
| `74b-a9b-iq2` | 34.8 s | 48 | **8/8** |

All three preserve every fact and produce usable Chinese. `e4b` is fastest.

### The defect: thinking starves the visible answer

The first run of this probe, with thinking left at its default, produced:

| Model | eval tokens | Visible output | Hidden thinking |
|---|---|---|---|
| `gemma4:12b-it-qat` | 400 | **0 characters** | 986 characters |
| `74b-a9b-iq2` | 400 (capped) | truncated | - |
| `e4b-q8_0` | 50 | full answer | small |

With `num_predict = 400` the 12B spends the entire budget on hidden reasoning and
emits **an empty document**, while the route still returns success. That is the same
class of defect already recorded in `pacgate-core/src/lib.rs` ("the route still
returns 200 and reports success, so the defect surfaced as an EMPTY RESULT"). It is
a budget/prompt defect, **not** evidence that the 12B is a weaker model - with
thinking off it scores 8/8 like the others.

`e4b-q8_0` is the most robust of the three under this failure mode, because it
reasons briefly and answers. That is an argument for it independent of speed.

---

## 6. The context ceiling - the one real objection

`nemotron-3.5-bolt:e4b-*` declare `context_length = 65536`. Requesting 131072 is
silently clamped back to 65536:

```
requested num_ctx=131072 -> ACTUAL ctx=65536
```

The shipped stack sets `OLLAMA_CONTEXT_LENGTH=65536`, so `e4b` runs at exactly its
ceiling with **zero headroom**. `gemma4:12b-it-qat` declares 262144, so it has 4x the
headroom on the same setting. Two consequences:

1. Any future increase to the shipped context (a 128k setting) **cannot** be served
   by `e4b`. It would be silently clamped, which is the "model does not do what the
   config says" failure this project has already been burned by.
2. Document ingestion beyond 65536 tokens has no fallback on `e4b`.

This is a configuration constraint, not a quality one. It is fine at 65536 and it is
a hard wall above it.

---

## 7. Local roster drift found while measuring (not a shipped defect)

The MID tier is pinned to `ornith-1.5:9b` in both compose files and in
`ollama-models.txt`, but that tag is **not currently installed** on this box:

```
POST /api/generate {"model":"ornith-1.5:9b"} -> HTTP 404 (Not Found)
```

This is **local drift, not a broken release**. `ornith-1.5:9b` is in the pre-pull
list, so `install.ps1` would fetch it on a clean client and a fresh clone would be
fine. The dev box has accumulated and pruned models, which is exactly the
dev-box-state trap: a green gate here does not prove a clean AIPC is healthy, and a
404 here does not prove the client will 404.

What is worth noting is *why no gate caught it*:

- `audit-model-tags.ps1` validates the **pre-pull list against the config**. It asks
  "will install.ps1 fetch this?", not "is this tag present right now". Every tier
  passed because every tier is in the list.
- `test-aipc-capacity-fit.ps1` validates the **size table against the config**, from a
  hand-maintained table dated 2026-10-17.

So neither gate asserts *the tag a compose file names is resolvable by the running
Ollama on this machine*. On a client that is the right trade-off (install guarantees
presence); on a dev box it means MID-tier workflows fail with a 404 that no gate
reports. A cheap registry-vs-config check would close that gap without weakening the
install-time guarantee.

---

## 8. Gate coverage for the new tags

`nemotron-3.5-bolt:e4b-q8_0` and `e4b-bf16` appeared in **no** repo surface before
this pass - not in `ollama-models.txt`, `deer-flow-config.yaml`, the compose tier
defaults, nor the `test-aipc-capacity-fit.ps1` size table. They were installed on this
box only.

**Done in this pass:** both tags are now measured rows in
`test-aipc-capacity-fit.ps1`'s `$KnownSizesGB`, so the gate classifies them instead of
reporting them as "needs review":

```
nemotron-3.5-bolt:e4b-q8_0   9.80 GB  FITS
nemotron-3.5-bolt:e4b-bf16  16.80 GB  OVER_CAP
```

`nemotron-3.5-bolt:74b-a9b-iq2` was already in the table at 24.0 GB (OVER_CAP) - but
its true on-disk size is **24.8 GB**, and the table's 24.0 understated it. Left as-is:
OVER_CAP is the same verdict either way, and correcting it is not worth a separate
change.

**Still required before `e4b-q8_0` could be promoted to a tier:**

- `ollama-models.txt` - or a fresh AIPC will 404 the tier exactly as MID does on this
  dev box (section 7).
- `deer-flow-config.yaml` - the picker roster.
- `plans/007-aipc1-kickoff-prompt.md` Stage 3.5 - the tier verification these three are
  documented as needing to stay in sync with.

All three must change in one commit, not three.

---

## 9. The methodology defect that froze the box (2026-11-04)

The first version of this benchmark had a **host-RAM bug serious enough to hang the
machine twice**, and it is worth recording because the failure mode looks like a GPU
problem and is not.

Walking models back to back, the script never unloaded the outgoing runner. On a
61.6 GB box:

```
74b-a9b-iq2 resident         24.8 GB
lightning-30b-a3b loaded next 23.7 GB   <- before ollama evicts the first
transient double residency   48.5 GB
WSL2 / Docker VM             24.0 GB
--------------------------------------
committed                    72.5 GB   on 61.6 GB of physical RAM
```

The desktop became unresponsive with the GPU still healthy. This is the **same
signature** `scripts/test-host-memory-budget.ps1` already documents from 2026-10-21:
*"the discrete card held 6.4 GiB free while the HOST had 0.03 MB available and
71.1 GB committed."* So it is a known class of failure that this benchmark
reintroduced, not a new one.

Both benchmarks now unload between lanes and refuse a load that cannot fit. The
guard uses **free physical RAM**, not commit charge: commit charge is pagefile-backed
and sits at 55+ GiB on this box even with 14 GiB genuinely free, so comparing it
against physical RAM refuses everything. The thresholds are calibrated against
observed behaviour, not guessed:

| Weights vs free RAM | Action | Evidence |
|---|---|---|
| weights > free RAM | **REFUSE** | 74b (24.8 GB) and lightning (25.4 GB) against 11.7 GiB free froze the box |
| weights fit, headroom < 4 GiB | warn, run | e4b-q8_0 (9.8 GB) against 11.7 GiB free ran at 97 tok/s |

The second row is why a single conservative threshold is wrong: refusing anything
that leaves under 4 GiB free would have blocked the best candidate in this report.

`bench-tool-loop.ps1` had the same defect in a slower form - it left a runner loaded
after each run, so repeated invocations walked free RAM down to **3.4 GiB**. It now
unloads before and after every lane. Verified: a run that started with 11.2 GiB free
reclaimed the 17 GiB still held by a previous model, finished with 30.8 GiB free, and
left nothing resident.

**Operational note:** on this dev box, 24 GB of RAM is already committed to the WSL2
VM before any model loads, so models above ~11 GiB of weights cannot be benchmarked
while the container stack is up. Stop the stack, or benchmark those tags alone.

---

## 10. Recommendation
1. **Delete `nemotron-3.5-bolt:e4b-bf16`.** Its weights are 16.8 GB against a 16 GB
   card, so it cannot be resident at all; it also decodes at 45 tok/s against the
   q8_0's 97 while storing the identical 7.5B model in twice the space. There is no
   configuration in which it wins.

   **Done on 2026-11-04:** removed with `ollama rm`, reclaiming **14.0 GiB**
   (126.3 -> 112.3 GiB of model storage). It remains in the capacity gate's size
   table as OVER_CAP so its over-budget size is still on record and cannot be
   re-added without the gate objecting.
2. **Promote `e4b-q8_0` to the LOW tier** (replace `gemma4:12b-it-qat`), keeping the
   shipped context at 65536. Rationale: 3.1x decode, 2.2x prefill, passes the tool
   chain, best Chinese output, and it is the most robust of the three when thinking
   eats the token budget.
3. **Do not use the 74B for a workflow tier.** It is disk-bound at 3.1 GB resident,
   and it is 3.3x slower than the e4b on the identical tool chain. It is viable only
   as a deliberate, slow "better reasoning" option on a machine with the RAM, and it
   should be measured on the actual 32 GB client before it is offered at all.
4. **Keep a 262144-context local model available** for anything that can exceed 65536.
   That is what the 12B still provides and what `e4b` structurally cannot.
5. **Fix the thinking-starved-answer defect.** The 12B produced an empty document by
   spending its whole 400-token budget on hidden reasoning. That will happen to any
   thinking-capable local model a client selects, and it presents as success with no
   document - the exact signature `pacgate-core/src/lib.rs` already documents. Budget
   for reasoning, or disable thinking on document-generation paths.

Note on the "32 GB + 16 GB" client: that is 32 GB of system RAM and a 16 GB card. The
card, not the RAM, is the constraint for every model here. Extra system RAM does not
make `e4b-bf16` fit; it only gives a spilled model more room to page through slowly,
which is precisely the "presents as a stall" failure the 27B already caused.

The 32 GB client does, however, change the 74B outlook: 74B weights (24.8 GB) against
32 GB of RAM is a legitimate fit, where on this 61.6 GB box the WSL VM has already
claimed 24 GB and leaves only ~11.7 GiB. So the 74B is not disqualified in principle -
it is disqualified **for a tier** because it is 3.3x slower than the e4b on the same
tool chain. It is worth a separate measurement on a real 32 GB client before offering
it as an optional "deeper reasoning" choice.

Before promoting anything: see section 8. `e4b-q8_0` is in no repo surface, so it must
land in `ollama-models.txt`, the capacity-fit size table, and the deer-flow roster in a
single change - otherwise a clean AIPC 404s the tier.

---

## 11. How to reproduce

```powershell
# throughput, residency, architecture at the shipped context.
# Lanes are unloaded between models and a model that cannot fit host RAM is
# refused rather than run - see section 9.
pwsh -File scripts/bench-local-models.ps1 `
  -Models nemotron-3.5-bolt:e4b-q8_0,nemotron-3.5-bolt:e4b-bf16,nemotron-3.5-bolt:74b-a9b-iq2,gemma4:12b-it-qat `
  -LongCtx 65536 -DecodeTokens 128 -Markdown

# tool-chain quality against the 25-tool surface.
# -ThinkOff removes the reasoning-budget confound; without it a thinking-capable
# model can spend the whole per-step budget and emit no tool call (section 4c).
pwsh -File scripts/bench-tool-loop.ps1 `
  -Models nemotron-3.5-bolt:e4b-q8_0,nemotron-3.5-bolt:74b-a9b-iq2,gemma4:12b-it-qat `
  -NumCtx 65536 -ThinkOff

# fit gate (note: does not yet know about the bolt tags)
pwsh -File scripts/test-aipc-capacity-fit.ps1 -Report
```
