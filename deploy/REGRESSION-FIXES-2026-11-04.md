# Regression fixes — generation and retrieval

**Date:** 2026-11-04
**Scope:** the four defects measured on this stack that produced (a) empty documents
reported as success and (b) the "endless steps, no end-result" symptom.

Each fix below starts from a measurement, not a hypothesis. Two of my own earlier
hypotheses were **wrong and are recorded here as wrong**, because the next person
will reach for them too.

---

## 1. An empty completion was a success at every layer

### Measured

Local Ollama `/v1/chat/completions`, utility-shaped prompt, `max_tokens: 300`,
thinking left at the model default:

| Model | content | hidden reasoning | finish | HTTP |
|---|---|---|---|---|
| `gemma4:12b-it-qat` | **0 chars** | 805 chars | `length` | 200 |
| `nemotron-3.5-bolt:e4b-q8_0` | **0 chars** | 1060 chars | `length` | 200 |

With suppression (`reasoning_effort: none`) both return 11 tokens of clean content
in ~2.5 s instead of ~17-21 s of nothing.

### Why it reached the user

`pacgate-llm` had **no** emptiness check. `Choice.finish_reason` was declared at
`lib.rs:114` and **never read anywhere in the repo**. `complete()` returned
`Ok((None, vec![]))`, `pacgate-agent` returned `Ok(AgentTurnResult { content: None })`
on the natural-final-answer path, `workflow_executor` cloned it verbatim, and
`workflows.rs` returned **HTTP 200** with `final_content: ""`. No warning fired,
because the `max_rounds_reached` warn lives on the break-out path only.

### Fixed

- `pacgate-llm`: new `interpret_choice()`, called by `complete()`. A reply is valid
  only if it has non-blank content **or** at least one tool call. A `finish_reason`
  of `length` with no content returns an error that names the cause — a token budget
  spent on hidden reasoning — so the next debugger is not sent to the agent loop.
- `pacgate-agent`: defense-in-depth assert on the natural-return path. If the model
  produced nothing, prefer the last non-blank narration from a tool round; otherwise
  return a real error rather than an empty success.
- Tool calls with empty content remain **valid** — that is the normal multi-step
  path, and rejecting it would break every workflow.

Tests (fail-first, 4 new): `truncated_empty_completion_is_an_error_not_an_empty_success`,
`whitespace_only_completion_is_rejected`, `empty_stop_completion_is_rejected`,
`tool_call_with_empty_content_is_accepted`, `normal_completion_is_accepted`.

---

## 2. The keyword half of hybrid search matched zero Chinese chunks

### Measured

`002_rag_schema.sql` indexed with `to_tsvector('english', content)`. Postgres'
default parser does not segment Han text, so a whole sentence becomes one lexeme:

```
to_tsvector('english','结算条款约定甲方应在收到合规发票后...')
  -> '结算条款约定甲方应在收到合规发票后三十个工作日内支付':1
```

Against the live corpus:**918 of 957 chunks are Chinese**, and:

| query | old | new |
|---|---|---|
| `质保金` | **0** | **3** |
| `验收` | 0 | **88** |
| `验收标准` | 0 | **38** |

### Two hypotheses that were WRONG

1. **"`'simple'` will fix it."** No. Tested: `'simple'` splits identically — same
   single lexeme. The parser is the problem, not the stemmer.
2. **"`zhparser` is the answer."** Not available in the shipped image
   (`pg_available_extensions` shows only `pg_trgm`). A fix requiring it would fail
   on a clean client install.

### Fixed

`migrations/009_cjk_fulltext.sql`:

- Index splits Han text to **one token per character**:
  `to_tsvector('simple', regexp_replace(content,'([一-鿿])',' \1 ','g'))`
- `cjk_tsquery(text)` joins those characters with the **phrase operator** `<->`.

The phrase operator is the part that matters. `plainto_tsquery('simple','质保金')`
still returns **false** because it produces a bag of characters, not adjacency.
Verified on the live DB — and precision holds: `结算条款` correctly returns 0 because
it appears contiguously in **zero** chunks (9 chunks contain both words apart).

Cost: one token per character inflates the tsvector. Acceptable at this corpus size,
and it needs no extension, no new service, and **no re-embedding** — the vector half
is untouched, only the tsvector and its GIN index are rebuilt.

---

## 3. `embed_batch` was a serial loop, 28.8x slower than necessary

### Measured (live, `nomic-embed-text`, 32 chunks)

| approach | wall | per chunk |
|---|---|---|
| per-call loop (old code) | 68,316 ms | 2,135 ms |
| one batched request (new) | **2,375 ms** | **74 ms** |

**28.8x.** The ~2 s is fixed per-HTTP-request overhead, not compute — a 137M model
does not take two seconds to embed one clause. The old code carried the comment
"we do it one at a time for reliability", which bought nothing: batch input is the
documented behaviour and it is one request.

A short-read guard is included, because a response with fewer vectors than inputs
would silently pair chunks with the wrong embeddings — confident nonsense is worse
than a loud error.

---

## 4. Retrieval had no ceiling on what reached the model

### Measured

Live corpus chunk length: **min 1 / avg 564 / max 6,006 chars**. `top_k` alone is
not a cap, so an 8-hit search could inject ~48k chars into a prompt — on a 16 GB
card with a 65536-token total window.

### Fixed

`MAX_CONTEXT_CHARS = 12_000` applied in `merge_results`. Whole hits are kept in rank
order until the budget breaks, then truncated on a **char boundary** (CJK is 3 bytes
per char in UTF-8, so byte slicing would panic or corrupt). Truncation beats
dropping: the rank-1 chunk is the one the query matched, so its head is worth
keeping. `search()` applies the cap; `search_capped()` takes an explicit one.

---

## 5. A pre-existing test that failed on any proxied machine

Not a product defect, but it made the suite red for an environmental reason:

`pacgate-core::http::tests::a_default_client_would_take_the_proxy_and_fail` asserts
that a default `reqwest::Client` routes through a dead proxy. On a box exporting
`NO_PROXY=localhost,127.0.0.1,...` the loopback request bypasses the proxy and the
assertion fails. Proven by A/B: passes with `NO_PROXY` cleared, fails with it set.

Fixed by clearing `NO_PROXY`/`no_proxy` for the duration of the test and restoring
them, so the assertion tests the **client** (its purpose) rather than the operator's
shell.

---

## What was NOT changed

- **No model swap.** The 3x decode advantage of `e4b-q8_0` largely does not reach
  the user, because a tool loop is dominated by prefill and short outputs. With
  suppression both models finish the same 25-tool chain in ~23 s. Model size was
  never the bottleneck.
- **No vector-model swap.** Chinese semantic retrieval already discriminates well:
  relevant clause **0.7814** vs noise **0.5885**, a 0.19 margin.
- **No new service.** A third MCP server would grow the tool-schema surface, which
  is paid in prefill on every turn — the opposite of the goal.

## Verification

```
cargo test --workspace          -> 0 failures (all crates)
scripts/test-rust-workspace.ps1 -> PASS, exit 0
```

Migration 009 applied to the live DB and verified by query counts above.
