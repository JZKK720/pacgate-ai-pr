#!/usr/bin/env python3
"""Assert pacgate_list_workflows over MCP returns the LIBRARY, not the built-ins.

Runs INSIDE the pacgate-mcp container.

WHY THIS IS SEPARATE FROM test-workflow-library-served.ps1
---------------------------------------------------------
That script checks the HTTP lane. This checks MCP. They are DIFFERENT LANES and
the MCP one is the one users actually touch: per this repo's standing rule the
workflow templates have no user-facing UI, so `pacgate_list_workflows` inside an
agent chat is the ONLY path to them. MCP calls the same API endpoint, so both
lanes shared the defect, but they are separate processes and a regression could
hit either alone.

It lives in its own file rather than embedded in the PowerShell guard so the probe
can be read, run, and debugged on its own - embedding ~40 lines of Python in a
PowerShell array literal was a string-generation exercise that failed to parse
twice.

Exit codes:
    0 = library served (count above the built-in floor)
    1 = only the built-ins -> the defect
    3 = could not check (no session / no payload / not JSON) - NEVER a pass

Usage:
    docker cp scripts/probe-mcp-workflow-count.py pacgate-mcp:/tmp/
    docker exec pacgate-mcp python3 /tmp/probe-mcp-workflow-count.py
"""
import json
import sys

import httpx

BASE = "http://127.0.0.1:8000/mcp"
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}
# The built-in Rust set is exactly 10. Anything at or below that is the fallback.
BUILTIN_FLOOR = 10


def parse_sse(text):
    """The server may answer as SSE; take the payload from the data: line."""
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[len("data: "):])
    return json.loads(text) if text.strip().startswith("{") else None


def main():
    with httpx.Client(timeout=60.0) as c:
        r = c.post(BASE, headers=HEADERS, json={
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "wf-count", "version": "1"},
            },
        })
        sid = r.headers.get("mcp-session-id")
        if not sid:
            print("ERROR: no mcp-session-id (status %s)" % r.status_code)
            return 3
        h = dict(HEADERS)
        h["mcp-session-id"] = sid

        c.post(BASE, headers=h,
               json={"jsonrpc": "2.0", "method": "notifications/initialized"})

        r = c.post(BASE, headers=h, json={
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "pacgate_list_workflows", "arguments": {}},
        })
        payload = parse_sse(r.text)
        if not payload:
            print("ERROR: no JSON payload from tools/call")
            return 3
        if "error" in payload:
            print("ERROR: tool call failed: %s" % payload["error"])
            return 3

        content = (payload.get("result") or {}).get("content") or []
        text = content[0].get("text", "") if content else ""
        try:
            data = json.loads(text)
        except Exception as exc:
            print("ERROR: tool text was not JSON: %s" % exc)
            return 3

        # Accept either a bare list or a wrapper object.
        if isinstance(data, dict):
            for key in ("workflows", "items", "data", "result"):
                if isinstance(data.get(key), list):
                    data = data[key]
                    break
        if not isinstance(data, list):
            print("ERROR: unexpected shape %s" % type(data).__name__)
            return 3

        count = len(data)
        cats = sorted({w.get("category", "?") for w in data
                       if isinstance(w, dict)})
        print("MCP workflows: %d  categories: %d" % (count, len(cats)))

        if count <= BUILTIN_FLOOR:
            print("FAIL: %d is the built-in fallback, not the library." % count)
            print("      The agent chat is the ONLY user-facing path to")
            print("      workflows, so this is user-visible. Check WORKFLOWS_DIR")
            print("      and the ./workflows mount on pacgate-api.")
            return 1

        # Report EVIDENCE, not raw template text. Printing the Chinese names
        # round-trips through the container's stdout encoding, which is not UTF-8
        # and garbles under a PowerShell capture - a guard whose output looks
        # broken undermines its own result. The count and category count are the
        # assertions; a non-ASCII tally proves the library (not the built-ins) was
        # loaded without depending on console encoding.
        non_ascii = sum(
            1 for w in data
            if isinstance(w, dict) and any(ord(ch) > 127 for ch in w.get("name", ""))
        )
        print("PASS: %d of %d names non-ASCII (library, not built-ins)" % (non_ascii, count))
        print("PASS: categories %d" % len(cats))
        return 0


if __name__ == "__main__":
    sys.exit(main())
