//! pacgate-template — Document templates for legal documents.
//!
//! Status: Stub — template library planned.

#![allow(dead_code)]

use pacgate_core::TemplateId;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Template {
    pub id:        TemplateId,
    pub name:      String,
    pub category:  String,
    pub structure: serde_json::Value,
}

/// List all templates (stub).
pub fn list_templates() -> Vec<Template> {
    Vec::new()
}