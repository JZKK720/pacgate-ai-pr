//! Pacgate-ai API server entry point.
//!
//! Wires the Postgres pool, document store, matter store, tenant store,
//! LLM router, and agent loop into `AppState`, then starts the Axum server.

use std::sync::Arc;

use pacgate_api::{build_router, AppConfig, AppState};
use pacgate_agent::{AgentLoop, ToolDispatcher};
use pacgate_docx::FsDocumentStore;
use pacgate_llm::LlmRouter;
use pacgate_tenant::{run_migrations, MatterStore, TenantStore};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    tracing::info!("Pacgate-ai API server starting up");

    // Load config from environment
    let database_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://pacgate:pacgate@localhost:5432/pacgate".to_string());
    let data_dir = std::env::var("DATA_DIR")
        .unwrap_or_else(|_| "./data/tenants".to_string());
    let jwt_secret = std::env::var("PACGATE_JWT_SECRET")
        .unwrap_or_else(|_| "change-me-in-production".to_string());
    let default_tenant = std::env::var("PACGATE_DEFAULT_TENANT")
        .unwrap_or_else(|_| "default-firm".to_string());

    let config = Arc::new(AppConfig {
        data_dir: std::path::PathBuf::from(&data_dir),
        max_upload_mb: 50,
        jwt_secret,
        default_tenant,
    });

    // Create Postgres connection pool
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(10)
        .connect(&database_url)
        .await
        .map_err(|e| {
            tracing::error!("Failed to connect to database: {e}");
            anyhow::anyhow!("database connection failed: {e}")
        })?;

    tracing::info!("Connected to database");

    // Run migrations
    run_migrations(&pool).await?;
    tracing::info!("Migrations applied");

    // Create stores
    let doc_store = Arc::new(FsDocumentStore::new(pool.clone(), &config.data_dir));
    let matter_store = Arc::new(MatterStore::new(pool.clone()));
    let tenant_store = Arc::new(TenantStore::new(pool.clone()));
    let auth = Arc::new(pacgate_auth::AuthService::new(config.jwt_secret.clone(), pool.clone()));

    // Create LLM router with default local config
    let model_configs = pacgate_core::ModelConfig::default_local();
    let api_keys = std::collections::HashMap::new();
    let router = Arc::new(LlmRouter::new(model_configs, api_keys));

    // Create agent loop and tool dispatcher
    // For now, use stub stores — these will be replaced with real implementations
    use pacgate_core::{DocumentStore, KbStore, WorkflowStore};
    
    struct StubDocStore;
    #[async_trait::async_trait]
    impl DocumentStore for StubDocStore {
        async fn read(&self, _id: &pacgate_core::DocumentId) -> pacgate_core::Result<String> {
            Err(pacgate_core::PacgateError::StorageError("stub".into()))
        }
        async fn read_version(&self, _id: &pacgate_core::DocumentId, _version: u32) -> pacgate_core::Result<String> {
            Err(pacgate_core::PacgateError::StorageError("stub".into()))
        }
        async fn list_for_matter(&self, _matter_id: &pacgate_core::MatterId) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
            Ok(Vec::new())
        }
        async fn find_in(&self, _id: &pacgate_core::DocumentId, _query: &str) -> pacgate_core::Result<Vec<pacgate_core::FindResult>> {
            Ok(Vec::new())
        }
        async fn create_from_structure(&self, _matter_id: &pacgate_core::MatterId, _filename: &str, _structure: &serde_json::Value) -> pacgate_core::Result<pacgate_core::Document> {
            Err(pacgate_core::PacgateError::StorageError("stub".into()))
        }
        async fn apply_edit(&self, _id: &pacgate_core::DocumentId, _find: &str, _replace: &str, _ctx_before: Option<&str>, _ctx_after: Option<&str>) -> pacgate_core::Result<pacgate_core::Document> {
            Err(pacgate_core::PacgateError::StorageError("stub".into()))
        }
        async fn replicate(&self, _id: &pacgate_core::DocumentId, _count: u32) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
            Ok(Vec::new())
        }
    }
    
    struct StubWorkflowStore;
    #[async_trait::async_trait]
    impl WorkflowStore for StubWorkflowStore {
        async fn get_prompt(&self, _workflow_id: &str) -> pacgate_core::Result<String> {
            Ok(String::new())
        }
    }
    
    struct StubKbStore;
    #[async_trait::async_trait]
    impl KbStore for StubKbStore {
        async fn search(&self, _matter_id: &pacgate_core::MatterId, _query: &str, _top_k: u32) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
            Ok(Vec::new())
        }
    }
    
    let dispatcher = Arc::new(ToolDispatcher::new(
        Arc::new(StubDocStore),
        Arc::new(StubWorkflowStore),
        Arc::new(StubKbStore),
    ));
    let agent_loop = Arc::new(AgentLoop::new(router.clone(), dispatcher.clone()));

    // Build application state
    let state = AppState {
        agent_loop,
        router,
        dispatcher,
        config,
        doc_store,
        matter_store,
        tenant_store,
        auth,
        db: pool,
    };

    // Build and start the Axum server
    let app = build_router(state);
    let addr = "0.0.0.0:8080";
    tracing::info!("Listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}