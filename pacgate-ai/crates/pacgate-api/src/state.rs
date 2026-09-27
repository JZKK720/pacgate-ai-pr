use std::sync::Arc;

use pacgate_agent::{AgentLoop, ToolDispatcher};
use pacgate_auth::AuthService;
use pacgate_docx::FsDocumentStore;
use pacgate_llm::LlmRouter;
use pacgate_rag::RagStore;
use pacgate_search::SearchRouter;
use pacgate_tenant::{MatterStore, TenantStore};

/// How many sanitize jobs may hold a detector set at once.
///
/// A sanitize job builds its own detector set, and with NER enabled that is a
/// 393 MiB allocation of resident F32 weights (measured 2026-09-27). Without a
/// bound, concurrency equals the Tokio worker count - 32 on the client hardware,
/// which has no CPU cap in compose - so the worst case is 32 x 393 MiB = 12.6 GiB
/// and an out-of-memory kill.
///
/// 2 keeps the detector peak near 786 MiB. This endpoint is a document job, not a
/// latency-critical one, so queueing beats allocating a larger peak.
pub const SANITIZE_MAX_CONCURRENT: usize = 2;

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
    /// Embedding service for ingesting extracted OCR text as pending chunks.
    pub embedding: pacgate_rag::EmbeddingService,
    pub db: sqlx::PgPool,
    /// Admission control for sanitize jobs. See `SANITIZE_MAX_CONCURRENT`.
    /// Held for the duration of the detector build and the sanitize call.
    pub sanitize_slots: Arc<tokio::sync::Semaphore>,
}

impl AppState {
    /// Resolve the LLM router for a tenant. If the tenant's
    /// `config_json.model_overrides` is non-empty, build a router from those
    /// overrides; otherwise fall back to the shared default router.
    pub async fn router_for_tenant(
        &self,
        tenant_id: &pacgate_core::TenantId,
    ) -> Result<Arc<LlmRouter>, pacgate_core::PacgateError> {
        let tenant = self
            .tenant_store
            .get(tenant_id)
            .await
            .map_err(|e| {
                pacgate_core::PacgateError::ValidationError(format!(
                    "tenant lookup failed: {e}"
                ))
            })?;

        if tenant.config.model_overrides.is_empty() {
            return Ok(self.router.clone());
        }

        Ok(Arc::new(LlmRouter::new(
            tenant.config.model_overrides.clone(),
            std::collections::HashMap::new(),
        )))
    }

    /// Take a sanitize slot, or `None` when both are in use.
    ///
    /// Non-blocking on purpose: the caller decides what to do, and returns 503.
    /// Failing closed means a *rejected* job, never a silently skipped one - if a
    /// job were dropped instead, its document would stay `pending` and
    /// unsearchable while the caller believed the sanitize had succeeded.
    pub fn try_acquire_sanitize_slot(&self) -> Option<tokio::sync::OwnedSemaphorePermit> {
        self.sanitize_slots.clone().try_acquire_owned().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_admission_bound_is_small_deliberately_and_documented() {
        // The tripwire on the number. Raising the constant without redoing the
        // arithmetic below should require deleting an assertion that says why.
        assert_eq!(
            SANITIZE_MAX_CONCURRENT, 2,
            "changing this changes peak memory: 393 MiB per concurrent sanitize \
             job, measured 2026-09-27. Re-measure before raising it."
        );
        assert!(
            SANITIZE_MAX_CONCURRENT * 393 < 1024,
            "keep the detector-memory peak under 1 GiB: {} x 393 MiB",
            SANITIZE_MAX_CONCURRENT
        );
    }
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
    /// Base URL of ocr-service, e.g. http://ocr-service:8100. None disables
    /// extraction (fail closed: extract_document errors rather than guessing).
    pub ocr_service_url: Option<String>,
    /// Directory with the local NER weights (config.json, model.safetensors,
    /// vocab.txt). None runs Tier-1 rules only; Some-but-broken fails the job.
    pub ner_model_dir: Option<String>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            data_dir: std::path::PathBuf::from("./data"),
            max_upload_mb: 50,
            jwt_secret: "change-me-in-production".to_string(),
            default_tenant: "default-firm".to_string(),
            workflows_dir: None,
            ocr_service_url: None,
            ner_model_dir: None,
        }
    }
}
