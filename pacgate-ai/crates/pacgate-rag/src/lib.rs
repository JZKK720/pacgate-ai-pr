//! pacgate-rag — Per-tenant retrieval using pgvector + tsvector.
//!
//! Dual-path retrieval:
//! 1. Semantic search via pgvector (cosine similarity on embeddings)
//! 2. Keyword search via tsvector (Postgres full-text search)
//!
//! Results are merged and ranked by combined score.
//!
//! Embeddings are generated via Ollama's `nomic-embed-text` model (768-dim).

use std::collections::HashMap;

use pacgate_core::{DataLevel, DocumentId, Jurisdiction, MatterId, SourceLevel, TenantId};
use sqlx::{PgPool, Row};
use tracing::instrument;

/// Upper bound on the total chunk text one search may return to a caller.
///
/// Measured on the live corpus 2026-11-04: chunk length min 1 / avg 564 / max
/// 6,006 chars. `top_k` alone is not a ceiling, so without this an 8-hit search
/// can inject ~48k chars into a prompt. 12,000 chars is roughly 4k CJK tokens
/// and about 8 average chunks - enough for a legal query to be grounded, small
/// enough that prefill stays inside a 65536-token window on a 16 GB card.
pub const MAX_CONTEXT_CHARS: usize = 12_000;

pub mod identity;
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
    /// The chunk's own classification. Callers must report this, not the
    /// filter ceiling: a T1 chunk returned under `max_data_level=T3` is still
    /// T1, and labelling it T3 misstates classification to the review panel.
    pub data_level: DataLevel,
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
    /// Filter by data classification level T1-T4.
    /// When set, only chunks at or below this level are returned.
    pub max_data_level: Option<DataLevel>,
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

    /// Set the maximum data classification level for results.
    /// T1 = shared templates only; T3 = templates + seeds + project files (excludes T4).
    pub fn with_max_data_level(mut self, level: DataLevel) -> Self {
        self.max_data_level = Some(level);
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

    /// The redacted rendering of one document, reassembled from `kb_chunks`.
    ///
    /// Moved here on 2026-11-09 from the `KbStore` adapter in `pacgate-api`, which
    /// was the only caller. Citation verification needs the same read, and a
    /// second copy of "which rows constitute this document's sanitised body" is
    /// the kind of duplicate that drifts: the adapter joins `content` in
    /// `chunk_index` order and returns `None` when there are no rows, and both
    /// properties are load-bearing.
    ///
    /// `None` means "no sanitised text exists". Callers must refuse in that case
    /// rather than fall back to `documents.storage_path` - serving the unredacted
    /// original is the 2026-11-03 egress leak.
    pub async fn sanitised_text(
        &self,
        tenant_id: &TenantId,
        document_id: &DocumentId,
    ) -> Result<Option<String>, RagError> {
        let rows: Vec<String> = sqlx::query_scalar(
            "SELECT content FROM kb_chunks \
             WHERE document_id = $1 AND tenant_id = $2 \
             ORDER BY chunk_index",
        )
        .bind(document_id.0)
        .bind(tenant_id.0)
        .fetch_all(&self.db)
        .await
        .map_err(|e| RagError::Database(e.to_string()))?;

        if rows.is_empty() {
            Ok(None)
        }
        else {
            Ok(Some(rows.join("")))
        }
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
        self.search_capped(tenant_id, matter_id, query, top_k, filter, MAX_CONTEXT_CHARS)
            .await
    }

    /// As [`search`], but with an explicit ceiling on the total characters of
    /// chunk text returned. See `merge_results` for why the cap exists.
    pub async fn search_capped(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        query: &str,
        top_k: u32,
        filter: &SearchFilter,
        max_chars: usize,
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
        let mut merged = self.merge_results(semantic_results, keyword_results, top_k, max_chars);

        // `ts_rank` is 0 for every matching row, so the keyword leg's weighted
        // contribution is 0 and a chunk that literally contains the query term
        // can be buried by closer, unrelated neighbours. Measured before this:
        // `sanitize` returned only 2 of 5 chunks containing the term.
        //
        // Promotion is a stable partition, applied AFTER truncation so a
        // lexically matching chunk outside top_k is not resurrected beyond the
        // caller's requested count.
        merged = promote_term_matches(merged, query);
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
            "SELECT c.content, c.page, c.data_level, d.name as doc_name,
                    (1 - (c.embedding <=> $3::vector))::float8 as score
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
                // Score is cast to ::float8 in the SQL so it is always FLOAT8.
                score: row.get::<f64, _>("score") as f32,
                source_doc: row.get("doc_name"),
                page: row.get::<Option<i32>, _>("page").map(|p| p as u32),
                data_level: DataLevel::from_code(&row.get::<String, _>("data_level"))
                    .unwrap_or(DataLevel::T4SpecialSensitive),
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
            // CJK-aware keyword search. `cjk_tsquery($3)` mirrors the exact
            // expression migration 009 indexes with, so index and query agree -
            // a mismatch here is a silent zero-result search.
            "SELECT c.content, c.page, c.data_level, d.name as doc_name,
                    ts_rank(c.content_tsv, cjk_tsquery($3)) as score
             FROM kb_chunks c
             JOIN documents d ON c.document_id = d.id
             WHERE c.tenant_id = $1 AND c.matter_id = $2
               AND c.content_tsv @@ cjk_tsquery($3)",
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
                // ts_rank returns real (FLOAT4), not FLOAT8. Decode as f32.
                score: row.get::<f32, _>("score"),
                source_doc: row.get("doc_name"),
                page: row.get::<Option<i32>, _>("page").map(|p| p as u32),
                data_level: DataLevel::from_code(&row.get::<String, _>("data_level"))
                    .unwrap_or(DataLevel::T4SpecialSensitive),
            })
            .collect())
    }

    /// Build SQL with optional jurisdiction, source_level, and data_level filter clauses.
    ///
    /// Returns `(sql_with_order_by_and_limit, jurisdiction_param, source_level_param)`.
    /// The params are `Some(String)` when the filter is active, `None` otherwise.
    /// When active, the SQL appends `AND c.jurisdiction = $N` / `AND c.source_level = $N`
    /// and inlines `AND c.data_level IN (...)` for max_data_level.
    /// Test-visible wrapper around `build_filtered_sql`.
    ///
    /// Exists so the gate can be asserted without a live Postgres. The real
    /// function stays private; this only forwards.
    #[cfg(test)]
    pub(crate) fn build_filtered_sql_for_test(
        base_sql: &str,
        filter: &SearchFilter,
        jur_param_num: &str,
        sl_param_num: &str,
    ) -> (String, Option<String>, Option<String>) {
        Self::build_filtered_sql(base_sql, filter, jur_param_num, sl_param_num)
    }

    /// Build SQL with optional jurisdiction, source_level, and data_level filter clauses.
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

        if let Some(max_level) = filter.max_data_level {
            let allowed: Vec<&str> = match max_level {
                DataLevel::T1SharedTemplate => vec!["T1"],
                DataLevel::T2RestrictedSeed => vec!["T1", "T2"],
                DataLevel::T3ProjectSpecific => vec!["T1", "T2", "T3"],
                DataLevel::T4SpecialSensitive => vec!["T1", "T2", "T3", "T4"],
            };
            let in_list = allowed
                .iter()
                .map(|code| format!("'{}'", code))
                .collect::<Vec<_>>()
                .join(", ");
            sql.push_str(&format!(" AND c.data_level IN ({})", in_list));
        }

        // ─── The sanitization gate ────────────────────────────────────────────
        // Unconditional, and deliberately a literal rather than a bind
        // parameter. Design section 5.1: the gate is a property of the
        // connection, not a request field. If it were a parameter, a caller
        // could pass any value, and a wrong one would be a silent disclosure
        // rather than an error.
        //
        // 'never' is included because it is an explicit out-of-scope marker
        // (e.g. a T1 shared template), which is a decision someone made rather
        // than a row nobody processed.
        sql.push_str(" AND c.sanitization_state IN ('sanitized', 'never')");

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
        max_chars: usize,
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

        // Cap what actually reaches the model.
        //
        // MEASURED 2026-11-04 on the live corpus: chunk length min 1 / avg 564 /
        // max 6,006 chars. `top_k` alone therefore has no ceiling - 8 hits can
        // inject ~48k chars into a prompt whose decode rate collapses as prefill
        // grows, and the local models on a 16 GB card have 65536 tokens TOTAL.
        //
        // Whole hits are kept in rank order until the budget breaks, then
        // truncated at a char boundary. Truncating is strictly better than
        // dropping: the rank-1 chunk is the one the query matched, so its head is
        // the part worth keeping. CJK characters are 3 bytes in UTF-8, so the cut
        // is made on a char boundary, never a byte index.
        let mut spent = 0usize;
        for r in results.iter_mut() {
            if spent >= max_chars {
                r.content.clear();
                continue;
            }
            let remaining = max_chars - spent;
            if r.content.chars().count() > remaining {
                r.content = r.content.chars().take(remaining).collect();
            }
            spent += r.content.chars().count();
        }
        results.retain(|r| !r.content.trim().is_empty());

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

            // Migration 004 adds the T1-T4 data_level column to kb_chunks. Without it,
            // ingest_with_data_level fails because the data_level column does not exist.
            let data_level_sql = include_str!("../../../migrations/004_data_level.sql");
            sqlx::raw_sql(data_level_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;


            // Migration 005 adds sanitization_state to kb_chunks. Without it,
            // every search gate that filters on the column errors out.
            let sanitization_sql =
                include_str!("../../../migrations/005_sanitization_state.sql");
            sqlx::raw_sql(sanitization_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            // Migration 006 adds document_spans. Without it, span persistence
            // fails and v2 pixel redaction has no coordinates to work from.
            let spans_sql = include_str!("../../../migrations/006_document_spans.sql");
            sqlx::raw_sql(spans_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            // Migration 007 adds the sanitizer job + ledger tables. Without it,
            // the job API (plan 020) has nowhere to persist the vault or the
            // redaction evidence.
            let sanitizer_sql = include_str!("../../../migrations/007_sanitizer_jobs.sql");
            sqlx::raw_sql(sanitizer_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            // Migration 008 records extraction COMPLETENESS per document version.
            // Without it, extract.rs cannot distinguish a fully-read document from
            // a partially-read one, and a document whose pages yielded no text is
            // reported as complete - which lets it be marked 'sanitized' and
            // released through the egress gate.
            let extractions_sql = include_str!("../../../migrations/008_document_extractions.sql");
            sqlx::raw_sql(extractions_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;

            // Migration 009 makes keyword search work for Chinese. Before it, the
            // tsvector used the 'english' parser, which does not segment Han text:
            // an entire sentence became ONE lexeme, so the keyword half of the
            // hybrid search matched 0 of 918 Chinese chunks. It rewrites the
            // tsvector expression and its GIN index; embeddings are untouched.
            let cjk_sql = include_str!("../../../migrations/009_cjk_fulltext.sql");
            sqlx::raw_sql(cjk_sql)
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

        tracing::info!(
            "RAG migrations applied (002_schema + 003_enrichment + 004_data_level + 005_sanitization_state + 006_document_spans + 007_sanitizer_jobs + 008_document_extractions + 009_cjk_fulltext)"
        );
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

    #[error("scope mismatch: {0}")]
    Scope(String),
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

/// Move chunks that contain a query term ahead of those that do not.
///
/// `ts_rank(content_tsv, cjk_tsquery(...))` returns 0 for every matching row, so
/// `merge_results` weights the keyword leg (0.4 x 0 = 0) below semantic
/// (0.6 x ~0.25). The leg that can actually find the query term is therefore
/// always ranked last: measured at top_k=5 on matter 4e1d30cc, `sanitize`
/// returned only 2 of 5 chunks containing the term, and `contract` 3 of 5.
///
/// This is a **stable partition**, not a re-sort: the ranking within each group
/// is preserved, so cosine order still decides among equally relevant chunks.
/// It only ensures a genuine term match is not buried under closer, unrelated
/// neighbours.
pub fn promote_term_matches(results: Vec<KbSearchResult>, query: &str) -> Vec<KbSearchResult> {
    let terms = matched_terms(query);
    if terms.is_empty() {
        return results;
    }

    let (matching, rest): (Vec<_>, Vec<_>) = results.into_iter().partition(|r| {
        let content = r.content.to_lowercase();
        terms.iter().any(|t| content.contains(t.as_str()))
    });

    if matching.is_empty() {
        return rest;
    }

    matching.into_iter().chain(rest).collect()
}

/// The tokens of `query` that are long enough to be evidence of a match.
///
/// Tokens shorter than three characters are ignored for Latin text because a
/// two-letter fragment matches nearly any English prose. CJK is compared per
/// character, since the query arrives unsegmented and the corpus stores it as
/// individual characters.
fn matched_terms(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .flat_map(|t| {
            if t.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)) {
                t.chars().map(|c| c.to_string()).collect::<Vec<_>>()
            } else {
                vec![t.to_string()]
            }
        })
        .filter(|t| {
            let n = t.chars().count();
            if t.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)) {
                n >= 1
            } else {
                n >= 3
            }
        })
        .map(|t| t.to_lowercase())
        .collect()
}

/// Whether a result set shares no term with the query, i.e. is unrelated noise.
///
/// `pgvector` has no notion of a miss: `semantic_search` returns the `top_k`
/// least-distant chunks for ANY query string, so on a populated matter the
/// result list is never empty. Measured on the live stack, a gibberish query
/// returned chunks scoring 0.621 - above 17 of 20 legitimate queries - so a
/// cosine floor cannot tell the two apart.
///
/// The lexical leg is not usable as a hard gate either: `cjk_tsquery` builds a
/// PHRASE query, and legitimate questions matched zero rows
/// (`how do I sanitize a document`, `如何脱敏文件`).
///
/// Judging the chunks actually returned is sound where both of those fail. A
/// genuine hit necessarily contains at least one query term, so this can only
/// drop neighbour noise, never a real match.
pub fn shares_no_term(results: &[KbSearchResult], query: &str) -> bool {
    if results.is_empty() {
        return false;
    }

    let terms = matched_terms(query);
    if terms.is_empty() {
        return false;
    }

    !results.iter().any(|r| {
        let content = r.content.to_lowercase();
        terms.iter().any(|t| content.contains(t.as_str()))
    })
}

#[cfg(test)]
mod gate_tests {
    use super::*;

    const BASE_SEMANTIC: &str =
        "SELECT c.id, 1 - (c.embedding <=> $3::vector) AS score FROM kb_chunks c WHERE c.tenant_id = $1 AND c.matter_id = $2";
    const BASE_KEYWORD: &str =
        "SELECT c.id, ts_rank(c.content_tsv, plainto_tsquery($3)) AS score FROM kb_chunks c WHERE c.tenant_id = $1 AND c.matter_id = $2";

    #[test]
    fn the_gate_is_present_with_an_empty_filter() {
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        assert!(
            sql.contains("c.sanitization_state = 'sanitized'")
                || sql.contains("c.sanitization_state IN ('sanitized'"),
            "the gate must apply with no filter set: {sql}"
        );
    }

    #[test]
    fn the_gate_is_present_on_the_keyword_path_too() {
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_KEYWORD, &filter, "$5", "$6");
        assert!(
            sql.contains("sanitization_state"),
            "the gate must apply on the keyword path: {sql}"
        );
    }

    #[test]
    fn the_gate_is_present_alongside_every_other_filter() {
        let filter = SearchFilter::new()
            .with_max_data_level(DataLevel::T3ProjectSpecific)
            .with_jurisdiction(Jurisdiction::ChinaMainland);
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        assert!(sql.contains("sanitization_state"), "{sql}");
        assert!(sql.contains("c.data_level IN ("), "{sql}");
    }

    #[test]
    fn the_gate_precedes_order_by_and_limit() {
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        let gate = sql.find("sanitization_state").expect("gate present");
        let order = sql.find("ORDER BY").expect("order by present");
        let limit = sql.find("LIMIT").expect("limit present");
        assert!(
            gate < order,
            "gate must be in the WHERE clause, not after ORDER BY"
        );
        assert!(order < limit, "ORDER BY must precede LIMIT");
    }

    #[test]
    fn the_gate_is_not_a_parameter() {
        // A bind placeholder would let a caller pass a different value.
        // The gate must be a literal.
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        assert!(
            !sql.contains("sanitization_state = $"),
            "the gate must not be caller-supplied: {sql}"
        );
    }
}

#[cfg(test)]
mod relevance_veto_tests {
    use super::{shares_no_term, KbSearchResult};
    use pacgate_core::DataLevel;

    fn hit(content: &str) -> KbSearchResult {
        KbSearchResult {
            content: content.to_string(),
            score: 0.3,
            source_doc: "doc".into(),
            page: None,
            data_level: DataLevel::T3ProjectSpecific,
        }
    }

    // WHY THIS EXISTS (measured 2026-11-09, live stack)
    //
    // pgvector cannot express "nothing matched": semantic_search returns the
    // top_k least-distant chunks for ANY query, so on a populated matter the
    // result list is never empty. Measured on matter 4e1d30cc, a gibberish query
    // ("zzzz 9999 xxxx") returned chunks scoring 0.621 - above 17 of 20
    // legitimate queries - so a cosine floor cannot separate noise from signal
    // (bands overlap by 0.375).
    //
    // The lexical leg also cannot be used as a hard gate: `cjk_tsquery` builds a
    // PHRASE query, and legitimate natural-language queries matched zero rows
    // ('how do I sanitize a document' -> 0, '如何脱敏文件' -> 0). Requiring a
    // lexical hit would therefore reject real questions.
    //
    // What IS sound: judge the chunks actually returned. If not one of them
    // contains a single term from the query, the result set is unrelated to the
    // query - the definition of noise. This cannot drop a real hit, because a
    // real hit necessarily contains a query term; it only drops neighbour noise.

    #[test]
    fn semantic_neighbours_sharing_no_query_term_are_noise() {
        let results = vec![
            hit("agent-meow 是一个本地语音代理，零云端依赖"),
            hit("脱敏处理 sanitize_ 接口说明"),
        ];
        assert!(
            shares_no_term(&results, "kangaroo submarine recipe"),
            "no returned chunk contains any query term, so the set is unrelated to the query"
        );
    }

    #[test]
    fn a_result_containing_a_query_term_survives() {
        let results = vec![hit("4. Once a readable contract is available, re-run this review")];
        assert!(
            !shares_no_term(&results, "contract"),
            "the chunk contains the term, so the result is a real match"
        );
    }

    #[test]
    fn a_natural_language_question_is_not_vetoed() {
        // The lexical path matched ZERO rows for this query, which is why a
        // keyword-based gate would have rejected it. The returned chunks DO
        // contain its terms, so it must survive.
        let results = vec![hit("Run pacgate_sanitize_document on the pending document, then search again")];
        assert!(
            !shares_no_term(&results, "how do I sanitize a document"),
            "common terms must count even though the phrase form matched nothing"
        );
    }

    #[test]
    fn short_and_stopword_tokens_do_not_fake_a_match() {
        // A two-letter token matches almost any English text. With no usable
        // term the check cannot judge, so it must decline to veto rather than
        // suppress a result it knows nothing about.
        let results = vec![hit("an unrelated paragraph about taxation")];
        assert!(
            !shares_no_term(&results, "zz a be"),
            "a query with no term long enough to judge must not veto results"
        );
    }

    #[test]
    fn cjk_queries_match_at_character_level() {
        let results = vec![hit("对文档进行脱敏处理后再检索")];
        assert!(
            !shares_no_term(&results, "如何脱敏文件"),
            "an unsegmented CJK query must be matched by character, not as one word"
        );
    }

    #[test]
    fn an_empty_result_set_is_not_vetoed_into_a_different_reason() {
        // Empty results are the no_documents / nothing_sanitized case, which the
        // caller distinguishes. The veto must not claim them as no_match.
        assert!(
            !shares_no_term(&[], "anything at all"),
            "an empty set is the caller's case to explain, not the veto's"
        );
    }
}

#[cfg(test)]
mod promotion_tests {
    use super::{promote_term_matches, KbSearchResult};
    use pacgate_core::DataLevel;

    fn hit(content: &str, score: f32) -> KbSearchResult {
        KbSearchResult {
            content: content.to_string(),
            score,
            source_doc: "doc".into(),
            page: None,
            data_level: DataLevel::T3ProjectSpecific,
        }
    }

    // WHY THIS EXISTS (measured 2026-11-09, live stack)
    //
    // `ts_rank(content_tsv, cjk_tsquery(...))` returns 0 for EVERY matching row,
    // so `merge_results` (semantic 0.6, keyword 0.4) gives the keyword leg a
    // weighted contribution of exactly 0. A chunk that literally contains the
    // query term therefore cannot outrank an unrelated cosine neighbour.
    //
    // Measured at top_k=5 on matter 4e1d30cc: `sanitize` returned only 2 of 5
    // chunks that contain the term, and `contract` 3 of 5. The leg that can
    // actually find the term was ranked last by construction.

    #[test]
    fn a_term_matching_chunk_outranks_a_higher_scoring_unrelated_one() {
        let results = vec![
            hit("an unrelated paragraph about taxation", 0.29),
            hit("OCR extraction runs PaddleOCR over the scan", 0.26),
        ];
        let ordered = promote_term_matches(results, "OCR");
        assert!(
            ordered[0].content.contains("OCR"),
            "the chunk containing the query term must lead, not the closer cosine neighbour"
        );
    }

    #[test]
    fn promotion_preserves_the_original_order_within_each_group() {
        let results = vec![
            hit("unrelated one", 0.31),
            hit("OCR first match", 0.28),
            hit("unrelated two", 0.30),
            hit("OCR second match", 0.26),
        ];
        let ordered = promote_term_matches(results, "OCR");
        let contents: Vec<&str> = ordered.iter().map(|r| r.content.as_str()).collect();
        assert_eq!(
            contents,
            vec!["OCR first match", "OCR second match", "unrelated one", "unrelated two"],
            "promotion must be a stable partition, not a re-sort that loses the ranking within each group"
        );
    }

    #[test]
    fn promotion_is_a_no_op_when_everything_matches() {
        let results = vec![hit("OCR one", 0.3), hit("OCR two", 0.2)];
        let ordered = promote_term_matches(results, "OCR");
        assert_eq!(ordered[0].content, "OCR one");
        assert_eq!(ordered[1].content, "OCR two");
    }

    #[test]
    fn promotion_does_not_resurrect_a_veto() {
        // If nothing matches, the order is unchanged and shares_no_term still
        // reports the set as unrelated.
        let results = vec![hit("unrelated", 0.3), hit("also unrelated", 0.2)];
        let ordered = promote_term_matches(results, "kangaroo submarine recipe");
        assert_eq!(ordered[0].content, "unrelated");
        assert!(super::shares_no_term(&ordered, "kangaroo submarine recipe"));
    }
}
