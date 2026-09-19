"""Probe the pacgate MCP server over streamable-http: initialize -> tools/list.

Runs INSIDE the pacgate-mcp container (no curl there; python httpx is present
because the server itself uses it).
"""
import json

import httpx

BASE = "http://127.0.0.1:8000/mcp"
HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


def parse_sse(text: str) -> dict | None:
    """Extract the JSON payload from an SSE 'data:' line, if present."""
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[len("data: "):])
    return json.loads(text) if text.strip().startswith("{") else None


def main() -> None:
    with httpx.Client(timeout=10) as client:
        init = client.post(
            BASE,
            headers=HEADERS,
            json={
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "probe", "version": "0.0.1"},
                },
            },
        )
        sid = init.headers.get("mcp-session-id", "")
        print(f"SID={sid}")
        client.post(
            BASE,
            headers={**HEADERS, "mcp-session-id": sid},
            json={"jsonrpc": "2.0", "method": "notifications/initialized"},
        )
        resp = client.post(
            BASE,
            headers={**HEADERS, "mcp-session-id": sid},
            json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        )
        payload = parse_sse(resp.text)
        if payload and "result" in payload:
            names = [t["name"] for t in payload["result"]["tools"]]
            print(f"TOOL_COUNT={len(names)}")
            for name in sorted(names):
                print(f"TOOL={name}")
        else:
            print(f"RAW={resp.text[:500]}")


if __name__ == "__main__":
    main()