# DEFECT: summarization destroys the folded range, so long documents are re-read

**Found:** 2026-11-08, while evaluating whether an external context-compression
proxy could help this stack.
**Status:** FIXED in `deploy/client-bundle/patches/deer-flow-summarization-recovery.py`
(bind-mounted at the **runtime** module path in both lanes). Gated by
`scripts/test-summarization-recovery.ps1` (22 assertions).

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
| R13a-e | a fold writes one telemetry row carrying pressure + re-read signal; it never writes message content; it never raises even on garbage input |
| R14a/b | the hint honours a declared model window, so it fires on window pressure below the trigger |

## Known limits - and what changed since the first version of this doc

### Limit 1: "the hint is advisory; judge it by whether runs stop re-reading"

**This was not a soft limitation, it was an UNINSTRUMENTED one.** Measured
2026-11-08: neither per-call context size nor a re-read count was answerable from
any table. `runs.total_input_tokens` is **cumulative** (2,243,116 over 107 calls on
run `78f2a3c9`), `token_usage_by_model` is an aggregate, and `middleware_tokens`
is **0**. The test the doc recommended could not be run.

**Now instrumented.** The patch writes one JSONL row per summarization pass to
`/data/deer-flow/data/pacgate-fold-telemetry.jsonl` (a bind-mounted path, so it
survives a recreate and needs no migration):

```json
{"kind":"fold","folded_msgs":40,"preserved_msgs":6,"tokens_at_fold":36120,
 "trigger_tokens":36000,"window_tokens":null,"hint_band":0.85,
 "hint_would_fire":true,"tool_names":["read_file","bash"],
 "tool_calls":90,"distinct_payloads":4,"retouch_ratio":22.5}
```

`scripts/fold_telemetry_report.py` turns those rows into `tokens_at_fold`,
`retouch_ratio` (**tool_calls / distinct_payloads** - a re-touch loop is many
calls over few distinct payloads), and whether the hint band was ever reached.

**It never writes message content.** Counts, token numbers and tool *names* only.
A telemetry file under a bind mount that captured folded matter text would be
exactly the second unscoped store this patch refuses. Gated by `R13d`, red-checked
by making the row carry content.

### Limit 1b: the hint had a blind spot - the TRIGGER is not the WINDOW

Found while instrumenting. The hint keyed on `trigger` (36,000), but `trigger` is
a *summarization threshold*, not the model window. On a model whose window is
**smaller** than the trigger, the band would never fire before the window itself
overflowed - the diagnostic silent in exactly the case it exists for.

Measured: **nothing in `deer-flow-config.yaml` declares
`profile={"max_input_tokens": N}`**, so `window_tokens` is `null` on every fold
today. That is itself the finding: the hint can only key on the trigger until a
model profile is declared.

The hint now uses `min(trigger, window)` when a window is declared, and falls back
to the trigger when none is, so it becomes correct the moment a profile is added
with no further change. Gated by `R14a`/`R14b`; red-checked by reverting to
trigger-only, which fails `R14b`.

**Now calibrated, not estimated.** `scripts/calibrate_context_band.py` derives the
band from the LangGraph checkpoint database - every recorded conversation state -
rather than from the fold log, because the fold log is empty until a fold happens.

Measured 2026-11-08 on the 15 busiest threads (deepest checkpoint each):

| metric | value |
|---|---|
| peak tokens | min 8,669 / median **16,847** / max **24,910** |
| peak vs the 36,000 trigger | median **46.8%** / max **69.2%** |
| threads at or over the trigger | **0 of 15** |
| band 0.85 would fire on | **0 of 15** |
| retouch ratio | median **1.0** / max **1.24** |

Verified as genuine, not truncated state: the busiest thread is 60 messages
(3 human / 29 ai / 28 tool) with real 4.9k-char `bash` outputs and Chinese
analysis.

**Interpretation - three things explained at once:**

1. `fold_telemetry_report.py` reports CANNOT CHECK because summarization has
   **never fired** since the trigger moved to 36,000. The sensor is idle, not
   broken.
2. The hint is silent because there is **no pressure to report**. Correct
   behaviour, not a defect.
3. The recovery index is dormant on this workload - and the retouch ratio (median
   1.0) says the re-read loops it targets are not present either. It is insurance
   for long document runs, not a fix for current traffic.

**The band stays at 0.85 deliberately.** Lowering it to fire on a 17k thread would
warn about pressure the trigger does not consider pressure, and would let us claim
a behavioural win that is really just a lower alarm.

**Genuinely still open:** the band has not been calibrated against *fold* events,
because none exist on this traffic. `calibrate_context_band.py` should be re-run
after a long document workflow (the 65-page CJK PDF that folded six times under the
old 12,000 trigger) to calibrate from the tail rather than from the bulk.


### Limit 2: excerpts cover only the three live-web tools

Unchanged and deliberate. `read_file`, `ls`, `glob`, `grep`, `bash`,
`pacgate_list_*` and the document readers are re-derivable from disk, so a pointer
is sufficient recovery for them. The excerpt exists only for
`pacgate_web_scrape` (measured **4,208 tokens** per reply), `pacgate_web_search`
and `pacgate_connector_search`, where a page can change or 404 and live results
drift.

A file **deleted mid-run** still loses its content. That is accepted, not
overlooked: excerpting deleted files would reintroduce the store of matter content
this patch exists to avoid, and nothing measured so far shows it happening.

### Limit 3: the docx bug and the recursion floor - CLOSED, not gaps

These were listed as limits. They are not, and saying so is the point of this
section:

- **docx tracked-edit nesting** (`DEFECT-docx-tracked-edit-nesting.md`) is **FIXED
  in source, tested, proven against a live stack, shipped in 0.1.27.** It was a
  write-side XML bug - tracked edits spliced inside a `<w:t>` text node. Never a
  context problem, so nothing here was ever going to touch it.
- **The recursion floor** (`DEFECT-recursion-budget-floor.md`) is **fixed and
  gated** - `test-run-recursion-cap.ps1` reports 43 passed. The cost was
  structural (nine middleware hooks per model call), not token pressure.

Both are closed. Neither should be re-opened on the strength of "summarization
changed".




### Limit 4: "no real fold has occurred, so the write path is unproven"

Was true when first written; now resolved as far as this workload allows.

The write path was proven by exercising the **live mounted module** in-container -
building a real `DeerFlowSummarizationMiddleware` through the app's own class and
calling `pacgate_record_fold` - then reading the row back through
`fold_telemetry_report.py`. That verified the writer, the bind-mounted path, the
JSON shape and the reader end to end, without needing a genuine fold.

What it cannot prove is behaviour under a fold the runtime itself triggered,
because **no such fold has happened since the trigger moved to 36,000** (see the
calibration above). That is a workload property, not a defect here. The honest
statement is:

> The sensor is wired and demonstrably writes and reads. It remains
> **unexercised by production traffic**, and must be re-checked after the first
> long document workflow that actually folds.

`fold_telemetry_report.py` reports `CANNOT CHECK` in this state on purpose. It
never reports a pass, because a green result there would mean "the sensor works",
not "the feature works".
