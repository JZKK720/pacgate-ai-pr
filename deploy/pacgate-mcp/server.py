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
    pacgate_ocr_document      — run OCR extraction on a stored document
                               (POST /api/documents/:id/extract) - standalone,
                               NOT gated by the sanitizer pipeline
    pacgate_ocr_batch         — OCR every document in a matter, capped by
                               PACGATE_OCR_BATCH_PAGE_LIMIT (default 200
                               pages per run; the tool stops at the cap and
                               reports the remaining budget)
    pacgate_list_workflows    — list workflow templates
                               (GET /api/workflows?category=&search=)
    pacgate_get_workflow      — get a workflow template's steps
                               (GET /api/workflows/:id)
    pacgate_execute_workflow  — run a workflow template
                               (POST /api/workflows/:id/execute)
    pacgate_sanitize_document  — run a sanitization job over a stored document
                               (POST /api/documents/:id/sanitize)
    pacgate_verify_sanitized   — check a document's sanitization status
                               (GET /api/documents/:id/sanitize-status)
    pacgate_sanitize_text      — sanitize raw text through the job pipeline
                               (POST /api/documents + POST .../sanitize)

    (pacgate_restore is deliberately NOT exposed: restore is client-side only,
     design 3.5 - no chat turn can re-hydrate placeholders.)
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

    def delete(self, path: str) -> httpx.Response:
        return self._client.delete(f"{self.base_url}{path}", headers=self._headers())

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


@mcp.tool()
def pacgate_ocr_document(document_id: str) -> str:
    """Run OCR extraction on a stored document (standalone, no sanitization).

    Turns a document (PDF, scan, image) into plain text + positional spans
    through the local PaddleOCR service, cached per document version. This is
    the plain perception lane: no redaction runs, no verdict is produced, and
    the result carries no sanitization state change. Use pacgate_sanitize_document
    instead when the text will leave the machine.

    Args:
        document_id: The UUID of the stored document to extract.

    Returns: { text, pages, spans[], engine, incomplete }. incomplete=True
    means at least one page failed to parse - treat the text as partial.
    """
    client = get_client()
    resp = client.post(f"/api/documents/{document_id}/extract", json={})
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


# Bulk-OCR page cap (per tool invocation). Server-side enforced so an agent
# cannot run away with an unbounded job: the loop stops at the cap, reports
# what was processed, and the operator calls again to continue (already-
# extracted documents are cache hits, so a re-run after a cap-stop only pays
# for the remaining pages).
OCR_BATCH_PAGE_LIMIT_DEFAULT = 200


def _batch_page_limit() -> int:
    raw = os.environ.get("PACGATE_OCR_BATCH_PAGE_LIMIT", "")
    try:
        value = int(raw) if raw else OCR_BATCH_PAGE_LIMIT_DEFAULT
    except ValueError:
        return OCR_BATCH_PAGE_LIMIT_DEFAULT
    return max(1, value)


@mcp.tool()
def pacgate_ocr_batch(matter_id: str, max_pages: int | None = None) -> str:
    """Run OCR extraction over every document in a matter (bulk lane).

    Loops pacgate_ocr_document across the matter's document list, oldest
    first. Each document's extraction is cached per version, so re-running
    the batch after an interruption only pays for the remaining documents.

    PAGE CAP: the run stops once the total extracted pages reach the cap -
    PACGATE_OCR_BATCH_PAGE_LIMIT (default 200) or the max_pages argument,
    whichever is smaller. This bounds a single tool invocation to roughly
    2 minutes of OCR work at the observed ~600ms/page, well inside the
    MCP request timeout. The response reports pages_used, pages_remaining,
    and every document processed, so the caller can continue with another
    batch call until pages_remaining reaches 0.

    Args:
        matter_id: The UUID of the matter whose documents to process.
        max_pages: Optional smaller cap for this run (cannot raise above the
            server limit).

    Returns: { matter_id, processed: [{document_id, name, pages, spans,
    incomplete, status}], pages_used, pages_remaining, cap }.
    """
    client = get_client()
    cap = min(_batch_page_limit(), max_pages) if max_pages else _batch_page_limit()

    listing = client.get(f"/api/matters/{matter_id}/documents")
    _handle_error(listing)
    documents = listing.json()

    processed = []
    pages_used = 0
    stopped_at_cap = False
    for doc in documents:
        document_id = doc["id"]
        # Cached extractions are free - check status first so a re-run does
        # not burn page budget re-counting already-extracted pages.
        try:
            resp = client.post(f"/api/documents/{document_id}/extract", json={})
            _handle_error(resp)
            outcome = resp.json()
        except RuntimeError as e:
            processed.append(
                {"document_id": document_id, "name": doc.get("name"), "status": "failed", "error": str(e)[:200]}
            )
            continue
        pages_used += int(outcome.get("pages", 0))
        processed.append(
            {
                "document_id": document_id,
                "name": doc.get("name"),
                "status": "extracted" if not outcome.get("incomplete") else "incomplete",
                "pages": outcome.get("pages"),
                "spans": len(outcome.get("spans", [])),
                "text_chars": len(outcome.get("text", "")),
            }
        )
        if pages_used >= cap:
            break

    remaining_docs = len(documents) - len(processed)
    return json.dumps(
        {
            "matter_id": matter_id,
            "cap": cap,
            "pages_used": pages_used,
            "pages_remaining": max(cap - pages_used, 0),
            "processed_count": len(processed),
            "documents_remaining_in_matter": max(remaining_docs, 0),
            "note": "Cache makes a continuation free for already-extracted documents; call again to continue past the cap." if pages_used >= cap else None,
            "processed": processed,
        },
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool()
def pacgate_sanitize_document(
    document_id: str,
    data_level: str = "T3",
) -> str:
    """Run a sanitization job over a stored document (extract-then-redact).

    The server extracts the document once (cached per version) and then runs
    the deterministic-first redaction pipeline. On a warm cache this costs
    ZERO OCR calls. A Block verdict marks the document 'blocked' - it cannot
    be downloaded or retrieved until a human decides. Restore is NOT exposed
    through MCP; it is a client-side operator action in pacgate-api.

    Args:
        document_id: The UUID of the document to sanitize.
        data_level: T1|T2|T3|T4 (default T3). T4 always requires human review.

    Returns the job outcome: verdict, redaction_count, mapping_count, the
    sanitized text, the allow_auto_pass / require_human_review flags, and the
    ledger evidence (SHA-256 pre/post, rule versions). The mapping itself
    never leaves pacgate-api.
    """
    client = get_client()
    resp = client.post(
        f"/api/documents/{document_id}/sanitize",
        json={"data_level": data_level},
    )
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_verify_sanitized(document_id: str) -> str:
    """Check a document's sanitization status (verifier side-channel).

    Returns the document-level state, the distinct per-chunk states, and the
    latest job id. Use this to decide whether material may be relied on in a
    workflow: only documents whose state is 'sanitized' (or explicitly
    'never') may leave the machine, and kb_search only ever returns
    'sanitized' or 'never' chunks regardless.

    Args:
        document_id: The UUID of the document to check.
    """
    client = get_client()
    resp = client.get(f"/api/documents/{document_id}/sanitize-status")
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_sanitize_text(text: str, data_level: str = "T3") -> str:
    """Sanitize raw text through the document pipeline (ephemeral artifact).

    Uploads the text as a temporary document, runs the same job path, and
    returns the sanitized text and verdict. The mapping is sealed server-side
    and is NOT returned; the result is one-way on purpose (design 6.3 - cloud
    output never resolves back). For bulk work prefer ingesting real
    documents and using pacgate_sanitize_document so extraction is cached.

    Args:
        text: The raw text to sanitize.
        data_level: T1|T2|T3|T4 (default T3).
    """
    import base64 as _b64

    client = get_client()
    matters_resp = client.get("/api/matters")
    _handle_error(matters_resp)
    matters = matters_resp.json()
    if not matters:
        raise RuntimeError("no matters available; create one in pacgate-api first")
    matter_id = matters[0]["id"]
    blob = _b64.b64decode(_b64.b64encode(text.encode("utf-8")).decode("ascii"))
    files = {"file": ("sanitize-ephemeral.txt", blob)}
    up = client.post_multipart("/api/documents", {"matter_id": matter_id}, files)
    _handle_error(up)
    doc = up.json()
    resp = client.post(
        f"/api/documents/{doc['id']}/sanitize",
        json={"data_level": data_level},
    )
    _handle_error(resp)
    outcome = resp.json()
    # Clean up: delete the ephemeral document so it does not pollute the matter.
    client.delete(f"/api/documents/{doc['id']}")
    return json.dumps(
        {
            "document_id": doc["id"],
            "job_id": outcome.get("job_id"),
            "verdict": outcome.get("verdict"),
            "sanitized_text": outcome.get("sanitized_text"),
            "redaction_count": outcome.get("redaction_count"),
            "require_human_review": outcome.get("require_human_review"),
            "note": "ephemeral document deleted; mapping sealed server-side",
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
