//! Pacgate-ai API server entry point.
//!
//! Wires the Postgres pool, document store, matter store, tenant store,
//! LLM router, and agent loop into `AppState`, then starts the Axum server.

use std::sync::Arc;

use pacgate_agent::{AgentLoop, ToolDispatcher};
use pacgate_api::{build_router, AppConfig, AppState};
use pacgate_docx::FsDocumentStore;
use pacgate_llm::LlmRouter;
use pacgate_tenant::{run_migrations, MatterStore, TenantStore};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    tracing::info!("Pacgate-ai API server starting up");

    // Load config from environment
    let database_url = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://pacgate:pacgate@localhost:5432/pacgate".to_string());
    let data_dir = std::env::var("DATA_DIR").unwrap_or_else(|_| "./data/tenants".to_string());
    let jwt_secret = std::env::var("PACGATE_JWT_SECRET")
        .unwrap_or_else(|_| "change-me-in-production".to_string());
    let default_tenant =
        std::env::var("PACGATE_DEFAULT_TENANT").unwrap_or_else(|_| "default-firm".to_string());
    let workflows_dir = std::env::var("WORKFLOWS_DIR")
        .map(std::path::PathBuf::from)
        .ok();
    // Ollama base URL used by BOTH the LLM router and the RAG embedding
    // service. In containerized deployments this must be host-reachable
    // (e.g. http://host.docker.internal:11434) — localhost would point at
    // the container itself.
    let ollama_url = std::env::var("OLLAMA_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:11434".to_string());

    let config = Arc::new(AppConfig {
        data_dir: std::path::PathBuf::from(&data_dir),
        max_upload_mb: 50,
        jwt_secret,
        default_tenant,
        workflows_dir,
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
    let auth = Arc::new(pacgate_auth::AuthService::new(
        config.jwt_secret.clone(),
        pool.clone(),
    ));

    // Create LLM router with default local config, honoring OLLAMA_BASE_URL
    let model_configs = pacgate_core::ModelConfig::default_local_with_base_url(&ollama_url);
    let api_keys = std::collections::HashMap::new();
    let router = Arc::new(LlmRouter::new(model_configs, api_keys));

    // Create agent loop and tool dispatcher
    // Wire the real FsDocumentStore into the agent tools so read_document /
    // generate_docx / edit_document operate on actual matter documents.
    use pacgate_core::{KbStore, WorkflowStore};

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
        async fn search(
            &self,
            _matter_id: &pacgate_core::MatterId,
            _query: &str,
            _top_k: u32,
        ) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
            Ok(Vec::new())
        }
    }

    // Create search router with all data source connectors
    let search = Arc::new(pacgate_search::default_router());

    // Create RAG store (optional — requires Ollama embedding service)
    // Reuses `ollama_url` read at config load (shared with the LLM router).
    let embedding_model = std::env::var("OLLAMA_EMBED_MODEL")
        .unwrap_or_else(|_| "nomic-embed-text".to_string());
    let embed_svc = pacgate_rag::EmbeddingService::new(&ollama_url, &embedding_model);
    let rag = {
        tracing::info!(
            "RAG store initialized (ollama={}, model={})",
            ollama_url,
            embedding_model
        );
        Some(Arc::new(pacgate_rag::RagStore::new(pool.clone(), embed_svc)))
    };

    let dispatcher = Arc::new(
        ToolDispatcher::new(
            doc_store.clone(),
            Arc::new(StubWorkflowStore),
            Arc::new(StubKbStore),
        )
        .with_search_router(search.clone()),
    );
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
        search,
        rag,
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
