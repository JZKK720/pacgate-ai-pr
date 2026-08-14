use axum::{
    extract::{Extension, Path, Query, State},
    Json,
};
use pacgate_core::SoulPersona;
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowSummary {
    pub id: String,
    pub name: String,
    pub description: String,
    pub category: String,
    pub step_count: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowDetail {
    pub id: String,
    pub name: String,
    pub description: String,
    pub category: String,
    pub steps: Vec<WorkflowStepDetail>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WorkflowStepDetail {
    pub name: String,
    pub description: String,
    pub tool: String,
}

/// Query parameters for workflow listing.
/// `category` filters by workflow category (e.g., "fund_formation", "litigation").
#[derive(Debug, Deserialize)]
pub struct WorkflowListQuery {
    pub category: Option<String>,
}

pub async fn list_workflows(
    State(state): State<AppState>,
    Query(query): Query<WorkflowListQuery>,
) -> Result<Json<Vec<WorkflowSummary>>, ApiError> {
    let workflows = state
        .config
        .workflows_dir
        .as_ref()
        .map(|dir| pacgate_workflow::list_all_workflows(Some(dir.as_path())))
        .unwrap_or_else(pacgate_workflow::list_workflows);

    let summaries: Vec<WorkflowSummary> = workflows
        .iter()
        .filter(|w| {
            query
                .category
                .as_ref()
                .map_or(true, |cat| &w.category == cat)
        })
        .map(|w| WorkflowSummary {
            id: w.id.to_string(),
            name: w.name.clone(),
            description: w.description.clone(),
            category: w.category.clone(),
            step_count: w.steps.len(),
        })
        .collect();

    Ok(Json(summaries))
}

pub async fn get_workflow(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> Result<Json<WorkflowDetail>, ApiError> {
    if id.trim().is_empty() {
        return Err(ApiError::bad_request("workflow id must not be empty"));
    }

    let workflow_id: pacgate_core::WorkflowId = id
        .parse()
        .map_err(|e| ApiError::bad_request(&format!("invalid workflow id: {e}")))?;

    let workflow = state
        .config
        .workflows_dir
        .as_ref()
        .and_then(|dir| pacgate_workflow::get_workflow_all(&workflow_id, Some(dir.as_path())))
        .or_else(|| pacgate_workflow::get_workflow(&workflow_id))
        .ok_or_else(|| ApiError::not_found("workflow not found"))?;

    Ok(Json(WorkflowDetail {
        id: workflow.id.to_string(),
        name: workflow.name.clone(),
        description: workflow.description.clone(),
        category: workflow.category.clone(),
        steps: workflow
            .steps
            .iter()
            .map(|s| WorkflowStepDetail {
                name: s.name.clone(),
                description: s.description.clone(),
                tool: s.tool.clone(),
            })
            .collect(),
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// Workflow execution
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ExecuteWorkflowRequest {
    /// The matter context (used for document/kb tools)
    pub matter_id: String,
    /// Optional explicit persona ID override (otherwise uses SOUL from request extensions)
    pub persona_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ExecuteWorkflowResponse {
    pub workflow_name: String,
    pub steps: Vec<ExecuteStepResult>,
    pub final_content: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ExecuteStepResult {
    pub step_name: String,
    pub tool: String,
    pub content: Option<String>,
    pub citations: Vec<pacgate_core::CitationRef>,
    pub tools_used: Vec<String>,
}

/// Execute a workflow: load the template, run each step through AgentLoop.
///
/// POST /api/workflows/:id/execute
/// Body: { "matter_id": "...", "persona_id": "optional-uuid" }
pub async fn execute_workflow(
    State(state): State<AppState>,
    Extension(soul): Extension<Option<SoulPersona>>,
    Path(id): Path<String>,
    Json(req): Json<ExecuteWorkflowRequest>,
) -> Result<Json<ExecuteWorkflowResponse>, ApiError> {
    if id.trim().is_empty() {
        return Err(ApiError::bad_request("workflow id must not be empty"));
    }

    let workflow_id: pacgate_core::WorkflowId = id
        .parse()
        .map_err(|e| ApiError::bad_request(&format!("invalid workflow id: {e}")))?;

    // Load the workflow (YAML first, then built-in fallback)
    let workflow = state
        .config
        .workflows_dir
        .as_ref()
        .and_then(|dir| pacgate_workflow::get_workflow_all(&workflow_id, Some(dir.as_path())))
        .or_else(|| pacgate_workflow::get_workflow(&workflow_id))
        .ok_or_else(|| ApiError::not_found("workflow not found"))?;

    // Compose persona prompt from SOUL + explicit persona_id
    let persona_prompt =
        compose_persona_prompt_for_workflow(soul.as_ref(), req.persona_id.as_deref());

    // Execute the workflow via WorkflowExecutor
    let executor = pacgate_agent::WorkflowExecutor::new(state.agent_loop.as_ref());
    let result = executor
        .execute(&workflow, persona_prompt.as_deref())
        .await
        .map_err(ApiError::from)?;

    Ok(Json(ExecuteWorkflowResponse {
        workflow_name: result.workflow_name,
        steps: result
            .steps
            .iter()
            .map(|s| ExecuteStepResult {
                step_name: s.step_name.clone(),
                tool: s.tool.clone(),
                content: s.content.clone(),
                citations: s.citations.clone(),
                tools_used: s.tools_used.clone(),
            })
            .collect(),
        final_content: result.final_content,
    }))
}

/// Compose persona prompt for workflow execution.
/// Reuses the same logic as chat.rs::compose_persona_prompt but in a standalone
/// form to avoid circular dependencies between modules.
fn compose_persona_prompt_for_workflow(
    soul: Option<&SoulPersona>,
    persona_id: Option<&str>,
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();

    if let Some(s) = soul {
        if !s.system_preamble.is_empty() {
            parts.push(format!("## IDENTITY OVERLAY\n\n{}", s.system_preamble));
        }
        if !s.boundary_rules.is_empty() {
            let rules: Vec<String> = s
                .boundary_rules
                .iter()
                .map(|r| format!("- {}", r.rule))
                .collect();
            parts.push(format!(
                "## BOUNDARY RULES (red lines)\n\n{}",
                rules.join("\n")
            ));
        }
        match s.output_format {
            pacgate_core::OutputFormat::Decision3Part => {
                parts.push("## OUTPUT FORMAT\n\nStructure your response in 3 parts: (1) conclusion, (2) options, (3) recommendation.".to_string());
            }
            pacgate_core::OutputFormat::LegalOpinion3Part => {
                parts.push("## OUTPUT FORMAT\n\nStructure your response in 3 parts: (1) 结论/结论建议, (2) 依据, (3) 待确认事项.".to_string());
            }
            pacgate_core::OutputFormat::Standard => {}
        }
    }

    if let Some(pid) = persona_id {
        if let Ok(uuid) = uuid::Uuid::parse_str(pid) {
            if let Some(practice_persona) = pacgate_persona::list_personas()
                .iter()
                .find(|p| p.id.0 == uuid)
            {
                parts.push(format!(
                    "## PRACTICE AREA INSTRUCTIONS\n\n{}",
                    practice_persona.system_prompt
                ));
            }
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}
