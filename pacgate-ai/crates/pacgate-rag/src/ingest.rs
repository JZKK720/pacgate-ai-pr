//! Chunk ingestor — splits document text into chunks, embeds them, and stores in Postgres.
//!
//! Chunking strategy:
//! - Split by paragraphs (double newlines)
//! - Merge short paragraphs to reach ~500-1000 chars per chunk
//! - Split long paragraphs at sentence boundaries
//! - Each chunk gets embedded via Ollama and stored in kb_chunks

use pacgate_core::{DataLevel, DocumentId, Jurisdiction, MatterId, SourceLevel, TenantId};
use sqlx::PgPool;
use tracing::instrument;

use crate::{EmbeddingService, RagError};

const MIN_CHUNK_SIZE: usize = 500;
const MAX_CHUNK_SIZE: usize = 1500;

pub struct ChunkIngestor {
    db: PgPool,
    embedding: EmbeddingService,
}

impl ChunkIngestor {
    pub fn new(db: PgPool, embedding: EmbeddingService) -> Self {
        Self { db, embedding }
    }

    /// Ingest a document: split into chunks, embed, and store in kb_chunks.
    ///
    /// Each chunk is tagged with the document's jurisdiction, source level,
    /// and data classification level (T1-T4) for later filtering during RAG search.
    ///
    /// Default data_level is T2 (restricted seed) if not specified.
    #[instrument(skip(self, content), fields(doc_id = %doc_id.as_str(), content_len = content.len()))]
    pub async fn ingest_document(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        doc_id: &DocumentId,
        content: &str,
        jurisdiction: &Jurisdiction,
        source_level: &SourceLevel,
    ) -> Result<u32, RagError> {
        self.ingest_with_data_level(
            tenant_id, matter_id, doc_id, content,
            jurisdiction, source_level, DataLevel::T2RestrictedSeed,
        ).await
    }

    /// Ingest a document with explicit data classification level.
    ///
    /// Use this when you know the T1-T4 tier of the source material:
    /// - T1: blank templates, standard texts (no client identity)
    /// - T2: completed project deliverables (retains client context)
    /// - T3: active project files (MatterId-scoped)
    /// - T4: special sensitive (strict isolation)
    pub async fn ingest_with_data_level(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        doc_id: &DocumentId,
        content: &str,
        jurisdiction: &Jurisdiction,
        source_level: &SourceLevel,
        data_level: DataLevel,
    ) -> Result<u32, RagError> {
        // Split into chunks
        let chunks = self.chunk_text(content);

        if chunks.is_empty() {
            return Ok(0);
        }

        // Serialize jurisdiction and source_level to snake_case strings
        let jur_str = serde_json::to_value(jurisdiction)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| "international".to_string());

        let sl_str = serde_json::to_value(source_level)
            .ok()
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| "model_inference".to_string());

        let dl_str = data_level.code();

        // Embed each chunk
        let chunk_refs: Vec<&str> = chunks.iter().map(|s| s.as_str()).collect();
        let embeddings = self.embedding.embed_batch(&chunk_refs.iter().map(|s| s.to_string()).collect::<Vec<_>>()).await?;

        // Store in Postgres
        let mut stored = 0u32;
        for (i, (chunk, embedding)) in chunks.iter().zip(embeddings.iter()).enumerate() {
            let embedding_str = format!(
                "[{}]",
                embedding
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            );

            sqlx::query(
                "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, embedding, jurisdiction, source_level, data_level)
                 VALUES ($1, $2, $3, $4, $5, $6::vector, $7, $8, $9)",
            )
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(doc_id.0)
            .bind(i as i32)
            .bind(chunk)
            .bind(&embedding_str)
            .bind(&jur_str)
            .bind(&sl_str)
            .bind(dl_str)
            .execute(&self.db)
            .await?;

            stored += 1;
        }

        tracing::info!("ingested {stored} chunks for document {} (jurisdiction={jur_str}, source_level={sl_str}, data_level={dl_str})", doc_id.as_str());
        Ok(stored)
    }

    /// Delete all chunks for a document (used when a document is deleted or re-ingested).
    pub async fn delete_for_document(&self, doc_id: &DocumentId) -> Result<(), RagError> {
        sqlx::query("DELETE FROM kb_chunks WHERE document_id = $1")
            .bind(doc_id.0)
            .execute(&self.db)
            .await?;
        Ok(())
    }

    /// Split text into chunks of ~500-1500 characters at paragraph boundaries.
    fn chunk_text(&self, text: &str) -> Vec<String> {
        let paragraphs: Vec<&str> = text.split("\n\n").collect();
        let mut chunks = Vec::new();
        let mut current = String::new();

        for para in paragraphs {
            let trimmed = para.trim();
            if trimmed.is_empty() {
                continue;
            }

            // If adding this paragraph would exceed max size, flush current chunk
            if !current.is_empty() && current.len() + trimmed.len() > MAX_CHUNK_SIZE {
                chunks.push(current.clone());
                current.clear();
            }

            // If the paragraph itself is too long, split it at sentence boundaries
            if trimmed.len() > MAX_CHUNK_SIZE {
                if !current.is_empty() {
                    chunks.push(current.clone());
                    current.clear();
                }
                let sentences = self.split_sentences(trimmed);
                for sentence in sentences {
                    if current.len() + sentence.len() > MAX_CHUNK_SIZE && !current.is_empty() {
                        chunks.push(current.clone());
                        current.clear();
                    }
                    if !current.is_empty() {
                        current.push(' ');
                    }
                    current.push_str(&sentence);
                }
            } else {
                if !current.is_empty() {
                    current.push_str("\n\n");
                }
                current.push_str(trimmed);
            }

            // Flush if we've reached a good chunk size
            if current.len() >= MIN_CHUNK_SIZE {
                chunks.push(current.clone());
                current.clear();
            }
        }

        // Flush remaining
        if !current.is_empty() {
            chunks.push(current);
        }

        chunks
    }

    /// Split a long paragraph into sentences.
    fn split_sentences(&self, text: &str) -> Vec<String> {
        // Simple sentence splitter: split on ". " "? " "! "
        let mut sentences = Vec::new();
        let mut current = String::new();

        for ch in text.chars() {
            current.push(ch);
            if (ch == '.' || ch == '?' || ch == '!') && current.len() > 50 {
                sentences.push(current.trim().to_string());
                current.clear();
            }
        }

        if !current.trim().is_empty() {
            sentences.push(current.trim().to_string());
        }

        sentences
    }
}