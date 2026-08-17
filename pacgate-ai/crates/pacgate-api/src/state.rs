use std::sync::Arc;

use pacgate_agent::{AgentLoop, ToolDispatcher};
use pacgate_auth::AuthService;
use pacgate_docx::FsDocumentStore;
use pacgate_llm::LlmRouter;
use pacgate_rag::RagStore;
use pacgate_search::SearchRouter;
use pacgate_tenant::{MatterStore, TenantStore};

/// Shared application state injected into all Axum handlers via `State<AppState>`.
#[derive(Clone)]
pub struct AppState {
    pub agent_loop: Arc<AgentLoop>,
    pub router: Arc<LlmRouter>,
    pub dispatcher: Arc<ToolDispatcher>,
    pub config: Arc<AppConfig>,
    pub doc_store: Arc<FsDocumentStore>,
    pub matter_store: Arc<MatterStore>,
    pub tenant_store: Arc<TenantStore>,
    pub auth: Arc<AuthService>,
    pub search: Arc<SearchRouter>,
    /// Optional RAG store — only available when Postgres is connected.
    /// When None, the `/api/kb/search` endpoint returns 503.
    pub rag: Option<Arc<RagStore>>,
    pub db: sqlx::PgPool,
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub data_dir: std::path::PathBuf,
    pub max_upload_mb: u64,
    /// JWT secret for auth tokens
    pub jwt_secret: String,
    /// Default tenant ID for single-tenant pilot deployments
    pub default_tenant: String,
    /// Directory containing YAML workflow templates (optional).
    /// When set, the API merges built-in + YAML workflows.
    pub workflows_dir: Option<std::path::PathBuf>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            data_dir: std::path::PathBuf::from("./data"),
            max_upload_mb: 50,
            jwt_secret: "change-me-in-production".to_string(),
            default_tenant: "default-firm".to_string(),
            workflows_dir: None,
        }
    }
}
