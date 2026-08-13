//! pacgate-docx — DOCX generation and tracked-change editing engine.
//!
//! Produces OOXML-compliant `.docx` ZIP archives entirely in Rust using
//! `zip` + `quick-xml`. Applies word-level diffs via the `similar` crate and
//! serialises them as `<w:ins>` / `<w:del>` revision marks.

mod builder;
mod diff;
mod error;
mod ooxml;
mod parser;
mod store;
mod styles;
mod templates;

pub use builder::{DocxBuilder, DocxSection};
pub use diff::{apply_tracked_edit, TrackedEdit};
pub use parser::extract_text;
pub use store::FsDocumentStore;
pub use templates::LegalDocumentTemplate;

use pacgate_core::{PacgateError, Result};

// ─────────────────────────────────────────────────────────────────────────────
// Public surface
// ─────────────────────────────────────────────────────────────────────────────

/// Generate a DOCX from a structured JSON definition.
///
/// # Structure schema
///
/// ```json
/// {
///   "title": "Non-Disclosure Agreement",
///   "landscape": false,
///   "sections": [
///     { "type": "heading", "level": 1, "text": "Background" },
///     { "type": "paragraph", "text": "The Parties agree..." },
///     { "type": "numbered_list", "items": ["Clause A", "Clause B"] },
///     { "type": "table", "headers": ["Party", "Role"], "rows": [["Pacgate", "Licensor"]] },
///     { "type": "signature_page", "parties": [{"name": "Pacgate Ltd.", "role": "Licensor"}] }
///   ]
/// }
/// ```
pub fn generate_from_structure(structure: &serde_json::Value) -> Result<Vec<u8>> {
    let builder = DocxBuilder::from_json(structure)
        .map_err(|e| PacgateError::DocxError(e.to_string()))?;
    builder.build().map_err(|e| PacgateError::DocxError(e.to_string()))
}

/// Apply a tracked-change edit to an existing DOCX byte buffer.
pub fn apply_edit(
    docx_bytes:     &[u8],
    find:           &str,
    replace:        &str,
    context_before: Option<&str>,
    context_after:  Option<&str>,
) -> Result<Vec<u8>> {
    let edit = TrackedEdit::new(find, replace, context_before, context_after);
    apply_tracked_edit(docx_bytes, &edit).map_err(|e| PacgateError::DocxError(e.to_string()))
}

/// Extract plain text from a DOCX byte buffer (for RAG indexing / read_document).
pub fn read_text(docx_bytes: &[u8]) -> Result<String> {
    extract_text(docx_bytes).map_err(|e| PacgateError::DocxError(e.to_string()))
}
