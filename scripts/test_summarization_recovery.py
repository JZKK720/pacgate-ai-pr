"""Gate: the summarization recovery patch keeps a folded range recoverable.

WHAT THIS ASSERTS, and why each one is a real failure mode rather than a style
preference. Every case below was either measured on this stack or is a shape the
patch has to survive:

  R1  the patch is a FULL-FILE mount replacement, not a diff
  R2  the stock single-argument signature still works (upgrade safety)
  R3  the two-argument path appends a verbatim index
  R4  a range with no handles appends NOTHING (no prompt bloat)
  R5  the index costs far less than the range it describes
  R6  the trigger resolver handles the RUNTIME tuple shape, not the YAML shape
  R7  context status reports against the live middleware's own counter
  R8  an unrecognised trigger shape reports 0 ("cannot report"), never a
      confident "no pressure"
  R9  both before_model call sites pass the folded range
  R10 the patch is mounted by both compose lanes

R6 EXISTS BECAUSE THIS WAS A REAL BUG IN THE FIRST DRAFT. The resolver was
written against `deer-flow-config.yaml`, which writes a LIST OF DICTS
({type: tokens, value: 36000}). The live object holds
`ContextTokens = tuple[Literal["tokens"], int]`, i.e. `("tokens", 36000)`. A
dict-shaped resolver returns 0 against the live object and reports "no pressure"
on a run that is about to summarize - a silent zero, the worst kind.

Exit codes, matching the rest of this repo:
  0 = every assertion passed
  1 = a real failure
  2 = CANNOT CHECK (no container, or the patched module is not reachable)

Run:
  pwsh -NoProfile -File scripts/test-summarization-recovery.ps1
or directly:
  python scripts/test_summarization_recovery.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

PATCH_REL = os.path.join("deploy", "client-bundle", "patches",
                         "deer-flow-summarization-recovery.py")
CONTAINER = os.environ.get("PACGATE_DF_CONTAINER", "deer-flow")
VENV_PY = "/app/backend/.venv/bin/python"

_passed = 0
_failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"  [PASS] {name}")
    else:
        _failed += 1
        print(f"  [FAIL] {name}")
        if detail:
            for line in str(detail).splitlines()[:12]:
                print(f"         {line}")


def cannot_check(why: str) -> None:
    print(f"CANNOT CHECK: {why}")
    print(f"RESULT: {_passed} passed, {_failed} failed (CANNOT CHECK)")
    sys.exit(2)


def run_in_container(script: str) -> tuple[int, str]:
    proc = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, VENV_PY, "-"],
        input=script, text=True, capture_output=True,
    )
    out = (proc.stdout or "") + (proc.returncode and (proc.stderr or "") or "")
    return proc.returncode, out


def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    patch_path = os.path.join(repo_root, PATCH_REL)

    print("=== summarization recovery patch ===")

    # ── R1: full-file replacement ────────────────────────────────────────────
    if not os.path.exists(patch_path):
        cannot_check(f"patch not found at {PATCH_REL}")
    text = open(patch_path, encoding="utf-8", newline="").read()
    is_full_file = "class SummarizationMiddleware" in text and "import uuid" in text
    check("R1 the patch is a full-file replacement of the stock module", is_full_file,
          "a diff cannot be bind-mounted over a module; see deer-flow-file-conversion.py")

    # ── R9: both call sites pass the folded range ────────────────────────────
    sync_n = text.count("new_messages = self._build_new_messages(summary, messages_to_summarize)")
    bare_n = text.count("new_messages = self._build_new_messages(summary)")
    check("R9 both before_model and abefore_model pass the folded range",
          sync_n == 2 and bare_n == 0,
          f"patched call sites={sync_n} (expected 2), stock-form sites={bare_n} (expected 0)")

    # ── R10: mounted by both lanes ───────────────────────────────────────────
    lanes = {}
    for lane in ("compose.prod.yaml", "compose.bundle.yaml"):
        lane_path = os.path.join(repo_root, "deploy", "client-bundle", lane)
        try:
            lane_text = open(lane_path, encoding="utf-8", newline="").read()
        except OSError:
            lane_text = ""
        lanes[lane] = "deer-flow-summarization-recovery.py" in lane_text
    check("R10 both compose lanes mount the patch", all(lanes.values()), json.dumps(lanes))

    # ── everything else runs inside the real venv ────────────────────────────
    probe = subprocess.run(["docker", "exec", CONTAINER, "true"], capture_output=True)
    if probe.returncode != 0:
        cannot_check(f"container {CONTAINER} is not running")

    cp = subprocess.run(["docker", "cp", patch_path, f"{CONTAINER}:/tmp/_recovery_probe.py"],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        cannot_check(f"could not stage the patch into {CONTAINER}: {cp.stderr.strip()}")

    script = r'''
import importlib.util, json
from unittest.mock import MagicMock
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage

spec = importlib.util.spec_from_file_location("sump", "/tmp/_recovery_probe.py")
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except Exception as exc:
    print(json.dumps({"import_error": f"{type(exc).__name__}: {exc}"}))
    raise SystemExit(0)

out = {}

# ── R2/R3/R4: builder signatures ────────────────────────────────────────────
out["one_arg"] = m.SummarizationMiddleware._build_new_messages("SUM")[0].content

folded = [
    AIMessage(content="", tool_calls=[{"name": "read_file",
               "args": {"path": "/data/outputs/handbook.pdf"}, "id": "c1"}]),
    ToolMessage(content="# 1. Scope\nsee /data/office/matter-a/nda.docx",
                tool_call_id="c1", name="read_file"),
    AIMessage(content="## 2. Liability\nbody"),
]
out["two_arg"] = m.SummarizationMiddleware._build_new_messages("SUM", folded)[0].content
out["no_handles"] = m._pacgate_folded_index([HumanMessage(content="plain prose")])

# R5 must be measured against a REALISTIC range. A 65-char fixture makes the
# index's fixed explanatory text dominate the ratio and says nothing about a
# real fold, which is kilobytes. Build a range the size a 36k-trigger pass
# actually folds, then compare.
big = []
for i in range(60):
    big.append(ToolMessage(
        content=("# Section %d\n" % i) + ("body text about the agreement. " * 40)
                + "/data/outputs/doc-%d.pdf" % i,
        tool_call_id="c%d" % i, name="read_file"))
out["big_folded_len"] = sum(len(str(getattr(x, "content", ""))) for x in big)
out["big_index"] = m._pacgate_folded_index(big)
out["big_index_len"] = len(out["big_index"])

# ── R6: RUNTIME tuple shape, plus the YAML shapes ───────────────────────────
class Odd: trigger = "weird"
mw = m.SummarizationMiddleware(model=MagicMock(), trigger=("tokens", 36000),
                               keep=("tokens", 6000))
out["trigger_tuple"] = m.pacgate_resolve_trigger_tokens(mw)
out["trigger_list_of_tuples"] = m.pacgate_resolve_trigger_tokens(
    m.SummarizationMiddleware(model=MagicMock(), trigger=[("tokens", 36000)],
                              keep=("tokens", 6000)))
out["trigger_unknown"] = m.pacgate_resolve_trigger_tokens(Odd())

# ── R7: status against the live counter ────────────────────────────────────
snap = m.pacgate_context_status(mw, [HumanMessage(content="word " * 5000)])
out["status"] = snap
print(json.dumps(out))
'''
    rc, raw = run_in_container(script)
    payload_line = ""
    for line in reversed(raw.strip().splitlines()):
        if line.startswith("{"):
            payload_line = line
            break
    if not payload_line:
        cannot_check(f"probe produced no JSON (rc={rc}): {raw.strip()[:400]}")
    try:
        res = json.loads(payload_line)
    except json.JSONDecodeError:
        cannot_check(f"probe JSON unparseable: {payload_line[:300]}")

    if "import_error" in res:
        check("R-patch imports in the real venv", False, res["import_error"])
        print(f"\nRESULT: {_passed} passed, {_failed} failed")
        return 1

    # R2: stock signature must be byte-identical to before the patch
    check("R2 the stock single-argument call still works",
          res["one_arg"] == "Here is a summary of the conversation to date:\n\nSUM",
          repr(res["one_arg"]))

    # R3: index appended on the two-argument path
    two = res["two_arg"]
    check("R3 the two-argument path appends a verbatim index",
          "recoverable handles" in two and "read_file" in two
          and "/data/outputs/handbook.pdf" in two and "1. Scope" in two,
          two)

    # R4: no bloat when there is nothing to index
    check("R4 a range with no handles appends nothing",
          res["no_handles"] == "", repr(res["no_handles"]))

    # R5: the index must cost far less than the range it describes. Measured on a
    # range the size a real summarization pass folds, not on a toy fixture - the
    # index carries fixed explanatory text, so a tiny range measures the
    # boilerplate rather than the compression.
    ratio = res["big_index_len"] / max(1, res["big_folded_len"])
    check("R5 the index is small relative to the range it describes",
          ratio < 0.10,
          f"index={res['big_index_len']} chars vs folded={res['big_folded_len']} chars "
          f"(ratio {ratio:.3f}, want < 0.100)")

    # R6: the runtime tuple is the shape that actually occurs
    check("R6 the resolver reads the RUNTIME tuple shape",
          res["trigger_tuple"] == 36000, f"got {res['trigger_tuple']!r} (want 36000)")
    check("R6b a list of runtime tuples also resolves",
          res["trigger_list_of_tuples"] == 36000, f"got {res['trigger_list_of_tuples']!r}")

    # R8: unknown shape must be 0, not a confident zero-pressure reading
    check("R8 an unrecognised trigger shape reports 0 (cannot report)",
          res["trigger_unknown"] == 0, f"got {res['trigger_unknown']!r}")

    # R7: status numbers agree with the middleware's own decision
    snap = res["status"]
    check("R7 context status reports against the live counter",
          snap["trigger_tokens"] == 36000 and snap["used_tokens"] > 0
          and 0 < snap["used_pct_of_trigger"] < 100
          and snap["headroom_tokens"] == snap["trigger_tokens"] - snap["used_tokens"]
          and snap["should_summarize"] is False,
          json.dumps(snap))

    print(f"\nRESULT: {_passed} passed, {_failed} failed")
    return 0 if _failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
