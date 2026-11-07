# DEFECT (HIGH): recursion ceiling alone did not stop the 1000 wall

**Found:** 2026-11-07, from a live user report: a research-then-write run on thread
`bcb69ff8` stopped early with

```
Recursion limit of 1000 reached without hitting a stop condition.
You can increase the limit by setting the `recursion_limit` config key.
```

**Status:** FIXED in `deploy/client-bundle/patches/deer-flow-run-recursion-cap.py`
(server floor) and `deploy/frontend-patches/files/src/core/threads/hooks.ts` (stop
pinning a client budget). Gated by `scripts/test-run-recursion-cap.ps1`.

## The prior fix was real but half a fix

`DEFECT-*` history and `compose.prod.yaml` both describe the 2026-10-28 change: the
gateway used to do

```python
config[k] = v          # the UI's 1000 overwrote the server's own 100
```

and the fix was a **ceiling** - clamp any caller request down to
`_PACGATE_MAX_RECURSION_LIMIT` (4000). That stopped a caller from asking for an
unbounded budget. It never raised a caller back **up**, so a caller asking for *too
little* was still obeyed, and the chat UI asks for 1000 on every single run.

The ceiling was therefore never binding in practice. Every UI run ran at exactly
1000 while a 4000 ceiling sat unused.

## What the data shows

`runs` in `/data/deer-flow/data/deerflow.db` joined to langgraph's own per-run `step`
counter in `/data/deer-flow/checkpoints.db`, over 333 recorded runs:

| signal | measurement |
|---|---|
| runs that died with `GraphRecursionError` | **22** |
| of those, ones carrying a client budget | **all died at exactly 1000** |
| their LLM call counts | 114-136 |
| the rest | died at the old `100` default, 14-15 calls |
| checkpoint walks consuming **exactly 1001** super-steps | **4** |
| deepest **SUCCESSFUL** run whose checkpoints were retained | **937 super-steps / 109 LLM calls (ratio 8.60)** |
| headroom that run had left before the wall | **63 super-steps (~6%)** |
| deepest success on record | **138 LLM calls** (its checkpoints were pruned) |
| that 138 extrapolated at the 8.24-8.88 ratio every other deep success shows | **~1150-1200 super-steps (extrapolation, not a measurement)** |

The four "1001" runs are the wall itself, not a coincidence: a run's last checkpoint
step index is `limit + 1` when it is killed. Segmented per run on `bcb69ff8`:

```
run 00  start=-1    last=-1     consumed=0
run 01  start=0     last=524    consumed=524
run 02  start=525   last=751    consumed=226
run 03  start=752   last=781    consumed=29
run 04  start=782   last=1783   consumed=1001   <-- the wall
```

## 1000 is below this graph's working depth

This is the part the earlier note got backwards. That note argued "1000 is a
proven-safe budget (runs have succeeded inside it)". Runs succeeded inside it only
because the runs that would have needed more were **killed at 1000** - and the
deepest success that survives in the checkpoint DB used **937 of its 1000**, i.e. 63
super-steps of headroom. A budget a successful run comes within 6% of is not a
budget, it is the next ceiling.

The very deepest success on record (138 LLM calls) went past it. That one is an
extrapolation rather than a measurement because its checkpoints were pruned, but it
is a well-grounded one: every deep success retained in the DB shows 8.24-8.88
super-steps per call (109 calls -> 937, 82 -> 676, 75 -> 638, 68 -> 604, 60 -> 514),
and 138 calls at that ratio lands at ~1150-1200.

## The killed run was not thrashing

The usual defence of a low budget is "it was looping". It was not:

| metric on `bcb69ff8`'s killed run | value |
|---|---|
| model calls | 111 |
| distinct tool-call argument payloads | 15 |
| distinct tool names | 8 (`read_file`, `write_file`, `bash`, `pacgate_web_search`, `pacgate_web_scrape`, `pacgate_connector_search`, `pacgate_list_matters`) |
| super-steps per model call | 9.0 (in line with healthy runs) |
| artifact left on disk | a real Chinese legal memo, written in 3 `write_file` parts |

The step cost is structural, not pathological: nine middleware
`before_model`/`after_model` hooks are each their own graph node, so each model call
costs ~9-10 super-steps before any tool work. That is why the ratio is stable across
success and failure, and why the budget cannot be tuned by guessing at "reasonable"
step counts.

## Why the summarization treadmill was not the cause

`DEFECT-summarization-treadmill.md` describes a real, separately-fixed defect
(`trigger` below the unremovable token floor, so summarization fired forever). It was
checked against this run and ruled out: the live config already carries the fixed
values (`trigger 36000`, `keep 6000`, `trim_tokens_to_summarize 36000`), and the
final run's 13 `RemoveMessage` events over 111 model calls is normal turnover, not a
treadmill. The 275 vs 194 route imbalance seen on the thread across all its runs is
explained by the run above being killed mid-flight, not by repeated summarization.

## The fix

Two changes, because either alone is insufficient.

**1. A server-side FLOOR** in `build_run_config()`:

```python
_PACGATE_MIN_RECURSION_LIMIT = int(os.environ.get("DEERFLOW_MIN_RECURSION_LIMIT", "2000") or 2000)
...
floor = min(_PACGATE_MIN_RECURSION_LIMIT, _PACGATE_MAX_RECURSION_LIMIT)
if requested < floor:
    requested = floor
```

Why 2000:

- it is above the measured 1000 wall, so it cannot reintroduce this defect;
- it is ~2.1x the deepest **directly measured** successful run (937 super-steps) and
  ~1.7x the extrapolated depth of the deepest success on record (~1150-1200);
- it leaves a 2x gap to the 4000 ceiling, so the ceiling still binds and
  `DEERFLOW_MAX_RECURSION_LIMIT` keeps its meaning;
- the floor is clamped under the ceiling at use time, so a deliberately low
  ceiling is **not** silently overridden upward by the floor.

**2. The frontend stops pinning a budget** (`hooks.ts`). The `recursion_limit: 1000`
key is removed from the run config entirely, so the server's own per-deployment
budget applies. The floor is the backstop for any other client shipping a stale
constant.

The ceiling is unchanged at 4000. A caller may still ask for **more** than the floor,
up to the ceiling - a genuinely deeper workload is still possible.

## Verified

Live in the running container, through the real `RunCreateRequest` model the router
uses:

| request | effective `recursion_limit` |
|---|---|
| UI sending `1000` (old frontend) | **2000** (raised to floor) |
| no config at all (new frontend) | **4000** (server default = ceiling) |
| `3000` | 3000 (honoured - above floor, below ceiling) |
| `50`, `900`, `-5` | 2000 (raised to floor) |
| `1000000` | 4000 (clamped to ceiling) |
| `"nonsense"` | 4000 (ignored, default kept) |
| ceiling forced to `800`, floor `5000` | 800 (floor yields to the explicit ceiling) |

`scripts/test-run-recursion-cap.ps1`: **43 passed, 0 failed**.

## Gates that were pinning the defect

Two assertions encoded the wrong conclusion and would have blocked this fix. Both
were rewritten, with the measurement recorded inline so the reasoning cannot silently
regress:

- `test-run-recursion-cap.ps1` asserted `the UI's 1000 sits under the ceiling and
  passes through` and `a caller asking for LESS is still honoured`. The first was
  the defect stated as a requirement; the second is what made 1000 authoritative.
  They now assert the raise-to-floor behaviour and that a request *just above* the
  floor is still honoured verbatim.
- `audit-recursion-regressions.ps1` treated `at_default = lim is None or lim <= 100`
  as benign, which meant a kill at 1000 counted as "the cap working". Now only
  `lim is None` is benign: a kill at a **client-supplied** budget proves the floor
  did not apply, which is a sharper signal than the old comparison.

The audit baseline moved from `2026-10-28 04:00:00` to `2026-11-07 07:00:00`. It had
been stuck at a date before the ten kills it was supposed to catch, so it reported a
standing REGRESSION that no amount of prompt work could clear. The ten historical
kills are what this change fixes; the baseline now starts at the floor going live.

## Residual risk

- The floor is **measured, not enforced**. A future graph with more middleware nodes
  per call raises super-steps-per-call and would push the legitimate depth past 2000.
  `test-run-recursion-cap.ps1` pins `floor > 1000` and `floor < ceiling`; it does not
  re-measure the graph. If a 2000-wall kill appears, raise
  `DEERFLOW_MIN_RECURSION_LIMIT` rather than lowering the ceiling.
- `app/channels/manager.py:51` and `deerflow/client.py:218` still hardcode
  `recursion_limit: 100` independently of `build_run_config`. The IM channel routes
  through the gateway and is therefore floored; a caller of `deerflow.client`
  directly is not. Unchanged by this fix, and recorded in both the patch header and
  the adoption plan so it is not mistaken for coverage.
- The frontend change is inert until the next frontend image build. Until then the
  **server floor** is what protects users, which is why it was implemented rather
  than relying on the frontend alone.
