#!/usr/bin/env python3
"""Prove the pacgate-mcp 401-retry behaviour (deploy/pacgate-mcp/server.py).

WHY THIS EXISTS
===============
pacgate-api issues 24-hour JWTs (pacgate-core/src/lib.rs: Duration::hours(24)),
but PacgateApi authenticated once at startup. So 24 h after every (re)start,
every MCP tool call returned 401 until the container was recreated - observed
live on AIPC #1 (login 09-28 07:33, first 401 09-29 08:05). The fix is a
re-login plus one retry.

This file proves the four properties that make the fix CORRECT, not merely
present. A check that cannot fail is worse than no check, so every case also
asserts the negative:

  1. a 401 triggers exactly ONE re-login and ONE retry, and the retry carries
     the NEW token (not the expired one that just failed)
  2. a second 401 does NOT loop - the response is handed back to the caller
  3. multipart uploads keep httpx's generated multipart Content-Type; a JSON
     Content-Type here would make the server parse a multipart body as JSON and
     break every document upload
  4. a PACGATE_JWT_TOKEN-only deployment (no credentials) does NOT retry -
     there is nothing to re-login with, so the 401 surfaces exactly as before

The test stubs the MCP SDK (not installed on a dev box) and drives PacgateApi
against a scripted httpx transport, so it needs neither pacgate-api nor Docker.

Run: python scripts/test-mcp-401-retry.py     (exit 0 = pass, 1 = fail)
"""

from __future__ import annotations

import importlib.util
import io
import os
import sys
import types
from contextlib import redirect_stdout
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parent.parent
SERVER_PY = REPO / "deploy" / "pacgate-mcp" / "server.py"

passed = 0
failed = 0


def ok(msg: str) -> None:
    global passed
    passed += 1
    print(f"  [PASS] {msg}")


def bad(msg: str) -> None:
    global failed
    failed += 1
    print(f"  [FAIL] {msg}")


def check(condition: bool, msg: str) -> None:
    ok(msg) if condition else bad(msg)


def install_mcp_stub() -> None:
    """Provide a minimal mcp.server.fastmcp so server.py imports without the SDK."""
    for name in ("mcp", "mcp.server", "mcp.server.fastmcp"):
        module = types.ModuleType(name)
        sys.modules.setdefault(name, module)

    class _FakeFastMCP:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def tool(self, *args, **kwargs):
            def decorator(fn):
                return fn

            return decorator

        def run(self, *args, **kwargs) -> None:
            pass

    sys.modules["mcp.server.fastmcp"].FastMCP = _FakeFastMCP


def load_server_module():
    install_mcp_stub()
    spec = importlib.util.spec_from_file_location("pacgate_mcp_server", SERVER_PY)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SERVER_PY}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ScriptedTransport(httpx.BaseTransport):
    """Records every request and answers from a per-path script.

    A script entry is a list of (status, json_body) consumed in order; the last
    entry repeats once exhausted.
    """

    def __init__(self, script: dict[str, list[tuple[int, dict]]]) -> None:
        self.script = script
        self.calls: list[dict[str, object]] = []
        self.counts: dict[str, int] = {}

    def handle_request(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        self.calls.append(
            {
                "method": request.method,
                "path": path,
                "auth": request.headers.get("authorization"),
                "content_type": request.headers.get("content-type"),
            }
        )
        index = self.counts.get(path, 0)
        self.counts[path] = index + 1

        entries = self.script.get(path)
        if entries is None:
            return httpx.Response(404, json={"error": "unscripted path"})
        status, body = entries[index] if index < len(entries) else entries[-1]
        return httpx.Response(status, json=body)

    def calls_to(self, path: str) -> list[dict[str, object]]:
        return [c for c in self.calls if c["path"] == path]


def make_api(module, transport: ScriptedTransport, *, with_credentials: bool = True):
    env = {
        "PACGATE_API_URL": "http://pacgate-api:8080",
        # A jwt_token is present so __init__ does NOT attempt a login on the
        # real network; re-login is still possible because credentials exist.
        "PACGATE_JWT_TOKEN": "STALE-TOKEN",
    }
    if with_credentials:
        env["PACGATE_API_EMAIL"] = "svc@pacgate.local"
        env["PACGATE_API_PASSWORD"] = "not-a-real-secret"

    original = dict(os.environ)
    os.environ.update(env)
    try:
        api = module.PacgateApi()
    finally:
        os.environ.clear()
        os.environ.update(original)

    # Substitute the scripted transport; keep the client's other config.
    api._client = httpx.Client(transport=transport, timeout=5.0)
    return api


def case_1_retry_uses_new_token(module) -> None:
    print("\nCASE 1 - a 401 re-logins once and retries with the NEW token")
    transport = ScriptedTransport(
        {
            "/api/auth/login": [(200, {"token": "FRESH-TOKEN"})],
            "/api/matters": [(401, {"detail": "token expired"}), (200, {"items": []})],
        }
    )
    api = make_api(module, transport)
    resp = api.get("/api/matters")

    check(resp.status_code == 200, f"call succeeded after retry (got {resp.status_code})")
    attempts = transport.calls_to("/api/matters")
    check(len(attempts) == 2, f"exactly 2 attempts to /api/matters (got {len(attempts)})")
    logins = transport.calls_to("/api/auth/login")
    check(len(logins) == 1, f"exactly 1 re-login (got {len(logins)})")
    check(
        attempts[0]["auth"] == "Bearer STALE-TOKEN",
        f"attempt 1 used the stale token (got {attempts[0]['auth']!r})",
    )
    check(
        attempts[1]["auth"] == "Bearer FRESH-TOKEN",
        f"attempt 2 used the REFRESHED token (got {attempts[1]['auth']!r})",
    )


def case_2_no_infinite_loop(module) -> None:
    print("\nCASE 2 - a persistent 401 does not loop; it surfaces to the caller")
    transport = ScriptedTransport(
        {
            "/api/auth/login": [(200, {"token": "STILL-BAD"})],
            "/api/kb/search": [(401, {"detail": "nope"})],
        }
    )
    api = make_api(module, transport)
    resp = api.get("/api/kb/search")

    attempts = transport.calls_to("/api/kb/search")
    check(resp.status_code == 401, f"401 returned to caller (got {resp.status_code})")
    check(len(attempts) == 2, f"exactly 2 attempts, no loop (got {len(attempts)})")
    logins = transport.calls_to("/api/auth/login")
    check(len(logins) == 1, f"exactly 1 re-login attempt (got {len(logins)})")


def case_3_multipart_content_type(module) -> None:
    print("\nCASE 3 - multipart uploads keep the generated multipart Content-Type")
    transport = ScriptedTransport(
        {
            "/api/auth/login": [(200, {"token": "FRESH-TOKEN"})],
            "/api/documents": [(200, {"id": "doc-1"})],
        }
    )
    api = make_api(module, transport)
    resp = api.post_multipart(
        "/api/documents",
        {"matter_id": "matter-1"},
        {"file": ("evidence.txt", b"hello", "text/plain")},
    )

    check(resp.status_code == 200, f"upload returned 200 (got {resp.status_code})")
    uploads = transport.calls_to("/api/documents")
    check(len(uploads) == 1, f"upload made 1 request (got {len(uploads)})")
    ctype = str(uploads[0]["content_type"] or "")
    check(
        ctype.startswith("multipart/form-data"),
        f"Content-Type is multipart/form-data (got {ctype!r})",
    )
    check("boundary=" in ctype, "Content-Type carries a multipart boundary")
    check(
        "application/json" not in ctype,
        "Content-Type is NOT application/json (would break upload parsing)",
    )


def case_4_token_only_does_not_retry(module) -> None:
    print("\nCASE 4 - a PACGATE_JWT_TOKEN-only deployment does not retry")
    transport = ScriptedTransport(
        {
            "/api/auth/login": [(200, {"token": "UNREACHABLE"})],
            "/api/matters": [(401, {"detail": "token expired"})],
        }
    )
    api = make_api(module, transport, with_credentials=False)
    resp = api.get("/api/matters")

    attempts = transport.calls_to("/api/matters")
    logins = transport.calls_to("/api/auth/login")
    check(resp.status_code == 401, f"401 surfaces as before (got {resp.status_code})")
    check(len(attempts) == 1, f"exactly 1 attempt, no blind retry (got {len(attempts)})")
    check(len(logins) == 0, f"no login attempted (got {len(logins)})")


def main() -> int:
    global failed

    print("pacgate-mcp 401-retry behaviour test")
    print(f"target: {SERVER_PY}")
    if not SERVER_PY.exists():
        print(f"[FAIL] server.py not found at {SERVER_PY}")
        return 1

    buffer = io.StringIO()
    try:
        with redirect_stdout(buffer):
            module = load_server_module()
    except Exception as exc:  # noqa: BLE001 - surface any import failure as a test failure
        print(buffer.getvalue())
        print(f"[FAIL] could not import server.py: {type(exc).__name__}: {exc}")
        return 1

    if not hasattr(module, "PacgateApi"):
        print("[FAIL] server.py defines no PacgateApi class")
        return 1

    for case in (
        case_1_retry_uses_new_token,
        case_2_no_infinite_loop,
        case_3_multipart_content_type,
        case_4_token_only_does_not_retry,
    ):
        try:
            case(module)
        except Exception as exc:  # noqa: BLE001 - a raised case is a failed case
            bad(f"{case.__name__} raised {type(exc).__name__}: {exc}")

    print(f"\nassertions passed: {passed}  failed: {failed}")
    if failed:
        print("RESULT: FAILED")
        return 1
    print("RESULT: 401-retry behaviour verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
