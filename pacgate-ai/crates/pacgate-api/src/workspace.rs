//! Matter workspace — one aggregated view of everything a matter holds.
//!
//! `GET /api/matters/:id/workspace`
//!
//! WHY THIS EXISTS (2026-10-05 design-gap fix). Matter material was scattered
//! across four surfaces with no single operator-facing view:
//!
//! 1. documents (original bytes on disk + rows in `documents`)
//! 2. OCR extraction records (`document_extractions` + `document_spans`)
//! 3. the RAG store, whose `kb_chunks.content` IS the sanitized text
//! 4. nothing for agent deliverables (those lived in deer-flow's ephemeral
//!    per-thread outputs)
//!
//! A legal team expects one "matter workspace": everything for a matter
//! browsable and retrievable from one place. This handler is that place's
//! read side. It aggregates what already exists — it introduces NO new store
//! — and every section is optional in the response so a partial deployment
//! (no RAG store configured, no OCR yet) still answers with what it has.
//!
//! AUTH: sits on the protected router, so Claims are always present and
//! tenant-scoped like every other matter route.

use axum::{
    extract::{Extension, Path, State},
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::{MatterId, TenantId};
use serde::Serialize;
use sqlx::Row;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Serialize)]
pub struct WorkspaceDocument {
    pub id: uuid::Uuid,
    pub name: String,
    pub format: String,
    pub version: i32,
    pub sanitization_state: String,
    pub storage_path: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize)]
pub struct WorkspaceExtraction {
    pub document_id: uuid::Uuid,
    pub document_version: i32,
    pub pages: i32,
    pub incomplete: bool,
    pub engine: String,
    pub extracted_at: String,
}

/// The read-side rollup for one matter.
#[derive(Debug, Serialize)]
pub struct MatterWorkspace {
    pub matter_id: uuid::Uuid,
    pub tenant_id: uuid::Uuid,
    pub documents: Vec<WorkspaceDocument>,
    pub extractions: Vec<WorkspaceExtraction>,
    /// Chunk rollup per document, so a caller can see what the RAG/sanitizer
    /// lane holds WITHOUT reading chunk contents (which stay query-side only).
    pub rag_documents: Vec<RagDocumentStatus>,
    pub generated_at: String,
}

/// Per-document chunk rollup from the RAG store.
#[derive(Debug, Serialize)]
pub struct RagDocumentStatus {
    pub document_id: uuid::Uuid,
    pub chunk_count: i64,
    /// Distinct states across this document's chunks (e.g. ["sanitized"]). A
    /// document with heterogeneous states lists all of them; callers that
    /// need every chunk query the chunks route instead.
    pub states: Vec<String>,
}

fn workspace_query_error(e: sqlx::Error, what: &str) -> ApiError {
    ApiError::internal(format!("workspace {what} query failed: {e}"))
}

pub async fn get_matter_workspace(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
) -> Result<Json<MatterWorkspace>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let tenant_id: TenantId = claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))?;

    // Tenant boundary first: a matter from another tenant reads as 404,
    // mirroring get_matter.
    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    // 1. Documents (all versions roll into one row per document; the version
    //    column carries the CURRENT version like list_matter_documents does).
    let doc_rows = sqlx::query(
        "SELECT id, name, format, version, sanitization_state, storage_path, \
                created_at, updated_at \
         FROM documents \
         WHERE tenant_id = $1 AND matter_id = $2 \
         ORDER BY created_at DESC",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| workspace_query_error(e, "documents"))?;

    let documents: Vec<WorkspaceDocument> = doc_rows
        .iter()
        .map(|r| WorkspaceDocument {
            id: r.get("id"),
            name: r.get("name"),
            format: r.get("format"),
            version: r.get::<i32, _>("version"),
            sanitization_state: r.get("sanitization_state"),
            storage_path: r.get("storage_path"),
            created_at: r.get::<chrono::DateTime<chrono::Utc>, _>("created_at").to_rfc3339(),
            updated_at: r.get::<chrono::DateTime<chrono::Utc>, _>("updated_at").to_rfc3339(),
        })
        .collect();

    // 2. Extraction records (one per document version extracted so far).
    let extraction_rows = sqlx::query(
        "SELECT document_id, document_version, pages, incomplete, engine, extracted_at \
         FROM document_extractions \
         WHERE tenant_id = $1 AND matter_id = $2 \
         ORDER BY extracted_at DESC",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| workspace_query_error(e, "extractions"))?;

    let extractions: Vec<WorkspaceExtraction> = extraction_rows
        .iter()
        .map(|r| WorkspaceExtraction {
            document_id: r.get("document_id"),
            document_version: r.get("document_version"),
            pages: r.get("pages"),
            incomplete: r.get("incomplete"),
            engine: r.get("engine"),
            extracted_at: r
                .get::<chrono::DateTime<chrono::Utc>, _>("extracted_at")
                .to_rfc3339(),
        })
        .collect();

    // 3. RAG/sanitizer lane rollup. Chunk CONTENTS stay out of this response:
    //    they are retrievable through the query route (kb/search) which applies
    //    the data-level filter; the workspace view is metadata + status.
    let rag_rows = sqlx::query(
        "SELECT document_id, \
                count(*) AS chunk_count, \
                array_agg(DISTINCT sanitization_state) AS states \
         FROM kb_chunks \
         WHERE tenant_id = $1 AND matter_id = $2 \
         GROUP BY document_id \
         ORDER BY document_id",
    )
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| workspace_query_error(e, "rag rollup"))?;

    let rag_documents: Vec<RagDocumentStatus> = rag_rows
        .iter()
        .map(|r| RagDocumentStatus {
            document_id: r.get("document_id"),
            chunk_count: r.get("chunk_count"),
            states: r
                .try_get::<Vec<String>, _>("states")
                .unwrap_or_default(),
        })
        .collect();

    Ok(Json(MatterWorkspace {
        matter_id: matter_id.0,
        tenant_id: tenant_id.0,
        documents,
        extractions,
        rag_documents,
        generated_at: chrono::Utc::now().to_rfc3339(),
    }))
}