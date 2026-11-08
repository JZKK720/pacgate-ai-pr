# DEFECT: summarization destroys the folded range, so long documents are re-read

**Found:** 2026-11-08, while evaluating whether an external context-compression
proxy could help this stack.
**Status:** FIXED in `deploy/client-bundle/patches/deer-flow-summarization-recovery.py`
(bind-mounted at the **runtime** module path in both lanes). Gated by
`scripts/test-summarization-recovery.ps1` (15 assertions).

## A correction to the first version of this fix

The first version edited
`langchain/agents/middleware/summarization.py::_build_new_messages`, mounted
cleanly, imported cleanly, and was **INERT**. deer-flow subclasses the middleware
and overrides that method in
`deerflow/agents/middlewares/summarization_middleware.py`:

```python
@override
def _build_new_messages(self, summary: str) -> list[HumanMessage]:
    return [HumanMessage(content=f"...", name="summary")]
```

Verified 2026-11-08 with
`inspect.getsource(DeerFlowSummarizationMiddleware._build_new_messages)` resolving
to **that** class. The runtime never called the patched base implementation.

That is the failure mode worth remembering: a patch that is mounted and imports
successfully **looks exactly like a working one** from the outside. The gate now
asserts the **runtime dispatch target** (`R1`), not "a file that imports", and
`R10` asserts both lanes mount at the runtime path. Both were red-checked by
retargeting the mount back at the base module: `R10` fails, as it should.

## The observation

Stock `SummarizationMiddleware.before_model` returns:

```python
return {
    "messages": [
        RemoveMessage(id=REMOVE_ALL_MESSAGES),
        *new_messages,        # exactly ONE HumanMessage
        *preserved_messages,
    ]
}
```

So the folded range is **not hidden** - it is **removed**. What survives is prose
the summarizer wrote, plus the preserved suffix. Everything the model did to the
folded messages is gone: which files it opened, which sections it had already
read, which URLs it had fetched.

That is the shape of the re-read loops this repo already documents. On thread
`b315a961`, three consecutive runs made **103 / 42 / 52 re-touches of the same
file**, 3.2-3.5M tokens each, all ending in `GraphRecursionError` with nothing
delivered. The 0.2.32 release fixed the *reachability* of document structure
(`pymupdf4llm` installed; `outline=51` where MarkItDown gave 0). This defect is
the next layer: once a range is folded, even a correct outline is no longer in
front of the model.

## Why the obvious fix was rejected

The obvious fix is a persistent archive of folded messages plus a
`recall_compressed` tool - which is what the external proxy
([billion-context](https://github.com/ranxianglei/billion-context)) actually is.

Rejected, and the reason is not cost. An archive of folded conversation is a
**second store of matter content, scoped to a session and not to a tenant**. This
repo is deliberate about exactly that boundary: OpenViking maps
`TenantId`→`X-OpenViking-Account` and `MatterId`→`X-OpenViking-Actor-Peer`, the
ethical wall is proven with `PEER_NOT_ALLOWED`, and session capture is kept on
`PacgateMemoryStore` → pacgate-api specifically so it stays inside that boundary.
Adding an unscoped archive is a data-residency decision, not a performance
trade-off, and it is not one this fix needs.

## What the fix does instead

**Recoverable handles, plus an excerpt for the content that is genuinely gone.**

The index distinguishes two classes of folded reply, because they need different
treatment:

| Reply source | Can it be re-derived? | What the index keeps |
|---|---|---|
| `read_file`, `ls`, `glob`, `grep`, `bash`, `pacgate_list_*` | yes, from disk | the path (pointer) |
| `pacgate_web_scrape` | **no** - page may change or 404 | a **bounded excerpt** |
| `pacgate_web_search` | **no** - live results drift | a **bounded excerpt** |
| `pacgate_connector_search` | **no** - federated, live | a **bounded excerpt** |

A web scrape reply measured **4,208 tokens** on this stack, so for those three a
pointer alone is *not* recovery. The excerpt is capped at 600 chars, whitespace
collapsed, max 4 per fold.

```
Folded range - recoverable handles (verbatim, not paraphrased):
  tools called: pacgate_web_scrape, read_file
  content that CANNOT be re-fetched (excerpt):
    - pacgate_web_scrape: # Judgment The court held that the contract was [...]
  paths/urls touched:
    - https://example.com/judgment
    - /data/outputs/handbook.pdf
  section headings seen:
    - Judgment
    - 1. Scope
  Re-read a path to recover its text rather than reconstructing it from the
  summary. Excerpts above are all that survives for live web/federated results.
```

Nothing persistent is stored, so there is no new residency surface and no new
tenant boundary to get wrong.

**Measured cost:** 1,318 chars of index against 76,600 chars folded = **1.7%
overhead** on a 60-message fold with 60 distinct paths. Bounded by
`_PACGATE_MAX_TOOL_NAMES` (20), `_PACGATE_MAX_PATHS` (24),
`_PACGATE_MAX_HEADINGS` (20), `_PACGATE_MAX_EXCERPTS` (4).

## Context pressure: a hint, not a tool

The `runs` table already stores `total_input_tokens`, `total_tokens`,
`lead_agent_tokens`, `middleware_tokens` and `token_usage_by_model`, so this was a
display gap, not a collection gap.

**A tool schema was rejected on measurement.** With the summarizer's own
`token_counter`:

| Shape | Tokens | Paid |
|---|---|---|
| one tool schema (always) | **159** | every call → **21,624/run** at 136 calls |
| band-gated one-line hint | **27** | only past the band; **0** below it |

The budget this feature exists to protect is `trigger − floor` = 36,000 − 14,728 =
**~21,300 tokens**. A schema would spend that entire budget reporting on it. The
hint costs 27 tokens and only on calls that already crossed the band.

It also fixes the actual failure: models do not spontaneously query their own
pressure. The failure is the model **not knowing**, not being unable to ask.

The hint is attached as an **else** branch of `before_model` - when a
summarization pass *did* run, the history was just relieved, so appending "fold
due soon" to the same turn would contradict what happened.

`pacgate_context_status(middleware, messages)` remains available for the
**operator** surface (API/UI), where it costs zero prompt tokens.

## Verification

| Assertion | What it proves |
|---|---|
| R1 | the patch ships the **runtime** class deer-flow dispatches to (the inert-patch bug) |
| R2 | the stock one-argument call still works - an upstream revert cannot make summarization raise `TypeError` |
| R3 | the two-argument path appends the index |
| R4 | a range with no handles appends **nothing** |
| R5 | 1.7% overhead against a realistic fold |
| R6 / R6b | the RUNTIME tuple shape `("tokens", 36000)` resolves |
| R7 | status numbers agree with the middleware's own `should_summarize` |
| R8 | an unrecognised trigger shape reports 0, never a confident "no pressure" |
| R9 | both `_maybe_summarize` and `_amaybe_summarize` pass the folded range |
| R10 | both compose lanes mount at the **runtime** path |
| R11a/b | non-reproducible output is excerpted; reproducible output is pointer-only |
| R12a/b | the hint is silent below the band and fires above it |

## Known limits, stated rather than implied

- The index recovers **where to look** for reproducible tools. If a file is deleted
  mid-run, that content is still lost - the excerpt only covers the three live web
  tools.
- It does not index code blocks or binary payloads.
- It does not make the summary itself better. A bad summary stays bad; the index
  only tells the model what it could re-read.
- The hint is advisory text. A model may ignore it - that is a prompt-quality
  question, not a mechanism one, and it is measured by whether long runs stop
  re-reading rather than by whether the hint appears.
- **The `-Update` restart covers this patch** via the existing `patches/*.py` ->
  `restart deer-flow` rule (`audit-aipc-update-coverage.ps1`: 14 of 14).


## The observation

Stock `SummarizationMiddleware.before_model` returns:

```python
return {
    "messages": [
        RemoveMessage(id=REMOVE_ALL_MESSAGES),
        *new_messages,        # exactly ONE HumanMessage
        *preserved_messages,
    ]
}
```

`langchain/agents/middleware/summarization.py`, this container's venv, line 320-330.
`_build_new_messages` (line 511) builds that single message:

```python
HumanMessage(content=f"Here is a summary of the conversation to date:\n\n{summary}")
```

So the folded range is **not hidden** - it is **removed**. What survives is prose the
summarizer wrote, plus the preserved suffix. Everything the model did to the folded
messages is gone: which files it opened, which sections it had already read, which
URLs it had fetched.

That is the shape of the re-read loops this repo already documents. On thread
`b315a961`, three consecutive runs made **103 / 42 / 52 re-touches of the same
file**, 3.2-3.5M tokens each, all ending in `GraphRecursionError` with nothing
delivered. The 0.2.32 release fixed the *reachability* of document structure
(`pymupdf4llm` installed; `outline=51` where MarkItDown gave 0). This defect is
the next layer: once a range is folded, even a correct outline is no longer in
front of the model.

## Why the obvious fix was rejected

The obvious fix is a persistent archive of folded messages plus a
`recall_compressed` tool - which is what the external proxy
([billion-context](https://github.com/ranxianglei/billion-context)) actually is.

Rejected, and the reason is not cost. An archive of folded conversation is a
**second store of matter content, scoped to a session and not to a tenant**. This
repo is deliberate about exactly that boundary: OpenViking maps
`TenantId`→`X-OpenViking-Account` and `MatterId`→`X-OpenViking-Actor-Peer`, the
ethical wall is proven with `PEER_NOT_ALLOWED`, and session capture is kept on
`PacgateMemoryStore` → pacgate-api specifically so it stays inside that boundary.
Adding an unscoped archive is a data-residency decision, not a performance
trade-off, and it is not one this fix needs.

## What the fix does instead

**Recoverable handles, not prose.** The patch appends a verbatim index to the
summary:

```
Folded range - recoverable handles (verbatim, not paraphrased):
  tools called: read_file, write_file, pacgate_web_search
  paths/urls touched:
    - /data/outputs/handbook.pdf
    - /data/office/matter-a/nda.docx
    - https://example.com/a/b.pdf
  section headings seen:
    - 1. Scope
    - 2. Liability
  These are handles, not content. Re-read a path to recover its text rather than
  reconstructing it from the summary.
```

The artifacts already exist on disk under `/data/outputs`, so a pointer **is**
sufficient recovery. Nothing new is stored, so there is no new residency surface
and no new tenant boundary to get wrong.

**Measured cost:** 1,318 chars of index against 76,600 chars folded = **1.7%
overhead**, on a 60-message fold with 60 distinct paths. Bounded by
`_PACGATE_MAX_TOOL_NAMES` (20), `_PACGATE_MAX_PATHS` (24), `_PACGATE_MAX_HEADINGS`
(20) so a pathological range cannot invert the saving.

## A second, cheaper gap closed in the same patch

Context pressure was **invisible**. The `runs` table already stores
`total_input_tokens`, `total_tokens`, `lead_agent_tokens`, `middleware_tokens` and
`token_usage_by_model`, so this was a display gap, not a collection gap.

`pacgate_context_status(middleware, messages)` reports `used_tokens`,
`trigger_tokens`, `used_pct_of_trigger`, `headroom_tokens`, `should_summarize`
and `messages` - computed from **the same `token_counter` and `trigger` the
summarizer uses**, so the number cannot drift from the decision.

It is a **function, not a `@tool`**, deliberately. Every registered tool adds its
schema to every request, and the unremovable per-call floor is already **14,728
tokens** (3,220 system prompt + 11,508 across 45 tool schemas) -
`DEFECT-summarization-treadmill.md` is the record of what happens when a
threshold sits below that floor. Adding tools to observe a threshold measured
against that floor would be self-defeating.

## A bug this found in its own first draft

The trigger resolver was written against `deer-flow-config.yaml`, which writes:

```yaml
trigger:
  - type: tokens
    value: 36000
```

But `SummarizationMiddleware.__init__` validates and **stores**
`ContextTokens = tuple[Literal["tokens"], int]`, i.e. `("tokens", 36000)`. A
dict-shaped resolver returns **0** against the live object - which reads as
"no pressure" on a run that is about to summarize. A silent zero in the one
number the feature exists to report.

Fixed, and `R6`/`R6b` now assert the runtime tuple and the list-of-tuples shapes.
`R8` asserts an unrecognised shape returns 0 so callers can distinguish "cannot
report" from "no pressure".

## Verification

| Assertion | What it proves |
|---|---|
| R1 | the patch is a full-file replacement (a diff cannot be bind-mounted over a module) |
| R2 | the stock single-argument `_build_new_messages("x")` still works - an upstream refactor cannot make summarization raise `TypeError` |
| R3 | the two-argument path appends the index |
| R4 | a range with no handles appends **nothing** (no prompt bloat) |
| R5 | 1.7% overhead against a realistic fold |
| R6 / R6b | the RUNTIME tuple shape resolves to 36000 |
| R7 | status numbers agree with the middleware's own `should_summarize` |
| R8 | an unrecognised trigger shape reports 0, never a confident "no pressure" |
| R9 | both `before_model` and `abefore_model` pass the folded range |
| R10 | both compose lanes mount the patch |

Live checks after `--force-recreate deer-flow`:
`test-agent-mcp-e2e.ps1` 9 passed / 0 failed (a real agent run through the patched
path); `test-summarization-treadmill.ps1` 6 of 6; `audit-deer-flow-patches.ps1`
OK; `test-baked-patch-parity.ps1` 16 passed / 0 failed.

## Known limits, stated rather than implied

- The index recovers **where to look**, not what the text said. A model that cannot
  re-read - e.g. because the file was deleted mid-run - still loses the content.
- It indexes tool names, paths/urls and markdown headings. It does not summarise
  code blocks, and it does not index binary payloads.
- It does **not** make the summary itself better. If the summarizer writes a bad
  summary, the index only tells the model what it could re-read.
- `pacgate_context_status` is available to the application layer; it is **not**
  registered as a model-visible tool, so the model cannot yet query its own
  pressure. That is the next piece of work, and it should come with a measurement
  of what one more tool schema costs against the 14,728-token floor - not an
  assumption that it is free.
