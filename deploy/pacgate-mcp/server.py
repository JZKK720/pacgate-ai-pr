"""Pacgate MCP server — exposes pacgate-api's RAG, legal connectors, matters,
documents, and workflow templates as MCP tools for deer-flow.

This is a standard MCP HTTP (streamable) server that deer-flow consumes the same
way it consumes `openviking` (via `mcpServers` in `extensions_config.json`).

It reuses pacgate-api's own HTTP endpoints so deer-flow never sees credentials —
auth happens inside pacgate-api. The MCP server authenticates once at startup
using `PACGATE_API_EMAIL`/`PACGATE_API_PASSWORD` (or `PACGATE_JWT_TOKEN`) and
forwards a Bearer token on every call.

Exposed tools:
    pacgate_kb_search         — query the internal per-matter RAG store
                               (GET /api/kb/search?matter_id=&q=&top_k=&max_data_level=)
    pacgate_connector_search  — query external legal databases
                               (GET /api/search?q=&jurisdiction=&doc_type=&limit=&connector=)
    pacgate_list_connectors   — list available legal data source connectors
                               (GET /api/search/connectors)
    pacgate_list_matters      — list matters for the current tenant
                               (GET /api/matters)
    pacgate_list_documents    — list documents for a matter
                               (GET /api/matters/:id/documents)
    pacgate_read_document     — read/download a document's bytes
                               (GET /api/documents/:id/download)
    pacgate_convert_document  — convert a stored document to Markdown
                               (GET /api/documents/:id/download + markitdown)
    pacgate_upload_document   — upload a generated artifact back to a matter
                               (POST /api/documents)
    pacgate_list_workflows    — list workflow templates
                               (GET /api/workflows?category=&search=)
    pacgate_get_workflow      — get a workflow template's steps
                               (GET /api/workflows/:id)
    pacgate_execute_workflow  — run a workflow template
                               (POST /api/workflows/:id/execute)
"""

from __future__ import annotations

import base64
import json
import logging
import os
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

logging.basicConfig(
    level=os.environ.get("PACGATE_MCP_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s - %(message)s",
)
logger = logging.getLogger("pacgate_mcp")

# Bind the streamable HTTP transport on 0.0.0.0 so the deer-flow container on
# the compose network can reach it. Host must not stay 127.0.0.1.
mcp = FastMCP(
    "pacgate",
    host="0.0.0.0",
    port=int(os.environ.get("PACGATE_MCP_PORT", "8000")),
)


class PacgateApi:
    """Minimal authenticated client for pacgate-api."""

    def __init__(self) -> None:
        self.base_url = os.environ.get(
            "PACGATE_API_URL", "http://pacgate-api:8080"
        ).rstrip("/")
        self.email = os.environ.get("PACGATE_API_EMAIL", "")
        self.password = os.environ.get("PACGATE_API_PASSWORD", "")
        self.jwt_token = os.environ.get("PACGATE_JWT_TOKEN", "")
        self.timeout = float(os.environ.get("PACGATE_MCP_TIMEOUT", "60"))
        self._client = httpx.Client(timeout=self.timeout)
        if not self.jwt_token and self.email and self.password:
            self.jwt_token = self._login()

    def _login(self) -> str:
        resp = self._client.post(
            f"{self.base_url}/api/auth/login",
            json={"email": self.email, "password": self.password},
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        token = resp.json().get("token", "")
        if not token:
            raise ValueError("pacgate-api login did not return a token")
        logger.info("Authenticated with pacgate-api")
        return token

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.jwt_token:
            headers["Authorization"] = f"Bearer {self.jwt_token}"
        return headers

    def get(self, path: str, params: dict[str, Any] | None = None) -> httpx.Response:
        return self._client.get(
            f"{self.base_url}{path}", params=params, headers=self._headers()
        )

    def post(self, path: str, json: dict[str, Any] | None = None) -> httpx.Response:
        return self._client.post(
            f"{self.base_url}{path}", json=json, headers=self._headers()
        )

    def post_multipart(
        self, path: str, data: dict[str, Any], files: dict[str, Any]
    ) -> httpx.Response:
        """POST multipart/form-data (used by pacgate-api document upload)."""
        headers = {"Authorization": f"Bearer {self.jwt_token}"} if self.jwt_token else {}
        return self._client.post(
            f"{self.base_url}{path}", data=data, files=files, headers=headers
        )


# Instantiate lazily so the MCP server can start even if pacgate-api is not yet
# reachable; auth is refreshed on first tool call if needed.
_client: PacgateApi | None = None


def get_client() -> PacgateApi:
    global _client
    if _client is None:
        _client = PacgateApi()
    return _client


def _handle_error(resp: httpx.Response) -> None:
    if resp.status_code >= 400:
        raise RuntimeError(
            f"pacgate-api error {resp.status_code}: {resp.text}"
        )


@mcp.tool()
def pacgate_kb_search(
    query: str,
    matter_id: str,
    top_k: int = 5,
    jurisdiction: str | None = None,
    source_level: str | None = None,
    max_data_level: str = "T3",
) -> str:
    """Search pacgate's internal per-matter knowledge base (RAG).

    Retrieves chunks of law-firm documents relevant to a matter using hybrid
    semantic + keyword search, filtered by the T1-T4 data classification level.

    Args:
        query: The search keywords / natural-language question.
        matter_id: The UUID of the matter to search within.
        top_k: Maximum number of chunks to return (default 5).
        jurisdiction: Optional filter, e.g. "ChinaMainland" or "UnitedStates".
        source_level: Optional source-level filter (e.g. "AuthorityVerified").
        max_data_level: Max data classification T1-T4 (default T3; excludes T4).
    """
    client = get_client()
    params: dict[str, Any] = {
        "q": query,
        "matter_id": matter_id,
        "top_k": top_k,
    }
    if jurisdiction:
        params["jurisdiction"] = jurisdiction
    if source_level:
        params["source_level"] = source_level
    if max_data_level:
        params["max_data_level"] = max_data_level

    resp = client.get("/api/kb/search", params=params)
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_connector_search(
    query: str,
    jurisdiction: str | None = None,
    doc_type: str | None = None,
    limit: int = 10,
    connector: str | None = None,
    data_level: str | None = None,
) -> str:
    """Search external legal databases (元典, 北大法宝, 企查查, CourtListener, SEC EDGAR, ...).

    Fans out across all available legal data source connectors and returns
    matching laws, cases, and filings.

    Args:
        query: The search keywords (e.g. a legal term or company name).
        jurisdiction: Optional filter, e.g. "ChinaMainland" or "UnitedStates".
        doc_type: Optional document type filter (law, case, regulation, ...).
        limit: Maximum results per connector (default 10).
        connector: Optional: restrict to a single connector by name.
        data_level: Optional data classification tag T1-T4 (audit only).
    """
    client = get_client()
    params: dict[str, Any] = {"q": query, "limit": limit}
    if jurisdiction:
        params["jurisdiction"] = jurisdiction
    if doc_type:
        params["doc_type"] = doc_type
    if connector:
        params["connector"] = connector
    if data_level:
        params["data_level"] = data_level

    resp = client.get("/api/search", params=params)
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_list_connectors() -> str:
    """List the legal data source connectors available to pacgate.

    Returns each connector's name, display name, and availability so you know
    which external databases you can search.
    """
    client = get_client()
    resp = client.get("/api/search/connectors")
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_list_matters() -> str:
    """List all matters (cases) for the current tenant.

    Returns each matter's id, name, description, persona_id, and timestamps so
    you can scope a document/workflow call to a specific matter.
    """
    client = get_client()
    resp = client.get("/api/matters")
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_list_documents(matter_id: str) -> str:
    """List documents for a specific matter.

    Args:
        matter_id: The UUID of the matter whose documents to list.

    Returns each document's id, name, format, version, and timestamps so you
    can identify a document to read or analyze.
    """
    client = get_client()
    resp = client.get(f"/api/matters/{matter_id}/documents")
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_read_document(document_id: str, version: int | None = None) -> str:
    """Read a document's content from pacgate-api.

    Args:
        document_id: The UUID of the document to read.
        version: Optional specific version to read (defaults to latest).

    Returns the document's raw bytes (decoded as UTF-8 text where possible).
    For DOCX/PDF binary formats this returns a base64-encoded payload.
    """
    client = get_client()
    path = f"/api/documents/{document_id}/download"
    if version is not None:
        path += f"?version={version}"
    resp = client.get(path)
    _handle_error(resp)
    content_type = resp.headers.get("content-type", "")
    data = resp.content
    if "json" in content_type or "text" in content_type:
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return json.dumps(
                {"document_id": document_id, "error": "binary content"},
                ensure_ascii=False,
            )
    # Binary (docx/pdf): base64-encode so the payload survives MCP transport.
    return json.dumps(
        {
            "document_id": document_id,
            "content_type": content_type,
            "size_bytes": len(data),
            "content_base64": base64.b64encode(data).decode("ascii"),
        },
        ensure_ascii=False,
    )


@mcp.tool()
def pacgate_upload_document(
    matter_id: str,
    filename: str,
    content_base64: str,
) -> str:
    """Upload a generated artifact (e.g. a .docx memo) back to a matter.

    Use this after generating a document so the artifact is stored and versioned
    under the tenant/matter structure in pacgate-api.

    Args:
        matter_id: The UUID of the matter to attach the document to.
        filename: The output filename (e.g. "research-memo.docx").
        content_base64: Base64-encoded file bytes.

    Returns the stored document metadata (id, name, format, version).
    """
    client = get_client()
    try:
        file_bytes = base64.b64decode(content_base64)
    except Exception as e:  # noqa: BLE001
        raise ValueError(f"content_base64 is not valid base64: {e}") from e
    files = {"file": (filename, file_bytes)}
    resp = client.post_multipart("/api/documents", {"matter_id": matter_id}, files)
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_list_workflows(category: str | None = None, search: str | None = None) -> str:
    """List the workflow templates available to pacgate.

    Args:
        category: Optional category filter (e.g. "contract_review", "due_diligence").
        search: Optional keyword to match against template name or description.

    Returns each template's id, name, description, category, and step_count so
    you can pick one to execute.
    """
    client = get_client()
    params: dict[str, Any] = {}
    if category:
        params["category"] = category
    if search:
        params["search"] = search
    resp = client.get("/api/workflows", params=params or None)
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_get_workflow(workflow_id: str) -> str:
    """Get the full detail (including steps) of a workflow template.

    Args:
        workflow_id: The UUID of the workflow template to inspect.

    Returns the template's id, name, description, category, and ordered steps,
    so you can understand exactly what a run will do.
    """
    client = get_client()
    resp = client.get(f"/api/workflows/{workflow_id}")
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_execute_workflow(
    workflow_id: str,
    matter_id: str,
    persona_id: str | None = None,
    dd_domain: str | None = None,
) -> str:
    """Execute a workflow template against a matter.

    Args:
        workflow_id: The UUID of the workflow template to run.
        matter_id: The UUID of the matter to run it against.
        persona_id: Optional practice-area persona UUID to scope the run.
        dd_domain: Optional due-diligence domain
            (legal, finance, commercial, product_tech, cybersecurity, hr, tax,
            regulatory, esg).

    Returns the per-step results (step name, tool, content, citations) so you
    can relay the run's output back to the user.
    """
    client = get_client()
    body: dict[str, Any] = {"matter_id": matter_id}
    if persona_id:
        body["persona_id"] = persona_id
    if dd_domain:
        body["dd_domain"] = dd_domain
    resp = client.post(f"/api/workflows/{workflow_id}/execute", json=body)
    _handle_error(resp)
    results = resp.json()
    return json.dumps(results, ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_convert_document(
    document_id: str,
    version: int | None = None,
) -> str:
    """Convert a stored document to Markdown using markitdown.

    Downloads the document bytes from pacgate-api and converts them locally
    (PDF, DOCX, PPTX, XLSX, HTML, CSV and more). Use this when a document is
    binary and pacgate_read_document would only return base64 — the Markdown
    output is directly readable and searchable.

    Args:
        document_id: The UUID of the document to convert.
        version: Optional specific version to convert (defaults to latest).

    Returns JSON with the converted Markdown text plus size metadata.
    """
    from markitdown import MarkItDown

    client = get_client()
    path = f"/api/documents/{document_id}/download"
    if version is not None:
        path += f"?version={version}"
    resp = client.get(path)
    _handle_error(resp)
    data = resp.content
    content_type = resp.headers.get("content-type", "")

    converter = MarkItDown()
    import tempfile

    suffix = ""
    if "pdf" in content_type:
        suffix = ".pdf"
    elif "wordprocessing" in content_type or "docx" in content_type:
        suffix = ".docx"
    elif "presentation" in content_type or "pptx" in content_type:
        suffix = ".pptx"
    elif "sheet" in content_type or "xlsx" in content_type:
        suffix = ".xlsx"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(data)
        tmp_path = tmp.name
    try:
        result = converter.convert(tmp_path)
        markdown = result.text_content or ""
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass

    return json.dumps(
        {
            "document_id": document_id,
            "content_type": content_type,
            "size_bytes": len(data),
            "markdown_chars": len(markdown),
            "markdown": markdown,
        },
        ensure_ascii=False,
        indent=2,
    )


def main() -> None:
    port = int(os.environ.get("PACGATE_MCP_PORT", "8000"))
    logger.info("Starting pacgate MCP server on :%s", port)
    # Tools are registered on the module-level `mcp` via @mcp.tool().
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
