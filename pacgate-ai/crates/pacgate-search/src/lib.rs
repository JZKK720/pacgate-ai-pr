//! pacgate-search — Legal search and data source connectors.
//!
//! Provides a trait-based abstraction for querying external legal databases.
//! The A4 Research Agent uses these connectors to search for legal authority
//! across multiple Chinese and international databases.
//!
//! ## Supported connectors
//!
//! | Connector | Type | Access | Status |
//! |-----------|------|--------|--------|
//! | `YuanDianConnector` | Chinese legal database (元典) | MCP endpoint | Active (needs API key) |
//! | `PkuLawConnector` | Chinese legal database (北大法宝) | MCP endpoint | Active (needs API key) |
//! | `QccConnector` | Corporate registry (企查查) | MCP endpoint | Active (needs API key) |
//! | `FyOpenConnector` | Chinese legal database (法源开) | REST API | Active (needs API key) |
//! | `CourtListenerConnector` | US case law | REST API | Active (free) |
//! | `SecEdgarConnector` | US SEC filings | REST API (free) | Active |
//! | `GleifConnector` | Global LEI registry | REST API (free) | Active |
//!
//! ## Architecture
//!
//! ```text
//! Agent (A4 Research) → SearchRouter → DataSourceConnector::search()
//!                                            ↓
//!                              [YuanDian] [PkuLaw] [CourtListener] ...
//!                                            ↓
//!                              Vec<SearchResult> (with source_level tagging)
//! ```

#![allow(dead_code)]

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Search result types
// ─────────────────────────────────────────────────────────────────────────────

/// A single search result from an external legal database.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// Title of the law, case, or document
    pub title:       String,
    /// Citation or reference number (e.g., "(2023)沪01民终123号")
    pub citation:    Option<String>,
    /// Summary or snippet of the content
    pub summary:     String,
    /// Source URL or document link
    pub url:         Option<String>,
    /// Which database this result came from
    pub source_name: String,
    /// Source level (from pacgate-core) — authority_verified, auxiliary_db, etc.
    pub source_level: String,
    /// Jurisdiction this result applies to
    pub jurisdiction: Option<String>,
    /// Publication or effective date (ISO 8601)
    pub date:        Option<String>,
    /// Raw metadata from the source
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata:    Option<serde_json::Value>,
}

/// Search query parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchQuery {
    /// Search keywords
    pub keywords:    String,
    /// Optional jurisdiction filter
    pub jurisdiction: Option<String>,
    /// Optional document type filter (law, case, regulation, etc.)
    pub doc_type:    Option<String>,
    /// Maximum results to return
    pub limit:       u32,
}

impl Default for SearchQuery {
    fn default() -> Self {
        Self {
            keywords:    String::new(),
            jurisdiction: None,
            doc_type:    None,
            limit:       10,
        }
    }
}

impl SearchQuery {
    pub fn new(keywords: impl Into<String>) -> Self {
        Self {
            keywords: keywords.into(),
            ..Default::default()
        }
    }

    pub fn with_jurisdiction(mut self, j: impl Into<String>) -> Self {
        self.jurisdiction = Some(j.into());
        self
    }

    pub fn with_doc_type(mut self, t: impl Into<String>) -> Self {
        self.doc_type = Some(t.into());
        self
    }

    pub fn with_limit(mut self, n: u32) -> Self {
        self.limit = n;
        self
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Connector trait
// ─────────────────────────────────────────────────────────────────────────────

/// Error type for data source connector operations.
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("connection error: {0}")]
    Connection(String),

    #[error("authentication error: {0}")]
    Auth(String),

    #[error("rate limited by source: {0}")]
    RateLimited(String),

    #[error("parse error: {0}")]
    Parse(String),

    #[error("source unavailable: {0}")]
    Unavailable(String),
}

/// Trait for external legal database connectors.
///
/// Each connector wraps a specific database's API (REST, MCP, or scrape).
/// Implementations should:
/// - Tag results with the correct `source_level` (from pacgate-core)
/// - Handle auth, rate limiting, and error recovery
/// - Never fabricate results — return empty Vec on failure
#[async_trait]
pub trait DataSourceConnector: Send + Sync {
    /// Unique name for this connector (e.g., "yuandian", "courtlistener")
    fn name(&self) -> &str;

    /// Human-readable display name (e.g., "元典法律数据库", "CourtListener")
    fn display_name(&self) -> &str;

    /// Whether this connector is currently available (has valid credentials, etc.)
    fn is_available(&self) -> bool;

    /// Search the database.
    ///
    /// Returns results tagged with source_level and source_name.
    /// On error, logs and returns empty Vec (does not propagate errors to caller).
    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult>;

    /// Test connectivity to the source.
    async fn health_check(&self) -> Result<(), SearchError>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Search router — aggregates multiple connectors
// ─────────────────────────────────────────────────────────────────────────────

use std::sync::Arc;

/// Aggregates multiple data source connectors and routes searches to all of them.
///
/// The A4 Research Agent uses this to search across all available databases
/// in a single call. Results are merged and sorted by source_level priority.
pub struct SearchRouter {
    connectors: Vec<Arc<dyn DataSourceConnector>>,
}

impl SearchRouter {
    pub fn new() -> Self {
        Self { connectors: Vec::new() }
    }

    pub fn with_connector(mut self, connector: Arc<dyn DataSourceConnector>) -> Self {
        self.connectors.push(connector);
        self
    }

    pub fn add_connector(&mut self, connector: Arc<dyn DataSourceConnector>) {
        self.connectors.push(connector);
    }

    /// List all registered connectors.
    pub fn list_connectors(&self) -> Vec<(String, String, bool)> {
        self.connectors
            .iter()
            .map(|c| (c.name().to_string(), c.display_name().to_string(), c.is_available()))
            .collect()
    }

    /// Search all available connectors and merge results.
    ///
    /// Failed connectors are logged and skipped — partial results are returned.
    pub async fn search_all(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let mut all_results = Vec::new();

        for connector in &self.connectors {
            if !connector.is_available() {
                tracing::debug!(connector = connector.name(), "skipping unavailable connector");
                continue;
            }

            let results = connector.search(query).await;
            tracing::info!(
                connector = connector.name(),
                results = results.len(),
                "connector returned results"
            );
            all_results.extend(results);
        }

        // Sort by source_level priority (authority_verified > auxiliary_db > internal_template > model_inference)
        all_results.sort_by(|a, b| {
            source_level_priority(&a.source_level).cmp(&source_level_priority(&b.source_level))
        });

        all_results
    }

    /// Search a specific connector by name.
    pub async fn search_one(&self, connector_name: &str, query: &SearchQuery) -> Vec<SearchResult> {
        match self.connectors.iter().find(|c| c.name() == connector_name) {
            Some(c) => c.search(query).await,
            None => Vec::new(),
        }
    }
}

impl Default for SearchRouter {
    fn default() -> Self {
        Self::new()
    }
}

fn source_level_priority(level: &str) -> u8 {
    match level {
        "authority_verified" => 0,
        "auxiliary_db" => 1,
        "internal_template" => 2,
        "model_inference" => 3,
        _ => 4,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Chinese connectors — MCP endpoints
// ─────────────────────────────────────────────────────────────────────────────

/// YuanDian (元典) — Chinese legal database via MCP endpoint.
/// URL: https://open.chineselaw.com
/// Auth: API key (env: YUANDIAN_API_KEY)
///
/// The endpoint exposes an MCP-style search API. We send a JSON-RPC style
/// request with the search keywords and jurisdiction filter, then parse
/// the response into SearchResult items.
pub struct YuanDianConnector {
    endpoint: String,
    api_key:  Option<String>,
    client:   reqwest::Client,
}

impl YuanDianConnector {
    pub fn new(endpoint: impl Into<String>, api_key: Option<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            api_key,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }
}

#[async_trait]
impl DataSourceConnector for YuanDianConnector {
    fn name(&self) -> &str { "yuandian" }
    fn display_name(&self) -> &str { "元典法律数据库" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k.clone(),
            None => {
                tracing::debug!(connector = self.name(), "no API key configured");
                return Vec::new();
            }
        };

        // MCP-style JSON-RPC request
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "search",
            "params": {
                "query": &query.keywords,
                "jurisdiction": query.jurisdiction.as_deref().unwrap_or("CN"),
                "doc_type": query.doc_type.as_deref().unwrap_or("all"),
                "limit": query.limit,
            },
            "id": 1
        });

        let url = format!("{}/api/search", self.endpoint.trim_end_matches('/'));
        let req = self.client
            .post(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Content-Type", "application/json")
            .json(&body);

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| {
                        json.get("result")?.as_array().map(|arr| {
                            arr.iter().filter_map(|item| {
                                Some(SearchResult {
                                    title:       item.get("title")?.as_str()?.to_string(),
                                    citation:    item.get("citation")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    summary:     item.get("summary")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                    url:         item.get("url")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    source_name: "yuandian".to_string(),
                                    source_level: "auxiliary_db".to_string(),
                                    jurisdiction: Some("ChinaMainland".to_string()),
                                    date:        item.get("date")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    metadata:    Some(item.clone()),
                                })
                            }).collect()
                        })
                    })
                    .unwrap_or_default()
            }
            Ok(resp) => {
                tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "yuandian request failed");
                Vec::new()
            }
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "yuandian connection error");
                Vec::new()
            }
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        let api_key = self.api_key.as_ref()
            .ok_or_else(|| SearchError::Auth("no API key configured".into()))?;
        let url = format!("{}/api/health", self.endpoint.trim_end_matches('/'));
        match self.client.get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .send().await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// PkuLaw (北大法宝) — Chinese legal database via MCP endpoint.
/// URL: https://mcp.pkulaw.com
/// Auth: API key (env: PKULAW_API_KEY)
pub struct PkuLawConnector {
    endpoint: String,
    api_key:  Option<String>,
    client:   reqwest::Client,
}

impl PkuLawConnector {
    pub fn new(endpoint: impl Into<String>, api_key: Option<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            api_key,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }
}

#[async_trait]
impl DataSourceConnector for PkuLawConnector {
    fn name(&self) -> &str { "pkulaw" }
    fn display_name(&self) -> &str { "北大法宝" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k.clone(),
            None => {
                tracing::debug!(connector = self.name(), "no API key configured");
                return Vec::new();
            }
        };

        // MCP-style JSON-RPC request
        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "method": "search",
            "params": {
                "query": &query.keywords,
                "jurisdiction": query.jurisdiction.as_deref().unwrap_or("CN"),
                "doc_type": query.doc_type.as_deref().unwrap_or("all"),
                "limit": query.limit,
            },
            "id": 1
        });

        let url = format!("{}/api/search", self.endpoint.trim_end_matches('/'));
        let req = self.client
            .post(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Content-Type", "application/json")
            .json(&body);

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| {
                        json.get("result")?.as_array().map(|arr| {
                            arr.iter().filter_map(|item| {
                                Some(SearchResult {
                                    title:       item.get("title")?.as_str()?.to_string(),
                                    citation:    item.get("citation")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    summary:     item.get("summary")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                    url:         item.get("url")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    source_name: "pkulaw".to_string(),
                                    source_level: "auxiliary_db".to_string(),
                                    jurisdiction: Some("ChinaMainland".to_string()),
                                    date:        item.get("date")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    metadata:    Some(item.clone()),
                                })
                            }).collect()
                        })
                    })
                    .unwrap_or_default()
            }
            Ok(resp) => {
                tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "pkulaw request failed");
                Vec::new()
            }
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "pkulaw connection error");
                Vec::new()
            }
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        let api_key = self.api_key.as_ref()
            .ok_or_else(|| SearchError::Auth("no API key configured".into()))?;
        let url = format!("{}/api/health", self.endpoint.trim_end_matches('/'));
        match self.client.get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .send().await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// Qcc (企查查) — Chinese corporate registry via MCP endpoint.
/// URL: https://agent.qcc.com
/// Auth: API key (env: QCC_API_KEY)
///
/// Provides company information, shareholder structures, legal proceedings,
/// and corporate registration data.
pub struct QccConnector {
    endpoint: String,
    api_key:  Option<String>,
    client:   reqwest::Client,
}

impl QccConnector {
    pub fn new(endpoint: impl Into<String>, api_key: Option<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            api_key,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }
}

#[async_trait]
impl DataSourceConnector for QccConnector {
    fn name(&self) -> &str { "qcc" }
    fn display_name(&self) -> &str { "企查查" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k.clone(),
            None => {
                tracing::debug!(connector = self.name(), "no API key configured");
                return Vec::new();
            }
        };

        // Agent-style API request — search companies by keyword
        let url = format!(
            "{}/api/search?keyword={}&limit={}",
            self.endpoint.trim_end_matches('/'),
            urlencoding::encode(&query.keywords),
            query.limit
        );
        let req = self.client
            .get(&url)
            .header("Authorization", format!("Bearer {api_key}"));

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| {
                        json.get("data")?.as_array().map(|arr| {
                            arr.iter().filter_map(|item| {
                                Some(SearchResult {
                                    title:       item.get("name")?.as_str()?.to_string(),
                                    citation:    item.get("creditNo")
                                        .or_else(|| item.get("uscc"))
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    summary:     item.get("operatingScope")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                    url:         item.get("detailUrl")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    source_name: "qcc".to_string(),
                                    source_level: "auxiliary_db".to_string(),
                                    jurisdiction: Some("ChinaMainland".to_string()),
                                    date:        item.get("establishDate")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    metadata:    Some(item.clone()),
                                })
                            }).collect()
                        })
                    })
                    .unwrap_or_default()
            }
            Ok(resp) => {
                tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "qcc request failed");
                Vec::new()
            }
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "qcc connection error");
                Vec::new()
            }
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        let api_key = self.api_key.as_ref()
            .ok_or_else(|| SearchError::Auth("no API key configured".into()))?;
        let url = format!("{}/api/health", self.endpoint.trim_end_matches('/'));
        match self.client.get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .send().await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// FYOpen (法源开) — Chinese legal database.
/// URL: https://www.fyopen.com/index
/// Auth: Account-based login (env: FYOPEN_API_KEY)
///
/// Additional Chinese database found in client assets (境外法律数据库和网站.md).
pub struct FyOpenConnector {
    endpoint: String,
    api_key:  Option<String>,
    client:   reqwest::Client,
}

impl FyOpenConnector {
    pub fn new(endpoint: impl Into<String>, api_key: Option<String>) -> Self {
        Self {
            endpoint: endpoint.into(),
            api_key,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }

    pub fn with_default_endpoint(api_key: Option<String>) -> Self {
        Self::new("https://www.fyopen.com", api_key)
    }
}

#[async_trait]
impl DataSourceConnector for FyOpenConnector {
    fn name(&self) -> &str { "fyopen" }
    fn display_name(&self) -> &str { "法源开" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k.clone(),
            None => {
                tracing::debug!(connector = self.name(), "no API key configured");
                return Vec::new();
            }
        };

        let url = format!(
            "{}/api/search?q={}&limit={}",
            self.endpoint.trim_end_matches('/'),
            urlencoding::encode(&query.keywords),
            query.limit
        );
        let req = self.client
            .get(&url)
            .header("Authorization", format!("Bearer {api_key}"));

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| {
                        json.get("results")?.as_array().map(|arr| {
                            arr.iter().filter_map(|item| {
                                Some(SearchResult {
                                    title:       item.get("title")?.as_str()?.to_string(),
                                    citation:    item.get("citation")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    summary:     item.get("summary")
                                        .and_then(|v| v.as_str())
                                        .unwrap_or("")
                                        .to_string(),
                                    url:         item.get("url")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    source_name: "fyopen".to_string(),
                                    source_level: "auxiliary_db".to_string(),
                                    jurisdiction: Some("ChinaMainland".to_string()),
                                    date:        item.get("date")
                                        .and_then(|v| v.as_str())
                                        .map(String::from),
                                    metadata:    Some(item.clone()),
                                })
                            }).collect()
                        })
                    })
                    .unwrap_or_default()
            }
            Ok(resp) => {
                tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "fyopen request failed");
                Vec::new()
            }
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "fyopen connection error");
                Vec::new()
            }
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        let api_key = self.api_key.as_ref()
            .ok_or_else(|| SearchError::Auth("no API key configured".into()))?;
        let url = format!("{}/api/health", self.endpoint.trim_end_matches('/'));
        match self.client.get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .send().await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active connectors — free international APIs
// ─────────────────────────────────────────────────────────────────────────────

/// CourtListener — US case law database (free API).
/// URL: https://www.courtlistener.com
pub struct CourtListenerConnector {
    api_key: Option<String>,
    client:  reqwest::Client,
}

impl CourtListenerConnector {
    pub fn new(api_key: Option<String>) -> Self {
        Self {
            api_key,
            client: reqwest::Client::builder()
                .user_agent("Pacgate-AI/0.1 (pacgate.ai01@outlook.com)")
                .build()
                .unwrap_or_default(),
        }
    }
}

#[async_trait]
impl DataSourceConnector for CourtListenerConnector {
    fn name(&self) -> &str { "courtlistener" }
    fn display_name(&self) -> &str { "CourtListener (US Case Law)" }
    fn is_available(&self) -> bool { true }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let url = format!(
            "https://www.courtlistener.com/api/rest/v4/search/?q={}&count={}",
            urlencoding::encode(&query.keywords),
            query.limit
        );

        let mut req = self.client.get(&url);
        if let Some(ref key) = self.api_key {
            req = req.header("Authorization", format!("Token {key}"));
        }

        match req.send().await {
            Ok(resp) if resp.status().is_success() => {
                match resp.json::<serde_json::Value>().await {
                    Ok(json) => {
                        json.get("results")
                            .and_then(|r| r.as_array())
                            .map(|arr| {
                                arr.iter().filter_map(|item| {
                                    Some(SearchResult {
                                        title:       item.get("caseName")?.as_str()?.to_string(),
                                        citation:    item.get("citation")
                                            .and_then(|v| v.as_array())
                                            .and_then(|a| a.first())
                                            .and_then(|c| c.get("cite"))
                                            .and_then(|v| v.as_str())
                                            .map(String::from),
                                        summary:     item.get("snippet")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                        url:         item.get("absolute_url")
                                            .and_then(|v| v.as_str())
                                            .map(|u| format!("https://www.courtlistener.com{u}")),
                                        source_name: "courtlistener".to_string(),
                                        source_level: "auxiliary_db".to_string(),
                                        jurisdiction: Some("UnitedStates".to_string()),
                                        date:        item.get("dateFiled")
                                            .and_then(|v| v.as_str())
                                            .map(String::from),
                                        metadata:    Some(item.clone()),
                                    })
                                }).collect()
                            })
                            .unwrap_or_default()
                    }
                    Err(e) => {
                        tracing::warn!(connector = self.name(), error = %e, "parse error");
                        Vec::new()
                    }
                }
            }
            Ok(resp) => {
                tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "request failed");
                Vec::new()
            }
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "connection error");
                Vec::new()
            }
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        match self.client.get("https://www.courtlistener.com/api/rest/v4/").send().await {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// SEC EDGAR — US SEC filings (free API, no key required).
pub struct SecEdgarConnector {
    client: reqwest::Client,
}

impl SecEdgarConnector {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .user_agent("Pacgate-AI/0.1 pacgate.ai01@outlook.com")
                .build()
                .unwrap_or_default(),
        }
    }
}

impl Default for SecEdgarConnector {
    fn default() -> Self { Self::new() }
}

#[async_trait]
impl DataSourceConnector for SecEdgarConnector {
    fn name(&self) -> &str { "sec_edgar" }
    fn display_name(&self) -> &str { "SEC EDGAR (US Filings)" }
    fn is_available(&self) -> bool { true }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let url = format!(
            "https://efts.sec.gov/LATEST/search-index?q={}",
            urlencoding::encode(&query.keywords)
        );

        match self.client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| json.get("hits")?.get("hits")?.as_array().map(|arr| {
                        arr.iter().filter_map(|hit| {
                            let source = hit.get("_source")?;
                            Some(SearchResult {
                                title:       source.get("display_names")
                                    .and_then(|v| v.as_array())
                                    .and_then(|a| a.first())
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("SEC Filing")
                                    .to_string(),
                                citation:    source.get("adsh").and_then(|v| v.as_str()).map(String::from),
                                summary:     source.get("form_type").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                                url:         None,
                                source_name: "sec_edgar".to_string(),
                                source_level: "auxiliary_db".to_string(),
                                jurisdiction: Some("UnitedStates".to_string()),
                                date:        source.get("file_date").and_then(|v| v.as_str()).map(String::from),
                                metadata:    Some(hit.clone()),
                            })
                        }).collect()
                    }))
                    .unwrap_or_default()
            }
            _ => Vec::new(),
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        match self.client.get("https://efts.sec.gov/LATEST/search-index?q=test").send().await {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// GLEIF — Global LEI Registry (free API, no key required).
pub struct GleifConnector {
    client: reqwest::Client,
}

impl GleifConnector {
    pub fn new() -> Self {
        Self { client: reqwest::Client::new() }
    }
}

impl Default for GleifConnector {
    fn default() -> Self { Self::new() }
}

#[async_trait]
impl DataSourceConnector for GleifConnector {
    fn name(&self) -> &str { "gleif" }
    fn display_name(&self) -> &str { "GLEIF (Global LEI Registry)" }
    fn is_available(&self) -> bool { true }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let url = format!(
            "https://api.gleif.org/api/v1/lei-records?filter[entity.legalName]={}&page[size]={}",
            urlencoding::encode(&query.keywords),
            query.limit
        );

        match self.client.get(&url)
            .header("Accept", "application/vnd.api+json")
            .send().await
        {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>().await
                    .ok()
                    .and_then(|json| json.get("data")?.as_array().map(|arr| {
                        arr.iter().filter_map(|item| {
                            let attrs = item.get("attributes")?;
                            let legal_name = attrs.get("entity")?.get("legalName")?.get("name")?.as_str()?;
                            Some(SearchResult {
                                title:       legal_name.to_string(),
                                citation:    item.get("id").and_then(|v| v.as_str()).map(String::from),
                                summary:     attrs.get("entity")
                                    .and_then(|e| e.get("legalAddress"))
                                    .and_then(|a| a.get("country"))
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                                url:         item.get("links").and_then(|l| l.get("self")).and_then(|v| v.as_str()).map(String::from),
                                source_name: "gleif".to_string(),
                                source_level: "auxiliary_db".to_string(),
                                jurisdiction: attrs.get("entity")
                                    .and_then(|e| e.get("legalAddress"))
                                    .and_then(|a| a.get("country"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                date:        attrs.get("registration")
                                    .and_then(|r| r.get("initialRegistrationDate"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                metadata:    Some(item.clone()),
                            })
                        }).collect()
                    }))
                    .unwrap_or_default()
            }
            _ => Vec::new(),
        }
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        match self.client.get("https://api.gleif.org/api/v1/lei-records?page[size]=1").send().await {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// Create a default SearchRouter with all connectors.
/// Chinese connectors need API keys (env vars: YUANDIAN_API_KEY, PKULAW_API_KEY, QCC_API_KEY, FYOPEN_API_KEY).
/// Free international connectors (CourtListener, SEC EDGAR, GLEIF) are always active.
pub fn default_router() -> SearchRouter {
    SearchRouter::new()
        .with_connector(Arc::new(YuanDianConnector::new(
            "https://open.chineselaw.com",
            std::env::var("YUANDIAN_API_KEY").ok(),
        )))
        .with_connector(Arc::new(PkuLawConnector::new(
            "https://mcp.pkulaw.com",
            std::env::var("PKULAW_API_KEY").ok(),
        )))
        .with_connector(Arc::new(QccConnector::new(
            "https://agent.qcc.com",
            std::env::var("QCC_API_KEY").ok(),
        )))
        .with_connector(Arc::new(FyOpenConnector::with_default_endpoint(
            std::env::var("FYOPEN_API_KEY").ok(),
        )))
        .with_connector(Arc::new(CourtListenerConnector::new(
            std::env::var("COURTLISTENER_API_KEY").ok(),
        )))
        .with_connector(Arc::new(SecEdgarConnector::new()))
        .with_connector(Arc::new(GleifConnector::new()))
}