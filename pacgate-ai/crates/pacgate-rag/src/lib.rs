//! pacgate-rag — Per-tenant retrieval using pgvector + tsvector.
//!
//! Status: Stub — implementation planned with pgvector extension.

#![allow(dead_code)]

/// Search the knowledge base for a matter (stub).
pub async fn kb_search(
    _matter_id: &pacgate_core::MatterId,
    _query: &str,
    _top_k: u32,
) -> Vec<KbSearchResult> {
    Vec::new()
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct KbSearchResult {
    pub content:    String,
    pub score:      f32,
    pub source_doc: String,
    pub page:       Option<u32>,
}