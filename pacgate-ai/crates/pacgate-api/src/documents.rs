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

fn claims_to_ids(claims: &Claims) -> Result<(TenantId, UserId), ApiError> {
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
    }
}

async fn fetch_document_for_tenant(
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

    let (doc, bytes) = state
        .doc_store
        .download_bytes(&doc_id, query.version)
        .await
        .map_err(ApiError::from)?;

    let content_type = match doc.format {
        DocumentFormat::Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        DocumentFormat::Pdf => "application/pdf",
        DocumentFormat::Txt => "text/plain; charset=utf-8",
        DocumentFormat::Markdown => "text/markdown; charset=utf-8",
    };

    let extension = match doc.format {
        DocumentFormat::Docx => "docx",
        DocumentFormat::Pdf => "pdf",
        DocumentFormat::Txt => "txt",
        DocumentFormat::Markdown => "md",
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
