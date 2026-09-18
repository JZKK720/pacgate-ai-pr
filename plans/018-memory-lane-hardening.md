# Memory-Lane Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the three defects found while mapping the memory interface, and add the `sanitization_state` gate that makes the sanitizer's boundary enforceable rather than advisory.

**Architecture:** No new subsystem. Three targeted changes to existing code: a real conflict check on matter-memory writes, a `sanitization_state` column on `kb_chunks` and `documents` enforced as a property of the connection (never a request parameter), and a cross-store identity assertion. The gate is what the whole sanitizer design depends on: without it, redaction happens and then gets bypassed by an ungated write.

**Tech Stack:** Rust 2021 (axum 0.7, sqlx 0.7, tokio) · Postgres + pgvector · Python 3.12 (httpx) for the adapter.

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` sections 3.6, 5.1, 5.2.

**Why this plan comes first:** defect 1 silently loses memory updates; defects 2 and 3 mean two of the four persistence lanes have *no* sanitization gate at all. Building the sanitizer before this would produce a control that does not control the paths it was written to protect.

**Verified environment (checked, not assumed):**
- `cargo` is installed at `%USERPROFILE%\.cargo\bin\cargo.exe` but **is not on PATH**. Every cargo command below therefore uses the full path. `cargo 1.94.1`, workspace resolves 16 members, `cargo check -p pacgate-tenant` succeeds.
- `pytest` is **not** installed in `.venv`. Python-adapter verification uses `python -m compileall` plus a manual HTTP probe, not pytest. Do not write a step that assumes pytest exists.

## Global Constraints

Copied from the repo conventions and the spec. Every task's requirements implicitly include this section.

- **Workspace version:** `version.workspace = true`. Never hardcode a version in a crate manifest.
- **Licence:** `license.workspace = true` (AGPL-3.0-only).
- **Dependencies:** add to `[workspace.dependencies]` in `pacgate-ai/Cargo.toml` first, then reference as `name.workspace = true`. No direct version pins inside crate manifests.
- **Errors:** use the existing `ApiError` shape (`{ status, code, message }` with the documented `pub fn` constructors). Do not introduce a second error type.
- **Migrations:** each migration file is `include_str!`-ed into a runner and executed inside an advisory lock. A new migration means editing the runner too, not just adding a file. Files are idempotent (`IF NOT EXISTS`).
- **The gate is never a request parameter** (spec 5.1). Hyrum's Law: a caller-supplied value would eventually be passed wrong, and the failure would be a silent disclosure rather than an error.
- **Fail closed:** a missing or unrecognised `sanitization_state` excludes the row. `pending` is the column default, so a path that forgets to set it fails closed.
- **No secrets:** no token, password or key in source, tests, fixtures or commit messages.
- **Text conventions:** hyphens, not em-dashes, in visible copy.

---

### Task 1: Add the `sanitization_state` migration and wire it into the runner

**Files:**
- Create: `pacgate-ai/migrations/005_sanitization_state.sql`
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs:343-393` (`run_migrations`)

**Interfaces:**
- Consumes: the existing runner pattern (advisory lock `4_243_001`, `sqlx::raw_sql`, `include_str!`).
- Produces: `kb_chunks.sanitization_state TEXT DEFAULT 'pending'` and `documents.sanitization_state TEXT DEFAULT 'pending'`, both indexed on `(tenant_id, matter_id, sanitization_state)`, applied at startup.

- [ ] **Step 1: Write the migration**

Create `pacgate-ai/migrations/005_sanitization_state.sql`:

```sql
-- Pacgate-ai sanitization state: gates every egress path.
-- Migration 005 -- design section 5.1.
--
-- Four states. `pending` is the DEFAULT and that is the safety property: a row
-- that was never processed reads as pending, not as sanitized, so a new
-- ingestion path that forgets to set this column fails closed. A default of
-- 'sanitized' would make forgetting indistinguishable from success.
--
--   pending    extracted, not yet sanitized
--   sanitized  a job produced a Block-free verdict; a ledger must exist
--   blocked    a job ran and the verdict was Block; must never reach any egress
--   never      explicitly out of scope (e.g. a T1 shared template)
--
-- Same TEXT-code convention as data_level in 004_data_level.sql, so both
-- filters can be applied in one query without a join.

ALTER TABLE kb_chunks ADD COLUMN
IF NOT EXISTS sanitization_state TEXT DEFAULT 'pending';

ALTER TABLE documents ADD COLUMN
IF NOT EXISTS sanitization_state TEXT DEFAULT 'pending';

-- Backfill is not possible automatically: no existing row has a ledger, so
-- none can claim to be sanitized. Leaving them at 'pending' is correct and
-- fail-closed. Do NOT add a backfill UPDATE here.

CREATE INDEX
IF NOT EXISTS idx_kb_chunks_sanitization
    ON kb_chunks
(tenant_id, matter_id, sanitization_state)
    WHERE sanitization_state IS NOT NULL;

CREATE INDEX
IF NOT EXISTS idx_documents_sanitization
    ON documents
(tenant_id, matter_id, sanitization_state)
    WHERE sanitization_state IS NOT NULL;
```

- [ ] **Step 2: Wire it into the runner**

In `pacgate-ai/crates/pacgate-rag/src/lib.rs`, add inside the `async` block in `run_migrations`, immediately after the `004_data_level.sql` execution and before `Ok::<(), RagError>(())`:

```rust
            // Migration 005 adds sanitization_state to kb_chunks. Without it,
            // every search gate that filters on the column errors out.
            let sanitization_sql =
                include_str!("../../../migrations/005_sanitization_state.sql");
            sqlx::raw_sql(sanitization_sql)
                .execute(&mut *conn)
                .await
                .map_err(|e| RagError::Migration(e.to_string()))?;
```

Then update the completion log line so it names all five migrations:

```rust
        tracing::info!(
            "RAG migrations applied (002_schema + 003_enrichment + 004_data_level + 005_sanitization_state)"
        );
```

- [ ] **Step 3: Verify it compiles**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-rag
```
Expected: `Finished` with exit 0. A missing or misnamed migration file fails here at compile time, because `include_str!` resolves during macro expansion.

- [ ] **Step 4: Verify the SQL parses against a real Postgres**

`include_str!` proves the file exists; it does not prove the SQL is valid. Run it for real:

```
docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-db
docker exec pacgate-db psql -U pacgate -d pacgate -c "\i /dev/stdin" < pacgate-ai/migrations/005_sanitization_state.sql
docker exec pacgate-db psql -U pacgate -d pacgate -c "\d kb_chunks" | Select-String sanitization_state
```

Expected: the `\d kb_chunks` output contains `sanitization_state | text | | 'pending'::text`. Run the migration file a **second** time and confirm it still succeeds (idempotency via `IF NOT EXISTS`).

If the `pacgate-db` container is not running, start only that service. Do not start the full stack.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/migrations/005_sanitization_state.sql pacgate-ai/crates/pacgate-rag/src/lib.rs
git commit -m "feat(db): add sanitization_state to kb_chunks and documents, defaulting to pending"
```

---
### Task 2: Add a `conflict` constructor to `ApiError`

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/error.rs:17-27`

**Interfaces:**
- Consumes: the existing `ApiError { status, code, message }` struct and its `IntoResponse`.
- Produces: `ApiError::conflict(msg: impl Into<String>) -> Self` returning `409` with code `"conflict"`.

Task 3 needs this. Adding it first keeps Task 3's diff to one concern.

- [ ] **Step 1: Write the failing test**

Append to `pacgate-ai/crates/pacgate-api/src/error.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflict_is_409_with_a_stable_code() {
        let e = ApiError::conflict("revision mismatch");
        assert_eq!(e.status, StatusCode::CONFLICT);
        assert_eq!(e.code, "conflict");
        assert_eq!(e.message, "revision mismatch");
    }

    #[test]
    fn existing_constructors_keep_their_codes() {
        assert_eq!(ApiError::bad_request("x").code, "bad_request");
        assert_eq!(ApiError::not_found("x").code, "not_found");
        assert_eq!(ApiError::internal("x").code, "internal_error");
        assert_eq!(ApiError::unauthorized("x").code, "unauthorized");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api error::
```
Expected: FAIL - `no function or associated item named 'conflict' found for struct 'ApiError'`.

- [ ] **Step 3: Write the minimal implementation**

In `pacgate-ai/crates/pacgate-api/src/error.rs`, add after the `unauthorized` constructor inside the `impl ApiError` block:

```rust
    /// 409 Conflict - the caller's view of the resource is stale.
    ///
    /// Used for optimistic concurrency on matter memory: the caller presents
    /// the revision it read, and a mismatch means somebody else wrote first.
    /// Returning the current state alongside the error is deliberate - the
    /// caller can then merge rather than blindly retry.
    pub fn conflict(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::CONFLICT, code: "conflict", message: msg.into() }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api error::`
Expected: PASS for both tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-api/src/error.rs
git commit -m "feat(api): add ApiError::conflict for optimistic concurrency"
```

---

### Task 3: Make `save_matter_memory` conflict-aware (defect 1)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs:32-49` (helpers), `:169-202` (`save_matter_memory`)

**Interfaces:**
- Consumes: `ApiError::conflict` (Task 2); existing `matter_memory_path`, `default_matter_memory`, `claims_to_ids`.
- Produces:
  - `fn memory_revision(memory: &serde_json::Value) -> u64` - reads `revision`, defaulting to 0
  - `fn check_revision(current: &serde_json::Value, expected: Option<u64>) -> Result<(), ApiError>` - the conflict rule, isolated so it is unit-testable without a database
  - A `save_matter_memory` that increments `revision` on success and returns `409` on a mismatch.

**The behaviour being fixed:** the handler currently replaces the whole file and nothing reads `revision`, so two concurrent writers lose one update silently. In legal work the loser may be the only record of a decision.

- [ ] **Step 1: Write the failing test**

Append to `pacgate-ai/crates/pacgate-api/src/matters.rs`:

```rust
#[cfg(test)]
mod memory_concurrency_tests {
    use super::*;

    #[test]
    fn revision_defaults_to_zero_when_absent_or_unusable() {
        assert_eq!(memory_revision(&serde_json::json!({})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": 7})), 7);
        assert_eq!(memory_revision(&serde_json::json!({"revision": "nope"})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": -3})), 0);
    }

    #[test]
    fn an_unconditional_write_is_allowed() {
        // Backwards compatibility: an existing caller that sends no If-Match
        // must keep working. This is a deliberate choice, not an oversight -
        // see the note in the plan.
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, None).is_ok());
    }

    #[test]
    fn a_matching_revision_is_allowed() {
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, Some(5)).is_ok());
    }

    #[test]
    fn a_stale_revision_is_a_conflict() {
        let current = serde_json::json!({"revision": 5});
        let err = check_revision(&current, Some(4)).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::CONFLICT);
    }

    #[test]
    fn a_future_revision_is_also_a_conflict() {
        // A caller claiming a revision that does not exist is confused, not
        // ahead. Treating it as a conflict is the fail-closed choice.
        let current = serde_json::json!({"revision": 5});
        assert_eq!(
            check_revision(&current, Some(99)).unwrap_err().status,
            axum::http::StatusCode::CONFLICT
        );
    }

    #[test]
    fn a_new_matter_with_no_file_conflicts_only_on_a_non_zero_claim() {
        // No file means revision 0. A caller sending If-Match: 0 is correct;
        // any other value is stale.
        let current = default_matter_memory();
        assert!(check_revision(&current, Some(0)).is_ok());
        assert!(check_revision(&current, Some(1)).is_err());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api memory_concurrency_tests
```
Expected: FAIL - `cannot find function 'memory_revision'`.

- [ ] **Step 3: Write the minimal implementation**

In `pacgate-ai/crates/pacgate-api/src/matters.rs`, add immediately after `default_matter_memory()` (after line 49):

```rust
/// Read the `revision` counter out of a matter-memory object.
///
/// Absent, negative or non-numeric all read as 0. That is the fail-closed
/// choice for a *missing* value, and it matches a brand-new matter whose file
/// has never been written.
fn memory_revision(memory: &serde_json::Value) -> u64 {
    memory
        .get("revision")
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
}

/// Enforce optimistic concurrency on a memory write.
///
/// `expected` is the revision the caller believes it is updating, or `None`
/// for an unconditional write.
///
/// Two deliberate decisions, both recorded because they are judgement calls
/// rather than derivable:
///
/// 1. `None` is ALLOWED. Requiring `If-Match` would break the existing
///    deer-flow adapter, which does not send one. The fix for the silent-loss
///    defect must not itself break a working integration, so the stricter
///    behaviour is opt-in per caller. Task 4 makes the adapter opt in.
/// 2. A claim that matches neither the current revision nor the past is a
///    conflict, not a fast-forward. A caller claiming revision 99 against
///    revision 5 is confused, and guessing which of the two is right is how
///    data gets lost.
fn check_revision(
    current: &serde_json::Value,
    expected: Option<u64>,
) -> Result<(), ApiError> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let actual = memory_revision(current);
    if expected == actual {
        return Ok(());
    }
    Err(ApiError::conflict(format!(
        "matter memory revision mismatch: file is at {}, caller expected {}",
        actual, expected
    )))
}
```

Then replace the body of `save_matter_memory` to read the current file, check the revision, and increment it. Add an `If-Match` header extractor to the signature:

```rust
pub async fn save_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
    headers: axum::http::HeaderMap,
    Json(mut memory): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !memory.is_object() {
        return Err(ApiError::bad_request("matter memory must be a JSON object"));
    }

    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let path = matter_memory_path(&state.config.data_dir, &tenant_id, &matter_id);

    // Read current state to establish the revision. A missing file is
    // revision 0, which is what default_matter_memory() reports.
    let current: serde_json::Value = if path.exists() {
        let bytes = std::fs::read(&path)
            .map_err(|e| ApiError::internal(format!("failed to read matter memory: {e}")))?;
        serde_json::from_slice(&bytes)
            .map_err(|e| ApiError::internal(format!("failed to parse matter memory: {e}")))?
    } else {
        default_matter_memory()
    };

    // Optional If-Match: <revision>. Absent means unconditional.
    let expected: Option<u64> = headers
        .get(axum::http::header::IF_MATCH)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().trim_matches('"').to_string())
        .and_then(|s| s.parse::<u64>().ok());

    check_revision(&current, expected)?;

    // Stamp the new revision and timestamp. The server owns both; a caller
    // cannot set them, because a caller-supplied revision would defeat the
    // whole check.
    let next = memory_revision(&current).saturating_add(1);
    if let Some(obj) = memory.as_object_mut() {
        obj.insert("revision".to_string(), serde_json::json!(next));
        obj.insert(
            "lastUpdated".to_string(),
            serde_json::json!(chrono::Utc::now().to_rfc3339()),
        );
    }

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| ApiError::internal(format!("failed to prepare matter memory dir: {e}")))?;
    }

    let bytes = serde_json::to_vec_pretty(&memory)
        .map_err(|e| ApiError::internal(format!("failed to serialize matter memory: {e}")))?;
    std::fs::write(&path, bytes)
        .map_err(|e| ApiError::internal(format!("failed to write matter memory: {e}")))?;

    Ok(Json(memory))
}
```

Note: `chrono` is already a dependency of `pacgate-api`. Confirm with `Select-String -Path pacgate-ai/crates/pacgate-api/Cargo.toml -Pattern chrono` before relying on it.

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api memory_concurrency_tests
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-api
```
Expected: PASS for all six tests, and `check` exits 0.

Also run the existing suite to prove nothing regressed:
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api
```

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-api/src/matters.rs
git commit -m "fix(api): make matter-memory writes conflict-aware so concurrent updates cannot be lost"
```

---

### Task 4: Make the deer-flow adapter opt into conflict detection

**Files:**
- Modify: `pacgate-adapters/python/pacgate_deerflow_adapter/client.py:66-71` (add a headers-aware `post`)
- Modify: `pacgate-adapters/python/pacgate_deerflow_adapter/storage.py` (`PacgateMemoryStorage`)

**Interfaces:**
- Consumes: the `If-Match` support from Task 3.
- Produces:
  - `PacgateApiClient.post(path, json=None, headers=None) -> httpx.Response` (header pass-through)
  - `PacgateMemoryStorage` tracks the revision it last read and sends `If-Match` on save, raising a distinguishable error on `409`.

Without this task the server-side check exists but no caller uses it, so the defect is only half fixed. Task 3 made the strictness opt-in deliberately, to avoid breaking this adapter; this task is the opt-in.

- [ ] **Step 1: Write the failing test**

Create `pacgate-adapters/python/tests/test_memory_revision.py`:

```python
"""Revision handling in PacgateMemoryStorage.

pytest is not installed in this repo's venv, so this file is written to be
runnable with plain unittest:

    python -m unittest discover -s pacgate-adapters/python/tests -v
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pacgate_deerflow_adapter.storage import (  # noqa: E402
    MatterMemoryConflict,
    PacgateMemoryStorage,
)


class RevisionTrackingTests(unittest.TestCase):
    def _storage(self):
        with patch.dict(
            "os.environ",
            {"PACGATE_MATTER_ID": "11111111-1111-1111-1111-111111111111"},
        ):
            storage = PacgateMemoryStorage.__new__(PacgateMemoryStorage)
            storage.client = MagicMock()
            storage.matter_id = "11111111-1111-1111-1111-111111111111"
            storage._revision = None
            return storage

    def test_load_records_the_revision_it_read(self):
        storage = self._storage()
        storage.client.get.return_value = MagicMock(
            status_code=200, json=lambda: {"revision": 4, "facts": []}
        )
        storage.client.get.return_value.raise_for_status = lambda: None

        storage.load()

        self.assertEqual(storage._revision, 4)

    def test_load_treats_a_missing_revision_as_zero(self):
        storage = self._storage()
        storage.client.get.return_value = MagicMock(
            status_code=200, json=lambda: {"facts": []}
        )
        storage.client.get.return_value.raise_for_status = lambda: None

        storage.load()

        self.assertEqual(storage._revision, 0)

    def test_save_sends_if_match_when_a_revision_is_known(self):
        storage = self._storage()
        storage._revision = 4
        storage.client.post.return_value = MagicMock(status_code=200, json=lambda: {})
        storage.client.post.return_value.raise_for_status = lambda: None

        storage.save({"facts": []})

        _, kwargs = storage.client.post.call_args
        self.assertEqual(kwargs["headers"]["If-Match"], "4")

    def test_save_without_a_known_revision_sends_no_if_match(self):
        storage = self._storage()
        storage.client.post.return_value = MagicMock(status_code=200, json=lambda: {})
        storage.client.post.return_value.raise_for_status = lambda: None

        storage.save({"facts": []})

        _, kwargs = storage.client.post.call_args
        self.assertNotIn("If-Match", kwargs["headers"])

    def test_a_409_raises_matter_memory_conflict_and_is_not_swallowed(self):
        storage = self._storage()
        storage._revision = 4
        conflict = MagicMock(status_code=409, text="revision mismatch")
        conflict.raise_for_status = lambda: None
        storage.client.post.return_value = conflict

        with self.assertRaises(MatterMemoryConflict):
            storage.save({"facts": []})

    def test_a_conflict_clears_the_remembered_revision(self):
        # After a conflict the local view is known-stale, so the next save
        # must not replay the bad revision.
        storage = self._storage()
        storage._revision = 4
        conflict = MagicMock(status_code=409, text="revision mismatch")
        conflict.raise_for_status = lambda: None
        storage.client.post.return_value = conflict

        with self.assertRaises(MatterMemoryConflict):
            storage.save({"facts": []})

        self.assertIsNone(storage._revision)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run from the repo root:
```
.venv\Scripts\python.exe -m unittest discover -s pacgate-adapters/python/tests -v
```
Expected: FAIL with `ImportError: cannot import name 'MatterMemoryConflict'`.

- [ ] **Step 3: Write the minimal implementation**

In `pacgate-adapters/python/pacgate_deerflow_adapter/client.py`, replace the existing `post` method (around line 66) with a header-aware version:

```python
    def post(
        self,
        path: str,
        json: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
    ) -> httpx.Response:
        """POST with optional extra headers (e.g. If-Match for concurrency)."""
        merged = self._headers()
        if headers:
            merged.update(headers)
        return self._client.post(f"{self.base_url}{path}", json=json, headers=merged)
```

In `pacgate-adapters/python/pacgate_deerflow_adapter/storage.py`, add the exception near the top (after the imports):

```python
class MatterMemoryConflict(Exception):
    """Raised when a matter-memory write is rejected as stale (HTTP 409).

    Deliberately NOT swallowed into a generic failure. A conflict means another
    writer changed the memory since this process read it; silently retrying
    would discard their update, and silently ignoring the error would discard
    this one. The caller must decide.
    """
```

Then replace `PacgateMemoryStorage.__init__`, `load` and `save`:

```python
    def __init__(self):
        self.client = PacgateApiClient(
            base_url=os.environ.get("PACGATE_API_URL"),
            jwt_token=os.environ.get("PACGATE_JWT_TOKEN"),
            tenant_id=os.environ.get("PACGATE_TENANT_ID"),
            email=os.environ.get("PACGATE_API_EMAIL"),
            password=os.environ.get("PACGATE_API_PASSWORD"),
        )
        self.matter_id = os.environ.get("PACGATE_MATTER_ID")
        if not self.matter_id:
            raise ValueError("PacgateMemoryStorage requires PACGATE_MATTER_ID")
        # The revision last observed. None means "never read", which sends no
        # If-Match and therefore keeps the unconditional write path working.
        self._revision: int | None = None

    def load(
        self, agent_name: str | None = None, *, user_id: str | None = None
    ) -> dict[str, Any]:
        """Load memory from pacgate-api, remembering the revision read."""
        resp = self.client.get(f"/api/matters/{self.matter_id}/memory")
        resp.raise_for_status()
        data = resp.json()
        if isinstance(data, dict):
            revision = data.get("revision", 0)
            self._revision = revision if isinstance(revision, int) else 0
        return data

    def reload(
        self, agent_name: str | None = None, *, user_id: str | None = None
    ) -> dict[str, Any]:
        """Reload memory from pacgate-api (same as load)."""
        return self.load(agent_name, user_id=user_id)

    def save(
        self,
        memory_data: dict[str, Any],
        agent_name: str | None = None,
        *,
        user_id: str | None = None,
    ) -> bool:
        """Save memory to pacgate-api, guarding against a lost update.

        Sends If-Match when a revision is known. On 409, raises
        MatterMemoryConflict and forgets the revision, so a caller that chooses
        to retry must reload first rather than replaying the stale value.
        """
        headers: dict[str, str] = {}
        if self._revision is not None:
            headers["If-Match"] = str(self._revision)

        resp = self.client.post(
            f"/api/matters/{self.matter_id}/memory",
            json=memory_data,
            headers=headers,
        )

        if resp.status_code == 409:
            self._revision = None
            raise MatterMemoryConflict(
                f"matter memory was modified concurrently: {resp.text}"
            )

        resp.raise_for_status()
        return True
```

- [ ] **Step 4: Run the test to verify it passes**

Run from the repo root:
```
.venv\Scripts\python.exe -m unittest discover -s pacgate-adapters/python/tests -v
```
Expected: PASS for all six tests (`OK`).

Then prove the package still compiles as a whole, since `unittest` only imports the module under test:
```
.venv\Scripts\python.exe -m compileall -q pacgate-adapters/python/pacgate_deerflow_adapter
```
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add pacgate-adapters/python/pacgate_deerflow_adapter/client.py pacgate-adapters/python/pacgate_deerflow_adapter/storage.py pacgate-adapters/python/tests/test_memory_revision.py
git commit -m "fix(adapter): send If-Match on memory save and surface 409 instead of losing the update"
```

---

### Task 5: Enforce the sanitization gate in the RAG search path (defect 2)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs:231-292` (`build_filtered_sql`)
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs:149`, `:197` (the two base queries)

**Interfaces:**
- Consumes: the `sanitization_state` column (Task 1).
- Produces: every `RagStore::search` result is restricted to `sanitization_state = 'sanitized'`, unconditionally, with no filter field and no caller override.

This is the gate the whole design depends on. `SearchFilter` deliberately gains **no** new field: the constraint is not configurable.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-rag/src/lib.rs` test module by appending to the file:

```rust
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
            sql.contains("c.sanitization_state = 'sanitized'"),
            "the gate must apply with no filter set: {sql}"
        );
    }

    #[test]
    fn the_gate_is_present_on_the_keyword_path_too() {
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_KEYWORD, &filter, "$5", "$6");
        assert!(sql.contains("c.sanitization_state = 'sanitized'"), "{sql}");
    }

    #[test]
    fn the_gate_is_present_alongside_every_other_filter() {
        let filter = SearchFilter::new()
            .with_max_data_level(DataLevel::T3ProjectSpecific)
            .with_jurisdiction(Jurisdiction::ChinaMainland);
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        assert!(sql.contains("c.sanitization_state = 'sanitized'"), "{sql}");
        assert!(sql.contains("c.data_level IN ("), "{sql}");
    }

    #[test]
    fn the_gate_precedes_order_by_and_limit() {
        let filter = SearchFilter::new();
        let (sql, _, _) = RagStore::build_filtered_sql_for_test(BASE_SEMANTIC, &filter, "$5", "$6");
        let gate = sql.find("sanitization_state").expect("gate present");
        let order = sql.find("ORDER BY").expect("order by present");
        let limit = sql.find("LIMIT").expect("limit present");
        assert!(gate < order, "gate must be in the WHERE clause, not after ORDER BY");
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag gate_tests
```
Expected: FAIL - `no function or associated item named 'build_filtered_sql_for_test'`.

- [ ] **Step 3: Write the minimal implementation**

`build_filtered_sql` is currently a private associated fn. Add a thin test-visible wrapper next to it in the same `impl` block:

```rust
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
```

Then, inside `build_filtered_sql`, append the gate immediately before the `sql.push_str(" ORDER BY ");` line (i.e. after the `data_level` block):

```rust
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag gate_tests
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-rag
```
Expected: PASS for all five tests, and `check` exits 0.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-rag/src/lib.rs
git commit -m "fix(rag): gate every search on sanitization_state as a property of the connection"
```

---

### Task 6: Make the ingest path set `sanitization_state` explicitly (defect 3)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-rag/src/ingest.rs`

**Interfaces:**
- Consumes: the column from Task 1; the gate from Task 5.
- Produces: `ChunkIngestor` writes `sanitization_state = 'pending'` explicitly on new chunks, and exposes `mark_sanitized(&self, tenant_id, matter_id, document_id, ledger_job_id) -> Result<u64, RagError>` for the sanitizer to call in plan 3.

Task 5 added the read gate. This task makes the write side explicit, so the default and the write agree rather than relying on the column default alone. `PacgateArtifactStore.write_artifact()` uploads to `/api/documents`, which is the ingestion path for exactly these rows, and it currently sets nothing.

- [ ] **Step 1: Write the failing test**

Append to `pacgate-ai/crates/pacgate-rag/src/ingest.rs`:

```rust
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
    fn the_promote_statement_targets_only_pending_rows() {
        // Promoting must be idempotent and must not resurrect a 'blocked' row.
        assert!(MARK_SANITIZED_SQL.contains("sanitization_state = 'pending'"));
        assert!(MARK_SANITIZED_SQL.contains("SET sanitization_state = 'sanitized'"));
    }

    #[test]
    fn the_promote_statement_stays_within_one_document() {
        assert!(MARK_SANITIZED_SQL.contains("document_id = $3"));
        assert!(MARK_SANITIZED_SQL.contains("tenant_id = $1"));
        assert!(MARK_SANITIZED_SQL.contains("matter_id = $2"));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag sanitization_state_tests
```
Expected: FAIL - `cannot find value 'INSERT_CHUNK_SQL'`.

- [ ] **Step 3: Add the two SQL constants and the promote method**

First, inspect the existing insert statement so the constant matches it:

```
Select-String -Path pacgate-ai/crates/pacgate-rag/src/ingest.rs -Pattern "INSERT INTO kb_chunks" -Context 0,12
```

Add at module level in `pacgate-ai/crates/pacgate-rag/src/ingest.rs` (adapt the column list to whatever the existing INSERT uses, keeping every existing column and adding `sanitization_state`):

```rust
/// Ingest sets `sanitization_state` explicitly rather than leaning on the
/// column default. If a future migration changed the default, ingest behaviour
/// would change silently - and the direction of that change would decide
/// whether unsanitized text becomes retrievable.
const INSERT_CHUNK_SQL: &str = "\
    INSERT INTO kb_chunks \
        (tenant_id, matter_id, document_id, chunk_index, content, embedding, jurisdiction, source_level, data_level, sanitization_state) \
    VALUES ($1, $2, $3, $4, $5, $6::vector, $7, $8, $9, 'pending')";

/// Promote a document's pending chunks after a job produced a clean verdict.
///
/// Scoped to one document on purpose: a sanitization job covers one document
/// version, so a wider UPDATE could promote chunks nobody examined. The
/// `= 'pending'` guard makes it idempotent and, more importantly, prevents a
/// `blocked` row from ever being promoted by a later successful run on a
/// different document.
const MARK_SANITIZED_SQL: &str = "\
    UPDATE kb_chunks SET sanitization_state = 'sanitized' \
    WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
      AND sanitization_state = 'pending'";
```

Add the promote method to `impl ChunkIngestor`:

```rust
    /// Promote this document's `pending` chunks to `sanitized`.
    ///
    /// Returns the number of rows changed. Called by the sanitizer (plan 3)
    /// only after a job has produced a `Verdict::Pass` and sealed a ledger row.
    /// The caller is responsible for that ordering; this method does not check
    /// for a ledger, because doing so would couple ingestion to the ledger
    /// schema.
    pub async fn mark_sanitized(
        &self,
        tenant_id: &pacgate_core::TenantId,
        matter_id: &pacgate_core::MatterId,
        document_id: &pacgate_core::DocumentId,
    ) -> Result<u64, RagError> {
        let result = sqlx::query(MARK_SANITIZED_SQL)
            .bind(tenant_id.0)
            .bind(matter_id.0)
            .bind(document_id.0)
            .execute(&self.db)
            .await
            .map_err(|e| RagError::Database(e.to_string()))?;

        Ok(result.rows_affected())
    }
```

Confirm the `self.db` field name and the `RagError` variant names against the existing file before compiling; adjust the accessor and variant if they differ.

- [ ] **Step 4: Use the constant in the existing insert**

Replace the insert query string in the ingest method with `INSERT_CHUNK_SQL`, and bind `data_level` as parameter `$8` in its existing position. Ensure `.bind(...)` order matches the placeholder order exactly - the existing code binds left to right, so `sanitization_state` being a literal in the SQL adds no bind.

- [ ] **Step 5: Run the tests to verify they pass**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-rag
```
Expected: PASS for all four new tests plus the Task 5 gate tests, and `check` exits 0.

- [ ] **Step 6: Commit**

```bash
git add pacgate-ai/crates/pacgate-rag/src/ingest.rs
git commit -m "feat(rag): set sanitization_state explicitly on ingest and add a scoped promote"
```

---

### Task 7: Cross-store identity consistency assertion

**Files:**
- Create: `pacgate-ai/crates/pacgate-rag/src/identity.rs`
- Modify: `pacgate-ai/crates/pacgate-rag/src/lib.rs` (add `pub mod identity;`)

**Interfaces:**
- Consumes: `TenantId`, `MatterId` from `pacgate-core`.
- Produces: `pub fn same_scope(a: &ScopeIds, b: &ScopeIds) -> Result<(), ScopeMismatch>` and `pub fn assert_document_scope(expected: &ScopeIds, actual: &ScopeIds) -> Result<(), RagError>`.

**Why this task exists, and it is not in the spec's defect list.** `tenant_id` and `matter_id` are the only values present in *every* store: the filesystem path (`matter_dir`), four SQL tables, and the OpenViking headers. Nothing enforces that they agree. The path copy is derived by string join; the SQL copy is a UUID column. A mismatch between them is an isolation failure that *no single-store check can detect*, because each store individually looks correct. This is the one defensive measure worth adding beyond the gate.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-rag/src/identity.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use pacgate_core::{MatterId, TenantId};
    use uuid::Uuid;

    fn ids(t: u128, m: u128) -> ScopeIds {
        ScopeIds { tenant_id: TenantId(Uuid::from_u128(t)), matter_id: MatterId(Uuid::from_u128(m)) }
    }

    #[test]
    fn identical_scope_passes() {
        assert!(same_scope(&ids(1, 2), &ids(1, 2)).is_ok());
    }

    #[test]
    fn a_tenant_mismatch_is_caught() {
        let err = same_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Tenant { .. }));
    }

    #[test]
    fn a_matter_mismatch_is_caught() {
        let err = same_scope(&ids(1, 2), &ids(1, 9)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Matter { .. }));
    }

    #[test]
    fn a_tenant_mismatch_is_reported_before_a_matter_mismatch() {
        // If both differ, the tenant is the outer boundary and the more
        // serious failure, so it must be the one reported.
        let err = same_scope(&ids(1, 2), &ids(9, 9)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Tenant { .. }));
    }

    #[test]
    fn the_error_message_names_both_values_without_leaking_content() {
        let err = same_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("tenant"), "{msg}");
        // IDs are identifiers, not content, so naming them aids diagnosis.
        assert!(msg.contains(&Uuid::from_u128(1).to_string()), "{msg}");
    }

    #[test]
    fn assert_document_scope_maps_a_mismatch_to_a_rag_error() {
        let err = assert_document_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        assert!(matches!(err, super::super::RagError::Scope(_)));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag identity::
```
Expected: FAIL - the module does not exist, and `RagError::Scope` is not a variant.

- [ ] **Step 3: Add the error variant**

In `pacgate-ai/crates/pacgate-rag/src/lib.rs`, add a variant to `RagError`:

```rust
    #[error("scope mismatch: {0}")]
    Scope(String),
```

Confirm the existing `RagError` definition's shape first with:
```
Select-String -Path pacgate-ai/crates/pacgate-rag/src/lib.rs -Pattern "enum RagError" -Context 0,20
```

- [ ] **Step 4: Write the implementation**

Prepend to `pacgate-ai/crates/pacgate-rag/src/identity.rs`, above the test module:

```rust
//! Cross-store identity consistency.
//!
//! `tenant_id` and `matter_id` appear in four different representations of the
//! same fact:
//!
//!   1. the filesystem path, built by `pacgate_tenant::matter_dir` as a string join
//!   2. `kb_chunks.tenant_id` / `.matter_id` UUID columns
//!   3. `documents.tenant_id` / `.matter_id` UUID columns
//!   4. the OpenViking `X-OpenViking-Account` header and `peer` value
//!
//! Nothing enforces that these agree, and a disagreement between 1 and 2 is
//! invisible to any single-store check: the file is where the path says, and
//! the row is where the columns say, so both look correct in isolation. The
//! observable symptom would be one matter reading another's memory.
//!
//! This module exists to make that specific mismatch detectable. It is not a
//! substitute for per-store validation; it covers the seam those validations
//! cannot see.

use pacgate_core::{MatterId, TenantId};

use crate::RagError;

/// The two identifiers that must agree everywhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScopeIds {
    pub tenant_id: TenantId,
    pub matter_id: MatterId,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ScopeMismatch {
    #[error("tenant mismatch: expected {expected}, found {actual}")]
    Tenant { expected: String, actual: String },
    #[error("matter mismatch within tenant {tenant}: expected {expected}, found {actual}")]
    Matter {
        tenant: String,
        expected: String,
        actual: String,
    },
}

/// Compare two views of the same scope.
///
/// Tenant is checked first: it is the outer boundary, so when both differ the
/// tenant is both the more serious failure and the more useful one to report.
pub fn same_scope(expected: &ScopeIds, actual: &ScopeIds) -> Result<(), ScopeMismatch> {
    if expected.tenant_id != actual.tenant_id {
        return Err(ScopeMismatch::Tenant {
            expected: expected.tenant_id.as_str(),
            actual: actual.tenant_id.as_str(),
        });
    }
    if expected.matter_id != actual.matter_id {
        return Err(ScopeMismatch::Matter {
            tenant: expected.tenant_id.as_str(),
            expected: expected.matter_id.as_str(),
            actual: actual.matter_id.as_str(),
        });
    }
    Ok(())
}

/// `same_scope`, mapped into `RagError` for use inside the retrieval path.
pub fn assert_document_scope(
    expected: &ScopeIds,
    actual: &ScopeIds,
) -> Result<(), RagError> {
    same_scope(expected, actual).map_err(|e| RagError::Scope(e.to_string()))
}
```

Add `pub mod identity;` to `pacgate-ai/crates/pacgate-rag/src/lib.rs`.

- [ ] **Step 5: Run the tests to verify they pass**

Run (from `pacgate-ai/`):
```
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-rag identity::
& "$env:USERPROFILE\.cargo\bin\cargo.exe" check -p pacgate-rag
```
Expected: PASS for all six tests, `check` exits 0.

- [ ] **Step 6: Commit**

```bash
git add pacgate-ai/crates/pacgate-rag/src/identity.rs pacgate-ai/crates/pacgate-rag/src/lib.rs
git commit -m "feat(rag): add cross-store identity consistency check for tenant and matter"
```

---

### Task 8: End-to-end verification against a live stack

**Files:**
- Create: `scripts/test-sanitization-gate.ps1`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: an executable proof that the gate actually excludes non-sanitized rows, using a real Postgres. Unit tests prove the SQL *contains* the clause; only this proves the clause *excludes* a row.

**Why this task is not optional.** A gate that compiles and contains the right string can still be a no-op if the column is NULL, the index is wrong, or the row was inserted before the migration. This is the same failure class recorded in this repo's memory: a check that cannot fail. Prove the exclusion, not the presence.

- [ ] **Step 1: Write the test script**

Create `scripts/test-sanitization-gate.ps1`:

```powershell
# Proves the sanitization gate EXCLUDES a non-sanitized row.
#
# Unit tests assert the SQL contains the gate. That is not the same claim. This
# script inserts three rows directly - pending, sanitized, blocked - and asserts
# that a search-equivalent SELECT returns only the sanitized one. A gate that is
# present but ineffective passes the unit tests and fails here.
#
# Requires: docker, the pacgate-db container, and migrations 001-005 applied.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$Db = 'pacgate-db'
$failures = 0

function Assert-Equal($label, $expected, $actual) {
    if ("$expected" -eq "$actual") {
        Write-Host "  PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $label" -ForegroundColor Red
        Write-Host "        expected: $expected"
        Write-Host "        actual:   $actual"
        $script:failures++
    }
}

function Invoke-Psql([string]$sql) {
    $out = docker exec $Db psql -U pacgate -d pacgate -t -A -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $out" }
    return ($out | Out-String).Trim()
}

Write-Host "=== sanitization gate: exclusion proof ===" -ForegroundColor Cyan

# Confirm the column exists at all. A missing column would make every later
# assertion fail with a confusing error, so check it explicitly first.
$col = Invoke-Psql "SELECT column_default FROM information_schema.columns WHERE table_name='kb_chunks' AND column_name='sanitization_state'"
Assert-Equal "kb_chunks.sanitization_state default is pending" "'pending'::text" $col

# Build a throwaway tenant/matter/document so the fixture cannot collide with
# real data and can be removed wholesale afterwards.
Invoke-Psql "INSERT INTO tenants (id, name, slug) VALUES ('00000000-0000-0000-0000-00000000dead','gate-test','gate-test') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO users (id, tenant_id, email, role) VALUES ('00000000-0000-0000-0000-0000000000ff','00000000-0000-0000-0000-00000000dead','gate@test.local','attorney') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO matters (id, tenant_id, name, created_by) VALUES ('00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000dead','gate matter','00000000-0000-0000-0000-0000000000ff') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO documents (id, matter_id, tenant_id, name, format, storage_path, owner_id) VALUES ('00000000-0000-0000-0000-00000000cafe','00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000dead','gate.docx','docx','gate/doc_v1.docx','00000000-0000-0000-0000-0000000000ff') ON CONFLICT DO NOTHING" | Out-Null

# Three chunks, one per state. Same content so only the state differs.
Invoke-Psql "DELETE FROM kb_chunks WHERE document_id='00000000-0000-0000-0000-00000000cafe'" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('00000000-0000-0000-0000-00000000dead','00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000cafe',0,'GATEPROBE pending','T3','pending')" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('00000000-0000-0000-0000-00000000dead','00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000cafe',1,'GATEPROBE sanitized','T3','sanitized')" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('00000000-0000-0000-0000-00000000dead','00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000cafe',2,'GATEPROBE blocked','T3','blocked')" | Out-Null

# The unfiltered count proves the fixture is real: three rows exist.
$all = Invoke-Psql "SELECT count(*) FROM kb_chunks WHERE content LIKE 'GATEPROBE%'"
Assert-Equal "fixture inserted 3 chunks" 3 $all

# THE assertion: the gate clause, run for real, returns only the sanitized row.
$gated = Invoke-Psql "SELECT content FROM kb_chunks c WHERE c.tenant_id='00000000-0000-0000-0000-00000000dead' AND c.matter_id='00000000-0000-0000-0000-00000000beef' AND c.sanitization_state IN ('sanitized','never') ORDER BY c.chunk_index"
Assert-Equal "gate returns exactly one row" "GATEPROBE sanitized" $gated

# A NULL state must be excluded, not treated as sanitized.
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('00000000-0000-0000-0000-00000000dead','00000000-0000-0000-0000-00000000beef','00000000-0000-0000-0000-00000000cafe',3,'GATEPROBE nullstate','T3',NULL)" | Out-Null
$withNull = Invoke-Psql "SELECT count(*) FROM kb_chunks c WHERE c.matter_id='00000000-0000-0000-0000-00000000beef' AND c.sanitization_state IN ('sanitized','never')"
Assert-Equal "a NULL state is excluded by the gate" 1 $withNull

# Cross-store identity: the path copy and the column copy must agree.
$pathMatter = Invoke-Psql "SELECT matter_id FROM documents WHERE id='00000000-0000-0000-0000-00000000cafe'"
$chunkMatter = Invoke-Psql "SELECT DISTINCT matter_id FROM kb_chunks WHERE document_id='00000000-0000-0000-0000-00000000cafe' LIMIT 1"
Assert-Equal "documents.matter_id matches kb_chunks.matter_id" $pathMatter $chunkMatter

# Clean up.
Invoke-Psql "DELETE FROM kb_chunks WHERE document_id='00000000-0000-0000-0000-00000000cafe'" | Out-Null
Invoke-Psql "DELETE FROM documents WHERE id='00000000-0000-0000-0000-00000000cafe'" | Out-Null
Invoke-Psql "DELETE FROM matters WHERE id='00000000-0000-0000-0000-00000000beef'" | Out-Null
Invoke-Psql "DELETE FROM users WHERE id='00000000-0000-0000-0000-0000000000ff'" | Out-Null
Invoke-Psql "DELETE FROM tenants WHERE id='00000000-0000-0000-0000-00000000dead'" | Out-Null

Write-Host ""
if ($failures -eq 0) {
    Write-Host "ALL ASSERTIONS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures ASSERTION(S) FAILED" -ForegroundColor Red
    exit 1
}
```

- [ ] **Step 2: Run it and watch it fail first**

Run:
```
docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-db
pwsh -NoProfile -File scripts/test-sanitization-gate.ps1
```

Expected: **FAIL** if Task 1 has not been applied, because `sanitization_state` does not exist. This is the check proving the script can fail - without it, a green run means nothing.

If it passes on the first attempt, stop and investigate: the column existed before this plan, or the assertions are not binding.

- [ ] **Step 3: Apply migrations and run it again**

Apply migrations by starting the API (which runs them at boot):
```
docker compose -f deploy/client-bundle/compose.prod.yaml up -d pacgate-api
docker logs pacgate-api 2>&1 | Select-String "migrations"
pwsh -NoProfile -File scripts/test-sanitization-gate.ps1
```

Expected: `ALL ASSERTIONS PASSED`, exit 0. The log line must name `005_sanitization_state`.

Note: `pacgate-api` in the compose file is pinned to a published image, which will **not** contain your local migration until it is rebuilt. For this step, build locally instead:
```
docker build -f pacgate-ai/Dockerfile -t pacgate-api:local pacgate-ai
```
and point a throwaway compose override at `pacgate-api:local`, or apply migration 005 by hand with `psql` and run only the script. Applying by hand is acceptable here because Task 1 Step 4 already proved the file is idempotent.

- [ ] **Step 4: Commit**

```bash
git add scripts/test-sanitization-gate.ps1
git commit -m "test(security): prove the sanitization gate excludes pending, blocked and NULL rows"
```

---

## Follow-on work

This plan is complete and independently shippable. The remaining design subsystems:

| Plan | Subsystem | Blocked on |
|---|---|---|
| **018 (this)** | memory-lane defects and the sanitization gate | - |
| 2 | `ocr-service` container + extraction cache | BBox storage decision (design 9, item 2) |
| 3 | API routes, vault, `pacgate_restore`, MCP tools | restore-authorisation decision (9, item 3); partial-job semantics (9, item 4) |
| 4 | deer-flow sanitizer agent + review panel | plans 2 and 3 |

**What plan 3 must build on top of this one:** `pacgate_extract_document`, `pacgate_sanitize_text`, `pacgate_sanitize_document`, `pacgate_verify_sanitized`, `pacgate_restore`, and the call to `ChunkIngestor::mark_sanitized` (Task 6) after a `Verdict::Pass`. The ordering matters and is not enforced by this plan: **seal the ledger first, then promote.** A promoted chunk with no ledger row would claim sanitization with no evidence behind it.

## Contractual deliverables tracking

Design section 10 requires six artifacts. This plan contributes to two; the rest need plans 2-4.

| Required artifact | Covered by |
|---|---|
| 规则及上下文决策说明 | plan 017 Task 5 + Task 11 |
| 已覆盖与未覆盖格式清单 | **plan 2** |
| 合成测试用例 | plan 017; Task 8 here (exclusion proof) |
| 漏报与误报记录 | plan 017 Task 5; recall harness is **plan 3** |
| 本地映射与还原说明 | plan 017 Tasks 6, 7, 12 |
| 出站边界验证结果 | plan 017 Task 9; **Task 8 here is the first real boundary assertion** |

**Layer-separated reporting (spec 9 L171).** This plan's evidence is the **storage and retrieval layer** row: `cargo test -p pacgate-rag` plus `scripts/test-sanitization-gate.ps1`. Do not present it as end-to-end coverage; the rule layer is plan 017 and the cloud boundary is plan 3.

## Known limitations of this plan

- **A document's other versions stay `pending`.** `mark_sanitized` is scoped to one `document_id`, and `documents.version` means a matter can hold several. Sanitizing v2 does not touch v1. That is correct fail-closed behaviour but means an older version cannot be retrieved until it is separately sanitized - which may surprise a user searching for a superseded draft.
- **`memory.json` has no server-side sanitization check.** Task 3 added concurrency control, not a content gate. The endpoint still accepts whatever the adapter POSTs. Adding a gate requires the sanitizer's detector set to be callable from `pacgate-api`, which is plan 3. Until then, the memory lane's protection is the convention recorded in design section 5.1, not enforcement.
- **OpenViking remains ungated.** Nothing in this plan touches it, because deer-flow holds its own credential and calls it directly. Design section 9 item 5 records the choice: accept that as a limitation, or route writes through pacgate-mcp. This plan does not decide it.
- **`If-Match` is opt-in, so an unaware caller can still lose an update.** Task 3 allows an unconditional write to keep the existing adapter working, and Task 4 makes that adapter opt in. A third caller that sends no `If-Match` reintroduces the defect. Making it mandatory is the stronger fix and is deliberately deferred because it would break the current adapter in the same commit that fixes it.
- **The identity check is available, not yet wired.** Task 7 provides `same_scope` / `assert_document_scope`, but no call site uses them yet. Wiring them into the search and ingest paths needs the path-derived scope alongside the column-derived one, which is plan 3's route layer.
