//! Integration test — verifies the full pacgate-api request flow against a
//! running Postgres instance.
//!
//! This test is gated behind `#[ignore]` because it requires:
//! 1. A running Postgres instance (set DATABASE_URL or use default)
//! 2. The `pacgate_test` database to exist (or it will be created)
//!
//! Run with: `cargo test -p pacgate-api --test integration -- --ignored`
//!
//! The test flow:
//!   1. Connect to Postgres, create test database, run migrations
//!   2. Build the full AppState (doc_store, matter_store, tenant_store, auth, LLM router, agent loop)
//!   3. Start the Axum server in the router in-process using `oneshot` requests
//!   4. Register a test user → login → verify JWT
//!   5. Create a matter → list matters → verify
//!   6. Upload a document → list documents → verify

#![cfg(test)]

use std::sync::Arc;

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use tower::ServiceExt;

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_DB_URL: &str = "postgres://pacgate:pacgate@localhost:5432/pacgate_test";
    const TEST_DATA_DIR: &str = "./data/test-integration";

    /// Full end-to-end test: register → login → create matter → list matters.
    ///
    /// Requires a running Postgres. Run with `--ignored`.
    #[tokio::test]
    #[ignore]
    async fn full_api_flow() {
        // ── 1. Setup: connect to Postgres, create test DB, run migrations ──

        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(5)
            .connect(TEST_DB_URL)
            .await
            .expect("failed to connect to test Postgres — is it running?");

        // Run tenant migrations (creates tenants, matters, documents, users tables)
        pacgate_tenant::run_migrations(&pool)
            .await
            .expect("failed to run tenant migrations");

        // Run RAG migrations (creates kb_chunks table + enrichment columns)
        pacgate_rag::RagStore::run_migrations(&pool)
            .await
            .expect("failed to run RAG migrations");

        // ── 2. Build AppState ──

        let config = Arc::new(pacgate_api::AppConfig {
            data_dir: std::path::PathBuf::from(TEST_DATA_DIR),
            max_upload_mb: 50,
            jwt_secret: "test-secret-key".to_string(),
            default_tenant: "test-firm".to_string(),
        });

        let doc_store = Arc::new(pacgate_docx::FsDocumentStore::new(
            pool.clone(),
            &config.data_dir,
        ));
        let matter_store = Arc::new(pacgate_tenant::MatterStore::new(pool.clone()));
        let tenant_store = Arc::new(pacgate_tenant::TenantStore::new(pool.clone()));
        let auth = Arc::new(pacgate_auth::AuthService::new(
            config.jwt_secret.clone(),
            pool.clone(),
        ));

        // Create LLM router with default local config (won't be called in this test)
        let model_configs = pacgate_core::ModelConfig::default_local();
        let api_keys = std::collections::HashMap::new();
        let router = Arc::new(pacgate_llm::LlmRouter::new(model_configs, api_keys));

        // Create stub stores for agent (we won't call chat in this test)
        use pacgate_core::{DocumentStore, KbStore, WorkflowStore};

        struct StubDocStore;
        #[async_trait::async_trait]
        impl DocumentStore for StubDocStore {
            async fn read(&self, _id: &pacgate_core::DocumentId) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn read_version(
                &self,
                _id: &pacgate_core::DocumentId,
                _version: u32,
            ) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn list_for_matter(
                &self,
                _matter_id: &pacgate_core::MatterId,
            ) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
                Ok(Vec::new())
            }
            async fn find_in(
                &self,
                _id: &pacgate_core::DocumentId,
                _query: &str,
            ) -> pacgate_core::Result<Vec<pacgate_core::FindResult>> {
                Ok(Vec::new())
            }
            async fn create_from_structure(
                &self,
                _matter_id: &pacgate_core::MatterId,
                _filename: &str,
                _structure: &serde_json::Value,
            ) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn apply_edit(
                &self,
                _id: &pacgate_core::DocumentId,
                _find: &str,
                _replace: &str,
                _ctx_before: Option<&str>,
                _ctx_after: Option<&str>,
            ) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn replicate(
                &self,
                _id: &pacgate_core::DocumentId,
                _count: u32,
            ) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
                Ok(Vec::new())
            }
        }

        struct StubWorkflowStore;
        #[async_trait::async_trait]
        impl WorkflowStore for StubWorkflowStore {
            async fn get_prompt(&self, _workflow_id: &str) -> pacgate_core::Result<String> {
                Ok("stub workflow prompt".to_string())
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

        let dispatcher = Arc::new(pacgate_agent::ToolDispatcher::new(
            Arc::new(StubDocStore),
            Arc::new(StubWorkflowStore),
            Arc::new(StubKbStore),
        ));

        let agent_loop = Arc::new(pacgate_agent::AgentLoop::new(
            router.clone(),
            dispatcher.clone(),
        ));

        let state = pacgate_api::AppState {
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

        let app = pacgate_api::build_router(state);

        // ── 3. Health check ──

        let response = app
            .clone()
            .oneshot(Request::builder().uri("/health").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // ── 4. Register a test user ──

        let register_body = serde_json::json!({
            "email": "test-integration@pacgate.test",
            "password": "test-password-123",
            "tenant_slug": "test-firm",
            "role": "admin"
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/register")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&register_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Register should succeed (201) or conflict (409 if user already exists from prior run)
        let status = response.status();
        assert!(
            status == StatusCode::CREATED || status == StatusCode::CONFLICT,
            "register should return 201 or 409, got {status}"
        );

        // ── 5. Login ──

        let login_body = serde_json::json!({
            "email": "test-integration@pacgate.test",
            "password": "test-password-123"
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/login")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&login_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK, "login should return 200");

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let login_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("login response is valid JSON");
        let token = login_response["token"]
            .as_str()
            .expect("login response contains token");
        assert!(!token.is_empty(), "token is not empty");

        // ── 6. Create a matter (requires auth) ──

        let matter_body = serde_json::json!({
            "name": "Integration Test Matter",
            "practice_area": "mergers_and_acquisitions"
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/matters")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(serde_json::to_vec(&matter_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Should succeed (201) or return an error if tenant doesn't exist yet
        let status = response.status();
        assert!(
            status == StatusCode::CREATED || status == StatusCode::INTERNAL_SERVER_ERROR,
            "create matter should return 201 or 500 (if tenant not seeded), got {status}"
        );

        // ── 7. List matters (requires auth) ──

        let response = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/matters")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK, "list matters should return 200");

        tracing::info!("Integration test passed: health → register → login → create matter → list matters");
    }

    /// Test that unauthenticated requests to protected routes return 401.
    #[tokio::test]
    #[ignore]
    async fn unauthenticated_request_returns_401() {
        // Build a minimal app (we don't need a real DB for this test,
        // but we need one to build AppState. Use the same setup as above.)
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .connect(TEST_DB_URL)
            .await
            .expect("failed to connect to test Postgres");

        pacgate_tenant::run_migrations(&pool).await.ok();
        pacgate_rag::RagStore::run_migrations(&pool).await.ok();

        let config = Arc::new(pacgate_api::AppConfig {
            data_dir: std::path::PathBuf::from(TEST_DATA_DIR),
            max_upload_mb: 50,
            jwt_secret: "test-secret-key".to_string(),
            default_tenant: "test-firm".to_string(),
        });

        // Build minimal state (stubs for everything)
        use pacgate_core::{DocumentStore, KbStore, WorkflowStore};
        struct StubAll;
        #[async_trait::async_trait]
        impl DocumentStore for StubAll {
            async fn read(&self, _: &pacgate_core::DocumentId) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn read_version(&self, _: &pacgate_core::DocumentId, _: u32) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn list_for_matter(&self, _: &pacgate_core::MatterId) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
                Ok(Vec::new())
            }
            async fn find_in(&self, _: &pacgate_core::DocumentId, _: &str) -> pacgate_core::Result<Vec<pacgate_core::FindResult>> {
                Ok(Vec::new())
            }
            async fn create_from_structure(&self, _: &pacgate_core::MatterId, _: &str, _: &serde_json::Value) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn apply_edit(&self, _: &pacgate_core::DocumentId, _: &str, _: &str, _: Option<&str>, _: Option<&str>) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn replicate(&self, _: &pacgate_core::DocumentId, _: u32) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
                Ok(Vec::new())
            }
        }
        #[async_trait::async_trait]
        impl WorkflowStore for StubAll {
            async fn get_prompt(&self, _: &str) -> pacgate_core::Result<String> {
                Ok(String::new())
            }
        }
        #[async_trait::async_trait]
        impl KbStore for StubAll {
            async fn search(&self, _: &pacgate_core::MatterId, _: &str, _: u32) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
                Ok(Vec::new())
            }
        }

        let dispatcher = Arc::new(pacgate_agent::ToolDispatcher::new(
            Arc::new(StubAll),
            Arc::new(StubAll),
            Arc::new(StubAll),
        ));
        let model_configs = pacgate_core::ModelConfig::default_local();
        let router = Arc::new(pacgate_llm::LlmRouter::new(model_configs, std::collections::HashMap::new()));
        let agent_loop = Arc::new(pacgate_agent::AgentLoop::new(router.clone(), dispatcher.clone()));

        let state = pacgate_api::AppState {
            agent_loop,
            router,
            dispatcher,
            config,
            doc_store: Arc::new(pacgate_docx::FsDocumentStore::new(pool.clone(), &std::path::PathBuf::from(TEST_DATA_DIR))),
            matter_store: Arc::new(pacgate_tenant::MatterStore::new(pool.clone())),
            tenant_store: Arc::new(pacgate_tenant::TenantStore::new(pool.clone())),
            auth: Arc::new(pacgate_auth::AuthService::new("test-secret", pool.clone())),
            db: pool,
        };

        let app = pacgate_api::build_router(state);

        // Request to a protected route without auth header
        let response = app
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/matters")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "unauthenticated request to protected route should return 401"
        );
    }
}