# laya as a local decision engine, and the four repos reconsidered

Status: research and implementation plan, 2026-10-31.
Supersedes the verdict table in `2026-10-31-third-party-skill-adoption.md`.

## Measured: laya on Chinese clauses (2026-10-31)

This section exists because the earlier version of this document said accuracy was
unmeasured. It is now measured, and the result is nuanced rather than a clean win.

**Setup.** Weights staged from ModelScope (HuggingFace egress on this box is
DNS-hijacked to an X/Twitter range and transfers at ~10 KB/s; ModelScope, on
Alibaba Cloud, measured **0.59 MB/s** and served the same checkpoint). Placed in
an HF cache layout because that is what `snapshot_download` reads, with
`HF_HUB_OFFLINE=1`. 614 MB weights + 33 MB tokenizer.

**It runs, offline, and it is fast.**

| Clause (Chinese) | Verdict | `answer_confidence` |
|---|---|---|
| unlimited liability incl. indirect loss and legal fees | **high** | **0.955** (h=0.955 m=0.013 l=0.032) |
| unilateral termination, no liability, no objection permitted | **medium** | 0.446 (h=0.233 m=0.446 l=0.321) |
| mutual 30-day notice to terminate | low | 0.475 (h=0.159 m=0.366 l=0.475) |
| payment within 30 days of invoice | low | 0.536 (h=0.220 m=0.244 l=0.536) |

Latency: **88-91 ms** warm per clause, 6.9 s on the very first call (model load).
That is the number that matters commercially - a per-clause pass over a contract
is cheap in a way a 27B local model could never be.

**The honest reading.** It nails the unambiguous worst case and gets the routine
cases right, but it called unilateral termination `medium` rather than `high`, and
the three non-obvious clauses all landed between 0.45 and 0.54. Near 0.5 on a
three-way choice is close to uniform, which is the model declining to commit.

That is not a defect to work around - it is the reason `min_confidence` is
forwarded. With a 0.55 threshold, three of these four clauses come back
`low_confidence` and reach a human, while the unlimited-liability clause is
flagged automatically. The engine is a **triage filter, not an adjudicator**, and
the integration is correct as built; what must not happen is treating its `low`
verdict as clearance.

**Not established.** This is four hand-written clauses, not a corpus. There is no
measured precision or recall, so it does not justify removing any human review
step. Before it changes any workflow, run it over a real annotated set of the
firm's contracts and measure agreement per risk bucket. Until then the correct
framing is: it reliably escalates the worst clause and defers on the rest.

**Verdicts are sensitive to how the criteria are worded.** The same English clause
("the Company may terminate at any time without liability") returns **high 0.808**
under the fuller criteria in `pacgate_clause_risk` and **low 0.672** under terse
criteria (`high: one-sided termination`, `medium: ambiguous`, `low: routine`).
A third of the gap is the question, not the clause.

That is the single most important operational note here: the criteria shipped in
server.py are part of the model's behaviour, so changing them changes verdicts.
Any future tuning must be measured against a fixed clause set - never judged by
eyeballing one result. It also means the shipped sets are worth reviewing
deliberately, as questions, not as documentation.

**Field naming, measured and easy to get wrong:**
`confidence` is the *margin* between the top two options (0.0432 in one sample),
while `answer_confidence` is the probability of the chosen option (0.4267). Only
the latter is comparable to a 0-1 threshold, so `min_confidence` gates on it.

## Benchmark: measured against CUAD, 2026-11-01

The earlier sections called accuracy "unmeasured" and rested on four hand-written
clauses. That gap is now closed for English, with real ground truth.

**Data.** CUAD (Contract Understanding Atticus Dataset): 510 real commercial
contracts from EDGAR, ~13,000 expert span annotations over 41 clause categories,
CC BY 4.0 - the datasheet states it is "free to the public for commercial and
non-commercial use". Four of its categories are the direct semantic counterparts
of our flags, which is the only reason this is measurable at all:

| flag | CUAD category | positives / 510 |
|---|---|---|
| `uncapped_liability` | Uncapped Liability | 111 |
| `termination_for_convenience` | Termination For Convenience | 183 |
| `auto_renewal` | Renewal Term | 176 |
| `dispute_waiver` | Covenant Not To Sue | 100 |

**Result** (`scripts/bench-laya-clause-flags.ps1 -Contracts 25`, seed 11, 80
predictions, 23 s, English checkpoint):

| flag | AUC | P@0.5 | R@0.5 | F1 | median pos | median neg |
|---|---|---|---|---|---|---|
| `uncapped_liability` | 0.931 | 0.83 | 0.83 | 0.83 | 0.93 | 0.23 |
| `termination_for_convenience` | **0.988** | 1.00 | 0.81 | 0.90 | 0.62 | 0.03 |
| `auto_renewal` | 0.942 | 0.90 | 0.82 | 0.86 | 0.83 | 0.10 |
| `dispute_waiver` | **1.000** | 1.00 | 0.71 | 0.83 | 0.82 | 0.06 |

Every flag separates the concept it names. **This is the first number in this
document that justifies shipping the flags as risk signals rather than hints.**

### Two wrong numbers I produced first, and why they were wrong

Both were defects in the measurement, not the model. Recorded because
re-deriving them is expensive and the failure modes are easy to repeat.

**1. AUC 0.235 - worse than chance - for "unilateral termination".** The negative
side of the first run was one hand-written benign sentence: *"Either party may
terminate this Agreement on thirty (30) days' prior written notice."* Measured
against CUAD, **that sentence is a positive** - it is a Termination For
Convenience. So the benchmark scored a positive as a negative and reported the
model as inverted. Fixed by drawing negatives from spans of *unrelated* CUAD
categories in the *same* contracts, and by using the semantic opposite
(`Cap On Liability`) as the hard negative for the liability flag.

**2. The flag asked a different question than the label.** CUAD's Termination For
Convenience includes mutual rights; our `unilateral_termination` adds an
asymmetry requirement CUAD does not annotate. On the same clauses the matching
question scores **AUC 0.988** and the asymmetry question **0.600**. Both are
honest numbers about different questions. The benchmark measures the concept
CUAD labels, and the flag is now named for it.

### Still not established

- **English only.** laya routes Latin text to the `english` checkpoint, so none of
  this transfers to Chinese. No public Chinese-language *contract* corpus with
  clause-level annotations exists to measure against, so Chinese remains a
  smoke-test-only claim.
- **80 predictions on 25 contracts.** Enough to separate a working flag from a
  broken one; not a confidence interval. Raise `-Contracts` for a tighter estimate.
- **CUAD is US commercial contracts.** Chinese-law and civil-law drafting differ
  enough that a good AUC here does not promise good behaviour on PRC deals.
- **Precision/recall per risk bucket is now measured; the decision to remove any
  human review step is still not justified.** Triage remains the correct framing.
- **Two plumbing defects were found later, by trial against the running stack
  (2026-11-02), and fixed there:** abstention was forwarded but unread, so an
  abstained Chinese answer graded `low`; and truncation was reported by laya but
  unread, so a ~384-word clause was judged as if it were the whole clause. See
  `decisions/2026-11-02-laya-live-trial.md`. The lesson is not about laya: a
  measured model does not make the layer around it correct, and neither defect
  was visible in any benchmark of the model.
- **`unilateral_termination` does not separate termination clauses.** Eight
  one-sided against eight mutual clauses, judged in isolation: mean P 0.55 vs
  0.57, mutual clauses reaching 0.93. The `termination_for_convenience` AUC 0.988
  above belongs to a *different question* - the matched one, which CUAD annotates
  and this tool does not ask. A three-option perception phrasing separates 3/3 vs
  0/4 in Chinese and is not shipped because the English number would need
  re-measuring first.
- **Latency in the shipped shape is ~1 s per English clause, not 0.3 s.** Four
  flags in one call measured 707-1150 ms; four separate calls 1010 ms. The batch
  endpoint is *slower per clause* (795 ms at 8 states, 920 ms at 32), so it does
  not make portfolio-wide triage cheap - it amortises per question, not per
  clause.

## Chinese: measured, failed, then fixed, 2026-11-01

The benchmark above is English. Running the same question on Chinese text
(CCL-DRR: 6,794 Chinese contract clauses, 3-way labels, chance 0.333) produced:

    accuracy 0.333   (exactly chance)
    recall on 风险高 0.00   it flagged none of the 7 high-risk clauses
    predictions  high=0  medium=17  low=4

Asking it in Chinese was worse (0.238). The first fix was to withhold Chinese
verdicts entirely - defensible, but it deleted the capability in the language the
product was built for.

**It was recoverable.** The single three-way question was carrying three semantic
axes at once (severity, ambiguity, asymmetry) and collapsing onto the majority
class. Decomposed into three yes/no questions and combined with tuned thresholds
(uncapped >= 0.75, unilateral >= 0.50, ambiguous >= 0.50):

| measure | value |
|---|---|
| recall on 风险高 | **0.86 - 1.00** (four sampling seeds) |
| precision | 0.35 - 0.43 |
| accuracy | 0.38 - 0.57 |

That is the difference between a tool that cannot see the class it exists to
catch and one that almost never misses it. The precision is the price: roughly
2.5-3 clauses are escalated per genuinely risky one. For legal triage that is the
correct bias - a false high costs minutes of review, a false low ships an unfair
term - but it is why a `high` is a prompt to review and never a finding.

`pacgate_clause_risk` routes by language: English to the three-way question
(CUAD, AUC 0.93-1.00), Chinese to the decomposed path. `pacgate_clause_flags`
stays English-only by measurement and points a Chinese reader at the tool that
does grade Chinese.

**One number I had to correct in myself.** The first tuned result was recall 1.00
on a single sample, and I wrote that into the docstrings. Four seeds gave
0.86-1.00, so every surface now states the range. A benchmark reported from one
draw is not a measurement.

### What is still not established

- **CCL-DRR is generated from statute articles**, not extracted from executed
  contracts, and has no external validation. It bounds the problem; it is not a
  substitute for a corpus of the firm's own deals.
- **Precision ~0.4** means most escalations are false positives. Nothing here
  justifies removing human review; it justifies pointing review at the right
  clauses.
- English figures come from US commercial contracts; Chinese from CCL-DRR's seven
  contract types. Neither is a PRC-executed-contract benchmark.

## What changed and what did not

The earlier record rejected five repositories. Two of its reasons were wrong and
this document corrects them. The egress objection to `jev-skill` stands, but it
now has an answer: `laya` replaces the meter with a local model.

Everything below marked **measured** was run on this machine against the real
artifacts. Everything marked **blocked** could not be proven here and says so.

## The headline: laya turns a cloud dependency into a local one

`NandhaKishorM/laya` is a System 1 decision engine. You ask typed questions -
`choice`, `score`, `noul` (probability) - about a piece of text and get
calibrated answers from one non-autoregressive forward pass. Nothing is
generated, so there is nothing to parse and nothing to hallucinate.

- 34,729 stars, Apache-2.0, Python, pushed 2026-10-31, not archived.
- **Measured:** `pip install "laya[onnx]"` succeeds on Python 3.14.3 and imports
  as `laya` 0.4.19. The `onnx` extra runs inference on ONNX Runtime with **no
  PyTorch** - that matters because torch is ~2.5 GB and an AIPC cannot spare it.
- **Measured:** it exports `LayaGuardrail`, `LayaTriage`, `LayaRouter`, `Agent`,
  `LayaEvaluator`, `OptionStabilityHook`. Guardrails and triage are first-class,
  not bolted on.
- Checkpoints: `multilingual` (mmBERT-base, 322M, 1024 tokens, 100+ languages,
  the default), `english` (ModernBERT-large, 421M, 512 tokens),
  `typed-decisions` (421M). Weights are a 2.5 MB graph plus a 1.20 GB
  `model.onnx.data` sidecar for multilingual.
- **Measured:** `DEFAULT_MODELS` resolves all three to one repo,
  `convaiinnovations/laya`, with a `subfolder` of `null` / `multilingual` /
  `typed-decisions`. One repo, three subdirectories, so staging is a single
  checkout.
- **Measured offline capability:** `snapshot_download` takes a directory path
  and short-circuits without network, and honours `HF_HUB_OFFLINE=1`. A
  pre-staged model directory therefore gives fully offline inference. This is
  the deployment path; nothing downloads at runtime on a client machine.
- **Measured API surface:**
  `Router.predict(state, questions, model=, task=, lang=, max_len=,
  head_max_len=, min_confidence=, hooks=)`.
  `min_confidence` is an abstention gate, so the engine can decline instead of
  guessing - the single most important property for clause classification.
  `max_len` reaches 8192 for long documents.

The honest limit: laya judges a **bounded state** - one clause, one candidate
list, one routing question. It is not a document reader. `max_len=8192` gets a
Chinese contract page in, roughly 4,000 tokens of usable context, and the
author's own long-context numbers drop off beyond that. So it is a clause-level
judge inside a loop, not the contract reader. That distinction decides the whole
architecture below.

## Substitution one: laya on the wire, no API key at all

There are two independent ways to remove `jev-mcp`'s meter, and they compose.

**1a. laya speaks the Jev protocol.** `laya-serve` "exposes Laya over the
TypeSafe Jev `/v1/systemone` wire protocol", so a client written against Jev
points its base URL at it unchanged.

**1b. jev-mcp can be told to use it.** `jev-mcp` documents
`JEV_PROVIDER=compatible` with `JEV_API_BASE_URL` (the full POST URL including
`/v1/systemone`) and an optional `JEV_API_KEY`. So:

    JEV_PROVIDER=compatible
    JEV_API_BASE_URL=http://laya:8000/v1/systemone
    # no key

`jev-mcp`'s twelve tools (`jev_verify`, `jev_gate`, `jev_extract`, ...) then run
against the local model. **No `TYPESAFE_API_KEY`, no cloud, no per-call cost.**
The earlier rejection of `jev-skill` on egress grounds is answered.

One caveat that is easy to miss: laya's own MCP server is **stdio only**. Its
documented HTTP path is `LAYA_BASE_URL`, where the stdio MCP process forwards
prediction calls over HTTP. So laya cannot be registered in deer-flow's MCP
config directly - deer-flow's transport options are stdio, `sse`, and `http`
(measured at `client.py:32`), and laya offers none of those as a server. It must
be reached through an HTTP-speaking proxy, which we already have.

## Substitution two: pacgate-mcp is the natural proxy, and it needs no rebuild

**Measured:** `deploy/pacgate-mcp/server.py` is a FastMCP streamable-HTTP server,
and deer-flow consumes it exactly as it consumes `openviking`, through
`mcpServers` in `extensions_config.json`. That is the established pattern: a
tool reaches the agent by being registered with a running MCP server, not by
altering the deer-flow image.

This is the decisive architectural fact for everything else in this document.
The earlier premise - that a new Python dependency means rebuilding the
upstream-only deer-flow image - is what made `laya` look expensive. It is not
the only path. A new service plus `pacgate-mcp` tools plus a config entry
delivers the capability, and `pacgate-mcp` is an image we build.

## Packaging: and here is the real blocker

`laya` needs a container. Two facts collide:

- **Blocked:** Docker Hub is unreachable from this machine, and the configured
  proxy at `127.0.0.1:7892` is not running. A `FROM python:3.12-slim` build
  cannot resolve its base image here.
- **Measured:** `compose.yaml` in the laya repo uses `build:`, there is no
  published image (`ghcr.io/nandhakishorm/laya` and
  `ghcr.io/convaiinnovations/laya` both return 401 - absent or private).

So packaging cannot be finished locally. It *can* be finished in CI, which is
how every other image in this stack is built and how `test-release-provenance`
already reasons. That inverts the sequencing: write the Dockerfile, the compose
service, the tools and their gates; validate the build in the release workflow;
only claim it works once CI has produced the image.

**And the model cannot be downloaded here either.** `huggingface.co` resolves to
`199.16.158.12`, an X/Twitter address range - DNS hijacking. Python's stack
times out against it, `hf-mirror.com` answers 403, and `cdn-lfs.huggingface.co`
fails TLS. So **no inference has been run on this box**. Nothing in this
document claims laya classifies Chinese clauses well; that is unmeasured and
must be measured on a machine that can fetch the weights, or from CI.

## What laya should actually do in Pacgate

The tempting use is "read the contract". laya cannot do that. The use that fits
its shape, and that our pipeline already has a slot for, is judging clauses the
pipeline has already extracted:

1. **Clause risk triage.** For every extracted obligation, ask a `choice`
   question over `{high, medium, low}` plus a `noul` question ("does this clause
   expose the client to uncapped liability?"). 33 ms per call makes a
   per-clause pass affordable in a way a 27B local model never is.
2. **Guardrail with abstention.** `LayaGuardrail` plus `min_confidence` lets a
   clause be flagged as *undecidable* rather than forced into a bucket. For
   legal review, "I cannot judge this" is a real answer and must not be
   invented away.
3. **Routing.** `LayaRouter` picks the checkpoint per request from language
   evidence, which is exactly the Chinese/English split our contracts have.

What it must not become is a replacement for the reasoning model. It answers
typed questions; it does not write. The review narrative stays with
`qwen3.8:27b`.

## The four other repositories, reconsidered properly

### `ibelick/ui-skills` - rejected again, for the right reason

Zero egress, nine skills, all structurally valid (every `name` matches its
directory, none declares `allowed-tools`, and the only frontmatter keys used are
`name`, `description`, `license`, `metadata`, `version` - all five are in
deer-flow's `ALLOWED_FRONTMATTER_PROPERTIES`). It is still rejected because the
product has no design surface. `component-canvas` also wants a browser. Keep it
at user level for `docs/` work. Unchanged verdict, now correctly grounded.

### `cobusgreyling/loop-engineering` - rejected, and now we know exactly why

**Measured:** every one of its seven skills declares `user_invocable: true`.
Feeding a faithful copy to the real validator returns:

    (False, 'Unexpected key(s) in SKILL.md frontmatter: user_invocable', None)

deer-flow computes `set(frontmatter.keys()) - ALLOWED_FRONTMATTER_PROPERTIES` and
refuses the skill on any surplus key. Mounted as-is, all seven would vanish
silently. That is a one-token fix per file, so it is not a hard blocker - but it
confirms the earlier judgement for a better reason: it is a methodology repo,
and we already run maker/checker discipline through `test-workflow-mutations`
and the mutation harness. The two skills worth *porting* rather than depending
on are `loop-verifier` ("finds reasons to reject", independent of the
implementer) and `minimal-fix` ("smallest diff that could work"). Both describe
what this repo already does by convention; encoding them as skills would make
the convention enforceable.

### `wandb/openui` - my earlier rejection was wrong, and the reason matters

I rejected it as "a competing application requiring a cloud LLM key". Both
halves need correcting:

- **It runs fully local.** The README documents `OLLAMA_HOST`, and this stack
  already points at `http://host.docker.internal:11434` (measured in
  `compose.prod.yaml`; Ollama answers live). So `OLLAMA_HOST` +
  `-e OLLAMA_HOST=http://host.docker.internal:11434` needs no cloud key at all.
  `OPENAI_COMPATIBLE_ENDPOINT` covers any other local gateway.
- **It is pullable without Docker Hub.** **Measured:**
  `ghcr.io/wandb/openui:latest` returns HTTP 200 from the GHCR manifest API, so
  it bypasses the Docker Hub outage entirely.

What still stands is relevance: generative UI has no place in contract review.
The defensible use is a **proposal surface** - the `docs/` pages we hand to
procurement and partners are today hand-written static HTML. That is a
real-time sink, and openui could render proposal sections from a prompt against
the local model. Recommendation: **experimental, opt-in profile, never in the
client bundle default.** It adds a port and a second LLM consumer on a box sized
for one.

### `CopilotKit/OpenIntelligentUI` - rejected, and this one holds

**Measured:** its README names no base-URL or local-model variable. It requires
`OPENAI_API_KEY` and `TYPESAFE_API_KEY`, and its default model is `chat-latest`,
"OpenAI's documented alias for the latest ChatGPT Instant model". There is no
documented path to redirect it at Ollama. Reject for product: it is a cloud-first
chat interface, and both of its keys are exactly what an on-prem deployment
exists to avoid.

## Plan

Ordered so that each phase is independently useful and nothing claims success
before it is measured. Packaging is deliberately last-but-one because CI is the
only place it can be proven.

### Phase 0 - decide the shape before writing code

- Confirm the service boundary: `laya-serve` as its own compose service (HTTP),
  reached by `pacgate-mcp` tools. Not an MCP server in deer-flow's config, which
  the stdio-only transport rules out.
- Confirm the model staging story: `deploy/client-bundle/models/laya-multilingual/`
  gitignored, populated by the installer, `HF_HUB_OFFLINE=1` set on the service,
  and `model_dir` pointing at the staged directory. **1.2 GB per checkpoint** -
  this needs an explicit capacity decision against the AIPC disk budget, and it
  belongs in `ollama-models.txt`'s sibling list, not an implicit download.
- **Open question, needs your decision:** is a 1.2 GB addition to the bundle
  acceptable, and should `english` (another 1.6 GB) be included or left out?

### Phase 1 - `pacgate-mcp` gains a `laya` tool group

- New tools: `pacgate_clause_risk`, `pacgate_clause_flags`, `pacgate_route_language`.
  Each takes clause text plus a question set and returns typed answers with
  confidence, forwarding to `laya-serve` over HTTP exactly as the existing
  helpers forward to `pacgate-api`.
- Gate first, red-checked: `scripts/test-laya-tools.ps1` asserting the tools are
  advertised, that a missing `laya-serve` degrades to an explicit unavailable
  result rather than an exception, and that `min_confidence` is actually
  forwarded (the abstention property is the whole point).
- `pacgate-mcp` is our image, so this ships on a version bump and is covered by
  `test-release-provenance`.

### Phase 2 - the service, validated in CI

- `deploy/laya-serve/Dockerfile` + compose service in **both** lanes
  (`compose.prod.yaml`, `compose.bundle.yaml`), healthchecking `/health` and
  pinning `LAYA_REVISION` + `LAYA_SHA256_DIGESTS` (the repo ships that
  supply-chain pair; use it).
- Blocked locally. The base image resolves only in CI. Do not mark this done
  until the release workflow has produced and pushed it.

### Phase 3 - optional jev-mcp substitution, deferred until wanted

- Pure configuration: `JEV_PROVIDER=compatible`,
  `JEV_API_BASE_URL=http://laya:8000/v1/systemone`, no key.
- Deferred because it buys twelve judgment tools we have not yet found a use
  for, and costs a Node 22 image (Docker Hub, blocked). Revisit when a concrete
  workflow wants `jev_gate` or `jev_extract`.

### Phase 4 - REJECTED: do not ship loop skills to the product

Superseded by a check that should have come first. The product's seed corpus is
three Chinese-law skills (`cn-contract-review`, `cn-nda-review`,
`matter-scoping`) and contains no code-oriented instructions at all. `loop-verifier`
and `minimal-fix` are **software-engineering** skills: run the project's tests,
review a diff, find reasons to reject a patch, fix a CI failure.

Shipping them would put instructions about diffs, test commands, and CI failures
into a lawyer-facing skill corpus, where they would dilute skill matching and
describe work the product never does. The original justification - "we already
run this discipline through `test-workflow-mutations`" - was about *our* process,
and our process is not a client capability. These belong in the agent skill
directory (`~/.agents/skills`), which is where they already are, and that costs a
client nothing.

The `user_invocable` finding stands as a fact worth keeping: seven external
skills would have loaded as zero, silently. That is a reason to check
frontmatter on any imported skill, not a reason to import these.

### Phase 5 - NOT IMPLEMENTED: openui needs a pinned image first

Left out deliberately, for two reasons that are not about effort.

1. **The only available reference is `:latest`.** `ghcr.io/wandb/openui:latest`
   resolves (HTTP 200), but an unpinned third-party image in a client-facing
   compose file is a supply-chain hole - the tag can change under a deployment
   with no diff and no review. Pinning by digest is the precondition, and a
   digest has to be re-verified per release.
2. **No contract-review use.** It renders generative UI from a prompt. The
   defensible use is scaffolding proposal pages in `docs/`, which is our
   development surface, not the client's.

If it is ever revisited: pin by digest, keep it behind a profile, and never in
the client bundle default. Not worth a compose stanza today.

## Standing rule, unchanged

Any skill added to `deploy/client-bundle/deer-flow-skills/` must pass
`test-skill-evolution.ps1` (E1-E6) and `test-skills-and-templates.ps1`, must have
no network dependency at skill runtime, must ship no executable support files,
and must keep its frontmatter within `ALLOWED_FRONTMATTER_PROPERTIES` -
`{name, description, license, allowed-tools, metadata, compatibility, version,
author}`. A key outside that set makes the loader reject the skill silently.
