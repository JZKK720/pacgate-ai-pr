use axum::{
    extract::{Extension, Path, State},
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::{DocumentStore, Matter, MatterId, TenantId, UserId};
use serde::Deserialize;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Deserialize)]
pub struct CreateMatterRequest {
    pub name:        String,
    pub description: Option<String>,
    pub persona_id:  Option<String>,
}

/// Parse tenant_id and user_id from JWT Claims.
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

pub async fn create_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Json(req):         Json<CreateMatterRequest>,
) -> Result<Json<Matter>, ApiError> {
    if req.name.trim().is_empty() {
        return Err(ApiError::bad_request("matter name must not be empty"));
    }

    let (tenant_id, created_by) = claims_to_ids(&claims)?;
    let persona_id = req
        .persona_id
        .as_deref()
        .and_then(|s| s.parse::<uuid::Uuid>().ok())
        .map(|u| pacgate_core::PersonaId(u));

    let matter = state
        .matter_store
        .create(
            &tenant_id,
            &req.name,
            req.description.as_deref(),
            persona_id.as_ref(),
            &created_by,
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    // Ensure the on-disk directory structure exists
    pacgate_tenant::ensure_dirs(&state.config.data_dir, &tenant_id, &matter.id)
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(matter))
}

pub async fn list_matters(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
) -> Result<Json<Vec<Matter>>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matters = state
        .matter_store
        .list(&tenant_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(matters))
}

pub async fn get_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):          Path<String>,
) -> Result<Json<Matter>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matter = state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(matter))
}

pub async fn delete_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):          Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;
    state
        .matter_store
        .delete(&tenant_id, &matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(serde_json::json!({"deleted": true, "id": id})))
}

pub async fn list_matter_documents(
    State(state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<Vec<pacgate_core::Document>>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let docs = state
        .doc_store
        .list_for_matter(&matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(docs))
}
