//! pacgate-workflow — 160+ legal workflow templates (Suzie Law seed, MIT).
//!
//! Status: Stub — template loading planned.

#![allow(dead_code)]

use pacgate_core::WorkflowId;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Workflow {
    pub id:          WorkflowId,
    pub name:        String,
    pub description: String,
    pub steps:       Vec<WorkflowStep>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WorkflowStep {
    pub name:        String,
    pub description: String,
    pub tool:        String,
}

/// List all workflows (stub — returns empty for now).
pub fn list_workflows() -> Vec<Workflow> {
    Vec::new()
}