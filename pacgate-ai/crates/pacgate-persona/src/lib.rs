//! pacgate-persona — Legal AI personas for different practice areas.
//!
//! Status: Stub — 20 personas planned (M&A, litigation, IP, compliance, etc.)

#![allow(dead_code)]

use pacgate_core::{PersonaId, PracticeArea};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Persona {
    pub id:          PersonaId,
    pub name:        String,
    pub practice_area: PracticeArea,
    pub system_prompt: String,
    pub description: String,
}

/// List all built-in personas (stub — returns empty for now).
pub fn list_personas() -> Vec<Persona> {
    Vec::new()
}