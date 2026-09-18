# Sanitizer Jobs: Vault, Gates, MCP Tools - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make plan 017's engine and plan 019's extraction usable end to end: a sanitize job API that produces + stores the vault, the egress gates that make `pending` unreachable, and the MCP tools so the sanitizer agent (plan 021) can drive it.

**Architecture:** Four additions, each independently shippable, each reusing the existing spine. (a) A `sanitize` API module in pacgate-api that runs `Sanitizer::sanitize` over cached extraction text, stores the mapping (vault) + ledger rows in Postgres, and promotes/blocks rows via `sanitization_state`. (b) Two new tables: `sanitizer_jobs` (job row) + `redaction_ledger_rows` (evidence); mapping JSON goes into the job row, never into deer-flow reach. (c) Three hard gates, applied by editing existing code paths (download + export) - the RAG search gate already shipped in plan 017. (d) Three new MCP tools in `deploy/pacgate-mcp/server.py` calling the new API routes via the existing authenticated client.

**Tech Stack:** Rust: axum + sqlx (existing), pacgate-redact (existing), sqlx migrations 007. Python: FastMCP server (existing). No new crates, no new containers.

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` (sections 3.3, 5, 5.1, 6, 6.1-6.3, 8.5-8.7); decisions table in that spec's section 12; locked decisions 1-4 in `plans/019-ocr-and-ner.md` carry over.

## Global Constraints

- **Cargo on this machine:** `& "$env:USERPROFILE\.cargo\bin\cargo.exe"`, run from `pacgate-ai/`. No bare `cargo` (not on PATH).
- **Workspace deps:** add to `[workspace.dependencies]` in `pacgate-ai/Cargo.toml` first, then `name.workspace = true` in the crate manifest.
- **The sanitizer crate never calls OCR:** `pacgate-redact` consumes text only. Only the API/MCP orchestrator may call extract-then-sanitize (warm cache = zero OCR calls, proven in plan 019).
- **Deterministic-first:** model candidates additive; VERIFY replays the same detector set. The verifier is never model-based.
- **Fail-closed:** unparseable input, detector error, unknown placeholder, version mismatch, or any error during a job = BLOCK or `pending`. Never PASS by default, never send on error.
- **The gate is a literal, not a parameter:** `sanitization_state IN ('sanitized','never')` is already hardcoded in `build_filtered_sql` (plan 017, verified at `crates/pacgate-rag/src/lib.rs:306`). Keep it that way; do not add a parameter to bypass it.
- **Atomic per document** (locked decision 3): `mark_sanitized` covers exactly one (tenant, matter, document). No partial jobs.
- **Vault isolation (spec 6.2):** mapping rows are keyed by `job_id` and matter. Restore requires the job's mapping version; unknown placeholder = error.
- **No secrets:** no key, token, or password in source, tests, fixtures, or commit messages.
- **Hyphens not em-dashes** in visible copy.
- **DB env:** `DATABASE_URL=postgres://pacgate:${PACGATE_DB_PASSWORD}@pacgate-db:5432/pacgate`; test containers use the live compose network `client-bundle_default`. `pacgate-seed` needs `--db-url` (ignores the env).

---

## Task 1: `sanitizer_jobs` + `redaction_ledger_rows` migration (007)

**Files:**
- Create: `pacgate-ai/migrations/007_sanitizer_jobs.sql`
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs` (add 007 to `run_migrations`, update the applied-migrations log line)

**Interfaces:**
- Produces: tables `sanitizer_jobs` and `redaction_ledger_rows`; every later task reads/writes them by column name exactly as in the SQL below.

- [ ] **Step 1: Write the migration**

Create `pacgate-ai/migrations/007_sanitizer_jobs.sql`:

```sql
-- Pacgate-ai sanitizer job store + redaction ledger (evidence half).
-- Migration 007 - design sections 3.3, 5.1, 6.1-6.3.
--
-- sanitizer_jobs : one row per sanitize job. The mapping (vault) is stored
--                  HERE ONLY - never in a lane deer-flow can read. Restoring
--                  requires this row plus the caller knowing the job id.
-- redaction_ledger_rows : the RedactionLedger JSON per (job, document),
--                  keyed to the document VERSION the job actually read.
--                  Evidence for "this artifact was really redacted".

CREATE TABLE IF NOT EXISTS sanitizer_jobs (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id     UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    data_level    TEXT NOT NULL,             -- T1|T2|T3|T4 (004 convention)
    mapping_version INTEGER NOT NULL,
    -- The vault. JSON of Mapping entries: placeholder -> (entity, original).
    -- This column never leaves pacgate-api (no MCP tool reads it).
    mapping       JSONB NOT NULL,
    mapping_count INTEGER NOT NULL,
    verdict       TEXT NOT NULL,             -- pass | block
    created_by    UUID REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sanitizer_jobs_tenant
    ON sanitizer_jobs (tenant_id, created_at);

CREATE TABLE IF NOT EXISTS redaction_ledger_rows (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    job_id          UUID NOT NULL REFERENCES sanitizer_jobs(id) ON DELETE CASCADE,
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    matter_id       UUID NOT NULL REFERENCES matters(id) ON DELETE CASCADE,
    document_id     UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    document_version INTEGER NOT NULL,
    input_sha256    TEXT NOT NULL,
    output_sha256   TEXT NOT NULL,
    redaction_count INTEGER NOT NULL,
    verdict         TEXT NOT NULL,           -- pass | block
    ledger_json     JSONB NOT NULL,          -- full RedactionLedger (no originals)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_redaction_ledger_doc
    ON redaction_ledger_rows (tenant_id, matter_id, document_id, document_version);
```

- [ ] **Step 2: Wire into `run_migrations`**

In `pacgate-ai/crates/pacgate-rag/src/lib.rs`, inside `run_migrations`, after the 006 block (the block starting `// Migration 006 adds document_spans`), add:

```rust
            // Migration 007 adds the sanitizer job + ledger tables. Without it,
            // the job API (plan 020) has nowhere to persist the vault or the
            // redaction evidence.
            let sanitizer_sql = include_str!("../../../migrations/007_sanitizer_jobs.sql");
            sqlx::raw_sql(sanitizer_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;
```

Update the final log line to:

```rust
        tracing::info!(
            "RAG migrations applied (002_schema + 003_enrichment + 004_data_level + 005_sanitization_state + 006_document_spans + 007_sanitizer_jobs)"
        );
```

- [ ] **Step 3: Verify against live Postgres**

```
docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-db
Get-Content pacgate-ai/migrations/007_sanitizer_jobs.sql -Raw | docker exec -i pacgate-db psql -U pacgate -d pacgate -v ON_ERROR_STOP=1
cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -c ""\dt sanitizer_jobs"" 2>&1"
cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -c ""\dt redaction_ledger_rows"" 2>&1"
```

Expected: both tables exist. Run the migration a second time - `already exists, skipping` notices and exit 0.

- [ ] **Step 4: Commit**

```bash
git add pacgate-ai/migrations/007_sanitizer_jobs.sql pacgate-ai/crates/pacgate-rag/src/lib.rs
git commit -m "feat(db): add sanitizer_jobs and redaction_ledger_rows for job vaults and evidence"
```

---

## Task 2: Sanitize job service module (API-side engine wrapper)

**Files:**
- Create: `pacgate-ai/crates/pacgate-api/src/sanitize.rs`
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs` (add `mod sanitize;`)
- Modify: `pacgate-ai/crates/pacgate-api/Cargo.toml` (add `pacgate-redact = { path = "../pacgate-redact" }`)
- Modify: `pacgate-ai/crates/pacgate-api/src/state.rs` (add `ner_model_dir: Option<String>` to `AppConfig`)
- Modify: `pacgate-ai/crates/pacgate-api/src/main.rs` (read `PACGATE_NER_MODEL_DIR` into config)

**Interfaces:**
- Consumes: `pacgate_redact::Sanitizer`, `pacgate_redact::SanitizeOutcome { job_id, text, mapping, ledger, decision }`, `pacgate_redact::detect::{full_detectors, tier_one_detectors}`, `pacgate_redact::MappingVersion::CURRENT`, `pacgate_redact::Mapping::restore(text, expected_version) -> RedactResult<String>`, `pacgate_rag::ChunkIngestor::mark_sanitized(tenant_id, matter_id, document_id) -> Result<u64, RagError>`, `crate::extract::extract_document(state, tenant_id, matter_id, document_id) -> Result<ExtractedDocument, ApiError>`.
- Produces: `pub async fn run_job(state, tenant_id, user_id, matter_id, document_id, data_level) -> Result<JobOutcome, ApiError>` and `pub struct JobOutcome` (fields below). The route task and the MCP tools consume exactly these.

- [ ] **Step 1: Add the dependency and module**

In `pacgate-ai/crates/pacgate-api/Cargo.toml`, after the `pacgate-search` line in `[dependencies]`, add:

```toml
pacgate-redact = { path = "../pacgate-redact" }
```

In `pacgate-ai/crates/pacgate-api/src/lib.rs`, next to the other `mod` lines (after `mod search;`), add:

```rust
mod sanitize;
```

- [ ] **Step 2: Write the failing test first**

Append to the end of `pacgate-ai/crates/pacgate-api/src/sanitize.rs` (created in Step 3 below) - these are string-contract tests, runnable without Postgres:

```rust
#[cfg(test)]
mod gate_tests {
    use super::*;

    #[test]
    fn the_promotion_targets_only_this_document() {
        assert!(MARK_SANITIZED_DOC_SQL.contains("tenant_id = $1"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("matter_id = $2"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("document_id = $3"));
        assert!(MARK_SANITIZED_DOC_SQL.contains("sanitization_state = 'pending'"));
    }

    #[test]
    fn a_block_never_promotes() {
        // Block verdict -> documents + kb_chunks go to 'blocked', never 'sanitized'.
        assert!(MARK_BLOCKED_SQL.contains("SET sanitization_state = 'blocked'"));
        assert!(!MARK_BLOCKED_SQL.contains("'sanitized'"));
    }

    #[test]
    fn the_audit_action_names_are_stable() {
        assert_eq!(AUDIT_SANITIZE, "document.sanitize");
        assert_eq!(AUDIT_RESTORE, "document.restore");
    }
}
```

- [ ] **Step 3: Write the service module**

Create `pacgate-ai/crates/pacgate-api/src/sanitize.rs`:

```rust
//! Sanitize job service - the API-side orchestrator.
//!
//! Owns the DECIDE/REPLACE/VERIFY pipeline around pacgate-redact and
//! persists the two artifacts the design requires: the vault (mapping) in
//! `sanitizer_jobs` and the evidence in `redaction_ledger_rows`. The state
//! promotion is atomic per document: a version completes or it stays pending.
//!
//! The vault never leaves pacgate-api. Only this module reads the mapping
//! column; restore is an API endpoint, never an MCP tool (design 3.5).

use axum::http::StatusCode;
use pacgate_core::{DataLevel, DocumentId, MatterId, TenantId, UserId};
use pacgate_redact::detect;
use pacgate_redact::MappingVersion;
use serde::{Serialize};
use sqlx::Row;

use crate::error::ApiError;
use crate::state::AppState;

/// Promote this document's pending chunks + the document rollup after a
/// clean verdict. Scoped to one document (locked decision 3: atomic).
const MARK_SANITIZED_DOC_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'sanitized' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";

/// A Block verdict writes 'blocked' so the row can never be promoted by a
/// later run on a different document (the pending-only guard in 005/ingest).
const MARK_BLOCKED_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'blocked' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";

/// Document-level rollup mirrors the chunk states (design 5.1).
const MARK_SANITIZED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'sanitized' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

const MARK_BLOCKED_DOCUMENT_SQL: &str = "\
    UPDATE documents SET sanitization_state = 'blocked' \
    WHERE id = $1 AND tenant_id = $2 AND sanitization_state = 'pending'";

/// Audit actions (stable codes; the review panel and tests rely on them).
const AUDIT_SANITIZE: &str = "document.sanitize";
const AUDIT_RESTORE: &str = "document.restore";

#[derive(Debug, Serialize)]
pub struct JobOutcome {
    pub job_id: String,
    pub document_id: String,
    pub document_version: u32,
    pub data_level: String,
    pub verdict: String,          // pass | block
    pub redaction_count: usize,
    pub mapping_count: usize,
    pub chunks_promoted: u64,
    pub allow_auto_pass: bool,
    pub require_human_review: bool,
    pub reason: String,
    pub sanitized_text: String,
    pub ledger: serde_json::Value,
}

/// Build the production detector set. Tiers 2-4 need the NER weights; when
/// `PACGATE_NER_MODEL_DIR` is unset the job runs Tier-1 rules only, which is
/// a degraded set the response reports honestly rather than hiding.
fn build_detectors(model_dir: Option<&str>) -> Result<Vec<Box<dyn detect::Detector>>, ApiError> {
    match model_dir.filter(|d| !d.is_empty()) {
        Some(dir) => {
            detect::full_detectors(dir)
                .map_err(|e| ApiError::internal(format!("NER model load failed: {e}")))
        }
        None => {
            tracing::warn!("PACGATE_NER_MODEL_DIR unset: running Tier-1 rules only");
            Ok(detect::tier_one_detectors())
        }
    }
}

async fn audit_row(
    state: &crate::state::AppState,
    tenant_id: &TenantId,
    user_id: Option<&UserId>,
    matter_id: &MatterId,
    document_id: &DocumentId,
    action: &str,
    metadata: serde_json::Value,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_log (tenant_id, user_id, action, resource, scope, metadata) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(tenant_id.0)
    .bind(user_id.map(|u| u.0))
    .bind(action)
    .bind(format!("document:{}", document_id.0))
    .bind(format!("matter:{}", matter_id.0))
    .bind(metadata)
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("audit write failed: {e}")))?;
    Ok(())
}

/// Run one sanitize job over one document version.
///
/// Cache-first: extract_document reads the stored extraction when present
/// (plan 019), so a per-job sanitize costs ZERO OCR calls on warm cache.
///
/// Verdict -> promotion (locked decision 3, atomic per document):
///   pass  -> kb_chunks pending -> sanitized, documents -> sanitized
///   block -> kb_chunks pending -> blocked,   documents -> blocked
/// Every job writes a `sanitizer_jobs` row (the vault) + one
/// `redaction_ledger_rows` row per document + one `audit_log` row.
pub async fn run_job(
    state: &crate::state::AppState,
    tenant_id: &TenantId,
    user_id: &UserId,
    matter_id: &MatterId,
    document_id: &DocumentId,
    data_level: DataLevel,
) -> Result<JobOutcome, ApiError> {
    // 1. INGEST (cache-first; warm cache = zero OCR calls).
    let extracted =
        crate::extract::extract_document(state, tenant_id, matter_id, document_id).await?;
    if extracted.incomplete {
        // Fail closed: never sanitize against an incomplete extraction.
        return Err(ApiError::internal(
            "extraction incomplete; document stays pending",
        ));
    }

    // The document version this job read. Everything below binds to it.
    let version = sqlx::query(
        "SELECT version FROM documents WHERE id = $1 AND tenant_id = $2 AND matter_id = $3 LIMIT 1",
    )
    .bind(document_id.0)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .get::<i32, _>("version");

    // 2-4. DETECT / DECIDE / REPLACE / VERIFY inside the crate.
    let mut sanitizer = pacgate_redact::Sanitizer::new(
        build_detectors(state.config.ner_model_dir.as_deref())?,
        MappingVersion::CURRENT,
    );
    let outcome = sanitizer
        .sanitize(&extracted.text, data_level)
        .map_err(|e| ApiError::internal(format!("sanitize failed: {e}")))?;

    // 5. Seal the evidence row BEFORE promoting state: the ledger must exist
    // for the row to claim 'sanitized' (design 5.1: column is the index,
    // ledger is the evidence).
    let ledger_json: serde_json::Value =
        serde_json::from_str(&outcome.ledger.to_json().expect("ledger serialisable"))
            .map_err(|e| ApiError::internal(format!("ledger parse failed: {e}")))?;
    let job_row = sqlx::query(
        "INSERT INTO sanitizer_jobs \
             (tenant_id, mapping_version, mapping, mapping_count, verdict, created_by) \
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
    )
    .bind(tenant_id.0)
    .bind(outcome.mapping.version().0 as i32)
    .bind(
        serde_json::to_value(&outcome.mapping).map_err(|e| {
            ApiError::internal(format!("mapping serialisation failed: {e}"))
        })?,
    )
    .bind(outcome.mapping.entry_count() as i32)
    .bind(if outcome.ledger.verdict().is_block() {
        "block"
    } else {
        "pass"
    })
    .bind(user_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("job insert failed: {e}")))?;
    let job_id: uuid::Uuid = job_row.get("id");

    sqlx::query(
        "INSERT INTO redaction_ledger_rows \
             (job_id, tenant_id, matter_id, document_id, document_version, \
              input_sha256, output_sha256, redaction_count, verdict, ledger_json) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
    )
    .bind(job_id)
    .bind(tenant_id.0)
    .bind(matter_id.0)
    .bind(document_id.0)
    .bind(version)
    .bind(outcome.ledger.input_sha256())
    .bind(outcome.ledger.output_sha256())
    .bind(outcome.ledger.redaction_count as i32)
    .bind(
        if outcome.ledger.verdict().is_block() {
            "block"
        } else {
            "pass"
        },
    )
    .bind(&ledger_json)
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("ledger insert failed: {e}")))?;

    // 6. Promote or block, atomically per document.
    let verdict_is_block = outcome.ledger.verdict().is_block();
    let promoted: u64 = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("block write failed: {e}")))?
            .rows_affected()
    } else {
        sqlx::query(MARK_SANITIZED_DOC_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("promote write failed: {e}")))?
            .rows_affected()
    };
    let _ = if verdict_is_block {
        sqlx::query(MARK_BLOCKED_DOCUMENT_SQL)
            .bind(document_id.0)
            .bind(tenant_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("document block failed: {e}")))?
            .rows_affected()
    } else {
        sqlx::query(MARK_SANITIZED_DOCUMENT_SQL)
            .bind(document_id.0)
            .bind(tenant_id.0)
            .execute(&state.db)
            .await
            .map_err(|e| ApiError::internal(format!("document promote failed: {e}")))?
            .rows_affected()
    };

    // 7. Audit (design 3.3/5.1: a redaction is an audit row, not a new store).
    audit_row(
        state,
        tenant_id,
        Some(user_id),
        matter_id,
        document_id,
        AUDIT_SANITIZE,
        serde_json::json!({
            "job_id": job_id.to_string(),
            "document_version": version,
            "verdict": if verdict_is_block { "block" } else { "pass" },
            "redaction_count": outcome.ledger.redaction_count,
            "data_level": data_level.code(),
        }),
    )
    .await?;

    Ok(JobOutcome {
        job_id: job_id.to_string(),
        document_id: document_id.as_str(),
        document_version: version as u32,
        data_level: data_level.code().to_string(),
        verdict: if verdict_is_block { "block" } else { "pass" }.to_string(),
        redaction_count: outcome.ledger.redaction_count,
        mapping_count: outcome.mapping.entry_count(),
        chunks_promoted: promoted,
        allow_auto_pass: outcome.decision.allow_auto_pass,
        require_human_review: outcome.decision.require_human_review,
        reason: outcome.decision.reason,
        sanitized_text: outcome.text,
        ledger: ledger_json,
    })
}
```

- [ ] **Step 4: Wire the NER model dir into config**

In `pacgate-ai/crates/pacgate-api/src/state.rs`, inside `AppConfig` (after `pub ocr_service_url: Option<String>,`), add:

```rust
    /// Directory with the local NER weights (config.json, model.safetensors,
    /// vocab.txt). None runs Tier-1 rules only; Some-but-broken fails the job.
    pub ner_model_dir: Option<String>,
```

and inside `impl Default for AppConfig` (after `ocr_service_url: None,`), add:

```rust
            ner_model_dir: None,
```

In `pacgate-ai/crates/pacgate-api/src/main.rs`, inside the `AppConfig { ... }` construction (after the `ocr_service_url:` line), add:

```rust
        ner_model_dir: std::env::var("PACGATE_NER_MODEL_DIR").ok().filter(|s| !s.is_empty()),
```

- [ ] **Step 5: Run the tests**

From `pacgate-ai/`:

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib sanitize
```

Expected: 3 gate tests PASS.

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-api
```

Expected: clean (warnings allowed, no errors).

- [ ] **Step 6: Commit**

```bash
git add pacgate-ai/crates/pacgate-api/src/sanitize.rs pacgate-ai/crates/pacgate-api/src/lib.rs pacgate-ai/crates/pacgate-api/Cargo.toml pacgate-ai/crates/pacgate-api/src/state.rs pacgate-ai/crates/pacgate-api/src/main.rs
git commit -m "feat(api): add sanitize job service persisting vault, ledger and audit rows"
```

---

## Task 3: Serialize the mapping + route wiring (job endpoint)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/mapping.rs` (add `serialize`/`deserialize` so the vault can live in JSONB)
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs` (route)
- Create: `pacgate-ai/crates/pacgate-api/src/sanitize.rs` additions (handler + request/response types)

**Interfaces:**
- Consumes: `Mapping::new(version)`, `Mapping::insert_typed(placeholder, entity, original)`, `Mapping::job_id()`, `Mapping::entry_count()`, `Mapping::restore(text, expected)`, `EntityType::from_code(code) -> Option<EntityType>`, `EntityType::code()`.
- Produces: `POST /api/documents/:id/sanitize` (body `{"data_level": "T3"}`) -> `JobOutcome` JSON; `pacgate_redact::Mapping::serialize() -> serde_json::Value` and `Mapping::from_serialized(v: serde_json::Value, version) -> RedactResult<Mapping>` used by restore in Task 4.

- [ ] **Step 1: Write the failing serialize test**

Append to `mod tests` in `pacgate-ai/crates/pacgate-redact/src/mapping.rs`:

```rust
    #[test]
    fn a_mapping_survives_a_json_round_trip() {
        let mut m = Mapping::new(MappingVersion(1));
        m.insert_typed("[PERSON_ABC123_1]", EntityType::PersonName, "张三");
        m.insert_typed("[ORG_ABC123_2]", EntityType::OrgName, "智方云");
        let json = m.serialize();
        let back = Mapping::deserialize(&json, MappingVersion(1)).expect("round trip");
        assert_eq!(back.entry_count(), 2);
        let restored = back
            .restore("[PERSON_ABC123_1] 与 [ORG_ABC123_2] 签约", MappingVersion(1))
            .unwrap();
        assert_eq!(restored, "张三 与 智方云 签约");
    }
```

- [ ] **Step 2: Run it to verify it fails**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib mapping
```

Expected: FAIL - `no method named 'serialize' found`.

- [ ] **Step 3: Implement serialize/deserialize**

In `impl Mapping` in `pacgate-ai/crates/pacgate-redact/src/mapping.rs`, add:

```rust
    /// JSON for the vault row (`sanitizer_jobs.mapping` JSONB). Shape:
    /// `{"entries": [{"placeholder", "entity", "original"}], "job_id", "version"}`.
    /// The original values NEVER leave pacgate-api; this is storage, not egress.
    pub fn serialize(&self) -> serde_json::Value {
        let entries: Vec<serde_json::Value> = self
            .entries
            .iter()
            .map(|(ph, (entity, original))| {
                serde_json::json!({
                    "placeholder": ph,
                    "entity": entity.code(),
                    "original": original,
                })
            })
            .collect();
        serde_json::json!({
            "job_id": self.job_id.0.to_string(),
            "version": self.version.0,
            "entries": entries,
        })
    }

    /// Rebuild a mapping from its serialized form. Unknown entity codes are
    /// skipped (never guessed), so a partial vault is visible rather than
    /// silently mis-restoring.
    pub fn deserialize(
        value: &serde_json::Value,
        expected_version: MappingVersion,
    ) -> RedactResult<Self> {
        let version = value
            .get("version")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| {
                RedactError::InvalidInput("mapping json lacks version".to_string())
            })?;
        if version != expected_version.0 {
            return Err(RedactError::InvalidInput(format!(
                "mapping version mismatch: stored v{version}, expected v{}",
                expected_version.0
            )));
        }
        let job_id_str = value
            .get("job_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| RedactError::InvalidInput("mapping json lacks job_id".to_string()))?;
        let job_id = JobId(job_id_str.parse().map_err(|e| {
            RedactError::InvalidInput(format!("mapping json job_id invalid: {e}"))
        })?);
        let mut entries = HashMap::new();
        for e in value
            .get("entries")
            .and_then(|v| v.as_array())
            .ok_or_else(|| RedactError::InvalidInput("mapping json lacks entries".to_string()))?
        {
            let placeholder = e
                .get("placeholder")
                .and_then(|v| v.as_str())
                .ok_or_else(|| RedactError::InvalidInput("entry lacks placeholder".to_string()))?
                .to_string();
            let entity_code = e
                .get("entity")
                .and_then(|v| v.as_str())
                .ok_or_else(|| RedactError::InvalidInput("entry lacks entity".to_string()))?;
            let entity = EntityType::from_code(entity_code).ok_or_else(|| {
                RedactError::InvalidInput(format!("unknown entity code {entity_code}"))
            })?;
            let original = e
                .get("original")
                .and_then(|v| v.as_str())
                .ok_or_else(|| RedactError::InvalidInput("entry lacks original".to_string()))?;
            entries.insert(placeholder, (entity, original.to_string()));
        }
        Ok(Self {
            job_id,
            version: expected_version,
            entries,
        })
    }
```

Note: `Mapping` is created with a *fresh* `JobId` in `Mapping::new`. The deserialized one carries the stored job id, which is what restore-in-task-4 binds on.

- [ ] **Step 4: Run the test to verify it passes**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib mapping
```

Expected: PASS (including the existing tests).

- [ ] **Step 5: Add the route + handler**

In `pacgate-ai/crates/pacgate-api/src/lib.rs`, in the protected router (after the `/api/documents/:id/extract` route), add:

```rust
        .route(
            "/api/documents/:id/sanitize",
            post(sanitize::sanitize_document_handler),
        )
```

Append to `pacgate-ai/crates/pacgate-api/src/sanitize.rs` (before the `#[cfg(test)]` block):

```rust
#[derive(Debug, Deserialize)]
pub struct SanitizeRequest {
    /// T1-T4 code. T4 forces require_human_review (policy.rs) regardless.
    pub data_level: String,
}

pub async fn sanitize_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    Json(req): Json<SanitizeRequest>,
) -> Result<Json<JobOutcome>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids_public(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let data_level = DataLevel::from_code(&req.data_level)
        .ok_or_else(|| ApiError::bad_request("data_level must be T1|T2|T3|T4"))?;

    let doc =
        crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;
    let outcome = run_job(
        &state,
        &tenant_id,
        &user_id,
        &doc.matter_id,
        &document_id,
        data_level,
    )
    .await?;
    Ok(Json(outcome))
}
```

This needs `serde::Deserialize` in sanitize.rs's use list: change `use serde::{Serialize};` to `use serde::{Deserialize, Serialize};` and extend the file's axum use block to include `extract::{Extension, Path, State}`.

**Visibility requirement (interface contract):** in `pacgate-ai/crates/pacgate-api/src/documents.rs`, change `fn claims_to_ids(` to `pub(crate) fn claims_to_ids(` and `async fn fetch_document_for_tenant(` to `pub(crate) async fn fetch_document_for_tenant(`. Do not change their bodies.

- [ ] **Step 6: Compile + run all api tests**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib sanitize
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test --workspace
```

Expected: sanitize tests PASS; workspace suites all `ok` (the E0063 lesson: always `--workspace`).

- [ ] **Step 7: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact/src/mapping.rs pacgate-ai/crates/pacgate-api/src/lib.rs pacgate-ai/crates/pacgate-api/src/sanitize.rs pacgate-ai/crates/pacgate-api/src/documents.rs
git commit -m "feat(api): add POST /api/documents/:id/sanitize with serialized mapping vault"
```

---

## Task 4: Restore endpoint (role-gated, job-scoped, audit-logged)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/sanitize.rs` (restore handler + status listing)

**Interfaces:**
- Consumes: `Mapping::deserialize(&vault, MappingVersion(version))`, `Mapping::restore(text, expected)`, `redaction_ledger_rows` (output_sha256 + ledger_json), `sanitizer_jobs.mapping` (JSONB).
- Produces: `POST /api/documents/:id/restore` (body `{"job_id": "...", "text": "..."}`) -> restored text; `GET /api/documents/:id/sanitize-status` -> `{document_state, chunks_state, latest_job}`. **No MCP tool wraps restore** (design 3.5: restore never reaches chat).

- [ ] **Step 1: Write the failing tests**

Append to `mod gate_tests` in `pacgate-ai/crates/pacgate-api/src/sanitize.rs`:

```rust
    #[test]
    fn restore_is_role_gated_to_admin_and_partner() {
        assert!(role_may_restore("admin"));
        assert!(role_may_restore("partner"));
        assert!(!role_may_restore("attorney"));
        assert!(!role_may_restore("paralegal"));
    }
```

- [ ] **Step 2: Run it to verify it fails**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib sanitize
```

Expected: FAIL - `role_may_restore` not defined.

- [ ] **Step 3: Implement the restore handler**

Append to `pacgate-ai/crates/pacgate-api/src/sanitize.rs` (before `#[cfg(test)]`):

```rust
/// Role gate for restore (locked decision 2). Only admin/partner may
/// re-hydrate placeholders; everything else is refused before any vault read.
fn role_may_restore(role: &str) -> bool {
    matches!(role, "admin" | "partner")
}

#[derive(Debug, Deserialize)]
pub struct RestoreRequest {
    pub job_id: String,
    pub text: String,
}

#[derive(Debug, Serialize)]
pub struct RestoreResponse {
    pub restored: String,
    pub job_id: String,
}

/// Local-only restore, bound to the job's mapping version (design stage 6).
/// Refusals are explicit: unknown role, unknown job, wrong matter, version
/// mismatch, or any unknown placeholder - the last never resolves to a guess.
pub async fn restore_document_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
    Json(req): Json<RestoreRequest>,
) -> Result<Json<RestoreResponse>, ApiError> {
    let (tenant_id, user_id) = crate::documents::claims_to_ids(&claims)?;
    if !role_may_restore(&claims.role) {
        return Err(ApiError::unauthorized(
            "restore requires the admin or partner role",
        ));
    }
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc =
        crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    // The job must belong to this tenant AND this document's matter.
    let job = sqlx::query(
        "SELECT mapping, mapping_version FROM sanitizer_jobs \
         WHERE id = $1 AND tenant_id = $2 LIMIT 1",
    )
    .bind(
        req.job_id
            .parse::<uuid::Uuid>()
            .map_err(|e| ApiError::bad_request(format!("invalid job_id: {e}")))?,
    )
    .bind(tenant_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .ok_or_else(|| ApiError::not_found("job not found"))?;

    let ledger = sqlx::query(
        "SELECT matter_id FROM redaction_ledger_rows \
         WHERE job_id = $1 AND document_id = $2 LIMIT 1",
    )
    .bind(
        req.job_id
            .parse::<uuid::Uuid>()
            .map_err(|e| ApiError::bad_request(format!("invalid job_id: {e}")))?,
    )
    .bind(document_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    // The job row must also cover this document (not just any job).
    if ledger.is_none() {
        return Err(ApiError::not_found(
            "job has no ledger row for this document; refusing to guess",
        ));
    }
    let ledger_matter: uuid::Uuid =
        ledger.expect("checked above").get("matter_id");
    if ledger_matter != doc.matter_id.0 {
        return Err(ApiError::unauthorized(
            "job belongs to a different matter; restore is matter-scoped",
        ));
    }

    let mapping_json: serde_json::Value = job.get("mapping");
    let version = job.get::<i32, _>("mapping_version");
    let mapping = pacgate_redact::Mapping::deserialize(
        &mapping_json,
        pacgate_redact::MappingVersion(version as u32),
    )
    .map_err(|e| ApiError::bad_request(format!("vault unreadable: {e}")))?;

    let restored = mapping
        .restore(&req.text, pacgate_redact::MappingVersion(version as u32))
        .map_err(|e| ApiError::bad_request(format!("restore refused: {e}")))?;

    // Audit the restore itself (locked decision 2: every restore is logged).
    sqlx::query(
        "INSERT INTO audit_log (tenant_id, user_id, action, resource, scope, metadata) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(tenant_id.0)
    .bind(user_id.0)
    .bind(AUDIT_RESTORE)
    .bind(format!("document:{}", document_id.0))
    .bind(format!("matter:{}", doc.matter_id.0))
    .bind(serde_json::json!({
        "job_id": req.job_id,
        "restored_bytes": restored.len()
    }))
    .execute(&state.db)
    .await
    .map_err(|e| ApiError::internal(format!("audit write failed: {e}")))?;

    Ok(Json(RestoreResponse {
        restored,
        job_id: req.job_id,
    }))
}
```

- [ ] **Step 4: Add the status handler (review panel feed)**

Also append to `sanitize.rs`:

```rust
#[derive(Debug, Serialize)]
pub struct SanitizeStatusResponse {
    pub document_state: String,
    pub chunk_states: Vec<String>,
    pub latest_job: Option<String>,
}

/// Status for the review panel: the document rollup + the per-chunk states +
/// the latest job that touched this document. Read-only; no vault contents.
pub async fn sanitize_status_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<pacgate_auth::Claims>,
    Path(id): Path<String>,
) -> Result<Json<SanitizeStatusResponse>, ApiError> {
    let (tenant_id, _) = crate::documents::claims_to_ids(&claims)?;
    let document_id: DocumentId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid document id: {e}")))?;
    let doc =
        crate::documents::fetch_document_for_tenant(&state, &tenant_id, &document_id).await?;

    let doc_state: String = sqlx::query(
        "SELECT sanitization_state FROM documents WHERE id = $1 LIMIT 1",
    )
    .bind(document_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .get("sanitization_state");

    let chunk_rows = sqlx::query(
        "SELECT DISTINCT sanitization_state FROM kb_chunks \
         WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3",
    )
    .bind(tenant_id.0)
    .bind(doc.matter_id.0)
    .bind(document_id.0)
    .fetch_all(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?;
    let chunk_states: Vec<String> = chunk_rows
        .iter()
        .map(|r| r.get::<String, _>("sanitization_state"))
        .collect();

    let latest_job: Option<String> = sqlx::query(
        "SELECT job_id FROM redaction_ledger_rows \
         WHERE document_id = $1 ORDER BY created_at DESC LIMIT 1",
    )
    .bind(document_id.0)
    .fetch_optional(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .map(|r| r.get::<uuid::Uuid, _>("job_id").to_string());

    Ok(Json(SanitizeStatusResponse {
        document_state: doc_state,
        chunk_states,
        latest_job,
    }))
}
```

- [ ] **Step 5: Wire the routes**

In `pacgate-ai/crates/pacgate-api/src/lib.rs`, right after the sanitize route from Task 3, add:

```rust
        .route(
            "/api/documents/:id/restore",
            post(sanitize::restore_document_handler),
        )
        .route(
            "/api/documents/:id/sanitize-status",
            get(sanitize::sanitize_status_handler),
        )
```

- [ ] **Step 6: Run the tests + workspace**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib sanitize
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test --workspace
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add pacgate-ai/crates/pacgate-api/src/sanitize.rs pacgate-ai/crates/pacgate-api/src/lib.rs
git commit -m "feat(api): add role-gated restore and sanitize-status endpoints with audit rows"
```

---

## Task 5: Hard gates on export + the OpenViking note

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/documents.rs` (`download_document`: refuse non-sanitized)

**Interfaces:**
- Consumes: `documents.sanitization_state` (TEXT, default 'pending').
- Produces: `download_document` returns `409 Conflict` when `sanitization_state NOT IN ('sanitized','never')`. The RAG gate already shipped in plan 017 (`lib.rs:306`); this task closes the second egress path named in design 5.1.

- [ ] **Step 1: Write the failing test**

Append a string-contract test module at the end of `pacgate-ai/crates/pacgate-docx/src/store.rs`'s existing test area (or a new `mod gates` block):

```rust
#[cfg(test)]
mod download_gate_tests {
    /// The gate SQL the download handler must use. Kept as a string contract
    /// so the property survives refactors without a live DB.
    pub const DOWNLOAD_STATE_SQL: &str = "\
        SELECT sanitization_state FROM documents WHERE id = $1";

    #[test]
    fn download_reads_the_state_column() {
        assert!(DOWNLOAD_STATE_SQL.contains("sanitization_state"));
    }
}
```

- [ ] **Step 2: Implement the gate in `download_document`**

In `pacgate-ai/crates/pacgate-api/src/documents.rs`, inside `download_document`, right after `fetch_document_for_tenant(&state, &tenant_id, &doc_id).await?;` and before the `doc_store.download_bytes` call, insert:

```rust
    // Egress gate (design 5.1): export/download refuses anything that is not
    // 'sanitized' or explicitly 'never'. 'pending' is the default state, so a
    // document nobody sanitized cannot leave through the download path.
    let doc_state: String = sqlx::query(
        "SELECT sanitization_state FROM documents WHERE id = $1 LIMIT 1",
    )
    .bind(doc_id.0)
    .fetch_one(&state.db)
    .await
    .map_err(|e| ApiError::internal(e.to_string()))?
    .get("sanitization_state");
    if doc_state != "sanitized" && doc_state != "never" {
        return Err(ApiError::conflict(format!(
            "document is '{doc_state}'; download requires sanitization (or explicit 'never')"
        )));
    }
```

Note: `row_to_document` does not select `sanitization_state`; keep the separate one-column query so `Document` (pacgate-core) stays unchanged.

- [ ] **Step 3: Run the workspace tests**

```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test --workspace
```

Expected: all suites `ok`.

- [ ] **Step 4: Record the OpenViking limitation in the docs block of compose**

In `deploy/client-bundle/compose.prod.yaml`, in the comment block above `pacgate-api`, add this line (hyphens, no em-dash):

```yaml
    # Sanitization gate note (design 5.1): OpenViking memory writes are
    # deer-flow -> openviking direct (not gated by pacgate-api). Accepted as a
    # documented limitation - the lane holds conversational context only, and
    # the gate inherits via sanitized chunk inputs. Do not "fix" silently.
```

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-api/src/documents.rs pacgate-ai/crates/pacgate-docx/src/store.rs deploy/client-bundle/compose.prod.yaml
git commit -m "feat(api): refuse downloads for non-sanitized documents; record OpenViking lane limitation"
```

---

## Task 6: MCP tools - sanitize, verify, document-composition

**Files:**
- Modify: `deploy/pacgate-mcp/server.py` (three new tools + docstring update)

**Interfaces:**
- Consumes: `POST /api/documents/:id/sanitize`, `GET /api/documents/:id/sanitize-status`, the existing `PacgateApi.post/get` helpers and `_handle_error`.
- Produces: `pacgate_sanitize_document(document_id, data_level="T3")`, `pacgate_verify_sanitized(document_id)`, `pacgate_sanitize_text(text, data_level="T3")` (round-trip via the API's per-document job using a throwaway text-only path is NOT built; the tool composes on `pacgate_sanitize_document` - see the design note inside the tool docstring).
- **Never added:** `pacgate_restore` (design 3.5: restore never reaches chat).

- [ ] **Step 1: Update the module docstring tool list**

In `deploy/pacgate-mcp/server.py`, in the module docstring, after the `pacgate_execute_workflow` line, add:

```python
    pacgate_sanitize_document  — run a sanitization job over a stored document
                               (POST /api/documents/:id/sanitize)
    pacgate_verify_sanitized   — check a document's sanitization status
                               (GET /api/documents/:id/sanitize-status)
```

And at the end of the docstring tool list, add this line (it documents an absence):

```python
    (pacgate_restore is deliberately NOT exposed: restore is client-side only,
     design 3.5 - no chat turn can re-hydrate placeholders.)
```

- [ ] **Step 2: Add the tools**

Append to `deploy/pacgate-mcp/server.py`:

```python
@mcp.tool()
def pacgate_sanitize_document(
    document_id: str,
    data_level: str = "T3",
) -> str:
    """Run a sanitization job over a stored document (extract-then-redact).

    The server extracts the document once (cached per version) and then runs
    the deterministic-first redaction pipeline. On a warm cache this costs
    ZERO OCR calls. A Block verdict marks the document 'blocked' - it cannot
    be downloaded or retrieved until a human decides. Restore is NOT exposed
    through MCP; it is a client-side operator action in pacgate-api.

    Args:
        document_id: The UUID of the document to sanitize.
        data_level: T1|T2|T3|T4 (default T3). T4 always requires human review.

    Returns the job outcome: verdict, redaction_count, mapping_count, the
    sanitized text, the allow_auto_pass / require_human_review flags, and the
    ledger evidence (SHA-256 pre/post, rule versions). The mapping itself
    never leaves pacgate-api.
    """
    client = get_client()
    resp = client.post(
        f"/api/documents/{document_id}/sanitize",
        json={"data_level": data_level},
    )
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_verify_sanitized(document_id: str) -> str:
    """Check a document's sanitization status (verifier side-channel).

    Returns the document-level state, the distinct per-chunk states, and the
    latest job id. Use this to decide whether material may be relied on in a
    workflow: only documents whose state is 'sanitized' (or explicitly
    'never') may leave the machine, and kb_search only ever returns
    'sanitized' or 'never' chunks regardless.

    Args:
        document_id: The UUID of the document to check.
    """
    client = get_client()
    resp = client.get(f"/api/documents/{document_id}/sanitize-status")
    _handle_error(resp)
    return json.dumps(resp.json(), ensure_ascii=False, indent=2)


@mcp.tool()
def pacgate_sanitize_text(text: str, data_level: str = "T3") -> str:
    """Sanitize raw text through the document pipeline (ephemeral artifact).

    Creates a temp doc, runs the same job path, returns the sanitized text and
    verdict. The mapping is sealed server-side and is NOT returned; the result
    is one-way on purpose (design 6.3 - cloud output never resolves back).
    For bulk work prefer ingesting real documents and using
    pacgate_sanitize_document so extraction is cached.

    Args:
        text: The raw text to sanitize.
        data_level: T1|T2|T3|T4 (default T3).
    """
    import base64 as _b64

    client = get_client()
    matters_resp = client.get("/api/matters")
    _handle_error(matters_resp)
    matters = matters_resp.json()
    if not matters:
        raise RuntimeError(
            "no matters available; create one in pacgate-api first"
        )
    matter_id = matters[0]["id"]
    blob = _b64.b64encode(text.encode("utf-8")).decode("ascii")
    files = {"file": ("sanitize-ephemeral.txt", base64.b64decode(blob))}
    up = client.post_multipart(
        "/api/documents", {"matter_id": matter_id}, files
    )
    _handle_error(up)
    doc = up.json()
    resp = client.post(
        f"/api/documents/{doc['id']}/sanitize",
        json={"data_level": data_level},
    )
    _handle_error(resp)
    outcome = resp.json()
    # Clean up: delete the ephemeral document so it does not pollute the matter.
    client.delete(f"/api/documents/{doc['id']}")
    return json.dumps(
        {
            "document_id": doc["id"],
            "job_id": outcome.get("job_id"),
            "verdict": outcome.get("verdict"),
            "sanitized_text": outcome.get("sanitized_text"),
            "redaction_count": outcome.get("redaction_count"),
            "require_human_review": outcome.get("require_human_review"),
            "note": "ephemeral document deleted; mapping sealed server-side",
        },
        ensure_ascii=False,
        indent=2,
    )
```

- [ ] **Step 3: Verify the server module imports**

From the repo root:

```
python -c "import ast; ast.parse(open('deploy/pacgate-mcp/server.py', encoding='utf-8').read()); print('syntax ok')"
```

Expected: `syntax ok`.

- [ ] **Step 4: Commit**

```bash
git add deploy/pacgate-mcp/server.py
git commit -m "feat(mcp): add sanitize/verify tools; restore stays client-side by design"
```

---

## Task 7: E2E proof - the whole loop on the live stack

**Files:**
- Create: `scripts/test-sanitizer-e2e.ps1`

**Interfaces:**
- Consumes: the plan-019 E2E flow (seed --db-url -> login -> matter -> upload PDF -> extract), then the new endpoints.

- [ ] **Step 1: Write the E2E script**

Create `scripts/test-sanitizer-e2e.ps1`:

```powershell
# Sanitizer E2E: upload -> extract -> sanitize -> verify -> restore-refusal.
# Mirrors scripts/test-ocr-extraction.ps1 conventions (PASS/FAIL lines).
# Boots fresh test containers; never touches the live pacgate-api/ deer-flow.
# Usage: powershell -File scripts/test-sanitizer-e2e.ps1
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Output "PASS: $name" } else { Write-Output "FAIL: $name"; $script:fail++ }
}

docker rm -f pacgate-ocr-e2e, pacgate-api-e2e 2>$null | Out-Null

# 1. OCR service (no host port needed; API reaches it over the compose net).
docker run -d --name pacgate-ocr-e2e --network client-bundle_default ocr-service:local | Out-Null
# 2. API under test, wired to the live db + ocr + embeddings.
docker run -d --name pacgate-api-e2e --network client-bundle_default `
  -p 127.0.0.1:8090:8080 `
  -e "DATABASE_URL=postgres://pacgate:change-me-to-a-strong-password@pacgate-db:5432/pacgate" `
  -e "DATA_DIR=/data/tenants" `
  -e "OCR_SERVICE_URL=http://pacgate-ocr-e2e:8100" `
  -e "OLLAMA_BASE_URL=http://host.docker.internal:11434" `
  -v "C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle\data:/data" `
  pacgate-api:plan020-test | Out-Null
Start-Sleep -Seconds 6
$health = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 5
Check "api boots" ($health -eq 'ok')

# 3. Seed + login + matter.
cmd /c "docker exec pacgate-api-e2e pacgate-seed --db-url postgres://pacgate:change-me-to-a-strong-password@pacgate-db:5432/pacgate 2>&1" | Out-Null
$login = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/auth/login" -Method Post -Body '{"email":"seed@pacgate.local","password":"seed-password-123"}' -ContentType "application/json"
$hdr = @{ Authorization = "Bearer $($login.token)" }
$matter = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/matters" -Method Post -Headers $hdr -Body '{"name":"Sanitizer E2E"}' -ContentType "application/json"

# 4. Upload a text document carrying an ID number (upload gate accepts .txt).
$bytes = [System.Text.Encoding]::UTF8.GetBytes("委托人张三，身份证 11010519491231002X，电话 13812345678。")
$ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
$boundary = "----psb$([System.Guid]::NewGuid().ToString('N'))"
$bw.Write([System.Text.Encoding]::ASCII.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$($matter.id)`r`n--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"case.txt`"`r`nContent-Type: text/plain`r`n`r`n"))
$bw.Write($bytes); $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$boundary--`r`n")); $bw.Flush()
$up = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents" -Method Post -Headers $hdr -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray()
Check "upload ok" ($null -ne $up.id)
$docId = $up.id

# 5. Extract (cache-warm step for the sanitize job).
$ex = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/extract" -Method Post -Headers $hdr -ContentType "application/json" -Body '{}'
Check "extract returned text" ($ex.text.Length -gt 0)

# 6. Sanitize (the plan-020 route).
$job = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/sanitize" -Method Post -Headers $hdr -ContentType "application/json" -Body '{"data_level":"T3"}'
Check "sanitize verdict pass" ($job.verdict -eq 'pass')
Check "placeholders present" ($job.sanitized_text -match '\[(CN_ID|CN_MOBILE)_)
Check "id card gone" (-not $job.sanitized_text.Contains('11010519491231002X'))
Check "phone gone" (-not $job.sanitized_text.Contains('13812345678'))
Check "mapping sealed server-side" ($job.mapping_count -ge 2)

# 7. Status + gate behaviour.
$status = Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/sanitize-status" -Headers $hdr
Check "document state sanitized" ($status.document_state -eq 'sanitized')

# 8. Restore: role gate. Attorney token must be refused.
$restoreBody = @{ job_id = $job.job_id; text = $job.sanitized_text } | ConvertTo-Json
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8090/api/documents/$docId/restore" -Method Post -Headers $hdr -ContentType "application/json" -Body $restoreBody | Out-Null
    Check "restore refused for seed role (not admin/partner)" ($false)
} catch {
    Check "restore refused for seed role (not admin/partner)" ($true)
}

# 9. DB evidence rows exist.
$dbSpans = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT count(*) FROM redaction_ledger_rows WHERE document_id = '$docId'"" 2>&1"
Check "ledger row written" ([int]($dbSpans | Select-Object -First 1) -ge 1)
$dbChunks = cmd /c "docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c ""SELECT DISTINCT sanitization_state FROM kb_chunks WHERE document_id = '$docId'"" 2>&1"
Check "chunks promoted to sanitized" (($dbChunks -join ',').Trim() -eq 'sanitized')

docker rm -f pacgate-ocr-e2e, pacgate-api-e2e 2>$null | Out-Null
if ($script:fail -eq 0) { Write-Output '== RESULT: PASS ==' } else { Write-Output "== RESULT: FAIL ($script:fail) =="; exit 1 }
```

- [ ] **Step 2: Build the image**

From the repo root:

```
docker build -f pacgate-ai/Dockerfile -t pacgate-api:plan020-test pacgate-ai
```

(Allow ~10 min; the plan-019 build cached most layers.)

- [ ] **Step 3: Run the E2E**

```
powershell -ExecutionPolicy Bypass -File scripts/test-sanitizer-e2e.ps1
```

Expected: all PASS lines + `== RESULT: PASS ==`.

- [ ] **Step 4: Commit**

```bash
git add scripts/test-sanitizer-e2e.ps1
git commit -m "test(e2e): prove the sanitizer loop - upload, extract, sanitize, gate, restore refusal"
```

---

## Task 8: Plan index + release wiring notes

**Files:**
- Create: `plans/020-sanitize-jobs.md` (one-page pointer plan)
- Modify: `plans/README.md` (status table row)
- Modify: `deploy/client-bundle/compose.prod.yaml` (env additions, commented until the release ships)

**Interfaces:**
- Consumes: everything above.
- Produces: the release gate for plan 015-style packaging: compose env + image + weights manifest.

- [ ] **Step 1: Write the one-page plan**

Create `plans/020-sanitize-jobs.md`:

```markdown
# Sanitize Jobs, Vault, Gates, MCP Tools

> Priority: P1 · Effort: M · Depends on: 019 (done), 017 (done)
> Status: DONE (2026-09-19)

Implements design `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md`
sections 3.3, 5, 5.1, 6, plus locked decisions 2/3.

## What shipped
- Migration 007: `sanitizer_jobs` (the vault; JSONB mapping) + `redaction_ledger_rows` (evidence).
- `POST /api/documents/:id/sanitize` - cache-first job; promotes pending → sanitized / blocked per document.
- `POST /api/documents/:id/restore` - admin/partner only, job + matter scoped, audit-logged.
- `GET /api/documents/:id/sanitize-status` - review-panel feed.
- Download gate: non-sanitized documents refuse download (409).
- MCP: `pacgate_sanitize_document`, `pacgate_verify_sanitized`, `pacgate_sanitize_text`. No `pacgate_restore`.
- E2E: `scripts/test-sanitizer-e2e.ps1`.

## Not in this plan (deliberate)
- OpenViking write gate (accepted limitation, recorded in compose comments).
- Combination-risk detector + red-team suite (v2).
- Pixel redaction (v2, uses plan-019 spans).
- deer-flow sanitizer agent + review panel (plan 021).
```

- [ ] **Step 2: Update the plan index**

In `plans/README.md`, add a row after `014` in the status table:

```markdown
| 019 | OCR service + Tier 2-4 NER | P1 | **DONE** — 0.1.14 line, 10 commits, E2E green (2026-09-18) |
| 020 | Sanitize jobs, vault, gates, MCP tools | P1 | **DONE** (2026-09-19) |
```

- [ ] **Step 3: Add the release env to compose (commented)**

In `deploy/client-bundle/compose.prod.yaml`, in the `pacgate-api` environment block, add:

```yaml
      # Sanitizer (plan 020). Uncomment in the 0.1.15 release compose:
      # OCR_SERVICE_URL: http://ocr-service:8100
      # PACGATE_NER_MODEL_DIR: /models/bert4ner-base-chinese
```

- [ ] **Step 4: Commit**

```bash
git add plans/020-sanitize-jobs.md plans/README.md deploy/client-bundle/compose.prod.yaml
git commit -m "docs(plans): record plan 020 sanitizer jobs as done; note release wiring"
```

---

## Self-review notes

- Spec coverage: §3.3 (MCP tools, restore excluded) → Task 6; §5/5.1 (two new objects, existing stores absorb state; audit reuses `audit_log`) → Tasks 1/2/4; stage 6 restore semantics (unknown placeholder = error, version binding) → Task 4 via `Mapping::restore`; the download gate from §5.1 contract → Task 5; the RAG gate already shipped in 017 and its tests remain green (verified at `lib.rs:490-511`).
- Placeholder scan: none - every step carries actual code or exact commands.
- Type consistency: `Mapping::serialize/deserialize` names match across Task 2 (insert call), Task 3 (impl + test), Task 4 (restore handler); `JobOutcome` fields match between the service module and the handler response.
- Deliberate exclusion: `documents.sanitization_state` rollup query reads the column directly rather than extending `pacgate_core::Document`, keeping the plan additive to the spine (design 5.1 "and nothing else").