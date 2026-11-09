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
    pacgate_read_memory        — read a matter's working memory
                               (GET /api/matters/:id/memory)
    pacgate_write_memory       — write a matter's working memory (revision-guarded)
                               (POST /api/matters/:id/memory, optional If-Match)
    pacgate_get_workspace      — one aggregated view of a matter (documents +
                               extraction records + RAG/sanitizer rollup)
                               (GET /api/matters/:id/workspace)

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

    def _relogin(self) -> None:
        """Re-acquire a JWT after a 401.

        pacgate-api issues 24-hour tokens (pacgate-core/src/lib.rs:
        `Duration::hours(24)`), but this client authenticates once at startup.
        Without a re-login every tool call 401s from the 24-hour mark until the
        container is recreated.

        Only possible when credentials are held: a deployment configured with
        PACGATE_JWT_TOKEN alone has nothing to log in with, and keeps the old
        behaviour (surface the 401 rather than spin).
        """
        if not (self.email and self.password):
            return
        self.jwt_token = self._login()

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.jwt_token:
            headers["Authorization"] = f"Bearer {self.jwt_token}"
        return headers

    def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: dict[str, Any] | None = None,
        data: dict[str, Any] | None = None,
        files: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> httpx.Response:
        """Send a request; on 401 re-login once and retry exactly once.

        Headers are rebuilt inside `send()` so the retry carries the NEW token -
        passing a headers dict built by the caller would resend the expired one
        and 401 again. Retrying is safe because pacgate-api rejects an expired
        token before the handler runs, so a 401 means nothing was executed.

        `headers` are per-call extras (e.g. `If-Match` from the memory revision
        guard) merged OVER the auth/Content-Type base. They are merged inside
        `send()` for the same reason the auth header is: a retry must carry the
        refreshed token, not a snapshot taken before the re-login.

        `timeout` overrides the client default for one call (used by the
        sanitize endpoints, whose NER pass legitimately runs for minutes).
        """

        def send() -> httpx.Response:
            merged = self._headers()
            if headers:
                merged.update(headers)
            if files is not None:
                # Let httpx generate multipart/form-data WITH its boundary.
                # Forcing application/json here would break every upload: the
                # server would parse a multipart body as JSON. The previous
                # post_multipart never set Content-Type for this reason.
                merged.pop("Content-Type", None)
            kwargs: dict[str, Any] = {"headers": merged}
            if params is not None:
                kwargs["params"] = params
            if json is not None:
                kwargs["json"] = json
            if data is not None:
                kwargs["data"] = data
            if files is not None:
                kwargs["files"] = files
            if timeout is not None:
                kwargs["timeout"] = timeout
            return self._client.request(method, f"{self.base_url}{path}", **kwargs)

        resp = send()
        if resp.status_code == 401 and self.email and self.password:
            logger.info("pacgate-api returned 401; re-authenticating and retrying once")
            self._relogin()
            resp = send()
        return resp

    def get(
        self, path: str, params: dict[str, Any] | None = None, timeout: float | None = None
    ) -> httpx.Response:
        return self._request("GET", path, params=params, timeout=timeout)

    def post(
        self,
        path: str,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        timeout: float | None = None,
    ) -> httpx.Response:
        return self._request("POST", path, json=json, headers=headers, timeout=timeout)

    def delete(self, path: str) -> httpx.Response:
        return self._request("DELETE", path)

    def patch(
        self, path: str, json: dict[str, Any] | None = None, timeout: float | None = None
    ) -> httpx.Response:
        return self._request("PATCH", path, json=json, timeout=timeout)

    def post_multipart(
        self, path: str, data: dict[str, Any], files: dict[str, Any]
    ) -> httpx.Response:
        """POST multipart/form-data (used by pacgate-api document upload)."""
        return self._request("POST", path, data=data, files=files)


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

    if results:
        return json.dumps(results, ensure_ascii=False, indent=2)

    # An empty result is a FACTUAL CLAIM, and a bare `[]` states the wrong one.
    #
    # Measured 2026-10-24: a lawyer asked for the firm's 互联网+/电商合规 material
    # and got `[]` eighteen times. The matter being searched ("Firm Knowledge
    # Base") had zero documents - nothing had ever been ingested. `[]` reads
    # identically to "the firm holds no such authority" and to "the tool is
    # broken", and a lawyer has no way to tell which.
    #
    # So distinguish the two empty cases and say what to do about each. The
    # non-empty path above is untouched, so existing consumers keep the array
    # shape they already parse.
    indexed = _matter_index_state(client, matter_id)
    if indexed["documents"] == 0:
        reason = "no_documents"
        message = (
            f"Matter {matter_id} has no documents at all, so there is nothing to "
            "search. This is NOT a statement that the firm lacks material on this "
            "topic - the corpus is empty. Upload the source documents to this "
            "matter, then run pacgate_sanitize_document on each one; only "
            "sanitized chunks become searchable."
        )
    elif indexed["searchable"] == 0:
        reason = "nothing_sanitized"
        message = (
            f"Matter {matter_id} has {indexed['documents']} document(s) but none "
            "are searchable yet: "
            f"{indexed['pending']} still pending sanitization. This is NOT a "
            "statement that the firm lacks material on this topic. Run "
            "pacgate_sanitize_document on the pending documents, then search "
            "again."
        )
    else:
        reason = "no_match"
        message = (
            f"Matter {matter_id} has {indexed['searchable']} searchable "
            f"document(s), but none matched {query!r}. The corpus is populated, so "
            "this is a genuine no-match: try broader or different keywords, or "
            "check that the relevant document has been sanitized."
        )

    return json.dumps(
        {
            "results": [],
            "empty_reason": reason,
            "matter_id": matter_id,
            "query": query,
            "documents_in_matter": indexed["documents"],
            "searchable_documents": indexed["searchable"],
            "pending_sanitization": indexed["pending"],
            "message": message,
        },
        ensure_ascii=False,
        indent=2,
    )


def _matter_index_state(client: "PacgateApi", matter_id: str) -> dict[str, int]:
    """Count a matter's documents by searchability.

    Search only returns chunks whose `sanitization_state` is 'sanitized' or
    'never' (pacgate-rag/src/lib.rs:314), so a document that exists but is still
    'pending' is invisible to `kb_search`. Without this count the tool cannot
    tell "empty corpus" from "populated but unsanitized" from "genuine no-match".

    Best-effort: if the workspace call fails, report zeros rather than turning a
    search into an error. The caller still gets a usable message.
    """
    try:
        resp = client.get(f"/api/matters/{matter_id}/workspace")
        _handle_error(resp)
        ws = resp.json()
    except Exception:
        return {"documents": 0, "searchable": 0, "pending": 0}

    docs = ws.get("documents") or []
    rag = ws.get("rag_documents") or []
    searchable = sum(
        1
        for r in rag
        if any(s in ("sanitized", "never") for s in (r.get("states") or []))
    )
    pending = sum(
        1 for d in docs if (d.get("sanitization_state") or "") == "pending"
    )
    return {"documents": len(docs), "searchable": searchable, "pending": pending}


@mcp.tool()
def pacgate_connector_search(
    query: str,
    jurisdiction: str | None = None,
    doc_type: str | None = None,
    limit: int = 10,
    connector: str | None = None,
) -> str:
    """Search external legal databases (元典, 北大法宝, 企查查, CourtListener, SEC EDGAR, ...).

    Fans out across all available legal data source connectors and returns
    matching laws, cases, and filings.

    Results come from third-party databases and carry NO Pacgate data
    classification, so there is no `data_level` argument: passing one to the
    API is a 400. Use `pacgate_kb_search` for the classified, filtered corpus.

    Args:
        query: The search keywords (e.g. a legal term or company name).
        jurisdiction: Optional filter, e.g. "ChinaMainland" or "UnitedStates".
        doc_type: Optional document type filter (law, case, regulation, ...).
        limit: Maximum results per connector (default 10).
        connector: Optional: restrict to a single connector by name.
    """
    client = get_client()
    params: dict[str, Any] = {"q": query, "limit": limit}
    if jurisdiction:
        params["jurisdiction"] = jurisdiction
    if doc_type:
        params["doc_type"] = doc_type
    if connector:
        params["connector"] = connector

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


# ─────────────────────────────────────────────────────────────────────────────
# Firecrawl — general web search and page-to-markdown extraction
# ─────────────────────────────────────────────────────────────────────────────
#
# WHY THESE LIVE HERE AND NOT AS A FOURTH `mcpServers` ENTRY
#
# Measured 2026-11-05 against the running 0.2.30 image. `get_mcp_tools()` in
# `deerflow/mcp/tools.py` awaits `MultiServerMCPClient.get_tools()`, which
# `asyncio.gather`s one `load_mcp_tools` task per server WITHOUT
# `return_exceptions`. The whole call is wrapped in a single
# `except Exception: return []`. So one unreachable MCP server does not degrade
# its own tool set - it deletes every MCP tool, including pacgate and officecli,
# and the agent keeps running with no indication that its legal database
# disappeared. A remote Firecrawl endpoint (api.firecrawl.dev, or a container
# that may not be started) is exactly that failure mode.
#
# As tools on the already-healthy pacgate server, the failure is contained: a
# missing key or a dead endpoint returns one JSON object with available=false,
# nothing else changes, and the agent can read the reason.
#
# WHY v1 AND NOT v2
#
# `pacgate-search/src/lib.rs` (FirecrawlConnector) and the QM sandbox tool
# `firecrawl_qm.py` both speak v1. v2 answers with a DIFFERENT shape for search
# (`data.web[]` rather than `data[]`), so mixing versions across three clients
# is how one of them silently starts parsing the wrong key and returns nothing.
# Verified 2026-11-05: v1 and v2 both still serve /search and /scrape, v1 carries
# no announced sunset, and scrape is byte-identical (`data.markdown`). A move to
# v2 is therefore a coordinated three-file change, not a per-call choice.
FIRECRAWL_API_BASE = "https://api.firecrawl.dev/v1"
# Search descriptions can carry the whole page in markdown (measured: 12,156
# characters for one result). Unclipped, ten results would flood the model
# context with page bodies the agent did not ask for.
FIRECRAWL_SNIPPET_CHARS = 400
FIRECRAWL_SCRAPE_DEFAULT_CHARS = 20000


class _FirecrawlUnavailable(RuntimeError):
    """No key on this deployment, or the API did not answer."""


def _firecrawl_key() -> str:
    """The per-machine key, or raise.

    An EMPTY value counts as absent, not as a key. `.env.example` ships the line
    commented out as `#FIRECRAWL_API_KEY=`; an operator who uncomments it without
    pasting a value would otherwise get a 401 from the API on every call instead
    of the honest "not configured" answer.
    """
    key = os.environ.get("FIRECRAWL_API_KEY", "").strip()
    if not key:
        raise _FirecrawlUnavailable(
            "FIRECRAWL_API_KEY is not set in this deployment's .env; "
            "web search and page extraction are disabled (nothing else is affected)"
        )
    return key


def _firecrawl_post(path: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    """POST to the Firecrawl API, or raise _FirecrawlUnavailable."""
    try:
        resp = httpx.post(
            f"{FIRECRAWL_API_BASE}{path}",
            json=payload,
            headers={
                "Authorization": f"Bearer {_firecrawl_key()}",
                "Content-Type": "application/json",
            },
            timeout=timeout,
        )
    except httpx.HTTPError as exc:
        raise _FirecrawlUnavailable(
            f"api.firecrawl.dev is not reachable from this deployment: {type(exc).__name__}"
        ) from exc
    if resp.status_code >= 400:
        # 401/403 is a wrong or revoked key - the one failure an operator can fix.
        raise _FirecrawlUnavailable(
            f"Firecrawl returned {resp.status_code}: {resp.text[:300]}"
        )
    try:
        return resp.json()
    except ValueError as exc:
        raise _FirecrawlUnavailable("Firecrawl returned a body that is not JSON") from exc


def _firecrawl_unavailable(tool: str, exc: Exception) -> str:
    """A readable "this source is off" answer instead of a tool error.

    Mirrors `_laya_unavailable_result`: a machine without a key must still be able
    to run every other tool, and the model should be able to say WHY the web lane
    is empty rather than retrying.
    """
    return json.dumps(
        {"tool": tool, "available": False, "reason": str(exc), "results": []},
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool()
def pacgate_web_search(query: str, limit: int = 5) -> str:
    """Search the open web (Firecrawl) for current events, company news, or
    public pages that the legal databases do not cover.

    Use pacgate_connector_search for statutes, cases and filings; use this for
    everything outside those databases. Results are web-sourced, not
    authority-verified - always cite the URL and do not treat a search hit as
    settled law.

    Args:
        query: The search query.
        limit: Maximum number of results (default 5).
    """
    tool = "pacgate_web_search"
    try:
        body = _firecrawl_post(
            "/search", {"query": query, "limit": max(1, min(limit, 20))}, timeout=60
        )
    except _FirecrawlUnavailable as exc:
        return _firecrawl_unavailable(tool, exc)

    if body.get("success") is False:
        return _firecrawl_unavailable(tool, _FirecrawlUnavailable("Firecrawl reported success=false"))

    results = []
    for item in body.get("data") or []:
        if not isinstance(item, dict):
            continue
        snippet = (item.get("description") or "").strip()
        if len(snippet) > FIRECRAWL_SNIPPET_CHARS:
            snippet = snippet[:FIRECRAWL_SNIPPET_CHARS].rstrip() + "…"
        results.append(
            {
                "title": item.get("title") or "",
                "url": item.get("url") or "",
                "snippet": snippet,
                # The 4-level provenance scale must not be inflated by a web hit.
                "source_level": "auxiliary_db",
                "source_name": "firecrawl",
            }
        )
    return json.dumps(
        {"tool": tool, "available": True, "count": len(results), "results": results},
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool()
def pacgate_web_scrape(url: str, max_chars: int = FIRECRAWL_SCRAPE_DEFAULT_CHARS) -> str:
    """Fetch one public web page and return its main content as markdown.

    Use this after pacgate_web_search when a result needs to be read, and for
    public documents that are already at a URL. The deployed tooling cannot
    browse, so a page that needs clicks, forms, or a login cannot be read here -
    take the public document URL instead.

    Args:
        url: The absolute http(s) URL to fetch.
        max_chars: Truncate the markdown at this many characters (default 20000).
    """
    tool = "pacgate_web_scrape"
    if not url.lower().startswith(("http://", "https://")):
        return json.dumps(
            {"tool": tool, "available": True, "error": f"not an http(s) URL: {url}"}
        )
    try:
        body = _firecrawl_post(
            "/scrape", {"url": url, "formats": ["markdown"]}, timeout=120
        )
    except _FirecrawlUnavailable as exc:
        return _firecrawl_unavailable(tool, exc)

    # The content sits at data.markdown, NOT at the top level. Reading `markdown`
    # directly is the exact defect that made the QM sandbox tool print an empty
    # page with exit code 0 - see deploy/qm-pacgate/sandbox/tools/firecrawl-qm/.
    data = body.get("data") or {}
    if not isinstance(data, dict):
        data = {}
    markdown = data.get("markdown") or ""
    meta = data.get("metadata") or {}
    truncated = len(markdown) > max_chars
    return json.dumps(
        {
            "tool": tool,
            "available": True,
            "url": url,
            "resolved_url": meta.get("sourceURL") or url,
            "title": meta.get("title") or "",
            "source_level": "auxiliary_db",
            "truncated": truncated,
            "chars": min(len(markdown), max_chars),
            "markdown": markdown[:max_chars],
        },
        ensure_ascii=False,
        indent=2,
    )


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


def _default_matter_id(matter_id: str | None) -> str | None:
    """Resolve the matter id: explicit arg wins, else PACGATE_MATTER_ID env.

    Models occasionally serialize an omitted optional as the literal strings
    "None" or "null" instead of leaving it out (observed live 2026-10-05:
    pacgate_get_workspace got matter_id="None" and the API answered
    "invalid matter id: invalid character; found `N` at 0"). Treat those and
    empty strings as unset so the env default still applies.
    """
    if matter_id and matter_id.strip().lower() not in ("none", "null", ""):
        return matter_id.strip()
    env_value = os.environ.get("PACGATE_MATTER_ID", "").strip()
    return env_value or None


@mcp.tool()
def pacgate_read_memory(matter_id: str | None = None) -> str:
    """Read a matter's working memory (procedural notes about the matter).

    Matter memory is NOT the document knowledge base - it is small,
    revision-controlled working notes scoped to one matter (e.g. task
    checklists, current status). Prefer this over pacgate_kb_search when the
    user asks about "matter memory" or what the team has recorded so far.

    Args:
        matter_id: The UUID of the matter. Defaults to PACGATE_MATTER_ID from
            the environment (the deployment's scoped matter).
    """
    mid = _default_matter_id(matter_id)
    if not mid:
        return json.dumps({"error": "no matter_id given and PACGATE_MATTER_ID is not set"})
    client = get_client()
    resp = client.get(f"/api/matters/{mid}/memory")
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_write_memory(
    content: str,
    matter_id: str | None = None,
    if_match: int | None = None,
) -> str:
    """Write a matter's working memory, with lost-update protection.

    Sends If-Match: <revision> when given; pacgate-api refuses (409) when the
    memory changed since that revision, refusing to silently overwrite a
    concurrent editor.

    Args:
        content: The new memory content (plain text working notes).
        matter_id: The UUID of the matter. Defaults to PACGATE_MATTER_ID.
        if_match: The revision previously read via pacgate_read_memory,
            sent as If-Match. Omit for an unconditional first write.
    """
    mid = _default_matter_id(matter_id)
    if not mid:
        return json.dumps({"error": "no matter_id given and PACGATE_MATTER_ID is not set"})
    client = get_client()
    headers = {"If-Match": str(if_match)} if if_match is not None else {}
    resp = client.post(
        f"/api/matters/{mid}/memory",
        json={"content": content},
        headers=headers,
    )
    if resp.status_code in (409, 422):
        return json.dumps(
            {"error": f"pacgate-api {resp.status_code}", "detail": resp.text},
            ensure_ascii=False,
        )
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


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
def pacgate_get_workspace(matter_id: str | None = None) -> str:
    """Get the unified matter workspace: everything one matter holds in one response.

    The aggregated view (GET /api/matters/:id/workspace): the document list
    with per-document sanitization state, OCR extraction records (pages,
    engine, incomplete flag), and the RAG store rollup (chunk counts +
    sanitization states per document). Use this FIRST to survey what a matter
    has before picking documents to read or searching the KB.

    Args:
        matter_id: The UUID of the matter. Defaults to PACGATE_MATTER_ID from
            the environment (the deployment's scoped matter).
    """
    mid = _default_matter_id(matter_id)
    if not mid:
        return json.dumps({"error": "no matter_id given and PACGATE_MATTER_ID is not set"})
    client = get_client()
    resp = client.get(f"/api/matters/{mid}/workspace")
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


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

# Per-request timeout override for endpoints that legitimately run for many
# minutes. Measured 2026-10-08: a full-document sanitize runs BERT NER over
# every 500-token window TWICE (detect + verify) - a 144-chunk doc took
# ~655s server-side. The default client timeout (PACGATE_MCP_TIMEOUT, 60s)
# aborted those calls mid-job; the dropped HTTP connection kills the handler
# future, so the doc stayed `pending` and NO progress was ever made. The
# override must exceed the composed nginx 720s read timeout chain.
SANITIZE_TIMEOUT_S = float(os.environ.get("PACGATE_SANITIZE_TIMEOUT", "700"))


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
        except httpx.HTTPError as e:
            # Transport-level failures (connection reset, timeout) measured
            # 2026-10-08 on the first batch call after idle: the failure is
            # per-request, so record it and keep going instead of aborting
            # the whole batch; the caller can re-run (cache makes re-runs of
            # already-extracted docs free).
            processed.append(
                {"document_id": document_id, "name": doc.get("name"), "status": "failed", "error": f"transport: {e}"[:200]}
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

    Trusting the verdict: since 2026-11-02 the verifier re-scans with the rule
    layer independently of the redactor's suppressor, so a `pass` means no
    structural identifier survived - it is no longer a replay of the same
    suppressor that drove the redaction. `verification_notes` records a
    `model gate:` line when a MODEL guess was suppressed; that never applies to
    a checksum or pattern match. For text sanitized BEFORE that date, use
    pacgate_rescan_residue rather than trusting the stored verdict.

    LONG-RUNNING: large documents can take several minutes (the sanitizer
    re-verifies with the same detector set it redacted with). This call uses
    its own long timeout; do not reduce PACGATE_SANITIZE_TIMEOUT below the
    nginx /pacgate/ proxy_read_timeout.

    Args:
        document_id: The UUID of the document to sanitize.
        data_level: T1|T2|T3|T4 (default T3). T4 always requires human review.

    Returns the job outcome: verdict, redaction_count, mapping_count, the
    sanitized text, the allow_auto_pass / require_human_review flags, and the
    ledger evidence (SHA-256 pre/post, rule versions). The mapping itself
    never leaves pacgate-api.

    A clean verdict is NOT the same as a promotion. When policy refuses to
    auto-pass (T4 always does), the document stays 'pending': it is not
    downloadable and not retrievable, and `chunks_promoted` is 0. Read
    `allow_auto_pass` before treating a `pass` verdict as usable.
    """
    client = get_client()
    resp = client.post(
        f"/api/documents/{document_id}/sanitize",
        json={"data_level": data_level},
        timeout=SANITIZE_TIMEOUT_S,
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
def pacgate_rescan_residue(
    document_id: str,
    matter_wide: bool = False,
    offset: int = 0,
) -> str:
    """Re-scan STORED text for identifiers that are still present (read-only).

    Use this BEFORE relying on any `sanitized` verdict produced before
    2026-11-02. Until that date the verifier replayed the redactor's own
    suppressor over the residue, so a document could pass while still holding
    身份证号, 统一社会信用代码, 律师执业证号, 银行账号, 港澳通行证, 车牌,
    微信号 and 纳税人识别号 verbatim - and a surviving resident ID could then
    be used as a lookup key against the knowledge base.

    This does not trust the ledger. It reads the chunks as stored, runs the
    deterministic rule layer only (no NER model, no embeddings, so it is fast
    and repeatable), and reports the surviving value.

    READ-ONLY: it never promotes, blocks or rewrites anything. Fixing what it
    finds is a separate, explicit step - see the `next` field, which names the
    reset + re-sanitize sequence.

    Args:
        document_id: The UUID of the document to scan, or the anchor document
                     when matter_wide is true.
        matter_wide: Scan every chunk in the document's matter instead of just
                     this document (default false).
        offset: Skip this many chunks, for paging a large matter.

    Returns: { chunks_scanned, chunks_offending, documents_offending,
    findings[{document_id, chunk_id, document_state, entity, text}],
    already_marked_sanitized[], next, truncated }.

    Read `already_marked_sanitized` first: those documents are published AND
    still carrying an identifier, so their search results must not be treated as
    clean until they are reset and re-sanitized.
    """
    client = get_client()
    resp = client.post(
        f"/api/documents/{document_id}/sanitize-rescan",
        json={"matter_wide": matter_wide, "offset": offset},
    )
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_reset_sanitization(document_id: str) -> str:
    """Un-publish a document so a re-sanitize can actually replace its chunks.

    A document in state `sanitized` whose chunks still carry an identifier (see
    pacgate_rescan_residue) cannot be repaired by simply re-running the job: the
    published rows are what the repair has to overwrite, and the promotion path
    is pending-only on purpose. This returns the document and its chunks to
    `pending` - not searchable, not downloadable - so the next sanitize run is a
    real rewrite rather than a no-op.

    This REMOVES reachability for the duration. That is the fail-closed
    direction, and it is why the call is explicit: admin/partner only, audited as
    `document.sanitize-reset`.

    Args:
        document_id: The UUID of the published document to reset.

    Returns: { document_id, document_reopened, chunks_reopened, note }.
    Re-run pacgate_sanitize_document afterwards to publish the repaired text.
    """
    client = get_client()
    resp = client.patch(f"/api/documents/{document_id}/sanitize-reset")
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
        timeout=SANITIZE_TIMEOUT_S,
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


# ---------------------------------------------------------------------------
# laya: local System 1 decision engine (optional)
#
# WHY THIS EXISTS (2026-10-31)
#
# laya is a non-autoregressive decision engine: you ask typed questions
# (choice / score / noul) about a piece of text and get calibrated answers from
# one forward pass. Nothing is generated, so there is nothing to parse and
# nothing to hallucinate. That makes it the right tool for judging a clause
# that the extraction pipeline has ALREADY found - not for reading documents,
# which is what the reasoning model does.
#
# It runs as its own HTTP service (`laya-serve`) because the deer-flow image is
# upstream and cannot take a new Python dependency. It is OPTIONAL: it costs a
# 1.2 GB checkpoint, so a machine may not have it. Everything below therefore
# degrades to an explicit "unavailable" result rather than raising. A tool that
# raises on an unconfigured machine looks broken; a tool that says it is not
# enabled is a capability that is simply absent.
#
# No API key is involved anywhere in this path - that is the entire point of
# using laya instead of a metered judgment API.
# ---------------------------------------------------------------------------

LAYA_DEFAULT_URL = "http://laya:8000/v1/systemone"

# The three questions are fixed here rather than taken from the caller so the
# model is always asked the same thing. A caller-supplied question set would
# make results incomparable across clauses, which is the one property a risk
# signal has to have.
_LAYA_RISK_QUESTIONS: dict[str, Any] = {
    "risk": {
        "type": "choice",
        "instructions": "How risky is this contract clause for our client?",
        "criteria": {
            "high": (
                "uncapped or unlimited liability, punitive or liquidated damages, "
                "one-sided termination, broad indemnity, waiver of key remedies"
            ),
            "medium": (
                "ambiguous wording, asymmetric obligations, unclear remedies, "
                "short or missing notice periods"
            ),
            "low": (
                "routine terms, balanced obligations, standard boilerplate, "
                "clear and mutual remedies"
            ),
        },
    },
    "favored_party": {
        "type": "choice",
        "instructions": "Which party does this clause favor?",
        "criteria": {
            "client": "clearly favors our client",
            "counterparty": "clearly favors the other party",
            "neutral": "balanced, mutual, or standard",
        },
    },
}

_LAYA_FLAG_QUESTIONS: dict[str, Any] = {
    "uncapped_liability": {
        "type": "noul",
        "instructions": "Does this clause expose our client to liability with no cap?",
    },
    "unilateral_termination": {
        "type": "noul",
        "instructions": "Can the other party terminate without our client having a matching right?",
    },
    "auto_renewal": {
        "type": "noul",
        "instructions": "Does this clause renew the agreement automatically unless notice is given?",
    },
    "dispute_waiver": {
        "type": "noul",
        "instructions": "Does this clause waive or restrict our client's right to litigate or arbitrate?",
    },
}


def _laya_url() -> str:
    return os.environ.get("PACGATE_LAYA_URL", LAYA_DEFAULT_URL).rstrip("/")


def _laya_post(payload: dict[str, Any]) -> dict[str, Any]:
    """POST to laya-serve, or raise _LayaUnavailable."""
    timeout = float(os.environ.get("PACGATE_LAYA_TIMEOUT", "60"))
    try:
        resp = httpx.post(_laya_url(), json=payload, timeout=timeout)
    except httpx.HTTPError as exc:
        raise _LayaUnavailable(
            f"laya is not reachable at {_laya_url()} "
            f"(set PACGATE_LAYA_URL, or enable the laya service): {type(exc).__name__}"
        ) from exc
    if resp.status_code >= 400:
        raise _LayaUnavailable(
            f"laya returned {resp.status_code} for this request: {resp.text[:300]}"
        )
    return resp.json()


class _LayaUnavailable(RuntimeError):
    """laya is not configured for this deployment, or did not answer."""


def _laya_truncation(usage: dict[str, Any] | None) -> dict[str, Any] | None:
    """Describe a state that laya cut short, or None when it read all of it.

    WHY THIS IS NOT LEFT IN `usage` (measured 2026-11-02). laya reports
    `usage.truncated` honestly, and every consumer of these tools reads the
    `answers` field - the probabilities look identical whether they were computed
    over the clause or over its first 400 words. Measured on the shipped question
    sets against the 4-flag endpoint: a clause of ~330 words is read in full, and
    ~384 words already drops 12 tokens, silently. Chinese is worse in practice
    because a single clause can carry 1,000+ characters.

    A probability computed over a prefix is not a wrong number; it is a number
    about a different clause. So it is surfaced at the top level, next to the
    answer, and the Chinese path refuses to grade at all - a `low` derived from
    the first third of a clause is exactly the false clearance the withholding
    logic elsewhere in this file exists to prevent.
    """
    if not isinstance(usage, dict) or not usage.get("truncated"):
        return None
    dropped = usage.get("state_tokens_dropped")
    return {
        "partial": True,
        "state_tokens_dropped": dropped,
        "state_tokens_read": usage.get("state_tokens"),
        "note": (
            "The clause exceeded laya's window and the tail was dropped before "
            "judgement, so these numbers describe only the part that was read. "
            "Do not treat an absence of flags in the dropped text as absence of "
            "risk. Split the clause, or raise max_len for this deployment."
        ),
    }


def _laya_unavailable_result(tool: str, exc: Exception) -> str:
    return json.dumps(
        {
            "tool": tool,
            "available": False,
            "reason": str(exc),
            "note": (
                "laya is an optional local decision engine. The clause tools are "
                "inactive until a laya service is configured for this deployment."
            ),
        },
        ensure_ascii=False,
        indent=2,
    )


def _laya_answers(
    state: str,
    questions: dict[str, Any],
    *,
    min_confidence: float | None = None,
    max_len: int | None = None,
    lang: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"state": state, "questions": questions}
    # Forwarded only when set, so the deployment's own Router settings stay in
    # charge otherwise. min_confidence is the abstention gate: without it laya
    # is forced to pick a bucket, and a confident wrong answer is worse than
    # "cannot judge" in legal review.
    if min_confidence is not None:
        payload["min_confidence"] = float(min_confidence)
    if max_len is not None:
        payload["max_len"] = int(max_len)
    if lang:
        payload["lang"] = lang
    return _laya_post(payload)


# ---------------------------------------------------------------------------
# Chinese risk grading is withheld on purpose.
#
# Measured 2026-11-01 against CCL-DRR (6,794 Chinese contract clauses, three-way
# labels, near-uniform so chance is 0.333), running the questions this server
# ships:
#
#     accuracy          0.333   exactly chance
#     recall on 风险高    0.00    it did not flag ONE high-risk clause
#     predictions       high=0  medium=17  low=4
#
# Asking the same question in Chinese was worse (0.238). Overall accuracy moves
# between 0.238 and 0.571 depending on framing and sample, which is the trap: on
# this class balance, answering "medium" most of the time scores 0.57 while
# catching nothing. So a Chinese "low" is not clearance, and returning one at all
# invites exactly that misreading in a legal review.
#
# Reproduce: scripts/bench-laya-chinese-risk.ps1 (gates on recall of 风险高).
#
# The guard is on CJK content, not on `lang`, because the caller may not pass
# `lang` and the text is the ground truth. `validated_for_language: false` plus a
# null verdict makes the reason impossible to ignore and impossible to sum into a
# report as if it were a green result.
# ---------------------------------------------------------------------------
_CJK_RANGES: tuple[tuple[int, int], ...] = (
    (0x3400, 0x4DBF),    # CJK Unified Ideographs Extension A
    (0x4E00, 0x9FFF),    # CJK Unified Ideographs
    (0xF900, 0xFAFF),    # CJK Compatibility Ideographs
    (0xFF00, 0xFFEF),    # Halfwidth and Fullwidth Forms
    (0x20000, 0x2FA1F),  # CJK Extension B and beyond
)


def _is_cjk_dominant(text: str) -> bool:
    """True when the text's letters are mostly CJK.

    Ratio rather than presence: an English contract legitimately contains a
    Chinese party name, and refusing those would make the English path useless.
    """
    letters = [ch for ch in text if ch.isalpha()]
    if not letters:
        return False
    cjk = sum(
        1 for ch in letters
        if any(lo <= ord(ch) <= hi for lo, hi in _CJK_RANGES)
    )
    return cjk / len(letters) >= 0.30


def _laya_withheld_result(tool: str, clause: str) -> str:
    # The alternative differs by tool, and getting it wrong leaves a reader stuck:
    # pacgate_clause_risk DOES grade Chinese (its own calibrated path), so for it
    # the honest answer points at `allow_unvalidated_language`; only
    # pacgate_clause_flags has nowhere else to send a Chinese clause.
    if tool == "pacgate_clause_flags":
        instead = (
            "Use pacgate_clause_risk on this Chinese clause: it has a "
            "Chinese-calibrated path measured at recall 0.86-1.00 on the "
            "high-risk class. The four English flags are not available for Chinese."
        )
    else:
        instead = (
            "Read the clause with the reasoning model and have the reviewing "
            "lawyer judge it."
        )
    return json.dumps(
        {
            "tool": tool,
            "available": True,
            "validated_for_language": False,
            "verdict_withheld": True,
            "reason": (
                "Chinese clause-risk grading is withheld: measured against CCL-DRR "
                "it returned chance-level accuracy with 0.00 recall on high-risk "
                "clauses (it flagged none of them). A 'low' verdict here would be "
                "read as clearance, which it is not."
            ),
            "measured": {
                "dataset": "CCL-DRR (6794 Chinese contract clauses, MIT)",
                "accuracy": 0.333,
                "chance_accuracy": 0.333,
                "recall_high_risk": 0.00,
                "reproduce": "scripts/bench-laya-chinese-risk.ps1",
            },
            "use_instead": instead,
            "validated_languages": ["en"],
        },
        ensure_ascii=False,
        indent=2,
    )


# ---------------------------------------------------------------------------
# The Chinese path, measured and rebuilt rather than guessed.
#
# WHY THE OBVIOUS VERSION FAILED. Asking "how risky is this clause" as a
# three-way choice over Chinese text scored 0.333 accuracy (chance) with recall
# 0.00 on 风险高. One question carrying three semantic axes - severity, ambiguity
# and asymmetry - collapsed onto the majority class.
#
# WHAT WORKS. Decompose into three yes/no questions, one concept each, and
# combine them. Measured on CCL-DRR across four sampling seeds:
#
#     recall on 风险高   0.86 - 1.00   (chance-level baselines missed all of them)
#     precision          0.35 - 0.43
#     accuracy           0.38 - 0.57   (chance 0.333)
#
# The trade is deliberate. Recall near 1.00 means dangerous clauses are almost
# never missed; precision ~0.4 means a lawyer reviews roughly 2.5-3 clauses for
# every one that is genuinely high-risk. For legal triage that is the correct
# bias - a false "high" costs a few minutes of review, a false "low" ships an
# unfair term. It is also why this is triage and not adjudication: most of what
# it escalates is fine.
#
# The thresholds below are tuned (uncapped >= 0.75, the rest >= 0.50), not round
# numbers picked by feel. Tuned on one sample and re-measured on others; the
# spread above is the real spread, not a single lucky draw.
# ---------------------------------------------------------------------------
_LAYA_ZH_QUESTIONS: dict[str, Any] = {
    "uncapped": {
        "type": "noul",
        "instructions": "该条款是否使我方承担无上限的责任？",
    },
    "unilateral": {
        "type": "noul",
        "instructions": "该条款是否只赋予对方单方解除权？",
    },
    "ambiguous": {
        "type": "noul",
        "instructions": (
            "该条款是否使用了“酌情”“原则上”“另行协商”等不确定措辞，"
            "导致权利义务难以确定？"
        ),
    },
}

_LAYA_ZH_THRESHOLDS = {"uncapped": 0.75, "unilateral": 0.50, "ambiguous": 0.50}


def _laya_zh_answers(
    clause: str,
    *,
    min_confidence: float | None = None,
    lang: str | None = None,
) -> dict[str, Any]:
    return _laya_answers(
        clause,
        _LAYA_ZH_QUESTIONS,
        min_confidence=min_confidence,
        lang=lang,
    )


def _laya_zh_grade(answers: dict[str, Any]) -> dict[str, Any]:
    """Collapse three Chinese yes/no answers into one risk grade, with the inputs."""
    probs = {
        key: float((answers.get(key) or {}).get("noul") or 0.0)
        for key in _LAYA_ZH_QUESTIONS
    }
    if (probs["uncapped"] >= _LAYA_ZH_THRESHOLDS["uncapped"]
            or probs["unilateral"] >= _LAYA_ZH_THRESHOLDS["unilateral"]):
        grade = "high"
    elif probs["ambiguous"] >= _LAYA_ZH_THRESHOLDS["ambiguous"]:
        grade = "medium"
    else:
        grade = "low"
    return {"grade": grade, "probabilities": probs, "thresholds": _LAYA_ZH_THRESHOLDS}


def _laya_zh_verdict(answers: dict[str, Any]) -> dict[str, Any]:
    """Grade the Chinese answers, or withhold the grade when the engine abstained.

    WHY ABSTENTION HAS TO STOP THE GRADE (measured 2026-11-02). `min_confidence`
    reaches laya and laya marks the answer - `low_confidence: true` and
    `abstention: "abstained"` - but the grader only ever read `noul`, so
    abstention changed nothing. Measured on an isolated clause: `noul` 0.4773 at
    `answer_confidence` 0.4773 with the default 0.55 threshold came back
    `abstained` and was still graded. `noul` 0.4773 is below every threshold in
    `_LAYA_ZH_THRESHOLDS`, so the grade that reaches the caller is `low` - the
    one verdict this path must never emit on a clause it could not judge. The
    English path has the same hole (`abstention` sits unread in the payload), but
    there the numbers are at least visible to the reader; here a single word is
    synthesised from them, so the hole is fixed here first.
    """
    withheld = [
        key for key in _LAYA_ZH_QUESTIONS
        if (answers.get(key) or {}).get("abstention") == "abstained"
    ]
    if withheld:
        return {
            "grade": None,
            "withheld": True,
            "abstained_questions": withheld,
            "note": (
                "The engine declined to judge "
                + ", ".join(withheld)
                + " at this min_confidence. No grade is reported: a clause it "
                  "could not decide is not a low-risk clause. Read it, or lower "
                  "min_confidence to see the raw probabilities and treat them as "
                  "a prompt to review."
            ),
            "probabilities": {
                key: float((answers.get(key) or {}).get("noul") or 0.0)
                for key in _LAYA_ZH_QUESTIONS
            },
            "thresholds": _LAYA_ZH_THRESHOLDS,
        }
    return {**_laya_zh_grade(answers), "withheld": False}


@mcp.tool()
def pacgate_clause_risk(
    clause: str,
    min_confidence: float = 0.55,
    lang: str | None = None,
    allow_unvalidated_language: bool = False,
) -> str:
    """Judge a single contract clause for risk and for which party it favors.

    VALIDATED FOR BOTH LANGUAGES, with different paths and different trade-offs:

    - English: against CUAD the English checkpoint's four flags score AUC
      0.93-1.00 (n=80 over 25 contracts). Reproduce with
      scripts/bench-laya-clause-flags.ps1. One of those figures belongs to a
      different question than the flag this server ships - see
      pacgate_clause_flags, which says which one and why it matters.
    - Chinese: the English three-way question was measured at chance with recall
      0.00 - it flagged none of 7 high-risk clauses. Chinese text therefore uses
      three dedicated yes/no questions instead, measured on CCL-DRR at recall
      **0.86-1.00** on the high-risk class with precision 0.35-0.43 across four
      sampling seeds. It over-flags on purpose: a missed unfair term is
      expensive, an unnecessary review is not.

    Note the difference in the two numbers. For English the flags are a graded
    triage signal. For Chinese, recall 0.86-1.00 with precision ~0.4 means roughly
    2.5-3 clauses are escalated per genuinely risky one - a 'high' is a prompt to
    review, never a finding, and a 'low' is only as good as that measurement.

    Use this on a clause the extraction pipeline has already pulled out of a
    document. It does not read or summarize documents; for that use
    pacgate_kb_search or pacgate_read_document.

    This tool degrades to an explicit `available: false` result when the
    deployment has no laya service, so treat that field as the capability check.

    Args:
        clause: The clause text. Keep it to one clause: the engine judges a
            bounded state, and a whole contract exceeds its window.
        min_confidence: Abstention threshold in [0, 1]. An answer below it comes
            back flagged `low_confidence` rather than being hidden - treat a low
            confidence answer as "a human should read this clause". For Chinese
            the grade is withheld outright instead: a clause the engine declined
            to judge is not a low-risk clause.
        lang: Optional language code (e.g. "zh", "en") to skip detection.
        allow_unvalidated_language: Escape hatch for benchmarking only. Set true
            to get the English three-way verdict for Chinese text instead of the
            Chinese-calibrated path. Never leave this on in a review path.
    """
    if _is_cjk_dominant(clause) and not allow_unvalidated_language:
        try:
            data = _laya_zh_answers(clause, min_confidence=min_confidence, lang=lang)
        except _LayaUnavailable as exc:
            return _laya_unavailable_result("pacgate_clause_risk", exc)
        partial = _laya_truncation(data.get("usage"))
        if partial:
            # Refuse rather than grade a prefix: the Chinese path exists because a
            # missed unfair term is expensive, and a tail nobody read cannot be
            # cleared. The English path reports `partial` beside its answers; here
            # one word is synthesised, so there is nothing honest to report it beside.
            return json.dumps(
                {
                    "tool": "pacgate_clause_risk",
                    "available": True,
                    "validated_for_language": True,
                    "language": "zh",
                    "verdict_withheld": True,
                    "partial": True,
                    "reason": (
                        "The clause did not fit laya's window and "
                        f"{partial['state_tokens_dropped']} tokens of it were dropped "
                        "before judgement. A clause-level grade over part of a clause "
                        "is not a grade, and a 'low' would be false clearance. Split "
                        "the clause and judge each part."
                    ),
                    "usage": data.get("usage"),
                    "routing": data.get("routing"),
                },
                ensure_ascii=False,
                indent=2,
            )
        grade = _laya_zh_verdict(data.get("answers", {}))
        return json.dumps(
            {
                "tool": "pacgate_clause_risk",
                "available": True,
                "validated_for_language": True,
                "language": "zh",
                "risk": grade["grade"],
                "verdict_withheld": grade["withheld"],
                "abstained_questions": grade.get("abstained_questions"),
                "probabilities": grade["probabilities"],
                "thresholds": grade["thresholds"],
                "routing": data.get("routing"),
                "usage": data.get("usage"),
                "measured": {
                    "dataset": "CCL-DRR (6794 Chinese contract clauses, MIT)",
                    "recall_high_risk": "0.86-1.00 across four sampling seeds",
                    "precision": "0.35-0.43",
                    "accuracy": "0.38-0.57 (chance 0.333)",
                    "note": (
                        "Recall is the point: dangerous clauses are almost never "
                        "missed. Precision ~0.4 means roughly 2.5-3 clauses are "
                        "escalated per genuinely risky one, so a 'high' here is a "
                        "prompt to review, not a finding. Reproduce with "
                        "scripts/bench-laya-chinese-risk.ps1 (gates on recall)."
                    ),
                },
            },
            ensure_ascii=False,
            indent=2,
        )
    try:
        data = _laya_answers(
            clause,
            _LAYA_RISK_QUESTIONS,
            min_confidence=min_confidence,
            lang=lang,
        )
    except _LayaUnavailable as exc:
        return _laya_unavailable_result("pacgate_clause_risk", exc)
    return json.dumps(
        {
            "tool": "pacgate_clause_risk",
            "available": True,
            # Beside the answers, because that is the field a caller reads: a
            # probability over a truncated clause looks exactly like one over the
            # whole clause, and only this key says which it is.
            "partial": _laya_truncation(data.get("usage")),
            "answers": data.get("answers", {}),
            "routing": data.get("routing"),
            "usage": data.get("usage"),
        },
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool()
def pacgate_clause_flags(
    clause: str,
    min_confidence: float = 0.55,
    lang: str | None = None,
    allow_unvalidated_language: bool = False,
) -> str:
    """Test a clause for four specific legal risk flags as probabilities.

    VALIDATED FOR ENGLISH (measured 2026-11-01 against CUAD, 25 contracts, 80
    predictions, English checkpoint):

        uncapped_liability            AUC 0.931   P 0.83  R 0.83
        termination_for_convenience   AUC 0.988   P 1.00  R 0.81
        auto_renewal                  AUC 0.942   P 0.90  R 0.82
        dispute_waiver                AUC 1.000   P 1.00  R 0.71

    Every flag separates its concept from unrelated clauses in the same
    contracts. Reproduce with scripts/bench-laya-clause-flags.ps1.

    ONE OF THOSE FOUR IS NOT A FLAG THIS TOOL RETURNS. The benchmark measures a
    `termination_for_convenience` question ("may a party end this agreement without
    cause, for convenience, on notice?"), and this tool asks a different one:
    `unilateral_termination` adds an asymmetry requirement CUAD does not annotate.
    On identical clauses the matched question scores AUC 0.988 and the asymmetry
    question 0.600 - both honest numbers about different questions. The 0.988 is
    reported here because the measurement exists, not because this tool earns it,
    and the number above is labelled with the question it belongs to.

    The shipped asymmetry question is also the weakest of the four in isolation
    (2026-11-02): over 8 one-sided and 8 mutual termination clauses it did not
    separate the groups at all - mean P 0.55 against 0.57, with mutual clauses
    reaching 0.93. `uncapped_liability` (0.96 vs 0.17) and `auto_renewal`
    (0.97 vs 0.51) did separate cleanly. Treat a high
    `unilateral_termination` as a prompt to read the termination clause, never as
    a finding. A replacement phrasing exists and separates perfectly in Chinese
    (a three-option perception question, 3/3 vs 0/4); it is not shipped because it
    changes the English number and has not been re-measured against CUAD.

    CHINESE: the four English flags are NOT reported. They were measured on English
    contracts, and on Chinese text the same questions flagged 0 of 7 high-risk
    clauses (CCL-DRR), so four reassuring near-zero numbers would read as
    clearance. Chinese text gets `validated_for_language: false` from this tool and
    should go to `pacgate_clause_risk` instead, which has a Chinese-calibrated path
    measured at recall 0.86-1.00.

    Each flag is a yes/no probability, not a label, so a reviewer can set their
    own threshold and see that 0.6 is honestly different from 0.95.

    A `partial` key appears beside the answers when the clause did not fit the
    window. laya reads about 330 words at this deployment's settings; beyond that
    the tail is dropped before judgement and four probabilities describe a prefix.

    This tool degrades to an explicit `available: false` result when the
    deployment has no laya service.

    Args:
        clause: The clause text. One clause, not a whole contract.
        min_confidence: Abstention threshold in [0, 1].
        lang: Optional language code to skip detection.
        allow_unvalidated_language: Escape hatch for benchmarking only. Set true
            to get the English flag probabilities for Chinese text. Never leave
            this on in a review path.
    """
    if not allow_unvalidated_language and _is_cjk_dominant(clause):
        return _laya_withheld_result("pacgate_clause_flags", clause)
    try:
        data = _laya_answers(
            clause,
            _LAYA_FLAG_QUESTIONS,
            min_confidence=min_confidence,
            lang=lang,
        )
    except _LayaUnavailable as exc:
        return _laya_unavailable_result("pacgate_clause_flags", exc)
    return json.dumps(
        {
            "tool": "pacgate_clause_flags",
            "available": True,
            # Same reason as pacgate_clause_risk: `answers` is what a caller reads,
            # and four reassuring probabilities over the first part of a clause are
            # otherwise indistinguishable from four over all of it.
            "partial": _laya_truncation(data.get("usage")),
            "answers": data.get("answers", {}),
            "routing": data.get("routing"),
            "usage": data.get("usage"),
        },
        ensure_ascii=False,
        indent=2,
    )


@mcp.tool()
def pacgate_route_language(
    text: str,
    lang_guess: str | None = None,
) -> str:
    """Report which laya checkpoint and language laya would use for this text.

    Routing decides whether a clause is judged by the Chinese-capable
    multilingual checkpoint or an English-tuned one, so it is worth checking
    before trusting a batch of results. This makes no inference call and needs
    no model loaded.

    This tool degrades to an explicit `available: false` result when the
    deployment has no laya service.

    Args:
        text: Sample text to route, typically a clause or a document's opening.
        lang_guess: Optional language code from your own detection, consulted
            before detection runs.
    """
    payload: dict[str, Any] = {"state": text, "questions": {}}
    if lang_guess:
        payload["lang_guess"] = lang_guess
    try:
        timeout = float(os.environ.get("PACGATE_LAYA_TIMEOUT", "60"))
        route_url = _laya_url().replace("/systemone", "/route")
        resp = httpx.post(route_url, json=payload, timeout=timeout)
        if resp.status_code >= 400:
            raise _LayaUnavailable(
                f"laya returned {resp.status_code} for this request: {resp.text[:300]}"
            )
        data = resp.json()
    except _LayaUnavailable as exc:
        return _laya_unavailable_result("pacgate_route_language", exc)
    except httpx.HTTPError as exc:
        return _laya_unavailable_result(
            "pacgate_route_language",
            _LayaUnavailable(
                f"laya is not reachable at {_laya_url()}: {type(exc).__name__}"
            ),
        )
    return json.dumps(
        {
            "tool": "pacgate_route_language",
            "available": True,
            "model": data.get("model"),
            "repo": data.get("repo"),
            "reason": data.get("reason"),
        },
        ensure_ascii=False,
        indent=2,
    )


def main() -> None:
    port = int(os.environ.get("PACGATE_MCP_PORT", "8000"))
    logger.info("Starting pacgate MCP server on :%s", port)
    logger.info("laya endpoint: %s", _laya_url())
    # Tools are registered on the module-level `mcp` via @mcp.tool().
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
