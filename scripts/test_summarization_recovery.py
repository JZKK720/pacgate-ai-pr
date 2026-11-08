"""Gate: the summarization recovery patch keeps a folded range recoverable.

WHAT THIS ASSERTS, and why each one is a real failure mode rather than a style
preference.

THE ASSERTION THAT MATTERS MOST IS R1. The first version of this patch edited
`langchain/agents/middleware/summarization.py::_build_new_messages`, mounted
cleanly, imported cleanly, and was INERT: deer-flow overrides that method in
`deerflow/agents/middlewares/summarization_middleware.py`, so the runtime never
called the patched base implementation. A patch that is mounted and imported but
never executed looks exactly like a working one from the outside. R1 therefore
asserts the RUNTIME DISPATCH TARGET, not the file that was edited.

  R1  the patch ships the deer-flow middleware (the runtime dispatch target)
  R2  the stock one-argument call still works (upgrade safety)
  R3  the two-argument path appends a verbatim index
  R4  a range with no handles appends NOTHING (no prompt bloat)
  R5  the index is small relative to the range it describes
  R6  the trigger resolver reads the RUNTIME tuple shape, not the YAML shape
  R7  context status agrees with the middleware's own decision
  R8  an unrecognised trigger shape reports 0 ("cannot report"), never a
      confident "no pressure"
  R9  both _maybe_summarize call sites pass the folded range
  R10 both compose lanes mount the patch at the RUNTIME path
  R11 non-reproducible tool output is excerpted, reproducible output is not
  R12 the pressure hint is SILENT below the band and fires above it

R6 EXISTS BECAUSE THIS WAS A REAL BUG IN THE FIRST DRAFT. The resolver was
written against `deer-flow-config.yaml`, which writes a LIST OF DICTS
({type: tokens, value: 36000}). The live object holds
`ContextTokens = tuple[Literal["tokens"], int]`, i.e. ("tokens", 36000). A
dict-shaped resolver returns 0 against the live object and reports "no pressure"
on a run that is about to summarize - a silent zero, the worst kind.

Exit codes, matching the rest of this repo:
  0 = every assertion passed
  1 = a real failure
  2 = CANNOT CHECK (no container, or the patched module is not reachable)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

PATCH_REL = os.path.join("deploy", "client-bundle", "patches",
                         "deer-flow-summarization-recovery.py")
RUNTIME_TARGET = (
    "/app/backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py"
)
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
    out = proc.stdout or ""
    if proc.returncode:
        out += proc.stderr or ""
    return proc.returncode, out


def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    patch_path = os.path.join(repo_root, PATCH_REL)

    print("=== summarization recovery patch ===")

    if not os.path.exists(patch_path):
        cannot_check(f"patch not found at {PATCH_REL}")
    text = open(patch_path, encoding="utf-8", newline="").read()

    # ── R1: runtime dispatch target, not "a file that imports" ───────────────
    is_runtime_class = ("class DeerFlowSummarizationMiddleware" in text
                        and "def _pacgate_context_hint" in text)
    is_base_class = "class SummarizationMiddleware" in text
    check("R1 the patch ships the RUNTIME class deer-flow actually dispatches to",
          is_runtime_class and not is_base_class,
          "editing the langchain base class mounts and imports cleanly but is INERT, "
          "because deer-flow overrides _build_new_messages. See this file's docstring.")

    # ── R9: both call sites pass the folded range ────────────────────────────
    patched_n = text.count("new_messages = self._build_new_messages(summary, messages_to_summarize)")
    bare_n = text.count("new_messages = self._build_new_messages(summary)")
    check("R9 both _maybe_summarize and _amaybe_summarize pass the folded range",
          patched_n == 2 and bare_n == 0,
          f"patched={patched_n} (want 2), stock-form={bare_n} (want 0)")

    # ── R10: both lanes mount at the RUNTIME path ────────────────────────────
    lanes = {}
    for lane in ("compose.prod.yaml", "compose.bundle.yaml"):
        lane_path = os.path.join(repo_root, "deploy", "client-bundle", lane)
        try:
            lane_text = open(lane_path, encoding="utf-8", newline="").read()
        except OSError:
            lane_text = ""
        lanes[lane] = RUNTIME_TARGET in lane_text
    check("R10 both compose lanes mount the patch at the RUNTIME path",
          all(lanes.values()), json.dumps(lanes))

    probe = subprocess.run(["docker", "exec", CONTAINER, "true"], capture_output=True)
    if probe.returncode != 0:
        cannot_check(f"container {CONTAINER} is not running")

    cp = subprocess.run(["docker", "cp", patch_path, f"{CONTAINER}:/tmp/_recovery_probe.py"],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        cannot_check(f"could not stage the patch into {CONTAINER}: {cp.stderr.strip()}")

    script = r'''
import sys, json, importlib.util
sys.path.insert(0, "/app/backend/packages/harness")
from unittest.mock import MagicMock
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage

# Load the MOUNTED FILE directly rather than through the package. Two reasons,
# both learned here:
#   1. `import langchain.agents` fails on this image with a circular ImportError
#      (`factory` -> `middleware/__init__` -> `summarization` -> `agents`).
#      Measured 2026-11-08: that failure is PRE-EXISTING and reproduces with no
#      patch present and no harness path on sys.path. It is not caused by this
#      patch, and the running app is unaffected because uvicorn's boot order
#      binds AgentState first.
#   2. Loading the file directly is what we actually want to assert: the bytes
#      that will be mounted, executed.
# dataclasses resolves cls.__module__ through sys.modules, so the module must be
# registered before exec_module or the @dataclass decorator raises AttributeError.
spec = importlib.util.spec_from_file_location("dsum_probe", "/tmp/_recovery_probe.py")
m = importlib.util.module_from_spec(spec)
sys.modules["dsum_probe"] = m
try:
    spec.loader.exec_module(m)
except Exception as exc:
    print(json.dumps({"import_error": f"{type(exc).__name__}: {exc}"}))
    raise SystemExit(0)

out = {}
D = m.DeerFlowSummarizationMiddleware

out["one_arg"] = D._build_new_messages(MagicMock(), "SUM")[0].content

folded = [
    AIMessage(content="", tool_calls=[{"name": "read_file",
               "args": {"path": "/data/outputs/handbook.pdf"}, "id": "c1"}]),
    ToolMessage(content="# 1. Scope\nsee /data/office/matter-a/nda.docx",
                tool_call_id="c1", name="read_file"),
    AIMessage(content="## 2. Liability\nbody"),
]
out["two_arg"] = D._build_new_messages(MagicMock(), "SUM", folded)[0].content
out["no_handles"] = m._pacgate_folded_index([HumanMessage(content="plain prose")])

big = [ToolMessage(content=("# Section %d\n" % i) + ("body text. " * 40)
                   + "/data/outputs/doc-%d.pdf" % i,
                   tool_call_id="c%d" % i, name="read_file") for i in range(60)]
out["big_folded_len"] = sum(len(str(x.content)) for x in big)
out["big_index_len"] = len(m._pacgate_folded_index(big))

web = [AIMessage(content="", tool_calls=[{"name": "pacgate_web_scrape",
        "args": {"url": "https://example.com/j"}, "id": "w1"}]),
       ToolMessage(content="The court held X. " * 200, tool_call_id="w1",
                   name="pacgate_web_scrape")]
out["web_index"] = m._pacgate_folded_index(web)
disk = [AIMessage(content="", tool_calls=[{"name": "read_file",
         "args": {"path": "/data/outputs/a.pdf"}, "id": "d1"}]),
        ToolMessage(content="The court held X. " * 200, tool_call_id="d1",
                    name="read_file")]
out["disk_index"] = m._pacgate_folded_index(disk)

class Odd: trigger = "weird"
mw = D(model=MagicMock(), trigger=("tokens", 36000), keep=("tokens", 6000))
out["trigger_tuple"] = m._pacgate_resolve_trigger_tokens(mw)
out["trigger_list"] = m._pacgate_resolve_trigger_tokens(
    D(model=MagicMock(), trigger=[("tokens", 36000)], keep=("tokens", 6000)))
out["trigger_unknown"] = m._pacgate_resolve_trigger_tokens(Odd())
out["status"] = m.pacgate_context_status(mw, [HumanMessage(content="word " * 5000)])

per_word = mw.token_counter([HumanMessage(content="word " * 1000)]) / 1000.0
out["hint_below"] = mw._pacgate_context_hint(
    [HumanMessage(content="word " * int(36000 * 0.50 / per_word))])
out["hint_above"] = mw._pacgate_context_hint(
    [HumanMessage(content="word " * int(36000 * 0.92 / per_word))])

# ── R13: fold telemetry ─────────────────────────────────────────────────────
import os, tempfile, json as _json
tmp = os.path.join(tempfile.mkdtemp(), "fold.jsonl")
os.environ["PACGATE_FOLD_LOG"] = tmp
fold_msgs = [
    AIMessage(content="", tool_calls=[{"name": "read_file",
               "args": {"path": "/data/outputs/a.pdf"}, "id": "f1"}]),
    ToolMessage(content="body", tool_call_id="f1", name="read_file"),
    AIMessage(content="", tool_calls=[{"name": "read_file",
               "args": {"path": "/data/outputs/a.pdf"}, "id": "f2"}]),
    ToolMessage(content="body again", tool_call_id="f2", name="read_file"),
]
row = m.pacgate_record_fold(mw, fold_msgs, [HumanMessage(content="keep")])
out["fold_row"] = row
out["fold_file_exists"] = os.path.exists(tmp)
out["fold_file_rows"] = len(open(tmp, encoding="utf-8").read().strip().splitlines()) if os.path.exists(tmp) else 0
# telemetry must never raise, even on garbage input
out["fold_garbage_returns_none"] = m.pacgate_record_fold(mw, None, None) is None
# and it must not write message CONTENT
raw = open(tmp, encoding="utf-8").read() if os.path.exists(tmp) else ""
out["fold_leaks_content"] = ("body again" in raw) or ("keep" in raw)

# ── R14: the hint honours a declared model window ───────────────────────────
# A window SMALLER than the trigger is the case a trigger-only band gets wrong.
narrow = D(model=MagicMock(profile={"max_input_tokens": 20000}),
           trigger=("tokens", 36000), keep=("tokens", 6000))
out["narrow_window"] = narrow._get_profile_limits()
# 92% of the WINDOW (18,400) but only 51% of the trigger -> must fire on window logic
out["hint_narrow_fires"] = narrow._pacgate_context_hint(
    [HumanMessage(content="word " * int(18400 / per_word))])

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

    check("R2 the stock single-argument call still works",
          res["one_arg"] == "Here is a summary of the conversation to date:\n\nSUM",
          repr(res["one_arg"]))

    two = res["two_arg"]
    check("R3 the two-argument path appends a verbatim index",
          "recoverable handles" in two and "read_file" in two
          and "/data/outputs/handbook.pdf" in two and "1. Scope" in two, two)

    check("R4 a range with no handles appends nothing",
          res["no_handles"] == "", repr(res["no_handles"]))

    ratio = res["big_index_len"] / max(1, res["big_folded_len"])
    check("R5 the index is small relative to the range it describes",
          ratio < 0.10,
          f"index={res['big_index_len']} vs folded={res['big_folded_len']} "
          f"(ratio {ratio:.3f}, want < 0.100)")

    check("R11a non-reproducible tool output is excerpted",
          "CANNOT be re-fetched" in res["web_index"]
          and "The court held X." in res["web_index"], res["web_index"][:400])
    check("R11b reproducible tool output is NOT excerpted (pointer only)",
          "CANNOT be re-fetched" not in res["disk_index"]
          and "/data/outputs/a.pdf" in res["disk_index"], res["disk_index"][:400])

    check("R6 the resolver reads the RUNTIME tuple shape",
          res["trigger_tuple"] == 36000, f"got {res['trigger_tuple']!r} (want 36000)")
    check("R6b a list of runtime tuples also resolves",
          res["trigger_list"] == 36000, f"got {res['trigger_list']!r}")
    check("R8 an unrecognised trigger shape reports 0 (cannot report)",
          res["trigger_unknown"] == 0, f"got {res['trigger_unknown']!r}")

    snap = res["status"]
    check("R7 context status reports against the live counter",
          snap["trigger_tokens"] == 36000 and snap["used_tokens"] > 0
          and 0 < snap["used_pct_of_trigger"] < 100
          and snap["headroom_tokens"] == snap["trigger_tokens"] - snap["used_tokens"]
          and snap["should_summarize"] is False, json.dumps(snap))

    check("R12a the pressure hint is SILENT below the band",
          res["hint_below"] is None, repr(res["hint_below"])[:200])
    check("R12b the pressure hint FIRES above the band",
          isinstance(res["hint_above"], str) and "context-pressure" in res["hint_above"]
          and "fold budget used" in res["hint_above"], repr(res["hint_above"])[:300])

    # ── R13: fold telemetry is the sensor the hint needs ────────────────────
    row = res["fold_row"] or {}
    check("R13a a fold writes one telemetry row",
          res["fold_file_exists"] and res["fold_file_rows"] == 1, json.dumps(row)[:400])
    check("R13b the row carries the pressure, counts and re-read signal",
          row.get("tokens_at_fold", 0) > 0 and row.get("trigger_tokens") == 36000
          and row.get("folded_msgs") == 4 and row.get("preserved_msgs") == 1
          and row.get("tool_calls") == 2 and row.get("distinct_payloads") == 1
          and row.get("retouch_ratio") == 2.0, json.dumps(row)[:600])
    check("R13c the row records that no model window is declared",
          row.get("window_tokens") is None, f"window_tokens={row.get('window_tokens')!r}")
    check("R13d telemetry NEVER writes message content",
          res["fold_leaks_content"] is False,
          "a JSONL under the bind mount that captured folded text would be the "
          "second unscoped store this patch refuses")
    check("R13e telemetry never raises, even on garbage input",
          res["fold_garbage_returns_none"] is True, repr(res["fold_garbage_returns_none"]))

    # ── R14: the hint must key on the BINDING limit, not the trigger alone ──
    check("R14a a declared model window is discovered",
          res["narrow_window"] == 20000, f"got {res['narrow_window']!r}")
    check("R14b the hint fires on WINDOW pressure below the trigger",
          isinstance(res["hint_narrow_fires"], str)
          and "context-pressure" in res["hint_narrow_fires"],
          "a trigger-only band is silent here; on a model narrower than the "
          "trigger the diagnostic would be silent in exactly the case it exists for")

    print(f"\nRESULT: {_passed} passed, {_failed} failed")
    return 0 if _failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
