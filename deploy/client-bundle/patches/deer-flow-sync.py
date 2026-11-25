"""Utilities for invoking async tools from synchronous agent paths."""

import asyncio
import atexit
import concurrent.futures
import contextvars
import threading
import functools
import logging
from collections.abc import Callable
from typing import Any, get_type_hints

from langchain_core.runnables import RunnableConfig

logger = logging.getLogger(__name__)

# Shared thread pool for sync tool invocation in async environments.
_SYNC_TOOL_EXECUTOR = concurrent.futures.ThreadPoolExecutor(max_workers=10, thread_name_prefix="tool-sync")

atexit.register(lambda: _SYNC_TOOL_EXECUTOR.shutdown(wait=False))

# ─────────────────────────────────────────────────────────────────────────────
# Pacgate: shared background event loop for sync tool invocation.
#
# The stock implementation calls `asyncio.run(coro(...))` (and, in a running
# loop, a one-off `asyncio.run` inside a thread-pool worker), so every sync
# tool call gets its OWN loop. When parallel tool calls (e.g. two Firecrawl MCP
# tools issued together) go through the sync wrapper, each call gets a separate
# loop. The MCP session pool keys sessions by `(server, scope_key)` and tracks
# the owning event loop; a second call on a different loop sees the first
# call's in-flight session creation as foreign, evicts it, and cancels the
# subprocess spawn mid-flight (`asyncio.exceptions.CancelledError` at
# `_make_subprocess_transport`). That leaves the run waiting on a tool result
# that never arrives.
#
# Running every sync tool coroutine on ONE shared background loop removes the
# cross-loop race: the session pool never sees an in-flight creation on a loop
# it does not recognise. The async path (`ainvoke` -> `coroutine`) is
# unaffected.
# ─────────────────────────────────────────────────────────────────────────
_SYNC_LOOP: asyncio.AbstractEventLoop | None = None
_SYNC_LOOP_THREAD: threading.Thread | None = None
_SYNC_LOOP_LOCK = threading.Lock()


def _run_sync_loop(loop: asyncio.AbstractEventLoop) -> None:
    """Run the shared background event loop forever (daemon thread)."""
    asyncio.set_event_loop(loop)
    loop.run_forever()


def _get_sync_loop() -> asyncio.AbstractEventLoop:
    """Return the single shared background event loop, creating it on demand."""
    global _SYNC_LOOP, _SYNC_LOOP_THREAD
    with _SYNC_LOOP_LOCK:
        if _SYNC_LOOP is not None and not _SYNC_LOOP.is_closed():
            return _SYNC_LOOP

        loop = asyncio.new_event_loop()
        thread = threading.Thread(
            target=_run_sync_loop,
            args=(loop,),
            name="tool-sync-loop",
            daemon=True,
        )
        thread.start()
        _SYNC_LOOP = loop
        _SYNC_LOOP_THREAD = thread
        return loop


def _shutdown_sync_loop() -> None:
    """Stop the shared background event loop on interpreter exit."""
    global _SYNC_LOOP, _SYNC_LOOP_THREAD
    with _SYNC_LOOP_LOCK:
        if _SYNC_LOOP is not None and not _SYNC_LOOP.is_closed():
            _SYNC_LOOP.call_soon_threadsafe(_SYNC_LOOP.stop)
        _SYNC_LOOP = None
        _SYNC_LOOP_THREAD = None


atexit.register(_shutdown_sync_loop)

def _get_runnable_config_param(func: Callable[..., Any]) -> str | None:
    """Return the coroutine parameter that expects LangChain RunnableConfig."""
    if isinstance(func, functools.partial):
        func = func.func

    try:
        type_hints = get_type_hints(func)
    except Exception:
        return None

    for name, type_ in type_hints.items():
        if type_ is RunnableConfig:
            return name
    return None


def make_sync_tool_wrapper(coro: Callable[..., Any], tool_name: str) -> Callable[..., Any]:
    """Build a synchronous wrapper for an asynchronous tool coroutine.

    Args:
        coro: Async callable backing a LangChain tool.
        tool_name: Tool name used in error logs.

    Returns:
        A sync callable suitable for ``BaseTool.func``.

    Notes:
        If ``coro`` declares a ``RunnableConfig`` parameter, this wrapper
        exposes ``config: RunnableConfig`` so LangChain can inject runtime
        config and then forwards it to the coroutine's detected config
        parameter. This covers DeerFlow's current config-sensitive tools, such
        as ``invoke_acp_agent``.

        This wrapper intentionally does not synthesize a dynamic function
        signature. A future async tool with a normal user-facing argument named
        ``config`` and a separate ``RunnableConfig`` parameter named something
        else, such as ``run_config``, may collide with LangChain's injected
        ``config`` argument. Rename that user-facing field or extend this
        helper before using that signature.

        The returned wrapper is built with ``functools.wraps(coro)``, so it
        copies ``__name__``, ``__qualname__``, ``__doc__``, ``__annotations__``
        and ``__dict__`` and sets ``__wrapped__``. This matters for LangGraph:
        ``ToolNode._get_all_injected_args`` reads ``get_type_hints(tool.func)``,
        and ``get_type_hints`` follows ``__wrapped__`` back to the coroutine's
        own ``__globals__``. That is why injected parameters such as
        ``runtime: Runtime`` are still detected here even when the caller was
        compiled with ``from __future__ import annotations`` (mcp/tools.py,
        skill_manage_tool.py) and the annotation is a string. Do not replace
        ``wraps`` with a bare wrapper or a hand-copied signature: the string
        annotation would then be evaluated against the wrapper's module globals,
        or the ``runtime`` parameter would disappear entirely and the tool would
        run with ``runtime=None``.
    """
    config_param = _get_runnable_config_param(coro)

    def run_coroutine(*args: Any, **kwargs: Any) -> Any:
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None

        try:
            if loop is not None and loop.is_running():
                # We are already inside a running loop (async context). Run the
                # coroutine on the shared background loop so it shares an event
                # loop with the other sync tool calls - this is what stops the
                # cross-loop session-pool eviction described above. Preserve the
                # caller's contextvars.
                context = contextvars.copy_context()
                sync_loop = _get_sync_loop()
                future = asyncio.run_coroutine_threadsafe(context.run(coro, *args, **kwargs), sync_loop)
                return future.result()
            # No running loop (pure sync context): run on the shared loop too.
            sync_loop = _get_sync_loop()
            future = asyncio.run_coroutine_threadsafe(coro(*args, **kwargs), sync_loop)
            return future.result()
        except Exception as e:
            logger.error("Error invoking tool %r via sync wrapper: %s", tool_name, e, exc_info=True)
            raise

    if config_param:

        @functools.wraps(coro)
        def sync_wrapper(*args: Any, config: RunnableConfig = None, **kwargs: Any) -> Any:
            if config is not None or config_param not in kwargs:
                kwargs[config_param] = config
            return run_coroutine(*args, **kwargs)

        return sync_wrapper

    @functools.wraps(coro)
    def sync_wrapper(*args: Any, **kwargs: Any) -> Any:
        return run_coroutine(*args, **kwargs)

    return sync_wrapper
