"""Read fold telemetry and compute the re-read ratio - the hint's outcome metric.

WHY THIS EXISTS. `deploy/DEFECT-summarization-recovery.md` lists as a known limit
that the context-pressure hint is advisory text and "a model may ignore it", and
says it should be judged by whether long runs stop re-reading. MEASURED
2026-11-08: that judgement had NO SENSOR. `runs.total_input_tokens` is
CUMULATIVE, `token_usage_by_model` is an aggregate, and `middleware_tokens` is 0 -
so neither per-call pressure nor a re-read count was answerable from any table.

The patch now writes one JSONL row per summarization pass
(`pacgate-fold-telemetry.jsonl` under the existing /data mount). This reader turns
those rows into the numbers the claim needs:

  tokens_at_fold      the real pressure that caused each pass
  window_tokens       the model window IF one is declared (None today - which is
                      why the hint can only key on the trigger)
  retouch_ratio       tool_calls / distinct_payloads within the folded range.
                      A re-touch loop is many calls over FEW distinct payloads,
                      so a high ratio with a high call count is the loop signature.

BASELINE TO COMPARE AGAINST, from this repo's own records (not invented):
  - the killed run on bcb69ff8: 111 model calls across 15 distinct tool-call
    payloads (ratio 7.4) - and it was NOT thrashing; the super-step cost was
    structural (nine middleware hooks per model call)
  - thread b315a961: three runs of 87-104 bash calls re-reading ONE file

So the ratio is read PER RUN against that run's own work, never against a fixed
threshold. A ratio alone is not a verdict; this tool reports it and says so.

Usage:
  python scripts/fold_telemetry_report.py                 # summary
  python scripts/fold_telemetry_report.py --json          # machine readable
  python scripts/fold_telemetry_report.py --tail 20       # last N rows
  python scripts/fold_telemetry_report.py --path <file>   # explicit file

Exit codes, matching the rest of this repo:
  0 = telemetry read successfully (even if it is still empty)
  2 = CANNOT CHECK (no telemetry file yet, or no container access)
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys

DEFAULT_IN_CONTAINER = "/data/deer-flow/data/pacgate-fold-telemetry.jsonl"
CONTAINER = os.environ.get("PACGATE_DF_CONTAINER", "deer-flow")


def read_rows(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    rows: list[dict] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # a torn final line must not break the report
    return rows


def fetch_from_container(path: str) -> str | None:
    """Copy the telemetry out of the container, or None if unavailable."""
    probe = subprocess.run(["docker", "exec", CONTAINER, "true"], capture_output=True)
    if probe.returncode != 0:
        return None
    dest = os.path.join(os.environ.get("TEMP", "/tmp"), "pacgate-fold-telemetry.jsonl")
    cp = subprocess.run(["docker", "cp", f"{CONTAINER}:{path}", dest], capture_output=True, text=True)
    if cp.returncode != 0:
        return None
    return dest


def summarise(rows: list[dict]) -> dict:
    if not rows:
        return {"rows": 0}
    folds = [r for r in rows if r.get("kind") == "fold"]
    tokens = [r["tokens_at_fold"] for r in folds if isinstance(r.get("tokens_at_fold"), int)]
    ratios = [r["retouch_ratio"] for r in folds if isinstance(r.get("retouch_ratio"), (int, float))]
    calls = [r["tool_calls"] for r in folds if isinstance(r.get("tool_calls"), int)]
    distinct = [r["distinct_payloads"] for r in folds if isinstance(r.get("distinct_payloads"), int)]
    return {
        "rows": len(rows),
        "folds": len(folds),
        "tokens_at_fold": {
            "min": min(tokens) if tokens else None,
            "median": int(statistics.median(tokens)) if tokens else None,
            "max": max(tokens) if tokens else None,
        },
        "retouch_ratio": {
            "median": round(statistics.median(ratios), 2) if ratios else None,
            "max": max(ratios) if ratios else None,
        },
        "tool_calls_total": sum(calls) if calls else 0,
        "distinct_payloads_total": sum(distinct) if distinct else 0,
        "hint_would_fire_on": sum(1 for r in folds if r.get("hint_would_fire")),
        "window_declared_on": sum(1 for r in folds if r.get("window_tokens")),
        "triggers_seen": sorted({r.get("trigger_tokens") for r in folds
                                 if isinstance(r.get("trigger_tokens"), int)}),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--path", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--tail", type=int, default=0)
    args = ap.parse_args()

    path = args.path
    if not path:
        path = fetch_from_container(DEFAULT_IN_CONTAINER)
        if path is None:
            print("CANNOT CHECK: no fold telemetry yet.", file=sys.stderr)
            print(f"  looked for {DEFAULT_IN_CONTAINER} in container '{CONTAINER}'", file=sys.stderr)
            print("  the file appears after the first summarization pass on the patched stack.",
                  file=sys.stderr)
            return 2

    rows = read_rows(path)
    if not rows:
        print("CANNOT CHECK: the telemetry file exists but holds no rows yet.", file=sys.stderr)
        print("  it fills on the first summarization pass, not on install.", file=sys.stderr)
        return 2

    summary = summarise(rows)
    if args.json:
        print(json.dumps({"summary": summary, "rows": rows[-args.tail:] if args.tail else rows},
                         indent=2, ensure_ascii=False))
        return 0

    print("=== fold telemetry ===")
    print(f"  rows: {summary['rows']}   folds: {summary['folds']}")
    t = summary["tokens_at_fold"]
    print(f"  tokens at fold: min={t['min']}  median={t['median']}  max={t['max']}")
    r = summary["retouch_ratio"]
    print(f"  retouch ratio (calls / distinct payloads): median={r['median']}  max={r['max']}")
    print(f"  tool calls fold-total: {summary['tool_calls_total']}  "
          f"distinct payloads: {summary['distinct_payloads_total']}")
    print(f"  triggers seen: {summary['triggers_seen']}")
    print(f"  folds where the hint band was reached: {summary['hint_would_fire_on']}")
    print(f"  folds with a DECLARED model window: {summary['window_declared_on']}"
          + ("  <- none: the hint can only key on the trigger"
             if summary["window_declared_on"] == 0 else ""))
    print()
    print("  A ratio is not a verdict. Baseline from this repo: the killed run on")
    print("  bcb69ff8 made 111 calls over 15 distinct payloads (7.4) and was NOT")
    print("  thrashing - its super-step cost was structural. Compare a run against")
    print("  its own work, and against the b315a961 shape (87-104 calls, 1 file).")

    if args.tail:
        print(f"\n  last {args.tail} row(s):")
        for row in rows[-args.tail:]:
            print("   ", json.dumps(row, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
