use axum::{
    extract::{Extension, Path, Query, State},
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::{MatterId, SoulPersona, TenantId};
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

fn claims_to_tenant_id(claims: &Claims) -> Result<TenantId, ApiError> {
    claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))
}

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
/// `search` filters by keyword match in name or description.
#[derive(Debug, Deserialize)]
pub struct WorkflowListQuery {
    pub category: Option<String>,
    pub search: Option<String>,
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

    let search_lower = query.search.as_ref().map(|s| s.to_lowercase());

    let summaries: Vec<WorkflowSummary> = workflows
        .iter()
        .filter(|w| {
            // Category filter
            let category_match = query
                .category
                .as_ref()
                .map_or(true, |cat| &w.category == cat);

            // Search filter (case-insensitive substring match on name + description)
            let search_match = search_lower.as_ref().map_or(true, |s| {
                w.name.to_lowercase().contains(s) || w.description.to_lowercase().contains(s)
            });

            category_match && search_match
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
// Workflow categories
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct CategoryInfo {
    pub category: String,
    pub workflow_count: usize,
}

/// List all distinct workflow categories with counts.
/// `GET /api/workflows/categories`
pub async fn list_workflow_categories(
    State(state): State<AppState>,
) -> Result<Json<Vec<CategoryInfo>>, ApiError> {
    let workflows = state
        .config
        .workflows_dir
        .as_ref()
        .map(|dir| pacgate_workflow::list_all_workflows(Some(dir.as_path())))
        .unwrap_or_else(pacgate_workflow::list_workflows);

    // Group by category and count
    let mut categories: std::collections::BTreeMap<String, usize> =
        std::collections::BTreeMap::new();
    for w in &workflows {
        *categories.entry(w.category.clone()).or_insert(0) += 1;
    }

    let result: Vec<CategoryInfo> = categories
        .into_iter()
        .map(|(category, count)| CategoryInfo {
            category,
            workflow_count: count,
        })
        .collect();

    Ok(Json(result))
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
    /// Optional DD domain for injecting DD agent config as system prompt.
    /// When set, the WorkflowExecutor injects the matching DdAgentConfig's
    /// system prompt (focus areas, severity rules, Chinese-law citations).
    /// Valid values: "legal", "finance", "commercial", "product_tech",
    /// "cybersecurity", "hr", "tax", "regulatory", "esg".
    pub dd_domain: Option<String>,
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
/// Body: { "matter_id": "...", "persona_id": "optional-uuid", "dd_domain": "optional-domain" }
pub async fn execute_workflow(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
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
    let tenant_id = claims_to_tenant_id(&claims)?;
    let matter_id: MatterId = req
        .matter_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

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

    let dd_config = match req.dd_domain.as_deref() {
        Some(raw_domain) => {
            let domain = pacgate_core::dd_domain_from_str(raw_domain).ok_or_else(|| {
                ApiError::bad_request(
                    "invalid dd_domain; expected one of: legal, finance, commercial, product_tech, cybersecurity, hr, tax, regulatory, esg",
                )
            })?;

            Some(
                pacgate_core::dd_config_for_domain(domain).ok_or_else(|| {
                    ApiError::bad_request("dd_domain is recognized but has no configured DD agent")
                })?,
            )
        }
        None => None,
    };

    if dd_config.is_some() {
        tracing::info!(
            workflow_id = %workflow_id.as_str(),
            dd_domain = ?req.dd_domain,
            "injecting DD agent config into workflow execution"
        );
    }

    // Execute the workflow via WorkflowExecutor
    let executor = pacgate_agent::WorkflowExecutor::new(state.agent_loop.as_ref());
    let result = executor
        .execute(&workflow, persona_prompt.as_deref(), Some(&matter_id), dd_config.as_ref())
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
