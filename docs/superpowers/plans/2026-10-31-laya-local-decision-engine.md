# laya as a local decision engine, and the four repos reconsidered

Status: research and implementation plan, 2026-10-31.
Supersedes the verdict table in `2026-10-31-third-party-skill-adoption.md`.

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
