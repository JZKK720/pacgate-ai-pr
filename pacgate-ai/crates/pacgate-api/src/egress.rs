//! The single egress decision for document body content.
//!
//! ## Why this module exists
//!
//! Before 2026-11-09 every handler that returned document text, spans or bytes
//! made its own admission decision, and two of them made the wrong one:
//!
//!  * `download_document` checked `sanitization_state` and then served the
//!    redacted chunks. Correct.
//!  * `extract_document_handler` checked only the TENANT and returned the body
//!    text of a document in any state, including `pending` and `blocked`. The
//!    document was never redacted, and the egress gate on `/download` had no
//!    bearing on it.
//!
//! The failure is structural, not clerical: a new `/extract_v2` written next
//! month inherits nothing from the handlers next to it. So the decision lives
//! here, once, and every body-returning path is expected to call
//! [`assert_readable`]. `mod egress_chokepoint` pins the set of such paths so a
//! handler that returns content without consulting this module fails a test
//! instead of leaking quietly.
//!
//! ## What "readable" means, and why the ingest lane is not a hole
//!
//! The rule is: **you may read a document whose text is yours to read.**
//!
//!  * `sanitized` - redacted, and the body must be served from the redacted
//!    chunks (see `documents::download_body_for`).
//!  * `never` - explicitly unredacted by decision, so the original IS the
//!    artifact.
//!  * `pending` / `blocked` - refused. This is the gate that was missing.
//!
//! The ingest and sanitize lanes must read a `pending` document's ORIGINAL
//! text; that is the input to redaction. They are not a hole in this rule
//! because they are not a caller choice: they reach the text through
//! `extract::extract_document` directly, which is `pub(crate)` and takes no
//! principal. An HTTP caller cannot select that path and cannot name a role
//! that opens it. What an HTTP caller may not do is read the body of a document
//! that nobody has decided it may read - including the person who uploaded it,
//! because "the uploading attorney may see their own unsanitised upload" is a
//! policy decision this system has never made, and inventing it here to keep an
//! endpoint convenient is how the gap opened.

use pacgate_core::{DocumentId, MatterId, TenantId, UserId};
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

/// Audit action for one document body fetch.
///
/// One stable code for every channel. `purpose` distinguishes them, so a
/// reviewer can group by `action` and still tell a download from an extraction.
const AUDIT_READ: &str = "document.read";

/// What the caller intends to do with the body.
///
/// Distinct variants rather than a string so a new channel cannot be added by
/// typo, and so the audit trail names a purpose this crate actually knows about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadPurpose {
    /// `POST /api/documents/:id/extract` - the extraction view of the text.
    Extract,
    /// `GET /api/documents/:id/download` - the file or its redacted rendering.
    Download,
}

impl ReadPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            ReadPurpose::Extract => "extract",
            ReadPurpose::Download => "download",
        }
    }
}

/// How a permitted read is served.
///
/// The variant carries the obligation, not just the permission. Returning
/// `Original` for a `sanitized` document is the 2026-11-03 leak expressed as a
/// type, so the two facts cannot drift apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodySource {
    /// Redacted rendering, rebuilt from `kb_chunks`.
    RedactedChunks,
    /// The stored original. Permitted only for `never`.
    Original,
}

/// The admission decision for one document, with the state it was made under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadAdmission {
    pub document_state: String,
    /// The data level the document's sanitize job last ran at, when one ran.
    /// `None` means no job has ever run - which is not "unknown", it is
    /// "unclassified", and it is reported as such rather than guessed at.
    pub data_level: Option<String>,
    pub body: BodySource,
}

impl ReadAdmission {
    /// The data level to record. Unclassified is stated, not defaulted: writing
    /// `T3` (the search default) into an audit row would invent a classification
    /// the firm never made.
    pub fn data_level_for_audit(&self) -> &str {
        self.data_level.as_deref().unwrap_or("unclassified")
    }
}

/// Decide whether this document's body may be read, and how it must be served.
///
/// Pure: no database, no I/O. The handler fetches the state and calls this, so
/// the decision is testable without a Postgres instance - which is the only
/// reason the 2026-11-03 download leak could be pinned by a test at all.
///
/// The admission is deliberately a function of the document STATE alone. A read
/// is permitted because the firm already decided this document may be read, not
/// because of who is asking through which route: a `blocked` document has no
/// readable body on any channel, and letting `purpose` or `format` widen that
/// would mean the gate's strictness depended on which endpoint you found.
/// `purpose` and `role` are carried on the call for the AUDIT row, not to vary
/// the decision - they are parameters here so a caller cannot claim a purpose
/// this module does not know about.
pub fn admit(
    document_state: &str,
    data_level: Option<&str>,
    purpose: ReadPurpose,
) -> Result<ReadAdmission, ApiError> {
    let _ = purpose;
    let body = match document_state {
        // Redacted text exists; the original does not leave.
        "sanitized" => BodySource::RedactedChunks,
        // The firm decided this document is never redacted.
        "never" => BodySource::Original,
        // `pending` is the default state, so this is the arm that matters: a
        // document nobody has sanitized cannot have its body read.
        "pending" | "blocked" => {
            return Err(ApiError::conflict(format!(
                "document is '{document_state}'; reading its body requires sanitization \
                 (or an explicit 'never' decision)"
            )))
        }
        // An unrecognised state is not an allow. A future state added to the
        // schema must make its own admission decision here.
        other => {
            return Err(ApiError::conflict(format!(
                "document state '{other}' has no read rule; refusing rather than guessing"
            )))
        }
    };

    Ok(ReadAdmission {
        document_state: document_state.to_string(),
        data_level: data_level.map(|s| s.to_string()),
        body,
    })
}

/// Everything the audit row needs, resolved once.
pub struct ReadContext<'a> {
    pub tenant_id: &'a TenantId,
    pub user_id: &'a UserId,
    pub matter_id: &'a MatterId,
    pub document_id: &'a DocumentId,
    pub purpose: ReadPurpose,
    pub role: &'a str,
}

/// The chokepoint: admit, or refuse, and record either way.
///
/// Callers must use the returned [`BodySource`] to decide what to serve. The
/// audit row is written for REFUSALS too - a document whose body was asked for
/// and denied is exactly what an egress review is looking for, and an audit
/// that only records successes cannot show an exfiltration attempt.
///
/// Best-effort like the other audit writes in this crate: a failed audit insert
/// must not turn a permitted read into an error the caller cannot act on. The
/// failure is logged at `error` so it stays visible.
pub async fn assert_readable(
    state: &AppState,
    doc: &pacgate_core::Document,
    ctx: &ReadContext<'_>,
) -> Result<ReadAdmission, ApiError> {
    let level_row = sqlx::query(
        // `sanitizer_jobs` is a PER-MATTER table and has no `document_id` column.
        // The per-document link lives in `redaction_ledger_rows`, which carries
        // both `job_id` and `document_id`. Joining through it is the only correct
        // way to reach the level of the job that actually read THIS document.
        //
        // Measured 2026-11-09 on the live stack: querying
        // `sanitizer_jobs WHERE document_id = $1` returned
        // "column \"document_id\" does not exist" and turned EVERY extract and
        // download into HTTP 500 - the admission check that exists to protect
        // reads instead blocked all of them.
        "SELECT j.data_level FROM sanitizer_jobs j \
         JOIN redaction_ledger_rows r ON r.job_id = j.id \
         WHERE r.document_id = $1 AND r.tenant_id = $2 \
         ORDER BY r.created_at DESC LIMIT 1",
    )
    .bind(ctx.document_id.0)
    .bind(ctx.tenant_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("read admission lookup failed: {e}")))?;
    let data_level: Option<String> = level_row.map(|r| r.get::<String, _>("data_level"));

    let state_row: String = sqlx::query(
        "SELECT sanitization_state FROM documents WHERE id = $1 AND tenant_id = $2",
    )
    .bind(ctx.document_id.0)
    .bind(ctx.tenant_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("read admission lookup failed: {e}")))?
    .map(|r| r.get::<String, _>("sanitization_state"))
    // A document that does not exist under this tenant was already rejected by
    // `fetch_document_for_tenant`; reaching here means a row vanished mid-call.
    .unwrap_or_else(|| "pending".to_string());

    let outcome = admit(&state_row, data_level.as_deref(), ctx.purpose);

    let (action, metadata) = match &outcome {
        Ok(adm) => (
            AUDIT_READ,
            serde_json::json!({
                "purpose": ctx.purpose.as_str(),
                "role": ctx.role,
                "document_state": adm.document_state,
                "data_level": adm.data_level_for_audit(),
                "body_source": match adm.body {
                    BodySource::RedactedChunks => "redacted_chunks",
                    BodySource::Original => "original",
                },
                "document_format": format!("{:?}", doc.format),
                "outcome": "allowed",
            }),
        ),
        Err(_) => (
            AUDIT_READ,
            serde_json::json!({
                "purpose": ctx.purpose.as_str(),
                "role": ctx.role,
                "document_state": state_row,
                "data_level": data_level.as_deref().unwrap_or("unclassified"),
                "document_format": format!("{:?}", doc.format),
                "outcome": "refused",
            }),
        ),
    };

    if let Err(e) = sqlx::query(
        "INSERT INTO audit_log (tenant_id, user_id, action, resource, scope, metadata) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(ctx.tenant_id.0)
    .bind(ctx.user_id.0)
    .bind(action)
    .bind(format!("document:{}", ctx.document_id.0))
    .bind(format!("matter:{}", ctx.matter_id.0))
    .bind(metadata)
    .execute(&state.db)
    .await
    {
        tracing::error!(
            error = %e,
            document_id = %ctx.document_id.0,
            purpose = ctx.purpose.as_str(),
            "failed to write document read audit row"
        );
    }

    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    /// The refusal contract, asserted as a value. 409 (not 403) because the
    /// resource is in a state that forbids reading and the caller can act on it.
    const REFUSAL_STATUS: StatusCode = StatusCode::CONFLICT;

    #[test]
    fn a_pending_document_cannot_have_its_body_read() {
        // The gap this module closes. Assert the STATUS, not just "is an error":
        // 403 would claim the caller is not allowed while 409 says the resource
        // is not in a state that permits reading, and the caller can act on 409.
        for purpose in [ReadPurpose::Extract, ReadPurpose::Download] {
            let e = admit("pending", None, purpose)
                .expect_err("pending must not be readable");
            assert_eq!(e.status, REFUSAL_STATUS);
            assert!(
                e.message.contains("sanitization"),
                "the refusal must name what would unblock it: {}",
                e.message
            );
        }
    }

    #[test]
    fn a_blocked_document_cannot_have_its_body_read() {
        let e = admit("blocked", Some("T4"), ReadPurpose::Extract)
            .expect_err("blocked must not be readable");
        assert_eq!(e.status, REFUSAL_STATUS);
    }

    #[test]
    fn a_sanitized_document_is_served_from_redacted_chunks() {
        let adm = admit("sanitized", Some("T2"), ReadPurpose::Extract).unwrap();
        assert_eq!(
            adm.body,
            BodySource::RedactedChunks,
            "a sanitized document must never be served from its original"
        );
        assert_eq!(adm.data_level_for_audit(), "T2");
    }

    #[test]
    fn a_never_document_is_the_one_original_read() {
        let adm = admit("never", None, ReadPurpose::Download).unwrap();
        assert_eq!(adm.body, BodySource::Original);
        assert_eq!(
            adm.data_level_for_audit(),
            "unclassified",
            "no job ever ran, so the audit row must say so rather than invent a level"
        );
    }

    #[test]
    fn an_unknown_state_is_refused_not_allowed() {
        // A future schema value must make its own decision. The old download
        // logic had a `_ =>` arm; the risk here is that it ever means "allow".
        for state in ["", "SANITIZED", "quarantined", "draft"] {
            assert!(
                admit(state, None, ReadPurpose::Extract).is_err(),
                "state {state:?} must not be admitted"
            );
        }
    }

    /// The decision must not vary by channel. A gate that is strict on
    /// `/download` and permissive on `/extract` is the exact 2026-11-09 defect,
    /// so this asserts that no purpose can reach a state the other cannot.
    #[test]
    fn no_state_is_readable_through_one_channel_and_not_the_other() {
        for state in ["pending", "blocked", "sanitized", "never", "", "other"] {
            let extract = admit(state, None, ReadPurpose::Extract);
            let download = admit(state, None, ReadPurpose::Download);
            assert_eq!(
                extract.is_ok(),
                download.is_ok(),
                "state {state:?} is admitted differently by extract and download, \
                 which is how the two endpoints drifted apart"
            );
        }
    }

    #[test]
    fn every_purpose_string_is_distinct() {
        // The audit trail groups on `purpose`; two channels sharing a string
        // would make the trail unable to distinguish them.
        assert_ne!(
            ReadPurpose::Extract.as_str(),
            ReadPurpose::Download.as_str()
        );
    }

    #[test]
    fn the_admission_lookup_only_names_columns_that_exist() {
        // WHY THIS EXISTS (found 2026-11-09, on the live 0.2.33 stack)
        //
        // `assert_readable` queried `sanitizer_jobs WHERE document_id = $1`, but
        // `sanitizer_jobs` has no `document_id` column - it is a PER-MATTER job
        // table (id, tenant_id, matter_id, data_level, mapping, verdict, ...).
        // The per-document link lives in `redaction_ledger_rows`, which carries
        // both `job_id` and `document_id`.
        //
        // The effect was total, not partial: EVERY extract and EVERY download
        // returned HTTP 500 "read admission lookup failed ... column
        // \"document_id\" does not exist". Measured by test-sanitizer-e2e.ps1,
        // which failed `extract returned text` and `download allowed
        // post-sanitize`.
        //
        // Nothing caught it before release because the module's own tests assert
        // `admit(...)`, the pure decision - the SQL that FEEDS that decision was
        // never checked against the schema. This asserts the wiring: the column
        // the query filters on must be one the table actually has.
        let src = include_str!("egress.rs");
        let start = src
            .find("pub async fn assert_readable")
            .expect("assert_readable must exist");
        let rest = &src[start..];
        let end = rest.find("let outcome = admit(").expect("admit follows the lookups");
        let body = &rest[..end];

        assert!(
            !body.contains("sanitizer_jobs \\\n         WHERE document_id"),
            "sanitizer_jobs has no document_id column; this query cannot succeed"
        );

        // The two lookups must target tables that actually own the columns they
        // filter on: `documents` for state, and the ledger join for the level.
        assert!(
            body.contains("FROM documents WHERE id = $1"),
            "document state must come from the documents table: {body}"
        );
        assert!(
            body.contains("redaction_ledger_rows"),
            "the per-document data level must be reached through \
             redaction_ledger_rows, the table that has both job_id and document_id"
        );
    }
}
