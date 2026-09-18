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
    pub external_key: Option<String>,
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

fn matter_memory_path(
    data_dir: &std::path::Path,
    tenant_id: &TenantId,
    matter_id: &MatterId,
) -> std::path::PathBuf {
    pacgate_tenant::matter_dir(data_dir, tenant_id, matter_id).join("memory.json")
}

fn default_matter_memory() -> serde_json::Value {
    serde_json::json!({
        "version": "2.0",
        "revision": 0,
        "lastUpdated": "",
        "user": {},
        "history": {},
        "facts": []
    })
}

/// Read the `revision` counter out of a matter-memory object.
///
/// Absent, negative or non-numeric all read as 0. That is the fail-closed
/// choice for a *missing* value, and it matches a brand-new matter whose file
/// has never been written.
fn memory_revision(memory: &serde_json::Value) -> u64 {
    memory
        .get("revision")
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
}

/// Enforce optimistic concurrency on a memory write.
///
/// `expected` is the revision the caller believes it is updating, or `None`
/// for an unconditional write.
///
/// Two deliberate decisions, both recorded because they are judgement calls
/// rather than derivable:
///
/// 1. `None` is ALLOWED. Requiring `If-Match` would break the existing
///    deer-flow adapter, which does not send one. The fix for the silent-loss
///    defect must not itself break a working integration, so the stricter
///    behaviour is opt-in per caller. Task 4 makes the adapter opt in.
/// 2. A claim that matches neither the current revision nor the past is a
///    conflict, not a fast-forward. A caller claiming revision 99 against
///    revision 5 is confused, and guessing which of the two is right is how
///    data gets lost.
fn check_revision(current: &serde_json::Value, expected: Option<u64>) -> Result<(), ApiError> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let actual = memory_revision(current);
    if expected == actual {
        return Ok(());
    }
    Err(ApiError::conflict(format!(
        "matter memory revision mismatch: file is at {}, caller expected {}",
        actual, expected
    )))
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
    let external_key = req
        .external_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let persona_id = req
        .persona_id
        .as_deref()
        .and_then(|s| s.parse::<uuid::Uuid>().ok())
        .map(pacgate_core::PersonaId);

    let matter = state
        .matter_store
        .create(
            &tenant_id,
            &req.name,
            req.description.as_deref(),
            external_key.as_deref(),
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

pub async fn get_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let path = matter_memory_path(&state.config.data_dir, &tenant_id, &matter_id);
    if !path.exists() {
        return Ok(Json(default_matter_memory()));
    }

    let bytes = std::fs::read(&path)
        .map_err(|e| ApiError::internal(format!("failed to read matter memory: {e}")))?;
    let memory = serde_json::from_slice(&bytes)
        .map_err(|e| ApiError::internal(format!("failed to parse matter memory: {e}")))?;

    Ok(Json(memory))
}

pub async fn save_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
    Json(memory): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !memory.is_object() {
        return Err(ApiError::bad_request("matter memory must be a JSON object"));
    }

    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let path = matter_memory_path(&state.config.data_dir, &tenant_id, &matter_id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| ApiError::internal(format!("failed to prepare matter memory dir: {e}")))?;
    }

    let bytes = serde_json::to_vec_pretty(&memory)
        .map_err(|e| ApiError::internal(format!("failed to serialize matter memory: {e}")))?;
    std::fs::write(&path, bytes)
        .map_err(|e| ApiError::internal(format!("failed to write matter memory: {e}")))?;

    Ok(Json(memory))
}

pub async fn list_matter_documents(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<Vec<pacgate_core::Document>>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let docs = state
        .doc_store
        .list_for_matter(&matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(docs))
}

#[cfg(test)]
mod memory_concurrency_tests {
    use super::*;

    #[test]
    fn revision_defaults_to_zero_when_absent_or_unusable() {
        assert_eq!(memory_revision(&serde_json::json!({})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": 7})), 7);
        assert_eq!(memory_revision(&serde_json::json!({"revision": "nope"})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": -3})), 0);
    }

    #[test]
    fn an_unconditional_write_is_allowed() {
        // Backwards compatibility: an existing caller that sends no If-Match
        // must keep working. Deliberate, not an oversight - see the plan.
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, None).is_ok());
    }

    #[test]
    fn a_matching_revision_is_allowed() {
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, Some(5)).is_ok());
    }

    #[test]
    fn a_stale_revision_is_a_conflict() {
        let current = serde_json::json!({"revision": 5});
        let err = check_revision(&current, Some(4)).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::CONFLICT);
    }

    #[test]
    fn a_future_revision_is_also_a_conflict() {
        // A caller claiming a revision that does not exist is confused, not
        // ahead. Treating it as a conflict is the fail-closed choice.
        let current = serde_json::json!({"revision": 5});
        assert_eq!(
            check_revision(&current, Some(99)).unwrap_err().status,
            axum::http::StatusCode::CONFLICT
        );
    }

    #[test]
    fn a_new_matter_with_no_file_conflicts_only_on_a_non_zero_claim() {
        // No file means revision 0. If-Match: 0 is correct; anything else is stale.
        let current = default_matter_memory();
        assert!(check_revision(&current, Some(0)).is_ok());
        assert!(check_revision(&current, Some(1)).is_err());
    }
}
