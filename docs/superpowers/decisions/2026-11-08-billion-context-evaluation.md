# Evaluation: billion-context for Pacgate's long-context, regression and document-generation gaps

**Date:** 2026-11-08
**Subject:** [ranxianglei/billion-context](https://github.com/ranxianglei/billion-context) (npm `billion-context`, MIT, v0.1.213)
**Verdict:** **Do not adopt into the Pacgate bundle.** Borrow two ideas from its technique instead. Rationale below, per claim.
**Status:** evaluation only. Nothing installed, nothing wired, no runtime touched.

## What the tool actually is

A **context-compression proxy for interactive CLI coding agents**. It sits between an agent
(pi, OpenCode, Codex, Claude Code, Gemini CLI, Copilot CLI, aider, crush, zed, and ~15 others) and
that agent's model API, rewriting Anthropic/OpenAI streams, and injecting four context-management
tools the model calls itself: `compress`, `decompress`, `search_context`, `acp_status`.

Published as a Node package (`engines: node>=20`, `bin: bili`, `bili-proxy`), with a hard runtime
dependency on `mysql2`. Ships a paper: *Model-Driven Incremental Hierarchical Compression:
Training-Free Multi-Generational Context Management for Long-Lived Coding Agents*.

That framing is the whole basis of the verdict: it is an **operator-side tool for a human running a
coding agent**, not a library a server-side application calls.

## Claim-by-claim: does it address our gaps?

### 1. The summarization treadmill — no, and it would not help

`deploy/DEFECT-summarization-treadmill.md` is a **threshold bug, already fixed and gated**:
`trigger` was 12000, *below* our unremovable per-call floor of **14,728 tokens** (3,220 system
prompt + 11,508 for 45 tool schemas). Summarization could remove messages but not the floor, so it
fired on every call — 6 recorded passes, each a full extra LLM call on the same single Ollama runner
slot. Fixed to `trigger: 36000` / `keep: 6000` / `trim_tokens_to_summarize: 36000`; gated by
`scripts/test-summarization-treadmill.ps1` (S1/S2/S5), proven against 147 real post-summarization
states: 0 of 147 fire under the applied config.

billion-context does not change that arithmetic. It compresses **messages**, exactly as ours does,
and it **adds four tool schemas to every request**, which grows the floor it cannot compress. On the
one defect class that actually caused a silent user-visible hang ("42 steps and no report"), this
would be neutral-to-worse, and it would introduce a *second* compression path in the same lane —
a new ungated failure mode in the place we already paid for.

### 2. The recursion wall — no, different mechanism

`deploy/DEFECT-recursion-budget-floor.md`: 22 runs died at exactly 1000 super-steps with
**114-136 LLM calls**, only **15 distinct tool-call payloads**, and a stable **~9.0 super-steps per
model call**. The cost is structural, not pathological: nine middleware `before_model`/`after_model`
hooks are each their own graph node. Compression reduces **tokens per call**, not **super-steps per
call**. The applied fix — `DEERFLOW_MIN_RECURSION_LIMIT` floor of 2000 plus the frontend no longer
pinning 1000 — is the correct lever. Nothing here is improved by a context compressor.

### 3. Document generation — no, not a context problem

Two separate defects, neither window-related:
- `DEFECT-docx-tracked-edit-nesting.md` — a **write-side XML bug**: the writer spliced tracked edits
  inside a `<w:t>` text node, truncating the paragraph; the reader then stopped at the first `<`.
- The "report produced but never shown" symptom was the treadmill above: the PDF *was* written
  (912,762 bytes); the run never emitted a closing message.

Neither is "the model ran out of window". Adding compression does not touch either.

### 4. We are not window-constrained

Measured on this box:

| Model | Context | Where |
|---|---|---|
| `nemotron-3.5-bolt:e4b-q8_0` (Mid=Low) | **65,536** | on-device |
| `ornith-1.5:9b` | 262,144 | on-device |
| `nemotron-3.5-bolt:74b-a9b-iq2` | 262,144 | on-device (MAX+ 395 carve-out) |
| `deepseek-v4.1-flash:cloud` (Main) | provider window | `ollama.com` via `:cloud` tag |

A 36k trigger plus an 8k completion is ~44k — already well inside 65,536, which the config block
states explicitly. A tool whose premise is *"a 100K context is enough"* is solving a scarcity we do
not have on the local tier, and certainly not on the cloud Main tier.

### 5. Wrong layer for our stack

Our agent runtime is a **server-side Python LangGraph service** (deer-flow) rendering on
`langchain_openai:ChatOpenAI` → `base_url: http://host.docker.internal:11434/v1`, carrying ~30
bind-mounted patches. billion-context offers no Python client and no application API; its seams are
`bili <client>` launchers and per-CLI plugins. Routing deer-flow through it would mean pointing
`base_url` at a Node MITM proxy and hoping its stream rewrites coexist with our patches
(`deer-flow-model-factory.py`, `deer-flow-prompt.py`, `deer-flow-run-recursion-cap.py`, the deferred
tool filter, the loop guard). None of that is a supported integration, and every one of those
patches is currently gated by `audit-deer-flow-patches.ps1`.

### 6. Disqualifier for a legal product: no tenancy model

The README mentions `tenant`, `matter`, `account`, `per-user` and `isolation` **zero times**, while
depending on `mysql2` — so it *does* persist folded conversation, scoped to a session, with no
tenant boundary because it was never asked for one.

Pacgate is tenant/matter/actor-scoped throughout: OpenViking maps `TenantId`→`X-OpenViking-Account`,
`MatterId`→`X-OpenViking-Actor-Peer`, and the ethical wall is proven by `PEER_NOT_ALLOWED` — write a
memory under matter A, it is not recalled under matter B. Session capture is deliberately kept on
`PacgateMemoryStorage` → pacgate-api so it stays inside that boundary.

A component that can **`decompress` and `search_context`** on demand creates a second, unscoped
store of matter conversation. For a firm handling privileged material, that is not a performance
trade-off, it is a data-residency question — the same class we already refuse elsewhere
(cloud chat is an accepted, *recorded* egress decision; an unmodelled third store is not).

### 7. Its own numbers do not transfer

"95-97% prefix-cache hit rate" and "5× fewer tokens" are measured on their stack — provider APIs
with prefix caching. Our local tier is Ollama's own prompt cache, and our Main tier routes
`ollama.com`. We would have to re-measure, and we already have a benchmark harness
(`bench-local-models.ps1`, `BENCHMARK-LOCAL-MODELS-2026-11-04.md`) that shows local reality differs
from provider claims.

## Decision

**Do not adopt.** Not because the tool is poor — the paper is serious and the engineering is real —
but because it targets a layer we do not have, a scarcity we do not have, and a tenancy model we
cannot give up.

### Two ideas worth borrowing, in our own code, behind our own gates

1. **Reversibility.** Our summarizer is destructive: it emits `RemoveMessage` and replaces history
   with one summary. billion-context's `decompress` is the interesting part — a run can recover an
   early detail after folding it. In a 65-page document workflow that is a real capability, and it
   is a bounded change to our summarization lane, testable against the 147-state replay we already
   have.
2. **Context-usage visibility.** `acp_status` exposes "how full is the window, what is still
   compressible". We have no such surface; a user cannot currently tell whether a run is near the
   trigger.

Both are **our** work, gated by **our** tests. Cost is small and the risk is bounded.

### What a legitimate trial would look like

A **throwaway spike on the dev box only** — install `bili`, point one interactive coding agent (not
deer-flow) at it, and read the paper's incremental-hierarchical technique against real sessions.
That teaches us the method without putting a tenancy-blind proxy in front of privileged matter
traffic. It is explicitly *not* a bundle change, and it must not be promoted into `compose.*.yaml`.

## If the premise changes

Re-open this if **any** of the following becomes true:

- deer-flow gains a supported non-CLI Python client seam for compression, or the project publishes a
  library rather than CLI plugins;
- we acquire a genuine window constraint (e.g. a client class pinned below ~32k effective context);
- a tenancy-scoped fork appears, or we would only ever run it on non-matter coding sessions;
- our own summarization lane proves unable to hold a workflow that billion-context demonstrably
  does — measured on our corpus, with our gate.
