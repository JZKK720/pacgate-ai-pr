"""Calibrate the context-pressure band from REAL conversation history.

WHY THIS EXISTS. The band (`_PACGATE_HINT_BAND = 0.85`) was an estimate. The fold
telemetry can calibrate it properly, but only once folds occur - and MEASURED
2026-11-08: on this box they never do. This script answers the question from the
data that DOES exist: the LangGraph checkpoint database, which holds every
recorded conversation state.

WHAT IT FOUND ON THIS BOX (2026-11-08, 15 busiest threads, deepest checkpoint per
thread):

    peak tokens: min=8,669  median=16,847  max=24,910
    threads at or over the 36,000 trigger: 0 of 15

That is the honest state, and it explains three things at once:

1. `scripts/fold_telemetry_report.py` reports CANNOT CHECK ("no fold recorded
   yet") - because summarization has never fired since the trigger moved to
   36,000. The sensor is idle, not broken.
2. The 0.85 band (= 30,600 tokens) is UNREACHABLE on observed traffic. The hint
   is silent because there is no pressure to report, which is the correct
   behaviour rather than a defect.
3. The recovery index is dormant on this workload. It stays as insurance for long
   document runs - the 65-page CJK PDF workflow that folded six times under the
   OLD 12,000 trigger. Raising the trigger to clear the 14,728-token floor is what
   bought that headroom.

THE CONCLUSION IS NOT "lower the band". A band is only meaningful relative to a
trigger that real traffic reaches. Lowering it to fire on a 17k thread would warn
about pressure that the 36,000 trigger does not consider pressure. The correct
output of this script is evidence plus a recommendation, not a silent retune.

Usage:
  python scripts/calibrate_context_band.py
  python scripts/calibrate_context_band.py --threads 30 --json
  python scripts/calibrate_context_band.py --min-checkpoints 20

Exit codes:
  0 = calibrated from real history
  2 = CANNOT CHECK (no checkpoint DB, or no decodable threads)
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys

CONTAINER = os.environ.get("PACGATE_DF_CONTAINER", "deer-flow")
CHECKPOINTS = "/data/deer-flow/checkpoints.db"
VENV_PY = "/app/backend/.venv/bin/python"

# Kept in sync with the patch. If these drift, the calibration is about the wrong
# numbers - so the script reads them from the patch where it can.
PATCH_REL = os.path.join("deploy", "client-bundle", "patches",
                         "deer-flow-summarization-recovery.py")

PROBE = r'''
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer
import sqlite3, statistics, json, sys
sys.path.insert(0, "/app/backend/packages/harness")
import deerflow.agents.middlewares.summarization_middleware as m

MIN_CP = {min_cp}
LIMIT = {limit}

class FakeModel:
    _llm_type = "ollama"; profile = None
    def with_config(self, **kw): return self
mw = m.DeerFlowSummarizationMiddleware(
    model=FakeModel(), trigger=("tokens", {trigger}), keep=("tokens", 6000))
band = getattr(m, "_PACGATE_HINT_BAND", None)
trigger = m._pacgate_resolve_trigger_tokens(mw)

s = JsonPlusSerializer()
c = sqlite3.connect("{db}")
threads = [r[0] for r in c.execute(
    "select thread_id from checkpoints group by thread_id "
    "having count(*) > ? order by count(*) desc limit ?", (MIN_CP, LIMIT))]

rows = []
for tid in threads:
    best = None
    for ctype, cp in c.execute(
            "select type, checkpoint from checkpoints where thread_id=? order by rowid", (tid,)):
        try:
            v = s.loads_typed((ctype, cp))
        except Exception:
            continue
        msgs = (v.get("channel_values") or {{}}).get("messages")
        if msgs and (best is None or len(msgs) > len(best)):
            best = msgs
    if not best:
        continue
    names, seen = [], set()
    for x in best:
        for tc in (getattr(x, "tool_calls", None) or []):
            nm = tc.get("name") if isinstance(tc, dict) else getattr(tc, "name", None)
            if not nm:
                continue
            names.append(nm)
            args = tc.get("args") if isinstance(tc, dict) else getattr(tc, "args", None)
            seen.add(nm + "|" + json.dumps(args, sort_keys=True, default=str))
    rows.append({{
        "thread": tid[:12],
        "msgs": len(best),
        "peak_tokens": mw.token_counter(best),
        "tool_calls": len(names),
        "distinct_payloads": len(seen),
        "retouch_ratio": round(len(names) / len(seen), 2) if seen else None,
    }})

print(json.dumps({{"trigger": trigger, "band": band, "rows": rows}}))
'''


def read_patch_constants() -> dict:
    """Read the band and default from the patch, so calibration tracks the code."""
    out = {"band": None, "excerpt_chars": None}
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), PATCH_REL)
    try:
        text = open(path, encoding="utf-8", newline="").read()
    except OSError:
        return out
    for line in text.splitlines():
        if line.startswith("_PACGATE_HINT_BAND"):
            try:
                out["band"] = float(line.split("=")[1].strip())
            except (IndexError, ValueError):
                pass
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--threads", type=int, default=15)
    ap.add_argument("--min-checkpoints", type=int, default=50)
    ap.add_argument("--trigger", type=int, default=36000)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    probe = subprocess.run(["docker", "exec", CONTAINER, "true"], capture_output=True)
    if probe.returncode != 0:
        print(f"CANNOT CHECK: container '{CONTAINER}' is not running.", file=sys.stderr)
        return 2

    script = PROBE.format(min_cp=args.min_checkpoints, limit=args.threads,
                          trigger=args.trigger, db=CHECKPOINTS)
    proc = subprocess.run(["docker", "exec", "-i", CONTAINER, VENV_PY, "-"],
                          input=script, text=True, capture_output=True)
    payload = ""
    for line in (proc.stdout or "").splitlines():
        if line.startswith("{"):
            payload = line
    if not payload:
        print("CANNOT CHECK: could not decode checkpoints.", file=sys.stderr)
        print((proc.stderr or "")[:800], file=sys.stderr)
        return 2

    data = json.loads(payload)
    rows = data["rows"]
    if not rows:
        print("CANNOT CHECK: no threads with messages and enough checkpoints.", file=sys.stderr)
        return 2

    trigger = data["trigger"] or args.trigger
    band = data["band"]
    patch = read_patch_constants()
    if band is not None and patch["band"] is not None and abs(band - patch["band"]) > 1e-9:
        print(f"WARNING: patch band {patch['band']} != live module band {band} - the "
              f"mounted file may be stale; re-run with the container recreated.", file=sys.stderr)

    toks = [r["peak_tokens"] for r in rows]
    ratios = [r["retouch_ratio"] for r in rows if r["retouch_ratio"] is not None]
    at_trigger = sum(1 for t in toks if t >= trigger)

    summary = {
        "threads": len(rows),
        "trigger": trigger,
        "band": band,
        "peak_tokens": {"min": min(toks), "median": int(statistics.median(toks)), "max": max(toks)},
        "peak_pct_of_trigger": {
            "median": round(statistics.median(toks) / trigger * 100, 1),
            "max": round(max(toks) / trigger * 100, 1),
        },
        "threads_at_or_over_trigger": at_trigger,
        "retouch_ratio": {"median": round(statistics.median(ratios), 2) if ratios else None,
                          "max": max(ratios) if ratios else None},
        "band_would_fire_on": sum(1 for t in toks if band and t >= trigger * band),
    }

    if args.json:
        print(json.dumps({"summary": summary, "rows": rows}, indent=2))
        return 0

    print("=== context band calibration from real history ===")
    print(f"  threads examined: {summary['threads']}   trigger: {trigger:,}")
    p = summary["peak_tokens"]
    print(f"  peak tokens:      min={p['min']:,}  median={p['median']:,}  max={p['max']:,}")
    pp = summary["peak_pct_of_trigger"]
    print(f"  peak vs trigger:  median={pp['median']}%  max={pp['max']}%")
    r = summary["retouch_ratio"]
    print(f"  retouch ratio:    median={r['median']}  max={r['max']}")
    print()
    print(f"  threads at/over the trigger: {at_trigger} of {summary['threads']}")
    print(f"  band {band} would fire on:    {summary['band_would_fire_on']} of {summary['threads']}")
    print()
    if at_trigger == 0:
        print("  READING: summarization has never fired on this workload since the")
        print("  trigger moved to 36,000. That is why fold telemetry is empty and why")
        print("  the hint is silent. Both are CORRECT: there is no pressure to report.")
        print()
        print("  Do NOT lower the band to manufacture a firing. A band is only")
        print("  meaningful against a trigger real traffic reaches; firing at 17k")
        print("  would warn about pressure the trigger does not consider pressure.")
        print("  Re-run this after a long document workflow to see the tail.")
    else:
        print("  READING: real traffic does reach the trigger, so the band is live and")
        print("  fold telemetry should accumulate. Compare band_would_fire_on against")
        print("  the folds actually recorded before moving the band.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
