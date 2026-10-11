"""MCP client using langchain-mcp-adapters.

Pacgate patch 2026-10-11: raise the HTTP transport timeouts for remote MCP
servers instead of riding the MCP SDK defaults.

Root cause (measured live 2026-10-11, run 53720ae5): langchain-mcp-adapters
builds the httpx client with MCP defaults of connect/write/pool = 30s and
read = 300s (mcp.shared._httpx_utils: MCP_DEFAULT_TIMEOUT=30.0,
MCP_DEFAULT_SSE_READ_TIMEOUT=300.0). Two long-lane tool calls live far above
those numbers in normal operation:

  - pacgate_execute_workflow: measured 174s live (kb_search + find_in + docx
    generation chain) and can scale with matter size.
  - pacgate_sanitize_document / pacgate_sanitize_text: server-side budget is
    SANITIZE_TIMEOUT_S=700 (~655s observed).

On 2026-10-11 01:47:41 a workflow call that had COMPLETED server-side
(pacgate-api finished at 01:46:00) was still torn down client-side:
"Server disconnected without sending a response", killing an agent run that
had already done ~4 minutes of work. This patch replaces the SDK default
httpx.Timeout with one sized for the Pacgate tool lanes:
  - per-request read budget: 900s (covers the 700s sanitize ceiling plus
    transport headroom, and everything measured so far),
  - SSE-stream idle read: 300s (unchanged; only matters for streaming).

Note on scope: this is the connect/read budget for HTTP MCP servers this
gateway serves. The MCP spec timeouts (timedelta) still route through
langchain-mcp-adapters' deprecated streamablehttp_client, which converts
them to httpx.Timeout(total=timeout, read=sse_read_timeout) - so we set the
same shape via httpx_client_factory to avoid the deprecation path entirely.
"""

import logging
from datetime import timedelta
from typing import Any

import httpx

from deerflow.config.extensions_config import ExtensionsConfig, McpServerConfig

logger = logging.getLogger(__name__)

# Pacgate: read budget for a single MCP tool call over HTTP. Must exceed the
# largest server-side lane (sanitize 700s) with headroom, and stay below the
# compose/nginx 720s read chain so errors surface here deterministically.
PACGATE_MCP_TOOL_TIMEOUT_S = float(900)
# Idle budget for the GET/SSE stream (server-initiated messages). The SDK
# default of 300s is fine for our servers; kept explicit for clarity.
PACGATE_MCP_SSE_READ_TIMEOUT_S = float(300)


def _httpx_timeout_factory(**_kwargs: Any) -> httpx.AsyncClient:
    """Build the httpx.AsyncClient with Pacgate's MCP timeout shape.

    Mirrors mcp.shared._httpx_utils.create_mcp_http_client follow_redirects
    default; only the Timeout differs (total=900, read=300 per MCP shape
    httpx.Timeout(total, read=sse_read)).
    """
    timeout = httpx.Timeout(
        PACGATE_MCP_TOOL_TIMEOUT_S,
        read=PACGATE_MCP_TOOL_TIMEOUT_S,
    )
    return httpx.AsyncClient(follow_redirects=True, timeout=timeout)


def build_server_params(server_name: str, config: McpServerConfig) -> dict[str, Any]:
    """Build server parameters for MultiServerMCPClient.

    Args:
        server_name: Name of the MCP server.
        config: Configuration for the MCP server.

    Returns:
        Dictionary of server parameters for langchain-mcp-adapters.
    """
    transport_type = config.type or "stdio"
    params: dict[str, Any] = {"transport": transport_type}

    if transport_type == "stdio":
        if not config.command:
            raise ValueError(f"MCP server '{server_name}' with stdio transport requires 'command' field")
        params["command"] = config.command
        params["args"] = config.args
        # Add environment variables if present
        if config.env:
            params["env"] = config.env
    elif transport_type in ("sse", "http"):
        if not config.url:
            raise ValueError(f"MCP server '{server_name}' with {transport_type} transport requires 'url' field")
        params["url"] = config.url
        # Add headers if present
        if config.headers:
            params["headers"] = config.headers
        # Pacgate 2026-10-11: replace the MCP SDK's default 30s/300s httpx
        # budget (which kills >5min tool calls, see module docstring) with a
        # Pacgate-sized one. Passed via httpx_client_factory so we do not
        # touch the deprecated timeout/sse_read_timeout kwargs at all.
        params["httpx_client_factory"] = _httpx_timeout_factory
    else:
        raise ValueError(f"MCP server '{server_name}' has unsupported transport type: {transport_type}")

    return params


def build_servers_config(extensions_config: ExtensionsConfig) -> dict[str, dict[str, Any]]:
    """Build servers configuration for MultiServerMCPClient.

    Args:
        extensions_config: Extensions configuration containing all MCP servers.

    Returns:
        Dictionary mapping server names to their parameters.
    """
    enabled_servers = extensions_config.get_enabled_mcp_servers()

    if not enabled_servers:
        logger.info("No enabled MCP servers found")
        return {}

    servers_config = {}
    for server_name, server_config in enabled_servers.items():
        try:
            servers_config[server_name] = build_server_params(server_name, server_config)
            logger.info(f"Configured MCP server: {server_name}")
        except Exception as e:
            logger.error(f"Failed to configure MCP server '{server_name}': {e}")

    return servers_config