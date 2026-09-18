//! Document extraction: OCR over HTTP, cached per document version.
//!
//! The cache-first property matters at bulk scale: the client ingests
//! hundreds of documents without sanitizing, then sanitizes a few per job.
//! Extraction happens ONCE per version; a warm cache means a per-job
//! sanitize makes ZERO OCR calls (design section 2).
//!
//! Extraction never promotes sanitization_state. New chunks land as
//! 'pending' (ingest SQL), so nothing extracted becomes retrievable until
//! a job completes.

use axum::http::StatusCode;
use pacgate_core::{DataLevel, DocumentId, Jurisdiction, MatterId, SourceLevel, TenantId};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractedSpan {
    pub page: Option<u32>,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractedDocument {
    pub text: String,
    pub pages: u32,
    pub spans: Vec<ExtractedSpan>,
    pub incomplete: bool,
}

/// Extract a document, cache-first.
///
/// Returns the cached extraction when this document version was already
/// extracted. The version binding is the correctness property: a new upload
/// bumps documents.version, so the cache can never serve text from an older
/// version of the file.
pub async fn extract_document(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
) -> Result<ExtractedDocument, ApiError> {
    let row = sqlx::query(
        "SELECT version, storage_path FROM documents WHERE id = $1 AND tenant_id = $2 AND matter_id = $3 LIMIT 1",
    )
    .bind(document_id.0)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::RowNotFound => ApiError::not_found("document not found"),
        other => ApiError::internal(other.to_string()),
    })?;

    let version: i32 = row.get("version");
    let storage_path: String = row.get("storage_path");

    // Cache check: any spans stored for this exact (document, version) mean
    // the extraction already ran.
    let cached = sqlx::query(
        "SELECT id, page, x, y, width, height, text FROM document_spans \
         WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 AND document_version = $4 \
         ORDER BY page, y, x",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;

    if !cached.is_empty() {
        let text = load_cached_text(state, tenant_id, matter_id, document_id).await?;
        let spans = cached
            .iter()
            .map(|r| ExtractedSpan {
                page: r.get::<Option<i32>, _>("page").map(|p| p as u32),
                x: r.get("x"),
                y: r.get("y"),
                width: r.get("width"),
                height: r.get("height"),
                text: r.get("text"),
            })
            .collect();
        let pages = cached
            .iter()
            .map(|r| r.get::<Option<i32>, _>("page").unwrap_or(1))
            .max()
            .unwrap_or(1) as u32;
        return Ok(ExtractedDocument {
            text,
            pages,
            spans,
            incomplete: false,
        });
    }

    // Cache miss: read the file bytes and call ocr-service. storage_path is
    // stored relative to DATA_DIR (same convention as FsDocumentStore::abs_path).
    let abs_path = std::path::Path::new(&state.config.data_dir).join(&storage_path);
    let bytes = std::fs::read(&abs_path)
        .map_err(|e| {
            ApiError::internal(format!(
                "failed to read stored document {}: {e}",
                abs_path.display()
            ))
        })?;

    let ocr_url = state
        .config
        .ocr_service_url
        .clone()
        .ok_or_else(|| ApiError::internal("ocr-service not configured (OCR_SERVICE_URL unset)"))?;

    let client = reqwest::Client::new();
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name("document")
        .mime_str("application/octet-stream")
        .map_err(|e| ApiError::internal(e.to_string()))?;
    let form = reqwest::multipart::Form::new().part("file", part);

    let resp = client
        .post(format!("{ocr_url}/extract"))
        .multipart(form)
        .timeout(std::time::Duration::from_secs(300))
        .send()
        .await
        .map_err(|e| ApiError::internal(format!("ocr-service unreachable: {e}")))?;

    let status = resp.status();
    if status != StatusCode::OK {
        // Fail closed: an OCR error must not yield text we treat as complete.
        return Err(ApiError::internal(format!(
            "ocr-service returned {status}; extraction is incomplete, document stays pending"
        )));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| ApiError::internal(format!("ocr-service returned invalid JSON: {e}")))?;

    let incomplete = body.get("incomplete").and_then(|v| v.as_bool()).unwrap_or(true);
    let text = body
        .get("text")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let pages = body.get("pages").and_then(|v| v.as_u64()).unwrap_or(0) as u32;

    let mut spans: Vec<ExtractedSpan> = Vec::new();
    if let Some(arr) = body.get("spans").and_then(|v| v.as_array()) {
        for s in arr {
            spans.push(ExtractedSpan {
                page: s.get("page").and_then(|v| v.as_u64()).map(|p| p as u32),
                x: s.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                y: s.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                width: s.get("width").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                height: s.get("height").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
                text: s.get("text").and_then(|v| v.as_str()).unwrap_or("").to_string(),
            });
        }
    }

    // Persist: spans to document_spans, text to kb_chunks as pending.
    persist_extraction(state, tenant_id, matter_id, document_id, version, &spans).await?;
    if !text.is_empty() {
        ingest_text_pending(state, tenant_id, matter_id, document_id, &text).await?;
    }

    Ok(ExtractedDocument {
        text,
        pages,
        spans,
        incomplete,
    })
}

/// Persist spans. `label`/`confidence` are written as NULL here: labelling
/// happens when a sanitizer job runs, not at extraction time.
async fn persist_extraction(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    version: i32,
    spans: &[ExtractedSpan],
) -> Result<(), ApiError> {
    for s in spans {
        sqlx::query(
            "INSERT INTO document_spans \
             (tenant_id, matter_id, document_id, document_version, page, x, y, width, height, text) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        )
        .bind(tenant_id.0)
        .bind(matter_id.0)
        .bind(document_id.0)
        .bind(version)
        .bind(s.page.map(|p| p as i32))
        .bind(s.x)
        .bind(s.y)
        .bind(s.width)
        .bind(s.height)
        .bind(&s.text)
        .execute(&state.db)
        .await
        .map_err(|e| ApiError::internal(format!("failed to persist span: {e}")))?;
    }
    Ok(())
}

/// Ingest extracted text as pending chunks.
///
/// Deliberately does NOT mark sanitized: extraction and sanitization are two
/// separate capabilities (design section 2), and the verifier only promotes
/// rows after a job completes. Signature matches
/// `ChunkIngestor::ingest_with_data_level` (verified against the crate).
async fn ingest_text_pending(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    text: &str,
) -> Result<(), ApiError> {
    let ingestor = pacgate_rag::ChunkIngestor::new(state.db.clone(), state.embedding.clone());
    ingestor
        .ingest_with_data_level(
            tenant_id,
            matter_id,
            document_id,
            text,
            &Jurisdiction::ChinaMainland,
            &SourceLevel::AuxiliaryDB,
            DataLevel::T3ProjectSpecific,
        )
        .await
        .map_err(|e| ApiError::internal(format!("failed to ingest extracted text: {e}")))?;
    Ok(())
}

/// Load the text half of a cached extraction from kb_chunks.
async fn load_cached_text(
    state: &AppState,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    document_id: &DocumentId,
) -> Result<String, ApiError> {
    let rows = sqlx::query(
        "SELECT content FROM kb_chunks WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 ORDER BY chunk_index",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(rows
        .iter()
        .map(|r| r.get::<String, _>("content"))
        .collect::<Vec<_>>()
        .join("\n"))
}
