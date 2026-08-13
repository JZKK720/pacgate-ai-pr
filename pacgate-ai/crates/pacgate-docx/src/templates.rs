//! Legal document templates — predefined DOCX structures.

use serde::{Deserialize, Serialize};

/// A legal document template with placeholder fields.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LegalDocumentTemplate {
    pub name:        String,
    pub category:    String,
    pub structure:   serde_json::Value,
}

/// Predefined templates (stub — returns empty for now).
pub fn list_templates() -> Vec<LegalDocumentTemplate> {
    Vec::new()
}