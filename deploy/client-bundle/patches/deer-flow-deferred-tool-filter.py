"""PacGate patch (2026-10-21): auto-promote a deferred tool instead of erroring.

Base: deer-flow 2.2.0 ``deferred_tool_filter_middleware.py``.

ROOT CAUSE THIS PATCH FIXES
    ``tool_search`` was shipped DISABLED in deer-flow-config.yaml with this note:

        EVIDENCE (2026-09-12): deferral makes ALL models call MCP tools without
        promoting first -> "deferred, not promoted" loop, never reaching
        write_file.

    That is a real failure, and it is not a model defect - it is this
    middleware's design. When the model calls a deferred tool,
    ``_blocked_tool_message`` returns a ToolMessage saying "Call tool_search
    first ... then retry". The model then has to (a) understand the
    instruction, (b) emit a SECOND tool call to tool_search, (c) wait for the
    schema, and (d) re-emit the original call with correct arguments. Small
    local models routinely fail at step (b) or (d), so the run burns turns and
    never reaches the tool it actually wanted.

WHAT THIS PATCH DOES
    Turns the block into a transparent promotion. When the model calls a
    deferred tool, this middleware:

      1. promotes that tool's schema into graph state (same ``promoted`` key
         and catalog-hash scoping the real ``tool_search`` uses, so the
         reducer merges it correctly), and
      2. executes the call in the SAME turn via the normal handler.

    The model therefore never has to know that deferral exists. From the next
    turn the schema is bound normally, so the model can reason about it.

SAFETY
    - Promotion is scoped by catalog hash AND the genuine user-turn id (see
      ``_promotion_is_current``), so a stale persisted promotion cannot expose
      a renamed tool or leak into a later user turn.
    - The tool must still be in the deferred set to be promoted; an unknown
      name falls through to the normal handler.
    - The promoted payload carries the current ``turn_id`` so it composes with
      the upstream per-turn migration in ``_turn_state_update``.
"""

import logging
from collections.abc import Awaitable, Callable, Mapping, Sequence
from typing import Any, override

from langchain.agents import AgentState
from langchain.agents.middleware import AgentMiddleware
from langchain.agents.middleware.types import ModelCallResult, ModelRequest, ModelResponse
from langchain_core.messages import ToolMessage
from langgraph.prebuilt.tool_node import ToolCallRequest
from langgraph.runtime import Runtime
from langgraph.types import Command

from deerflow.agents.middlewares.message_utils import genuine_user_turn_id, has_ai_response_after_latest_user_message

logger = logging.getLogger(__name__)


class DeferredToolFilterMiddleware(AgentMiddleware[AgentState]):
    """Hide deferred tool schemas from the bound model until promoted.

    ToolNode still holds all tools (including deferred) for execution routing,
    but the LLM only sees active tool schemas plus tools that have already been
    promoted under the current catalog hash and genuine user turn.
    """

    def __init__(self, deferred_names: frozenset[str], catalog_hash: str | None):
        super().__init__()
        self._deferred = deferred_names
        self._catalog_hash = catalog_hash

    def release_policy_parameters(self) -> dict[str, object]:
        return {
            "deferred_names": sorted(self._deferred),
            "catalog_hash": self._catalog_hash,
            "promotion_scope": "graph_state_catalog_hash_user_turn",
        }

    def _promotion_is_current(self, state: Mapping[str, Any] | None, promoted: Mapping[str, Any]) -> bool:
        if promoted.get("catalog_hash") != self._catalog_hash:
            return False
        promoted_turn_id = promoted.get("turn_id")
        if promoted_turn_id is None:
            return has_ai_response_after_latest_user_message(list((state or {}).get("messages") or []))
        current_turn_id = genuine_user_turn_id(list((state or {}).get("messages") or []))
        return current_turn_id is not None and promoted_turn_id == current_turn_id

    def _promoted(self, state: Mapping[str, Any] | None) -> set[str]:
        promoted = (state or {}).get("promoted")
        if not isinstance(promoted, Mapping) or not self._promotion_is_current(state, promoted):
            return set()
        names = promoted.get("names")
        if isinstance(names, Sequence) and not isinstance(names, (str, bytes)):
            return {name for name in names if isinstance(name, str)}
        return set()

    def _turn_state_update(self, state: Mapping[str, Any] | None) -> dict[str, Any] | None:
        turn_id = genuine_user_turn_id(list((state or {}).get("messages") or []))
        if not self._deferred or not self._catalog_hash or turn_id is None:
            return None
        promoted = (state or {}).get("promoted")
        if isinstance(promoted, Mapping) and self._promotion_is_current(state, promoted):
            if promoted.get("turn_id") == turn_id:
                return None
            names = promoted.get("names")
            migrated_names = [name for name in names if isinstance(name, str)] if isinstance(names, Sequence) and not isinstance(names, (str, bytes)) else []
        else:
            migrated_names = []
        return {
            "promoted": {
                "catalog_hash": self._catalog_hash,
                "names": migrated_names,
                "turn_id": turn_id,
            }
        }

    def _hidden(self, state: Mapping[str, Any] | None) -> set[str]:
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

    def _promotion_payload(self, request: ToolCallRequest) -> dict[str, Any] | None:
        """Build the ``promoted`` payload for this call, or None if not deferred."""
        if not self._deferred:
            return None
        name = str(request.tool_call.get("name") or "")
        if not name or name not in self._hidden(request.state):
            return None
        turn_id = genuine_user_turn_id(list((request.state or {}).get("messages") or []))
        payload = {"catalog_hash": self._catalog_hash, "names": [name]}
        if turn_id is not None:
            payload["turn_id"] = turn_id
        return payload

    def _with_promotion(self, result: ToolMessage | Command, payload: dict[str, Any]) -> Command:
        """Merge the promotion into whatever the handler returned."""
        if isinstance(result, Command):
            merged = dict(result.update or {})
            merged["promoted"] = payload
            return Command(update=merged, goto=result.goto, graph=result.graph)
        return Command(update={"promoted": payload, "messages": [result]})

    @override
    def before_model(self, state: AgentState, runtime: Runtime) -> dict[str, Any] | None:
        return self._turn_state_update(state)

    @override
    async def abefore_model(self, state: AgentState, runtime: Runtime) -> dict[str, Any] | None:
        return self._turn_state_update(state)

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
        payload = self._promotion_payload(request)
        result = handler(request)
        if payload is None:
            return result
        logger.info(
            "Auto-promoting deferred tool %r on first call (tool_search deferral is transparent)",
            request.tool_call.get("name"),
        )
        return self._with_promotion(result, payload)

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
        payload = self._promotion_payload(request)
        result = await handler(request)
        if payload is None:
            return result
        logger.info(
            "Auto-promoting deferred tool %r on first call (tool_search deferral is transparent)",
            request.tool_call.get("name"),
        )
        return self._with_promotion(result, payload)
