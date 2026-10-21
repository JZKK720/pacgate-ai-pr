"""PacGate patch (2026-10-21): auto-promote a deferred tool instead of erroring.

Base: ghcr.io/jzkk720/deer-flow-pacgate:0.1.34 image version of
``packages/harness/deerflow/agents/middlewares/deferred_tool_filter_middleware.py``.

ROOT CAUSE FIXED HERE
    ``tool_search`` was shipped DISABLED in deer-flow-config.yaml with this note:

        EVIDENCE (2026-09-12): deferral makes ALL models call MCP tools without
        promoting first -> "deferred, not promoted" loop, never reaching
        write_file.

    That is a real failure, and it is not a model defect - it is this middleware's
    design. When the model calls a deferred tool, ``_blocked_tool_message`` returns
    a ToolMessage that says "Call tool_search first ... then retry". The model then
    has to (a) understand the instruction, (b) emit a SECOND tool call to
    tool_search, (c) wait for the schema, and (d) re-emit the original call with
    correct arguments. Small local models (gemma4:12b, ornith-1.5:9b) routinely
    fail at step (b) or (d), so the run burns turns and never reaches the tool it
    actually wanted. The recorded symptom - "never reaching write_file" - is
    exactly that loop.

    The cost of leaving it disabled is large and measured on this box: MCP schemas
    are 32,023 of 42,582 bound characters, so deferral removes ~8,005 of ~10,645
    tokens from EVERY call (75%). At the measured 528 tok/s prefill that is ~15 s
    of fixed cost per call, on every turn of every run.

WHAT THIS PATCH DOES
    Turns the block into a transparent promotion. When the model calls a deferred
    tool, this middleware:

      1. promotes that tool's schema into graph state (same ``promoted`` key and
         catalog-hash scoping the real ``tool_search`` uses, so the reducer in
         thread_state.py merges it correctly), and
      2. executes the call in the SAME turn via the normal handler.

    The model therefore never has to know that deferral exists. It sees the tool
    name in <available-deferred-tools>, calls it, and it works. From the next turn
    the schema is bound normally, so the model can also reason about it.

    This is strictly better than the error path for small models: it removes the
    two steps they fail at, and it costs one extra schema in context only AFTER
    the tool has been used - which is when it is worth paying for.

WHY NOT JUST BIND EVERYTHING
    That is the current state and it is what this patch exists to avoid: 75% of
    every prompt is schema text for tools that, measured across 828 checkpoints
    and 2,664 tool calls on this box, were used in 380 of 2,664 calls (14%) - and
    the sandbox tools (bash/read_file/write_file) carried the rest.

SAFETY
    - Promotion is scoped by catalog hash, so a stale persisted name cannot expose
      a different tool after the catalog drifts.
    - The tool must still be in the deferred set to be promoted; an unknown name
      falls through to the normal handler, which raises the usual "not found".
    - Nothing is promoted for tools the policy filter removed, because the
      deferred set is built AFTER policy filtering.
"""

import logging
from collections.abc import Awaitable, Callable
from typing import override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import ToolMessage
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.types import Command

logger = logging.getLogger(__name__)


class DeferredToolFilterMiddleware(AgentMiddleware[AgentState]):
    """Hide deferred tool schemas from the bound model until promoted.

    ToolNode still holds all tools (including deferred) for execution routing,
    but the LLM only sees active tool schemas plus tools that have already been
    promoted (recorded in ``state["promoted"]`` under the current catalog hash).
    """

    def __init__(self, deferred_names: frozenset[str], catalog_hash: str | None):
        super().__init__()
        self._deferred = deferred_names
        self._catalog_hash = catalog_hash

    def _promoted(self, state) -> set[str]:
        promoted = (state or {}).get("promoted")
        if promoted and promoted.get("catalog_hash") == self._catalog_hash:
            return set(promoted.get("names") or [])
        return set()

    def _hidden(self, state) -> set[str]:
        return set(self._deferred) - self._promoted(state)

    def _filter_tools(self, request: ModelRequest) -> ModelRequest:
        if not self._deferred:
            return request
        hide = self._hidden(request.state)
        if not hide:
            return request
        active = [t for t in request.tools if getattr(t, "name", None) not in hide]
        if len(active) < len(request.tools):
            logger.debug("Filtered %d deferred tool schema(s) from model binding", len(request.tools) - len(active))
        return request.override(tools=active)

    def _promotion_command(self, request: ToolCallRequest) -> Command | None:
        """Promote the called tool and run it in the same turn.

        Returns None when the call is not for a hidden deferred tool, so the
        normal handler runs unchanged.
        """
        if not self._deferred:
            return None
        name = str(request.tool_call.get("name") or "")
        if not name or name not in self._hidden(request.state):
            return None

        # Promote BEFORE executing so the schema is bound from the next turn on.
        # The reducer in thread_state.merge_promoted unions names under the same
        # catalog hash, so this composes with a real tool_search call rather than
        # replacing its result.
        logger.info(
            "Auto-promoting deferred tool %r on first call (tool_search deferral is transparent)",
            name,
        )
        return Command(
            update={
                "promoted": {"catalog_hash": self._catalog_hash, "names": [name]},
            }
        )

    @override
    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelCallResult:
        return handler(self._filter_tools(request))

    @override
    def wrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], ToolMessage | Command],
    ) -> ToolMessage | Command:
        promotion = self._promotion_command(request)
        result = handler(request)
        if promotion is None:
            return result
        # Merge the promotion into whatever the handler returned. The handler's
        # result may itself be a Command (tools that write state) or a plain
        # ToolMessage; both must keep their own updates.
        if isinstance(result, Command):
            merged = dict(result.update or {})
            merged["promoted"] = {"catalog_hash": self._catalog_hash, "names": [str(request.tool_call.get("name"))]}
            return Command(update=merged, goto=result.goto, graph=result.graph)
        return Command(
            update={
                "promoted": {"catalog_hash": self._catalog_hash, "names": [str(request.tool_call.get("name"))]},
                "messages": [result],
            }
        )

    @override
    async def awrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], Awaitable[ModelResponse]],
    ) -> ModelCallResult:
        return await handler(self._filter_tools(request))

    @override
    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[ToolMessage | Command]],
    ) -> ToolMessage | Command:
        promotion = self._promotion_command(request)
        result = await handler(request)
        if promotion is None:
            return result
        if isinstance(result, Command):
            merged = dict(result.update or {})
            merged["promoted"] = {"catalog_hash": self._catalog_hash, "names": [str(request.tool_call.get("name"))]}
            return Command(update=merged, goto=result.goto, graph=result.graph)
        return Command(
            update={
                "promoted": {"catalog_hash": self._catalog_hash, "names": [str(request.tool_call.get("name"))]},
                "messages": [result],
            }
        )
