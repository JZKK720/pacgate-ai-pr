use axum::{
    extract::{Path, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowSummary {
    pub id:          String,
    pub name:        String,
    pub description: String,
    pub category:    String,
}

pub async fn list_workflows(
    State(_state): State<AppState>,
) -> Result<Json<Vec<WorkflowSummary>>, ApiError> {
    Err(ApiError::internal("workflow store not yet wired"))
}

pub async fn get_workflow(
    State(_state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<WorkflowSummary>, ApiError> {
    if id.trim().is_empty() {
        return Err(ApiError::bad_request("workflow id must not be empty"));
    }
    Err(ApiError::internal("workflow store not yet wired"))
}
