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

/// A Block verdict writes 'blocked' so the row can never be promoted by a
/// later run on a different document (the pending-only guard in 005/ingest).
const MARK_BLOCKED_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'blocked' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";

/// Reopen a blocked document so a re-sanitize can actually re-examine it.
///
/// A Block is a deliberate refusal, and the rewrite path is forbidden from
/// touching blocked rows on purpose (see `ingest.rs`: "a deliberate refusal
/// must not be silently overwritten"). That invariant is right, but it left
/// NO recovery path: measured 2026-10-25, `e2e_audit` re-sanitized to
/// `verdict=pass, residue=none` and stayed `blocked` with
/// `chunks_promoted=0`, because every transition matched zero rows. The only
/// way out was manual SQL.
///
/// So the reopen is explicit and separate rather than a widened guard: it runs
/// ONLY when the caller asked to re-sanitize a document that is currently
/// blocked, it is audited, and the verdict that follows decides the final
/// state. A document that blocks again simply returns to 'blocked'.
const REOPEN_BLOCKED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'pending' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'blocked'";

const REOPEN_BLOCKED_CHUNKS_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'pending' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'blocked'";

/// Document-level rollup mirrors the chunk states (design 5.1).
const MARK_SANITIZED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'sanitized' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

const MARK_BLOCKED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'blocked' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

/// Un-publish a document that was labelled `sanitized` but still carries an
/// identifier (see `reset_sanitized_handler`).
///
/// `SET sanitization_state = 'pending'` is the fail-closed direction: pending is
/// not searched by the RAG gate and not downloadable, so an un-publish can only
/// remove reachability, never add it.
const RESET_SANITIZED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'pending' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'sanitized'";

const RESET_SANITIZED_CHUNKS_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'pending' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'sanitized'";

/// Audit actions (stable codes; the review panel and tests rely on them).
const AUDIT_SANITIZE: &str = "document.sanitize";
const AUDIT_REOPEN: &str = "document.reopen";
const AUDIT_RESTORE: &str = "document.restore";
const AUDIT_APPROVE: &str = "document.approve";
/// A `sanitized` document returned to `pending` because a rescan found an
/// identifier still in it.
const AUDIT_RESET: &str = "document.sanitize-reset";
/// A read-only residue scan. Audited because a scan that found a leak is
/// itself evidence, and a scan that found nothing must not look like an audit
/// that was never run.
const AUDIT_RESCAN: &str = "document.sanitize-rescan";

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
    /// What survived redaction, when the verdict is `block`.
    ///
    /// Without this a reviewer got `verdict: "block"` and a generic sentence
    /// ("has residue after redaction, so it is held for review") with no way to
    /// see WHICH entity or WHICH text survived. Measured 2026-10-24: 5 of 13
    /// firm documents blocked this way and the only way to clear one was to
    /// reset the row in Postgres by hand.
    ///
    /// Empty on a pass, so a clean response is unchanged.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub residue: Vec<pacgate_redact::ledger::ResidueEntry>,
    /// The verifier's own explanation of the verdict.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub verification_notes: Vec<String>,
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
    run_job_inner(
        state,
        tenant_id,
        user_id,
        matter_id,
        document_id,
        data_level,
        None,
    )
    .await
}

/// Re-run a held job with the policy hold bypassed, because a human approved it.
///
/// `approved_job_id` is recorded in the audit row so the release names the
/// evidence it was based on. Everything else is the ordinary job path: the same
/// detectors, the same verify, the same delete-then-insert chunk rewrite. That
/// is the point - approval must not be a second, weaker promotion path.
async fn run_job_approved(
    state: &AppState,
    tenant_id: &TenantId,
    user_id: &UserId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    data_level: DataLevel,
    approved_job_id: &str,
) -> Result<JobOutcome, ApiError> {
    run_job_inner(
        state,
        tenant_id,
        user_id,
        matter_id,
        document_id,
        data_level,
        Some(approved_job_id),
    )
    .await
}

async fn run_job_inner(
    state: &AppState,
    tenant_id: &TenantId,
    user_id: &UserId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    data_level: DataLevel,
    approved_job_id: Option<&str>,
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

    // Take an admission slot BEFORE building detectors. The 393 MiB allocation
    // happens inside build_detectors, so a permit taken afterwards would bound
    // nothing while still passing every behavioural test - which is why the test
    // below asserts source order rather than behaviour.
    //
    // The permit is bound to a named variable and held to the end of the
    // function, so it covers the sanitize call too. `let _ =` would drop it
    // immediately and bound nothing.
    //
    // Over the bound the answer is 503, not a silent skip: a dropped job would
    // leave its document `pending` and unsearchable while the caller believed the
    // sanitize had succeeded.
    let _slot = state.try_acquire_sanitize_slot().ok_or_else(|| {
        ApiError::service_unavailable(format!(
            "sanitize capacity: {} job(s) already running; retry shortly",
            crate::SANITIZE_MAX_CONCURRENT
        ))
    })?;

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

    // 6. Promote, block, or hold, atomically per document.
    //
    // A Pass earns the 'sanitized' label by *replacing* the chunks with the
    // job's redacted rendering. Flipping the flag alone left the raw text in
    // `content`, which the RAG gate then served to chat - see
    // `reingest_sanitized_chunks`.
    //
    // A clean verdict is necessary but not sufficient: policy can still refuse
    // to auto-pass (T4 always does). Promoting on `verdict != block` alone
    // ignored `allow_auto_pass`, so a T4 document with zero findings was
    // labelled 'sanitized' and cleared the download egress gate - the exact
    // auto-pass the design forbids. Held documents stay 'pending' (fail-closed,
    // not served, not downloadable) and keep their raw chunks untouched.
    let verdict_is_block = outcome.ledger.verdict().is_block();
    // An approval bypasses the hold, but never a Block: a Block means the
    // redaction could not be verified, and no human approval can make unverified
    // redaction safe.
    let held_for_review =
        !verdict_is_block && !outcome.decision.allow_auto_pass && approved_job_id.is_none();
    let promoted: u64 = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("block write failed: {e}")))?
            .rows_affected()
    } else if held_for_review {
        0
    } else {
        let ingestor = pacgate_rag::ChunkIngestor::new(state.db.clone(), state.embedding.clone());
        ingestor
            .reingest_sanitized_chunks(tenant_id, matter_id, document_id, &outcome.text)
            .await
            .map_err(|e| ApiError::internal(format!("sanitized chunk rewrite failed: {e}")))?
    };
    let _ = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_DOCUMENT_SQL)
            .bind(document_id.0)
            .bind(tenant_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("document block failed: {e}")))?
            .rows_affected()
    } else if held_for_review {
        // Already 'pending' - the fail-closed state. No write is needed: the
        // document is not served by the RAG gate and not downloadable, and a
        // later human approval can promote from here. Writing 'pending' over
        // 'pending' would be a no-op UPDATE.
        0
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
            "disposition": if verdict_is_block {
                "blocked"
            } else if held_for_review {
                "held_for_review"
            } else {
                "sanitized"
            },
            "redaction_count": outcome.ledger.redaction_count,
            "data_level": data_level.code(),
            "approved_job_id": approved_job_id,
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
        residue: outcome.ledger.residue.clone(),
        verification_notes: outcome.ledger.verification_notes.clone(),
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

    // A blocked document is a deliberate refusal, and the rewrite path is
    // forbidden from touching blocked rows (see ingest.rs). Without an explicit
    // reopen, re-sanitizing one is a silent no-op: measured 2026-10-25,
    // `e2e_audit` returned `verdict=pass, residue=none` and stayed `blocked`
    // with `chunks_promoted=0`. Reopening here - only for a document that is
    // actually blocked, only because the caller asked to re-sanitize it - is
    // what makes the re-run a real recovery path. The verdict that follows
    // decides the final state, so a document that blocks again returns to
    // 'blocked'.
    let reopened = reopen_if_blocked(&state, &tenant_id, &doc.matter_id, &document_id).await?;
    if reopened {
        // Best-effort, like the other audit writes in this module: a failed
        // audit row must not abort a sanitize the operator asked for.
        let _ = audit_row(
            &state,
            &tenant_id,
            Some(&user_id),
            &doc.matter_id,
            &document_id,
            AUDIT_REOPEN,
            serde_json::json!({ "reason": "re-sanitize requested for a blocked document" }),
        )
        .await;
    }

    let outcome =
        run_job(&state, &tenant_id, &user_id, &doc.matter_id, &document_id, data_level).await?;
    Ok(axum::Json(outcome))
}

/// Move a blocked document and its chunks back to 'pending' so a re-sanitize
/// can re-examine them. Returns whether anything was reopened.
async fn reopen_if_blocked(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
) -> Result<bool, ApiError> {
    let doc_rows = sqlx::query(REOPEN_BLOCKED_DOCUMENT_SQL)
        .bind(document_id.0)
        .bind(tenant_id.0)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("reopen document failed: {e}")))?
        .rows_affected();
    if doc_rows == 0 {
        return Ok(false);
    }
    sqlx::query(REOPEN_BLOCKED_CHUNKS_SQL)
        .bind(tenant_id.0)
        .bind(matter_id.0)
        .bind(document_id.0)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("reopen chunks failed: {e}")))?;
    Ok(true)
}

// ─────────────────────────────────────────────────────────────────────────────
// Restore - local-only, role-gated, job-scoped, audit-logged (locked decision 2)
// ─────────────────────────────────────────────────────────────────────────────

/// Role gate for restore (locked decision 2). Only admin/partner may
/// re-hydrate placeholders; everything else is refused before any vault read.
fn role_may_restore(role: &str) -> bool {
    matches!(role, "admin" | "partner")
}

/// Approving a held document is the same authority as restoring redacted text:
/// both release sensitive content to a human, so both are admin/partner only.
fn role_may_approve(role: &str) -> bool {
    role_may_restore(role)
}

// ─────────────────────────────────────────────────────────────────────────────
// Residue rescan - the remediation path for text that already passed
// ─────────────────────────────────────────────────────────────────────────────

/// How many stored chunks one rescan request examines.
///
/// A rescan is read-only and cheap (rules only, no model, no embedding), so this
/// exists to bound the response size rather than to protect the process. Callers
/// page with `offset` when a matter has more.
const RESCAN_MAX_CHUNKS: i64 = 2000;

#[derive(Debug, Deserialize)]
pub struct RescanRequest {
    /// `true` scans every chunk in the matter. `false` (default) scans only one
    /// document.
    #[serde(default)]
    pub matter_wide: bool,
    #[serde(default)]
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct RescanFinding {
    pub document_id: String,
    pub chunk_id: String,
    pub document_state: String,
    pub entity: String,
    pub text: String,
}

#[derive(Debug, Serialize)]
pub struct RescanResponse {
    /// Chunks examined in this call.
    pub chunks_scanned: i64,
    /// Chunks that still contain at least one structurally-identifiable value.
    pub chunks_offending: i64,
    /// Distinct documents among them.
    pub documents_offending: Vec<String>,
    /// One entry per surviving span, so the reviewer sees WHAT survived.
    pub findings: Vec<RescanFinding>,
    /// Documents whose stored state is already `sanitized`.
    ///
    /// These are the dangerous ones: the text is searchable AND labelled clean,
    /// so nothing downstream will look at it again. Reported separately because
    /// the remediation is different - they are not "waiting" for a job, they are
    /// published and wrong.
    pub already_marked_sanitized: Vec<String>,
    /// How to fix what this call found.
    pub next: String,
    /// True when the scan hit `RESCAN_MAX_CHUNKS` and stopped early.
    pub truncated: bool,
}

/// Re-scan stored chunks for identifiers that are still present.
///
/// This exists because the verifier was circular (see `pacgate_redact::verify`):
/// until 2026-11-02 the suppressor that drove redaction was replayed over the
/// residue, so a document could be labelled `sanitized` while still holding, in
/// the client's measured case, eight identifier classes - including a resident ID
/// that could then be used as a search key against the vector store.
///
/// The old evidence cannot be trusted for that window, so the only sound
/// remediation is to re-examine the TEXT THAT IS ACTUALLY STORED rather than
/// re-read the ledger's verdict. That is what this does: a single indexed query,
/// the rule layer only (no model, no embedding, so it is fast and deterministic),
/// and the surviving value reported verbatim so a reviewer - or
/// `PATCH /api/documents/:id/sanitize-reset` - can act.
///
/// Read-only. It never promotes or blocks anything itself; changing a state on
/// the strength of a scan would repeat the mistake of letting one mechanism both
/// decide and certify.
pub async fn rescan_residue_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    axum::Json(req): axum::Json<RescanRequest>,
) -> Result<axum::Json<RescanResponse>, ApiError> {
    let (tenant_id, _user_id) = crate::documents::claims_to_ids(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc = crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    let rows = if req.matter_wide {
        sqlx::query(
            "SELECT c.id AS chunk_id, c.document_id, c.content, d.sanitization_state \
             FROM kb_chunks c JOIN documents d ON d.id = c.document_id \
             WHERE c.tenant_id = $1 AND c.matter_id = $2 \
             ORDER BY c.document_id, c.chunk_index \
             LIMIT $3 OFFSET $4",
        )
        .bind(tenant_id.0)
        .bind(doc.matter_id.0)
        .bind(RESCAN_MAX_CHUNKS)
        .bind(req.offset.unwrap_or(0))
        .fetch_all(&state.db)
        .await
    } else {
        sqlx::query(
            "SELECT c.id AS chunk_id, c.document_id, c.content, d.sanitization_state \
             FROM kb_chunks c JOIN documents d ON d.id = c.document_id \
             WHERE c.tenant_id = $1 AND c.document_id = $2 \
             ORDER BY c.chunk_index \
             LIMIT $3 OFFSET $4",
        )
        .bind(tenant_id.0)
        .bind(document_id.0)
        .bind(RESCAN_MAX_CHUNKS)
        .bind(req.offset.unwrap_or(0))
        .fetch_all(&state.db)
        .await
    }
    .map_err(|e| ApiError::internal(format!("rescan query failed: {e}")))?;

    // Rules only. A rescan must answer "is a structural identifier still in this
    // text", and the model answers a different question badly and slowly.
    let detectors = detect::tier_one_detectors();

    let mut findings: Vec<RescanFinding> = Vec::new();
    let mut offending_docs: Vec<String> = Vec::new();
    let mut already_sanitized: Vec<String> = Vec::new();

    for row in &rows {
        let chunk_id: uuid::Uuid = row.get("chunk_id");
        let chunk_doc: uuid::Uuid = row.get("document_id");
        let content: String = row.get("content");
        let doc_state: String = row.get("sanitization_state");

        let mut found = Vec::new();
        for d in &detectors {
            match d.detect(&content) {
                Ok(mut m) => found.append(&mut m),
                // A detector error here must be visible, not silent.
                Err(e) => {
                    return Err(ApiError::internal(format!(
                        "rescan detector {} failed: {e}",
                        d.name()
                    )))
                }
            }
        }
        if found.is_empty() {
            continue;
        }

        let doc_id = chunk_doc.to_string();
        if !offending_docs.contains(&doc_id) {
            offending_docs.push(doc_id.clone());
        }
        if doc_state == "sanitized" && !already_sanitized.contains(&doc_id) {
            already_sanitized.push(doc_id.clone());
        }

        // One finding per chunk keeps the response readable; the entity and the
        // surviving text are what a reviewer needs to judge it.
        let first = found
            .into_iter()
            .min_by_key(|m| (m.start, m.end))
            .expect("non-empty checked above");
        findings.push(RescanFinding {
            document_id: doc_id,
            chunk_id: chunk_id.to_string(),
            document_state: doc_state,
            entity: first.entity.code().to_string(),
            text: first.text,
        });
    }

    let chunks_scanned = rows.len() as i64;
    let next = if findings.is_empty() {
        "No structural identifier survived in the scanned chunks.".to_string()
    } else if already_sanitized.is_empty() {
        "Re-run the sanitize job on the documents listed in documents_offending; their chunks are not yet published."
            .to_string()
    } else {
        format!(
            "{} document(s) are BOTH published and still carrying an identifier. Reset each one with \
             PATCH /api/documents/:id/sanitize-reset, then re-run POST /api/documents/:id/sanitize. \
             Until then, do not treat their RAG results as clean.",
            already_sanitized.len()
        )
    };

    // Audited even on a clean result: a scan that ran and found nothing is
    // different evidence from a scan that was never run, and a compliance record
    // must be able to tell the two apart.
    audit_row(
        &state,
        &tenant_id,
        Some(&_user_id),
        &doc.matter_id,
        &document_id,
        AUDIT_RESCAN,
        serde_json::json!({
            "matter_wide": req.matter_wide,
            "offset": req.offset.unwrap_or(0),
            "chunks_scanned": chunks_scanned,
            "chunks_offending": findings.len(),
            "documents_offending": offending_docs,
            "already_marked_sanitized": already_sanitized,
        }),
    )
    .await?;

    Ok(axum::Json(RescanResponse {
        chunks_scanned,
        chunks_offending: findings.len() as i64,
        documents_offending: offending_docs,
        findings,
        already_marked_sanitized: already_sanitized,
        next,
        truncated: chunks_scanned >= RESCAN_MAX_CHUNKS,
    }))
}
#[derive(Debug, Serialize)]
pub struct ResetResponse {
    pub document_id: String,
    pub document_reopened: bool,
    pub chunks_reopened: u64,
    pub note: String,
}

/// Return a `sanitized` document to `pending` so a re-run actually replaces its
/// chunks.
///
/// Distinct from the automatic reopen in `sanitize_document_handler`, and
/// deliberately so. That one only fires for a document in state `blocked`,
/// because a Block is a refusal that a re-run may legitimately retry. This one
/// fires for `sanitized` - the state that says "this text is published and
/// clean" - and un-publishing is a decision with consequences, so it is a
/// separate, auditable call rather than something a re-run does silently.
///
/// Needed because `reingest_sanitized_chunks` selects `IN ('pending',
/// 'sanitized')` inside a transaction, but the surrounding job is gated on the
/// document row: a `sanitized` document whose chunks are already published has
/// no other way back into the pipeline. Measured 2026-11-02: 26 of 28 documents
/// in the default matter were `pending`, so most corpus damage was caught before
/// publication - but the ones that did pass are the reason this endpoint exists.
///
/// Admin/partner only, like approve and restore: it is the same class of
/// authority, since it makes client text un-retrievable for the duration.
pub async fn reset_sanitized_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
) -> Result<axum::Json<ResetResponse>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids(&claims)?;
    if !role_may_restore(&claims.role) {
        return Err(ApiError::unauthorized(
            "resetting a published document requires the admin or partner role",
        ));
    }
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc = crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    let document_reopened = sqlx::query(RESET_SANITIZED_DOCUMENT_SQL)
        .bind(document_id.0)
        .bind(tenant_id.0)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("reset document failed: {e}")))?
        .rows_affected()
        > 0;

    let chunks_reopened = sqlx::query(RESET_SANITIZED_CHUNKS_SQL)
        .bind(tenant_id.0)
        .bind(doc.matter_id.0)
        .bind(document_id.0)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("reset chunks failed: {e}")))?
        .rows_affected();

    let note = if document_reopened || chunks_reopened > 0 {
        "Document returned to 'pending': not searchable, not downloadable. Re-run the sanitize job to publish it again."
            .to_string()
    } else {
        "Nothing to reset: the document is not in state 'sanitized'.".to_string()
    };

    audit_row(
        &state,
        &tenant_id,
        Some(&user_id),
        &doc.matter_id,
        &document_id,
        AUDIT_RESET,
        serde_json::json!({
            "document_reopened": document_reopened,
            "chunks_reopened": chunks_reopened,
        }),
    )
    .await?;

    Ok(axum::Json(ResetResponse {
        document_id: document_id.as_str().to_string(),
        document_reopened,
        chunks_reopened,
        note,
    }))
}

#[derive(Debug, Deserialize)]
pub struct ApproveRequest {
    /// The job whose clean verdict is being accepted. Required so the approval
    /// names the evidence it is based on rather than approving "whatever ran
    /// last" - a job that ran after the reviewer looked would otherwise be
    /// silently blessed.
    pub job_id: String,
}

#[derive(Debug, Serialize)]
pub struct ApproveResponse {
    pub document_id: String,
    pub job_id: String,
    pub chunks_promoted: u64,
    pub document_state: String,
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

/// Approve a held document: promote it from 'pending' to 'sanitized'.
///
/// This is the human half of the T4 contract. `run_job` refuses to auto-pass a
/// document when policy says `allow_auto_pass == false`, which leaves it at
/// 'pending' - not downloadable, not searchable. Without this endpoint that
/// document had no path to release at all, so the hold was a dead end rather
/// than a review gate.
///
/// The caller names the job it is approving. That is deliberate: approving
/// "whatever ran last" would let a job that ran after the reviewer looked be
/// silently blessed. The job must belong to this tenant, this matter, and this
/// document, and its ledger verdict must be `pass` - a Block is never
/// approvable, because a Block means the redaction could not be verified.
///
/// Approval then RE-RUNS the job with the hold bypassed rather than promoting
/// the old result. That is not redundant: it re-derives the redacted text from
/// the current extraction, so approval can never promote text that was never
/// redacted, and it produces a fresh ledger row naming the approver.
pub async fn approve_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    axum::Json(req): axum::Json<ApproveRequest>,
) -> Result<axum::Json<ApproveResponse>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids(&claims)?;
    if !role_may_approve(&claims.role) {
        return Err(ApiError::unauthorized(
            "approval requires the admin or partner role",
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

    // The ledger row is the evidence. It must exist for THIS document and THIS
    // tenant, and it must say pass. A Block is never approvable.
    let ledger = sqlx::query(
        "SELECT matter_id, verdict, document_version FROM redaction_ledger_rows \
         WHERE job_id = $1 AND document_id = $2 AND tenant_id = $3 LIMIT 1",
    )
    .bind(job_uuid)
    .bind(document_id.0)
    .bind(tenant_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .ok_or_else(|| {
        ApiError::not_found("no ledger row for this job and document; refusing to guess")
    })?;

    let ledger_matter: uuid::Uuid = ledger.get("matter_id");
    if ledger_matter != doc.matter_id.0 {
        return Err(ApiError::unauthorized(
            "job belongs to a different matter; approval is matter-scoped",
        ));
    }
    let verdict: String = ledger.get("verdict");
    if verdict != "pass" {
        return Err(ApiError::conflict(
            "a Block verdict cannot be approved; the redaction could not be verified",
        ));
    }

    // Only a held document can be approved. 'sanitized' is already released and
    // 'blocked' is a different decision; approving either would be a no-op that
    // looks like an action.
    let current: String =
        sqlx::query("SELECT sanitization_state FROM documents WHERE id = $1 AND tenant_id = $2")
            .bind(document_id.0)
            .bind(tenant_id.0)
            .fetch_one(&state.db)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .get("sanitization_state");
    if current != "pending" {
        return Err(ApiError::conflict(format!(
            "document is '{current}'; only a held ('pending') document can be approved"
        )));
    }

    // The data level the approved job ran at, so the re-run is the same job.
    let data_level_code: String =
        sqlx::query("SELECT data_level FROM sanitizer_jobs WHERE id = $1 AND tenant_id = $2")
            .bind(job_uuid)
            .bind(tenant_id.0)
            .fetch_one(&state.db)
            .await
            .map_err(|e| ApiError::internal(e.to_string()))?
            .get("data_level");
    let data_level = DataLevel::from_code(&data_level_code)
        .ok_or_else(|| ApiError::internal(format!("job has unknown data_level '{data_level_code}'")))?;

    let outcome = run_job_approved(
        &state,
        &tenant_id,
        &user_id,
        &doc.matter_id,
        &document_id,
        data_level,
        &req.job_id,
    )
    .await?;

    Ok(axum::Json(ApproveResponse {
        document_id: document_id.to_string(),
        job_id: outcome.job_id,
        chunks_promoted: outcome.chunks_promoted,
        document_state: "sanitized".to_string(),
    }))
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
    /// True when a job ran, produced a clean verdict, and policy refused to
    /// auto-pass it (T4 always does), so the document was deliberately left at
    /// 'pending'.
    ///
    /// This is DERIVED, not stored. `pending` alone cannot distinguish "held for
    /// review" from "never processed", and the review panel needs to tell them
    /// apart. Deriving it from the ledger means there is no second source of
    /// truth to drift: if the ledger says pass and the document is still
    /// pending, it is held, by construction.
    pub held_for_review: bool,
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

    // Held = a job ran and passed, but the document is still 'pending'. That
    // combination can only mean policy refused to auto-pass it, because a
    // passing job that was allowed to promote would have written 'sanitized'.
    // Deriving it here keeps one source of truth: the ledger plus the state.
    let held_for_review = doc_state == "pending"
        && sqlx::query(
            "SELECT 1 FROM redaction_ledger_rows \
             WHERE document_id = $1 AND tenant_id = $2 AND verdict = 'pass' LIMIT 1",
        )
        .bind(document_id.0)
        .bind(tenant_id.0)
        .fetch_optional(&state.db)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .is_some();

    Ok(axum::Json(SanitizeStatusResponse {
        document_state: doc_state,
        chunk_states,
        latest_job,
        held_for_review,
    }))
}

#[cfg(test)]
mod gate_tests {
    use super::*;

    #[test]
    fn the_promotion_targets_only_this_document() {
        assert!(MARK_SANITIZED_DOCUMENT_SQL.contains("tenant_id = $2"));
        assert!(MARK_SANITIZED_DOCUMENT_SQL.contains("id = $1"));
    }

    #[test]
    fn a_block_never_promotes() {
        // Block verdict -> documents + kb_chunks go to 'blocked', never 'sanitized'.
        assert!(MARK_BLOCKED_SQL.contains("SET sanitization_state = 'blocked'"));
        assert!(!MARK_BLOCKED_SQL.contains("'sanitized'"));
    }

    #[test]
    fn a_blocked_document_can_be_reopened_but_only_explicitly() {
        // A Block is a deliberate refusal, and the rewrite path is forbidden
        // from touching blocked rows (ingest.rs asserts that). That invariant
        // left NO recovery path: measured 2026-10-25, `e2e_audit` re-sanitized
        // to `verdict=pass, residue=none` and stayed `blocked` with
        // `chunks_promoted=0`, because every transition matched zero rows.
        //
        // The reopen is therefore a separate, explicit statement - not a
        // widened guard on the promotion path.
        assert!(
            REOPEN_BLOCKED_DOCUMENT_SQL.contains("sanitization_state = 'blocked'"),
            "the reopen must only ever match a blocked document"
        );
        assert!(
            REOPEN_BLOCKED_DOCUMENT_SQL.contains("SET sanitization_state = 'pending'"),
            "the reopen must return the document to the fail-closed state"
        );
        assert!(
            !REOPEN_BLOCKED_DOCUMENT_SQL.contains("'sanitized'"),
            "a reopen must never promote; only a clean verdict may do that"
        );
        // The promotion path itself must stay pending-only, so a reopen is the
        // ONLY way out of 'blocked'.
        assert!(
            MARK_SANITIZED_DOCUMENT_SQL.contains("sanitization_state = 'pending'"),
            "promotion must stay pending-only"
        );
        assert!(
            !MARK_SANITIZED_DOCUMENT_SQL.contains("'blocked'"),
            "promotion must not reach a blocked document directly"
        );
    }

    #[test]
    fn the_reopen_runs_before_the_job_and_is_audited() {
        let src = include_str!("sanitize.rs");
        let handler = src
            .split("pub async fn sanitize_document_handler")
            .nth(1)
            .expect("handler must exist");
        let reopen_at = handler.find("reopen_if_blocked").expect("reopen call");
        let job_at = handler.find("run_job(").expect("job call");
        assert!(
            reopen_at < job_at,
            "the reopen must precede the job, or the rewrite still sees 'blocked'"
        );
        assert!(
            handler.contains("AUDIT_REOPEN"),
            "a reopen changes a compliance state and must be audited"
        );
    }

    /// The reset exists because a document can be published AND wrong.
    ///
    /// Measured 2026-11-02: a document carried the `sanitized` label with a
    /// resident ID still in its chunks, so the id could be used as a search key
    /// and downstream treated the text as clean. The two directions that matter
    /// here are that a reset only ever UN-publishes, and that it cannot touch a
    /// blocked row (whose refusal is a different decision).
    #[test]
    fn a_published_document_can_be_unpublished_but_never_blocked_by_the_reset() {
        assert!(
            RESET_SANITIZED_DOCUMENT_SQL.contains("sanitization_state = 'sanitized'"),
            "a reset must only match a PUBLISHED document; 'pending' has nothing to reset \
             and 'blocked' is a refusal that a re-run does not own"
        );
        assert!(
            RESET_SANITIZED_DOCUMENT_SQL.contains("SET sanitization_state = 'pending'"),
            "a reset must move toward the fail-closed state, never toward 'sanitized'"
        );
        assert!(
            !RESET_SANITIZED_DOCUMENT_SQL.contains("'blocked'"),
            "a reset must not be a back door around the blocked state"
        );
        assert!(
            !RESET_SANITIZED_DOCUMENT_SQL.contains("SET sanitization_state = 'sanitized'"),
            "no path may promote without a verdict"
        );
        assert!(
            RESET_SANITIZED_CHUNKS_SQL.contains("sanitization_state = 'sanitized'")
                && RESET_SANITIZED_CHUNKS_SQL.contains("tenant_id = $1")
                && RESET_SANITIZED_CHUNKS_SQL.contains("matter_id = $2")
                && RESET_SANITIZED_CHUNKS_SQL.contains("document_id = $3"),
            "the chunk reset must be scoped to one document in one matter"
        );
    }

    /// The rescan is read-only on purpose.
    ///
    /// It answers "is an identifier still in the stored text", and it must not
    /// also decide. A scan that flipped states would be the same
    /// one-mechanism-decides-and-certifies mistake the verifier made.
    #[test]
    fn the_rescan_reads_and_never_writes_a_sanitization_state() {
        let src = include_str!("sanitize.rs");
        let handler = src
            .split("pub async fn rescan_residue_handler")
            .nth(1)
            .expect("rescan handler must exist");
        let handler = &handler[..handler
            .find("pub struct ResetResponse")
            .expect("reset section marker")];
        assert!(
            !handler.contains("SET sanitization_state"),
            "the rescan must not mutate a compliance state"
        );
        assert!(
            !handler.contains("reingest_sanitized_chunks"),
            "the rescan must not rewrite chunks"
        );
        assert!(
            handler.contains("AUDIT_RESCAN"),
            "a scan that found a leak is evidence and must be audited"
        );
        // Rules only: a rescan must answer the structural question, not the
        // model's guess at it, and it must stay cheap enough to run over a matter.
        assert!(
            handler.contains("tier_one_detectors"),
            "the rescan must not load the NER model"
        );
        assert!(
            !handler.contains("full_detectors"),
            "the rescan must not depend on the 400MB model bundle"
        );
    }

    #[test]
    fn a_held_document_stays_pending_and_never_promotes() {
        // T4 (and any policy refusal to auto-pass) must not reach 'sanitized'.
        // 'pending' is the fail-closed state: the RAG gate and the download
        // egress gate both refuse it, and a later approval can promote from it.
        // The hold branch must therefore write NOTHING - a 'pending' -> 'pending'
        // UPDATE would be a no-op that only looks like enforcement.
        let src = include_str!("sanitize.rs");
        let promotion = src
            .split("let verdict_is_block = outcome.ledger.verdict().is_block();")
            .nth(1)
            .expect("promotion block not found");
        let promotion = &promotion[..promotion.find("// 7. Audit").expect("audit marker")];
        let hold_at = promotion.rfind("held_for_review").expect("hold branch");
        let sanitized_at = promotion
            .find("sqlx::query(MARK_SANITIZED_DOCUMENT_SQL)")
            .expect("sanitized branch");
        assert!(hold_at < sanitized_at, "hold must precede promotion");
        // Between the hold branch and the promotion call there must be no state
        // write at all.
        let hold_branch = &promotion[hold_at..sanitized_at];
        assert!(
            !hold_branch.contains("sqlx::query"),
            "the hold branch must not write a state"
        );
    }

    #[test]
    fn promotion_requires_policy_consent_not_just_a_clean_verdict() {
        // The regression this guards: promoting on `verdict != block` alone
        // ignored allow_auto_pass, so a T4 document with zero findings was
        // labelled 'sanitized' and cleared the download egress gate.
        let src = include_str!("sanitize.rs");
        let promotion = src
            .split("let verdict_is_block = outcome.ledger.verdict().is_block();")
            .nth(1)
            .expect("promotion block not found");
        let promotion = &promotion[..promotion.find("// 7. Audit").expect("audit marker")];
        assert!(
            promotion.contains("allow_auto_pass"),
            "promotion must consult allow_auto_pass"
        );
        assert!(
            promotion.contains("held_for_review"),
            "promotion must have a hold branch"
        );
        // The hold branch must come before the sanitized branch, so a held
        // document can never fall through to promotion.
        let hold_at = promotion.find("held_for_review").expect("hold branch");
        let sanitized_at = promotion
            .find("MARK_SANITIZED_DOCUMENT_SQL")
            .expect("sanitized branch");
        assert!(hold_at < sanitized_at, "hold must precede promotion");
    }

    #[test]
    fn the_audit_action_names_are_stable() {
        assert_eq!(AUDIT_SANITIZE, "document.sanitize");
        assert_eq!(AUDIT_RESTORE, "document.restore");
        assert_eq!(AUDIT_APPROVE, "document.approve");
    }

    #[test]
    fn approval_is_role_gated_like_restore() {
        // Both release sensitive content to a human, so both need the same
        // authority. A narrower gate on approval would be a way around restore.
        for role in ["admin", "partner"] {
            assert!(role_may_approve(role), "{role} must be able to approve");
        }
        for role in ["attorney", "user", "viewer", ""] {
            assert!(!role_may_approve(role), "{role} must not approve");
        }
    }

    #[test]
    fn an_approval_bypasses_the_hold_but_never_a_block() {
        // The hold exists because policy refused to auto-pass. An approval is
        // the human override for exactly that. A Block is different: the
        // redaction could not be verified, and no approval can make unverified
        // redaction safe.
        let src = include_str!("sanitize.rs");
        let at = src
            .find("let held_for_review =")
            .expect("hold decision must exist");
        let decision = &src[at..at + 260];
        assert!(
            decision.contains("!verdict_is_block"),
            "a Block must never be held-then-approvable: {decision}"
        );
        assert!(
            decision.contains("approved_job_id.is_none()"),
            "an approval must bypass the hold: {decision}"
        );
    }

    #[test]
    fn approval_reuses_the_job_path_rather_than_a_second_promotion() {
        // A separate promotion path would be a weaker path: it could skip the
        // verify stage or the delete-then-insert rewrite. Approval must go
        // through run_job_inner like every other promotion.
        let src = include_str!("sanitize.rs");
        let approve = src
            .find("pub async fn approve_document_handler")
            .expect("approve handler");
        let body = &src[approve..];
        let end = body.find("pub async fn restore_document_handler").expect("restore");
        let body = &body[..end];
        assert!(
            body.contains("run_job_approved"),
            "approval must reuse the job path"
        );
        assert!(
            !body.contains("reingest_sanitized_chunks"),
            "approval must not rewrite chunks itself; that is the job's job"
        );
        assert!(
            !body.contains("MARK_SANITIZED_DOCUMENT_SQL"),
            "approval must not flip the state itself"
        );
    }

    #[test]
    fn approval_refuses_a_block_and_a_non_pending_document() {
        let src = include_str!("sanitize.rs");
        let approve = src
            .find("pub async fn approve_document_handler")
            .expect("approve handler");
        let body = &src[approve..];
        let end = body.find("pub async fn restore_document_handler").expect("restore");
        let body = &body[..end];
        assert!(
            body.contains("verdict != \"pass\""),
            "a Block verdict must be refused"
        );
        assert!(
            body.contains("current != \"pending\""),
            "only a held document may be approved"
        );
        assert!(
            body.contains("role_may_approve"),
            "approval must be role-gated"
        );
    }

    #[test]
    fn held_state_is_derived_not_stored() {
        // 'pending' cannot distinguish "held for review" from "never processed".
        // Deriving it from the ledger keeps one source of truth: if a passing
        // ledger row exists and the document is still pending, it is held.
        let src = include_str!("sanitize.rs");
        let at = src
            .find("let held_for_review = doc_state == \"pending\"")
            .expect("derived held state");
        let body = &src[at..at + 400];
        assert!(
            body.contains("redaction_ledger_rows"),
            "held state must be derived from the ledger: {body}"
        );
        assert!(
            body.contains("verdict = 'pass'"),
            "only a passing job can leave a document held: {body}"
        );
    }

    #[test]
    fn restore_is_role_gated_to_admin_and_partner() {
        assert!(role_may_restore("admin"));
        assert!(role_may_restore("partner"));
        assert!(!role_may_restore("attorney"));
        assert!(!role_may_restore("paralegal"));
    }

    /// Read this file's source up to the test module.
    ///
    /// Scoped deliberately: searching the whole file makes the assertions match
    /// their OWN string literals and the `fn build_detectors` definition, which
    /// is exactly what a first attempt did - both tests failed against correct
    /// code because they were measuring their own text.
    fn production_source() -> String {
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/sanitize.rs"),
        )
        .expect("read own source");
        let end = src
            .find("#[cfg(test)]")
            .expect("this file must have a test module to scope against");
        src[..end].to_string()
    }

    /// The bound must be enforced where the allocation happens.
    ///
    /// This asserts SOURCE ORDER, not behaviour, and that is deliberate: a permit
    /// acquired *after* `build_detectors` still passes every behavioural test
    /// while bounding nothing, because the 393 MiB has already been allocated by
    /// then. An ordering bug is invisible to functional testing, so the only
    /// reliable guard is the order of the two calls.
    #[test]
    fn the_sanitize_slot_is_taken_before_detectors_are_built() {
        let prod = production_source();

        let acquire = prod
            .find("try_acquire_sanitize_slot")
            .expect("run_job must acquire a sanitize slot, or the allocation is unbounded");
        // The CALL, not the definition: `fn build_detectors` appears near the top
        // of the file, so matching the bare name would compare against the wrong
        // occurrence and pass regardless of call order.
        let build = prod
            .find("build_detectors(state.config.ner_model_dir")
            .expect("run_job must call build_detectors; without this the order is unassertable");

        assert!(
            acquire < build,
            "the slot must be acquired BEFORE build_detectors: acquiring after the \
             allocation would bound nothing while passing every behavioural test \
             (acquire at byte {acquire}, call at byte {build})"
        );
    }

    /// `let _ =` drops the permit immediately, which would make the bound a
    /// no-op that still reads as correct in review.
    #[test]
    fn the_permit_is_bound_to_a_named_variable() {
        let prod = production_source();

        assert!(
            !prod.contains("let _ = state.try_acquire_sanitize_slot()"),
            "the permit must be bound to a named variable: `let _ =` drops the \
             guard immediately, so the function would hold no slot at all"
        );
        assert!(
            prod.contains("let _slot = state.try_acquire_sanitize_slot()"),
            "expected the permit bound as `_slot`"
        );
    }
}