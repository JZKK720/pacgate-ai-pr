# 035 — Ten-Repo Evaluation and Integration Plan (pacgate-ai e2e)

Status: **PROPOSED (re-evaluated 2026-11-22)** · Scope: pacgate-ai bundle stack
(deer-flow + qm + pacgate-mcp), **not** the VS Code agent host.

This document was revised after the user pushed back on four points: (1) Univer
is more than redline, (2) re-consider DataFlow-WebUI / AG-UI / OpenIntelligentUI
plus UI-animation repos, (3) billion-context had no implementation verdict, and
(4) qm's `pi` is model-wired to Ollama so should be re-examined. All four are
answered below, and **two of the answers overturned earlier conclusions**: Univer
`engine-formula` is worth adopting, and DOCX redlines are a **solved problem** —
not via Univer, and not via hand-rolled OOXML, but via `docx-scalpel`
(Docxodus), whose CJK accept/reject contract was proven exactly on this machine.

Evaluated repos:

| # | Repo | License | Stars | Verdict |
|---|------|---------|-------|---------|
| 1 | [dream-num/univer](https://github.com/dream-num/univer) | Apache-2.0 core | 31.1k | **REJECT as editor** · **ADOPT `engine-formula`** (P1.5) |
| 2 | [omnara-ai/omnara](https://github.com/omnara-ai/omnara) | Apache-2.0 | 3.4k | **REJECT as orchestrator** · watch as substrate |
| 3 | [OpenDCAI/DataFlow-WebUI](https://github.com/OpenDCAI/DataFlow-WebUI) | Apache-2.0 | 257 | **REJECT as product** · steal 2 patterns |
| 4 | [ag-ui-protocol/ag-ui](https://github.com/ag-ui-protocol/ag-ui) | MIT | 21.0k | **DEFER** · Phase 3 trial endpoint only |
| 5 | [CopilotKit/OpenIntelligentUI](https://github.com/CopilotKit/OpenIntelligentUI) | MIT | 4.3k | **REJECT as base** · ONE component worth copying |
| 6 | [ranxianglei/billion-context](https://github.com/ranxianglei/billion-context) | MIT + attribution | 8.1k | **PILOT, SCOPED** · implementation in §2.6.1 |
| 7 | [Yuan-ManX/open-motion](https://github.com/Yuan-ManX/open-motion) | MIT | 189 | **REJECT** · 492 tool schemas ≈ 74K tokens (§2.7) |
| 8 | [Hada45/Open-Motion](https://github.com/Hada45/Open-Motion) | MIT | 35 | **REJECT** · video motion-graphics, wrong domain (§2.7) |
| 9 | [fireX-bit/AimatorsAreGoats](https://github.com/fireX-bit/AimatorsAreGoats) | **none** | 0 | **REJECT** · 2 files, no source, no LICENSE (§2.7) |
| + | [JSv4/Docxodus](https://github.com/JSv4/Docxodus) → PyPI `docx-scalpel` | MIT | 121 | **ADOPT for redline** (P1.6) · CJK accept/reject contract proven |

---

## 0. Executive summary

Three conclusions, in order of importance.

**1. The `billion-context` premise is inverted.** It compresses *conversation*, not
*static tool schemas*. Its own configuration docs name the static floor as
irreducible and tell the user to prune tools themselves. We already did that —
better, and in-house (see §1). So it cannot fix the 192K-token static block. It
*can* help a different, real problem: long single sessions. And it is **not**
OpenViking-like and should **not** be wired as an MCP server.

**2. Five of the six original repos fail on integration cost, not on capability.**
Each is real and well-built. Each would require us to replace a layer we already
own and have already debugged — deer-flow's tool_search deferral, our SSE layer,
our message store, our auth. The measured cost of that replacement exceeds the
gain. Two exceptions survived re-evaluation and are narrow: Univer's
**`engine-formula`** (one Apache-2.0 package that closes a real OfficeCLI gap),
and **`docx-scalpel`** (MIT), which turns DOCX redlines from "blocked" into
"solved and proven".

**3. The highest-value action in this evaluation is not adopting anything — it is
sending fewer bytes per call.** Measured in §1.0: on this session, model time was
**90.4% waiting for the first token**, the cache was already **~99.4% hit** (a
450k-token prompt still took 14 s), and a same-size payload with **more** tokens was
**faster** — so latency tracks **bytes on the wire**, not tokens. The fitted model at
100% cache hit is `2698 + 20.86 ms per 1k tokens`; at this session's 239k mean prompt
that is **7.7 s of pure waiting per call**, versus 3.7 s at 50k.

**Consequence: do not spend effort on cache tuning.** It is saturated. Spend it on
payload size and on not re-sending an unchanged history. See §1.0 and P0 route C.

**Recommendation: implement P0 and P1. Defer P2. Reject P3 outright.**

---

## 1. Ground truth measured for this plan

### 1.0 The dominant cost is PAYLOAD TRANSFER, not tokens, not cache — measured 2026-11-22

This is the finding that reorganises everything else, so it comes first.

**This session's own numbers** (`agentSessionData/b7726dae…/session.db`, 18 turns):

```
total input tokens   : 4,066,493
mean input per turn  :   239,216
max input per turn   :   456,349
output/input ratio   :      0.49%   <- 99.5% of what we pay for is re-read, not produced
cacheReadTokens      :         0   (BYOK reports nothing; see below)
TTFT share of model time:   90.4%  <- it is nearly all waiting for the first token
```

**A 450k-token prompt costs 14-25 s even at a 100% cache hit.** Measured directly
against the local daemon:

| prompt | bytes | tokens | cached | wall |
|---|---|---|---|---|
| small | 0.08 MB | 14,034 | 13,900 | 2.1 s |
| med | 0.38 MB | 70,034 | 69,900 | 4.7 s |
| large | 1.53 MB | 280,034 | 279,900 | 9.3 s |
| huge | 3.05 MB | 560,034 | 559,902 | 13.9 s |

Fitting those four points gives, **at 100% cache hit**:

```
latency_ms = 2698 + 20.86 ms per 1k tokens
```

**The decisive experiment.** Two payloads of the SAME byte size, one with 375k
tokens and one with 464k (24% more tokens):

```
3MB, few tokens   tokens=375,033  wall=25,243ms
3MB, many tokens  tokens=464,034  wall=21,619ms
   -> latency ratio 0.86x: the one with MORE tokens was FASTER
```

**Latency tracks bytes, not tokens.** The bottleneck is shipping the JSON body to
`ollama.com` and reading it back, so:

- **Prompt caching cannot fix this.** It was already at 100% and the call still took
  14 s. `cacheReadTokens: 0` is a BYOK *reporting* gap, and the real cache hit rate
  is ~99.4% on identical prompts (measured: `prompt_eval_cached_count 20908/21038`).
  Tuning a cache that already hits is not where the money is.
- **A one-character change invalidates everything after it.** Measured: identical
  prompt → `cached=20908`; one char changed deep in the prefix → `cached=0`. That is
  real, but it only matters when the payload is large, which leads to the actual fix.

**What actually reduces latency, in order of effect:**

1. **Send less.** The fitted model says a 50k-token prompt is **3.7 s** against
   **7.7 s** at this session's 239k mean — 2.1x — and the byte experiment says the
   relationship is linear in payload size, so it keeps improving. This is a
   *conversation-discipline* fix (fresh session per task, fewer re-reads), not a code
   change.
2. **Do not re-send what has not changed.** 0.49% output/input means the agent is
   re-transmitting its entire history every call. Anything that trims the re-sent
   body helps proportionally to the bytes it removes.
3. **Cache tuning: no measurable headroom.** Already ~100%.

**Honest caveat:** the 20.86 ms/1k figure is from a *warm* local daemon talking to a
cloud model, on this box's uplink. The constant term and the slope will differ per
client site, but the *shape* — linear in payload bytes, cache-saturated — is the
property that matters for planning.


Everything below was measured on this machine on 2026-11-22, not quoted from
vendor docs.

### 1.1 pacgate-ai-pr does not contain the technologies five of six repos assume

| Probe | Result |
|---|---|
| Java (`pom.xml`, `build.gradle`) | **none** |
| .NET (`*.csproj`, `*.sln`) | **none** |
| Bicep / Terraform | **none** |
| Cosmos DB config | **none** |
| SQL files | 3 (`seed-base-model.sql`, `001_initial_schema.sql`) |
| SQL tool calls across pacgate sessions | **0** |

Consequence: azure/cosmos/mssql/java/dotnet tooling contributes zero value here.

### 1.2 pacgate already solved static tool bloat in-house

`deploy/deer-flow-pacgate/config.yaml:204-209`:

```yaml
# Pacgate: DEFER MCP tool loading to cut system-prompt size dramatically.
# MCP tool schemas are NOT bound into context; listed by name and fetched on
# demand via tool_search. Removes ~36K tokens of MCP schema from every prompt.
tool_search:
  enabled: true
```

`deploy/client-bundle/patches/deer-flow-deferred-tool-filter.py` records the
measured justification:

- MCP schemas were **32,023 of 42,582** bound characters
- deferral removes **~8,005 of ~10,645 tokens** per call (**75%**)
- at **528 tok/s** prefill that is **~15 s of fixed cost per call, every turn**

This is upstream deer-flow `tool_search`, which shipped **disabled** because
small models fail the promote-then-retry loop. The pacgate patch converts the
block into a transparent promotion. That patch is the load-bearing piece, and it
is ours.

### 1.3 The tool-count spread *(superseded by §1.0 — cache tuning has no headroom)*

Kept because the measurement is real and the withdrawal should be legible. Read
§1.0 first: the latency is bytes-on-the-wire, and the cache already hits ~99.4%, so
the ms/1k spread below is a *description* of a cost, not a lever.

Session `ac564b88` (pacgate workspace, 3,689 model calls) spends most of its calls
at 19-46 tools, then spikes to 877 — **291 tool-set flips, 7.9% of all calls**:

| tools | calls | avg TTFT | avg input | ms / 1k tok |
|---|---|---|---|---|
| 19 | 132 | 3,115 ms | 59,824 | **52.1** |
| 21 | 61 | 9,505 ms | 55,591 | **171.0** |
| 46 | 238 | 12,088 ms | 176,879 | 68.3 |
| 596 | 1,749 | 7,762 ms | 389,790 | 19.9 |
| 876 | 200 | 6,888 ms | 398,253 | 17.9 |

`19` and `21` differ by two tools and 4K tokens, yet run **3.3x apart** in
ms/1k-token. A changed tool block invalidates the provider's byte-exact prefix
cache. This is cache invalidation, not context size.

Only **16 of 291** flips followed a sub-agent call, so sub-agents are not the
driver.

### 1.4 The 192K figure is from a different workspace — but pacgate spikes too

*(Context only. §1.0 explains why the static block is not the lever: it is re-sent
bytes, and the tool block is a fraction of a 1.4-3.0 MB request body.)*

| session | repo | max tools | max tool tokens |
|---|---|---|---|
| `565bcf75` | pacgate | 1,068 | 485,103 |
| `2c2218fc` | pacgate | 1,021 | 472,764 |
| `120108e9` | pacgate | 790 | 242,493 |
| `cd5b70dc` | **cubecloud-agentic-os** | 638 | 199,082 |
| `ac564b88` | pacgate | **877** | **272,067** |

The 619-tool / 192K number quoted in earlier analysis came from `cd5b70dc`,
which is **not** pacgate. But the correction cuts both ways and must be stated
plainly: pacgate's own `ac564b88` spends 3,689 calls oscillating between **19 and
877 tools** (5,747 to 272,067 tool tokens). So the static problem is real in
pacgate — it is simply **not the steady state**. The steady state is ~21 tools /
16K tokens; the spikes are what cost us.

This is why P0 targets stability rather than size. Shrinking the floor further
buys little at 21 tools; eliminating the 19↔877 swing buys back the measured
3.3x.

### 1.5 Runtime facts that constrain every integration

| Fact | Value | Source |
|---|---|---|
| deer-flow context ceiling | **65,536** (silently clamped) | `deploy/deer-flow-pacgate/config.yaml:63` |
| deer-flow max_tokens | 8,192 | same |
| qm harness | `pi`, `MODEL_BASE_URL=http://host.docker.internal:11434/v1` | `deploy/qm-pacgate/qm.config.jsonc` |
| openviking | embeddings **only** — `nomic-embed-text`, 768-dim, via Ollama | container env |
| pacgate-mcp | 26 `@mcp.tool()` functions, FastMCP, `streamable-http` | `deploy/pacgate-mcp/server.py:1985` |
| deer-flow frontend | upstream bytedance Next.js + `deploy/frontend-patches/` | `deploy/deer-flow-frontend-pacgate/Dockerfile` |

---

## 2. Per-repo verdicts

### 2.1 Univer — REJECT as editor, ADOPT one package (`engine-formula`)

This section was re-evaluated 2026-11-22 on the user's objection that Univer is
more than redline: "other SDK, Form and Canvases". The objection is worth
answering precisely, because **two of the three named capabilities do not exist
and the third is not OSS.**

#### 2.1.1 The redline question is closed, and it is not a licensing issue

- `trackChanges` appears **0 times** repo-wide. `acceptChange|rejectChange|
  suggestionMode` likewise.
- `CustomDecorationType` has only `COMMENT` and `DELETED`; `DELETED = 9999` is an
  internal tombstone whose style resolver returns `null`
  (`packages/engine-render/.../custom-decoration.ts:37-39`).
- Univer's own comparison matrix, which covers the **commercial** SDK, marks
  Track Changes **Not supported**, and the adjacent row says Compare Documents
  *"returns structured differences; it does not generate a new document with
  tracked changes."*

#### 2.1.2 "Forms" does not exist. "Canvas" is the paid Boards whiteboard.

Verified by git history, not by reading docs:

| Path | Status |
|---|---|
| `packages/boards` | **zero commits ever** |
| `packages/bases` | **zero commits ever** |
| `packages/pdfs` | **zero commits ever** |
| `packages/forms` | **zero commits ever** — and 0 `forms` entries in `docs.univer.ai/sitemap.xml` |
| `packages/charts`, `packages/pivot` | **zero commits ever** |
| `packages/slides` | existed, **deleted 2026-11-04** (PR #8084) |

- **Forms does not exist in any edition** — no `@univerjs/forms`, no
  `@univerjs-pro/forms` on npm, not in the six-product list.
- **Canvas and Boards are the same product.** `README.md:626`: *"canvases'
  `IBoardData` (called **Boards** in the API)"*; the comparison page labels the
  column "Canvas (51)". It ships only as `@univerjs-pro/boards` — commercial, and
  with **no headless preset at all**, not even a paid one.
- **Slides (pptx) is not OSS.** OSS `@univerjs/slides` was deleted. The npm
  artifact `@univerjs/slides@1.3.1` is an orphan pinned to a dead minor while the
  rest of the line is at 1.6.0; `README.md:228` requires keeping all
  `@univerjs/*` on the same version. Unusable.

#### 2.1.3 The OSS surface is exactly two content models: Sheets and Docs

| Surface | Package(s) | License |
|---|---|---|
| **Sheets** (model + UI + formula + numfmt + filter + sort + table + validation + conditional formatting + comments + drawing) | `@univerjs/sheets*` | **Apache-2.0** |
| **Docs** (model + UI + drawing + TOC + hyperlink + comments) | `@univerjs/docs*` | **Apache-2.0** |
| **Formula engine** | `@univerjs/engine-formula` | **Apache-2.0** |
| Render engine | `@univerjs/engine-render` | **Apache-2.0** |
| Slides / Boards / Bases / PDFs / Charts / Pivot / Shapes / Print / Collaboration / **Office file exchange** | `@univerjs-pro/*` | **`Univer Office SDK Licensing`** |

**OSS cannot read or write any Office file.** Dependency audit of `@univerjs/core`,
`@univerjs/sheets`, `@univerjs/engine-formula` for `xlsx|excel|jszip|docx|ooxml` →
**none**. Docs state it: *"Office conversion requires Server SDK."* So OSS Univer
cannot consume OfficeCLI's `.xlsx` output without a mapper we write ourselves.

Headless is genuinely real, though:
- `@univerjs/preset-sheets-node-core` and `@univerjs/preset-docs-node-core` are
  **Apache-2.0**; Node `>=18.17`.
- `univerAPI.createWorkbook(data)` (`packages/sheets/src/facade/f-univer.ts:93`)
  runs in Node **without a DOM** — `engine-render` is imported but *"never mounts
  a Canvas"*.
- Output is a **snapshot JSON**, not a file.

#### 2.1.4 The gap I thought existed does not

Measured on OfficeCLI 1.0.152: it **computes** formulas, including `SORT`, `XLOOKUP`,
`LET`, `IF`, `CONCATENATE`, `TEXT`, `SUMIF`, and CJK inside formulas
(`CONCATENATE("甲方","与","乙方")` → `甲方与乙方`). It caches the value at write time
(`<x:f>SUM(A1:A2)</x:f><x:v>30</x:v>`).

The only shortfall: after editing a **precedent**, it recomputes internally
(`query --json` returns the new value) but **drops the persisted `<x:v>`**. One
`raw-set --action append '<x:v>…</x:v>'` persists it.

So `engine-formula` would duplicate a capability we already have. **Not adopted.**
Full measurement and the reproducible Univer recipe are in §3 P1.5.

---

#### 2.1.5 DOCX redline: two working paths, both measured (supersedes the earlier "blocked" verdict)

The redline requirement resolves to OOXML `w:ins`/`w:del`. **Two independent paths
now work**, and one is strictly better.

**Path A (chosen): `docx-scalpel` — MIT, pure-Python wheel over Docxodus.**

Discovered via [JSv4/Docxodus](https://github.com/JSv4/Docxodus) (MIT, C#,
*"Word-grade redlines with native tracked changes"*). The Python client is on PyPI
as **`docx-scalpel` 0.13.0**, MIT, `requires_python >=3.10`, and it ships a
**`manylinux_2_28_x86_64` wheel (58.9 MB)** — self-contained, **no .NET install
required** in the container.

**Verified end-to-end on this machine**, CJK contract clause:

```
docx_diff_compare(a_bytes, b_bytes, DocxDiffSettings(
    author_for_revisions="PacGate Legal Review",
    date_time_for_revisions="2026-11-22T13:00:00Z",
    deterministic=True,
    pre_accept_input_revisions=True))
```

Inputs:

```
a: 甲方应于2026年12月31日前支付合同价款人民币壹佰万元整。乙方应在收到发票后三十日内开具增值税专用发票。
b: 甲方应于2026年11月30日前支付合同价款人民币贰佰万元整。乙方应在收到发票后三十五日内开具增值税普通发票。
```

Output — **5 `w:ins`, 4 `w:del`, correct author and date**, and granularity is
exactly right: `12`→`11`, `31`→`30`, `壹`→`贰`, insert `五`, `专用`→`普通`. Not one
whole-sentence replacement.

**The accept/reject contract was proven exactly:**

```
accept(redline).text == b.text   ✔  (0 residual revisions)
reject(redline).text == a.text   ✔  (0 residual revisions)
```

Caveat found: `prove_redline_reversibility()` returned `success=False` on a
`path='relationship'` package-identity mismatch. That is the *stricter* package-bytes
proof, triggered because my two inputs were generated by different producers; the
**text-level contract above held exactly**. Do not treat a package-identity
mismatch as a redline failure.

**Path B (fallback, also working): OfficeCLI `raw-set` + `validate`.**

```
officecli raw-set test.docx /document --xpath "/w:document/w:body:w:p[1]" \
  --action append --xml '<w:ins .../><w:r>...</w:r>'
→ raw-set applied
officecli validate test.docx → Validation passed: no errors found
```

Useful when we must inject revisions without a diff (e.g. applying a
model-authored suggestion list), and as an independent validator for Path A's
output.

**Rejected, tested:**

| Option | Verdict | Evidence |
|---|---|---|
| PyPI `redlines` (installed here) | **REJECT** | No docx writer at all — only `output_markdown`, `output_json`, `output_rich`; `output_docx` does not exist |
| `redlines` on CJK | **REJECT** | Replaced the **entire sentence** (`('replace', 0, 1, 0, 1)`) — Chinese has no spaces to tokenize |
| `difflib` char-level, `autojunk=False` | usable, inferior to Path A | Correct opcodes but you own the emitter and the round-trip proof |
| LibreOffice headless | not evaluable here | Not installed on this box |

**Decision:** Path A is the redline engine. Path B stays as the injection escape
hatch and the validator.

---

#### 2.1.7 BLOCKER found by e2e (2026-11-22): the redline tools cannot reach a `.docx`

**Status: OPEN, needs a design decision.** Recorded in
`deploy/AIPC-0.2.36-E2E-AUDIT.md` §3.3 with the full evidence.

`pacgate_redline_compare` fetches its inputs via `GET /api/documents/:id/download`,
whose body decision (`documents.rs::download_body_for`) is:

```
("sanitized", text_like = false) => RefusedBinary    <-- a .docx
("sanitized", text_like = true ) => SanitisedText
("never",     _                ) => OriginalBinary
_                                => RefusedBinary
```

Observed in the live 0.2.36 stack, both directions:

- `pending` → `409 "document is 'pending'; reading its body requires sanitization
  (or an explicit 'never' decision)"`
- after `sanitize` → `pacgate_read_document` returned **112 characters of Chinese
  text** ending `creator: OfficeCLI lastModifiedBy: OfficeCLI` — the text rendering,
  not a zip. `docx-scalpel` then reported `File contains corrupted data`.
- `never` → would return the binary, but **no HTTP route sets that state**; `'never'`
  exists only as a *read* case in `documents.rs` and `egress.rs`.

So in every reachable state a binary `.docx` cannot be fetched, and the three tools
cannot do their job. **The engine is correct** (gate 8/8 on bytes in memory); the
transport is not. The sanitizer is also right — after redaction the artifact genuinely
is text — so this is a defect in the feature's assumption, not in egress.

Options (not chosen here, because it is an egress decision):

1. **Redaction-preserving binary lane** — redact inside the `.docx` package so a
   "sanitized" binary is truly redacted. Correct; largest change.
2. **Dedicated compare endpoint** — takes two document IDs, builds the redline from
   the *original* package under an explicit audited `ReadPurpose`. Smallest change
   that keeps the audit trail honest, and it reuses the existing `ReadPurpose`
   mechanism.
3. **Remove the tools** — shipping an unusable tool is worse than not shipping it.

Option 2 is recommended.


#### 2.1.6 Path A details worth knowing before implementation

`docx-scalpel` exposes 282 symbols, of which the ones we need are:

```
docx_diff_compare(left, right, settings=None) -> bytes      # redlined DOCX
docx_diff_accept_revisions(redline) -> bytes
docx_diff_reject_revisions(redline) -> bytes
docx_diff_get_revisions(redline, right) -> [...]            # needs BOTH args
docx_diff_get_semantic_changes / get_edit_script / get_conflicts
prove_redline_reversibility(...)                            # strict package proof
```

`DocxDiffSettings` fields that matter to us: `author_for_revisions`,
`date_time_for_revisions`, `deterministic`, `pre_accept_input_revisions`,
`revision_granularity`, `detect_moves`, `track_cell_insertions_and_deletions`,
`track_numbering_changes`, `compare_headers_footers`, `word_separators`,
`culture`.

The package also ships an **MCP server for AI agents** (per its README), which is a
second delivery route if we would rather expose redlining as a tool than as a
library call — evaluate only if the library path proves awkward.

Note the default revision author is literally `Docxodus` and the default date is
`2000-01-01T00:00:00Z`; set both explicitly or the audit trail is meaningless.

---

### 2.2 omnara — REJECT as orchestrator, watch as substrate

**Question asked:** how can we manage our multi-agents with the pacgate-ai
bundle full stack?

**Answer: it does not orchestrate, and it would put a second control plane in
front of a bundle that already ships one.**

It is a real Go control plane (api / worker / maintenance / migrate / `omnarad`
daemon) with Postgres-as-queue (`FOR UPDATE SKIP LOCKED`), leased stateless
workers, per-step transactional checkpointing, and reconstruction-on-claim. That
is legitimately well-engineered.

But on the critical distinction:
- Sub-agent tools are exactly five: `spawn_agent, read_agent, send_agent_message,
  stop_agent, list_agents`.
- `spawn_agent` **returns immediately**; the child's answer arrives later as a
  message. There is **no** `wait_agent` / `join_agents` / `gather`.
- **No DAG**, no `steps:`, no `depends_on:`, no fan-in, no supervisor graph.
- `max_depth` defaults to **1** (grandchildren forbidden), hard cap 8.
- The canonical parallel example tells the *prompt* to use git worktrees —
  isolation is prompt-engineered, not enforced.
- **No Python SDK** (TS + CLI + MCP only).
- Self-host needs **PostgreSQL ≥18 + Redis/Valkey + S3 + a shared POSIX mount**
  in api/worker/maintenance; docs warn naively pointing two instances at RWX/NFS
  "gives you silent corruption".

Model-agnostic is genuine, including Ollama — but loopback egress is blocked by
an SSRF guard unless `OMNARA_PRIVATE_ENDPOINT_CIDRS` is set on api, worker **and**
maintenance.

**Decision.** Do not adopt. The bundle (deer-flow + qm) is already a control
plane; omnara would be a third. Track it as a possible *durable execution
substrate* if we ever need cross-machine run resumption. It is not that need
today.

---

### 2.3 DataFlow-WebUI — REJECT as product, steal two patterns

**Question asked:** how can we generate DataFlow-WebUI for pacgate, for deerflow
and qm?

**Answer: we should not generate it for either. It is not embeddable by design.**

Hard blockers, all sourced:
- `CLAUDE.md:3-7` states the project is **single-user, local-first** and that
  adding **"login pages, JWT/session infrastructure, or per-user ACL"** is
  prohibited — listed again under "Still prohibited".
- Identity is `user_id = websocket.query_params.get("user_id", "default")` against
  an in-process `dict[str, WebSocket]` — **not a security boundary**.
- CORS is hardcoded to a localhost regex (`main.py:26`).
- Every `/api/v1` error returns **HTTP 200** with `{success:false}` — breaks any
  sane client contract.
- The NL2Pipeline leg is a **WebSocket streaming a `claude`/`codex` subprocess**,
  not a request/response API. The "NL2" capability *is* a third-party coding agent
  plus a `SKILL.md`.
- Execution is arbitrary Python via Ray — **RCE by design**, self-admitted.
- **No export-to-code.** Searched `to_code|export_pipeline|as_python|
  download_pipeline` → 0 hits.
- Pins `open-dataflow==1.0.10`; PyPI latest is **1.0.13**. 23 commits in 6 months,
  12 contributors. Issue #78 (`re.template` removed in Python 3.13) **open 7
  months, unanswered**.

**What is worth stealing (this is the real answer):**
1. **`PipelineValidationIssue`** — carries `suggested_fields` **and**
   `repair_hint` (`backend/app/schemas/pipelines.py:120-135`). Structuring a
   validation error so the model can self-repair is the single best idea in that
   repo, and it maps directly onto `pacgate_clause_flags`.
2. **The operator discovery ladder** — `list_categories → recommend → by_category
   → get_operator_detail` (`skills/canonical/.../SKILL.md:49-68`). This is a
   budget-bounded tool-discovery protocol. It is the same shape as our
   `tool_search` deferral, but two-stage.

**Decision.** Reject for both frontends. Do not fork. Adopt idea (1) as a small
change to `pacgate-mcp`; keep idea (2) as reference for P1.

---

### 2.4 AG-UI — DEFER to Phase 3, trial one endpoint behind a flag

**Question asked:** can we adapt and integrate AG-UI within pacgate-ai?

**Answer: yes technically, and no strategically — not yet, and not for Vue.**
The SDK path was exercised on 2026-11-22 (§3 P3): `ag-ui-protocol==1.0.0` (MIT,
`pydantic>=2.11.2` only) encodes a pacgate-shaped run to valid SSE with CJK intact
and correct camelCase wire keys.

It is a real spec: **1.0 frozen 2026-09-17**, ~31 typed events, JSON Schema,
conformance fixtures, three generated SDKs (TS/Python/.NET), MIT. Complementary
to MCP (AG-UI = agent↔frontend, MCP = agent↔tools, A2A = agent↔agent), so our MCP
investment is preserved.

The costs that matter for us:
- **HTTP-SSE binding has no `Last-Event-ID` resumption.** Our WebSocket resume
  would become a documented deviation.
- **Interrupts are terminal-run + resume**, requiring thread persistence. A
  "socket stays open while a human thinks" design must be rebuilt.
- **The Vue path is thin.** `@copilotkit/vue` is ~19.3k weekly vs 818k for React,
  and drags `chart.js`, `maplibre-gl`, `@jetbrains/websandbox`, `@a2ui/web_core`.
  Without CopilotKit's opinions you hand-write an `AbstractAgent` runtime.
- **qml's web-ui is not a Next.js app** — it would be the hand-written client.
- 1.1 is already in draft; shims expire 2027-09-17.

**Decision.** Phase 3, one endpoint, behind a flag, no production dependency.
`pin ag-ui-protocol==1.0.x` and pin `@ag-ui/*` exactly. Do not touch the existing
SSE path.

---

### 2.5 OpenIntelligentUI — REJECT as base, copy exactly one component

**Question asked:** can we enhance and integrate this for our deerflow frontend?

**Answer: it is a reference app, not a library. Almost nothing is installable.**

- Every JS workspace package is `"private": true`. **No npm package named
  `openintelligentui`** (registry 404). **0 git tags, 0 GitHub releases.**
- 6 contributors, 141 of 162 commits by one CopilotKit staff engineer. Root
  `package.json` is still named `"copilotkit-langgraph-template"`.
- It hard-depends on `@copilotkit/react-core/v2` + `@copilotkit/runtime@1.55.2-next.1`
  (a **`-next` prerelease**) and therefore on `@ag-ui/*@0.0.52`.
- Its state layer is self-admittedly **process memory**:
  *"Restarting or scaling the agent can lose or split conversation state"*;
  `BoundedMemorySaver(max_threads=200)`.
- Open issue #87: with non-Claude models `generateSandboxedUi` is never called →
  *"0 iframes in the DOM"*. Our default is a local Nemotron. That is our exact
  configuration.
- The interesting capability (free-form generative UI) is **not in this repo** —
  it is upstream CopilotKit's `openGenerativeUI` flag plus its built-in activity
  renderer.

**The one genuinely drop-in piece:** `@copilotkit/a2ui-renderer` is a real
published React package with only `react`/`react-dom` peer deps — **no
CopilotKit dependency**. `createCatalog({Table:…}, {Table: DataTable})` from
`apps/app/src/components/generative-ui/table-catalog.tsx:66-76` is ~10 lines and
gives a schema-validated, accessible table renderer for agent tool results.

**Decision.** Do not adopt the app. Phase 2 may copy the A2UI table renderer
into `deploy/frontend-patches/` as a patch file — that is the whole extent.
Verify the `createCatalog` signature against the version actually installed; the
repo pins `1.55.2-next.1` and the package has since moved.

---

### 2.6 billion-context — PILOT, SCOPED (and it is not OpenViking-like)

**Question asked:** would it be like openviking or MCP to pacgate-ai, which
session can be wired and called from deerflow and qm?

**Answer: neither. It is a proxy, it does not fix our pain, and the MCP framing
is wrong.**

**What it actually is.** A local HTTP proxy (`bili` / `bili-proxy`) that sits
between an agent and its **model API**, rewriting Anthropic/OpenAI/Responses/
Google streams. Interception is either a locally generated MITM root CA
(`"billion-context MITM Root CA"`) or a base-URL rewrite `/bili/<absolute-url>`.
It injects four tools (`compress`, `decompress`, `search_context`, `acp_status`)
and nudges the model to call `compress` every ~50K new tokens.

**License — resolved, and it is usable.** GitHub says `NOASSERTION` because the
LICENSE is MIT *plus* one term. The deciding clause:

> "if you use or incorporate the Software … in a product or service that end users
> can see or interact with — whether commercial or open source — you must make
> attribution clearly visible in … the product's home page; … documentation; or …
> 'About' / 'Credits' … For purely server-side or embedded uses with no
> user-facing surface, carrying these notices in the shipped documentation
> satisfies this term."

No non-commercial clause, no field-of-use restriction, no copyleft. Safe for
commercial deployment with one credit line in the shipped docs.

**Why it does NOT fix the 192K static block.** From its own configuration docs:
when the irreducible baseline (system prompt + **tool definitions** + live tail)
exceeds the target, the target is **raised** to that measured size. Its own FAQ
tells you to trim the system prompt and disable unneeded tools yourself. It
compresses **conversation and tool results** — a different pool.

**Why the MCP framing is wrong for us specifically.** deer-flow already defers
MCP schemas (`tool_search.enabled: true`, §1.2). Adding a tool that grows the
tool block would work against the exact mechanism that bought us 75%.

**Why the OpenViking framing is wrong.** OpenViking is an embedding/retrieval
service (768-dim `nomic-embed-text`). billion-context is a stream rewriter with
no embeddings. They are not substitutes.

**The real blocker for our stack.** State is local files + SQLite; from the
README:

> "One conversation belongs to one instance for its whole life. … There is no
> shared store between instances: nothing replicates, nothing fails over, nothing
> rehydrates a session onto a different instance."
>
> "Pointing two instances at the same RWX/NFS path does not give you a shared
> store — it gives you silent corruption behind a timeout."

**Honest expected gain.** Their own paper gives **1.2-1.8x** for 200K-class
windows. The "5x" figure is a 1M-window marathon artifact and they say so.
Compression also costs a summarizer call per fold and can add proxy-side
re-request rounds (`MAX_LOOP_ROUNDS = 10`), which can *worsen* our
1,300-calls-per-16-messages symptom while cutting tokens per call.

**Honest trust read.** ~200K LOC, 9.5K commits, 1,571 test files, a separately
published pure engine (`acp-kernel`), Z3 proofs, and a paper that volunteers its
own weaknesses (`[V]/[A]/[P]` claim register, "counterfactual savings partly
modeled", "summary quality unquantified"). That is unusually self-critical and
argues for legitimacy. But: 874 open issues, 575 open PRs, **10,225 npm versions
in 100 days** (10,009 `pr-*` prereleases), 4M downloads/month, and the proxy
**polls npm every 3 minutes and self-installs**, with an advisories channel that
can force a version change even when auto-update is off. Star timestamps could
not be verified. Treat velocity signals as machine-generated.

**Decision: scoped pilot only, never in the client bundle path.** See §2.6.1 for
the concrete implementation.

---

#### 2.6.1 How we would actually implement billion-context (the plan the earlier draft omitted)

**Verdict: implementable in exactly ONE place — a developer's own VS Code / Claude
Code coding session. Not deer-flow, not qm, not the bundle.**

Why the other two are excluded, with evidence:

| Surface | Why billion-context cannot serve it |
|---|---|
| **deer-flow** | It is a **container**. billion-context needs one conversation pinned to one process on one local volume; its README warns RWX/NFS "gives you silent corruption". Also deer-flow already has `tool_search` deferral **and** `deploy/client-bundle/patches/deer-flow-summarization-recovery.py` — a second compressor would fight both. |
| **qm** | `pi` harness. See §2.8: qm has **zero** MCP support and no compression hook. Nothing to attach to. |
| **client bundle** | Same one-process/one-volume constraint, plus it would ship an auto-updating proxy that polls npm every 3 minutes. Unacceptable in a client install. |

**Concrete wiring for the one valid target (local dev session):**

1. **Install pinned, not latest.**
   `npm i -g billion-context@0.1.216` (exact; the project published **10,225
   versions in 100 days**, 10,009 of them `pr-*` prereleases — `latest` is unsafe).
2. **Disable every phone-home channel** before first run:
   `ACP_AUTO_UPDATE=0`, advisories check off (the advisories channel can
   force-install or roll back a version even with auto-update disabled), and point
   `BILI_ANNOUNCEMENTS_URL` at nothing or an internal mirror.
3. **Do not use the MITM mode.** Use the plain base-URL rewrite
   (`http://localhost:8787/bili/<absolute-model-url>`). A "billion-context MITM Root
   CA" merged into the OS trust store is an endpoint-management change we do not
   need to accept for a pilot.
4. **Route summaries to a local model** so we do not burn cloud turns:
   `compress.externalSummary` with `autoFold: true` pointed at
   `http://host.docker.internal:11434/v1` (or `127.0.0.1:11434/v1` from the host).
5. **One volume per session.** `~/.local/share/billion-context/`; never a shared
   drive. Take a `bili storage backup` before pinning a version.
6. **Measure, per its own honest numbers** — not the marketing 5x. Expect
   **1.2-1.8x** at 200K-class windows (their paper volunteers this). Success =
   token reduction **with no increase in model calls per user message**. If
   calls-per-message rises, kill it: it adds up to 10 proxy-side re-request rounds
   (`MAX_LOOP_ROUNDS = 10`), which is the opposite of what our loop-heavy sessions
   need.
7. **Add the attribution line** to shipped docs (license term).

**What it will NOT do for us:** touch the 19↔877 tool-schema block. Its own config
docs raise the compaction target when the irreducible floor (system prompt + tool
definitions) exceeds it, and its FAQ tells you to prune tools yourself. P0 is
still the fix for that.

---

### 2.7 OpenMotion — three different repos, all rejected (and one is not what it claims)

Three projects share the name. All three were checked; none should be adopted.

| Repo | License | Stars | Reality |
|---|---|---|---|
| [Hada45/Open-Motion](https://github.com/Hada45/Open-Motion) | MIT | 35 | *"The open-source Alight Motion alternative"* — a **video motion-graphics app**. Wrong domain entirely; we need web-UI animation for agent sessions, not a video editor. 15 forks, last push 2026-11-08. |
| [Yuan-ManX/open-motion](https://github.com/Yuan-ManX/open-motion) | MIT | 189 | The real engineering: TypeScript monorepo, MCP server (`@modelcontextprotocol/sdk`, stdio + http), export to Lottie/HTML/video via `ffmpeg-static` + `puppeteer-core`, checkpoint/rollback, MIT. **But** see the tool-count problem below. |
| [fireX-bit/AimatorsAreGoats](https://github.com/fireX-bit/AimatorsAreGoats) | **none** | 0 | **Do not use.** The repo contains exactly **two files**: `ReadMe.txt` (148 bytes, a download link) and `index.html` (50 KB). **No source, no LICENSE**, `language: HTML`, all commits by one account within 4 hours on 2026-10-10, one release asset `OpenMotion.zip` (20 MB, 17 downloads). Its site claims "MIT licensed", "every release built from source in a public CI pipeline", and a bundled model — **none of which is true**. It also collides with the real [Hada45/Open-Motion] name. |

**Why Yuan-ManX is rejected despite being real engineering.** Measured:

```
open-motion/src/shared/tools.ts       294,295 bytes  (~74K tokens at 4 chars/tok)
distinct *Input zod schemas            492            (GetMotionSpec … BatchUpdate …)
```

It registers **all** of them onto the MCP server (`registerMcpTools` loops
`TOOL_NAMES`). Adding that server to deer-flow would inject ~74K tokens of tool
schema — roughly **4.5x** the entire 16.3K-token tool block pacgate currently runs
at, and about **double** the 36K that `tool_search` deferral exists to remove.
It would be the single largest static-context regression available to us.

It could only be used **outside** the agent's tool list (a side service we call
over HTTP), which defeats the purpose — the point was agent-driven animation.

**Decision: reject all three.** If we later want generated animation in a
session, the pattern to copy is "export to **Lottie JSON**" (an artifact a model
can author as data, ~no tool surface), not an MCP server with 492 endpoints.

---

### 2.8 qm + `pi`: the harness is model-wired, but has no MCP and no compression hook

**Question asked:** for qm, `pi` is customized to an Ollama endpoint — can we
re-evaluate?

**Answer: yes, and it changes nothing for these six repos. Re-verified on the
installed package, not from docs.**

What `pi` genuinely is, verified in
`deploy/qm-pacgate/node_modules/@yc-software/qm/dist/src/config.d.ts`:

```ts
export declare const MODEL_PROVIDERS: readonly ["anthropic", "openai", "openrouter"];
export declare const MODEL_PROVIDER_HARNESSES = {
  anthropic: ["pi", "opencode", "claude", "mock"],
  openai:    ["pi", "opencode", "codex", "mock"],
  openrouter:["pi", "mock"],
};
```

So `pi` is a **first-class harness on all three providers**, and `openai` (the
OpenAI-compatible path, which is how Ollama is reached) offers `pi`, `opencode`,
`codex`, `mock`. Our config uses exactly that:

```jsonc
"env": { "core": {
  "HARNESS": "pi", "SANDBOX_BACKEND": "local",
  "MODEL_BASE_URL": "http://host.docker.internal:11434/v1",
  "PI_MODEL": "glm-5.3-flash:cloud", ...
}}
```

**But the decisive finding is what `QmConfig` does *not* contain.** The complete
top-level schema is:

```
contract, orgId, publicUrl, apiUrl?, target, model?, modelProvider?, basePort?,
services, plugins, skills, env, secretEnv?, securityScreen?, vms?, imageOverrides,
sandbox?, appPrefix?, region?, flyOrg?, imageFrom?, deployAppPrefix?, aws?
```

There is **no `mcp` key**, and a case-insensitive search for `mcp` across the
entire installed `@yc-software/qm` package (`.js`, `.d.ts`, `.json`, `.md`)
returns **0 hits**.

Consequences, and they are the real answer to "which session can be wired into
qm":
- `pacgate-mcp`'s 26 tools **cannot** be wired into qm by config. It would need a
  harness-level change inside the core image (or `HARNESS: "opencode"`, which is
  MCP-capable but is a different harness with different behaviour and would need
  its own validation on the AIPC).
- billion-context **cannot** attach to qm's model traffic. `MODEL_BASE_URL` is
  passed to the harness inside the core container; redirecting it to a host-side
  proxy is possible in principle (`host.docker.internal:8787`), but you would then
  have one proxy process owning one conversation across a container boundary with
  no shared store — the exact shape its README calls silent corruption.
- Univer/AG-UI/OpenIntelligentUI have no qm surface at all: `skills` is a list of
  `SKILL.md` directories, not an extension or UI plugin point.

**Decision.** qm's `pi`+Ollama wiring is **already correct and is not the
bottleneck** — it is model-plumbing, not context management. Re-evaluating it does
not unlock any of the six repos.

#### 2.8.1 The `HARNESS: "opencode"` question — answered (2026-11-22)

**Verdict: conditionally yes, and the switch alone buys nothing.** Researched
against the live opencode schema and docs:

- opencode **does** support MCP, first-class, under `mcp.servers` (the V2 shape; the
  flat `mcp` form is schema-deprecated). Source of truth is
  `https://opencode.ai/config.json`.
- It reads config from `~/.config/opencode/opencode.json(c)`, the
  **`OPENCODE_CONFIG`** env var, `OPENCODE_CONFIG_CONTENT` (inline), and a
  project-local `opencode.json(c)` walked from cwd upward. `OPENCODE_CONFIG_DIR` is
  searched for `agents/`, `commands/`, `skills/`, `plugins/`.
- It supports OpenAI-compatible endpoints (`@ai-sdk/openai-compatible` with
  `baseURL`), so `http://host.docker.internal:11434/v1` is already the right shape.
- MCP maturity is production-grade (dedicated docs, OAuth/CIMD/DCR, per-server
  timeouts, connection pooling, protocol negotiation). **No tool-count cap found.**

Because `pacgate-mcp` is `streamable-http`, the entry would be the **remote** form,
and `oauth: false` is required — remote defaults to OAuth on, and FastMCP here is
unauthenticated:

```jsonc
{ "mcp": { "servers": { "pacgate": {
    "type": "remote", "url": "http://host.docker.internal:8090/mcp", "oauth": false } } } }
```

**All three of these must hold before it works:**
1. **qm must actually implement an `opencode` harness.** Unverified — no opencode
   adapter exists in `pacgate-adapters/typescript/`. `MODEL_PROVIDER_HARNESSES`
   implies it upstream, but this is the largest unknown and must be checked first.
2. **A config must be injected out-of-band**, since qm passes no MCP env: write
   `opencode.json` into the workspace, or set `OPENCODE_CONFIG` /
   `OPENCODE_CONFIG_CONTENT` on the core container.
3. **`pacgate-mcp` must be reachable from `qm-pacgate-core`** over
   `host.docker.internal`, the same pattern already proven for Ollama and
   pacgate-api.

Also decide Code Mode: opencode defaults it **on**, exposing tools grouped as
`tools.<server>.<tool>`; set `codemode: false` if the 29 pacgate tools should appear
as flat native tools.

---

## 3. Implementation plan

Ordering. **P1 and P1.6 are DONE** (repair hints; redline shipped and gated, both
verified against a built image). **P1.5 is CLOSED** — its premise was falsified,
OfficeCLI already calculates. **P2 and P3 are investigated and gated but not
adopted**: billion-context install surface verified and wired in §2.6.1 (pilot only,
never in the bundle); AG-UI proven encodable in §3 P3 (flag-gated trial only).
**P0-C** remains the honest first action: confirm whether the call count is the
actual complaint before touching anything, because P0's original code premise was
withdrawn on re-measurement.

### P0 — Close the tool-count instability (highest value)

**SUPERSEDED 2026-11-22 by §1.0.** The cache-tuning framing below is *withdrawn*: the
bottleneck is payload transfer, the cache is already at ~100%, and the measured
fitted model (`2698 + 20.86 ms/1k tok`, at 100% hit) says caching has no headroom
left. Read §1.0 for what to do instead. The original analysis is kept because its
*diagnosis* was still informative and its withdrawal should be legible.

**What was originally claimed:** pacgate sessions oscillate 19↔46 tools because
`tool_search` promotion perturbs the tool block, costing a 3.3x prefix-cache loss.

**What the session log actually shows.** `tool_search.activated` fires only **3
times** in `ac564b88` (and once in `a8453d57`). Promotion is therefore **not** the
driver of 291 flips — my earlier attribution was wrong. The real pattern is:

```
09:29:08   43 ->  46   init=agent      type=conversation-agent
10:07:31   46 ->  21   init=sub-agent  type=conversation-subagent
10:07:38   21 ->  46   init=agent
10:07:42   46 ->  21   init=sub-agent
...  279 more of the same
```

Every flip is the **parent↔sub-agent alternation**: the parent binds 46 tools, the
sub-agent binds 21, then back. That is by construction, and it re-keys the
provider cache on every handoff.

**And the scope is wrong.** These sessions are `interactionType:
conversation-agent` / `conversation-subagent` — that is the **VS Code Copilot agent
host**, not deer-flow. `cd5b70dc` was `cubecloud-agentic-os`; `ac564b88` is a VS
Code session. deer-flow's own deferral patch is *already* prefix-stable: the
catalog is sorted (`sorted(self.tools, key=lambda t: t.name)`), so the rendered
name block is byte-stable, and `scripts/test-tool-search-deferral.ps1` passes
**25/25**.

So there is **no deer-flow code change to make**. What is left is a decision about
where the work happens.

| Route | Change | Cost | Risk |
|---|---|---|---|
| **A — stop sub-agents for pacgate work** | None in code. In the VS Code client, disable tool-invoking subagents (the `task` tool) for pacgate sessions, or keep sub-agents but accept the cache re-key. | zero | loses parallel research |
| **B — reduce the static floor 46 → ~21** | Trim the extension-contributed tool surface for this workspace (the measured 46-tool parent set) so both parent and child sit near 21, halving the block that gets re-keyed. | small, local (`.vscode/settings.json`) | needs the tool composition enumerated first |
| **C — send less per call** | §1.0: latency is linear in payload bytes. Trim what is re-sent. | zero code | needs discipline, not a patch |
| **D — accept it** | Nothing. | zero | none |

**Recommendation: C, then D.** §1.0 shows the cache is already saturated and the
cost is bytes on the wire. A "sticky promoted set" would tune a cache that already
hits ~99.4%.

**Do not** implement a "sticky promoted set" in deer-flow. It was the premise of
the original P0 and the premise is false: promotion fires 3 times, not 291.

---

### P1 — Actionable failure results (`repair_hint`) — **DONE**

**Action taken.** The `repair_hint` idea from DataFlow-WebUI's
`PipelineValidationIssue` (`suggested_fields` + `repair_hint`,
`backend/app/schemas/pipelines.py:120-135`) was applied to the three places
pacgate-mcp fails, because a failure that only *describes* the fault leaves an agent
nothing to change and it re-issues the same call.

| Step | Action | Status |
|---|---|---|
| P1.1 | `_laya_truncation` emits a **computed** `repair_hint` | **DONE** — new `_truncation_repair_hint(read, dropped)` |
| P1.2 | `_laya_unavailable_result` names the env vars and says the retry is pointless | **DONE** |
| P1.3 | `_laya_withheld_result` names the substitute tool **and its arguments** | **DONE** |
| P1.4 | The Chinese-path refusal (`pacgate_clause_risk`) carries the same hint | **DONE** — it refused with a reason but no next step |
| P1.5 | Regression gate | **DONE** — `scripts/test-mcp-repair-hints.ps1`, 26 assertions, registered |

**The hint is computed, not decorative.** It reports `suggested_max_chars`,
`fraction_read` and `suggested_parts` from laya's own `state_tokens` /
`state_tokens_dropped`, and returns *no* numbers when laya did not report enough —
because a hint that guesses is worse than no hint, since a model will follow it.
Verified behaviourally: `read=400, dropped=100` → `max=400, fraction=0.8, parts=2`;
`dropped=0` and `read=None` both yield no invented values.

**A false-negative was found and fixed while mutation-testing.** The gate's first
version asserted `repair_hint` as a bare word, so renaming the JSON key to
`repair_tip` still passed — the function's own comment contains "`repair_hint`".
It now strips comments and requires `"repair_hint"\s*:`. Confirmed: the rename fails
24/26, exit 1.

**Acceptance met:** every failure shape carries a `repair_hint` with an `action`, a
concrete next step, and (where meaningful) a computed size. **No** auth, tenancy, or
Vue app was added.

---

### P1.5 — Univer `engine-formula` — **NOT NEEDED; premise falsified (2026-11-22)**

**This item is closed.** The premise was "OfficeCLI stores xlsx formulas but has no
calculation engine, so generated workbooks ship unevaluated". That is **false**, and
it was falsified by testing rather than reading the help text.

**What OfficeCLI 1.0.152 actually does, measured:**

| Behaviour | Result |
|---|---|
| Writes a formula and its value | **Caches the value at write time**: `<x:f>SUM(A1:A2)</x:f><x:v>30</x:v>` |
| Advanced functions | Computes `SORT` (array `t="array" ref="B1"`), `XLOOKUP`, **`LET`**, `IF`, `CONCATENATE`, `TEXT`, `SUMIF` — all with correct `<x:v>` |
| CJK inside formulas | `CONCATENATE("甲方","与","乙方")` → `甲方与乙方` ✔ |
| **After editing a precedent** | Recomputes internally — `query --json` returns `A3 = 120` for `A1=100, A2=20` — but **drops the persisted `<x:v>`** from the sheet XML |
| Persisting a computed value | `officecli raw-set <f> /Sheet1 --xpath "//x:c[@r='A3']" --action append --xml '<x:v>120</x:v>'` → **persists cleanly** |

So the real gap is narrow and already closable: OfficeCLI *computes* but does not
*persist* the cache after a dependent edit. One `raw-set append` fixes it, and that
is the same escape hatch P1.6 uses.

**A capability spike was still run, because "not needed" is only credible if the
alternative actually worked.** It does:

```
createUniver({ presets: [UniverSheetsNodeCorePreset()] })   # @univerjs/presets 1.0.4
→ A3 = SUM(A1:A2) = 30 ; B1 = A3*2 = 60
→ edit A1 → 120 / 240 ; edit A2 → 105 / 210
→ 6 consecutive runs, 1 distinct outcome (deterministic)
→ CONCATENATE("甲方","与","乙方") = 甲方与乙方 ; SORT spill = [3,5,8] ; TEXT = "30.00 元"
→ wb.save() gives cellData[2]["0"] = { f: "=SUM(A1:A2)", v: 30, t: 2 }
```

Two traps worth recording for anyone who revisits this:
- `api.getFormula().onCalculationResultApplied(...)` **throws**
  `Error: Calculation end timeout` headless, after a `TimeoutNaNWarning: NaN`. Its
  timeout argument is `undefined`, so `setTimeout(..., NaN)` fires at 1 ms. Do not
  wait on it.
- `await executeCalculation()` **resolves before results are applied**. Reading a
  cell immediately returns `null`. The deterministic recipe is: call
  `executeCalculation()`, then poll until the watched value set stops changing.
- The npm `@univerjs/preset-sheets-node-core` is stuck at **1.0.4** while the core
  packages are at **1.6.0**; mixing them breaks. Pin the whole tree to 1.0.4, or
  skip Univer as below.

**Decision: do not adopt `engine-formula`.** OfficeCLI already computes the same
class of formulas including CJK and `LET`, so Univer would add a 75-package Node
tree to duplicate a capability we have. The only thing it offers beyond OfficeCLI is
a persisted recalculated snapshot — and `raw-set append` delivers that in one
existing call.

---

### P1.6 — DOCX redline pipeline (`docx-scalpel`, MIT; contract proven)

**Problem.** Legal drafts need visible tracked changes a reviewer can accept or
reject. Previously recorded as blocked; that was wrong — it was blocked *in
Univer*, not in our toolchain.

**Proven on this machine (§2.1.5-2.1.6):** `docx-scalpel` 0.13.0 (MIT, manylinux
wheel, no .NET) yields real `w:ins`/`w:del` with correct CJK granularity, and
`accept(redline) == b`, `reject(redline) == a` exactly. `officecli validate`
passes on the output.

| Step | Action | Artifact |
|---|---|---|
| P1.6.1 | Add `docx-scalpel` to the pacgate-mcp image `requirements.txt` (pin `0.13.0`; verify the `manylinux_2_28_x86_64` wheel is the one resolved, not the sdist) | `deploy/pacgate-mcp/requirements.txt` — **DONE** |
| P1.6.2 | Wrap `docx_diff_compare` with **explicit** `author_for_revisions` + `date_time_for_revisions` + `deterministic=True` + `pre_accept_input_revisions=True` (defaults are `Docxodus` / `2000-01-01T00:00:00Z`) | `deploy/pacgate-mcp/redline.py` — **DONE** |
| P1.6.3 | Gate: `accept(redline).text == right.text`, `reject(redline).text == left.text`, asserted **inside** `compare()` so a bad redline is refused rather than returned | `redline.py` — **DONE** |
| P1.6.4 | Expose `pacgate_redline_compare` / `_accept` / `_reject` as MCP tools, inside the **deferred** set | `server.py` (26 → 29 tools) — **DONE** |
| P1.6.5 | Regression gate `scripts/test-docx-redline.ps1`: engine present in the **image**, real `w:ins`/`w:del`, round-trip both directions, author not `Docxodus`, CJK granularity by **span** (no revision covering ≥50% of the document) | **DONE**, 8/8 pass; registered in `run-all-checks.ps1` |
| P1.6.6 | Fallback: keep `officecli raw-set` available for injection without a diff, and as an independent validator | existing |

**Outstanding before this ships:** the `pacgate-mcp` image must be rebuilt and
republished (`ghcr.io/jzkk720/pacgate-mcp:0.2.35` is still the live tag). The build
is verified — a test image was built and both gates were run against a container
from it:

```
test-docx-redline.ps1      → 8 passed, 0 failed   (exit 0)
tools/list from new image  → 29 tools, incl. pacgate_redline_compare/_accept/_reject
```

Two container-only defects were found and fixed during that verification, neither
of which the Windows dev box could have shown:
1. **`redline.py` was not in the image.** Added `COPY redline.py .`.
2. **The bundled .NET host aborted for want of ICU** — `Couldn't find a valid ICU
   package installed on the system` — so every redline call raised
   `DocxodusTransportError`. Added an apt layer for `libicu-dev libssl3 libstdc++6
   ca-certificates`.

**Also fixed a false-negative in the new repair-hint gate (plan 035 P1).** Its first
version asserted `repair_hint` as a bare word, so renaming the JSON key to
`repair_tip` still passed — because the function's own comment says "`repair_hint`".
The assertion now strips comments and requires the key (`"repair_hint"\s*:`).
Mutation-verified: the rename now fails 24/26.

**Implementation notes from building it (all measured):**

- `docx_diff_get_revisions` takes **(left, right)** — the two *source* documents —
  not `(redline, right)`. Passing a redline returns an empty tuple, which reads as
  "no changes": measured 9 revisions for `(a, b)` vs **0** for `(redline, b)`.
- The gate originally asserted CJK granularity by counting revisions. That is
  **not sufficient**: the whole-sentence failure produces 1 revision, but a short
  clause legitimately yields only 3, so a `>= 3` threshold missed the real failure
  on other inputs. It now measures the **longest single revision as a fraction of
  the document** (must be < 50%). Mutation-tested both ways.
- `compare()` and `list_revisions()` originally built settings independently, which
  produced a change list stamped `Docxodus` beside a document stamped
  `PacGate Legal Review` — the same edit under two authors. Both now share one
  `_settings()` helper.
- `prove_redline_reversibility()` is **not** used as a gate. It is the strict
  package-bytes proof and returns `success=False` on a `path='relationship'`
  mismatch when the inputs come from different producers, while the text contract
  holds. Assert text, not package identity.

**Do not**: use `redlines` (no docx writer, destroys CJK), `python-docx` revision
helpers, `docx4j`, Aspose, or LibreOffice for this.

---

### P2 — billion-context: isolated single-developer pilot (NOT for clients)

Full wiring steps: **§2.6.1**. This section is only the gate list.

**Supply-chain verification done (2026-11-22):** installed `billion-context@0.1.216`
with `--ignore-scripts` and inspected the manifest — **no `preinstall`/`install`/
`postinstall`**, `bin: {bili, bili-proxy}`, `license: MIT`, deps only `zod@4.6.7` +
`mysql2@^3.15.3`, 46 files / 47.2 MB unpacked. 93 transitive packages. So the
install itself is not a script-execution risk; the risk is the runtime behaviour
(npm polling + advisories channel), which the env vars below disable.

Preconditions, all mandatory:

| # | Requirement |
|---|---|
| P2.1 | **Not** in `deploy/client-bundle/` and **not** in any compose file shipped to a client |
| P2.2 | Exact version pin (not `latest`), `ACP_AUTO_UPDATE=0`, advisories check disabled |
| P2.3 | `compress.externalSummary` + `autoFold: true` pointed at a **local** summarizer, so we do not burn expensive cloud turns on summaries |
| P2.4 | One volume per instance; sticky routing on a conversation header; never RWX/NFS |
| P2.5 | Attribution line added to shipped docs (license term) |
| P2.6 | Legal review of `src/anon-provenance.ts` (keeps UA ≤120 chars, header *names*, and a ≤160-char masked preview of the first user message) and `BILI_IDENTITY_HARVEST` (off by default) |
| P2.7 | Measure `[acp-usage]` cache-hit lines and ms/1k-token before/after on one pacgate workspace |

**Success criterion:** ≥1.2x token reduction on the *conversation* portion with
**no** increase in model calls per user message. If calls-per-message rises, stop
— that is the failure mode that matters to us.

**Kill criterion:** any increase in calls-per-user-message, or any interaction
that perturbs the deferred-tool block.

**Where it would be wired, if it works.** Nowhere in the bundle. It wraps a
*developer's own* coding agent locally. deer-flow and qm must not depend on it,
because (a) it has no shared store, (b) both are containers, and (c) both already
compress via `tool_search` + the summarization-recovery patch
(`deploy/client-bundle/patches/deer-flow-summarization-recovery.py`).

---

### P3 — AG-UI trial endpoint (verified feasible; still deferred to a flag)

**Feasibility proven 2026-11-22.** `ag-ui-protocol==1.0.0` on PyPI is MIT, needs only
`pydantic>=2.11.2`, and a pacgate-shaped run encodes to valid SSE in one file:

```
data: {"type":"RUN_STARTED","threadId":"t1","runId":"r1"}
data: {"type":"STATE_SNAPSHOT","snapshot":{"matter":"8f963544","stage":"review"}}
...
frames: 11   bytes: 856   CJK preserved: True   camelCase keys: True
```

Event vocabulary available in the SDK (49 classes): `RUN_STARTED/FINISHED`,
`TEXT_MESSAGE_START/CONTENT/END/CHUNK`, `TOOL_CALL_START/ARGS/END/RESULT`,
`STATE_SNAPSHOT/DELTA`, `MESSAGES_SNAPSHOT`, `ACTIVITY_*`, `REASONING_*`,
`STEP_STARTED/FINISHED`, `INTERRUPT` + `RunFinishedInterruptOutcome`, `CUSTOM`, `RAW`.

Two integration details that cost time:
- The Python models use **snake_case fields** (`thread_id`, `tool_call_id`,
  `message_id`) and alias to **camelCase on the wire**. Do not hand-build the JSON.
- `role` is a `Literal`, not an enum — pass `"assistant"`, not `Role.ASSISTANT`.

**Still deferred**, for the reasons in §2.4: HTTP-SSE has no `Last-Event-ID`
resumption, interrupts are terminal-run + resume, and the Vue/qml client is
hand-written. Phase 3 only, behind a flag, with the existing SSE path untouched.

| Step | Action |
|---|---|
| P3.1 | Add a **parallel** `/agui` route to one pacgate-mcp-adjacent agent; leave the existing SSE path untouched |
| P3.2 | Emit `RUN_STARTED → TEXT_MESSAGE_* / TOOL_CALL_* / STATE_* → RUN_FINISHED` with `protocolVersion="1.0"` |
| P3.3 | One Next.js page in `deploy/frontend-patches/` consuming it via `HttpAgent` |
| P3.4 | Measure; decide before touching qm's web-ui |

**Do not** migrate the Vue/qml surface. That is a hand-written client and the
weakest part of the AG-UI ecosystem.

---

## 4. Explicitly rejected, with reasons

| Item | Reason |
|---|---|
| Univer **as an editor** | Buys a React/Canvas editor we do not want, at the cost of a ~60-package lockstep pin (`README.md:228`) and an SSR-hostile mount (`ssr: false`). OSS reads/writes **no** Office file. |
| Univer Forms | Does not exist in any edition — `packages/forms` has zero commits ever, 0 sitemap entries, no npm package. |
| Univer Canvas / Boards | Proprietary `@univerjs-pro/boards`; never had an OSS commit; no headless preset even paid. Canvas **is** Boards (`README.md:626`). |
| Univer Slides (pptx) | OSS `@univerjs/slides` deleted 2026-11-04 (PR #8084); the npm `1.3.1` orphan cannot coexist with the 1.6.0 line. |
| Univer `@univerjs-pro/exchange-node` for DOCX I/O | Closed native binary, exports metered (10/mo free, 5,000/mo at $1,000/yr), vendor says *"Unsupported elements may be dropped"* — disqualifying for contracts. |
| Univer as redline engine | Track Changes **Not supported** across the full SDK, not just OSS. |
| omnara as orchestrator | No DAG / join / fan-in / shared state; second control plane over an existing one; no Python SDK. |
| DataFlow-WebUI embedded | Auth forbidden by project policy; `user_id` is a query param; errors return HTTP 200; RCE by design; no export-to-code. |
| OpenIntelligentUI as base | No published packages, 0 releases, 6 contributors, process-memory state, requires full CopilotKit + AG-UI adoption. |
| billion-context as an MCP server | Wrong shape; grows the tool block that `tool_search` exists to shrink. |
| billion-context in client bundle / deer-flow / qm | One-conversation-one-process, no shared store, self-admitting "silent corruption" on RWX; containers cannot own a conversation across processes. |
| **Yuan-ManX/open-motion** | 492 MCP tools, ~74K tokens of static schema — **4.5x** our whole current tool block. Would be the largest static-context regression available. |
| **Hada45/Open-Motion** | Video motion-graphics app (Alight Motion alternative). Wrong domain. |
| **fireX-bit/AimatorsAreGoats** | 2 files, no source, no LICENSE, 0 stars, false MIT/CI/model claims. **Do not use.** |
| PyPI `redlines` for docx | No docx writer at all; and it replaces whole CJK sentences. |
| `difflib` hand-rolled emitter | Superseded by `docx-scalpel`, which ships the engine **and** the accept/reject round-trip proof. Keep only as fallback. |
| Disabling editor extensions for pacgate | Verified earlier: 0 azure/cosmos/sql tool calls ever in pacgate; repo has no Java/.NET/Bicep/Cosmos. |

---

## 5. Risks

1. **P0's original premise was wrong and is withdrawn.** `tool_search` promotion
   fires 3 times, not 291; the flips are parent↔sub-agent alternation in the VS Code
   agent host, not deer-flow. Implementing a "sticky promoted set" in deer-flow
   would have been work on the wrong surface, fixing a non-cause.
2. **The measured cost is payload transfer, and no cache change touches it.**
   §1.0: 90.4% of model time is TTFT, the cache already hits ~99.4%, and a
   same-size payload with more tokens was *faster*. Treat "reduce what is re-sent"
   as the lever and "tune the cache" as closed. The 1,303-calls-for-16-messages
   figure from `ac564b88` is a *different* symptom (turn volume, not byte volume)
   and is still unexplained.
3. **billion-context is very young** (created 2026-08-06) with a self-installing
   proxy that polls npm every 3 minutes. Pin hard; assume the maintainers will
   ship breaking changes.
4. **AG-UI 1.1 is already in draft** and shims expire 2027-09-17. Any Phase 3
   work is knowingly on a moving spec.
5. **P1.6 depends on a 58 MB native wheel — and a .NET runtime dependency that is
   NOT in the wheel.** `docx-scalpel` ships `docx_scalpel/_bin/docxodus-pyhost`
   (~156 MB), which is a ** .NET single-file app**, not a native extension. It aborts
   at startup on `python:3.12-slim` with *"Couldn't find a valid ICU package
   installed on the system"*, and **every** redline call then raises
   `DocxodusTransportError: host exited unexpectedly`. It worked on the Windows dev
   box only because the OS provides ICU. The Dockerfile now installs
   `libicu-dev libssl3 libstdc++6 ca-certificates`. **Do not** drop that apt layer,
   and **not** on musl/Alpine either — the wheel is `manylinux_2_28_x86_64`, so glibc
   ≥ 2.28 is required. Measured and fixed 2026-11-22.
6. **The redline author/date are environment-controlled.** `PACGATE_REDLINE_AUTHOR`
   defaults to `PacGate Legal Review`; a deployment that overrides it to something
   anonymous produces an unattributed audit trail. `test-docx-redline.ps1` asserts
   the author is not the engine default `Docxodus`, but it cannot know whether the
   configured name is the *right* one.
7. **A fresh clone remains the only valid test** for anything touching the install
   path. This dev box hides failures behind pulled models and rendered gitignored
   configs.
8. **P1.6 `raw-set` fallback is version-sensitive.** It is an escape hatch, not a
   stable API. Pin the OfficeCLI version used in the image; a silent schema change
   would otherwise ship a corrupt docx.
9. **P1.5 depends on an unverified assumption** (that OfficeCLI has no calc). If
   OfficeCLI later adds evaluation, the mapper work is wasted. Hence the explicit
   abandon gate at P1.5.5.

---

## 6. How to ship the pacgate-mcp change (answer: bump, do not rebuild 0.2.35)

**Question:** rebuild `0.2.35`, or bump the bundle version?

**Answer: bump. Never publish onto an existing version tag.** The repo already has
the scar tissue for exactly this mistake.

`scripts/test-release-provenance.ps1` documents the 0.1.28 defect in the file
header: `v0.1.28` was tagged at `fffec57` and published; a later
`workflow_dispatch` — used "correctly" to publish a newer OCR bake without minting a
version — **overwrote the existing 0.1.28 packages** with revision `afe2965`, while
the tag stayed at `fffec57`. The published artifacts were fine; the **tag was
wrong**, and the recipe for the release no longer produced the release.

The mechanism that permits it is still present, which is why this is not rhetorical:
`Resolve image tag` in `.github/workflows/build-ghcr.yml` reads `inputs.tag` on a
dispatch and `github.ref_name` on a push, and `actions/checkout` sets no explicit
`ref:` — so **a dispatch checks out `main` while still publishing the old version
number.** Any dispatch after a tag moves the artifact without moving the tag.

So the sequence is:

| # | Step | Why |
|---|---|---|
| 1 | Add the redline + repair-hint changes (already done in the working tree) | — |
| 2 | Bump `pacgate-ai/Cargo.toml` `version = "0.2.35"` → the next version | it is the workspace version of record |
| 3 | Tag, push, let `build-ghcr.yml` fire on the **push** | a push resolves the tag; a dispatch resolves `main` |
| 4 | Run `scripts/preflight-release-tag.ps1`, then `scripts/test-release-provenance.ps1` | the only gate that notices a tag/artifact divergence |
| 5 | Re-pin the client bundle to the new tag | a client pulls by tag |

**Why not just rebuild 0.2.35 for speed:** it would work today and silently
recreate the 0.1.28 defect — the tag would still point at the old recipe while the
registry served new bytes, and nothing except `test-release-provenance.ps1` would
notice. The `preflight-release-tag.ps1` check `Bad "$tag already exists"` also
refuses to re-tag while the tag and packages coexist, so a rebuild does not even
give you a coherent release to point at.

**One exception worth naming:** if the intent is to publish a *fix* before a
version bump for a **single client site**, that is a site-local
`docker build` + `docker tag` + `docker save`, hand-delivered — not a registry
mutation. It leaves the registry's meaning intact. That is the only form of "rebuild
0.2.35" that does not create a provenance lie.

---

## 7. Open questions

1. What actually triggers the 19↔877 tool-set oscillation? (P0.2 answers this.)
2. Is the 790-1,068-tool spike (`120108e9`, `565bcf75`) reproducible now, or was
   it a stale-extension phase that has since cleared? `ac564b88` still peaked at
   **877**, so it has not cleared — but the trigger is unexplained.
3. **Does qm actually implement an `opencode` harness?** §2.8.1 established that
   opencode itself supports MCP + OpenAI-compatible endpoints, but found **no**
   opencode adapter in `pacgate-adapters/typescript/`. `MODEL_PROVIDER_HARNESSES`
   lists it; nothing in this repo proves qm ships it. Check upstream before
   planning on it.
4. Can `officecli raw-set --action replace` be anchored on a `<w:t>` node rather
   than a `<w:r>`? If yes, P1.6 avoids the trailing-text loss seen in the test.
5. Does `@univerjs/engine-formula` load headless **without** `@univerjs/sheets`
   (pure evaluator mode)? Would cut P1.5's footprint substantially.
6. If a browser editing surface is ever wanted, which of `docx4j` (Java diff API),
   Aspose.Words (`Document.Compare`), or LibreOffice UNO `XCompareDocument` wins
   on CJK fidelity? Note LibreOffice is **not installed** on this box, so no local
   evaluation was possible.
