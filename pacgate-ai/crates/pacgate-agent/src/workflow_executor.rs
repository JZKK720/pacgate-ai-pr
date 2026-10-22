//! WorkflowExecutor — drives AgentLoop step-by-step through a Workflow.
//!
//! Each workflow step carries a `tool` name (which agent tool to call) and
//! `parameters` (which may include a `system_prompt` field). The executor:
//!
//! 1. Extracts the `system_prompt` from step parameters (if present)
//! 2. Builds a user message that describes the step task
//! 3. Calls `AgentLoop::run()` with the accumulated context
//! 4. Collects the output and passes it as context to the next step
//!
//! The executor is designed to work with the YAML workflow templates in
//! `pacgate-ai/workflows/*.yaml`, where each step's `parameters.system_prompt`
//! contains the full prompt template from the client's prompt guides.

use pacgate_core::{DdAgentConfig, MatterId};
use pacgate_llm::LlmRouter;
use pacgate_workflow::{Workflow, WorkflowStep};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{info, instrument};

use crate::AgentLoop;

/// Result of executing a single workflow step.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub step_name: String,
    pub tool: String,
    pub content: Option<String>,
    pub citations: Vec<pacgate_core::CitationRef>,
    pub tools_used: Vec<String>,
    /// The step's tools ran but the agent loop hit its round cap before the model
    /// wrote a closing summary. The step's side effects are real (a document was
    /// created); only the narration is missing. Reported, not failed - see
    /// `AgentTurnResult::max_rounds_reached`.
    #[serde(default)]
    pub max_rounds_reached: bool,
}

/// Result of executing a complete workflow.
#[derive(Debug, Clone)]
pub struct WorkflowResult {
    pub workflow_name: String,
    pub steps: Vec<StepResult>,
    /// Final output from the last step (convenience accessor)
    pub final_content: Option<String>,
}

impl WorkflowResult {
    /// Returns the output of the last step that produced content.
    pub fn last_output(&self) -> Option<&str> {
        self.steps.iter().rev().find_map(|s| s.content.as_deref())
    }
}

/// Extract the `system_prompt` from a step's parameters (JSON).
fn extract_system_prompt(parameters: &serde_json::Value) -> Option<String> {
    parameters
        .get("system_prompt")
        .and_then(|v| v.as_str())
        .map(String::from)
}

/// Build a user message for a workflow step.
///
/// The message includes:
/// - The step name and description
/// - Any accumulated context from prior steps
/// - A request to execute the step's tool with its parameters
fn build_step_message(
    step: &WorkflowStep,
    prior_context: &[String],
    matter_id: Option<&MatterId>,
) -> String {
    let mut msg = format!("## Task: {}\n\n{}\n\n", step.name, step.description);

    // Name the tool the step exists to run. Without this the model has to infer
    // it from prose, and it does not: measured 2026-10-22, the 项目概况表编制 step
    // declares `generate_docx` and its system_prompt says "输出为Word文档", yet the
    // model called `list_documents, kb_search` and stopped on 3 runs out of 3.
    // The route still returned 200, so the defect surfaced as an empty result
    // rather than an error. `step.tool` was previously only logged and copied
    // into the result, never sent.
    if !step.tool.trim().is_empty() {
        msg.push_str(&format!(
            "## Required tool\n\nCall `{}` to complete this step. Do not substitute a \
             different tool, and do not stop after gathering context.\n\n",
            step.tool
        ));
    }

    if let Some(matter_id) = matter_id {
        msg.push_str("## Matter context\n\n");
        msg.push_str(&format!(
            "- matter_id: {}\n- Use this matter_id for all matter-scoped tool calls in this workflow unless the user explicitly switches matters.\n\n",
            matter_id.as_str()
        ));
    }

    if !prior_context.is_empty() {
        msg.push_str("## Context from prior steps\n\n");
        for (i, ctx) in prior_context.iter().enumerate() {
            msg.push_str(&format!("### Step {} output\n\n{}\n\n", i + 1, ctx));
        }
    }

    // Include non-system_prompt parameters as instructions
    if let Some(obj) = step.parameters.as_object() {
        let extra: Vec<_> = obj.iter().filter(|(k, _)| *k != "system_prompt").collect();
        if !extra.is_empty() {
            msg.push_str("## Parameters\n\n");
            for (key, val) in extra {
                msg.push_str(&format!("- **{key}**: {}\n", val));
            }
        }
    }

    msg
}

/// The workflow executor — runs a workflow's steps sequentially through AgentLoop.
pub struct WorkflowExecutor<'a> {
    agent: &'a AgentLoop,
}

impl<'a> WorkflowExecutor<'a> {
    pub fn new(agent: &'a AgentLoop) -> Self {
        Self { agent }
    }

    /// Execute a workflow sequentially.
    ///
    /// Each step's output is accumulated and passed as context to subsequent steps.
    /// The `persona_prompt` (if any) is applied to all steps — typically the SOUL
    /// persona's system preamble.
    ///
    /// When `dd_config` is provided, the DD agent's system prompt is composed and
    /// injected as an additional system prompt layer for DD workflows.
    #[instrument(skip(self, workflow, persona_prompt, dd_config), fields(workflow = %workflow.name, steps = workflow.steps.len()))]
    pub async fn execute(
        &self,
        workflow: &Workflow,
        persona_prompt: Option<&str>,
        matter_id: Option<&MatterId>,
        dd_config: Option<&DdAgentConfig>,
    ) -> Result<WorkflowResult, pacgate_core::PacgateError> {
        self.execute_with_router(&self.agent.router, workflow, persona_prompt, matter_id, dd_config)
            .await
    }

    /// Execute a workflow using an explicit router (per-tenant model overrides).
    #[instrument(skip(self, router, workflow, persona_prompt, dd_config), fields(workflow = %workflow.name, steps = workflow.steps.len()))]
    pub async fn execute_with_router(
        &self,
        router: &Arc<LlmRouter>,
        workflow: &Workflow,
        persona_prompt: Option<&str>,
        matter_id: Option<&MatterId>,
        dd_config: Option<&DdAgentConfig>,
    ) -> Result<WorkflowResult, pacgate_core::PacgateError> {
        // Pre-compose the DD system prompt if a DD config is provided
        let dd_prompt = dd_config.map(|c| c.compose_system_prompt());

        let mut results = Vec::with_capacity(workflow.steps.len());
        let mut prior_context: Vec<String> = Vec::new();

        for (i, step) in workflow.steps.iter().enumerate() {
            info!(step = i, name = %step.name, tool = %step.tool, "executing workflow step");

            // Compose the step's system_prompt with the persona_prompt and DD prompt
            let step_prompt = extract_system_prompt(&step.parameters);
            let combined_prompt = compose_combined_prompt(
                persona_prompt,
                step_prompt.as_deref(),
                dd_prompt.as_deref(),
            );

            // Build the user message for this step
            let user_message = build_step_message(step, &prior_context, matter_id);

            // Run the agent loop for this step
            let turn_result = self
                .agent
                .run_with_router(router, vec![], &user_message, combined_prompt.as_deref(), matter_id)
                .await?;

            // Record the result
            let step_result = StepResult {
                step_name: step.name.clone(),
                tool: step.tool.clone(),
                content: turn_result.content.clone(),
                citations: turn_result.citations.clone(),
                tools_used: turn_result.tool_calls_made.clone(),
                max_rounds_reached: turn_result.max_rounds_reached,
            };
            if turn_result.max_rounds_reached {
                // Make it visible at the step that hit it. Without this the run
                // looks like an ordinary success, and the missing narration is
                // mistaken for a model that "sometimes doesn't write anything".
                tracing::warn!(
                    step = i,
                    name = %step.name,
                    tool = %step.tool,
                    tools_used = turn_result.tool_calls_made.len(),
                    "step reached its tool-round cap; its tools ran, the closing summary did not"
                );
            }

            // Accumulate context for the next step
            if let Some(ref content) = turn_result.content {
                prior_context.push(content.clone());
            }

            results.push(step_result);
        }

        let final_content = results.iter().rev().find_map(|r| r.content.clone());

        info!(
            workflow = %workflow.name,
            steps_completed = results.len(),
            has_output = final_content.is_some(),
            "workflow execution complete"
        );

        Ok(WorkflowResult {
            workflow_name: workflow.name.clone(),
            steps: results,
            final_content,
        })
    }
}

/// Compose the full system prompt from three optional layers:
/// 1. SOUL persona prompt (identity overlay + boundary rules)
/// 2. DD agent config prompt (domain expertise + focus areas + severity rules)
/// 3. Step-specific system prompt (from workflow template parameters)
///
/// Layers are joined with double newlines. None layers are skipped.
fn compose_combined_prompt(
    persona: Option<&str>,
    step_prompt: Option<&str>,
    dd_prompt: Option<&str>,
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();

    if let Some(p) = persona {
        parts.push(p.to_string());
    }
    if let Some(dd) = dd_prompt {
        parts.push(dd.to_string());
    }
    if let Some(sp) = step_prompt {
        parts.push(sp.to_string());
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn step_message_names_the_declared_tool() {
        // A workflow step declares the tool it exists to run. That declaration
        // used to be recorded in the result and logged, but never sent to the
        // model, so the model had to infer the tool from prose. Measured
        // 2026-10-22: the 项目概况表编制 step declares `generate_docx` and its
        // system_prompt says "输出为Word文档", yet the model called
        // `list_documents, kb_search` and stopped - 3 runs out of 3 - so the
        // route returned 200 and produced no document.
        let step = WorkflowStep {
            name: "Generate project overview".to_string(),
            description: "Generate the project overview table".to_string(),
            tool: "generate_docx".to_string(),
            parameters: serde_json::json!({}),
        };

        let message = build_step_message(&step, &[], None);

        assert!(
            message.contains("generate_docx"),
            "the step's declared tool must reach the model; got: {message}"
        );
    }

    #[test]
    fn step_message_includes_matter_context() {
        let step = WorkflowStep {
            name: "List documents".to_string(),
            description: "List all documents for the matter".to_string(),
            tool: "list_documents".to_string(),
            parameters: serde_json::json!({}),
        };
        let matter_id = MatterId(uuid::Uuid::parse_str("22222222-2222-2222-2222-222222222222").unwrap());

        let message = build_step_message(&step, &[], Some(&matter_id));

        assert!(message.contains("Matter context"));
        assert!(message.contains(&matter_id.as_str()));
    }

    #[test]
    fn compose_combined_prompt_joins_layers() {
        let result = compose_combined_prompt(Some("persona"), Some("step"), Some("dd")).unwrap();
        assert!(result.contains("persona"));
        assert!(result.contains("step"));
        assert!(result.contains("dd"));
    }

    #[test]
    fn compose_combined_prompt_skips_none_layers() {
        let result = compose_combined_prompt(None, Some("only step"), None).unwrap();
        assert_eq!(result, "only step");
    }

    #[test]
    fn compose_combined_prompt_all_none_returns_none() {
        assert!(compose_combined_prompt(None, None, None).is_none());
    }
}
