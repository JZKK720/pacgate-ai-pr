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

    // Run RAG migrations (creates kb_chunks + pgvector/tsvector schema).
    // These were previously never run at startup, so /api/kb/search queried a
    // nonexistent table and document review/generation returned no grounding.
    // If pgvector is unavailable, log and continue so the rest of the API still
    // boots (RAG search will return 503 rather than crash the whole server).
    if let Err(error) = pacgate_rag::RagStore::run_migrations(&pool).await {
        tracing::warn!(%error, "RAG migrations failed; RAG search will be unavailable");
    }

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

    // Workflow store backed by the YAML template directory when configured.
    // Falls back to built-in templates when WORKFLOWS_DIR is unset.
    struct YamlWorkflowStore {
        dir: Option<std::path::PathBuf>,
    }
    #[async_trait::async_trait]
    impl WorkflowStore for YamlWorkflowStore {
        async fn get_prompt(&self, workflow_id: &str) -> pacgate_core::Result<String> {
            let id = workflow_id.parse::<pacgate_core::WorkflowId>()
                .map_err(|e| pacgate_core::PacgateError::ValidationError(
                    format!("invalid workflow_id: {e}")))?;
            let workflow = self.dir.as_ref()
                .and_then(|dir| pacgate_workflow::get_workflow_all(&id, Some(dir.as_path())))
                .or_else(|| pacgate_workflow::get_workflow(&id));
            Ok(workflow
                .map(|w| serde_json::to_string(&w).unwrap_or_default())
                .unwrap_or_default())
        }
    }

    // KB store backed by the real RagStore so the agent's `kb_search` tool reads
    // the per-matter knowledge base instead of returning an empty vec.
    struct RagKbStore {
        rag: Arc<pacgate_rag::RagStore>,
        tenant_id: pacgate_core::TenantId,
    }
    #[async_trait::async_trait]
    impl KbStore for RagKbStore {
        async fn search(
            &self,
            matter_id: &pacgate_core::MatterId,
            query: &str,
            top_k: u32,
        ) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
            let results = self.rag.search(
                &self.tenant_id,
                matter_id,
                query,
                top_k,
                &pacgate_rag::SearchFilter::new(),
            ).await.map_err(|e| pacgate_core::PacgateError::ValidationError(e.to_string()))?;
            Ok(results.into_iter().map(|r| pacgate_core::KbChunk {
                score: r.score,
                // RagStore does not return the document_id; the agent uses text
                // for context. Preserve the doc name as the source label.
                document_id: pacgate_core::DocumentId(uuid::Uuid::nil()),
                page: r.page.unwrap_or(0),
                text: r.content,
            }).collect())
        }
    }

    // Fallback KB store used only when the RAG store is unavailable (e.g. the
    // DB image lacks pgvector). Returns no chunks rather than erroring.
    struct EmptyKbStore;
    #[async_trait::async_trait]
    impl KbStore for EmptyKbStore {
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

    let dispatcher = {
        // Tenant id used by the KB store and the /api/kb/search handler. The
        // default tenant slug is a string (e.g. "default-firm") but kb_search
        // and the RAG store need a UUID TenantId. Resolve it once here from the
        // tenant store by slug, falling back to the literal parse for existing
        // setups that already store a UUID in PACGATE_DEFAULT_TENANT.
        let tenant_id = match tenant_store.get_by_slug(&config.default_tenant).await {
            Ok(t) => t.id,
            Err(_) => config.default_tenant.parse::<uuid::Uuid>()
                .map(pacgate_core::TenantId)
                .unwrap_or(pacgate_core::TenantId(uuid::Uuid::nil())),
        };

        let kb_store: Arc<dyn KbStore> = match &rag {
            Some(rag_store) => Arc::new(RagKbStore {
                rag: rag_store.clone(),
                tenant_id,
            }),
            None => Arc::new(EmptyKbStore),
        };

        Arc::new(
            ToolDispatcher::new(
                doc_store.clone(),
                Arc::new(YamlWorkflowStore {
                    dir: config.workflows_dir.clone(),
                }),
                kb_store,
            )
            .with_search_router(search.clone()),
        )
    };
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
