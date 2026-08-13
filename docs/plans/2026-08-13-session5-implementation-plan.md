# Session 5 Implementation Plan — 2026-08-13

## Overview

Continuation from session 4. Phase 1 critical path is complete (Rust workspace compiles, 15 smoke tests pass). This plan covers 5 work items in dependency order: clippy cleanup, SOUL resolver middleware, remaining BigLaw agents, RAG enrichment, and integration test scaffolding.

## Verified Baseline

- 5 commits on main, all pushed to origin (sync state clean)
- `cargo check` passes (43 clippy warnings — up from documented 38)
- `cargo test -p pacgate-api --test smoke` → 15 passed, 0 failed
- 57 client asset files (28 markdown prompt guides/templates)
- 10 workflow templates implemented (target: 160+)
- 20 legal personas + 6 SOUL personas (A1, A4, A5, A8 + Justin + Sylvie)
- 4 missing BigLaw agents: A2, A3, A6, A7

## Task Summary

| #   | Task                                              | Files touched                                                                        | Estimate |
| --- | ------------------------------------------------- | ------------------------------------------------------------------------------------ | -------- |
| 1   | Clippy cleanup — remove unused imports/variables  | ~8 crate lib.rs files                                                                | 15 min   |
| 2   | SOUL resolver middleware in pacgate-auth          | pacgate-auth/src/middleware.rs, pacgate-auth/src/lib.rs, pacgate-api/src/state.rs    | 20 min   |
| 3   | Add BigLaw agents A2/A3/A6/A7 as SOUL personas    | pacgate-persona/src/lib.rs                                                           | 25 min   |
| 4   | RAG jurisdiction filtering + source level tagging | pacgate-rag/src/lib.rs, pacgate-rag/src/ingest.rs, migrations/003_rag_enrichment.sql | 30 min   |
| 5   | Integration test scaffold                         | pacgate-api/tests/integration.rs, compose.yaml                                       | 20 min   |

## Tasks

### Task 1: Clippy Cleanup

**Files:**

- Modify: `crates/pacgate-llm/src/lib.rs` — remove unused `AgentMessage`
- Modify: `crates/pacgate-tenant/src/lib.rs` — remove unused `chrono::Utc`
- Modify: `crates/pacgate-tenant/src/tenant_store.rs` — remove unused `chrono::Utc`
- Modify: `crates/pacgate-docx/src/parser.rs` — remove unused `Context`
- Modify: `crates/pacgate-docx/src/store.rs` — remove unused `chrono::Utc`, `warn`, fix `page_text`
- Modify: `crates/pacgate-rag/src/lib.rs` — remove unused `DocumentId`, `KbChunk`
- Modify: `crates/pacgate-rag/src/ingest.rs` — remove unused `uuid::Uuid`, `Row`
- Modify: `crates/pacgate-agent/src/lib.rs` — remove unused `Context`, `async_trait`, `ConversationId`, `LlmStreamEvent`, `Uuid`
- Modify: `crates/pacgate-auth/src/middleware.rs` — remove unused `Claims`
- Modify: `crates/pacgate-api/src/chat.rs` — remove unused `ConversationId`, `LlmTier`, `MessageId`
- Modify: `crates/pacgate-api/src/lib.rs` — remove unused `middleware`

**Verify:** `cargo clippy 2>&1 | grep -c "warning:"` should drop significantly. `cargo test -p pacgate-api --test smoke` must still pass 15/15.

### Task 2: SOUL Resolver Middleware

**Files:**

- Modify: `crates/pacgate-auth/src/lib.rs` — add `SoulResolver` struct
- Modify: `crates/pacgate-auth/src/middleware.rs` — add `soul_resolver_middleware`
- Modify: `crates/pacgate-api/src/state.rs` — wire `SoulResolver` into `AppState`
- Modify: `crates/pacgate-api/src/lib.rs` — apply soul resolver middleware after auth middleware

**Design:**
The SOUL resolver runs AFTER auth middleware. It reads `Claims.soul_id` from request extensions, resolves it to a `SoulPersona` via `pacgate_persona::get_soul()`, and injects the resolved `SoulPersona` into request extensions. Downstream handlers (chat, agent) can then read the `SoulPersona` to prepend the `system_preamble` and enforce `boundary_rules`.

**Verify:** `cargo check` + `cargo test -p pacgate-api --test smoke` pass.

### Task 3: Add BigLaw Agents A2/A3/A6/A7

**Files:**

- Modify: `crates/pacgate-persona/src/lib.rs` — add 4 new `SoulPersona` entries to `built_in_souls()`

**Agent definitions (from client asset: Appendix A):**

- **A2 Intake & Conflicts**: Low/Mid tier, SecurityLevel::LevelB. Runs conflict checks, creates matter workspace. Hard boundary: no matter starts without conflict clearance.
- **A3 Domain Experts**: Main tier, SecurityLevel::LevelC. 9 practice domains (Legal/Finance/Commercial/ProductTech/Cybersecurity/HR/Tax/Regulatory/ESG). Strict single-domain — no cross-domain conclusions.
- **A6 Devil's Advocate**: Main tier, SecurityLevel::LevelA. Red-flag scan, cross-domain consistency check, adversarial challenge. Can only append annotations — no rewrite power.
- **A7 Document Pipeline**: Low tier, SecurityLevel::LevelD. OCR, classification, extraction, tabular review, desensitization. Pure mechanical, zero judgment.

**Verify:** `cargo check` + `cargo test -p pacgate-api --test smoke` pass.

### Task 4: RAG Jurisdiction Filtering + Source Level Tagging

**Files:**

- Create: `pacgate-ai/migrations/003_rag_enrichment.sql` — add `jurisdiction` and `source_level` columns to `kb_chunks`
- Modify: `crates/pacgate-rag/src/lib.rs` — add jurisdiction + source_level filter params to `search()`, update SQL queries
- Modify: `crates/pacgate-rag/src/ingest.rs` — accept jurisdiction + source_level params in `ingest_document()`
- Modify: `crates/pacgate-core/src/lib.rs` — add `Jurisdiction` enum if not present

**Design:**

- `Jurisdiction` enum: `International`, `China`, `CrossBorder`, `Custom(String)` — already partially exists as a concept in `PracticeArea`.
- `kb_chunks` gets two new columns: `jurisdiction TEXT` and `source_level TEXT` (matching `SourceLevel` enum values).
- `RagStore::search()` gains optional `jurisdiction: Option<&Jurisdiction>` and `source_level: Option<&SourceLevel>` filter params.
- When filters are provided, SQL WHERE clause adds `AND c.jurisdiction = $N` and `AND c.source_level = $N`.
- `ChunkIngestor::ingest_document()` gains `jurisdiction: &Jurisdiction` and `source_level: &SourceLevel` params.

**Verify:** `cargo check` + `cargo test -p pacgate-api --test smoke` pass.

### Task 5: Integration Test Scaffold

**Files:**

- Create: `pacgate-ai/tests/integration.rs` — test that starts pacgate-api against a test Postgres and verifies the full request flow
- Modify: `compose.yaml` — add a `test` profile with ephemeral Postgres

**Design:**

- Test uses `sqlx` to create a test database, run migrations, then starts the Axum app in-process (no Docker needed for the Rust side).
- Test flow: register → login → create matter → upload document → list documents → chat (mocked LLM) → verify response.
- The test is gated behind a `#[ignore]` attribute since it needs a running Postgres. Run with `cargo test -- --ignored`.

**Verify:** `cargo test -p pacgate-api --test smoke` still passes. The integration test compiles (`cargo test -p pacgate-api --test integration --no-run`).

---

## Execution Order

1. Task 1 (clippy) → commit
2. Task 2 (SOUL resolver) → commit
3. Task 3 (BigLaw agents) → commit
4. Task 4 (RAG enrichment) → commit
5. Task 5 (integration test) → commit

Each task is independently committable. The smoke test suite is the gate after each task.
