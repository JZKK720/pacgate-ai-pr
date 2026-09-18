//! Sanitize job service - the API-side orchestrator.
//!
//! Owns the DETECT/DECIDE/REPLACE/VERIFY pipeline around pacgate-redact and
//! persists the two artifacts the design requires: the vault (mapping) in
//! `sanitizer_jobs` and the evidence in `redaction_ledger_rows`. The state
//! promotion is atomic per document: a version completes or it stays pending.
//!
//! The vault never leaves pacgate-api. Only this module reads the mapping
//! column; restore is an API endpoint, never an MCP tool (design 3.5).

use axum::extract::{Extension, Path, State};
use pacgate_core::{DataLevel, DocumentId, MatterId, TenantId, UserId};
use pacgate_redact::detect;
use pacgate_redact::MappingVersion;
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::error::ApiError;
use crate::state::AppState;

/// Promote this document's pending chunks + the document rollup after a
/// clean verdict. Scoped to one document (locked decision 3: atomic).
const MARK_SANITIZED_DOC_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'sanitized' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";

/// A Block verdict writes 'blocked' so the row can never be promoted by a
/// later run on a different document (the pending-only guard in 005/ingest).
const MARK_BLOCKED_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'blocked' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";

/// Document-level rollup mirrors the chunk states (design 5.1).
const MARK_SANITIZED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'sanitized' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

const MARK_BLOCKED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'blocked' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

/// Audit actions (stable codes; the review panel and tests rely on them).
const AUDIT_SANITIZE: &str = "document.sanitize";
const AUDIT_RESTORE: &str = "document.restore";

#[derive(Debug, Serialize)]
pub struct JobOutcome {
    pub job_id: String,
    pub document_id: String,
    pub document_version: u32,
    pub data_level: String,
    pub verdict: String,          // pass | block
    pub redaction_count: usize,
    pub mapping_count: usize,
    pub chunks_promoted: u64,
    pub allow_auto_pass: bool,
    pub require_human_review: bool,
    pub reason: String,
    pub sanitized_text: String,
    pub ledger: serde_json::Value,
}

/// Build the production detector set. Tiers 2-4 need the NER weights; when
/// `PACGATE_NER_MODEL_DIR` is unset the job runs Tier-1 rules only, which is
/// a degraded set the response reports honestly rather than hiding.
fn build_detectors(model_dir: Option<&str>) -> Result<Vec<Box<dyn detect::Detector>>, ApiError> {
    match model_dir.filter(|d| !d.is_empty()) {
        Some(dir) => detect::full_detectors(dir)
            .map_err(|e| ApiError::internal(format!("NER model load failed: {e}"))),
        None => {
            tracing::warn!("PACGATE_NER_MODEL_DIR unset: running Tier-1 rules only");
            Ok(detect::tier_one_detectors())
        }
    }
}

async fn audit_row(
    state: &AppState,
    tenant_id: &TenantId,
    user_id: Option<&UserId>,
    matter_id: &MatterId,
    document_id: &DocumentId,
    action: &str,
    metadata: serde_json::Value,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_log (tenant_id, user_id, action, resource, scope, metadata) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(tenant_id.0)
    .bind(user_id.map(|u| u.0))
    .bind(action)
    .bind(format!("document:{}", document_id.0))
    .bind(format!("matter:{}", matter_id.0))
    .bind(metadata)
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("audit write failed: {e}")))?;
    Ok(())
}

/// Run one sanitize job over one document version.
///
/// Cache-first: extract_document reads the stored extraction when present
/// (plan 019), so a per-job sanitize costs ZERO OCR calls on warm cache.
///
/// Verdict -> promotion (locked decision 3, atomic per document):
///   pass  -> kb_chunks pending -> sanitized, documents -> sanitized
///   block -> kb_chunks pending -> blocked,   documents -> blocked
/// Every job writes a `sanitizer_jobs` row (the vault) + one
/// `redaction_ledger_rows` row per document + one `audit_log` row.
pub async fn run_job(
    state: &AppState,
    tenant_id: &TenantId,
    user_id: &UserId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    data_level: DataLevel,
) -> Result<JobOutcome, ApiError> {
    // 1. INGEST (cache-first; warm cache = zero OCR calls).
    let extracted =
        crate::extract::extract_document(state, tenant_id, matter_id, document_id).await?;
    if extracted.incomplete {
        // Fail closed: never sanitize against an incomplete extraction.
        return Err(ApiError::internal(
            "extraction incomplete; document stays pending",
        ));
    }

    // The document version this job read. Everything below binds to it.
    let version = sqlx::query(
        "SELECT version FROM documents WHERE id = $1 AND tenant_id = $2 AND matter_id = $3 LIMIT 1",
    )
    .bind(document_id.0)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .get::<i32, _>("version");

    // 2-4. DETECT / DECIDE / REPLACE / VERIFY inside the crate.
    let mut sanitizer = pacgate_redact::Sanitizer::new(
        build_detectors(state.config.ner_model_dir.as_deref())?,
        MappingVersion::CURRENT,
    );
    let outcome = sanitizer
        .sanitize(&extracted.text, data_level)
        .map_err(|e| ApiError::internal(format!("sanitize failed: {e}")))?;

    // 5. Seal the evidence row BEFORE promoting state: the ledger must exist
    // for the row to claim 'sanitized' (design 5.1: column is the index,
    // ledger is the evidence).
    let ledger_json: serde_json::Value =
        serde_json::from_str(&outcome.ledger.to_json().expect("ledger serialisable"))
            .map_err(|e| ApiError::internal(format!("ledger parse failed: {e}")))?;
    let mapping_json = outcome.mapping.serialize();
    let job_row = sqlx::query(
        "INSERT INTO sanitizer_jobs \
             (tenant_id, matter_id, data_level, mapping_version, mapping, mapping_count, verdict, created_by) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(data_level.code())
    .bind(outcome.mapping.version().0 as i32)
    .bind(&mapping_json)
    .bind(outcome.mapping.entry_count() as i32)
    .bind(if outcome.ledger.verdict().is_block() {
        "block"
    } else {
        "pass"
    })
    .bind(user_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("job insert failed: {e}")))?;
    let job_id: uuid::Uuid = job_row.get("id");

    sqlx::query(
        "INSERT INTO redaction_ledger_rows \
             (job_id, tenant_id, matter_id, document_id, document_version, \
              input_sha256, output_sha256, redaction_count, verdict, ledger_json) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
    )
    .bind(job_id)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .bind(outcome.ledger.input_sha256())
    .bind(outcome.ledger.output_sha256())
    .bind(outcome.ledger.redaction_count as i32)
    .bind(
        if outcome.ledger.verdict().is_block() {
            "block"
        } else {
            "pass"
        },
    )
    .bind(&ledger_json)
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("ledger insert failed: {e}")))?;

    // 6. Promote or block, atomically per document.
    let verdict_is_block = outcome.ledger.verdict().is_block();
    let promoted: u64 = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("block write failed: {e}")))?
            .rows_affected()
    } else {
        sqlx::query(MARK_SANITIZED_DOC_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("promote write failed: {e}")))?
            .rows_affected()
    };
    let _ = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_DOCUMENT_SQL)
            .bind(document_id.0)
            .bind(tenant_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("document block failed: {e}")))?
            .rows_affected()
    } else {
        sqlx::query(MARK_SANITIZED_DOCUMENT_SQL)
            .bind(document_id.0)
            .bind(tenant_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("document promote failed: {e}")))?
            .rows_affected()
    };

    // 7. Audit (design 3.3/5.1: a redaction is an audit row, not a new store).
    audit_row(
        state,
        tenant_id,
        Some(user_id),
        matter_id,
        document_id,
        AUDIT_SANITIZE,
        serde_json::json!({
            "job_id": job_id.to_string(),
            "document_version": version,
            "verdict": if verdict_is_block { "block" } else { "pass" },
            "redaction_count": outcome.ledger.redaction_count,
            "data_level": data_level.code(),
        }),
    )
    .await?;

    Ok(JobOutcome {
        job_id: job_id.to_string(),
        document_id: document_id.as_str(),
        document_version: version as u32,
        data_level: data_level.code().to_string(),
        verdict: if verdict_is_block { "block" } else { "pass" }.to_string(),
        redaction_count: outcome.ledger.redaction_count,
        mapping_count: outcome.mapping.entry_count(),
        chunks_promoted: promoted,
        allow_auto_pass: outcome.decision.allow_auto_pass,
        require_human_review: outcome.decision.require_human_review,
        reason: outcome.decision.reason,
        sanitized_text: outcome.text,
        ledger: ledger_json,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP handlers
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct SanitizeRequest {
    /// T1-T4 code. T4 forces require_human_review (policy.rs) regardless.
    pub data_level: String,
}

pub async fn sanitize_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    axum::Json(req): axum::Json<SanitizeRequest>,
) -> Result<axum::Json<JobOutcome>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let data_level = DataLevel::from_code(&req.data_level)
        .ok_or_else(|| ApiError::bad_request("data_level must be T1|T2|T3|T4"))?;

    let doc = crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;
    let outcome =
        run_job(&state, &tenant_id, &user_id, &doc.matter_id, &document_id, data_level).await?;
    Ok(axum::Json(outcome))
}

// ─────────────────────────────────────────────────────────────────────────────
// Restore - local-only, role-gated, job-scoped, audit-logged (locked decision 2)
// ─────────────────────────────────────────────────────────────────────────────

/// Role gate for restore (locked decision 2). Only admin/partner may
/// re-hydrate placeholders; everything else is refused before any vault read.
fn role_may_restore(role: &str) -> bool {
    matches!(role, "admin" | "partner")
}

#[derive(Debug, Deserialize)]
pub struct RestoreRequest {
    pub job_id: String,
    pub text: String,
}

#[derive(Debug, Serialize)]
pub struct RestoreResponse {
    pub restored: String,
    pub job_id: String,
}

/// Local-only restore, bound to the job's mapping version (design stage 6).
/// Refusals are explicit: unknown role, unknown job, wrong matter, version
/// mismatch, or any unknown placeholder - the last never resolves to a guess.
pub async fn restore_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    axum::Json(req): axum::Json<RestoreRequest>,
) -> Result<axum::Json<RestoreResponse>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids(&claims)?;
    if !role_may_restore(&claims.role) {
        return Err(ApiError::unauthorized(
            "restore requires the admin or partner role",
        ));
    }
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc = crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    let job_uuid = req
        .job_id
        .parse::<uuid::Uuid>()
        .map_err(|e| ApiError::bad_request(format!("invalid job_id: {e}")))?;

    // The job must belong to this tenant.
    let job = sqlx::query(
        "SELECT mapping, mapping_version FROM sanitizer_jobs \
         WHERE id = $1 AND tenant_id = $2 LIMIT 1",
    )
    .bind(job_uuid)
    .bind(tenant_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .ok_or_else(|| ApiError::not_found("job not found"))?;

    // The job row must also cover this document's matter (not just any job).
    let ledger = sqlx::query(
        "SELECT matter_id FROM redaction_ledger_rows \
         WHERE job_id = $1 AND document_id = $2 LIMIT 1",
    )
    .bind(job_uuid)
    .bind(document_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    if ledger.is_none() {
        return Err(ApiError::not_found(
            "job has no ledger row for this document; refusing to guess",
        ));
    }
    let ledger_matter: uuid::Uuid = ledger.expect("checked above").get("matter_id");
    if ledger_matter != doc.matter_id.0 {
        return Err(ApiError::unauthorized(
            "job belongs to a different matter; restore is matter-scoped",
        ));
    }

    let mapping_json: serde_json::Value = job.get("mapping");
    let version = job.get::<i32, _>("mapping_version");
    let mapping = pacgate_redact::Mapping::deserialize(
        &mapping_json,
        pacgate_redact::MappingVersion(version as u32),
    )
    .map_err(|e| ApiError::bad_request(format!("vault unreadable: {e}")))?;

    let restored = mapping
        .restore(&req.text, pacgate_redact::MappingVersion(version as u32))
        .map_err(|e| ApiError::bad_request(format!("restore refused: {e}")))?;

    // Audit the restore itself (locked decision 2: every restore is logged).
    sqlx::query(
        "INSERT INTO audit_log (tenant_id, user_id, action, resource, scope, metadata) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(tenant_id.0)
    .bind(user_id.0)
    .bind(AUDIT_RESTORE)
    .bind(format!("document:{}", document_id.0))
    .bind(format!("matter:{}", doc.matter_id.0))
    .bind(serde_json::json!({
        "job_id": req.job_id,
        "restored_bytes": restored.len()
    }))
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("audit write failed: {e}")))?;

    Ok(axum::Json(RestoreResponse {
        restored,
        job_id: req.job_id,
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Status - the review panel feed (read-only; no vault contents)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct SanitizeStatusResponse {
    pub document_state: String,
    pub chunk_states: Vec<String>,
    pub latest_job: Option<String>,
}

pub async fn sanitize_status_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
) -> Result<axum::Json<SanitizeStatusResponse>, ApiError> {
    let (tenant_id, _) = crate::documents::claims_to_ids(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc = crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    let doc_state: String =
        sqlx::query("SELECT sanitization_state FROM documents WHERE id = $1 LIMIT 1")
            .bind(document_id.0)
            .fetch_one(&state.db)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .get("sanitization_state");

    let chunk_rows = sqlx::query(
        "SELECT DISTINCT sanitization_state FROM kb_chunks \
         WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3",
    )
    .bind(tenant_id.0)
    .bind(doc.matter_id.0)
    .bind(document_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    let chunk_states: Vec<String> = chunk_rows
        .iter()
        .map(|r| r.get::<String, _>("sanitization_state"))
        .collect();

    let latest_job: Option<String> = sqlx::query(
        "SELECT job_id FROM redaction_ledger_rows \
         WHERE document_id = $1 ORDER BY created_at DESC LIMIT 1",
    )
    .bind(document_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .map(|r| r.get::<uuid::Uuid, _>("job_id").to_string());

    Ok(axum::Json(SanitizeStatusResponse {
        document_state: doc_state,
        chunk_states,
        latest_job,
    }))
}

#[cfg(test)]
mod gate_tests {
    use super::*;

    #[test]
    fn the_promotion_targets_only_this_document() {
        assert!(MARK_SANITIZED_DOC_SQL.contains("tenant_id = $1"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("matter_id = $2"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("document_id = $3"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("sanitization_state = 'pending'"));
    }

    #[test]
    fn a_block_never_promotes() {
        // Block verdict -> documents + kb_chunks go to 'blocked', never 'sanitized'.
        assert!(MARK_BLOCKED_SQL.contains("SET sanitization_state = 'blocked'"));
        assert!(!MARK_BLOCKED_SQL.contains("'sanitized'"));
    }

    #[test]
    fn the_audit_action_names_are_stable() {
        assert_eq!(AUDIT_SANITIZE, "document.sanitize");
        assert_eq!(AUDIT_RESTORE, "document.restore");
    }

    #[test]
    fn restore_is_role_gated_to_admin_and_partner() {
        assert!(role_may_restore("admin"));
        assert!(role_may_restore("partner"));
        assert!(!role_may_restore("attorney"));
        assert!(!role_may_restore("paralegal"));
    }
}