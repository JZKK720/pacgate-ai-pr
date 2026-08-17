//! Legal search API handlers — query external legal databases via SearchRouter.

use axum::{
    extract::{Query, State},
    Json,
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
    /// When set, results are tagged with this level for downstream filtering.
    /// External connectors don't filter by data_level yet, but the metadata
    /// is passed through for audit and future connector-level enforcement.
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
/// `GET /api/search?q=keyword&connector=courtlistener&data_level=T2`
///
/// The `data_level` parameter (T1-T4) tags the search request with a data
/// classification level. External connectors don't filter by it yet, but
/// the metadata is available for audit logging and future enforcement.
pub async fn search(
    State(state): State<AppState>,
    Query(params): Query<SearchQueryParams>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    if params.q.trim().is_empty() {
        return Err(ApiError::bad_request("search query 'q' must not be empty"));
    }

    // Validate data_level if provided
    if let Some(ref dl) = params.data_level {
        if pacgate_core::DataLevel::from_code(dl).is_none() {
            return Err(ApiError::bad_request(
                "data_level must be one of: T1, T2, T3, T4",
            ));
        }
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

    if let Some(ref dl) = params.data_level {
        tracing::info!(
            "external search with data_level={} (tagged for audit, not filtered)",
            dl
        );
    }

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
    Query(params): Query<KbSearchQueryParams>,
) -> Result<Json<Vec<KbSearchResultResponse>>, ApiError> {
    if params.q.trim().is_empty() {
        return Err(ApiError::bad_request("search query 'q' must not be empty"));
    }

    let matter_id: pacgate_core::MatterId = params
        .matter_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter_id: {e}")))?;

    // Build SearchFilter from query params
    let mut filter = pacgate_rag::SearchFilter::new();

    // Default max_data_level is T3 (returns T1+T2+T3, excludes T4)
    let max_dl = params
        .max_data_level
        .as_deref()
        .and_then(pacgate_core::DataLevel::from_code)
        .unwrap_or(pacgate_core::DataLevel::T3ProjectSpecific);
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

    // Use default tenant for now (single-tenant pilot)
    let tenant_id = pacgate_core::TenantId(
        uuid::Uuid::parse_str(&state.config.default_tenant).unwrap_or_else(|_| uuid::Uuid::nil()),
    );

    let rag_store = state
        .rag
        .as_ref()
        .ok_or_else(|| ApiError::internal("RAG store not configured (requires Postgres)"))?;

    let top_k = params.top_k.unwrap_or(5);

    let results = rag_store
        .search(&tenant_id, &matter_id, &params.q, top_k, &filter)
        .await
        .map_err(|e| ApiError::internal(format!("RAG search failed: {e}")))?;

    let response: Vec<KbSearchResultResponse> = results
        .iter()
        .map(|r| KbSearchResultResponse {
            content: r.content.clone(),
            score: r.score,
            source_doc: r.source_doc.clone(),
            page: r.page,
            data_level: max_dl.code().to_string(),
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
