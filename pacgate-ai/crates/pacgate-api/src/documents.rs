use axum::{
    extract::{Multipart, Path, State},
    Json,
};
use pacgate_core::{DataLevel, Document, DocumentId};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

// ─────────────────────────────────────────────────────────────────────────────
// Upload
// ─────────────────────────────────────────────────────────────────────────────

/// Upload a document with optional T1-T4 data classification.
///
/// Multipart form fields:
/// - `file` (required): the document file
/// - `data_level` (optional): T1-T4 classification level. Default: T2.
///   T1 = shared template, T2 = restricted seed, T3 = project-specific,
///   T4 = special sensitive. This controls cross-project search visibility
///   and access scoping in the RAG store.
pub async fn upload_document(
    State(state): State<AppState>,
    mut multipart: Multipart,
) -> Result<Json<Document>, ApiError> {
    let mut data_level: DataLevel = DataLevel::T2RestrictedSeed;
    let mut file_bytes: Option<Vec<u8>> = None;
    let mut filename: String = "upload".to_string();

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| ApiError::bad_request(e.to_string()))?
    {
        let name = field.name().unwrap_or("").to_string();
        match name.as_str() {
            "file" => {
                filename = field.file_name().unwrap_or("upload").to_string();
                let bytes = field
                    .bytes()
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
                file_bytes = Some(bytes.to_vec());
            }
            "data_level" => {
                let text = field
                    .text()
                    .await
                    .map_err(|e| ApiError::bad_request(e.to_string()))?;
                data_level = DataLevel::from_code(text.trim())
                    .ok_or_else(|| {
                        ApiError::bad_request(
                            "data_level must be one of: T1, T2, T3, T4",
                        )
                    })?;
            }
            _ => {}
        }
    }

    let bytes = file_bytes.ok_or_else(|| ApiError::bad_request("no file field in multipart upload"))?;

    let max_bytes = state.config.max_upload_mb * 1024 * 1024;
    if bytes.len() as u64 > max_bytes {
        return Err(ApiError::bad_request(format!(
            "file exceeds {} MB limit",
            state.config.max_upload_mb
        )));
    }

    tracing::info!(
        "upload_document: filename={}, data_level={}",
        filename,
        data_level.code()
    );

    // TODO: delegate to document storage layer + ChunkIngestor with data_level
    Err(ApiError::internal("storage layer not yet wired"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Get / list
// ─────────────────────────────────────────────────────────────────────────────

pub async fn get_document(
    State(state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<Document>, ApiError> {
    let doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    // The FsDocumentStore read method returns content; for metadata we query the DB
    // For now, list_for_matter won't work without a matter context — use a direct query
    let row = sqlx::query(
        "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
         FROM documents WHERE id = $1 ORDER BY version DESC LIMIT 1",
    )
    .bind(doc_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("document not found: {e}")))?;

    Ok(Json(Document {
        id: DocumentId(row.get::<uuid::Uuid, _>("id")),
        matter_id: pacgate_core::MatterId(row.get::<uuid::Uuid, _>("matter_id")),
        tenant_id: pacgate_core::TenantId(row.get::<uuid::Uuid, _>("tenant_id")),
        name: row.get("name"),
        format: match row.get::<String, _>("format").as_str() {
            "docx" => pacgate_core::DocumentFormat::Docx,
            "pdf" => pacgate_core::DocumentFormat::Pdf,
            "txt" => pacgate_core::DocumentFormat::Txt,
            "markdown" => pacgate_core::DocumentFormat::Markdown,
            _ => pacgate_core::DocumentFormat::Txt,
        },
        version: row.get::<i32, _>("version") as u32,
        storage_path: row.get("storage_path"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        owner_id: pacgate_core::UserId(row.get::<uuid::Uuid, _>("owner_id")),
    }))
}

pub async fn delete_document(
    State(_state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Err(ApiError::internal("storage layer not yet wired"))
}

pub async fn list_versions(
    State(_state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<Vec<Document>>, ApiError> {
    let _doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Err(ApiError::internal("storage layer not yet wired"))
}

pub async fn download_document(
    State(_state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<axum::response::Response, ApiError> {
    let _doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Err(ApiError::internal("storage layer not yet wired"))
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
    State(_state): State<AppState>,
    Path(id):      Path<String>,
    Json(_req):    Json<EditDocumentRequest>,
) -> Result<Json<Document>, ApiError> {
    let _doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Err(ApiError::internal("storage layer not yet wired"))
}

pub async fn accept_changes(
    State(_state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<Document>, ApiError> {
    let _doc_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    Err(ApiError::internal("storage layer not yet wired"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tabular review
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct TabularReviewRequest {
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
