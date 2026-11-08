"""Summarization middleware."""

import uuid
import warnings
# Pacgate patch (2026-11-08): required by the folded-range index regexes.
import re
from collections.abc import Callable, Iterable, Mapping
from functools import partial
from typing import Any, Literal, cast

from langchain_core.messages import (
    AIMessage,
    AnyMessage,
    MessageLikeRepresentation,
    RemoveMessage,
    ToolMessage,
)
from langchain_core.messages.human import HumanMessage
from langchain_core.messages.utils import (
    count_tokens_approximately,
    get_buffer_string,
    trim_messages,
)
from langgraph.graph.message import (
    REMOVE_ALL_MESSAGES,
)
from langgraph.runtime import Runtime
from typing_extensions import override

from langchain.agents.middleware.types import AgentMiddleware, AgentState, ContextT, ResponseT
from langchain.chat_models import BaseChatModel, init_chat_model

TokenCounter = Callable[[Iterable[MessageLikeRepresentation]], int]

DEFAULT_SUMMARY_PROMPT = """<role>
Context Extraction Assistant
</role>

<primary_objective>
Your sole objective in this task is to extract the highest quality/most relevant context from the conversation history below.
</primary_objective>

<objective_information>
You're nearing the total number of input tokens you can accept, so you must extract the highest quality/most relevant pieces of information from your conversation history.
This context will then overwrite the conversation history presented below. Because of this, ensure the context you extract is only the most important information to continue working toward your overall goal.
</objective_information>

<instructions>
The conversation history below will be replaced with the context you extract in this step.
You want to ensure that you don't repeat any actions you've already completed, so the context you extract from the conversation history should be focused on the most important information to your overall goal.

You should structure your summary using the following sections. Each section acts as a checklist - you must populate it with relevant information or explicitly state "None" if there is nothing to report for that section:

## SESSION INTENT
What is the user's primary goal or request? What overall task are you trying to accomplish? This should be concise but complete enough to understand the purpose of the entire session.

## SUMMARY
Extract and record all of the most important context from the conversation history. Include important choices, conclusions, or strategies determined during this conversation. Include the reasoning behind key decisions. Document any rejected options and why they were not pursued.

## ARTIFACTS
What artifacts, files, or resources were created, modified, or accessed during this conversation? For file modifications, list specific file paths and briefly describe the changes made to each. This section prevents silent loss of artifact information.

## NEXT STEPS
What specific tasks remain to be completed to achieve the session intent? What should you do next?

</instructions>

The user will message you with the full message history from which you'll extract context to create a replacement. Carefully read through it all and think deeply about what information is most important to your overall goal and should be saved:

With all of this in mind, please carefully read over the entire conversation history, and extract the most important and relevant context to replace it so that you can free up space in the conversation history.
Respond ONLY with the extracted context. Do not include any additional information, or text before or after the extracted context.

<messages>
Messages to summarize:
{messages}
</messages>"""  # noqa: E501

_DEFAULT_MESSAGES_TO_KEEP = 20
_DEFAULT_TRIM_TOKEN_LIMIT = 4000
_DEFAULT_FALLBACK_MESSAGE_COUNT = 15

ContextFraction = tuple[Literal["fraction"], float]
"""Fraction of model's maximum input tokens.

Example:
    To specify 50% of the model's max input tokens:

    ```python
    ("fraction", 0.5)
    ```
"""

ContextTokens = tuple[Literal["tokens"], int]
"""Absolute number of tokens.

Example:
    To specify 3000 tokens:

    ```python
    ("tokens", 3000)
    ```
"""

ContextMessages = tuple[Literal["messages"], int]
"""Absolute number of messages.

Example:
    To specify 50 messages:

    ```python
    ("messages", 50)
    ```
"""

ContextSize = ContextFraction | ContextTokens | ContextMessages
"""Union type for context size specifications.

Can be either:

- [`ContextFraction`][langchain.agents.middleware.summarization.ContextFraction]: A
    fraction of the model's maximum input tokens.
- [`ContextTokens`][langchain.agents.middleware.summarization.ContextTokens]: An absolute
    number of tokens.
- [`ContextMessages`][langchain.agents.middleware.summarization.ContextMessages]: An
    absolute number of messages.

Depending on use with `trigger` or `keep` parameters, this type indicates either
when to trigger summarization or how much context to retain.

Example:
    ```python
    # ContextFraction
    context_size: ContextSize = ("fraction", 0.5)

    # ContextTokens
    context_size: ContextSize = ("tokens", 3000)

    # ContextMessages
    context_size: ContextSize = ("messages", 50)
    ```
"""


def _get_approximate_token_counter(model: BaseChatModel) -> TokenCounter:
    """Tune parameters of approximate token counter based on model type."""
    if model._llm_type.startswith("anthropic-chat"):  # noqa: SLF001
        # 3.3 was estimated in an offline experiment, comparing with Claude's token-counting
        # API: https://platform.claude.com/docs/en/build-with-claude/token-counting
        return partial(
            count_tokens_approximately, use_usage_metadata_scaling=True, chars_per_token=3.3
        )
    return partial(count_tokens_approximately, use_usage_metadata_scaling=True)


class SummarizationMiddleware(AgentMiddleware[AgentState[ResponseT], ContextT, ResponseT]):
    """Summarizes conversation history when token limits are approached.

    This middleware monitors message token counts and automatically summarizes older
    messages when a threshold is reached, preserving recent messages and maintaining
    context continuity by ensuring AI/Tool message pairs remain together.
    """

    def __init__(
        self,
        model: str | BaseChatModel,
        *,
        trigger: ContextSize | list[ContextSize] | None = None,
        keep: ContextSize = ("messages", _DEFAULT_MESSAGES_TO_KEEP),
        token_counter: TokenCounter = count_tokens_approximately,
        summary_prompt: str = DEFAULT_SUMMARY_PROMPT,
        trim_tokens_to_summarize: int | None = _DEFAULT_TRIM_TOKEN_LIMIT,
        **deprecated_kwargs: Any,
    ) -> None:
        """Initialize summarization middleware.

        Args:
            model: The language model to use for generating summaries.
            trigger: One or more thresholds that trigger summarization.

                Provide a single
                [`ContextSize`][langchain.agents.middleware.summarization.ContextSize]
                tuple or a list of tuples, in which case summarization runs when any
                threshold is met.

                !!! example

                    ```python
                    # Trigger summarization when 50 messages is reached
                    ("messages", 50)

                    # Trigger summarization when 3000 tokens is reached
                    ("tokens", 3000)

                    # Trigger summarization either when 80% of model's max input tokens
                    # is reached or when 100 messages is reached (whichever comes first)
                    [("fraction", 0.8), ("messages", 100)]
                    ```

                    See [`ContextSize`][langchain.agents.middleware.summarization.ContextSize]
                    for more details.
            keep: Context retention policy applied after summarization.

                Provide a [`ContextSize`][langchain.agents.middleware.summarization.ContextSize]
                tuple to specify how much history to preserve.

                Defaults to keeping the most recent `20` messages.

                Does not support multiple values like `trigger`.

                !!! example

                    ```python
                    # Keep the most recent 20 messages
                    ("messages", 20)

                    # Keep the most recent 3000 tokens
                    ("tokens", 3000)

                    # Keep the most recent 30% of the model's max input tokens
                    ("fraction", 0.3)
                    ```
            token_counter: Function to count tokens in messages.
            summary_prompt: Prompt template for generating summaries.
            trim_tokens_to_summarize: Maximum tokens to keep when preparing messages for
                the summarization call.

                Pass `None` to skip trimming entirely.
        """
        # Handle deprecated parameters
        if "max_tokens_before_summary" in deprecated_kwargs:
            value = deprecated_kwargs["max_tokens_before_summary"]
            warnings.warn(
                "max_tokens_before_summary is deprecated. Use trigger=('tokens', value) instead.",
                DeprecationWarning,
                stacklevel=2,
            )
            if trigger is None and value is not None:
                trigger = ("tokens", value)

        if "messages_to_keep" in deprecated_kwargs:
            value = deprecated_kwargs["messages_to_keep"]
            warnings.warn(
                "messages_to_keep is deprecated. Use keep=('messages', value) instead.",
                DeprecationWarning,
                stacklevel=2,
            )
            if keep == ("messages", _DEFAULT_MESSAGES_TO_KEEP):
                keep = ("messages", value)

        super().__init__()

        if isinstance(model, str):
            model = init_chat_model(model)

        self.model = model
        if trigger is None:
            self.trigger: ContextSize | list[ContextSize] | None = None
            trigger_conditions: list[ContextSize] = []
        elif isinstance(trigger, list):
            validated_list = [self._validate_context_size(item, "trigger") for item in trigger]
            self.trigger = validated_list
            trigger_conditions = validated_list
        else:
            validated = self._validate_context_size(trigger, "trigger")
            self.trigger = validated
            trigger_conditions = [validated]
        self._trigger_conditions = trigger_conditions

        self.keep = self._validate_context_size(keep, "keep")
        if token_counter is count_tokens_approximately:
            self.token_counter = _get_approximate_token_counter(self.model)
            self._partial_token_counter: TokenCounter = partial(  # type: ignore[call-arg]
                self.token_counter, use_usage_metadata_scaling=False
            )
        else:
            self.token_counter = token_counter
            self._partial_token_counter = token_counter
        self.summary_prompt = summary_prompt
        self.trim_tokens_to_summarize = trim_tokens_to_summarize

        requires_profile = any(condition[0] == "fraction" for condition in self._trigger_conditions)
        if self.keep[0] == "fraction":
            requires_profile = True
        if requires_profile and self._get_profile_limits() is None:
            msg = (
                "Model profile information is required to use fractional token limits, "
                "and is unavailable for the specified model. Please use absolute token "
                "counts instead, or pass "
                '`\n\nChatModel(..., profile={"max_input_tokens": ...})`.\n\n'
                "with a desired integer value of the model's maximum input tokens."
            )
            raise ValueError(msg)

    @override
    def before_model(
        self, state: AgentState[Any], runtime: Runtime[ContextT]
    ) -> dict[str, Any] | None:
        """Process messages before model invocation, potentially triggering summarization.

        Args:
            state: The agent state.
            runtime: The runtime environment.

        Returns:
            An updated state with summarized messages if summarization was performed.
        """
        messages = state["messages"]
        self._ensure_message_ids(messages)

        total_tokens = self.token_counter(messages)
        if not self._should_summarize(messages, total_tokens):
            return None

        cutoff_index = self._determine_cutoff_index(messages)

        if cutoff_index <= 0:
            return None

        messages_to_summarize, preserved_messages = self._partition_messages(messages, cutoff_index)

        summary = self._create_summary(messages_to_summarize)
        new_messages = self._build_new_messages(summary, messages_to_summarize)

        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *new_messages,
                *preserved_messages,
            ]
        }

    @override
    async def abefore_model(
        self, state: AgentState[Any], runtime: Runtime[ContextT]
    ) -> dict[str, Any] | None:
        """Process messages before model invocation, potentially triggering summarization.

        Args:
            state: The agent state.
            runtime: The runtime environment.

        Returns:
            An updated state with summarized messages if summarization was performed.
        """
        messages = state["messages"]
        self._ensure_message_ids(messages)

        total_tokens = self.token_counter(messages)
        if not self._should_summarize(messages, total_tokens):
            return None

        cutoff_index = self._determine_cutoff_index(messages)

        if cutoff_index <= 0:
            return None

        messages_to_summarize, preserved_messages = self._partition_messages(messages, cutoff_index)

        summary = await self._acreate_summary(messages_to_summarize)
        new_messages = self._build_new_messages(summary, messages_to_summarize)

        return {
            "messages": [
                RemoveMessage(id=REMOVE_ALL_MESSAGES),
                *new_messages,
                *preserved_messages,
            ]
        }

    def _should_summarize_based_on_reported_tokens(
        self, messages: list[AnyMessage], threshold: float
    ) -> bool:
        """Check if reported token usage from last AIMessage exceeds threshold."""
        last_ai_message = next(
            (msg for msg in reversed(messages) if isinstance(msg, AIMessage)),
            None,
        )
        if (  # noqa: SIM103
            isinstance(last_ai_message, AIMessage)
            and last_ai_message.usage_metadata is not None
            and (reported_tokens := last_ai_message.usage_metadata.get("total_tokens", -1))
            and reported_tokens >= threshold
            and (message_provider := last_ai_message.response_metadata.get("model_provider"))
            and message_provider == self.model._get_ls_params().get("ls_provider")  # noqa: SLF001
        ):
            return True
        return False

    def _should_summarize(self, messages: list[AnyMessage], total_tokens: int) -> bool:
        """Determine whether summarization should run for the current token usage."""
        if not self._trigger_conditions:
            return False

        for kind, value in self._trigger_conditions:
            if kind == "messages" and len(messages) >= value:
                return True
            if kind == "tokens" and total_tokens >= value:
                return True
            if kind == "tokens" and self._should_summarize_based_on_reported_tokens(
                messages, value
            ):
                return True
            if kind == "fraction":
                max_input_tokens = self._get_profile_limits()
                if max_input_tokens is None:
                    continue
                threshold = int(max_input_tokens * value)
                if threshold <= 0:
                    threshold = 1
                if total_tokens >= threshold:
                    return True

                if self._should_summarize_based_on_reported_tokens(messages, threshold):
                    return True
        return False

    def _determine_cutoff_index(self, messages: list[AnyMessage]) -> int:
        """Choose cutoff index respecting retention configuration."""
        kind, value = self.keep
        if kind in {"tokens", "fraction"}:
            token_based_cutoff = self._find_token_based_cutoff(messages)
            if token_based_cutoff is not None:
                return token_based_cutoff
            # None cutoff -> model profile data not available (caught in __init__ but
            # here for safety), fallback to message count
            return self._find_safe_cutoff(messages, _DEFAULT_MESSAGES_TO_KEEP)
        return self._find_safe_cutoff(messages, cast("int", value))

    def _find_token_based_cutoff(self, messages: list[AnyMessage]) -> int | None:
        """Find cutoff index based on target token retention."""
        if not messages:
            return 0

        kind, value = self.keep
        if kind == "fraction":
            max_input_tokens = self._get_profile_limits()
            if max_input_tokens is None:
                return None
            target_token_count = int(max_input_tokens * value)
        elif kind == "tokens":
            target_token_count = int(value)
        else:
            return None

        if target_token_count <= 0:
            target_token_count = 1

        if self.token_counter(messages) <= target_token_count:
            return 0

        # Use binary search to identify the earliest message index that keeps the
        # suffix within the token budget.
        left, right = 0, len(messages)
        cutoff_candidate = len(messages)
        max_iterations = len(messages).bit_length() + 1
        for _ in range(max_iterations):
            if left >= right:
                break

            mid = (left + right) // 2
            if self._partial_token_counter(messages[mid:]) <= target_token_count:
                cutoff_candidate = mid
                right = mid
            else:
                left = mid + 1

        if cutoff_candidate == len(messages):
            cutoff_candidate = left

        if cutoff_candidate >= len(messages):
            if len(messages) == 1:
                return 0
            cutoff_candidate = len(messages) - 1

        # Advance past any ToolMessages to avoid splitting AI/Tool pairs
        return self._find_safe_cutoff_point(messages, cutoff_candidate)

    def _get_profile_limits(self) -> int | None:
        """Retrieve max input token limit from the model profile."""
        try:
            profile = self.model.profile
        except AttributeError:
            return None

        if not isinstance(profile, Mapping):
            return None

        max_input_tokens = profile.get("max_input_tokens")

        if not isinstance(max_input_tokens, int):
            return None

        return max_input_tokens

    @staticmethod
    def _validate_context_size(context: ContextSize, parameter_name: str) -> ContextSize:
        """Validate context configuration tuples."""
        kind, value = context
        if kind == "fraction":
            if not 0 < value <= 1:
                msg = f"Fractional {parameter_name} values must be between 0 and 1, got {value}."
                raise ValueError(msg)
        elif kind in {"tokens", "messages"}:
            if value <= 0:
                msg = f"{parameter_name} thresholds must be greater than 0, got {value}."
                raise ValueError(msg)
        else:
            msg = f"Unsupported context size type {kind} for {parameter_name}."
            raise ValueError(msg)
        return context

    @staticmethod
    def _build_new_messages(
        summary: str, messages_to_summarize: list[AnyMessage] | None = None
    ) -> list[HumanMessage]:
        # Pacgate patch (2026-11-08): keep the folded range RECOVERABLE.
        #
        # Stock returns one HumanMessage and nothing else, and the caller
        # replaces history with `[RemoveMessage(REMOVE_ALL_MESSAGES), *these,
        # *preserved]`. The folded range is therefore GONE, not hidden. The
        # prose summary is lossy, so on a 65-page document workflow the model
        # loses the only record of which files it already read and which
        # sections it already passed - the measured shape of the re-read loops
        # this repo documents (103 / 42 / 52 re-touches on thread b315a961).
        #
        # The second argument is optional ON PURPOSE. Stock is a @staticmethod
        # taking one argument; a LangChain upgrade that moves this method, or a
        # caller elsewhere in the tree, must not start raising TypeError during
        # summarization. A missing range means no index, never a failure.
        index = _pacgate_folded_index(messages_to_summarize)
        return [
            HumanMessage(
                content=f"Here is a summary of the conversation to date:\n\n{summary}{index}",
                additional_kwargs={"lc_source": "summarization"},
            )
        ]

    @staticmethod
    def _ensure_message_ids(messages: list[AnyMessage]) -> None:
        """Ensure all messages have unique IDs for the add_messages reducer."""
        for msg in messages:
            if msg.id is None:
                msg.id = str(uuid.uuid4())

    @staticmethod
    def _partition_messages(
        conversation_messages: list[AnyMessage],
        cutoff_index: int,
    ) -> tuple[list[AnyMessage], list[AnyMessage]]:
        """Partition messages into those to summarize and those to preserve."""
        messages_to_summarize = conversation_messages[:cutoff_index]
        preserved_messages = conversation_messages[cutoff_index:]

        return messages_to_summarize, preserved_messages

    def _find_safe_cutoff(self, messages: list[AnyMessage], messages_to_keep: int) -> int:
        """Find safe cutoff point that preserves AI/Tool message pairs.

        Returns the index where messages can be safely cut without separating
        related AI and Tool messages. Returns `0` if no safe cutoff is found.

        This is aggressive with summarization - if the target cutoff lands in the
        middle of tool messages, we advance past all of them (summarizing more).
        """
        if len(messages) <= messages_to_keep:
            return 0

        target_cutoff = len(messages) - messages_to_keep
        return self._find_safe_cutoff_point(messages, target_cutoff)

    @staticmethod
    def _find_safe_cutoff_point(messages: list[AnyMessage], cutoff_index: int) -> int:
        """Find a safe cutoff point that doesn't split AI/Tool message pairs.

        If the message at `cutoff_index` is a `ToolMessage`, search backward for the
        `AIMessage` containing the corresponding `tool_calls` and adjust the cutoff to
        include it. This ensures tool call requests and responses stay together.

        Falls back to advancing forward past `ToolMessage` objects only if no matching
        `AIMessage` is found (edge case).
        """
        if cutoff_index >= len(messages) or not isinstance(messages[cutoff_index], ToolMessage):
            return cutoff_index

        # Collect tool_call_ids from consecutive ToolMessages at/after cutoff
        tool_call_ids: set[str] = set()
        idx = cutoff_index
        while idx < len(messages) and isinstance(messages[idx], ToolMessage):
            tool_msg = cast("ToolMessage", messages[idx])
            if tool_msg.tool_call_id:
                tool_call_ids.add(tool_msg.tool_call_id)
            idx += 1

        # Search backward for AIMessage with matching tool_calls
        for i in range(cutoff_index - 1, -1, -1):
            msg = messages[i]
            if isinstance(msg, AIMessage) and msg.tool_calls:
                ai_tool_call_ids = {tc.get("id") for tc in msg.tool_calls if tc.get("id")}
                if tool_call_ids & ai_tool_call_ids:
                    # Found the AIMessage - move cutoff to include it
                    return i

        # Fallback: no matching AIMessage found, advance past ToolMessages to avoid
        # orphaned tool responses
        return idx

    def _create_summary(self, messages_to_summarize: list[AnyMessage]) -> str:
        """Generate summary for the given messages.

        Args:
            messages_to_summarize: Messages to summarize.
        """
        if not messages_to_summarize:
            return "No previous conversation history."

        trimmed_messages = self._trim_messages_for_summary(messages_to_summarize)
        if not trimmed_messages:
            return "Previous conversation was too long to summarize."

        # Format messages to avoid token inflation from metadata when str() is called on
        # message objects
        formatted_messages = get_buffer_string(trimmed_messages)

        try:
            response = self.model.invoke(
                self.summary_prompt.format(messages=formatted_messages).rstrip(),
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception as e:
            return f"Error generating summary: {e!s}"

    async def _acreate_summary(self, messages_to_summarize: list[AnyMessage]) -> str:
        """Generate summary for the given messages.

        Args:
            messages_to_summarize: Messages to summarize.
        """
        if not messages_to_summarize:
            return "No previous conversation history."

        trimmed_messages = self._trim_messages_for_summary(messages_to_summarize)
        if not trimmed_messages:
            return "Previous conversation was too long to summarize."

        # Format messages to avoid token inflation from metadata when str() is called on
        # message objects
        formatted_messages = get_buffer_string(trimmed_messages)

        try:
            response = await self.model.ainvoke(
                self.summary_prompt.format(messages=formatted_messages).rstrip(),
                config={"metadata": {"lc_source": "summarization"}},
            )
            return response.text.strip()
        except Exception as e:
            return f"Error generating summary: {e!s}"

    def _trim_messages_for_summary(self, messages: list[AnyMessage]) -> list[AnyMessage]:
        """Trim messages to fit within summary generation limits."""
        try:
            if self.trim_tokens_to_summarize is None:
                return messages
            return cast(
                "list[AnyMessage]",
                trim_messages(
                    messages,
                    max_tokens=self.trim_tokens_to_summarize,
                    token_counter=self.token_counter,
                    start_on="human",
                    strategy="last",
                    allow_partial=True,
                    include_system=True,
                ),
            )
        except Exception:
            return messages[-_DEFAULT_FALLBACK_MESSAGE_COUNT:]


# ---------------------------------------------------------------------------
# Pacgate patch (2026-11-08): folded-range index + context-pressure snapshot.
#
# WHY THESE LIVE IN THIS FILE. The patch is a full-file mount replacement, so
# the helpers must travel with the module it patches. Keeping them here means
# one file to audit and no import path to add to the image.
# ---------------------------------------------------------------------------

# Bounds: the index must cost far less than the range it describes, or it
# re-introduces the pressure it exists to relieve. A pass at trigger=36000 /
# keep=6000 leaves ~25k of headroom, so a few hundred tokens is noise.
_PACGATE_MAX_TOOL_NAMES = 20
_PACGATE_MAX_PATHS = 24
_PACGATE_MAX_HEADINGS = 20
_PACGATE_MAX_PATH_CHARS = 200

# POSIX file with an extension | URL | Windows path. Broad on separators
# because tool layers report all three on this stack.
_PACGATE_PATH_RE = re.compile(
    r"(?:/[\w.\-]+){2,}\.[A-Za-z0-9]{1,8}"
    r"|https?://[^\s\"')>\]]+"
    r"|[A-Za-z]:\\[^\s\"'<>|]+"
)

# Markdown headings - what pymupdf4llm emits for PDF structure. This is the
# handle a long-document navigation loop actually needs: the 0.2.32 fix made
# headings reachable (outline=51 on the CJK PDF); this keeps the model aware of
# which ones it has already passed once they fall into a folded range.
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


def _pacgate_folded_index(messages: list[Any] | None) -> str:
    """Compact verbatim index of the range about to be folded.

    Returns '' when there is nothing worth indexing, so a trivial range adds
    nothing to the prompt.

    Recovers POINTERS, not prose. It deliberately does not archive message
    bodies: a persistent store of folded matter conversation would be a second
    unscoped copy of privileged content, which is the property this repo
    refuses elsewhere (OpenViking is tenant/matter scoped; session capture stays
    on PacgateMemoryStore -> pacgate-api). Disk already holds the artifacts
    under /data/outputs, so the index is the cheap correct half of
    reversibility.
    """
    if not messages:
        return ""

    tool_names: list[str] = []
    paths: list[str] = []
    headings: list[str] = []

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

        # Tool replies carry the tool NAME on the message itself.
        name = getattr(message, "name", None)
        if name and getattr(message, "tool_call_id", None):
            tool_names.append(str(name))

        text = _pacgate_text_of(message)
        if text:
            paths.extend(m.group(0) for m in _PACGATE_PATH_RE.finditer(text))
            headings.extend(m.group(1).strip() for m in _PACGATE_HEADING_RE.finditer(text))

    tool_names = _pacgate_dedupe(tool_names)[:_PACGATE_MAX_TOOL_NAMES]
    paths = [p[:_PACGATE_MAX_PATH_CHARS] for p in _pacgate_dedupe(paths)][:_PACGATE_MAX_PATHS]
    headings = _pacgate_dedupe(headings)[:_PACGATE_MAX_HEADINGS]

    if not (tool_names or paths or headings):
        return ""

    lines = ["", "Folded range - recoverable handles (verbatim, not paraphrased):"]
    if tool_names:
        lines.append(f"  tools called: {', '.join(tool_names)}")
    if paths:
        lines.append("  paths/urls touched:")
        lines.extend(f"    - {p}" for p in paths)
    if headings:
        lines.append("  section headings seen:")
        lines.extend(f"    - {h}" for h in headings)
    lines.append(
        "  These are handles, not content. Re-read a path to recover its text "
        "rather than reconstructing it from the summary."
    )
    return "\n".join(lines)


def pacgate_resolve_trigger_tokens(middleware: Any) -> int:
    """Token-type trigger off a live middleware, without guessing.

    MEASURED 2026-11-08: the shape at runtime is a TUPLE, not a dict.
    `deer-flow-config.yaml` writes

        trigger:
          - type: tokens
            value: 36000

    but `SummarizationMiddleware.__init__` validates and stores it as
    `ContextTokens = tuple[Literal["tokens"], int]`, i.e. `("tokens", 36000)`,
    or a list of those. A resolver written against the YAML shape returns 0
    against the live object and reports "no pressure" on a run that is about to
    summarize - the exact silent-zero failure this helper exists to avoid.

    Handles: tuple/list of tuples (runtime), list/dict of {type, value} (YAML,
    in case a caller passes config straight through), and a bare int. Returns 0
    ONLY when the shape is genuinely unrecognised, which callers must treat as
    "cannot report" rather than "no pressure".
    """
    trigger = getattr(middleware, "trigger", None)

    def from_one(item: Any) -> int | None:
        # Runtime shape: ("tokens", 36000)
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

    # A single tuple reads as a 2-element sequence of scalars; a list-of-tuples
    # reads as a sequence of sequences. Distinguish before iterating, or a
    # single ("tokens", 36000) is mistaken for two unknown items.
    if isinstance(trigger, (tuple, list)):
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
    """Context-pressure snapshot from the live middleware.

    Reads the SAME token_counter and trigger the summarizer uses, so the number
    reported is the number that decides whether a pass fires - not a separate
    estimate that can drift from it.

    WHY THIS IS NOT A TOOL. Every registered tool adds its schema to every
    request. The unremovable per-call floor is already 14,728 tokens (3,220
    system prompt + 11,508 across 45 tool schemas), and
    DEFECT-summarization-treadmill.md is the record of what happens when a
    threshold sits below that floor. Adding tools purely for visibility would
    raise the floor to observe a threshold measured against it. The caller
    decides whether the value is worth a schema.

    Returns a plain dict so it survives JSON serialisation into a tool result or
    an API response without either side importing this module.
    """
    counted = middleware.token_counter(messages)
    trigger = pacgate_resolve_trigger_tokens(middleware)
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
