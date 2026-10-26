//! Chunk ingestor — splits document text into chunks, embeds them, and stores in Postgres.
//!
//! Chunking strategy:
//! - Split by paragraphs (double newlines)
//! - Merge short paragraphs to reach ~500-1000 chars per chunk
//! - Split long paragraphs at sentence boundaries
//! - Each chunk gets embedded via Ollama and stored in kb_chunks

use pacgate_core::{DataLevel, DocumentId, Jurisdiction, MatterId, SourceLevel, TenantId};
use sqlx::{PgPool, Row};
use tracing::instrument;

use crate::{EmbeddingService, RagError};

const MIN_CHUNK_SIZE: usize = 500;
const MAX_CHUNK_SIZE: usize = 1500;

/// Ingest sets `sanitization_state` explicitly rather than leaning on the
/// column default. If a future migration changed the default, ingest behaviour
/// would change silently - and the direction of that change would decide
/// whether unsanitized text becomes retrievable.
const INSERT_CHUNK_SQL: &str = "\
    INSERT INTO kb_chunks \
        (tenant_id, matter_id, document_id, chunk_index, content, embedding, jurisdiction, source_level, data_level, sanitization_state) \
    VALUES ($1, $2, $3, $4, $5, $6::vector, $7, $8, $9, 'pending')";

/// Metadata for the rows about to be replaced, so the sanitized rewrite keeps
/// the document's own jurisdiction / source level / classification.
///
/// `IN ('pending','sanitized')`, not `= 'pending'`. Measured 2026-10-14: with the
/// pending-only filter, re-running the sanitize job on a document that the
/// pre-0.1.31 code had stamped `sanitized` while leaving the raw text in place
/// found NOTHING to rewrite (`chunks_promoted=0`) and the leak survived the
/// repair attempt. Widening the selection is what makes the sanitize job a
/// remediation path for already-poisoned documents, not just a forward-only
/// write. `blocked` is still excluded - a deliberate refusal must not be
/// silently overwritten - so this cannot resurrect a blocked row.
const SELECT_CHUNK_META_SQL: &str = "\
    SELECT jurisdiction, source_level, data_level FROM kb_chunks \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
    AND sanitization_state IN ('pending', 'sanitized') \
    ORDER BY chunk_index LIMIT 1";

/// Insert a chunk that is ALREADY redacted, so it is born `sanitized`.
const INSERT_SANITIZED_CHUNK_SQL: &str = "\
    INSERT INTO kb_chunks \
        (tenant_id, matter_id, document_id, chunk_index, content, embedding, jurisdiction, source_level, data_level, sanitization_state) \
    VALUES ($1, $2, $3, $4, $5, $6::vector, $7, $8, $9, 'sanitized')";

/// Delete the un-redacted rows being replaced.
///
/// Scoped to one document on purpose: a sanitization job covers one document
/// version, so a wider DELETE could remove chunks nobody examined. Deleting
/// (rather than updating) also drops the stale embeddings, which no longer
/// describe the text.
///
/// `IN ('pending','sanitized')` to match the selection above, so a repair pass
/// replaces the poisoned rows instead of leaving them beside the new ones.
/// `blocked` stays excluded: a deliberate refusal must never be silently
/// deleted, and it is the one state that means "do not touch".
const DELETE_UNSANITIZED_CHUNKS_SQL: &str = "\
    DELETE FROM kb_chunks \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state IN ('pending', 'sanitized')";

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
    #[allow(clippy::too_many_arguments)]
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

            sqlx::query(INSERT_CHUNK_SQL)
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

    /// Replace this document's `pending` chunks with redacted ones.
    ///
    /// The sanitizer calls this after a job produced `Verdict::Pass`. It is the
    /// only place a chunk may become `sanitized`, and it *earns* the label
    /// rather than asserting it: the text handed in is the job's redacted
    /// rendering, so a `sanitized` row's `content` is redacted by construction.
    ///
    /// This used to flip `sanitization_state` while leaving `content` untouched,
    /// which stored the raw text under a label that the RAG gate
    /// (`sanitization_state IN ('sanitized','never')`) then served to chat. The
    /// design is explicit that the label means the content is clean - section 3
    /// describes kb_chunks as the lane "chat retrieves", and the design note
    /// reads "sanitized chunks, so its inputs are already clean".
    ///
    /// Ordering: insert-then-delete. A crash between the two leaves the raw rows
    /// still in place, so the document keeps its original chunks and the job is
    /// simply re-runnable; a delete-then-insert crash would instead lose the
    /// document's chunks entirely. The whole rewrite runs in ONE transaction, so
    /// the intermediate state is never visible to a concurrent reader - a RAG
    /// query cannot observe both the new and the old chunk sets at once.
    ///
    /// Returns the number of redacted chunks stored (0 means the document had no
    /// chunks to rewrite, which the caller reports rather than treating as a
    /// successful promotion).
    pub async fn reingest_sanitized_chunks(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        document_id: &DocumentId,
        redacted_text: &str,
    ) -> Result<u64, RagError> {
        let mut tx = self
            .db
            .begin()
            .await
            .map_err(|e| RagError::Database(e.to_string()))?;

        // No rows means the caller has the wrong document, or the raw chunking
        // produced no text. Neither should be reported as "promoted".
        let meta = sqlx::query(SELECT_CHUNK_META_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|e| RagError::Database(e.to_string()))?;

        let Some(meta) = meta else {
            return Ok(0);
        };

        let jur_str: String = meta
            .try_get("jurisdiction")
            .unwrap_or_else(|_| "international".to_string());
        let sl_str: String = meta
            .try_get("source_level")
            .unwrap_or_else(|_| "model_inference".to_string());
        let dl_str: String = meta
            .try_get("data_level")
            .unwrap_or_else(|_| "T2".to_string());

        // Chunk with the same splitter as ingest, so chunk boundaries - and so
        // the review panel's spans and `page` values - stay meaningful.
        let chunks = self.chunk_text(redacted_text);
        if chunks.is_empty() {
            return Ok(0);
        }

        let embeddings = self
            .embedding
            .embed_batch(&chunks.iter().cloned().collect::<Vec<_>>())
            .await?;

        // Delete FIRST, then insert - both inside the transaction.
        //
        // The order is load-bearing now that the selection also accepts
        // 'sanitized' rows: the rows this method inserts are themselves
        // 'sanitized', so an insert-then-delete would have the DELETE match and
        // remove the freshly written chunks. MEASURED 2026-10-14 - that is
        // exactly what happened: promoted=1 and the document was left with
        // ZERO chunks, i.e. the repair silently stripped its RAG coverage.
        //
        // Delete-first is safe here because the transaction is atomic: the
        // intermediate state in which the old rows are gone and the new ones are
        // not yet written is never visible to another session. A crash rolls the
        // delete back, leaving the document exactly as it was.
        let removed = sqlx::query(DELETE_UNSANITIZED_CHUNKS_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&mut *tx)
            .await
            .map_err(|e| RagError::Database(e.to_string()))?
            .rows_affected();

        for (i, (chunk, embedding)) in chunks.iter().zip(embeddings.iter()).enumerate() {
            let embedding_str = format!(
                "[{}]",
                embedding
                    .iter()
                    .map(|v| v.to_string())
                    .collect::<Vec<_>>()
                    .join(",")
            );

            sqlx::query(INSERT_SANITIZED_CHUNK_SQL)
                .bind(tenant_id.0)
                .bind(matter_id.0)
                .bind(document_id.0)
                .bind(i as i32)
                .bind(chunk)
                .bind(&embedding_str)
                .bind(&jur_str)
                .bind(&sl_str)
                .bind(&dl_str)
                .execute(&mut *tx)
                .await
                .map_err(|e| RagError::Database(e.to_string()))?;
        }

        // Stored only once the whole rewrite is in place. An early return above
        // drops `tx` and rolls back, so a failure can never leave a document
        // half-rewritten.
        tx.commit()
            .await
            .map_err(|e| RagError::Database(e.to_string()))?;

        tracing::info!(
            "sanitized rewrite for document {}: {} redacted chunks stored, {} raw chunks removed",
            document_id.as_str(),
            chunks.len(),
            removed
        );

        Ok(chunks.len() as u64)
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

#[cfg(test)]
mod sanitization_state_tests {
    use super::*;

    #[test]
    fn a_new_chunk_defaults_to_pending() {
        // The ingest SQL must name the column explicitly. Relying on the
        // column default would mean a future ALTER changing the default
        // silently changes ingest behaviour.
        assert!(
            INSERT_CHUNK_SQL.contains("sanitization_state"),
            "ingest must set sanitization_state explicitly"
        );
        assert!(
            INSERT_CHUNK_SQL.contains("'pending'"),
            "a newly ingested chunk is pending, never sanitized"
        );
    }

    #[test]
    fn ingest_never_claims_sanitized() {
        assert!(
            !INSERT_CHUNK_SQL.contains("'sanitized'"),
            "ingestion cannot know a document is sanitized; only a job can say that"
        );
    }

    #[test]
    fn the_promote_statement_never_touches_a_blocked_row() {
        // A blocked row is a deliberate refusal and must survive every later
        // run. `blocked` appearing in the DELETE or the SELECT - in any form -
        // would let a re-run silently overwrite that decision.
        assert!(
            !DELETE_UNSANITIZED_CHUNKS_SQL.contains("blocked"),
            "the rewrite must never delete a blocked row"
        );
        assert!(
            !SELECT_CHUNK_META_SQL.contains("blocked"),
            "the rewrite must never read a blocked row's metadata"
        );
    }

    #[test]
    fn the_rewrite_can_repair_a_row_the_old_code_mislabelled() {
        // Measured 2026-10-14: with a pending-only filter, re-running the
        // sanitize job on a document the pre-0.1.31 code had stamped 'sanitized'
        // (content still raw) found nothing to rewrite, and the leak survived
        // the repair. Both statements must therefore accept 'sanitized'.
        assert!(
            SELECT_CHUNK_META_SQL.contains("'sanitized'"),
            "the selection must see already-mislabelled rows, or repair is a no-op"
        );
        assert!(
            DELETE_UNSANITIZED_CHUNKS_SQL.contains("'sanitized'"),
            "the delete must remove the mislabelled row, not leave it beside the new one"
        );
        assert!(
            SELECT_CHUNK_META_SQL.contains("'pending'"),
            "a fresh document's rows are pending and must still be rewritten"
        );
    }

    #[test]
    fn the_rewrite_deletes_before_it_inserts() {
        // The DELETE predicate matches 'sanitized', and the rows this method
        // INSERTs are themselves 'sanitized' - so the two overlap by
        // construction, and an insert-then-delete would have the DELETE remove
        // the chunks that were just written. MEASURED 2026-10-14: that left the
        // document with ZERO chunks while the job reported promoted=1, silently
        // stripping its RAG coverage.
        //
        // Ordering is therefore load-bearing, not stylistic, and it is asserted
        // against the source because no unit test can observe statement order
        // through the consts alone.
        let src = include_str!("ingest.rs");
        let body = src
            .split("pub async fn reingest_sanitized_chunks")
            .nth(1)
            .expect("reingest_sanitized_chunks must exist");
        let del = body
            .find("DELETE_UNSANITIZED_CHUNKS_SQL")
            .expect("the rewrite must delete the old rows");
        let ins = body
            .find("INSERT_SANITIZED_CHUNK_SQL")
            .expect("the rewrite must insert the redacted rows");
        assert!(
            del < ins,
            "delete must precede insert: the DELETE matches 'sanitized', which is \
             exactly what the INSERT writes, so insert-then-delete erases the result"
        );
    }

    #[test]
    fn a_sanitized_chunk_is_inserted_already_redacted() {
        // The label must be earned at insert time. If this INSERT ever wrote
        // 'pending', a later promote could stamp 'sanitized' onto text nobody
        // redacted - which is the defect this method exists to close.
        assert!(
            INSERT_SANITIZED_CHUNK_SQL.contains("'sanitized'"),
            "the redacted rewrite must be born sanitized"
        );
        assert!(
            !INSERT_SANITIZED_CHUNK_SQL.contains("'pending'"),
            "a redacted chunk is never pending"
        );
    }

    #[test]
    fn the_rewrite_removes_the_rows_whose_embedding_would_be_stale() {
        // Replacing content invalidates the embedding, so the old row must go
        // rather than be updated in place.
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("DELETE FROM kb_chunks"));
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("document_id = $3"));
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("tenant_id = $1"));
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("matter_id = $2"));
    }

    #[test]
    fn the_promote_statement_stays_within_one_document() {
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("document_id = $3"));
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("tenant_id = $1"));
        assert!(DELETE_UNSANITIZED_CHUNKS_SQL.contains("matter_id = $2"));
    }
}
