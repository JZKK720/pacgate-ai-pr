//! Legal search API handlers — query external legal databases via SearchRouter.

use axum::{
    extract::{Query, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

/// Query parameters for the external search endpoint.
#[derive(Debug, Deserialize)]
pub struct SearchQueryParams {
    /// Search keywords (required)
    pub q: String,
    /// Optional jurisdiction filter
    pub jurisdiction: Option<String>,
    /// Optional document type filter
    pub doc_type: Option<String>,
    /// Maximum results (default 10)
    pub limit: Option<u32>,
    /// Optional: search only a specific connector by name
    pub connector: Option<String>,
    /// Optional data classification level T1-T4.
    ///
    /// Refused, not ignored. It was previously accepted and described as
    /// "tagged for audit" while nothing wrote an audit row and nothing filtered,
    /// so the honest contract is a 400 until a connector can honour it.
    /// Unclassified third-party results cannot carry a Pacgate classification.
    pub data_level: Option<String>,
}

/// Query parameters for the internal knowledge base search endpoint.
#[derive(Debug, Deserialize)]
pub struct KbSearchQueryParams {
    /// Search keywords (required)
    pub q: String,
    /// Matter ID (required) — KB search is always scoped to a matter
    pub matter_id: String,
    /// Maximum results (default 5)
    pub top_k: Option<u32>,
    /// Optional jurisdiction filter (e.g., "ChinaMainland", "UnitedStates")
    pub jurisdiction: Option<String>,
    /// Optional source level filter (e.g., "AuthorityVerified", "AuxiliaryDB")
    pub source_level: Option<String>,
    /// Optional maximum data classification level T1-T4.
    /// When set, only chunks at or below this level are returned.
    /// T1 = shared templates only; T3 = templates + seeds + project files (excludes T4).
    /// Default: T3 (returns T1+T2+T3, excludes T4 special sensitive).
    ///
    /// A PRESENT but unparseable value is a 400, not a silent fall-back to T3.
    pub max_data_level: Option<String>,
}

/// A KB search result in the API response format.
#[derive(Debug, Serialize)]
pub struct KbSearchResultResponse {
    pub content: String,
    pub score: f32,
    pub source_doc: String,
    pub page: Option<u32>,
    pub data_level: String,
}

/// A search result in the API response format.
#[derive(Debug, Serialize)]
pub struct SearchResultResponse {
    pub title: String,
    pub citation: Option<String>,
    pub summary: String,
    pub url: Option<String>,
    pub source_name: String,
    pub source_level: String,
    pub jurisdiction: Option<String>,
    pub date: Option<String>,
}

/// Connector status info for the health check endpoint.
#[derive(Debug, Serialize)]
pub struct ConnectorStatus {
    pub name: String,
    pub display_name: String,
    pub available: bool,
}

/// Search external legal databases.
///
/// `GET /api/search?q=keyword&jurisdiction=ChinaMainland&limit=10`
///
/// `data_level` is NOT accepted here - see `SearchQueryParams::data_level`. The
/// classified corpus lives at `/api/kb/search`, which really does filter.
pub async fn search(
    State(state): State<AppState>,
    Query(params): Query<SearchQueryParams>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    if params.q.trim().is_empty() {
        return Err(ApiError::bad_request("search query 'q' must not be empty"));
    }

    // Validate data_level if provided.
    //
    // 2026-11-09: this parameter was validated, logged, and then DISCARDED -
    // `SearchQuery` has no data-level field because an external connector has no
    // corpus to classify. Keeping it as an accept-then-ignore argument was a
    // false compliance signal: a caller that sends `data_level=T2` reasonably
    // reads the response as "filtered to T2". It now refuses, so the parameter
    // can only ever mean something by being implemented. `tracing::info!` was
    // also not an audit trail; nothing here wrote to `audit_log`.
    if params.data_level.is_some() {
        return Err(ApiError::bad_request(
            "data_level is not supported on external search: connectors return \
             third-party results with no Pacgate classification. Use /api/kb/search \
             for the classified, filtered corpus",
        ));
    }

    let query = pacgate_search::SearchQuery::new(&params.q).with_limit(params.limit.unwrap_or(10));

    let query = if let Some(ref j) = params.jurisdiction {
        query.with_jurisdiction(j)
    } else {
        query
    };

    let query = if let Some(ref dt) = params.doc_type {
        query.with_doc_type(dt)
    } else {
        query
    };

    let results = if let Some(ref connector_name) = params.connector {
        state.search.search_one(connector_name, &query).await
    } else {
        state.search.search_all(&query).await
    };

    let response: Vec<SearchResultResponse> = results
        .iter()
        .map(|r| SearchResultResponse {
            title: r.title.clone(),
            citation: r.citation.clone(),
            summary: r.summary.clone(),
            url: r.url.clone(),
            source_name: r.source_name.clone(),
            source_level: r.source_level.clone(),
            jurisdiction: r.jurisdiction.clone(),
            date: r.date.clone(),
        })
        .collect();

    Ok(Json(response))
}

/// Resolve the caller's `max_data_level` into a ceiling, refusing anything
/// unparseable.
///
/// Extracted from `kb_search` so the behaviour can be tested without a database.
/// The distinction this function exists to preserve:
///
///  * `None` (parameter absent) -> `T3`, the documented default.
///  * `Some(valid)`             -> that ceiling.
///  * `Some(invalid)`           -> 400. NOT `T3`.
///
/// The last arm is the fix. It used to be `T3`, which meant a typo in a
/// data-classification parameter returned MORE sensitive content than the
/// caller asked for, with a 200 and no warning.
pub(crate) fn resolve_max_data_level(
    requested: Option<&str>,
) -> Result<pacgate_core::DataLevel, ApiError> {
    match requested {
        Some(code) => pacgate_core::DataLevel::from_code(code).ok_or_else(|| {
            ApiError::bad_request(format!(
                "max_data_level '{code}' is not T1|T2|T3|T4; refusing rather than \
                 widening the ceiling to the default"
            ))
        }),
        None => Ok(pacgate_core::DataLevel::T3ProjectSpecific),
    }
}

/// Search the internal knowledge base (RAG) with data classification filtering.
///
/// `GET /api/kb/search?q=keyword&matter_id=<uuid>&top_k=5&max_data_level=T3`
///
/// This endpoint queries the per-matter RAG store (pgvector + tsvector
/// hybrid retrieval) and applies the T1-T4 data classification filter.
/// Only chunks at or below `max_data_level` are returned.
///
/// - T1: shared templates only
/// - T2: templates + restricted seeds
/// - T3: templates + seeds + project-specific files (default)
/// - T4: all, including special sensitive
pub async fn kb_search(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Query(params): Query<KbSearchQueryParams>,
) -> Result<Json<Vec<KbSearchResultResponse>>, ApiError> {
    if params.q.trim().is_empty() {
        return Err(ApiError::bad_request("search query 'q' must not be empty"));
    }

    let matter_id: pacgate_core::MatterId = params
        .matter_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter_id: {e}")))?;

    // Scope to the caller's tenant, like every other matter-scoped handler.
    // Resolving `PACGATE_DEFAULT_TENANT` instead meant a token from tenant A
    // searched tenant B's chunks whenever the deployment was not single-tenant.
    let (tenant_id, _user_id) = crate::documents::claims_to_ids(&claims)?;

    // Build SearchFilter from query params
    let mut filter = pacgate_rag::SearchFilter::new();

    // Default max_data_level is T3 (returns T1+T2+T3, excludes T4).
    //
    // 2026-11-09: this used to be
    //     params.max_data_level.as_deref()
    //         .and_then(DataLevel::from_code)
    //         .unwrap_or(T3)
    // which silently widened an UNPARSEABLE ceiling to T3. A caller asking for
    // T1 who sent a typo received T3 content - the filter failed open, in the
    // one direction that discloses more. An absent parameter still defaults to
    // T3 (that is the documented behaviour); a PRESENT but invalid one is now a
    // 400, because "we did not understand your security parameter" and "you did
    // not send one" are different requests and must not share an answer.
    let max_dl = resolve_max_data_level(params.max_data_level.as_deref())?;
    filter = filter.with_max_data_level(max_dl);

    // Optional jurisdiction filter
    if let Some(ref j) = params.jurisdiction {
        if let Ok(jur) = serde_json::from_value::<pacgate_core::Jurisdiction>(
            serde_json::Value::String(j.clone()),
        ) {
            filter = filter.with_jurisdiction(jur);
        }
    }

    // Optional source level filter
    if let Some(ref sl) = params.source_level {
        if let Ok(src) = serde_json::from_value::<pacgate_core::SourceLevel>(
            serde_json::Value::String(sl.clone()),
        ) {
            filter = filter.with_source_level(src);
        }
    }

    let rag_store = state
        .rag
        .as_ref()
        .ok_or_else(|| ApiError::internal("RAG store not configured (requires Postgres)"))?;

    let top_k = params.top_k.unwrap_or(5);

    let results = rag_store
        .search(&tenant_id, &matter_id, &params.q, top_k, &filter)
        .await
        .map_err(|e| ApiError::internal(format!("RAG search failed: {e}")))?;

    // pgvector returns the `top_k` least-distant chunks for ANY query, so on a
    // populated matter this is never empty - a query sharing no term with the
    // corpus still comes back looking like an answer. Cosine score cannot
    // separate the two on this workload (measured bands overlap by 0.375), so
    // the returned chunks are checked instead: if not one contains a query
    // term, the set is noise and the honest answer is "nothing matched".
    //
    // Returning an empty list here is what makes the caller's `no_match` branch
    // reachable. It cannot drop a real hit: a hit that answers the query
    // contains a query term by construction.
    if pacgate_rag::shares_no_term(&results, &params.q) {
        tracing::debug!(
            matter_id = %matter_id.as_str(),
            query = %params.q,
            "kb_search suppressed {} unrelated neighbour(s)",
            results.len()
        );
        return Ok(Json(Vec::new()));
    }

    let response: Vec<KbSearchResultResponse> = results
        .iter()
        .map(|r| KbSearchResultResponse {
            content: r.content.clone(),
            score: r.score,
            source_doc: r.source_doc.clone(),
            page: r.page,
            // The chunk's own level, not the filter ceiling. Echoing `max_dl`
            // labelled a T1 chunk as T3 whenever the caller widened the filter.
            data_level: r.data_level.code().to_string(),
        })
        .collect();

    Ok(Json(response))
}

/// List all registered data source connectors and their availability.
///
/// `GET /api/search/connectors`
pub async fn list_connectors(
    State(state): State<AppState>,
) -> Result<Json<Vec<ConnectorStatus>>, ApiError> {
    let connectors: Vec<ConnectorStatus> = state
        .search
        .list_connectors()
        .iter()
        .map(|(name, display_name, available)| ConnectorStatus {
            name: name.clone(),
            display_name: display_name.clone(),
            available: *available,
        })
        .collect();

    Ok(Json(connectors))
}

/// List the full connector registry from client assets.
///
/// `GET /api/search/registry`
///
/// Returns all 27 data source entries from 百宸AI系统资源接入清单,
/// including metadata (name, display_name, description, connector_type,
/// url, usage, auth_method, env_var, priority, region, implemented).
/// This is the structured catalog that deer-flow and qm can discover
/// via API to know which databases are available and how to connect.
pub async fn list_registry() -> Result<Json<Vec<pacgate_search::ConnectorMetadata>>, ApiError> {
    let registry = pacgate_search::ConnectorRegistry::from_client_assets();
    Ok(Json(registry.entries().to_vec()))
}

/// List all 9 Chinese-law due diligence agent configs.
///
/// `GET /api/dd-configs`
///
/// Returns the DD agent configs from dd-agents 中国法智能体改写清单.
/// Each config contains focus areas (keep/delete/add), severity rules,
/// Chinese law references, and citation format. Both deer-flow and qm
/// can fetch these to render DD checklists or inject as system prompts.
pub async fn list_dd_configs() -> Result<Json<Vec<pacgate_core::DdAgentConfig>>, ApiError> {
    Ok(Json(pacgate_core::dd_agent_configs()))
}

/// Health check for all data source connectors.
///
/// `GET /api/search/health`
pub async fn search_health(
    State(state): State<AppState>,
) -> Result<Json<Vec<ConnectorStatus>>, ApiError> {
    // For now, return the same info as list_connectors.
    // A full health check would call health_check() on each connector,
    // but that requires async iteration which is better done in a batch.
    let connectors: Vec<ConnectorStatus> = state
        .search
        .list_connectors()
        .iter()
        .map(|(name, display_name, available)| ConnectorStatus {
            name: name.clone(),
            display_name: display_name.clone(),
            available: *available,
        })
        .collect();

    Ok(Json(connectors))
}

#[cfg(test)]
mod gate_tests {
    use super::*;

    /// The handler body, so the assertions below read the code that runs rather
    /// than a restatement of it.
    fn kb_search_source() -> &'static str {
        let src = include_str!("search.rs");
        let start = src
            .find("pub async fn kb_search(")
            .expect("kb_search must exist");
        let rest = &src[start..];
        let end = rest
            .find("pub async fn list_connectors(")
            .expect("list_connectors must follow kb_search");
        &rest[..end]
    }

    #[test]
    fn kb_search_scopes_to_the_callers_tenant() {
        // The regression this guards: kb_search resolved the tenant from
        // PACGATE_DEFAULT_TENANT instead of the JWT, so a token from tenant A
        // searched tenant B's chunks in any multi-tenant deployment.
        let body = kb_search_source();
        assert!(
            body.contains("Extension(claims): Extension<pacgate_auth::Claims>"),
            "kb_search must take the caller's claims"
        );
        assert!(
            body.contains("claims_to_ids(&claims)"),
            "kb_search must derive the tenant from the JWT"
        );
        assert!(
            !body.contains("default_tenant"),
            "kb_search must not fall back to the configured default tenant"
        );
    }

    #[test]
    fn kb_search_reports_the_chunks_own_data_level() {
        // The regression this guards: the response echoed `max_dl` (the filter
        // ceiling), so a T1 chunk returned under max_data_level=T3 was labelled
        // T3 - misstating classification to the review panel and to audit.
        let body = kb_search_source();
        assert!(
            body.contains("r.data_level.code()"),
            "the response must report the chunk's own level"
        );
        assert!(
            !body.contains("data_level: max_dl.code()"),
            "the response must not echo the filter ceiling as the level"
        );
    }

    #[test]
    fn the_tenant_is_resolved_before_the_search_runs() {
        // A scope check that happens after the query has already run is not a
        // scope check. Assert the order, not just the presence.
        let body = kb_search_source();
        let claims_at = body.find("claims_to_ids(&claims)").expect("claims");
        let search_at = body.find(".search(&tenant_id").expect("search call");
        assert!(
            claims_at < search_at,
            "the tenant must be resolved before the search executes"
        );
    }

    #[test]
    fn irrelevant_neighbours_are_suppressed_so_no_match_is_reachable() {
        // The gap this guards (measured 2026-11-09): pgvector returns top_k
        // neighbours for any query, so on a populated matter the list was never
        // empty. The caller's `no_match` branch therefore could not fire, and a
        // gibberish query came back looking like an answer.
        let body = kb_search_source();
        assert!(
            body.contains("shares_no_term(&results"),
            "kb_search must judge the returned chunks before responding"
        );
        // Presence alone is not enough: a guard written `if false && ...` or a
        // guard whose body falls through satisfies a substring check while doing
        // nothing. Assert that the branch RETURNS EMPTY, which is the behaviour
        // that makes the caller's no_match reachable.
        //
        // Anchor on the fully-qualified call: the bare name also appears in this
        // test's own assertion strings, which would slice the wrong region and
        // pass on a broken guard.
        let guard_at = body
            .find("if pacgate_rag::shares_no_term(&results")
            .expect("the guard must be present in kb_search");
        let tail = &body[guard_at..];
        let branch_end = tail.find("let response").expect("response follows the guard");
        let branch = &tail[..branch_end];
        assert!(
            branch.contains("Json(Vec::new())"),
            "the guard must return an empty list, not merely be present: {branch}"
        );
        assert!(
            guard_at < body.find("let response").expect("response"),
            "the relevance check must run before the response is built"
        );
    }

    /// The 2026-11-09 fail-open. `max_data_level` was parsed with
    /// `.and_then(from_code).unwrap_or(T3)`, so a value the server did not
    /// understand was silently replaced by the DEFAULT ceiling: a caller asking
    /// for T1 with a typo received T3 - the filter failed in the one direction
    /// that discloses more, and no error said so.
    ///
    /// This asserts BEHAVIOUR, not source text. A source-scanning version of
    /// this test passed when the fail-open was deliberately reintroduced, so it
    /// was proving nothing.
    #[test]
    fn an_unparseable_max_data_level_is_refused_not_widened_to_the_default() {
        use pacgate_core::DataLevel;

        // Present and invalid: refused, and the message names the bad value.
        //
        // `"T3 "` is deliberately NOT in this list: `from_code` trims, so a
        // trailing space is a valid T3. Being lenient about whitespace in a
        // query parameter is harmless; being lenient about an unrecognised
        // LEVEL is what failed open.
        for bad in ["T9", "t0", "MAX", "3", "T"] {
            let err = resolve_max_data_level(Some(bad))
                .expect_err(&format!("{bad:?} must be refused, never widened"));
            assert_eq!(err.status, axum::http::StatusCode::BAD_REQUEST);
            assert!(
                err.message.contains(bad.trim()),
                "the refusal must name the rejected value so it can be fixed: {}",
                err.message
            );
        }

        // Present and valid: honoured exactly, in both spellings `from_code`
        // accepts. A ceiling of T1 must stay T1.
        assert_eq!(resolve_max_data_level(Some("T1")).unwrap(), DataLevel::T1SharedTemplate);
        assert_eq!(resolve_max_data_level(Some("t1")).unwrap(), DataLevel::T1SharedTemplate);
        assert_eq!(resolve_max_data_level(Some("T4")).unwrap(), DataLevel::T4SpecialSensitive);

        // Absent: the documented default, unchanged.
        assert_eq!(
            resolve_max_data_level(None).unwrap(),
            DataLevel::T3ProjectSpecific,
            "an ABSENT max_data_level must still default to T3"
        );
    }

    /// An invalid level must never resolve to something WIDER than requested.
    ///
    /// Stated separately because it is the property that actually matters: a
    /// refusal and a narrowing are both acceptable outcomes, a widening is not.
    #[test]
    fn an_invalid_level_never_resolves_to_a_wider_ceiling() {
        for bad in ["T9", "", "T1000"] {
            match resolve_max_data_level(Some(bad)) {
                Err(_) => {}
                Ok(dl) => panic!(
                    "{bad:?} resolved to {dl:?}; an unrecognised ceiling must not \
                     fall back to a classification the caller did not request"
                ),
            }
        }
    }

    /// `data_level` on EXTERNAL search was validated, logged, and discarded:
    /// `SearchQuery` has no data-level field, so nothing filtered. Accepting it
    /// was a false compliance signal - a caller sending T2 read the response as
    /// "filtered to T2". It is now a 400 until a connector can honour it.
    #[test]
    fn external_search_refuses_data_level_instead_of_accepting_and_ignoring_it() {
        let src = include_str!("search.rs");
        let start = src.find("pub async fn search(").expect("search must exist");
        let rest = &src[start..];
        let end = rest
            .find("pub async fn kb_search(")
            .expect("kb_search must follow");
        let body = &rest[..end];

        assert!(
            body.contains("data_level is not supported on external search"),
            "external search must refuse the parameter it cannot honour"
        );
        assert!(
            !body.contains("not filtered"),
            "the accept-and-discard behaviour must be gone, not reworded"
        );
    }
}
