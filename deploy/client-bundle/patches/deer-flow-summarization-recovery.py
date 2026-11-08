"""Summarization middleware extensions for DeerFlow."""

from __future__ import annotations

import logging
import json
import os
import re
import threading
from datetime import datetime, timezone
from collections.abc import Collection
from dataclasses import dataclass
from typing import Any, Protocol, override, runtime_checkable

from langchain.agents import AgentState
from langchain.agents.middleware import SummarizationMiddleware
from langchain_core.messages import AIMessage, AnyMessage, HumanMessage, RemoveMessage, ToolMessage, get_buffer_string
from langgraph.config import get_config
from langgraph.constants import TAG_NOSTREAM
from langgraph.graph.message import REMOVE_ALL_MESSAGES
from langgraph.runtime import Runtime

from deerflow.agents.middlewares.dynamic_context_middleware import is_dynamic_context_reminder
from deerflow.agents.middlewares.tool_call_metadata import clone_ai_message_with_tool_calls

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SummarizationEvent:
    """Context emitted before conversation history is summarized away."""

    messages_to_summarize: tuple[AnyMessage, ...]
    preserved_messages: tuple[AnyMessage, ...]
    thread_id: str | None
    agent_name: str | None
    runtime: Runtime


@runtime_checkable
class BeforeSummarizationHook(Protocol):
    """Hook invoked before summarization removes messages from state."""

    def __call__(self, event: SummarizationEvent) -> None: ...


def _resolve_thread_id(runtime: Runtime) -> str | None:
    """Resolve the current thread ID from runtime context or LangGraph config."""
    thread_id = runtime.context.get("thread_id") if runtime.context else None
    if thread_id is None:
        try:
            config_data = get_config()
        except RuntimeError:
            return None
        thread_id = config_data.get("configurable", {}).get("thread_id")
    return thread_id


def _resolve_agent_name(runtime: Runtime) -> str | None:
    """Resolve the current agent name from runtime context or LangGraph config."""
    agent_name = runtime.context.get("agent_name") if runtime.context else None
    if agent_name is None:
        try:
            config_data = get_config()
        except RuntimeError:
            return None
        agent_name = config_data.get("configurable", {}).get("agent_name")
    return agent_name


def _tool_call_path(tool_call: dict[str, Any]) -> str | None:
    """Best-effort extraction of a file path argument from a read_file-like tool call."""
    args = tool_call.get("args") or {}
    if not isinstance(args, dict):
        return None
    for key in ("path", "file_path", "filepath"):
        value = args.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _clone_ai_message(
    message: AIMessage,
    tool_calls: list[dict[str, Any]],
    *,
    content: Any | None = None,
) -> AIMessage:
    """Clone an AIMessage while replacing its tool_calls list and optional content."""
    return clone_ai_message_with_tool_calls(message, tool_calls, content=content)


@dataclass
class _SkillBundle:
    """Skill-related tool calls and tool results associated with one AIMessage."""

    ai_index: int
    skill_tool_indices: tuple[int, ...]
    skill_tool_call_ids: frozenset[str]
    skill_tool_tokens: int
    skill_key: str


class DeerFlowSummarizationMiddleware(SummarizationMiddleware):
    """Summarization middleware with pre-compression hook dispatch and skill rescue."""

    def __init__(
        self,
        *args,
        skills_container_path: str | None = None,
        skill_file_read_tool_names: Collection[str] | None = None,
        before_summarization: list[BeforeSummarizationHook] | None = None,
        preserve_recent_skill_count: int = 5,
        preserve_recent_skill_tokens: int = 25_000,
        preserve_recent_skill_tokens_per_skill: int = 5_000,
        **kwargs,
    ) -> None:
        super().__init__(*args, **kwargs)
        self._skills_container_path = skills_container_path or "/mnt/skills"
        self._skill_file_read_tool_names = frozenset(skill_file_read_tool_names or {"read_file", "read", "view", "cat"})
        self._before_summarization_hooks = before_summarization or []
        self._preserve_recent_skill_count = max(0, preserve_recent_skill_count)
        self._preserve_recent_skill_tokens = max(0, preserve_recent_skill_tokens)
        self._preserve_recent_skill_tokens_per_skill = max(0, preserve_recent_skill_tokens_per_skill)
        # The summary LLM call runs inside a LangGraph middleware hook, so its token
        # stream would otherwise be captured by the messages-tuple stream callback and
        # broadcast to the frontend as a phantom AI message. Tag a dedicated model copy
        # with TAG_NOSTREAM so the streaming handler skips it.
        # Keep self.model untagged so the parent's profile / ls_params inspection still works.
        #
        # Preserve any tags already bound on the model (e.g. "middleware:summarize" set in
        # lead_agent/agent.py for RunJournal attribution): RunnableBinding.with_config does a
        # shallow merge that would otherwise overwrite the existing tags list entirely.
        existing_tags = list((getattr(self.model, "config", None) or {}).get("tags") or [])
        merged_tags = [*existing_tags, TAG_NOSTREAM] if TAG_NOSTREAM not in existing_tags else existing_tags
        self._summary_model = self.model.with_config(tags=merged_tags)

    @override
    def _create_summary(self, messages_to_summarize: list[AnyMessage]) -> str:
        return self._summarize_with(messages_to_summarize)

    @override
    async def _acreate_summary(self, messages_to_summarize: list[AnyMessage]) -> str:
        return await self._asummarize_with(messages_to_summarize)

    def _summarize_with(self, messages_to_summarize: list[AnyMessage]) -> str:
        """Mirror the parent ``_create_summary`` but invoke the nostream-tagged model.

        We do not swap ``self.model`` at the instance level: the agent/middleware is
        cached and reused across concurrent runs, so a temporary swap would leak the
        ``RunnableBinding`` to other coroutines during ``await`` and break parent logic
        that inspects the raw model (``profile`` / ``_get_ls_params``).
        """
        if not messages_to_summarize:
            return "No previous conversation history."
        prompt = self._build_summary_prompt(messages_to_summarize)
        if prompt is None:
            return "Previous conversation was too long to summarize."
        try:
            response = self._summary_model.invoke(
                prompt,
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception as e:
            return f"Error generating summary: {e!s}"

    async def _asummarize_with(self, messages_to_summarize: list[AnyMessage]) -> str:
        """Async counterpart of :meth:`_summarize_with` using the nostream model."""
        if not messages_to_summarize:
            return "No previous conversation history."
        prompt = self._build_summary_prompt(messages_to_summarize)
        if prompt is None:
            return "Previous conversation was too long to summarize."
        try:
            response = await self._summary_model.ainvoke(
                prompt,
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception as e:
            return f"Error generating summary: {e!s}"

    def _build_summary_prompt(self, messages_to_summarize: list[AnyMessage]) -> str | None:
        """Build the summary prompt, returning ``None`` when trimming leaves nothing."""
        trimmed_messages = self._trim_messages_for_summary(messages_to_summarize)
        if not trimmed_messages:
            return None
        # Format messages to avoid token inflation from metadata when str() is called on
        # message objects.
        formatted_messages = get_buffer_string(trimmed_messages)
        return self.summary_prompt.format(messages=formatted_messages).rstrip()

    def before_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        result = self._maybe_summarize(state, runtime)
        return result if result is not None else self._pacgate_hint_result(state)

    async def abefore_model(self, state: AgentState, runtime: Runtime) -> dict | None:
        result = await self._amaybe_summarize(state, runtime)
        return result if result is not None else self._pacgate_hint_result(state)

    def _pacgate_hint_result(self, state: AgentState) -> dict | None:
        """Attach the pressure hint ONLY when a summarization pass did not run.

        When a pass DID run, the history is replaced by summary+index and the
        pressure has just been relieved - appending a "fold due soon" line to the
        same turn would contradict what just happened. So the hint is an else
        branch, not an addition.
        """
        try:
            hint = self._pacgate_context_hint(state["messages"])
        except Exception:  # a diagnostic must never break a run
            return None
        if not hint:
            return None
        return {"messages": [HumanMessage(content=hint, name=_PACGATE_HINT_NAME)]}

    def _maybe_summarize(self, state: AgentState, runtime: Runtime) -> dict | None:
        messages = state["messages"]
        self._ensure_message_ids(messages)

        total_tokens = self.token_counter(messages)
        if not self._should_summarize(messages, total_tokens):
            return None

        cutoff_index = self._determine_cutoff_index(messages)
        if cutoff_index <= 0:
            return None

        messages_to_summarize, preserved_messages = self._partition_with_skill_rescue(messages, cutoff_index)
        messages_to_summarize, preserved_messages = self._preserve_dynamic_context_reminders(messages_to_summarize, preserved_messages)
        self._fire_hooks(messages_to_summarize, preserved_messages, runtime)
        summary = self._create_summary(messages_to_summarize)
        pacgate_record_fold(self, messages_to_summarize, preserved_messages)
        new_messages = self._build_new_messages(summary, messages_to_summarize)

        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *new_messages,
                *preserved_messages,
            ]
        }

    async def _amaybe_summarize(self, state: AgentState, runtime: Runtime) -> dict | None:
        messages = state["messages"]
        self._ensure_message_ids(messages)

        total_tokens = self.token_counter(messages)
        if not self._should_summarize(messages, total_tokens):
            return None

        cutoff_index = self._determine_cutoff_index(messages)
        if cutoff_index <= 0:
            return None

        messages_to_summarize, preserved_messages = self._partition_with_skill_rescue(messages, cutoff_index)
        messages_to_summarize, preserved_messages = self._preserve_dynamic_context_reminders(messages_to_summarize, preserved_messages)
        self._fire_hooks(messages_to_summarize, preserved_messages, runtime)
        summary = await self._acreate_summary(messages_to_summarize)
        pacgate_record_fold(self, messages_to_summarize, preserved_messages)
        new_messages = self._build_new_messages(summary, messages_to_summarize)

        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *new_messages,
                *preserved_messages,
            ]
        }

    @override
    def _build_new_messages(
        self, summary: str, messages_to_summarize: list[AnyMessage] | None = None
    ) -> list[HumanMessage]:
        """Override the base implementation to let the human message with the special name 'summary'.
        And this message will be ignored to display in the frontend, but still can be used as context for the model.

        Pacgate patch (2026-11-08): keep the folded range RECOVERABLE.

        The base class this inherits from returns ONE HumanMessage and the caller
        replaces history with `[RemoveMessage(REMOVE_ALL_MESSAGES), *these,
        *preserved]`. The folded range is therefore GONE, not hidden, and the
        prose summary is lossy - on a 65-page document the model loses the only
        record of which files it already read and which sections it already
        passed. That is the measured shape of the re-read loops this repo
        documents (103 / 42 / 52 re-touches of the same file on thread
        b315a961, 3.2-3.5M tokens each, all killed with nothing delivered).

        WHY THIS FILE AND NOT THE LANGCHAIN BASE CLASS. The first version of this
        patch edited
        langchain/agents/middleware/summarization.py::_build_new_messages and was
        INERT: deer-flow overrides that method here, so the runtime never called
        the patched base implementation. Verified 2026-11-08 with
        `inspect.getsource(DeerFlowSummarizationMiddleware._build_new_messages)`
        resolving to THIS class. A patch that is mounted and imported but never
        executed looks exactly like a working one from the outside - which is why
        the gate now asserts the runtime class, not the base class.

        The second argument is optional ON PURPOSE: an upstream deer-flow change
        that reverts to the one-argument call must degrade to "no index", never to
        a TypeError during summarization.
        """
        index = _pacgate_folded_index(messages_to_summarize)
        return [
            HumanMessage(
                content=f"Here is a summary of the conversation to date:\n\n{summary}{index}",
                name="summary",
            )
        ]

    def _pacgate_context_hint(self, messages: list[AnyMessage]) -> str | None:
        """One-line context-pressure hint, or None when the band is not entered.

        WHY A HINT AND NOT A TOOL. Measured 2026-11-08 with this middleware's own
        token_counter: one tool schema costs 159 tokens and is paid on EVERY
        call - 159 x 136 = 21,624 tokens across a deep run. The budget this
        feature exists to protect is `trigger - floor` = 36,000 - 14,728 =
        ~21,300 tokens. A schema would therefore spend the entire protected
        budget to report on it. The band-gated hint below costs 27 tokens, and
        only on the calls that have already crossed the band.

        It also fixes the actual failure. Models do not spontaneously query their
        own pressure; the failure mode is the model not KNOWING, not being unable
        to ask.
        """
        try:
            total = self.token_counter(messages)
            trigger = _pacgate_resolve_trigger_tokens(self)
            try:
                window = self._get_profile_limits()
            except Exception:
                window = None
        except Exception:  # never let a hint break a run
            return None

        # THE BINDING LIMIT IS min(trigger, window), NOT the trigger alone.
        #
        # MEASURED 2026-11-08: nothing in deer-flow-config.yaml declares
        # `profile={"max_input_tokens": N}`, so `window` is None today and the
        # trigger is the only reference. But keying ONLY on the trigger is wrong
        # by construction: on a model whose window is SMALLER than the trigger,
        # the band would never fire before the window itself overflows - the
        # diagnostic would be silent in exactly the case it exists for. Honouring
        # the window when one is declared makes the hint correct the moment a
        # model profile is added, with no further change here.
        limit = trigger
        if window:
            limit = min(trigger, window) if trigger else window
        if not limit or total < limit * _PACGATE_HINT_BAND:
            return None
        pct = int(total / limit * 100)
        return (
            f"<context-pressure>{pct}% of the fold budget used "
            f"({total:,}/{limit:,} tokens). A compression pass is due soon - "
            "finish the current file or section before starting another.</context-pressure>"
        )


    def _preserve_dynamic_context_reminders(
        self,
        messages_to_summarize: list[AnyMessage],
        preserved_messages: list[AnyMessage],
    ) -> tuple[list[AnyMessage], list[AnyMessage]]:
        """Keep hidden dynamic-context reminders out of summary compression.

        These reminders carry the current date and optional memory. If summarization
        removes them, DynamicContextMiddleware can mistake the summary HumanMessage
        for the first user message and inject the reminder in the wrong place.
        """
        reminders = [msg for msg in messages_to_summarize if is_dynamic_context_reminder(msg)]
        if not reminders:
            return messages_to_summarize, preserved_messages

        remaining = [msg for msg in messages_to_summarize if not is_dynamic_context_reminder(msg)]
        return remaining, reminders + preserved_messages

    def _partition_with_skill_rescue(
        self,
        messages: list[AnyMessage],
        cutoff_index: int,
    ) -> tuple[list[AnyMessage], list[AnyMessage]]:
        """Partition like the parent, then rescue recently-loaded skill bundles."""
        to_summarize, preserved = self._partition_messages(messages, cutoff_index)

        if self._preserve_recent_skill_count == 0 or self._preserve_recent_skill_tokens == 0 or not to_summarize:
            return to_summarize, preserved

        try:
            bundles = self._find_skill_bundles(to_summarize, self._skills_container_path)
        except Exception:
            logger.exception("Skill-preserving summarization rescue failed; falling back to default partition")
            return to_summarize, preserved

        if not bundles:
            return to_summarize, preserved

        rescue_bundles = self._select_bundles_to_rescue(bundles)
        if not rescue_bundles:
            return to_summarize, preserved

        bundles_by_ai_index = {bundle.ai_index: bundle for bundle in rescue_bundles}
        rescue_tool_indices = {idx for bundle in rescue_bundles for idx in bundle.skill_tool_indices}
        rescued: list[AnyMessage] = []
        remaining: list[AnyMessage] = []
        for i, msg in enumerate(to_summarize):
            bundle = bundles_by_ai_index.get(i)
            if bundle is not None and isinstance(msg, AIMessage):
                rescued_tool_calls = [tc for tc in msg.tool_calls if tc.get("id") in bundle.skill_tool_call_ids]
                remaining_tool_calls = [tc for tc in msg.tool_calls if tc.get("id") not in bundle.skill_tool_call_ids]

                if rescued_tool_calls:
                    rescued.append(_clone_ai_message(msg, rescued_tool_calls, content=""))
                if remaining_tool_calls or msg.content:
                    remaining.append(_clone_ai_message(msg, remaining_tool_calls))
                continue

            if i in rescue_tool_indices:
                rescued.append(msg)
                continue

            remaining.append(msg)

        return remaining, rescued + preserved

    def _find_skill_bundles(
        self,
        messages: list[AnyMessage],
        skills_root: str,
    ) -> list[_SkillBundle]:
        """Locate AIMessage + paired ToolMessage groups that load skill files."""
        bundles: list[_SkillBundle] = []
        n = len(messages)
        i = 0
        while i < n:
            msg = messages[i]
            if not (isinstance(msg, AIMessage) and msg.tool_calls):
                i += 1
                continue

            tool_calls = list(msg.tool_calls)
            skill_paths_by_id: dict[str, str] = {}
            for tc in tool_calls:
                if self._is_skill_tool_call(tc, skills_root):
                    tc_id = tc.get("id")
                    path = _tool_call_path(tc)
                    if tc_id and path:
                        skill_paths_by_id[tc_id] = path

            if not skill_paths_by_id:
                i += 1
                continue

            skill_tool_tokens = 0
            skill_key_parts: list[str] = []
            skill_tool_indices: list[int] = []
            matched_skill_call_ids: set[str] = set()

            j = i + 1
            while j < n and isinstance(messages[j], ToolMessage):
                j += 1

            for k in range(i + 1, j):
                tool_msg = messages[k]
                if isinstance(tool_msg, ToolMessage) and tool_msg.tool_call_id in skill_paths_by_id:
                    skill_tool_tokens += self.token_counter([tool_msg])
                    skill_key_parts.append(skill_paths_by_id[tool_msg.tool_call_id])
                    skill_tool_indices.append(k)
                    matched_skill_call_ids.add(tool_msg.tool_call_id)

            if not skill_tool_indices:
                i = j
                continue

            bundles.append(
                _SkillBundle(
                    ai_index=i,
                    skill_tool_indices=tuple(skill_tool_indices),
                    skill_tool_call_ids=frozenset(matched_skill_call_ids),
                    skill_tool_tokens=skill_tool_tokens,
                    skill_key="|".join(sorted(skill_key_parts)),
                )
            )
            i = j

        return bundles

    def _select_bundles_to_rescue(self, bundles: list[_SkillBundle]) -> list[_SkillBundle]:
        """Pick bundles to keep, walking newest-first under count/token budgets."""
        selected: list[_SkillBundle] = []
        if not bundles:
            return selected

        seen_skill_keys: set[str] = set()
        total_tokens = 0
        kept = 0

        for bundle in reversed(bundles):
            if kept >= self._preserve_recent_skill_count:
                break
            if bundle.skill_key in seen_skill_keys:
                continue
            if bundle.skill_tool_tokens > self._preserve_recent_skill_tokens_per_skill:
                continue
            if total_tokens + bundle.skill_tool_tokens > self._preserve_recent_skill_tokens:
                continue

            selected.append(bundle)
            total_tokens += bundle.skill_tool_tokens
            kept += 1
            seen_skill_keys.add(bundle.skill_key)

        selected.reverse()
        return selected

    def _is_skill_tool_call(self, tool_call: dict[str, Any], skills_root: str) -> bool:
        """Return True when ``tool_call`` reads a file under the configured skills root."""
        name = tool_call.get("name") or ""
        if name not in self._skill_file_read_tool_names:
            return False
        path = _tool_call_path(tool_call)
        if not path:
            return False
        normalized_root = skills_root.rstrip("/")
        return path == normalized_root or path.startswith(normalized_root + "/")

    def _fire_hooks(
        self,
        messages_to_summarize: list[AnyMessage],
        preserved_messages: list[AnyMessage],
        runtime: Runtime,
    ) -> None:
        if not self._before_summarization_hooks:
            return

        event = SummarizationEvent(
            messages_to_summarize=tuple(messages_to_summarize),
            preserved_messages=tuple(preserved_messages),
            thread_id=_resolve_thread_id(runtime),
            agent_name=_resolve_agent_name(runtime),
            runtime=runtime,
        )

        for hook in self._before_summarization_hooks:
            try:
                hook(event)
            except Exception:
                hook_name = getattr(hook, "__name__", None) or type(hook).__name__
                logger.exception("before_summarization hook %s failed", hook_name)

# ---------------------------------------------------------------------------
# Pacgate patch (2026-11-08): folded-range index + context-pressure hint.
#
# These live in THIS file because the patch is a full-file mount replacement, so
# the helpers must travel with the module they patch. One file to audit.
# ---------------------------------------------------------------------------

# Bounds. The index must cost far less than the range it describes, or it
# re-introduces the pressure it exists to relieve. A pass at trigger=36000 /
# keep=6000 leaves ~25k of headroom; measured 1.7% overhead on a realistic fold.
_PACGATE_MAX_TOOL_NAMES = 20
_PACGATE_MAX_PATHS = 24
_PACGATE_MAX_HEADINGS = 20
_PACGATE_MAX_PATH_CHARS = 200

# Pressure hint band: report once the fold budget is this far consumed. 0.85
# leaves ~15% of the budget for the model to finish the line of work it is on.
#
# CALIBRATED AGAINST REAL HISTORY, 2026-11-08 (scripts/calibrate_context_band.py,
# 15 busiest threads, deepest checkpoint each, decoded from the LangGraph
# checkpoint DB):
#
#     peak tokens: min=8,669  median=16,847  max=24,910
#     peak vs the 36,000 trigger: median 46.8%   max 69.2%
#     threads at or over the trigger: 0 of 15
#     band 0.85 would fire on: 0 of 15
#
# So on THIS workload the hint never fires and no fold occurs - and both are
# correct, because there is no pressure. Retouch ratio across those threads was
# median 1.0, max 1.24: the re-read loops this patch exists for are not present
# either. The mechanism is insurance for long document runs, not a fix for
# current traffic.
#
# The band is left at 0.85 deliberately. Lowering it to fire on a 17k thread
# would report pressure the trigger does not consider pressure, and would then
# claim a behavioural win that is really just a lower alarm. Re-calibrate from
# accumulated fold rows once a long document workflow runs on this stack.
_PACGATE_HINT_BAND = 0.85
_PACGATE_HINT_NAME = "pacgate_context_hint"

# Tools whose output CANNOT be re-derived by calling them again. Everything
# else (read_file, ls, glob, grep, bash, pacgate_list_*, the document readers)
# is reproducible from disk, so a pointer is sufficient recovery for those.
#
# MEASURED 2026-11-08: a web scrape reply is ~4,208 tokens. So for these three
# tools the pointer alone is NOT recovery - the page may have changed or stopped
# being reachable - and an excerpt is the honest minimum.
_PACGATE_NON_REPRODUCIBLE = (
    "pacgate_web_scrape",
    "pacgate_web_search",
    "pacgate_connector_search",
)
_PACGATE_EXCERPT_CHARS = 600
_PACGATE_MAX_EXCERPTS = 4

# POSIX file with an extension | URL | Windows path.
_PACGATE_PATH_RE = re.compile(
    r"(?:/[\w.\-]+){2,}\.[A-Za-z0-9]{1,8}"
    r"|https?://[^\s\"')>\]]+"
    r"|[A-Za-z]:\\[^\s\"'<>|]+"
)
# Markdown headings - what pymupdf4llm emits for PDF structure. This is the
# handle a long-document navigation loop needs: 0.2.32 made headings reachable
# (outline=51 on the CJK PDF); this keeps them in view once folded.
_PACGATE_HEADING_RE = re.compile(r"^#{1,3}\s+(.{1,120})$", re.MULTILINE)


def _pacgate_dedupe(items: list[str]) -> list[str]:
    """Order-preserving, case-insensitive dedupe."""
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        key = item.lower()
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


def _pacgate_text_of(message: Any) -> str:
    """Best-effort text of a message without importing its class."""
    content = getattr(message, "content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                text = block.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


def _pacgate_excerpt(text: str) -> str:
    """One-line, whitespace-collapsed excerpt - bounded and greppable."""
    flat = " ".join(text.split())
    if len(flat) <= _PACGATE_EXCERPT_CHARS:
        return flat
    return flat[:_PACGATE_EXCERPT_CHARS].rstrip() + " [...]"


def _pacgate_folded_index(messages: list[Any] | None) -> str:
    """Compact verbatim index of the range about to be folded.

    Returns '' when there is nothing worth indexing, so a trivial range adds
    nothing to the prompt.

    Recovers POINTERS for reproducible tools and a bounded EXCERPT for the three
    tools whose output cannot be re-derived. It stores NO message bodies: a
    persistent archive of folded matter conversation would be a second unscoped
    copy of privileged content, which is the property this repo refuses
    elsewhere (OpenViking is tenant/matter scoped; the ethical wall is proven
    with PEER_NOT_ALLOWED; session capture stays on PacgateMemoryStore ->
    pacgate-api). Disk holds the reproducible artifacts, so a pointer is enough
    for those - and the excerpt covers the part disk does not hold.
    """
    if not messages:
        return ""

    tool_names: list[str] = []
    paths: list[str] = []
    headings: list[str] = []
    excerpts: list[str] = []

    for message in messages:
        # Tool names come from the assistant turn that REQUESTED the call, so
        # "read_file was called" is recorded even when the reply was an error.
        for call in getattr(message, "tool_calls", None) or []:
            name = call.get("name") if isinstance(call, dict) else getattr(call, "name", None)
            if name:
                tool_names.append(str(name))
            args = call.get("args") if isinstance(call, dict) else getattr(call, "args", None)
            if isinstance(args, dict):
                for value in args.values():
                    if isinstance(value, str):
                        paths.extend(m.group(0) for m in _PACGATE_PATH_RE.finditer(value))

        text = _pacgate_text_of(message)

        # A tool REPLY carries the tool name on the message itself. This is the
        # only place an excerpt can be captured: the assistant turn holds the
        # arguments, the reply holds the content.
        name = getattr(message, "name", None)
        is_reply = bool(getattr(message, "tool_call_id", None))
        if name and is_reply:
            tool_names.append(str(name))
            if name in _PACGATE_NON_REPRODUCIBLE and text.strip():
                if len(excerpts) < _PACGATE_MAX_EXCERPTS:
                    excerpts.append(f"{name}: {_pacgate_excerpt(text)}")

        if text:
            paths.extend(m.group(0) for m in _PACGATE_PATH_RE.finditer(text))
            headings.extend(m.group(1).strip() for m in _PACGATE_HEADING_RE.finditer(text))

    tool_names = _pacgate_dedupe(tool_names)[:_PACGATE_MAX_TOOL_NAMES]
    paths = [p[:_PACGATE_MAX_PATH_CHARS] for p in _pacgate_dedupe(paths)][:_PACGATE_MAX_PATHS]
    headings = _pacgate_dedupe(headings)[:_PACGATE_MAX_HEADINGS]

    if not (tool_names or paths or headings or excerpts):
        return ""

    lines = ["", "Folded range - recoverable handles (verbatim, not paraphrased):"]
    if tool_names:
        lines.append(f"  tools called: {', '.join(tool_names)}")
    if excerpts:
        # Only the non-reproducible tools get content carried forward.
        lines.append("  content that CANNOT be re-fetched (excerpt):")
        lines.extend(f"    - {e}" for e in excerpts)
    if paths:
        lines.append("  paths/urls touched:")
        lines.extend(f"    - {p}" for p in paths)
    if headings:
        lines.append("  section headings seen:")
        lines.extend(f"    - {h}" for h in headings)
    lines.append(
        "  Re-read a path to recover its text rather than reconstructing it from "
        "the summary. Excerpts above are all that survives for live web/federated "
        "results."
    )
    return "\n".join(lines)


def _pacgate_resolve_trigger_tokens(middleware: Any) -> int:
    """Token-type trigger off a live middleware, without guessing.

    MEASURED 2026-11-08: the shape at RUNTIME is a tuple, not the YAML dict.
    deer-flow-config.yaml writes `- type: tokens / value: 36000`, but
    SummarizationMiddleware.__init__ validates and stores
    `ContextTokens = tuple[Literal["tokens"], int]`, i.e. ("tokens", 36000), or a
    list of those. A resolver written against the YAML shape returns 0 against
    the live object and reports "no pressure" on a run about to summarize - a
    silent zero in the one number this feature exists to report.

    Returns 0 ONLY when the shape is genuinely unrecognised; callers must read
    that as "cannot report", never as "no pressure".
    """
    trigger = getattr(middleware, "trigger", None)

    def from_one(item: Any) -> int | None:
        if isinstance(item, (tuple, list)) and len(item) == 2:
            kind, value = item
            if kind == "tokens" and isinstance(value, int):
                return value
        if isinstance(item, dict):
            if item.get("type") == "tokens" and isinstance(item.get("value"), int):
                return item["value"]
        return None

    if isinstance(trigger, int):
        return trigger
    if isinstance(trigger, (tuple, list)):
        # A single ("tokens", 36000) must not be mistaken for two unknown items.
        direct = from_one(trigger)
        if direct is not None:
            return direct
        for item in trigger:
            found = from_one(item)
            if found is not None:
                return found
    if isinstance(trigger, dict):
        found = from_one(trigger)
        if found is not None:
            return found
    return 0


def pacgate_context_status(middleware: Any, messages: list[Any]) -> dict[str, Any]:
    """Context-pressure snapshot, for the OPERATOR surface (API/UI).

    Reads the SAME token_counter and trigger the summarizer uses, so the number
    reported is the number that decides whether a pass fires - not a separate
    estimate that can drift from it. Costs zero prompt tokens because it is
    called by the application layer, not by the model.
    """
    counted = middleware.token_counter(messages)
    trigger = _pacgate_resolve_trigger_tokens(middleware)
    used = int(counted)
    return {
        "used_tokens": used,
        "trigger_tokens": trigger,
        "used_pct_of_trigger": round((used / trigger * 100.0), 1) if trigger else 0.0,
        "headroom_tokens": max(0, trigger - used),
        "should_summarize": bool(middleware._should_summarize(messages, counted)),
        "messages": len(messages),
        "note": (
            "trigger_tokens is the summarization threshold, not the model window. "
            "System prompt and tool schemas are part of used_tokens and cannot be "
            "compressed."
        ),
    }

# ---------------------------------------------------------------------------
# Pacgate patch (2026-11-08): FOLD TELEMETRY - the sensor the hint cannot be
# judged without.
#
# WHY THIS EXISTS. The context-pressure hint is advisory text, so the obvious
# question is "did it change behaviour?". MEASURED 2026-11-08: that question had
# NO SENSOR. `runs.total_input_tokens` is CUMULATIVE (2,243,116 over 107 calls on
# run 78f2a3c9, i.e. ~21k per call but not recorded per call), and
# `token_usage_by_model` is also an aggregate with `middleware_tokens: 0`. So
# neither "how full was the window at the moment of a fold" nor "did the model
# re-read fewer files" was answerable from any table in the system.
#
# One row per summarization pass makes both answerable:
#
#   folded_msgs / preserved_msgs  -> how much history a pass actually removed
#   tokens_at_fold                -> the real pressure that triggered it
#   trigger_tokens                -> what the config said it should be
#   window_tokens                 -> the model window IF the model declares
#                                    `profile={"max_input_tokens": N}`; None when
#                                    it does not (measured: nothing in
#                                    deer-flow-config.yaml declares one, so this
#                                    is None today - which is itself the finding
#                                    that the hint can only key on the trigger)
#   hint_band / hint_would_fire   -> whether the advisory hint had fired by then
#   tool_names / distinct_payloads-> the re-read ratio, computed at fold time
#
# WHERE THE STORY GOES. A JSONL file under the existing /data bind mount, so it
# survives a container recreate and needs no schema migration. Deliberately NOT
# a table: this is diagnostic history, not state the app must query, and adding
# a migration for telemetry would couple it to the DB version.
#
# WHAT IT NEVER WRITES. Message CONTENT. Counts, token numbers and tool NAMES
# only. A telemetry file under a bind mount that captured folded matter text
# would be exactly the second unscoped store this patch refuses elsewhere.
# ---------------------------------------------------------------------------

_PACGATE_FOLD_LOG_ENV = "PACGATE_FOLD_LOG"
_PACGATE_FOLD_LOG_DEFAULT = "/data/deer-flow/data/pacgate-fold-telemetry.jsonl"
_PACGATE_FOLD_LOG_LOCK = threading.Lock()


def _pacgate_fold_log_path() -> str:
    return os.environ.get(_PACGATE_FOLD_LOG_ENV, _PACGATE_FOLD_LOG_DEFAULT)


def _pacgate_tool_fingerprints(messages: list[Any]) -> tuple[list[str], int]:
    """Tool names used, and how many DISTINCT (tool, args) calls were made.

    The distinct count is the re-read signal: 103 re-touches of one file is 1
    distinct payload, so `calls / distinct` (the re-touch ratio) separates
    productive work from a navigation loop. Measured baseline in this repo: the
    killed run on bcb69ff8 made 111 model calls across 15 distinct payloads
    (ratio 7.4), while healthy runs sit near the same structural ratio - so the
    number has to be read per run, not against a fixed threshold.
    """
    names: list[str] = []
    seen: set[str] = set()
    for message in messages:
        for call in getattr(message, "tool_calls", None) or []:
            name = call.get("name") if isinstance(call, dict) else getattr(call, "name", None)
            args = call.get("args") if isinstance(call, dict) else getattr(call, "args", None)
            if not name:
                continue
            names.append(str(name))
            try:
                fingerprint = f"{name}|{json.dumps(args, sort_keys=True, default=str)}"
            except Exception:
                fingerprint = f"{name}|<?>"
            seen.add(fingerprint)
    return names, len(seen)


def pacgate_record_fold(middleware: Any, messages_to_summarize: list[Any],
                        preserved_messages: list[Any]) -> dict[str, Any] | None:
    """Append one JSONL row describing a summarization pass. Never raises.

    Never raises on purpose: telemetry that can break a summarization pass turns
    a diagnostic into an outage. Every failure path returns None.
    """
    try:
        used = int(middleware.token_counter(list(messages_to_summarize) + list(preserved_messages)))
        trigger = _pacgate_resolve_trigger_tokens(middleware)
        try:
            window = middleware._get_profile_limits()
        except Exception:
            window = None
        names, distinct = _pacgate_tool_fingerprints(list(messages_to_summarize))

        # THE FOLD IS DECIDED ON TWO DIFFERENT NUMBERS, so recording only the
        # counter MISREPORTS the cause. Measured 2026-11-08 on the first real fold
        # this stack ever produced (thread 0207ce2f): the row said
        # tokens_at_fold=26,935 against a 36,000 trigger - apparently firing 9,065
        # tokens early. It was not. `_should_summarize` fires on EITHER
        #   (a) this counter, OR
        #   (b) `_should_summarize_based_on_reported_tokens`: the provider-reported
        #       `usage_metadata.total_tokens` of the last AIMessage, which includes
        #       the unremovable floor (measured 3,220 system prompt + 11,508 tool
        #       schemas = 14,728).
        # That split is the same one DEFECT-summarization-treadmill.md documents.
        #
        # SCOPE MATTERS, and the first version of this line got it wrong. The
        # decision reads the last AIMessage of the FULL message list, not of the
        # folded subset - so reading only `messages_to_summarize` reported 28,155 on
        # a fold that fired on a newer, larger figure. Both lists are concatenated
        # here because folded + preserved is the original order.
        reported = None
        try:
            whole = list(messages_to_summarize) + list(preserved_messages)
            for message in reversed(whole):
                usage = getattr(message, "usage_metadata", None)
                if usage and usage.get("total_tokens"):
                    reported = int(usage["total_tokens"])
                    break
        except Exception:
            reported = None
        floor_estimate = (reported - used) if (reported is not None and reported > used) else None

        row = {
            "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "kind": "fold",
            "folded_msgs": len(messages_to_summarize),
            "preserved_msgs": len(preserved_messages),
            "tokens_at_fold": used,
            "reported_tokens_at_fold": reported,
            "floor_estimate": floor_estimate,
            "trigger_tokens": trigger,
            "window_tokens": window,
            "hint_band": _PACGATE_HINT_BAND,
            "hint_would_fire": bool(trigger and used >= trigger * _PACGATE_HINT_BAND),
            "tool_names": sorted(set(names)),
            "tool_calls": len(names),
            "distinct_payloads": distinct,
            "retouch_ratio": round(len(names) / distinct, 2) if distinct else None,
        }
        path = _pacgate_fold_log_path()
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with _PACGATE_FOLD_LOG_LOCK:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        return row
    except Exception:  # telemetry must never break a run
        return None
