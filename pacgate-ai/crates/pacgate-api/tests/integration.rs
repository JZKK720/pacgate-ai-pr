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
            ocr_service_url: None,
            ner_model_dir: None,
            // `true` because this test registers users DIRECTLY through
            // `AuthService::register`, not through the HTTP route, so the gate
            // does not participate. It is set explicitly rather than relying on a
            // default so the value is visible here.
            //
            // NOT covered by this file: the first-user-only behaviour of the
            // `POST /api/auth/register` ROUTE. An earlier version of this comment
            // claimed the test "asserts first-user-only separately" - it does not.
            // Nothing in this file or in `tests/smoke.rs` exercises that route, the
            // `/api/auth/users` route, or their placement relative to the auth
            // middleware. Those are covered by `scripts/test-auth-registration-gate.ps1`
            // against a running stack. Say so here rather than implying coverage
            // that does not exist - a false claim of coverage is worse than a
            // known gap, because it stops anyone from looking.
            allow_registration: true,
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
            "user",
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
            embedding: pacgate_rag::EmbeddingService::new("http://127.0.0.1:1", "nomic-embed-text"),
            db: pool,
            // A test harness gets its own semaphore. Size is irrelevant here:
            // these tests drive one request at a time.
            sanitize_slots: Arc::new(tokio::sync::Semaphore::new(
                pacgate_api::SANITIZE_MAX_CONCURRENT,
            )),
        };

        // Keep an Arc handle to the document store BEFORE `state` is moved into
        // the router. The HTTP download route is gated (design 5.1) and refuses
        // an unsanitized document, so proving persisted bytes requires reading
        // through the store - the same method the route calls after its gate.
        let doc_store_for_asserts = state.doc_store.clone();

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

        // ── 6a. An UNKNOWN matter id is a 404, not a 500 ──
        //
        // Regression: get_matter flattened every store error into
        // ApiError::internal, so a well-formed-but-missing id returned 500
        // while a malformed one returned 400. The store already discriminated
        // RowNotFound (From<sqlx::Error> -> TenantError::MatterNotFound); the
        // handler threw it away.
        //
        // This is not cosmetic. install.ps1 probes GET /api/matters/<id> to
        // decide whether a configured PACGATE_MATTER_ID is real, and a 500 is
        // indistinguishable from "the API is down" - so the installer could not
        // tell a stale id from a dead service, which is precisely the state the
        // silent FileMemoryStorage fallback lives in.
        let missing = "00000000-0000-4000-8000-000000000000";
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{missing}"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let probe_status = response.status();
        let probe_body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let probe_text = String::from_utf8_lossy(&probe_body).to_string();
        assert_eq!(
            probe_status,
            StatusCode::NOT_FOUND,
            "an unknown matter id must be 404 so a caller can tell it apart from a server fault. Body was: {probe_text}"
        );

        // A malformed id stays a 400 - the two failure modes must not collapse.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri("/api/matters/not-a-uuid")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "a malformed matter id is a 400, distinct from the 404 for a missing one"
        );

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

        // The SERVER now owns `revision` (it is assigned on every successful
        // write, so the concurrency guard has something to compare). The caller's
        // body fields must still round-trip untouched - only the server-owned
        // counter is added, so the round-trip is lossless apart from that field.
        let mut expected = memory_body.clone();
        let revision = saved_memory
            .get("revision")
            .and_then(|v| v.as_u64())
            .expect("the server must assign a revision");
        assert!(
            revision >= 1,
            "the first write must advance the revision from the default 0, got {revision}"
        );
        expected["revision"] = serde_json::Value::from(revision);
        assert_eq!(
            saved_memory, expected,
            "matter memory round-trip should be lossless apart from the \
             server-assigned revision"
        );

        // ── 6b. The concurrency guard is CONNECTED (not merely present) ──
        //
        // This is the assertion whose absence let the guard be dead at three
        // layers at once. Each piece had passing tests; nothing tested them
        // TOGETHER, and a guard is only real where it can REJECT.

        // A caller holding a STALE revision must be refused.
        let stale = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .header("if-match", "0")
                    .body(Body::from(r#"{"facts":[{"text":"stale overwrite"}]}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            stale.status(),
            StatusCode::CONFLICT,
            "a caller holding a stale revision must get 409, not a silent overwrite"
        );

        // And the rejected write must not have modified the file: a 409 that had
        // already truncated the file would be worse than no guard.
        let reread = app
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
        let reread_bytes = axum::body::to_bytes(reread.into_body(), usize::MAX)
            .await
            .unwrap();
        let after: serde_json::Value = serde_json::from_slice(&reread_bytes).unwrap();
        assert_eq!(
            after["facts"][0]["text"], "Client prefers concise updates",
            "the REJECTED write must not have modified the file"
        );
        assert_eq!(
            after["revision"].as_u64(),
            Some(revision),
            "a rejected write must not advance the revision"
        );

        // A caller holding the CURRENT revision succeeds and advances it.
        let good = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .header("if-match", revision.to_string())
                    .body(Body::from(r#"{"facts":[{"text":"second write"}]}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            good.status(),
            StatusCode::OK,
            "a caller holding the current revision must be accepted"
        );
        let good_bytes = axum::body::to_bytes(good.into_body(), usize::MAX)
            .await
            .unwrap();
        let second: serde_json::Value = serde_json::from_slice(&good_bytes).unwrap();
        assert_eq!(
            second["revision"].as_u64(),
            Some(revision + 1),
            "an accepted write must advance the revision"
        );

        // ── 6c. The memory SCOPE is enforced end to end ──
        //
        // Memory holds process, not matter facts. Asserted through the real router,
        // because a policy that is only unit-tested is a policy that can be unwired
        // without anyone noticing.

        // A checksum-valid resident ID must be refused.
        let with_id = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(
                        r#"{"facts":[{"content":"Client ID 11010519491231002X"}]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            with_id.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "an identifier in memory must be refused with 422, not stored"
        );

        // A PROCESS SUMMARY must still be accepted. This assertion matters as much
        // as the refusal: a gate that fires on legitimate traffic gets disabled,
        // which is how the If-Match guard came to be dead at three layers.
        let prose = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .header("if-match", (revision + 1).to_string())
                    .body(Body::from(
                        r#"{"facts":[{"content":"The firm reviewed the matter with the user."}]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            prose.status(),
            StatusCode::OK,
            "a process summary must be accepted: a gate that fires on legitimate \
             traffic gets disabled"
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

        // ── 10. Download is refused while the document is unsanitized ──

        // The download route is gated (design 5.1): it refuses anything that is
        // not 'sanitized' or explicitly 'never'. 'pending' is the DEFAULT state,
        // so a freshly uploaded document MUST be refused here.
        //
        // This test previously asserted 200 unconditionally, which was correct
        // before the gate existed and became WRONG the moment it landed - it then
        // failed with 409. The refusal is the contract, so assert the refusal.
        //
        // WHY THE FULL DOWNLOAD IS NOT EXERCISED HERE
        // -------------------------------------------
        // Opening the gate requires POST /api/documents/:id/sanitize, which runs
        // extract_document first, which on a cache miss calls ocr-service over
        // HTTP. This test builds AppState in-process with `ocr_service_url: None`
        // (see the config above), so sanitize fails closed with
        // "ocr-service not configured". That is the intended fail-closed
        // behaviour, not a defect.
        //
        // The sanitize-then-download order is therefore proven where it belongs:
        // `scripts/test-sanitizer-e2e.ps1` drives a REAL container with
        // ocr-service attached, and asserts exactly this sequence - the doc is
        // refused while pending, then ALLOWED once sanitized. Do not "restore"
        // the 200 assertion here; it is the assertion this change fixes.
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
            StatusCode::CONFLICT,
            "an unsanitized document must be refused by the egress gate"
        );

        // The byte-for-byte body assertions that used to live here are GONE, and
        // deliberately so. They asserted that both versions download with exactly
        // the uploaded content, which is true only of a document that is allowed
        // to leave. The egress gate refuses 'pending', so there is no body to
        // compare - comparing one produced this failure:
        //
        //   left:  {"error":{"code":"conflict","message":"document is 'pending';
        //          download requires sanitization (or explicit 'never')"}}
        //   right: "integration-test-document"
        //
        // Proving the bytes requires a sanitized document, and sanitizing needs
        // ocr-service (see the note above), which this in-process test does not
        // have. The refusal asserted above IS the complete, checkable contract for
        // an unsanitized document, and the byte-level download is covered by
        // scripts/test-sanitizer-e2e.ps1 against a real stack.
        //
        // The two uploads still matter: they are what create version 2 and the
        // version list asserted in step 9, so their bytes are still read below to
        // build the multipart bodies.

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

        // Read the persisted bytes through the STORE, not the HTTP route. The
        // route is gated (design 5.1) and refuses an unsanitized document, so it
        // cannot serve a body to assert on - see the note in step 10. The store
        // is the same code path the route uses internally after the gate
        // (documents.rs calls this exact method), so this still proves the accept
        // operation persisted the replacement text; it just does not re-test the
        // gate here, which step 10 already covers.
        let docx_id_parsed: pacgate_core::DocumentId = docx_document_id
            .parse()
            .expect("docx id should parse as a DocumentId");
        let (_, body_bytes) = doc_store_for_asserts
            .download_bytes(&docx_id_parsed, None)
            .await
            .expect("accepted docx should be readable from the store");
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
            ocr_service_url: None,
            ner_model_dir: None,
            allow_registration: true,
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
                std::path::PathBuf::from(TEST_DATA_DIR),
            )),
            matter_store: Arc::new(pacgate_tenant::MatterStore::new(pool.clone())),
            tenant_store: Arc::new(pacgate_tenant::TenantStore::new(pool.clone())),
            auth: Arc::new(pacgate_auth::AuthService::new("test-secret", pool.clone())),
            search: Arc::new(pacgate_search::default_router()),
            rag: None,
            embedding: pacgate_rag::EmbeddingService::new("http://127.0.0.1:1", "nomic-embed-text"),
            db: pool,
            // A test harness gets its own semaphore. Size is irrelevant here:
            // these tests drive one request at a time.
            sanitize_slots: Arc::new(tokio::sync::Semaphore::new(
                pacgate_api::SANITIZE_MAX_CONCURRENT,
            )),
        };

        // Keep an Arc handle to the document store BEFORE `state` is moved into
        // the router. The HTTP download route is gated (design 5.1) and refuses
        // an unsanitized document, so proving persisted bytes requires reading
        // through the store - the same method the route calls after its gate.
        let _doc_store_for_asserts = state.doc_store.clone();

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

    /// The matter-workspace rollup (workspace.rs): one response gathering the
    /// matter's documents, extraction records, and RAG/sanitizer lane status.
    ///
    /// Requires a running Postgres with pgvector. Run with `--ignored` like the
    /// other integration tests.
    ///
    /// Covers:
    ///   1. a fresh matter answers 200 with empty sections (aggregation must
    ///      not require every lane to have data)
    ///   2. after an upload, documents[] carries the uploaded document with
    ///      its sanitization_state (which drives the egress gate)
    ///   3. the owner tenant reads it; a second tenant reads it as 404
    ///   4. RAG rollup stays empty (no chunks ingested in this flow) and
    ///      extractions stay empty (no ocr-service) - the response must
    ///      DEGRADE, not fail, when a lane has no data
    #[tokio::test]
    #[ignore]
    async fn matter_workspace_rollup() {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(3)
            .connect(&test_db_url())
            .await
            .expect("failed to connect to test Postgres — is it running?");

        pacgate_tenant::run_migrations(&pool)
            .await
            .expect("failed to run tenant migrations");
        run_rag_migrations_if_available(&pool).await;

        let tenant_id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO tenants (name, slug) VALUES ($1, $2)
             ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
        )
        .bind("Workspace Test Firm")
        .bind(format!("workspace-firm-{}", uuid::Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("failed to seed workspace-test tenant");

        let other_tenant_id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO tenants (name, slug) VALUES ($1, $2)
             ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
             RETURNING id",
        )
        .bind("Workspace Test Firm Two")
        .bind(format!("workspace-firm-two-{}", uuid::Uuid::new_v4().simple()))
        .fetch_one(&pool)
        .await
        .expect("failed to seed second workspace-test tenant");

        let email = format!("workspace-{}@pacgate.test", uuid::Uuid::new_v4().simple());
        let other_email = format!(
            "workspace-other-{}@pacgate.test",
            uuid::Uuid::new_v4().simple()
        );
        let password = "workspace-pass-123";

        let config = Arc::new(pacgate_api::AppConfig {
            data_dir: std::path::PathBuf::from(TEST_DATA_DIR),
            max_upload_mb: 50,
            jwt_secret: "test-secret-key".to_string(),
            default_tenant: "workspace-test".to_string(),
            workflows_dir: None,
            ocr_service_url: None,
            ner_model_dir: None,
            allow_registration: true,
        });

        let doc_store = Arc::new(pacgate_docx::FsDocumentStore::new(
            pool.clone(),
            &config.data_dir,
        ));

        let auth = Arc::new(pacgate_auth::AuthService::new(
            config.jwt_secret.clone(),
            pool.clone(),
        ));
        let tenant_id_core = pacgate_core::TenantId(tenant_id);
        let other_tenant_id_core = pacgate_core::TenantId(other_tenant_id);
        auth.register(
            &tenant_id_core,
            &email,
            password,
            "attorney",
            "user",
            Some("Workspace Tester"),
        )
        .await
        .expect("failed to create workspace-test user");
        auth.register(
            &other_tenant_id_core,
            &other_email,
            password,
            "attorney",
            "user",
            Some("Other Tenant Tester"),
        )
        .await
        .expect("failed to create second-tenant user");

        let state = pacgate_api::AppState {
            agent_loop: Arc::new(pacgate_agent::AgentLoop::new(
                Arc::new(pacgate_llm::LlmRouter::new(
                    pacgate_core::ModelConfig::default_local(),
                    std::collections::HashMap::new(),
                )),
                Arc::new(pacgate_agent::ToolDispatcher::new(
                    doc_store.clone() as Arc<dyn pacgate_core::DocumentStore>,
                    Arc::new(StubWorkflowForWorkspace),
                    Arc::new(StubKbForWorkspace),
                )),
            )),
            router: Arc::new(pacgate_llm::LlmRouter::new(
                pacgate_core::ModelConfig::default_local(),
                std::collections::HashMap::new(),
            )),
            dispatcher: Arc::new(pacgate_agent::ToolDispatcher::new(
                doc_store.clone() as Arc<dyn pacgate_core::DocumentStore>,
                Arc::new(StubWorkflowForWorkspace),
                Arc::new(StubKbForWorkspace),
            )),
            config,
            doc_store,
            matter_store: Arc::new(pacgate_tenant::MatterStore::new(pool.clone())),
            tenant_store: Arc::new(pacgate_tenant::TenantStore::new(pool.clone())),
            auth,
            search: Arc::new(pacgate_search::default_router()),
            rag: None,
            embedding: pacgate_rag::EmbeddingService::new("http://127.0.0.1:1", "nomic-embed-text"),
            db: pool,
            sanitize_slots: Arc::new(tokio::sync::Semaphore::new(
                pacgate_api::SANITIZE_MAX_CONCURRENT,
            )),
        };

        let app = pacgate_api::build_router(state);

        // Login both users.
        let login = |email: &str| {
            let app = app.clone();
            let body = serde_json::to_vec(&serde_json::json!({
                "email": email,
                "password": password
            }))
            .unwrap();
            async move {
                let response = app
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri("/api/auth/login")
                            .header("content-type", "application/json")
                            .body(Body::from(body))
                            .unwrap(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response.status(), StatusCode::OK, "login should pass");
                let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
                    .await
                    .unwrap();
                let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
                json["token"].as_str().expect("login token present").to_string()
            }
        };
        let token = login(&email).await;
        let other_token = login(&other_email).await;

        // Fresh matter (owner tenant).
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/matters")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(
                        serde_json::to_vec(&serde_json::json!({
                            "name": "Workspace Test Matter"
                        }))
                        .unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "matter create passes");
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let matter_json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let matter_id = matter_json["id"].as_str().expect("matter id").to_string();

        // 1. Fresh matter: 200 with empty sections.
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/workspace"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::OK,
            "a fresh matter's workspace view must answer 200 with empty sections"
        );
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let fresh: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            fresh["matter_id"].as_str(),
            Some(matter_id.as_str()),
            "rollup must carry the matter id"
        );
        assert_eq!(
            fresh["documents"].as_array().map(|a| a.len()),
            Some(0),
            "fresh matter has no documents"
        );
        assert_eq!(
            fresh["extractions"].as_array().map(|a| a.len()),
            Some(0),
            "fresh matter has no extraction records"
        );
        assert_eq!(
            fresh["rag_documents"].as_array().map(|a| a.len()),
            Some(0),
            "fresh matter has no RAG rollup rows"
        );

        // 2. Upload a document; the workspace view must list it with its
        //    sanitization_state.
        let boundary = "----wsp";
        let prefix = format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"matter_id\"\r\n\r\n{matter_id}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"summary.md\"\r\nContent-Type: text/markdown\r\n\r\n"
        );
        let suffix = format!("\r\n--{boundary}--\r\n");
        let mut body = prefix.into_bytes();
        body.extend_from_slice(b"# Workspace rollup proof");
        body.extend_from_slice(suffix.as_bytes());

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
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "upload passes");
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let uploaded: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let document_id = uploaded["id"].as_str().expect("document id").to_string();

        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/workspace"))
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let with_doc: serde_json::Value = serde_json::from_slice(&bytes).unwrap();

        let docs = with_doc["documents"].as_array().expect("documents array");
        assert_eq!(docs.len(), 1, "the uploaded document appears");
        // The name is the file STEM, not the raw filename: upload_bytes (the
        // same store every other document route reads through) strips the
        // extension and keeps it in the `format` column - verified 2026-10-05
        // by reading store.rs. The workspace view reports what the store holds.
        assert_eq!(docs[0]["name"], "summary");
        assert_eq!(docs[0]["format"], "markdown");
        assert_eq!(docs[0]["id"].as_str(), Some(document_id.as_str()));
        // The state drives the egress gate - the workspace view exposes it.
        assert_eq!(
            docs[0]["sanitization_state"], "pending",
            "a fresh upload reads as pending in the workspace rollup"
        );
        // Extractions and RAG stay empty (no ocr-service, no chunks) - the
        // response must degrade, not fail.
        assert_eq!(
            with_doc["extractions"].as_array().map(|a| a.len()),
            Some(0),
            "no extraction records yet"
        );
        assert_eq!(
            with_doc["rag_documents"].as_array().map(|a| a.len()),
            Some(0),
            "no RAG rollup rows yet"
        );

        // 3. The OTHER tenant reads the same URL as 404 (tenant boundary).
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(format!("/api/matters/{matter_id}/workspace"))
                    .header("authorization", format!("Bearer {other_token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::NOT_FOUND,
            "cross-tenant workspace view must be hidden, not leaked"
        );
    }

    struct StubWorkflowForWorkspace;
    #[async_trait::async_trait]
    impl pacgate_core::WorkflowStore for StubWorkflowForWorkspace {
        async fn get_prompt(&self, _: &str) -> pacgate_core::Result<String> {
            Ok(String::new())
        }
    }

    struct StubKbForWorkspace;
    #[async_trait::async_trait]
    impl pacgate_core::KbStore for StubKbForWorkspace {
        async fn search(
            &self,
            _: &pacgate_core::MatterId,
            _: &str,
            _: u32,
        ) -> pacgate_core::Result<Vec<pacgate_core::KbChunk>> {
            Ok(Vec::new())
        }
    }
}
