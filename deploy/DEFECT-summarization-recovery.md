# DEFECT: summarization destroys the folded range, so long documents are re-read

**Found:** 2026-11-08, while evaluating whether an external context-compression
proxy could help this stack.
**Status:** FIXED in `deploy/client-bundle/patches/deer-flow-summarization-recovery.py`
(bind-mounted in both lanes). Gated by `scripts/test-summarization-recovery.ps1` (11 assertions).

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
