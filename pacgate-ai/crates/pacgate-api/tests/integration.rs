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

    const DEFAULT_TEST_DB_URL: &str = "postgres://hermes:changeme@localhost:5435/pacgate_test";
    const TEST_DATA_DIR: &str = "./data/test-integration";

    fn test_db_url() -> String {
        std::env::var("PACGATE_TEST_DATABASE_URL")
            .unwrap_or_else(|_| DEFAULT_TEST_DB_URL.to_string())
    }

    async fn run_rag_migrations_if_available(pool: &sqlx::PgPool) {
        if let Err(error) = pacgate_rag::RagStore::run_migrations(pool).await {
            let message = error.to_string();
            if message.contains("extension \"vector\" is not available") {
                tracing::warn!(%message, "skipping RAG migrations in integration test because pgvector is unavailable");
            } else {
                panic!("failed to run RAG migrations: {error}");
            }
        }
    }

    /// Full end-to-end test: register → login → create matter → list matters.
    ///
    /// Requires a running Postgres. Run with `--ignored`.
    #[tokio::test]
    #[ignore]
    async fn full_api_flow() {
        // ── 1. Setup: connect to Postgres, create test DB, run migrations ──

        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(5)
            .connect(&test_db_url())
            .await
            .expect("failed to connect to test Postgres — is it running?");

        // Run tenant migrations (creates tenants, matters, documents, users tables)
        pacgate_tenant::run_migrations(&pool)
            .await
            .expect("failed to run tenant migrations");

        // RAG is not exercised by this flow; tolerate local Postgres instances
        // that do not have pgvector installed.
        run_rag_migrations_if_available(&pool).await;

        let tenant_id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO tenants (name, slug) VALUES ($1, $2)
             ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
        )
        .bind("Integration Test Firm")
        .bind("test-firm")
        .fetch_one(&pool)
        .await
        .expect("failed to seed integration-test tenant");

        let other_tenant_id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO tenants (name, slug) VALUES ($1, $2)
             ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
        )
        .bind("Integration Test Firm Two")
        .bind("test-firm-two")
        .fetch_one(&pool)
        .await
        .expect("failed to seed second integration-test tenant");

        let test_email = format!("test-integration-{}@pacgate.test", uuid::Uuid::new_v4());
        let other_test_email = format!(
            "test-integration-other-{}@pacgate.test",
            uuid::Uuid::new_v4()
        );

        // ── 2. Build AppState ──

        let config = Arc::new(pacgate_api::AppConfig {
            data_dir: std::path::PathBuf::from(TEST_DATA_DIR),
            max_upload_mb: 50,
            jwt_secret: "test-secret-key".to_string(),
            default_tenant: "test-firm".to_string(),
            workflows_dir: None,
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

        auth.register(
            &pacgate_core::TenantId(other_tenant_id),
            &other_test_email,
            "test-password-123",
            "attorney",
            Some("Other Tenant User"),
        )
        .await
        .expect("failed to create second-tenant user");

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
            search: Arc::new(pacgate_search::default_router()),
            rag: None,
            db: pool,
        };

        let app = pacgate_api::build_router(state);

        // ── 3. Health check ──

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        // ── 4. Register a test user ──

        let register_body = serde_json::json!({
            "tenant_id": uuid::Uuid::new_v4(),
            "email": test_email,
            "password": "test-password-123",
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

        // Register should succeed with the current JSON handler behavior.
        let status = response.status();
        assert!(
            status == StatusCode::OK,
            "register should return 200, got {status}"
        );

        // ── 5. Login ──

        let login_body = serde_json::json!({
            "email": test_email,
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
        assert_eq!(
            login_response["tenant_id"].as_str(),
            Some(tenant_id.to_string().as_str()),
            "public registration should bind to the configured default tenant"
        );
        assert_eq!(
            login_response["role"].as_str(),
            Some("attorney"),
            "public registration should not preserve a caller-supplied elevated role"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/auth/me")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK, "me should return 200");

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let me_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("me response is valid JSON");
        assert_eq!(
            me_response["tenant_id"].as_str(),
            Some(tenant_id.to_string().as_str()),
            "me should expose the default tenant claim"
        );
        assert_eq!(
            me_response["role"].as_str(),
            Some("attorney"),
            "me should expose the stored non-privileged role"
        );

        // ── 6. Create a matter (requires auth) ──

        let matter_external_key = format!("qm-channel-integration-{}", uuid::Uuid::new_v4());

        let matter_body = serde_json::json!({
            "name": "Integration Test Matter",
            "external_key": matter_external_key,
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

        // Current handler returns 200 on success.
        let status = response.status();
        assert!(
            status == StatusCode::OK,
            "create matter should return 200, got {status}"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let matter_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("matter response is valid JSON");
        assert_eq!(
            matter_response["external_key"].as_str(),
            Some(matter_external_key.as_str()),
            "matter response should preserve the external scope key"
        );
        let matter_id = matter_response["id"]
            .as_str()
            .expect("matter response contains id")
            .to_string();

        let memory_body = serde_json::json!({
            "version": "2.0",
            "revision": 1,
            "lastUpdated": "2026-08-15T00:00:00Z",
            "user": { "preferences": ["formal"] },
            "history": { "last_task": "seed memory" },
            "facts": [{ "text": "Client prefers concise updates" }]
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(serde_json::to_vec(&memory_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "save matter memory should return 200"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "get matter memory should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let saved_memory: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("memory response is valid JSON");
        assert_eq!(
            saved_memory, memory_body,
            "matter memory round-trip should be lossless"
        );

        // ── 7. Upload a document into the created matter ──

        let boundary = "X-PACGATE-BOUNDARY";
        let document_bytes = b"integration-test-document";
        let multipart_prefix = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"matter_id\"\r\n\r\n{matter_id}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\nContent-Type: text/plain\r\n\r\n"
        );
        let multipart_suffix = format!("\r\n--{boundary}--\r\n");
        let mut multipart_body = multipart_prefix.into_bytes();
        multipart_body.extend_from_slice(document_bytes);
        multipart_body.extend_from_slice(multipart_suffix.as_bytes());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/documents")
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(multipart_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "document upload should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let document_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("document response is valid JSON");
        let document_id = document_response["id"]
            .as_str()
            .expect("document response contains id")
            .to_string();

        // Upload a second version of the same logical file name.
        let second_document_bytes = b"integration-test-document-v2";
        let second_prefix = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"matter_id\"\r\n\r\n{matter_id}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\nContent-Type: text/plain\r\n\r\n"
        );
        let second_suffix = format!("\r\n--{boundary}--\r\n");
        let mut second_multipart_body = second_prefix.into_bytes();
        second_multipart_body.extend_from_slice(second_document_bytes);
        second_multipart_body.extend_from_slice(second_suffix.as_bytes());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/documents")
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(second_multipart_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "second document upload should return 200"
        );

        // ── 8. List matter documents ──

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/documents"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "list matter documents should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let listed_documents: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("documents list is valid JSON");
        assert_eq!(
            listed_documents.as_array().map(|items| items.len()),
            Some(1),
            "matter should expose the uploaded document"
        );

        let other_login_body = serde_json::json!({
            "email": other_test_email,
            "password": "test-password-123"
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/auth/login")
                    .header("content-type", "application/json")
                    .body(Body::from(serde_json::to_vec(&other_login_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "other-tenant login should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let other_login_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("other login response is valid JSON");
        let other_token = other_login_response["token"]
            .as_str()
            .expect("other login response contains token");

        let chat_body = serde_json::json!({
            "matter_id": matter_id,
            "message": "Summarize the matter",
            "history": []
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/chat")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::from(serde_json::to_vec(&chat_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant chat should be hidden before any agent execution"
        );

        let workflow_execute_body = serde_json::json!({
            "matter_id": matter_id,
            "persona_id": null
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/workflows/00000000-0000-0000-0000-000000000101/execute")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::from(
                        serde_json::to_vec(&workflow_execute_body).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant workflow execution should be hidden before any workflow run"
        );

        for uri in [
            format!("/api/matters/{matter_id}/memory"),
            format!("/api/matters/{matter_id}/documents"),
            format!("/api/documents/{document_id}"),
            format!("/api/documents/{document_id}/versions"),
            format!("/api/documents/{document_id}/download"),
        ] {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("GET")
                        .uri(&uri)
                        .header("authorization", format!("Bearer {other_token}"))
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();

            assert_eq!(
                response.status(),
                StatusCode::NOT_FOUND,
                "cross-tenant GET {uri} should be hidden"
            );
        }

        // ── 9. List all versions for the original document id ──

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/documents/{document_id}/versions"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "list document versions should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let document_versions: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("document versions are valid JSON");
        assert_eq!(
            document_versions.as_array().map(|items| items.len()),
            Some(2),
            "versions route should return both revisions"
        );

        // ── 10. Download both versions explicitly ──

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/documents/{document_id}/download?version=1"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "document download should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(
            body_bytes.as_ref(),
            document_bytes,
            "version 1 download should match the first uploaded content"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/documents/{document_id}/download?version=2"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "document version 2 download should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(
            body_bytes.as_ref(),
            second_document_bytes,
            "version 2 download should match the second uploaded content"
        );

        // ── 11. Upload a DOCX and exercise edit/accept/delete ──

        let docx_bytes = pacgate_docx::generate_from_structure(&serde_json::json!({
            "title": "Contract Draft",
            "sections": [
                { "type": "paragraph", "text": "Original clause" }
            ]
        }))
        .expect("docx generation should succeed");

        let docx_prefix = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"matter_id\"\r\n\r\n{matter_id}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"contract.docx\"\r\nContent-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n"
        );
        let docx_suffix = format!("\r\n--{boundary}--\r\n");
        let mut docx_multipart_body = docx_prefix.into_bytes();
        docx_multipart_body.extend_from_slice(&docx_bytes);
        docx_multipart_body.extend_from_slice(docx_suffix.as_bytes());

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/documents")
                    .header(
                        "content-type",
                        format!("multipart/form-data; boundary={boundary}"),
                    )
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(docx_multipart_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "docx upload should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let docx_response: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("docx response is valid JSON");
        let docx_document_id = docx_response["id"]
            .as_str()
            .expect("docx response contains id")
            .to_string();

        let edit_body = serde_json::json!({
            "find": "Original clause",
            "replace": "Updated clause",
            "context_before": null,
            "context_after": null
        });

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("/api/documents/{docx_document_id}/edit"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(serde_json::to_vec(&edit_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "docx edit should return 200"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/documents/{docx_document_id}/versions"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "docx versions should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let docx_versions: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("docx versions are valid JSON");
        assert_eq!(
            docx_versions.as_array().map(|items| items.len()),
            Some(2),
            "docx versions should include original + tracked edit"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("/api/documents/{docx_document_id}/edit"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::from(serde_json::to_vec(&edit_body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant edit should be hidden"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/documents/{docx_document_id}/accept"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "accept changes should return 200"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/documents/{docx_document_id}/download"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "accepted docx download should return 200"
        );

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let accepted_text =
            pacgate_docx::read_text(&body_bytes).expect("accepted docx should remain readable");
        assert!(
            accepted_text.contains("Updated clause"),
            "accepted docx should keep the replacement text"
        );
        assert!(
            !accepted_text.contains("Original clause"),
            "accepted docx should remove the deleted text"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/documents/{docx_document_id}/accept"))
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant accept should be hidden"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/documents/{docx_document_id}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "document delete should return 200"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/documents"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let body_bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let listed_documents: serde_json::Value =
            serde_json::from_slice(&body_bytes).expect("documents list after delete is valid JSON");
        assert_eq!(
            listed_documents.as_array().map(|items| items.len()),
            Some(1),
            "deleting the docx family should leave only the text document in the matter"
        );

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("DELETE")
                    .uri(format!("/api/documents/{document_id}"))
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant delete should be hidden"
        );

        // ── 12. List matters (requires auth) ──

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

        assert_eq!(
            response.status(),
            StatusCode::OK,
            "list matters should return 200"
        );

        tracing::info!(
            "Integration test passed: health → register → login → create matter → upload text/docx documents → edit/accept/delete docx → list/download document versions → list matters"
        );
    }

    /// Test that unauthenticated requests to protected routes return 401.
    #[tokio::test]
    #[ignore]
    async fn unauthenticated_request_returns_401() {
        // Build a minimal app (we don't need a real DB for this test,
        // but we need one to build AppState. Use the same setup as above.)
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(1)
            .connect(&test_db_url())
            .await
            .expect("failed to connect to test Postgres");

        pacgate_tenant::run_migrations(&pool).await.ok();
        run_rag_migrations_if_available(&pool).await;

        let config = Arc::new(pacgate_api::AppConfig {
            data_dir: std::path::PathBuf::from(TEST_DATA_DIR),
            max_upload_mb: 50,
            jwt_secret: "test-secret-key".to_string(),
            default_tenant: "test-firm".to_string(),
            workflows_dir: None,
        });

        // Build minimal state (stubs for everything)
        use pacgate_core::{DocumentStore, KbStore, WorkflowStore};
        struct StubAll;
        #[async_trait::async_trait]
        impl DocumentStore for StubAll {
            async fn read(&self, _: &pacgate_core::DocumentId) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn read_version(
                &self,
                _: &pacgate_core::DocumentId,
                _: u32,
            ) -> pacgate_core::Result<String> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn list_for_matter(
                &self,
                _: &pacgate_core::MatterId,
            ) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
                Ok(Vec::new())
            }
            async fn find_in(
                &self,
                _: &pacgate_core::DocumentId,
                _: &str,
            ) -> pacgate_core::Result<Vec<pacgate_core::FindResult>> {
                Ok(Vec::new())
            }
            async fn create_from_structure(
                &self,
                _: &pacgate_core::MatterId,
                _: &str,
                _: &serde_json::Value,
            ) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn apply_edit(
                &self,
                _: &pacgate_core::DocumentId,
                _: &str,
                _: &str,
                _: Option<&str>,
                _: Option<&str>,
            ) -> pacgate_core::Result<pacgate_core::Document> {
                Err(pacgate_core::PacgateError::StorageError("stub".into()))
            }
            async fn replicate(
                &self,
                _: &pacgate_core::DocumentId,
                _: u32,
            ) -> pacgate_core::Result<Vec<pacgate_core::Document>> {
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
            async fn search(
                &self,
                _: &pacgate_core::MatterId,
                _: &str,
                _: u32,
            ) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
                Ok(Vec::new())
            }
        }

        let dispatcher = Arc::new(pacgate_agent::ToolDispatcher::new(
            Arc::new(StubAll),
            Arc::new(StubAll),
            Arc::new(StubAll),
        ));
        let model_configs = pacgate_core::ModelConfig::default_local();
        let router = Arc::new(pacgate_llm::LlmRouter::new(
            model_configs,
            std::collections::HashMap::new(),
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
            doc_store: Arc::new(pacgate_docx::FsDocumentStore::new(
                pool.clone(),
                &std::path::PathBuf::from(TEST_DATA_DIR),
            )),
            matter_store: Arc::new(pacgate_tenant::MatterStore::new(pool.clone())),
            tenant_store: Arc::new(pacgate_tenant::TenantStore::new(pool.clone())),
            auth: Arc::new(pacgate_auth::AuthService::new("test-secret", pool.clone())),
            search: Arc::new(pacgate_search::default_router()),
            rag: None,
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
