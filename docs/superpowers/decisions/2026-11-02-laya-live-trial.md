# laya live trial: what the running stack actually does (2026-11-02)

## Question

The integration was measured against CUAD and CCL-DRR. Those numbers describe
questions and checkpoints, not the running product. This records what a trial of
the shipped stack - `ghcr.io/jzkk720/laya-serve:0.2.13` beside `pacgate-mcp:0.2.13`
- does when called the way the tools call it, and what it changed.

Every figure below was produced on this box (AMD Ryzen AI 9 HX 370, 24 logical
cores, `device: cpu`, no CPU quota on the container) against the real container.

## The architecture claim holds, on one condition

laya belongs upstream of the guardrail layer as a candidate generator. It has no
generative head - `output_tokens: 0` on every call, confirmed - so it cannot
summarise, draft, or answer off-schema. Its number has to reach deterministic
rules as a `signal`, and the rules produce the `finding` a person sees.

That is exactly the shape of `pacgate_clause_risk`: laya answers three typed
questions, `_laya_zh_grade` is the rule, the grade is the finding. Nothing in the
trial argues against the design. What it argues against is the assumption that the
plumbing between the two was already correct - twice it was not.

## Two defects, both in our layer, one of them fail-open

### 1. Abstention reached laya and stopped there

`min_confidence` is forwarded. laya honours it: an answer below the threshold
carries `low_confidence: true` and `abstention: "abstained"` (measured on an
isolated clause, `abstention` at 0.55 on an answer with `answer_confidence`
0.4773). `_laya_zh_grade` read only `noul`, so the flag changed nothing.

Measured consequence: `noul` 0.4773 is below all three tuned thresholds
(0.75 / 0.50 / 0.50), so the clause came back **`risk: low`** - the one verdict a
Chinese path must never emit for a clause the engine refused to judge. That is
false clearance, and it was reachable through the default arguments.

Fixed: `_laya_zh_verdict` withholds the grade when any of the three questions
abstained, reports `risk: null`, `verdict_withheld: true`, and names the
abstaining questions so a reader can ask them again instead of re-reading the
clause. A genuine clear clause still grades `low`, and a genuine risky one still
grades `high` - both asserted.

The English path has the same unread `abstention`, and it is deliberately left
as-is: there the numbers are returned beside the flag, so a reader sees 0.4773
rather than a synthesised word. Worth fixing on its own schedule, not worth
mixing into a measured Chinese change.

### 2. A probability over part of a clause was indistinguishable from one over all of it

laya reports `usage.truncated` and `state_tokens_dropped` honestly. Nothing read
them, and the shipped question sets set the boundary, because options share the
window with the state:

| path | deployed `max_len` | read in full | first truncation |
|---|---|---|---|
| 4 EN flags | 512 | ~330 words | ~384 words, 12 tokens dropped |
| 2 EN risk questions | 512 | ~330 words | same (~480 state tokens) |
| 3 ZH risk questions | 1024 | ~1,000 Han characters | ~1,400 characters, 17 dropped |

A 384-word clause is ordinary, not pathological. Fixed two ways because the two
paths fail differently:

- **English** now returns `partial: {state_tokens_dropped, ...}` beside `answers`.
- **Chinese** refuses to grade and returns `verdict_withheld: true` with the
  reason. There, one word is synthesised from the three numbers, and a `low` over
  the first two thirds of a clause is false clearance again.

Raising `max_len` is supported (`max_len: 2048` reads a 1,501-token clause with
zero dropped) and is the wrong default here: the same 1,500-token Chinese clause
measured **6.8 s truncated, 11.5 s untruncated** on this CPU, against 0.39 s for a
one-sentence clause. Splitting the clause is cheaper than reading it whole.

## The `unilateral_termination` flag does not separate termination clauses

This is the finding that changes what may be claimed, and it is a question defect
rather than a plumbing defect - so it is recorded and gated, not silently
reworded.

Isolated test: 8 one-sided and 8 mutual termination clauses, each judged alone.

| flag | mean P(pos) | mean P(neg) | separated? |
|---|---|---|---|
| `uncapped_liability` | 0.96 | 0.17 | yes |
| `auto_renewal` | 0.97 | 0.51 | yes |
| `dispute_waiver` | 0.82 | 0.40 | partly |
| `unilateral_termination` | **0.55** | **0.57** | **no** |

Mutual clauses scored as high as 0.93. Asking it as a two-option `choice`, or
adding explicit `noul` criteria, did not fix it (`mean P(pos)` 0.32 vs 0.52 under
`choice`).

**A phrasing that does work, measured in Chinese**, is a perception question with
three named options rather than a yes/no entailment: `only_counterparty` /
`both` / `neither` separated 3/3 from 4/4 with no error. It is not shipped because
it changes what the English benchmark measured - the same reason the earlier
`termination_for_convenience` number could not be reused, and repeating that
mistake in the other direction would be worse.

The docstring now says which of its four CUAD numbers belongs to a question this
tool does not ask (`termination_for_convenience`, AUC 0.988) and what the shipped
asymmetry question actually scored (0.600 on the matched benchmark; no separation
in isolation). The gate asserts that disclosure survives.

## Cost, measured rather than assumed

| | measured |
|---|---|
| CPU torch, no CUDA | `torch 2.15.0+cpu`, `torch.version.cuda` None, 0 devices |
| Resident memory, both checkpoints idle | **4.437 GiB** (`docker stats`) |
| 1 English question, warm | **288 ms** median (266-306) |
| 1 Chinese question, warm | **109 ms** median (103-110) |
| 4 English flags, one call | **707-1150 ms** (~177 ms/question) |
| 4 flags as 4 separate calls | **1010 ms** (~252 ms/question) |
| batch endpoint, 8 clauses x 4 flags | **795 ms/clause** |
| batch endpoint, 32 clauses x 4 flags | **920 ms/clause** |

Two things this corrects. Batching does help per question (~30%), but the batch
endpoint does **not** amortise at clause level - it is slower per clause than one
call per clause, so "nightly full-portfolio triage is trivial via batch" is not
what the numbers say. And the earlier "0.3 s per English clause" figure is a
one-question call; the shipped tool asks four, and costs ~1 s.

`device: cpu` is a **preference**, not a constraint, and there is no GPU to
fall back from: `device_is_preference: false`, `cpu_fallbacks` count 0 on both
checkpoints, `torch.cuda.is_available()` False. The image pins the CPU wheel
(`download.pytorch.org/whl/cpu`), so this box's RX 7600 XT - and the HX 370's
iGPU - are unreachable without a different image, not without a flag.

## Provenance, closed

| claim | evidence |
|---|---|
| Apache-2.0 | GitHub API `license.spdx_id = Apache-2.0`; ModelScope model card `License: "apache-2.0"`, tag `commercial-use`; README footer "Apache 2.0 - Convai Innovations" |
| revision pinned | `refs/main` in the staged cache = `7b928d828b7b0e022f929d9bd2e44165aa270148`, matching `ARG LAYA_REVISION`; `/health` reports it for both checkpoints |
| licence file ships | `/usr/local/lib/python3.12/site-packages/laya-0.4.19.dist-info/licenses/LICENSE` is the Apache 2.0 text |

**What is still not established: the training-data provenance.** The model card
documents the method (`RLCD`, strictly proper scoring rules) and the architecture
(ModernBERT-large + a decision head) but names no corpus. Self-hosting relocates
the data-governance question rather than removing it - the weights were trained on
something, and the card does not say what. That is a business question for a
confidentiality promise, not a technical one, and it is now not something the
documentation implies is settled.

## Verified live

- `/health`: `loaded: ["multilingual","english"]`, both revisions pinned, device cpu.
- Routing: English to `english`, Han to `multilingual`, with the reason reported.
- In-budget decisions: abstention fires, and the grade now follows it.
- Both guardrails: the Chinese withheld payload routes to `pacgate_clause_risk`;
  the English `partial` flag reaches the payload.
- Batch limits: `MAX_BATCH_STATES = 64`, `MAX_QUESTIONS = 64`,
  `MAX_STATE_CHARS = 50000`. A 32-state batch ran; single-vs-batch parity was
  checked at 8 states (8 answers, 0 mismatch). The 64 cap is read from the
  service, not exercised here.
- Parity: single vs `/v1/systemone/batch`, 8 answers compared, 0 mismatch.
- Gate: `scripts/test-laya-tools.ps1` **64 passed, 0 skipped**, with four new L11
  assertions red-checked by reintroducing both defects (4 failures) and restoring.

## What this does not change

The standing rule stays: a `high` is a prompt to review, never a finding, and
nothing here justifies removing a human review step. `pacgate_clause_flags` stays
English-only by measurement. The cloud-model decision for deer-flow is untouched -
laya is upstream of it and neither reads the other's output.
