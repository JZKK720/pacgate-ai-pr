"""PacGate patch (2026-10-08): prefix-aware skill allowed-tools matching.

Base: ghcr.io/jzkk720/deer-flow-pacgate:0.1.24 image version of
``packages/harness/deerflow/skills/tool_policy.py``.

Root cause fixed here: skills declare allowed-tools with bare MCP *server*
names (``pkulaw``, ``yuandian-law``, ``pacgate``), but loaded MCP tool names
are prefixed with the hyphen-normalized server name
(``pkulaw_case_keyword_get_case_list``, ``pacgate_pacgate_connector_search``).
Exact-match filtering dropped ALL 137 MCP tools once any skill declared
allowed-tools (verified live 2026-10-08; thread 44e28035 used only
bash/read_file). The filter now treats a declaration as covering every tool
whose name equals the declaration or starts with ``<declaration>_`` (hyphens
normalized to underscores), so ``qcc`` cannot swallow a hypothetical
``qccother`` server.
"""

import logging
from typing import Protocol

from deerflow.skills.types import Skill

logger = logging.getLogger(__name__)


class NamedTool(Protocol):
    name: str


def allowed_tool_names_for_skills(skills: list[Skill]) -> set[str] | None:
    """Return the union of explicit skill allowed-tools declarations.

    None means legacy allow-all behavior. It is returned only when no loaded
    skill declares allowed-tools. Once any skill declares the field, legacy
    skills without the field contribute no tools instead of disabling the
    explicit restrictions from other skills.
    """
    if not skills:
        return None

    allowed: set[str] = set()
    has_explicit_declaration = False
    for skill in skills:
        if skill.allowed_tools is None:
            continue
        has_explicit_declaration = True
        if not skill.allowed_tools:
            logger.info("Skill %s declared empty allowed-tools", skill.name)
        allowed.update(skill.allowed_tools)

    if not has_explicit_declaration:
        return None
    return allowed


def _tool_matches_declaration(tool_name: str, declaration: str) -> bool:
    """Whether a loaded tool name is covered by one allowed-tools declaration.

    Declarations may be exact tool names (``bash``) or bare MCP server names
    (``pkulaw``, ``yuandian-law``). MCP tool names are prefixed with the
    server name with hyphens normalized to underscores
    (``yuandian-law`` -> ``yuandian_law_<tool>``; the pacgate bridge server is
    itself named ``pacgate`` and its tools carry the ``pacgate_`` tool-name
    prefix, so ``pacgate`` -> ``pacgate_pacgate_<tool>``). Match exact, or the
    underscore-suffixed prefix of the normalized declaration.
    """
    if tool_name == declaration:
        return True
    normalized = declaration.replace("-", "_")
    return tool_name.startswith(f"{normalized}_")


def filter_tools_by_skill_allowed_tools[ToolT: NamedTool](tools: list[ToolT], skills: list[Skill]) -> list[ToolT]:
    allowed = allowed_tool_names_for_skills(skills)
    if allowed is None:
        return tools

    return [
        tool
        for tool in tools
        if any(_tool_matches_declaration(tool.name, declaration) for declaration in allowed)
    ]
