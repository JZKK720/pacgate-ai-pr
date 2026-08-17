//! pacgate-rag — Per-tenant retrieval using pgvector + tsvector.
//!
//! Dual-path retrieval:
//! 1. Semantic search via pgvector (cosine similarity on embeddings)
//! 2. Keyword search via tsvector (Postgres full-text search)
//! Results are merged and ranked by combined score.
//!
//! Embeddings are generated via Ollama's `nomic-embed-text` model (768-dim).

use std::collections::HashMap;

use pacgate_core::{Jurisdiction, MatterId, SourceLevel, TenantId};
use sqlx::{PgPool, Row};
use tracing::instrument;

pub mod embed;
pub mod ingest;

pub use embed::EmbeddingService;
pub use ingest::ChunkIngestor;

// ─────────────────────────────────────────────────────────────────────────────
// Search result
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct KbSearchResult {
    pub content: String,
    pub score: f32,
    pub source_doc: String,
    pub page: Option<u32>,
}

/// Optional filters for RAG search.
///
/// When a filter is `Some`, only chunks matching the filter are returned.
/// When `None`, no filtering is applied on that dimension.
#[derive(Debug, Clone, Default)]
pub struct SearchFilter {
    /// Filter by jurisdiction (e.g., ChinaMainland, UnitedStates)
    pub jurisdiction: Option<Jurisdiction>,
    /// Filter by source level (e.g., AuthorityVerified, AuxiliaryDB)
    pub source_level: Option<SourceLevel>,
}

impl SearchFilter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_jurisdiction(mut self, j: Jurisdiction) -> Self {
        self.jurisdiction = Some(j);
        self
    }

    pub fn with_source_level(mut self, s: SourceLevel) -> Self {
        self.source_level = Some(s);
        self
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RagStore — the main search interface
// ─────────────────────────────────────────────────────────────────────────────

pub struct RagStore {
    db: PgPool,
    embedding: EmbeddingService,
}

impl RagStore {
    pub fn new(db: PgPool, embedding: EmbeddingService) -> Self {
        Self { db, embedding }
    }

    /// Search the knowledge base for a matter using hybrid retrieval.
    ///
    /// Combines semantic (pgvector) and keyword (tsvector) search,
    /// merges results, and returns the top_k by combined score.
    ///
    /// Pass `SearchFilter::default()` for no filtering, or use
    /// `SearchFilter::new().with_jurisdiction(...)` to filter by jurisdiction
    /// and/or source level.
    #[instrument(skip(self), fields(matter_id = %matter_id.as_str(), query = %query, top_k = top_k))]
    pub async fn search(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        query: &str,
        top_k: u32,
        filter: &SearchFilter,
    ) -> Result<Vec<KbSearchResult>, RagError> {
        // Generate embedding for the query
        let query_embedding = self.embedding.embed(query).await?;

        // Semantic search via pgvector cosine similarity
        let semantic_results = self
            .semantic_search(tenant_id, matter_id, &query_embedding, top_k, filter)
            .await
            .unwrap_or_default();

        // Keyword search via tsvector
        let keyword_results = self
            .keyword_search(tenant_id, matter_id, query, top_k, filter)
            .await
            .unwrap_or_default();

        // Merge and rank by combined score
        let merged = self.merge_results(semantic_results, keyword_results, top_k);
        Ok(merged)
    }

    /// Semantic search using pgvector cosine distance.
    async fn semantic_search(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        embedding: &[f32],
        top_k: u32,
        filter: &SearchFilter,
    ) -> Result<Vec<KbSearchResult>, RagError> {
        // Convert embedding to pgvector format: "[0.1,0.2,...]"
        let embedding_str = format!(
            "[{}]",
            embedding
                .iter()
                .map(|v| v.to_string())
                .collect::<Vec<_>>()
                .join(",")
        );

        // Build query with optional jurisdiction + source_level filters
        let (sql, jur_param, sl_param) = Self::build_filtered_sql(
            "SELECT c.content, c.page, d.name as doc_name,
                    1 - (c.embedding <=> $3::vector) as score
             FROM kb_chunks c
             JOIN documents d ON c.document_id = d.id
             WHERE c.tenant_id = $1 AND c.matter_id = $2
               AND c.embedding IS NOT NULL",
            filter,
            "$5",
            "$6",
        );

        let mut query = sqlx::query(&sql)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(&embedding_str)
            .bind(top_k as i32);

        if let Some(j) = jur_param {
            query = query.bind(j);
        }
        if let Some(s) = sl_param {
            query = query.bind(s);
        }

        let rows = query.fetch_all(&self.db).await?;

        Ok(rows
            .into_iter()
            .map(|row| KbSearchResult {
                content: row.get("content"),
                score: row.get::<f64, _>("score") as f32,
                source_doc: row.get("doc_name"),
                page: row.get::<Option<i32>, _>("page").map(|p| p as u32),
            })
            .collect())
    }

    /// Keyword search using tsvector full-text search.
    async fn keyword_search(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        query: &str,
        top_k: u32,
        filter: &SearchFilter,
    ) -> Result<Vec<KbSearchResult>, RagError> {
        let (sql, jur_param, sl_param) = Self::build_filtered_sql(
            "SELECT c.content, c.page, d.name as doc_name,
                    ts_rank(c.content_tsv, plainto_tsquery('english', $3)) as score
             FROM kb_chunks c
             JOIN documents d ON c.document_id = d.id
             WHERE c.tenant_id = $1 AND c.matter_id = $2
               AND c.content_tsv @@ plainto_tsquery('english', $3)",
            filter,
            "$5",
            "$6",
        );

        let mut q = sqlx::query(&sql)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(query)
            .bind(top_k as i32);

        if let Some(j) = jur_param {
            q = q.bind(j);
        }
        if let Some(s) = sl_param {
            q = q.bind(s);
        }

        let rows = q.fetch_all(&self.db).await?;

        Ok(rows
            .into_iter()
            .map(|row| KbSearchResult {
                content: row.get("content"),
                score: row.get::<f64, _>("score") as f32,
                source_doc: row.get("doc_name"),
                page: row.get::<Option<i32>, _>("page").map(|p| p as u32),
            })
            .collect())
    }

    /// Build SQL with optional jurisdiction and source_level filter clauses.
    ///
    /// Returns `(sql_with_order_by_and_limit, jurisdiction_param, source_level_param)`.
    /// The params are `Some(String)` when the filter is active, `None` otherwise.
    /// When active, the SQL appends `AND c.jurisdiction = $N` / `AND c.source_level = $N`
    /// and the caller must bind the param in the correct position.
    fn build_filtered_sql(
        base_sql: &str,
        filter: &SearchFilter,
        jur_param_num: &str,
        sl_param_num: &str,
    ) -> (String, Option<String>, Option<String>) {
        let mut sql = base_sql.to_string();
        let mut jur_param: Option<String> = None;
        let mut sl_param: Option<String> = None;

        if let Some(ref j) = filter.jurisdiction {
            let j_str = serde_json::to_value(j)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_default();
            sql.push_str(&format!(" AND c.jurisdiction = {}", jur_param_num));
            jur_param = Some(j_str);
        }

        if let Some(ref s) = filter.source_level {
            let s_str = serde_json::to_value(s)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_default();
            sql.push_str(&format!(" AND c.source_level = {}", sl_param_num));
            sl_param = Some(s_str);
        }

        sql.push_str(" ORDER BY ");
        // For semantic search, order by embedding distance; for keyword, by score
        // We need to detect which query this is. The simplest approach: if the base
        // SQL contains "embedding <=>", order by that; otherwise by score DESC.
        if base_sql.contains("embedding <=>") {
            sql.push_str("c.embedding <=> $3::vector");
        } else {
            sql.push_str("score DESC");
        }
        sql.push_str(" LIMIT $4");

        (sql, jur_param, sl_param)
    }

    /// Merge semantic and keyword results, combining scores for duplicates.
    fn merge_results(
        &self,
        semantic: Vec<KbSearchResult>,
        keyword: Vec<KbSearchResult>,
        top_k: u32,
    ) -> Vec<KbSearchResult> {
        // Use content hash as key for deduplication
        let mut merged: HashMap<String, KbSearchResult> = HashMap::new();

        // Semantic results get weight 0.6
        for result in semantic {
            let key = result.content.clone();
            merged
                .entry(key)
                .and_modify(|existing| {
                    existing.score += result.score * 0.6;
                })
                .or_insert_with(|| KbSearchResult {
                    score: result.score * 0.6,
                    ..result
                });
        }

        // Keyword results get weight 0.4
        for result in keyword {
            let key = result.content.clone();
            merged
                .entry(key)
                .and_modify(|existing| {
                    existing.score += result.score * 0.4;
                })
                .or_insert_with(|| KbSearchResult {
                    score: result.score * 0.4,
                    ..result
                });
        }

        // Sort by combined score, take top_k
        let mut results: Vec<KbSearchResult> = merged.into_values().collect();
        results.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        results.truncate(top_k as usize);
        results
    }

    /// Run RAG migrations.
    pub async fn run_migrations(pool: &PgPool) -> Result<(), RagError> {
        const MIGRATION_LOCK_KEY: i64 = 4_243_001;

        let mut conn = pool
            .acquire()
            .await
            .map_err(|e| RagError::Migration(e.to_string()))?;

        sqlx::query("SELECT pg_advisory_lock($1)")
            .bind(MIGRATION_LOCK_KEY)
            .fetch_optional(&mut *conn)
            .await
            .map_err(|e| RagError::Migration(e.to_string()))?;

        let migration_sql = include_str!("../../../migrations/002_rag_schema.sql");
        let result = async {
            sqlx::raw_sql(migration_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            let enrichment_sql = include_str!("../../../migrations/003_rag_enrichment.sql");
            sqlx::raw_sql(enrichment_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            Ok::<(), RagError>(())
        }
        .await;

        let _unlock_result = sqlx::query("SELECT pg_advisory_unlock($1)")
            .bind(MIGRATION_LOCK_KEY)
            .fetch_optional(&mut *conn)
            .await
            .map_err(|e| RagError::Migration(e.to_string()))?;

        result?;

        tracing::info!("RAG migrations applied (002_schema + 003_enrichment)");
        Ok(())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error type
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum RagError {
    #[error("embedding error: {0}")]
    Embedding(String),

    #[error("database error: {0}")]
    Database(String),

    #[error("migration error: {0}")]
    Migration(String),

    #[error("chunking error: {0}")]
    Chunking(String),
}

impl From<sqlx::Error> for RagError {
    fn from(e: sqlx::Error) -> Self {
        RagError::Database(e.to_string())
    }
}

impl From<pacgate_core::PacgateError> for RagError {
    fn from(e: pacgate_core::PacgateError) -> Self {
        RagError::Database(e.to_string())
    }
}
