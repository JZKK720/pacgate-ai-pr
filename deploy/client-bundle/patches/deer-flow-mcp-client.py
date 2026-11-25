"""MCP client using langchain-mcp-adapters."""

import logging
from typing import Any

import httpx

from deerflow.config.extensions_config import ExtensionsConfig, McpServerConfig
from deerflow.mcp.headers import illegal_header_value_reason

logger = logging.getLogger(__name__)

# Pacgate 2026-10-11: read budget for a single MCP tool call over HTTP. Must
# exceed the largest server-side lane (sanitize 700s) with headroom, and stay
# below the compose/nginx 720s read chain so failures surface here.
PACGATE_MCP_TOOL_TIMEOUT_S = float(900)
# Idle budget for the GET/SSE stream; unchanged from the SDK default.
PACGATE_MCP_SSE_READ_TIMEOUT_S = float(300)


def _pacgate_httpx_client_factory(
    headers: dict[str, str] | None = None,
    timeout: httpx.Timeout | None = None,
    auth: httpx.Auth | None = None,
) -> httpx.AsyncClient:
    """Pacgate's replacement for mcp's create_mcp_http_client.

    The SDK caller (streamable_http_client / sse_client) passes
    ``timeout=httpx.Timeout(<connect/write/pool>, read=<sse_read_timeout>)``,
    i.e. 30s connect/write/pool and 300s read by default. Two long-lane tool
    calls live far above those numbers (pacgate_execute_workflow measured at
    ~174s and scaling with matter size; pacgate_sanitize_* at ~655s against a
    700s server-side budget). Measured 2026-10-11: a workflow that had already
    completed server-side was torn down at 01:47:41 with "Server disconnected
    without sending a response" because of the 300s read budget.

    `timeout` is therefore deliberately IGNORED (the whole point of this patch),
    while `headers` and `auth` are forwarded: a server with an X-API-Key would
    otherwise authenticate as anonymous and get 401s that cascade into an empty
    tool list for every server.
    """
    del timeout
    return httpx.AsyncClient(
        follow_redirects=True,
        timeout=httpx.Timeout(PACGATE_MCP_TOOL_TIMEOUT_S, read=PACGATE_MCP_TOOL_TIMEOUT_S),
        headers=headers,
        auth=auth,
    )


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
        if config.cwd:
            params["cwd"] = config.cwd
        # Add environment variables if present
        if config.env:
            params["env"] = config.env
    elif transport_type in ("sse", "http"):
        if not config.url:
            raise ValueError(f"MCP server '{server_name}' with {transport_type} transport requires 'url' field")
        params["url"] = config.url
        if (config.model_extra or {}).get("personal_public_network") is True:
            from deerflow.mcp.personal_network import personal_httpx_client_factory

            params["httpx_client_factory"] = personal_httpx_client_factory
        else:
            # Pacgate: replace the 30s/300s SDK default with the Pacgate budget.
            # Personal-network servers keep upstream's factory, which owns its
            # own transport pinning and must not be wrapped.
            params["httpx_client_factory"] = _pacgate_httpx_client_factory
        # Add headers if present
        if config.headers:
            # A statically configured value the transport would refuse gets the
            # same treatment as a request-scoped one: h11 renders the full
            # value into its exception on a line break or surrounding
            # whitespace, which reaches the model through
            # ToolErrorHandlingMiddleware. These values are API keys often
            # enough to be worth refusing here, where build_servers_config
            # already drops just this server and logs the reason.
            for header_name, header_value in config.headers.items():
                reason = illegal_header_value_reason(header_value)
                if reason is not None:
                    raise ValueError(f"MCP server '{server_name}' has a header '{header_name}' that cannot be sent as an HTTP header value: it {reason}")
            params["headers"] = config.headers
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
