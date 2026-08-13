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
    pub step_count:  usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowDetail {
    pub id:          String,
    pub name:        String,
    pub description: String,
    pub category:    String,
    pub steps:       Vec<WorkflowStepDetail>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowStepDetail {
    pub name:        String,
    pub description: String,
    pub tool:        String,
}

pub async fn list_workflows(
    State(state): State<AppState>,
) -> Result<Json<Vec<WorkflowSummary>>, ApiError> {
    let workflows = state.config.workflows_dir
        .as_ref()
        .map(|dir| pacgate_workflow::list_all_workflows(Some(dir.as_path())))
        .unwrap_or_else(pacgate_workflow::list_workflows);

    let summaries: Vec<WorkflowSummary> = workflows
        .iter()
        .map(|w| WorkflowSummary {
            id:          w.id.to_string(),
            name:        w.name.clone(),
            description: w.description.clone(),
            category:    w.category.clone(),
            step_count:  w.steps.len(),
        })
        .collect();

    Ok(Json(summaries))
}

pub async fn get_workflow(
    State(state): State<AppState>,
    Path(id):     Path<String>,
) -> Result<Json<WorkflowDetail>, ApiError> {
    if id.trim().is_empty() {
        return Err(ApiError::bad_request("workflow id must not be empty"));
    }

    let workflow_id: pacgate_core::WorkflowId = id
        .parse()
        .map_err(|e| ApiError::bad_request(&format!("invalid workflow id: {e}")))?;

    let workflow = state.config.workflows_dir
        .as_ref()
        .and_then(|dir| pacgate_workflow::get_workflow_all(&workflow_id, Some(dir.as_path())))
        .or_else(|| pacgate_workflow::get_workflow(&workflow_id))
        .ok_or_else(|| ApiError::not_found("workflow not found"))?;

    Ok(Json(WorkflowDetail {
        id:          workflow.id.to_string(),
        name:        workflow.name.clone(),
        description: workflow.description.clone(),
        category:    workflow.category.clone(),
        steps:       workflow.steps
            .iter()
            .map(|s| WorkflowStepDetail {
                name:        s.name.clone(),
                description: s.description.clone(),
                tool:        s.tool.clone(),
            })
            .collect(),
    }))
}
