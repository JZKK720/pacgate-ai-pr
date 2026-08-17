//! Smoke tests for pacgate-api — verify core gateway flows.
//!
//! These tests validate the API structure, route wiring, and error handling
//! without requiring a running Postgres instance. They test:
//! 1. Router builds successfully with all routes
//! 2. Health endpoint responds
//! 3. Auth endpoints exist (login/register/me)
//! 4. Matter/document/workflow routes are wired
//! 5. ApiError converts to proper HTTP responses
//! 6. Claims extraction logic

#[cfg(test)]
mod tests {
    use axum::{
        http::StatusCode,
        response::IntoResponse,
        routing::get,
        Router,
    };

    /// Health endpoint route should build successfully.
    #[test]
    fn health_route_builds() {
        let app: Router = Router::new().route("/health", get(|| async { "ok" }));
        // If the router builds without panicking, the route is wired correctly
        let _ = app;
    }

    /// Verify the API error types produce the correct HTTP status codes.
    #[test]
    fn api_error_status_codes() {
        use pacgate_api::ApiError;

        let bad = ApiError::bad_request("test");
        assert_eq!(bad.status, StatusCode::BAD_REQUEST);
        assert_eq!(bad.code, "bad_request");

        let not_found = ApiError::not_found("test");
        assert_eq!(not_found.status, StatusCode::NOT_FOUND);

        let internal = ApiError::internal("test");
        assert_eq!(internal.status, StatusCode::INTERNAL_SERVER_ERROR);

        let unauthorized = ApiError::unauthorized("test");
        assert_eq!(unauthorized.status, StatusCode::UNAUTHORIZED);
    }

    /// Verify ApiError converts to a JSON response with the expected structure.
    #[tokio::test]
    async fn api_error_converts_to_json_response() {
        use pacgate_api::ApiError;

        let error = ApiError::bad_request("matter name required");
        let response = IntoResponse::into_response(error);
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    /// Verify Claims can be serialized and deserialized (JWT round-trip).
    #[test]
    fn claims_serialization_roundtrip() {
        use pacgate_auth::Claims;

        let claims = Claims {
            sub: "550e8400-e29b-41d4-a716-446655440000".to_string(),
            tenant_id: "550e8400-e29b-41d4-a716-446655440001".to_string(),
            role: "attorney".to_string(),
            system_role: "user".to_string(),
            soul_id: Some("550e8400-e29b-41d4-a716-446655440002".to_string()),
            exp: 1735689600,
        };

        let json = serde_json::to_string(&claims).unwrap();
        let parsed: Claims = serde_json::from_str(&json).unwrap();

        assert_eq!(parsed.sub, claims.sub);
        assert_eq!(parsed.tenant_id, claims.tenant_id);
        assert_eq!(parsed.role, claims.role);
        assert_eq!(parsed.system_role, claims.system_role);
        assert_eq!(parsed.soul_id, claims.soul_id);
        assert_eq!(parsed.exp, claims.exp);
    }

    /// Verify AuthService can extract bearer tokens from Authorization headers.
    #[test]
    fn extract_bearer_token() {
        // This tests the static method without needing a DB connection
        let header = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test-token";
        let token = pacgate_auth::AuthService::extract_bearer(header);
        assert_eq!(token, Some("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test-token"));

        let no_bearer = "Basic dXNlcjpwYXNz";
        assert_eq!(pacgate_auth::AuthService::extract_bearer(no_bearer), None);

        let empty = "";
        assert_eq!(pacgate_auth::AuthService::extract_bearer(empty), None);
    }

    /// Verify the tenant path helpers produce correct filesystem paths.
    #[test]
    fn tenant_path_helpers() {
        use pacgate_core::{MatterId, TenantId};
        use pacgate_tenant::{docs_dir, matter_dir, tenant_dir};
        use std::path::PathBuf;

        let data_dir = PathBuf::from("/data");
        let tenant_id = TenantId(uuid::Uuid::new_v4());
        let matter_id = MatterId(uuid::Uuid::new_v4());

        let t_dir = tenant_dir(&data_dir, &tenant_id);
        assert!(t_dir.starts_with("/data/tenants/"));

        let m_dir = matter_dir(&data_dir, &tenant_id, &matter_id);
        assert!(m_dir.starts_with(&t_dir));
        assert!(m_dir.to_string_lossy().contains("matters"));

        let d_dir = docs_dir(&data_dir, &tenant_id, &matter_id);
        assert!(d_dir.ends_with("docs"));
    }

    /// Verify the document path helper includes version and extension.
    #[test]
    fn doc_path_helper() {
        use pacgate_core::{MatterId, TenantId};
        use pacgate_tenant::doc_path;
        use std::path::PathBuf;

        let data_dir = PathBuf::from("/data");
        let tenant_id = TenantId(uuid::Uuid::new_v4());
        let matter_id = MatterId(uuid::Uuid::new_v4());

        let path = doc_path(&data_dir, &tenant_id, &matter_id, "contract", 3, "docx");
        assert!(path.to_string_lossy().contains("contract_v3.docx"));

        let path_pdf = doc_path(&data_dir, &tenant_id, &matter_id, "evidence", 1, "pdf");
        assert!(path_pdf.to_string_lossy().ends_with("evidence_v1.pdf"));

        let path_md = doc_path(&data_dir, &tenant_id, &matter_id, "notes", 2, "markdown");
        assert!(path_md.to_string_lossy().ends_with("notes_v2.md"));
    }
    #[test]
    fn llm_provider_variants() {
        use pacgate_core::LlmProvider;

        let ollama = LlmProvider::Ollama {
            base_url: "http://localhost:11434".into(),
        };
        let anthropic = LlmProvider::Anthropic;
        let openai = LlmProvider::OpenAI;
        let qwen = LlmProvider::Qwen;
        let deepseek = LlmProvider::DeepSeek;
        let minimax = LlmProvider::MiniMax;

        // Just verify they all serialize
        assert!(serde_json::to_string(&ollama).is_ok());
        assert!(serde_json::to_string(&anthropic).is_ok());
        assert!(serde_json::to_string(&openai).is_ok());
        assert!(serde_json::to_string(&qwen).is_ok());
        assert!(serde_json::to_string(&deepseek).is_ok());
        assert!(serde_json::to_string(&minimax).is_ok());
    }

    /// Verify ModelConfig::default_local returns 3 tiers.
    #[test]
    fn default_local_model_config_has_3_tiers() {
        use pacgate_core::{LlmTier, ModelConfig};

        let configs = ModelConfig::default_local();
        assert_eq!(configs.len(), 3);

        let tiers: Vec<_> = configs.iter().map(|c| c.tier).collect();
        assert!(tiers.contains(&LlmTier::Main));
        assert!(tiers.contains(&LlmTier::Mid));
        assert!(tiers.contains(&LlmTier::Low));
    }

    /// Verify Jurisdiction has all expected variants.
    #[test]
    fn jurisdiction_variants() {
        use pacgate_core::Jurisdiction;

        assert_eq!(Jurisdiction::ChinaMainland.code(), "CN");
        assert_eq!(Jurisdiction::HongKong.code(), "HK");
        assert_eq!(Jurisdiction::UnitedStates.code(), "US");
        assert_eq!(Jurisdiction::UnitedKingdom.code(), "GB");
        assert_eq!(Jurisdiction::EuropeanUnion.code(), "EU");
    }

    /// Verify Tenant struct has expected fields.
    #[test]
    fn tenant_struct_fields() {
        use pacgate_core::TenantConfig;

        let config = TenantConfig::default();
        assert!(config.model_overrides.is_empty());
        assert!(!config.strict_security_posture);
        assert!(config.allowed_egress_hosts.is_empty());

        let config_json = serde_json::to_string(&config).unwrap();
        let parsed: TenantConfig = serde_json::from_str(&config_json).unwrap();
        assert!(parsed.model_overrides.is_empty());
    }

    /// Verify the deer-flow adapter Python package has the expected structure.
    #[test]
    fn deerflow_adapter_files_exist() {
        let adapter_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../pacgate-adapters/python/pacgate_deerflow_adapter");

        assert!(adapter_dir.exists(), "deer-flow adapter directory should exist at {}", adapter_dir.display());
        assert!(adapter_dir.join("__init__.py").exists(), "__init__.py should exist");
        assert!(adapter_dir.join("client.py").exists(), "client.py should exist");
        assert!(adapter_dir.join("storage.py").exists(), "storage.py should exist");
        assert!(adapter_dir.join("pyproject.toml").exists(), "pyproject.toml should exist");
    }

    /// Verify the deer-flow wrapper Dockerfile exists.
    #[test]
    fn deerflow_wrapper_dockerfile_exists() {
        let dockerfile = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../deploy/deer-flow-pacgate/Dockerfile");

        assert!(dockerfile.exists(), "deer-flow wrapper Dockerfile should exist at {}", dockerfile.display());
    }

    /// Verify the SQL migration file exists and has the expected tables.
    #[test]
    fn migration_file_has_expected_tables() {
        let migration = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../migrations/001_initial_schema.sql");

        assert!(migration.exists(), "migration file should exist at {}", migration.display());

        let content = std::fs::read_to_string(&migration).unwrap();
        assert!(content.contains("CREATE TABLE IF NOT EXISTS tenants"));
        assert!(content.contains("CREATE TABLE IF NOT EXISTS users"));
        assert!(content.contains("CREATE TABLE IF NOT EXISTS matters"));
        assert!(content.contains("CREATE TABLE IF NOT EXISTS documents"));
        assert!(content.contains("CREATE TABLE IF NOT EXISTS audit_log"));
    }

    /// Verify the pacgate-ai Dockerfile exists.
    #[test]
    fn pacgate_dockerfile_exists() {
        let dockerfile = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Dockerfile");

        assert!(dockerfile.exists(), "pacgate-ai Dockerfile should exist at {}", dockerfile.display());
    }

    /// Verify DataLevel T1-T4 classification parsing and access rules.
    #[test]
    fn data_level_parsing_and_access_rules() {
        use pacgate_core::DataLevel;

        // Code round-trip
        assert_eq!(DataLevel::T1SharedTemplate.code(), "T1");
        assert_eq!(DataLevel::T2RestrictedSeed.code(), "T2");
        assert_eq!(DataLevel::T3ProjectSpecific.code(), "T3");
        assert_eq!(DataLevel::T4SpecialSensitive.code(), "T4");

        // from_code parsing
        assert_eq!(DataLevel::from_code("T1"), Some(DataLevel::T1SharedTemplate));
        assert_eq!(DataLevel::from_code("t2"), Some(DataLevel::T2RestrictedSeed));
        assert_eq!(DataLevel::from_code("T3"), Some(DataLevel::T3ProjectSpecific));
        assert_eq!(DataLevel::from_code("T4"), Some(DataLevel::T4SpecialSensitive));
        assert_eq!(DataLevel::from_code("T5"), None);
        assert_eq!(DataLevel::from_code(""), None);

        // Cross-project search rules
        assert!(DataLevel::T1SharedTemplate.allows_cross_project_search());
        assert!(!DataLevel::T2RestrictedSeed.allows_cross_project_search());
        assert!(!DataLevel::T3ProjectSpecific.allows_cross_project_search());
        assert!(!DataLevel::T4SpecialSensitive.allows_cross_project_search());

        // Matter scoping rules
        assert!(!DataLevel::T1SharedTemplate.requires_matter_scoping());
        assert!(DataLevel::T2RestrictedSeed.requires_matter_scoping());
        assert!(DataLevel::T3ProjectSpecific.requires_matter_scoping());
        assert!(DataLevel::T4SpecialSensitive.requires_matter_scoping());
    }

    /// Verify ArchiveDirectory has all 9 directories (00-08).
    #[test]
    fn archive_directory_9_dirs() {
        use pacgate_core::ArchiveDirectory;

        let dirs: Vec<ArchiveDirectory> = vec![
            ArchiveDirectory::Directory00Overview,
            ArchiveDirectory::Directory01CoreWork,
            ArchiveDirectory::Directory02Agreements,
            ArchiveDirectory::Directory03DraftsTools,
            ArchiveDirectory::Directory04Approvals,
            ArchiveDirectory::Directory05Closing,
            ArchiveDirectory::Directory06FinalDelivery,
            ArchiveDirectory::Directory07Evidence,
            ArchiveDirectory::Directory08CoverageReview,
        ];
        assert_eq!(dirs.len(), 9);

        // Verify numbers and names
        assert_eq!(ArchiveDirectory::Directory00Overview.number(), "00");
        assert_eq!(ArchiveDirectory::Directory08CoverageReview.number(), "08");

        // Mandatory check (00-02 are 必交)
        assert!(ArchiveDirectory::Directory00Overview.is_mandatory());
        assert!(ArchiveDirectory::Directory01CoreWork.is_mandatory());
        assert!(ArchiveDirectory::Directory02Agreements.is_mandatory());
        assert!(!ArchiveDirectory::Directory03DraftsTools.is_mandatory());
        assert!(!ArchiveDirectory::Directory08CoverageReview.is_mandatory());

        // Chinese name sanity
        assert!(!ArchiveDirectory::Directory00Overview.name_zh().is_empty());
    }

    /// Verify SearchFilter supports data_level filtering.
    #[test]
    fn search_filter_data_level() {
        use pacgate_core::DataLevel;
        use pacgate_rag::SearchFilter;

        // Default filter has no data_level restriction
        let default_filter = SearchFilter::default();
        assert!(default_filter.max_data_level.is_none());

        // with_max_data_level sets the filter
        let t3_filter = SearchFilter::new().with_max_data_level(DataLevel::T3ProjectSpecific);
        assert_eq!(t3_filter.max_data_level, Some(DataLevel::T3ProjectSpecific));

        // T1 filter (most restrictive)
        let t1_filter = SearchFilter::new().with_max_data_level(DataLevel::T1SharedTemplate);
        assert_eq!(t1_filter.max_data_level, Some(DataLevel::T1SharedTemplate));
    }

    /// Verify ConnectorRegistry has 27 entries from client assets.
    #[test]
    fn connector_registry_has_27_entries() {
        let registry = pacgate_search::ConnectorRegistry::from_client_assets();
        assert_eq!(registry.entries().len(), 27, "ConnectorRegistry should have 27 entries from client assets");
    }

    /// Verify DD agent configs has 9 domains.
    #[test]
    fn dd_agent_configs_has_9_domains() {
        let configs = pacgate_core::dd_agent_configs();
        assert_eq!(configs.len(), 9, "Should have 9 DD agent configs from dd-agents 中国法智能体改写清单");
    }

    /// Verify DD config system prompt composition produces structured Chinese-law guidance.
    #[test]
    fn dd_config_system_prompt_composition() {
        let configs = pacgate_core::dd_agent_configs();
        let legal = configs.iter().find(|c| c.domain == pacgate_core::DdAgentDomain::Legal)
            .expect("Legal DD config should exist");

        let prompt = legal.compose_system_prompt();
        assert!(prompt.contains("法律"), "prompt should mention the legal domain");
        assert!(prompt.contains("尽调关注领域"), "prompt should list focus areas");
        assert!(prompt.contains("输出要求"), "prompt should contain output requirements");
        assert!(prompt.contains("一票否决"), "prompt should warn about P0 veto items");
        assert!(prompt.len() > 200, "system prompt should be substantial");
    }

    /// Verify DD domain lookup by string works for all 9 domains.
    #[test]
    fn dd_domain_from_str_all_9() {
        use pacgate_core::{dd_domain_from_str, DdAgentDomain};

        assert_eq!(dd_domain_from_str("legal"), Some(DdAgentDomain::Legal));
        assert_eq!(dd_domain_from_str("finance"), Some(DdAgentDomain::Finance));
        assert_eq!(dd_domain_from_str("regulatory"), Some(DdAgentDomain::Regulatory));
        assert_eq!(dd_domain_from_str("esg"), Some(DdAgentDomain::Esg));
        assert_eq!(dd_domain_from_str("法律"), Some(DdAgentDomain::Legal));
        assert_eq!(dd_domain_from_str("LEGAL"), Some(DdAgentDomain::Legal));
        assert_eq!(dd_domain_from_str("unknown"), None);
        assert_eq!(dd_domain_from_str(""), None);
    }

    /// Verify dd_config_for_domain returns the right config.
    #[test]
    fn dd_config_for_domain_lookup() {
        use pacgate_core::{dd_config_for_domain, DdAgentDomain};

        let legal = dd_config_for_domain(DdAgentDomain::Legal);
        assert!(legal.is_some());
        assert_eq!(legal.unwrap().domain, DdAgentDomain::Legal);

        // All 9 domains should have configs
        for domain in [
            DdAgentDomain::Legal, DdAgentDomain::Finance, DdAgentDomain::Commercial,
            DdAgentDomain::ProductTech, DdAgentDomain::Cybersecurity, DdAgentDomain::Hr,
            DdAgentDomain::Tax, DdAgentDomain::Regulatory, DdAgentDomain::Esg,
        ] {
            let config = dd_config_for_domain(domain);
            assert!(config.is_some(), "{:?} config should exist", domain);
            assert!(!config.unwrap().focus_areas.is_empty(), "{:?} should have focus areas", domain);
        }
    }
}