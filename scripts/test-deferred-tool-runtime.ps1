# Test: the deferred-tool patch must actually EXECUTE inside the running container.
#
# WHY THIS EXISTS
#
# scripts/test-tool-search-deferral.ps1 is a STATIC test: it greps the patch file
# and the compose mount. That proves the code is present and wired, but not that
# it runs. The one claim it cannot make is the one that matters most - that a
# deferred MCP tool call is promoted AND executed in the same turn rather than
# bouncing off the "deferred, not promoted" error path that caused tool_search to
# be disabled in the first place.
#
# A static test would still pass if the patch imported the wrong symbol, if the
# middleware were never constructed, or if the container were running the
# unpatched upstream file. This test imports the REAL module from the REAL
# container and drives the REAL middleware methods.
#
# WHAT IT ASSERTS
#
#   R1  The mounted file is the patched one (contains the auto-promote path).
#   R2  The module imports cleanly inside the container - a syntax error or a
#       missing dependency fails here, not at the first user turn.
#   R3  A call to a HIDDEN deferred tool is promoted AND the handler still runs
#       (this is the whole fix: promote + execute in one turn).
#   R4  The promotion is merged into the handler's own Command updates rather
#       than replacing them - a tool that writes state must not lose its writes.
#   R5  A call to a NON-deferred tool passes through untouched (no spurious
#       promotion, handler result returned as-is).
#   R6  The async path behaves identically to the sync path.
#   R7  The deferred-tools prompt section TELLS the model a direct call works.
#       Without this the auto-promote path exists but is never selected: measured
#       on 0.1.34, the section was a bare list of names with no instruction verb,
#       and the live run called tool_search first, so the auto-promote line never
#       fired. A runtime probe cannot catch that - the middleware was correct the
#       whole time - so it is asserted on the RENDERED text instead.
#
# Usage:  powershell -File scripts/test-deferred-tool-runtime.ps1
# Exit:   0 = all assertions pass, 1 = a failure, 2 = could not check (no stack).

[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$script:passed = 0
$script:failed = 0

function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Info($m) { Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host '=== deferred-tool patch: runtime execution ===' -ForegroundColor Cyan

# --- preflight: the stack must be up, or this test cannot say anything --------
$running = (& docker ps --filter "name=^/$Container$" --format '{{.Names}}' 2>&1) -join ''
if ($running -notmatch [regex]::Escape($Container)) {
    Write-Host "RESULT: SKIP - container '$Container' is not running; cannot check." -ForegroundColor Yellow
    exit 2
}

$target = '/app/backend/packages/harness/deerflow/agents/middlewares/deferred_tool_filter_middleware.py'

# --- R1: the mounted file is the patched one ----------------------------------
$marker = (& docker exec $Container grep -c 'Auto-promoting deferred tool' $target 2>&1) -join ''
if ($marker.Trim() -match '^[1-9]') {
    Pass 'R1 the mounted middleware is the patched file'
} else {
    Fail "R1 the mounted middleware is NOT patched (marker count: $marker)"
    Info 'The container is running the unpatched upstream file; deferral will loop.'
}

# --- R2..R6: drive the real middleware inside the container -------------------
# The probe is written to a temp file inside the container so quoting cannot
# mangle it, then executed with the container's own interpreter.
$probe = @'
import asyncio, json, sys, traceback

out = {"ok": False, "checks": [], "error": None}

def check(name, cond, detail=""):
    out["checks"].append({"name": name, "pass": bool(cond), "detail": str(detail)})

try:
    from langchain_core.messages import ToolMessage
    from langgraph.types import Command
    from deerflow.agents.middlewares.deferred_tool_filter_middleware import (
        DeferredToolFilterMiddleware,
    )

    # Build a middleware instance without running __init__: the constructor wants
    # a live catalog and a real state graph. We only need the two methods under
    # test, so we set the attributes they read.
    mw = DeferredToolFilterMiddleware.__new__(DeferredToolFilterMiddleware)
    mw._deferred = True
    mw._catalog_hash = "testhash"
    mw._hidden = lambda state: {"pacgate_kb_search"}

    class Req:
        def __init__(self, name):
            self.tool_call = {"name": name, "args": {}, "id": "call_1"}
            self.state = {}

    # R3: hidden tool -> promoted AND handler executed.
    ran = {"n": 0}
    def handler(req):
        ran["n"] += 1
        return ToolMessage(content="tool-output", tool_call_id="call_1")

    res = mw.wrap_tool_call(Req("pacgate_kb_search"), handler)
    promoted = isinstance(res, Command) and "promoted" in (res.update or {})
    names = (res.update or {}).get("promoted", {}).get("names", []) if promoted else []
    msgs = (res.update or {}).get("messages", []) if promoted else []
    check("R3 hidden tool is promoted", promoted and names == ["pacgate_kb_search"], names)
    check("R3 handler still executed in the same turn", ran["n"] == 1, ran["n"])
    check("R3 tool output is preserved", len(msgs) == 1 and msgs[0].content == "tool-output", len(msgs))

    # R4: handler returns its own Command -> its updates must survive the merge.
    def cmd_handler(req):
        return Command(update={"custom_key": "kept"}, goto="next_node")

    res2 = mw.wrap_tool_call(Req("pacgate_kb_search"), cmd_handler)
    upd = res2.update or {}
    check("R4 handler Command updates survive the merge", upd.get("custom_key") == "kept", list(upd))
    check("R4 promotion is merged in, not substituted", "promoted" in upd, list(upd))
    check("R4 handler goto is preserved", getattr(res2, "goto", None) == "next_node", getattr(res2, "goto", None))

    # R5: non-deferred tool -> untouched passthrough.
    ran2 = {"n": 0}
    def handler2(req):
        ran2["n"] += 1
        return ToolMessage(content="plain", tool_call_id="call_1")

    res3 = mw.wrap_tool_call(Req("bash"), handler2)
    check("R5 non-deferred tool passes through untouched",
          isinstance(res3, ToolMessage) and res3.content == "plain", type(res3).__name__)
    check("R5 non-deferred handler ran exactly once", ran2["n"] == 1, ran2["n"])

    # R6: async path must match the sync path.
    ran3 = {"n": 0}
    async def ahandler(req):
        ran3["n"] += 1
        return ToolMessage(content="async-output", tool_call_id="call_1")

    ares = asyncio.run(mw.awrap_tool_call(Req("pacgate_kb_search"), ahandler))
    apromoted = isinstance(ares, Command) and "promoted" in (ares.update or {})
    check("R6 async path promotes", apromoted, type(ares).__name__)
    check("R6 async handler still executed", ran3["n"] == 1, ran3["n"])

    # R7: the prompt section must say a DIRECT call is supported.
    #
    # This is the gap the 2026-10-21 live run exposed. The middleware promoted
    # correctly, but <available-deferred-tools> was a bare list and tool_search's
    # own description says a name is not callable "until fetched", so the model
    # fetched first and the auto-promote path was never exercised. Asserting on
    # the rendered text is the only way to catch that: the code was right.
    from deerflow.tools.builtins.tool_search import get_deferred_tools_prompt_section

    rendered = get_deferred_tools_prompt_section(
        deferred_names=frozenset({"pacgate_kb_search", "pacgate_list_documents"})
    )
    lowered = rendered.lower()
    check("R7 section names every deferred tool", "pacgate_kb_search" in rendered and "pacgate_list_documents" in rendered, rendered[:120])
    check("R7 section tells the model a direct call works", "directly" in lowered, rendered[-200:])
    check("R7 section says promotion needs no fetch first", "no" in lowered and "need to fetch it first" in lowered, rendered[-200:])
    check("R7 section keeps tool_search as the fallback", "tool_search" in rendered, rendered[-200:])
    # The empty case must stay empty: a stray instruction with no names would
    # put deferral guidance in every prompt even when nothing is deferred.
    check("R7 empty deferred set renders nothing", get_deferred_tools_prompt_section(deferred_names=frozenset()) == "", "non-empty")

    out["ok"] = True
except Exception:
    out["error"] = traceback.format_exc()

print("PROBE_JSON:" + json.dumps(out))
'@

# Write the probe into the container via stdin so no host temp file is needed and
# quoting cannot be mangled by the shell.
$probePath = '/tmp/_deferral_probe.py'
$probe | & docker exec -i $Container sh -c "cat > $probePath" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail 'could not stage the probe inside the container'
    Write-Host "RESULT: FAIL - $($script:failed) failure(s)." -ForegroundColor Red
    exit 1
}

$raw = (& docker exec $Container /app/backend/.venv/bin/python $probePath 2>&1) -join "`n"
& docker exec $Container rm -f $probePath 2>&1 | Out-Null

$line = ($raw -split "`n" | Where-Object { $_ -match '^PROBE_JSON:' } | Select-Object -First 1)
if (-not $line) {
    Fail 'R2 the module could not be imported or the probe crashed'
    Info ($raw -split "`n" | Select-Object -Last 12) -join "`n"
    Write-Host "RESULT: FAIL - $($script:failed) failure(s)." -ForegroundColor Red
    exit 1
}

$data = ($line -replace '^PROBE_JSON:', '') | ConvertFrom-Json

if (-not $data.ok) {
    Fail 'R2 the module imported but the probe raised'
    Info $data.error
    Write-Host "RESULT: FAIL - $($script:failed) failure(s)." -ForegroundColor Red
    exit 1
}
Pass 'R2 the patched module imports cleanly inside the container'

foreach ($c in $data.checks) {
    if ($c.pass) { Pass $c.name } else { Fail ("{0} (got: {1})" -f $c.name, $c.detail) }
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "RESULT: FAIL - $($script:failed) failure(s), $($script:passed) passed." -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: $($script:passed) passed, 0 failed" -ForegroundColor Green
exit 0
