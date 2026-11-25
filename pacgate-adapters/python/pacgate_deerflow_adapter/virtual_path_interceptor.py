"""MCP tool-call interceptor: rewrite virtual paths in tool arguments.

Why this exists
---------------
``/mnt/user-data/...`` is a *virtual* path. Inside the container it does not
exist; the real directory is
``{paths.sandbox_*_dir(thread_id)}`` on the host-mapped volume. DeerFlow
rewrites virtual paths for bash commands and for ``read_file``, but never for
arguments handed to MCP tools, so an agent that calls
``officecli({"command": "create /mnt/user-data/outputs/x.docx"})`` gets a raw
"file not found" from a tool that cannot see the virtual root.

This module implements the fix as an ``mcpInterceptors`` entry (see
``deerflow.mcp.interceptors.build_mcp_tool_interceptors``) instead of a
whole-file fork of ``deerflow.mcp.tools``. The stock 2.2.0 module is already
correct about runtime injection and argument passing, so wrapping it keeps the
patch surface to the one behaviour that is actually missing.

Scope is deliberately narrow, because this rewrites arbitrary strings inside
arbitrary tool arguments and a blind rewrite is how a prompt injection becomes
a filesystem write:

* only ``str`` values are inspected, and only when they contain the virtual
  prefix at all;
* a value that does not mention the virtual prefix is returned untouched;
* only the three known roots (``workspace``/``uploads``/``outputs``) and their
  common parent are mapped, and the mapping is computed by deer-flow itself
  (``sandbox.tools._thread_virtual_to_actual_mappings``), so no path segment is
  invented here;
* dicts and lists/tuples are walked to a bounded depth; anything else is left
  alone;
* when no thread context can be resolved the interceptor is a no-op.

Registered in ``deploy/client-bundle/deer-flow-extensions-config.json`` as::

    "mcpInterceptors": ["pacgate_deerflow_adapter.virtual_path_interceptor:build_virtual_path_interceptor"]
"""

from __future__ import annotations

import logging
from typing import Any

from langchain_mcp_adapters.interceptors import MCPToolCallRequest

from deerflow.config.paths import VIRTUAL_PATH_PREFIX, get_paths
from deerflow.runtime.user_context import resolve_runtime_user_id
from deerflow.sandbox.tools import (
    get_thread_data,
    replace_virtual_path,
    replace_virtual_paths_in_command,
)
from deerflow.tools.types import Runtime

logger = logging.getLogger(__name__)

_ARG_PATH_MAX_DEPTH = 8


def _thread_data_for_mcp(runtime: Runtime | None) -> dict[str, str] | None:
    """Best-effort thread-data for an MCP tool call.

    Preferred source is the injected ``runtime.state["thread_data"]`` written by
    ``ThreadDataMiddleware``. When the tool runs outside a graph (a direct unit
    call, or a graph that does not inject state), fall back to deriving the same
    three directories from the thread id -- the same derivation
    ``ThreadDataMiddleware`` performs -- so the rewrite still works.
    """
    thread_data = get_thread_data(runtime)
    if thread_data:
        return thread_data

    thread_id = _thread_id_from_runtime(runtime)
    if not thread_id or thread_id == "default":
        return None

    user_id = resolve_runtime_user_id(runtime)
    try:
        paths = get_paths()
        return {
            "workspace_path": str(paths.sandbox_work_dir(thread_id, user_id=user_id)),
            "uploads_path": str(paths.sandbox_uploads_dir(thread_id, user_id=user_id)),
            "outputs_path": str(paths.sandbox_outputs_dir(thread_id, user_id=user_id)),
        }
    except Exception as exc:  # noqa: BLE001 - a failed derivation must not break the call
        logger.warning("MCP argument path rewrite skipped: could not derive thread dirs: %s", exc)
        return None


def _thread_id_from_runtime(runtime: Runtime | None) -> str | None:
    """Mirror ``deerflow.mcp.tools._extract_thread_id`` without importing a private symbol."""
    if runtime is None:
        return None
    context = getattr(runtime, "context", None) or {}
    tid = context.get("thread_id") if isinstance(context, dict) else None
    if tid is not None:
        return str(tid)
    config = getattr(runtime, "config", None) or {}
    configurable = config.get("configurable") if isinstance(config, dict) else None
    tid = configurable.get("thread_id") if isinstance(configurable, dict) else None
    return str(tid) if tid is not None else None


def _rewrite_virtual_paths_in_value(value: Any, thread_data: Any, *, _depth: int) -> Any:
    """Recursively rewrite virtual paths inside an arbitrary argument value."""
    if _depth >= _ARG_PATH_MAX_DEPTH:
        return value
    if isinstance(value, str):
        if VIRTUAL_PATH_PREFIX not in value:
            return value
        # Two shapes reach an MCP argument, and they need different helpers:
        #
        #   a PURE path      "/mnt/user-data/uploads/a.pdf"
        #   an EMBEDDED path "create /mnt/user-data/outputs/x.docx"
        #
        # ``replace_virtual_path`` only rewrites a value that STARTS with a virtual
        # root, so it is exact (and space-safe) but leaves a command string alone.
        # ``replace_virtual_paths_in_command`` rewrites anywhere in the string, but
        # tokenizes on whitespace, so a path that contains a space must not reach it
        # first. Try the exact one and fall back to the embedded one.
        new_value = replace_virtual_path(value, thread_data)
        if new_value == value:
            new_value = replace_virtual_paths_in_command(value, thread_data)
        if new_value != value:
            logger.info("MCP argument path rewrite applied")
        return new_value
    if isinstance(value, dict):
        return _rewrite_virtual_paths_in_args(value, thread_data, _depth=_depth + 1)
    if isinstance(value, (list, tuple)):
        items = [_rewrite_virtual_paths_in_value(item, thread_data, _depth=_depth + 1) for item in value]
        if isinstance(value, tuple):
            items = tuple(items)
        return items if any(a is not b for a, b in zip(items, value)) else value
    return value


def _rewrite_virtual_paths_in_args(args: dict[str, Any], thread_data: Any, *, _depth: int = 0) -> dict[str, Any]:
    """Return *args* with virtual ``/mnt/user-data`` paths mapped to thread paths.

    No-op when *thread_data* is falsy, so a call with no thread context keeps the
    exact previous behaviour instead of failing.
    """
    if not thread_data or not isinstance(args, dict):
        return args
    if _depth >= _ARG_PATH_MAX_DEPTH:
        return args

    rewritten: dict[str, Any] = {}
    changed = False
    for key, value in args.items():
        new_value = _rewrite_virtual_paths_in_value(value, thread_data, _depth=_depth)
        if new_value is not value:
            changed = True
        rewritten[key] = new_value
    return rewritten if changed else args


def build_virtual_path_interceptor():
    """Return the ``mcpInterceptors`` entry point.

    deer-flow calls the zero-argument builder, then invokes the returned callable
    as ``await interceptor(request, handler)`` for every MCP tool call, on both the
    stdio (pooled session) and HTTP/SSE paths.
    """

    async def intercept(request: MCPToolCallRequest, handler):
        thread_data = _thread_data_for_mcp(request.runtime)  # type: ignore[arg-type]
        args = _rewrite_virtual_paths_in_args(dict(request.args), thread_data)
        if args is not request.args:
            request = request.override(args=args)
        return await handler(request)

    return intercept
