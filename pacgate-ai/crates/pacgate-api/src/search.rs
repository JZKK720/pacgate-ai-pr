//! Legal search API handlers — query external legal databases via SearchRouter.

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

/// Query parameters for the search endpoint.
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
/// `GET /api/search?q=keyword&connector=courtlistener`
pub async fn search(
    State(state): State<AppState>,
    Query(params): Query<SearchQueryParams>,
) -> Result<Json<Vec<SearchResultResponse>>, ApiError> {
    if params.q.trim().is_empty() {
        return Err(ApiError::bad_request("search query 'q' must not be empty"));
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
