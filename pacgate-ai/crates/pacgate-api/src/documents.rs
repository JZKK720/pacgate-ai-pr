use axum::{
    extract::{Extension, Multipart, Path, Query, State},
    http::{header, StatusCode},
    response::Response,
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::{Document, DocumentFormat, DocumentId, MatterId, TenantId, UserId};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

pub(crate) fn claims_to_ids(claims: &Claims) -> Result<(TenantId, UserId), ApiError> {
    let tenant_id: TenantId = claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))?;
    let user_id: UserId = claims
        .sub
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid user_id in token: {e}")))?;
    Ok((tenant_id, user_id))
}

fn row_to_document(row: &sqlx::postgres::PgRow) -> Document {
    Document {
        id: DocumentId(row.get::<uuid::Uuid, _>("id")),
        matter_id: pacgate_core::MatterId(row.get::<uuid::Uuid, _>("matter_id")),
        tenant_id: pacgate_core::TenantId(row.get::<uuid::Uuid, _>("tenant_id")),
        name: row.get("name"),
        format: pacgate_core::DocumentFormat::from_storage_key(&row.get::<String, _>("format")),
        version: row.get::<i32, _>("version") as u32,
        storage_path: row.get("storage_path"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        owner_id: pacgate_core::UserId(row.get::<uuid::Uuid, _>("owner_id")),
    }
}

pub(crate) async fn fetch_document_for_tenant(
    state: &AppState,
    tenant_id: &TenantId,
    doc_id: &DocumentId,
) -> Result<Document, ApiError> {
    let row = sqlx::query(
        "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
         FROM documents WHERE id = $1 AND tenant_id = $2 LIMIT 1",
    )
    .bind(doc_id.0)
    .bind(tenant_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::RowNotFound => ApiError::not_found("document not found"),
        other => ApiError::internal(other.to_string()),
    })?;

    Ok(row_to_document(&row))
}

// ─────────────────────────────────────────────────────────────────────────────
// Upload
// ─────────────────────────────────────────────────────────────────────────────

pub async fn upload_document(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    mut multipart: Multipart,
) -> Result<Json<Document>, ApiError> {
    let (tenant_id, user_id) = claims_to_ids(&claims)?;
    let mut matter_id: Option<MatterId> = None;
    let mut upload: Option<(String, Vec<u8>)> = None;

    while let Some(field) = multipart.next_field().await.map_err(|e| ApiError::bad_request(e.to_string()))? {
        let name = field.name().unwrap_or("").to_string();
        if name == "matter_id" {
            let value = field.text().await.map_err(|e| ApiError::bad_request(e.to_string()))?;
            matter_id = Some(
                value
                    .parse()
                    .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?,
            );
            continue;
        }

        if name == "file" {
            let filename = field.file_name().unwrap_or("upload").to_string();
            let bytes = field.bytes().await.map_err(|e| ApiError::bad_request(e.to_string()))?;

            let max_bytes = state.config.max_upload_mb * 1024 * 1024;
            if bytes.len() as u64 > max_bytes {
                return Err(ApiError::bad_request(format!(
                    "file exceeds {} MB limit", state.config.max_upload_mb
                )));
            }

            upload = Some((filename, bytes.to_vec()));
        }
    }

    let matter_id = matter_id.ok_or_else(|| ApiError::bad_request("matter_id is required"))?;
    let (filename, bytes) = upload.ok_or_else(|| ApiError::bad_request("no file field in multipart upload"))?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let document = state
        .doc_store
        .upload_bytes(&matter_id, &filename, &bytes, &user_id)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(document))
}

// ─────────────────────────────────────────────────────────────────────────────
// Get / list
// ─────────────────────────────────────────────────────────────────────────────

pub async fn get_document(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<Document>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Ok(Json(fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?))
}

pub async fn extract_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
) -> Result<Json<crate::extract::ExtractedDocument>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    // The document's matter scopes the call; fetch it to enforce the tenant
    // boundary before extracting.
    let doc = fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;
    let extracted = crate::extract::extract_document(
        &state,
        &tenant_id,
        &doc.matter_id,
        &document_id,
    )
    .await?;
    Ok(Json(extracted))
}

pub async fn delete_document(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;

    state
        .doc_store
        .delete_document_family(&doc_id)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(serde_json::json!({ "deleted": true, "id": id })))
}

pub async fn list_versions(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<Vec<Document>>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;

    let documents = state
        .doc_store
        .list_versions_for_document(&doc_id)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(documents))
}

#[derive(Debug, Deserialize)]
pub struct DownloadQuery {
    version: Option<u32>,
}

/// Which body the download endpoint may serve, decided without touching the DB.
///
/// Extracted so it can be tested at all: `documents.rs` had no test module, which is
/// why the 2026-11-03 download leak survived every gate. The decision is the whole
/// bug - before it, "sanitized" meant "allowed" and the bytes were passed through
/// unchanged.
#[derive(Debug, PartialEq)]
enum DownloadBody {
    /// The redacted rendering, rebuilt from `kb_chunks`.
    SanitisedText,
    /// The stored original, only for a document explicitly marked `never`.
    OriginalBinary,
    /// Refused: the label says sanitised but the artifact is binary, and a redacted
    /// binary cannot be rebuilt from text chunks. Serving the original here would be
    /// exactly the leak this fixes.
    RefusedBinary,
}

fn download_body_for(state: &str, format: &DocumentFormat) -> DownloadBody {
    let text_like = matches!(
        format,
        DocumentFormat::Txt | DocumentFormat::Markdown | DocumentFormat::Html
    );
    match (state, text_like) {
        ("sanitized", true) => DownloadBody::SanitisedText,
        ("sanitized", false) => DownloadBody::RefusedBinary,
        ("never", _) => DownloadBody::OriginalBinary,
        _ => DownloadBody::RefusedBinary,
    }
}

pub async fn download_document(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
    Query(query): Query<DownloadQuery>,
) -> Result<Response, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;

    // Egress gate (design 5.1): export/download refuses anything that is not
    // 'sanitized' or explicitly 'never'. 'pending' is the default state, so a
    // document nobody sanitized cannot leave through the download path.
    let doc_state: String = sqlx::query(
        "SELECT sanitization_state FROM documents WHERE id = $1 LIMIT 1",
    )
    .bind(doc_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .get("sanitization_state");
    if doc_state != "sanitized" && doc_state != "never" {
        return Err(ApiError::conflict(format!(
            "document is '{doc_state}'; download requires sanitization (or explicit 'never')"
        )));
    }

    let (doc, raw_bytes) = state
        .doc_store
        .download_bytes(&doc_id, query.version)
        .await
        .map_err(ApiError::from)?;

    // The download MUST serve the SANITISED rendering, not the stored original.
    //
    // MEASURED 2026-11-03, and this was a live P0 that every existing gate missed:
    // 36 of 37 documents labelled `sanitized` returned their FULL ORIGINAL TEXT
    // through this endpoint, including `OCR-VERIFY-扫描件样张` (80 KB, raw 身份证号)
    // and `probe-0217-regression` (raw HK1234567 / M1234567). The egress gate above
    // only refused `pending`; it never replaced the bytes, so the label said
    // "sanitised" while the payload said otherwise.
    //
    // Worse, `pacgate_read_document` in the MCP server is a thin wrapper over this
    // path, so the agent read the original and correctly reported that sanitisation
    // had done nothing - while the database and every gate said it was clean.
    //
    // `kb_chunks.content` holds the redacted rendering for every sanitised document
    // (verified: `纳税人识别号 [CN_TAX_ID_...]`), so the sanitised body is recovered
    // from there rather than re-running the pipeline. Binary formats (docx/pdf/...)
    // cannot be rebuilt byte-for-byte from chunks, so they are served as the redacted
    // TEXT rather than as the original file - which is what the conversion surface
    // consumes anyway.
    let body_plan = download_body_for(&doc_state, &doc.format);

    let bytes = match body_plan {
        DownloadBody::SanitisedText => {
            let rows: Vec<String> = sqlx::query_scalar(
                "SELECT content FROM kb_chunks \
                 WHERE document_id = $1 ORDER BY chunk_index",
            )
            .bind(doc_id.0)
            .fetch_all(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("download chunk lookup failed: {e}")))?;

            if rows.is_empty() {
                return Err(ApiError::conflict(
                    "document is labelled 'sanitized' but has no sanitised chunks to serve; \
                     re-run the sanitize job (its download would otherwise return the original)"
                        .to_string(),
                ));
            }
            rows.join("").into_bytes()
        }
        DownloadBody::RefusedBinary => {
            // A redacted BINARY cannot be rebuilt byte-for-byte from text chunks, so
            // the ORIGINAL is never served from here.
            //
            // Returning 409 was my regression, not a requirement: `pacgate_convert_document`
            // fetches this endpoint and converts locally, so refusing the body broke
            // PDF/DOCX/XLSX/PPTX entirely (measured 2026-11-03, test-format-coverage-e2e).
            // The redaction already exists as text; serving it keeps every format usable
            // and still discloses nothing.
            let rows: Vec<String> = sqlx::query_scalar(
                "SELECT content FROM kb_chunks \
                 WHERE document_id = $1 ORDER BY chunk_index",
            )
            .bind(doc_id.0)
            .fetch_all(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("download chunk lookup failed: {e}")))?;

            if rows.is_empty() {
                return Err(ApiError::conflict(
                    "download refused: this document is labelled 'sanitized' but has no \
                     sanitised text chunks, so its original cannot be released. Re-run \
                     the sanitize job.",
                ));
            }

            let text = rows.join("");
            let mut resp = Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, "text/markdown; charset=utf-8")
                .header(
                    header::CONTENT_DISPOSITION,
                    format!("attachment; filename=\"{}.md\"", doc.name),
                )
                // The caller cannot infer the original container from Markdown, and the
                // converter needs to say what it actually received.
                .header("x-pacgate-source-format", "redacted-text")
                .body(axum::body::Body::from(text))
                .map_err(|e| ApiError::internal(e.to_string()))?;
            resp.headers_mut()
                .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
            return Ok(resp);
        }
        // `never` - explicitly never-sanitised, so the original IS the artifact.
        DownloadBody::OriginalBinary => raw_bytes,
    };

    let content_type = match doc.format {
        DocumentFormat::Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        DocumentFormat::Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        DocumentFormat::Pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        DocumentFormat::Pdf => "application/pdf",
        DocumentFormat::Txt => "text/plain; charset=utf-8",
        DocumentFormat::Markdown => "text/markdown; charset=utf-8",
        DocumentFormat::Html => "text/html; charset=utf-8",
        DocumentFormat::ImagePng => "image/png",
        DocumentFormat::ImageJpeg => "image/jpeg",
        DocumentFormat::ImageTiff => "image/tiff",
        DocumentFormat::ImageBmp => "image/bmp",
        DocumentFormat::ImageWebp => "image/webp",
    };

    let extension = match doc.format {
        DocumentFormat::Docx => "docx",
        DocumentFormat::Xlsx => "xlsx",
        DocumentFormat::Pptx => "pptx",
        DocumentFormat::Pdf => "pdf",
        DocumentFormat::Txt => "txt",
        DocumentFormat::Markdown => "md",
        DocumentFormat::Html => "html",
        DocumentFormat::ImagePng => "png",
        DocumentFormat::ImageJpeg => "jpg",
        DocumentFormat::ImageTiff => "tif",
        DocumentFormat::ImageBmp => "bmp",
        DocumentFormat::ImageWebp => "webp",
    };

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{}.{}\"", doc.name, extension),
        )
        .body(axum::body::Body::from(bytes))
        .map_err(|e| ApiError::internal(e.to_string()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit + accept
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct EditDocumentRequest {
    pub find:           String,
    pub replace:        String,
    pub context_before: Option<String>,
    pub context_after:  Option<String>,
}

pub async fn edit_document(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):      Path<String>,
    Json(req):     Json<EditDocumentRequest>,
) -> Result<Json<Document>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;

    let document = state
        .doc_store
        .apply_edit_to_family(
            &doc_id,
            &req.find,
            &req.replace,
            req.context_before.as_deref(),
            req.context_after.as_deref(),
        )
        .await
        .map_err(ApiError::from)?;

    Ok(Json(document))
}

pub async fn accept_changes(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<Document>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;

    fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;

    let document = state
        .doc_store
        .accept_latest_changes(&doc_id)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(document))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tabular review
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct TabularReviewRequest {
    /// Matter scope for the review — part of the request contract;
    /// consumed once the tabular review engine is wired.
    #[allow(dead_code)]
    pub matter_id:    String,
    pub document_ids: Vec<String>,
    pub columns:      Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct TabularReviewResponse {
    pub review_id: String,
    pub status:    String,
}

pub async fn start_tabular_review(
    State(_state): State<AppState>,
    Json(req):     Json<TabularReviewRequest>,
) -> Result<Json<TabularReviewResponse>, ApiError> {
    if req.columns.is_empty() {
        return Err(ApiError::bad_request("columns must not be empty"));
    }
    if req.document_ids.is_empty() {
        return Err(ApiError::bad_request("document_ids must not be empty"));
    }
    Err(ApiError::internal("tabular review engine not yet wired"))
}

pub async fn get_tabular_results(
    State(_state): State<AppState>,
    Path(_id):    Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Err(ApiError::internal("tabular review engine not yet wired"))
}

#[cfg(test)]
mod download_tests {
    use super::*;

    /// The 2026-11-03 regression, stated as an invariant.
    ///
    /// `documents.rs` had NO test module at all, which is why the leak survived:
    /// the endpoint refused `pending` but passed the stored bytes through unchanged,
    /// so a document labelled `sanitized` served its full original text. 36 of 37
    /// documents did. The MCP tool `pacgate_read_document` wraps this endpoint, so
    /// the agent read raw client identifiers and - correctly - reported that
    /// sanitisation had not worked, while every gate said clean.
    ///
    /// A status-code assertion cannot catch this: the original and the redacted
    /// artifact are both HTTP 200.
    #[test]
    fn a_sanitized_text_document_never_serves_its_original() {
        for fmt in [DocumentFormat::Txt, DocumentFormat::Markdown, DocumentFormat::Html] {
            assert_eq!(
                download_body_for("sanitized", &fmt),
                DownloadBody::SanitisedText,
                "{fmt:?} is text-like, so its body must come from the redacted chunks"
            );
            assert_ne!(
                download_body_for("sanitized", &fmt),
                DownloadBody::OriginalBinary,
                "{fmt:?} must never fall back to the stored original"
            );
        }
    }

    /// A sanitised BINARY is served as REDACTED TEXT, never as its original bytes.
    ///
    /// The first version of this fix returned 409 here. That was wrong, and the
    /// format-coverage gate caught it: `pacgate_convert_document` fetches
    /// `/download` and converts the bytes locally, so refusing the body broke
    /// PDF/DOCX/XLSX/PPTX conversion outright. The requirement was never "refuse
    /// binaries" - it was "never release the ORIGINAL". The redaction already
    /// exists as text in `kb_chunks`; serving that keeps every format usable and
    /// still discloses nothing.
    #[test]
    fn a_sanitized_binary_document_is_served_as_redacted_text() {
        for fmt in [
            DocumentFormat::Docx,
            DocumentFormat::Xlsx,
            DocumentFormat::Pptx,
            DocumentFormat::Pdf,
            DocumentFormat::ImagePng,
            DocumentFormat::ImageJpeg,
            DocumentFormat::ImageTiff,
            DocumentFormat::ImageBmp,
            DocumentFormat::ImageWebp,
        ] {
            assert_eq!(
                download_body_for("sanitized", &fmt),
                DownloadBody::RefusedBinary,
                "{fmt:?} has no faithful binary rebuild, so the body must come from chunks"
            );
            assert_ne!(
                download_body_for("sanitized", &fmt),
                DownloadBody::OriginalBinary,
                "{fmt:?} must never fall back to the stored original"
            );
        }
    }

    /// An explicitly `never` document keeps serving its original - that is what the
    /// state means, and it is the one path where the raw bytes are the artifact.
    #[test]
    fn a_never_document_still_serves_its_original() {
        for fmt in [DocumentFormat::Txt, DocumentFormat::Docx, DocumentFormat::Pdf] {
            assert_eq!(
                download_body_for("never", &fmt),
                DownloadBody::OriginalBinary,
                "{fmt:?} marked 'never' is unredacted by definition"
            );
        }
    }

    /// Every other state is refused. The HTTP handler rejects these earlier, but the
    /// decision function must not have a "default allow" branch either.
    #[test]
    fn any_other_state_is_refused() {
        for state in ["pending", "blocked", "", "SANITIZED"] {
            assert_eq!(
                download_body_for(state, &DocumentFormat::Txt),
                DownloadBody::RefusedBinary,
                "state {state:?} must not authorise a download"
            );
        }
    }
}
