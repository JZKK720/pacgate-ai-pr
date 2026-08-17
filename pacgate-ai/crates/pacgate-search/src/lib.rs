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
// Connector registry — structured resource metadata from 百宸AI系统资源接入清单
// ─────────────────────────────────────────────────────────────────────────────

/// Priority tier for resource onboarding (from the client's resource list).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ConnectorPriority {
    /// 优先接入 — first-phase critical connectors
    #[default]
    Priority,
    /// 待评估 — needs evaluation before onboarding
    Evaluate,
    /// 采购评估 — commercial procurement evaluation
    Procurement,
    /// 自建 — self-built internal resource
    SelfBuilt,
    /// 免费可接 — free, can be connected immediately
    FreeAvailable,
    /// 备选 — backup/redundancy option
    Backup,
}

/// Geographic/jurisdictional category for connector grouping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectorRegion {
    /// Chinese legal databases (元典, 北大法宝, 企查查, etc.)
    ChinaMainland,
    /// US legal databases (CourtListener, SEC EDGAR, Vaquill, etc.)
    UnitedStates,
    /// EU/European databases (EUR-Lex, Ansvar, CURIA, etc.)
    Europe,
    /// Hong Kong legal databases
    HongKong,
    /// Singapore legal databases
    Singapore,
    /// Global/multi-jurisdiction databases (vLex, JusMundi, WorldLII, etc.)
    Global,
    /// Offshore jurisdiction databases (BVI, Cayman, OpenCorporates, etc.)
    Offshore,
    /// Internal firm resources (knowledge bases, template libraries)
    Internal,
}

/// Structured metadata for a registered data source connector.
///
/// From 百宸AI系统资源接入清单 v1/v2 — maps each external resource to its
/// connector implementation, endpoint, auth method, priority, and status.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectorMetadata {
    /// Unique connector name (matches `DataSourceConnector::name()`)
    pub name: String,
    /// Human-readable display name (Chinese or English)
    pub display_name: String,
    /// Brief description of the resource
    pub description: String,
    /// Connector type: "MCP", "API", "网页", "MCP / API", etc.
    pub connector_type: String,
    /// Base URL or endpoint
    pub url: String,
    /// How to use / access method (from the resource list)
    pub usage: String,
    /// Auth method: "bearer_token", "api_key", "free", "account_login", "none"
    pub auth_method: String,
    /// Environment variable name for the API key (if applicable)
    pub env_var: Option<String>,
    /// Priority tier for onboarding
    pub priority: ConnectorPriority,
    /// Geographic region
    pub region: ConnectorRegion,
    /// Whether this connector is currently implemented in code
    pub implemented: bool,
}

/// The connector registry — a structured catalog of all legal data sources
/// from the client's resource onboarding list.
///
/// This replaces ad-hoc env var lookups with a formal registry that the API
/// can expose via `GET /api/search/registry`.
pub struct ConnectorRegistry {
    entries: Vec<ConnectorMetadata>,
}

impl ConnectorRegistry {
    pub fn new() -> Self {
        Self { entries: Vec::new() }
    }

    pub fn with_entry(mut self, entry: ConnectorMetadata) -> Self {
        self.entries.push(entry);
        self
    }

    pub fn entries(&self) -> &[ConnectorMetadata] {
        &self.entries
    }

    /// Filter by region
    pub fn by_region(&self, region: ConnectorRegion) -> Vec<&ConnectorMetadata> {
        self.entries.iter().filter(|e| e.region == region).collect()
    }

    /// Filter by priority
    pub fn by_priority(&self, priority: ConnectorPriority) -> Vec<&ConnectorMetadata> {
        self.entries.iter().filter(|e| e.priority == priority).collect()
    }

    /// Only implemented connectors
    pub fn implemented(&self) -> Vec<&ConnectorMetadata> {
        self.entries.iter().filter(|e| e.implemented).collect()
    }

    /// Only connectors needing API keys (not yet available)
    pub fn needs_credentials(&self) -> Vec<&ConnectorMetadata> {
        self.entries.iter().filter(|e| !e.implemented && e.auth_method != "free" && e.auth_method != "none").collect()
    }

    /// Get the total count
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

impl Default for ConnectorRegistry {
    fn default() -> Self {
        Self::from_client_assets()
    }
}

impl ConnectorRegistry {
    /// Build the registry from the client's resource onboarding list
    /// (百宸AI系统资源接入清单 v1/v2 + 境外法律数据库和网站).
    pub fn from_client_assets() -> Self {
        Self::new()
            // ── Chinese legal databases (MCP/API) ──
            .with_entry(ConnectorMetadata {
                name: "yuandian".into(),
                display_name: "元典法律数据库".into(),
                description: "元典智库法律开放平台，提供法律幻觉核验、法规检索、企业信息聚合".into(),
                connector_type: "MCP / API".into(),
                url: "open.chineselaw.com".into(),
                usage: "注册开放平台账号→申请 API Key→按 MCP 配置接入".into(),
                auth_method: "api_key".into(),
                env_var: Some("YUANDIAN_API_KEY".into()),
                priority: ConnectorPriority::Priority,
                region: ConnectorRegion::ChinaMainland,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "pkulaw".into(),
                display_name: "北大法宝".into(),
                description: "国内权威法律法规、司法案例、专题/期刊数据库，MCP 法规语义检索".into(),
                connector_type: "MCP / API".into(),
                url: "mcp.pkulaw.com".into(),
                usage: "采购机构授权→获取 Bearer Token→MCP 网关接入".into(),
                auth_method: "bearer_token".into(),
                env_var: Some("PKULAW_API_KEY".into()),
                priority: ConnectorPriority::Priority,
                region: ConnectorRegion::ChinaMainland,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "qcc".into(),
                display_name: "企查查".into(),
                description: "全国3.5亿+市场主体，300+数据维度：工商、股东、司法涉诉、经营风险".into(),
                connector_type: "API".into(),
                url: "openapi.qcc.com".into(),
                usage: "注册开放平台→实名认证→获取 AppKey+SecretKey→Token 鉴权".into(),
                auth_method: "api_key".into(),
                env_var: Some("QCC_API_KEY".into()),
                priority: ConnectorPriority::Priority,
                region: ConnectorRegion::ChinaMainland,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "fyopen".into(),
                display_name: "法源开".into(),
                description: "中国法律数据库，有免费额度，需充值".into(),
                connector_type: "API".into(),
                url: "www.fyopen.com".into(),
                usage: "注册账号→验证码登录→API 调用".into(),
                auth_method: "api_key".into(),
                env_var: Some("FYOPEN_API_KEY".into()),
                priority: ConnectorPriority::Priority,
                region: ConnectorRegion::ChinaMainland,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "wolters_kluwer".into(),
                display_name: "威科先行".into(),
                description: "威科先行法律信息库：法规、案例、实务内容、英文翻译版法规".into(),
                connector_type: "网页 / API(洽谈)".into(),
                url: "law.wkinfo.com.cn".into(),
                usage: "机构订阅账号登录；API/数据对接需与销售洽谈".into(),
                auth_method: "account_login".into(),
                env_var: None,
                priority: ConnectorPriority::Evaluate,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "faxin".into(),
                display_name: "法信".into(),
                description: "最高人民法院主管法律应用平台，权威裁判规则、案例、法律知识库".into(),
                connector_type: "网页 / API(待确认)".into(),
                url: "faxin.cn".into(),
                usage: "机构订阅；是否提供开放接口需与官方确认".into(),
                auth_method: "account_login".into(),
                env_var: None,
                priority: ConnectorPriority::Evaluate,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "npc_law_db".into(),
                display_name: "国家法律法规数据库".into(),
                description: "官方现行有效的法律、行政法规、地方性法规、司法解释，权威且免费".into(),
                connector_type: "网页 / 检索接口".into(),
                url: "flk.npc.gov.cn".into(),
                usage: "网页检索；可定向抓取/对接（注意官方使用条款）".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "wenshu_court".into(),
                display_name: "中国裁判文书网".into(),
                description: "官方裁判文书库，量大权威；近年公众访问与批量获取有所收紧".into(),
                connector_type: "网页(接口受限)".into(),
                url: "wenshu.court.gov.cn".into(),
                usage: "网页检索为主；批量需评估合规与可得性".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "tianyancha".into(),
                display_name: "天眼查".into(),
                description: "企业工商与风险数据 API，覆盖度与企查查相近，可作冗余/交叉校验源".into(),
                connector_type: "API".into(),
                url: "open.tianyancha.com".into(),
                usage: "注册开放平台→申请 Token→REST 调用".into(),
                auth_method: "api_key".into(),
                env_var: Some("TIANYANCHA_API_KEY".into()),
                priority: ConnectorPriority::Backup,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "qixin".into(),
                display_name: "启信宝".into(),
                description: "合合信息旗下企业征信/工商数据 API，金融与尽调场景常用".into(),
                connector_type: "API".into(),
                url: "open.qixin.com".into(),
                usage: "注册→企业认证→获取密钥→REST 调用".into(),
                auth_method: "api_key".into(),
                env_var: Some("QIXIN_API_KEY".into()),
                priority: ConnectorPriority::Backup,
                region: ConnectorRegion::ChinaMainland,
                implemented: false,
            })
            // ── US legal databases ──
            .with_entry(ConnectorMetadata {
                name: "courtlistener".into(),
                display_name: "CourtListener (US Case Law)".into(),
                description: "900万+美国联邦及州法院判决、案卷、法官数据；含语义检索".into(),
                connector_type: "API / MCP / 网页".into(),
                url: "courtlistener.com".into(),
                usage: "注册获取免费 API Token；或接入社区 CourtListener MCP".into(),
                auth_method: "api_key".into(),
                env_var: Some("COURTLISTENER_API_KEY".into()),
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::UnitedStates,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "vaquill".into(),
                display_name: "Vaquill AI".into(),
                description: "美国法律研究平台，800万+联邦/州判决 + US Code/CFR，含引文核验".into(),
                connector_type: "API / MCP".into(),
                url: "vaquill.ai".into(),
                usage: "注册账号→订阅→获取 API Key；接入 Vaquill MCP".into(),
                auth_method: "api_key".into(),
                env_var: Some("VAQUILL_API_KEY".into()),
                priority: ConnectorPriority::Evaluate,
                region: ConnectorRegion::UnitedStates,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "sec_edgar".into(),
                display_name: "SEC EDGAR (US Filings)".into(),
                description: "美国证监会披露系统：上市公司年报/财报/内部人交易".into(),
                connector_type: "API / MCP".into(),
                url: "data.sec.gov".into(),
                usage: "公开 API 免费；需声明 User-Agent".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::UnitedStates,
                implemented: true,
            })
            // ── EU/European databases ──
            .with_entry(ConnectorMetadata {
                name: "eur_lex".into(),
                display_name: "EUR-Lex".into(),
                description: "欧盟官方法律门户：全部立法、判例、条约，24语言，提供 Webservice/SPARQL/REST".into(),
                connector_type: "API / 网页".into(),
                url: "eur-lex.europa.eu".into(),
                usage: "注册 Webservice 账号→SOAP/SPARQL/REST 调用；网页免费检索".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::Europe,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "ansvar".into(),
                display_name: "Ansvar (EU Compliance MCP)".into(),
                description: "开源 MCP，覆盖 61 部欧盟法规（GDPR、AI Act、DORA、NIS2 等）4000+条文".into(),
                connector_type: "MCP (开源)".into(),
                url: "github.com/Ansvar-Systems/EU_compliance_MCP".into(),
                usage: "自托管部署 MCP；接入 AI 系统".into(),
                auth_method: "api_key".into(),
                env_var: Some("ANSVAR_API_KEY".into()),
                priority: ConnectorPriority::Evaluate,
                region: ConnectorRegion::Europe,
                implemented: true,
            })
            // ── Hong Kong ──
            .with_entry(ConnectorMetadata {
                name: "elegislation_hk".into(),
                display_name: "香港法律参考资料系统 e-Legislation".into(),
                description: "香港律政司官方、经核证的现行综合法例库（中英对照）".into(),
                connector_type: "网页 / 数据".into(),
                url: "elegislation.gov.hk".into(),
                usage: "网页检索；可定向抓取（遵守使用条款）".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::HongKong,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "hklii".into(),
                display_name: "HKLII".into(),
                description: "香港法律资讯研究中心：判例与法例免费库，覆盖各级法院判决".into(),
                connector_type: "网页 / 数据".into(),
                url: "hklii.hk".into(),
                usage: "网页检索；学术/抓取需遵守条款".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::HongKong,
                implemented: false,
            })
            // ── Singapore ──
            .with_entry(ConnectorMetadata {
                name: "sso_sg".into(),
                display_name: "Singapore Statutes Online".into(),
                description: "新加坡总检察署官方免费法例库（现行与历史成文法、附属立法）".into(),
                connector_type: "网页 / 数据".into(),
                url: "sso.agc.gov.sg".into(),
                usage: "网页检索；可定向抓取（遵守条款）".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::Singapore,
                implemented: false,
            })
            // ── Global / multi-jurisdiction ──
            .with_entry(ConnectorMetadata {
                name: "gleif".into(),
                display_name: "GLEIF (Global LEI Registry)".into(),
                description: "全球法人识别编码基金会，免费 API 查询 LEI 记录".into(),
                connector_type: "API (free)".into(),
                url: "api.gleif.org".into(),
                usage: "公开 API 免费，无需认证".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::Global,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "vlex".into(),
                display_name: "vLex / Vincent AI".into(),
                description: "全球法律库（10亿+文档、17+国家），支持跨法域 AI 对比检索".into(),
                connector_type: "商业订阅 / AI".into(),
                url: "vlex.com".into(),
                usage: "机构订阅；AI 检索与对比；接口对接需洽谈".into(),
                auth_method: "account_login".into(),
                env_var: None,
                priority: ConnectorPriority::Procurement,
                region: ConnectorRegion::Global,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "jusmundi".into(),
                display_name: "Jus Mundi".into(),
                description: "国际仲裁与跨境公法/投资争端专业库（裁决、条约、案例）".into(),
                connector_type: "商业订阅 / API".into(),
                url: "jusmundi.com".into(),
                usage: "机构订阅；提供 API（需洽谈）".into(),
                auth_method: "account_login".into(),
                env_var: None,
                priority: ConnectorPriority::Procurement,
                region: ConnectorRegion::Global,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "worldlii".into(),
                display_name: "WorldLII / CommonLII / AsianLII".into(),
                description: "免费法律信息网联邦门户，200+法域，含香港/新加坡及英联邦判例".into(),
                connector_type: "网页 / 数据".into(),
                url: "worldlii.org".into(),
                usage: "网页检索/定向抓取（遵守条款）".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::Global,
                implemented: false,
            })
            // ── Offshore jurisdictions ──
            .with_entry(ConnectorMetadata {
                name: "opencorporates".into(),
                display_name: "OpenCorporates".into(),
                description: "全球公司注册数据门户，覆盖离岸法域公司信息".into(),
                connector_type: "API".into(),
                url: "opencorporates.com".into(),
                usage: "注册账号→获取 API Key→REST 调用".into(),
                auth_method: "api_key".into(),
                env_var: Some("OPENCORPORATES_API_KEY".into()),
                priority: ConnectorPriority::Evaluate,
                region: ConnectorRegion::Offshore,
                implemented: true,
            })
            .with_entry(ConnectorMetadata {
                name: "offshore_leaks".into(),
                display_name: "OffshoreLeaks (ICIJ)".into(),
                description: "ICIJ 离岸泄密数据库，免费 API 接入".into(),
                connector_type: "API (free)".into(),
                url: "offshoreleaks.icij.org".into(),
                usage: "免费 API 接入：offshoreleaks.icij.org/docs/reconciliation".into(),
                auth_method: "free".into(),
                env_var: None,
                priority: ConnectorPriority::FreeAvailable,
                region: ConnectorRegion::Offshore,
                implemented: false,
            })
            // ── Internal firm resources (knowledge bases) ──
            .with_entry(ConnectorMetadata {
                name: "internal_cases".into(),
                display_name: "内部案例与文书库".into(),
                description: "律所历史案件、办案文书、检索报告、备忘录等，RAG 检索核心私域知识".into(),
                connector_type: "文件/DMS + 向量库".into(),
                url: "(内部系统)".into(),
                usage: "文档接入 DMS/对象存储→OCR/解析→切分入向量库→检索增强".into(),
                auth_method: "internal".into(),
                env_var: None,
                priority: ConnectorPriority::SelfBuilt,
                region: ConnectorRegion::Internal,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "internal_templates".into(),
                display_name: "合同与文书模板库".into(),
                description: "标准合同/协议/通知/意见书模板与条款库，支撑起草与审查智能体".into(),
                connector_type: "文件 + 向量库".into(),
                url: "(内部系统)".into(),
                usage: "模板结构化标注→入库→生成/审查时调用".into(),
                auth_method: "internal".into(),
                env_var: None,
                priority: ConnectorPriority::SelfBuilt,
                region: ConnectorRegion::Internal,
                implemented: false,
            })
            .with_entry(ConnectorMetadata {
                name: "internal_conflicts".into(),
                display_name: "客户与项目档案（利冲）".into(),
                description: "客户、对手方、关联方与项目台账，支撑利益冲突检索与立案合规".into(),
                connector_type: "结构化DB".into(),
                url: "(内部系统)".into(),
                usage: "结构化入库→与企查查/企业数据联动做关联识别".into(),
                auth_method: "internal".into(),
                env_var: None,
                priority: ConnectorPriority::SelfBuilt,
                region: ConnectorRegion::Internal,
                implemented: false,
            })
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
/// Free international connectors (CourtListener, SEC EDGAR, GLEIF, EUR-Lex) are always active.
/// Paid international connectors (Vaquill, Ansvar, OpenCorporates) need env vars when available.
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
        .with_connector(Arc::new(VaquillConnector::new(
            std::env::var("VAQUILL_API_KEY").ok(),
        )))
        .with_connector(Arc::new(EurLexConnector::new()))
        .with_connector(Arc::new(AnsvarConnector::new(
            std::env::var("ANSVAR_API_KEY").ok(),
        )))
        .with_connector(Arc::new(OpenCorporatesConnector::new(
            std::env::var("OPENCORPORATES_API_KEY").ok(),
        )))
}

// ─────────────────────────────────────────────────────────────────────────────
// International connectors (Vaquill, EUR-Lex, Ansvar, OpenCorporates)
// ─────────────────────────────────────────────────────────────────────────────

/// Vaquill — US legal research platform with AI-powered search.
/// Requires API key (env: VAQUILL_API_KEY).
/// Credentials: pacgate.ai01@outlook.com / PacgateLaw
/// API key format: vq_key_...
pub struct VaquillConnector {
    api_key: Option<String>,
    client: reqwest::Client,
}

impl VaquillConnector {
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
impl DataSourceConnector for VaquillConnector {
    fn name(&self) -> &str { "vaquill" }
    fn display_name(&self) -> &str { "Vaquill AI (US Legal Research)" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k,
            None => return Vec::new(),
        };

        let url = format!(
            "https://api.vaquill.ai/v1/search?q={}&limit={}",
            urlencoding::encode(&query.keywords),
            query.limit
        );

        let resp = match self.client
            .get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Accept", "application/json")
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "connection error");
                return Vec::new();
            }
        };

        if !resp.status().is_success() {
            tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "request failed");
            return Vec::new();
        }

        resp.json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|json| json.get("results").and_then(|r| r.as_array()).map(|arr| {
                arr.iter().filter_map(|item| {
                    Some(SearchResult {
                        title:       item.get("title")?.as_str()?.to_string(),
                        citation:    item.get("citation").and_then(|v| v.as_str()).map(String::from),
                        summary:     item.get("snippet").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                        url:         item.get("url").and_then(|v| v.as_str()).map(String::from),
                        source_name: "vaquill".to_string(),
                        source_level: "auxiliary_db".to_string(),
                        jurisdiction: Some("UnitedStates".to_string()),
                        date:        item.get("date").and_then(|v| v.as_str()).map(String::from),
                        metadata:    Some(item.clone()),
                    })
                }).collect()
            }))
            .unwrap_or_default()
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        if self.api_key.is_none() {
            return Err(SearchError::Unavailable("no API key configured".into()));
        }
        match self.client.get("https://api.vaquill.ai/v1/health").send().await {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// EUR-Lex — EU law database (public SPARQL endpoint, no API key required).
/// Endpoint: https://publications.europa.eu/webapi/rdf/sparql
/// Datadump: datadump.publications.europa.eu
/// Note: The client asset notes "都不能被agent调用" for the SPARQL endpoint,
/// but the public REST API at https://eur-lex.europa.eu/content/legal-information/legal-information.html
/// can be queried via the Cellar API.
pub struct EurLexConnector {
    client: reqwest::Client,
}

impl EurLexConnector {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .user_agent("Pacgate-AI/0.1 (pacgate.ai01@outlook.com)")
                .build()
                .unwrap_or_default(),
        }
    }
}

impl Default for EurLexConnector {
    fn default() -> Self { Self::new() }
}

#[async_trait]
impl DataSourceConnector for EurLexConnector {
    fn name(&self) -> &str { "eur-lex" }
    fn display_name(&self) -> &str { "EUR-Lex (EU Law Database)" }
    fn is_available(&self) -> bool { true }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        // EUR-Lex search API (public, no key required)
        // Uses the public search endpoint at publications.europa.eu
        let url = format!(
            "https://publications.europa.eu/resource/celex/search?q={}&pageSize={}&format=json",
            urlencoding::encode(&query.keywords),
            query.limit
        );

        match self.client
            .get(&url)
            .header("Accept", "application/json")
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>()
                    .await
                    .ok()
                    .and_then(|json| {
                        // EUR-Lex returns results in different possible structures
                        // Try the "results" array first, then "entries"
                        let results = json.get("results")
                            .or_else(|| json.get("entries"))
                            .and_then(|r| r.as_array())?;
                        Some(results.iter().filter_map(|item| {
                            Some(SearchResult {
                                title:       item.get("title")
                                    .and_then(|t| t.as_str())
                                    .unwrap_or("EUR-Lex document")
                                    .to_string(),
                                citation:    item.get("celex")
                                    .or_else(|| item.get("id"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                summary:     item.get("summary")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("")
                                    .to_string(),
                                url:         item.get("link")
                                    .or_else(|| item.get("url"))
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                source_name: "eur-lex".to_string(),
                                source_level: "authority_verified".to_string(),
                                jurisdiction: Some("EuropeanUnion".to_string()),
                                date:        item.get("date")
                                    .and_then(|v| v.as_str())
                                    .map(String::from),
                                metadata:    Some(item.clone()),
                            })
                        }).collect())
                    })
                    .unwrap_or_default()
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
        match self.client
            .get("https://publications.europa.eu/resource/celex/search?q=test&pageSize=1&format=json")
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// Ansvar — EU compliance MCP server.
/// Requires API key (env: ANSVAR_API_KEY).
/// Credentials: pacgate.ai01@outlook.com / Lawisdivine@123456
/// Docs: https://ansvar.eu/docs/setup
pub struct AnsvarConnector {
    api_key: Option<String>,
    client: reqwest::Client,
}

impl AnsvarConnector {
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
impl DataSourceConnector for AnsvarConnector {
    fn name(&self) -> &str { "ansvar" }
    fn display_name(&self) -> &str { "Ansvar (EU Compliance MCP)" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k,
            None => return Vec::new(),
        };

        let url = format!(
            "https://ansvar.eu/api/v1/search?q={}&limit={}",
            urlencoding::encode(&query.keywords),
            query.limit
        );

        let resp = match self.client
            .get(&url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Accept", "application/json")
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "connection error");
                return Vec::new();
            }
        };

        if !resp.status().is_success() {
            tracing::warn!(connector = self.name(), status = resp.status().as_u16(), "request failed");
            return Vec::new();
        }

        resp.json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|json| json.get("results").and_then(|r| r.as_array()).map(|arr| {
                arr.iter().filter_map(|item| {
                    Some(SearchResult {
                        title:       item.get("title")?.as_str()?.to_string(),
                        citation:    item.get("reference").and_then(|v| v.as_str()).map(String::from),
                        summary:     item.get("description").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                        url:         item.get("url").and_then(|v| v.as_str()).map(String::from),
                        source_name: "ansvar".to_string(),
                        source_level: "auxiliary_db".to_string(),
                        jurisdiction: Some("EuropeanUnion".to_string()),
                        date:        item.get("effective_date").and_then(|v| v.as_str()).map(String::from),
                        metadata:    Some(item.clone()),
                    })
                }).collect()
            }))
            .unwrap_or_default()
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        if self.api_key.is_none() {
            return Err(SearchError::Unavailable("no API key configured".into()));
        }
        match self.client.get("https://ansvar.eu/api/v1/health").send().await {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

/// OpenCorporates — global corporate registry (offshore jurisdictions).
/// Requires API key (env: OPENCORPORATES_API_KEY).
/// Credentials: pacgate.ai01@outlook.com / Cc@123456
/// API docs: https://api.opencorporates.com/documentation/
pub struct OpenCorporatesConnector {
    api_key: Option<String>,
    client: reqwest::Client,
}

impl OpenCorporatesConnector {
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
impl DataSourceConnector for OpenCorporatesConnector {
    fn name(&self) -> &str { "opencorporates" }
    fn display_name(&self) -> &str { "OpenCorporates (Global Corporate Registry)" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k,
            None => return Vec::new(),
        };

        // OpenCorporates company search API
        let url = format!(
            "https://api.opencorporates.com/v0.4/companies/search?q={}&per_page={}&api_token={}",
            urlencoding::encode(&query.keywords),
            query.limit,
            urlencoding::encode(api_key),
        );

        match self.client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                resp.json::<serde_json::Value>()
                    .await
                    .ok()
                    .and_then(|json| {
                        json.get("results")?
                            .get("companies")?
                            .as_array()
                            .map(|arr| {
                                arr.iter().filter_map(|item| {
                                    let company = item.get("company")?;
                                    Some(SearchResult {
                                        title:       company.get("name")?.as_str()?.to_string(),
                                        citation:    company.get("company_number").and_then(|v| v.as_str()).map(String::from),
                                        summary:     company.get("registered_address")
                                            .and_then(|a| a.get("country"))
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("")
                                            .to_string(),
                                        url:         company.get("opencorporates_url").and_then(|v| v.as_str()).map(String::from),
                                        source_name: "opencorporates".to_string(),
                                        source_level: "auxiliary_db".to_string(),
                                        jurisdiction: company.get("jurisdiction_code").and_then(|v| v.as_str()).map(String::from),
                                        date:        company.get("incorporation_date").and_then(|v| v.as_str()).map(String::from),
                                        metadata:    Some(company.clone()),
                                    })
                                }).collect()
                            })
                    })
                    .unwrap_or_default()
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
        if self.api_key.is_none() {
            return Err(SearchError::Unavailable("no API key configured".into()));
        }
        match self.client
            .get("https://api.opencorporates.com/v0.4/companies/search?q=test&per_page=1")
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}