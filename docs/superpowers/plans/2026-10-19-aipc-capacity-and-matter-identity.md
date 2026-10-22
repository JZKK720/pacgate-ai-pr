# AIPC Capacity and Matter Identity - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 16 GB AIPCs unable to be handed a model they cannot run, and make `matters.external_key` repairable so cross-machine sync stops relying on a name that is not unique.

**Architecture:** Two defects, both already measured, both currently only *reported* rather than *prevented*. (1) The capacity gate already knows which models cannot fit a 16 GB card and already has a working `-Strict` mode that fails on them, but it is registered in the suite's `$measurements` list, which by design ignores the exit code, so the knowledge exists and enforces nothing. (2) `POST /api/matters` accepts `external_key`, but the router serves only GET, POST and DELETE on `/api/matters/:id` - there is no route that can change the key afterwards - so the 59 matters with a NULL key can never be repaired, and cross-machine import must fall back to matching on `matters.name`, which occurs 50 times on this box for one name.

**Tech Stack:** Rust (pacgate-api axum handlers, pacgate-tenant sqlx/PostgreSQL), YAML config (`deer-flow-config.yaml`), PowerShell gate scripts (PS 5.1 compatible - the AIPCs ship Windows PowerShell 5.1), Docker Compose.

**Spec:** `deploy/AIPC-PERF-ANALYSIS-2026-10-17.md` (Part 1 sections 5, 7, 9) and `deploy/CROSS-STACK-AUTH-AND-SYNC-ANALYSIS-2026-10-19.md` (sections 3a, 5, 8d).

## Verified starting state (measured 2026-10-19, before any task)

Do not re-derive these; they are the facts the plan is built on.

| Fact | Value |
|---|---|
| `test-aipc-capacity-fit.ps1 -Strict` | **Already implemented** (line 55). Exits `1` today with 4 failures. |
| Over-cap ACTIVE roster entries | `nemotron-3.5-lightning-30b-local` (25.0 GB), `ornith-1.5-35b-local` (22.0 GB) |
| Over-cap REFERENCED pre-pull tags | `qwen3.8:27b-mtp-q4_K_M` (17.0 GB), `ornith-1.5:35b` (22.0 GB), `nemotron-3.5-lightning:30b-a3b` (25.0 GB) |
| `PACGATE_MODEL_MID` default | `qwen3.8:27b-mtp-q4_K_M` (17.0 GB) in both compose files (prod:121, bundle:101) |
| Capacity script registration | `$measurements` array (line ~519), which ignores exit codes |
| Gate invocation | `& $psLauncher -NoProfile -File $s` with **no arguments** (line ~591) |
| `PATCH /api/matters/:id` | **Does not exist.** `lib.rs` has GET, POST, DELETE only. |
| `matters.external_key` | Populated on 0 of 59 rows; partial unique index exists |
| Duplicate matter names | One name occurs 50 times (`Sanitizer E2E`, one per e2e run) |
| `deploy/client-bundle/` in images | **No.** No Dockerfile COPYs it, so config changes need no rebuild. |

## Global Constraints

- **No new YAML/JSON parser dependency.** The gates run on Windows PowerShell 5.1, which has no `ConvertFrom-Yaml`. Follow `scripts/test-auxiliary-model-pins.ps1`: a line-oriented reader for exactly the constructs needed.
- **Gates must be red-checked.** Every new gate is proven to fail on the defect it describes before it is committed.
- **Exit codes:** `0` = pass, `1` = a real defect, `2` = cannot check (stack down / file absent). A clean machine is never a false red.
- **Deploy path is `origin/main` then `git pull --ff-only` via `install.ps1 -Update`.** Config and gate changes reach clients without a rebuild; Rust changes require one.
- **Never delete a client's data.** No task deletes a matter, a document, or a row the user created.
- **No em-dashes in visible copy** (repo rule). Use hyphens.
- **`matters.external_key` is not a secret** and is not bound to any volume, so it is safe to write.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/test-aipc-capacity-fit-strict.ps1` | **Create.** Thin wrapper so the suite can run the existing gate in its `-Strict` mode. |
| `scripts/run-all-checks.ps1` | **Modify.** Move capacity from `$measurements` to `$gates`. |
| `scripts/check-installer-syntax.ps1` | **Modify.** Register the wrapper for parse checking. |
| `deploy/client-bundle/deer-flow-config.yaml` | **Modify.** Comment out the two over-cap roster entries. |
| `deploy/client-bundle/compose.prod.yaml`, `compose.bundle.yaml` | **Modify.** `PACGATE_MODEL_MID` moves off the 17.0 GB tag. |
| `deploy/client-bundle/ollama-models.txt` | **Modify.** Drop tags no active surface references. |
| `pacgate-ai/crates/pacgate-tenant/src/error.rs` | **Modify.** Map the partial-unique violation to a distinct variant. |
| `pacgate-ai/crates/pacgate-tenant/src/tenant_store.rs` | **Modify.** Add `update_external_key`. |
| `pacgate-ai/crates/pacgate-api/src/matters.rs` | **Modify.** Add the `PATCH` handler. |
| `pacgate-ai/crates/pacgate-api/src/lib.rs` | **Modify.** Route it. |
| `pacgate-ai/crates/pacgate-api/tests/integration.rs` | **Test.** Four assertions. |
| `scripts/sync-pacgate-matters.ps1` | **Modify.** Add `BackfillKeys`. |
| `scripts/test-sync-capability.ps1` | **Modify.** Assert the backfill exists and cannot fabricate a key. |
| `deploy/client-bundle/README-client.md` | **Modify.** Operator-facing explanation. |

---

### Task 1: Remove the two roster entries that cannot run on an AIPC

`nemotron-3.5-lightning:30b-a3b` is 25.0 GB and `ornith-1.5:35b` is 22.0 GB against a 16 GB card. Both are offered in the shipped picker. They fit the 96 GiB dev box, which is exactly why they survived review.

**Files:**
- Modify: `deploy/client-bundle/deer-flow-config.yaml` (the `models:` block, lines ~44-140)
- Modify: `deploy/client-bundle/compose.prod.yaml:121`, `deploy/client-bundle/compose.bundle.yaml:101`
- Test: `scripts/test-aipc-capacity-fit.ps1 -Strict`, `scripts/test-auxiliary-model-pins.ps1`, `scripts/test-model-roster-consistency.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: a roster whose every active entry is at or under 16 GB, with `models[0]` = `gemma4-12b-local` (7.2 GB). Auxiliary lanes (`title`, `memory`, `summarization`) still converge on the single 7.2 GB `gemma4:12b-it-qat` tag.

- [ ] **Step 1: Record the baseline**

```powershell
pwsh -File scripts/test-aipc-capacity-fit.ps1 -Strict; "exit=$LASTEXITCODE"
```

Expected now: exit `1`, `FAIL: 4 model(s) in an unconditional path exceed the 16 GB AIPC budget.` This is the red state every later step works against.

- [ ] **Step 2: Comment out `nemotron-3.5-lightning-30b-local`**

In `deploy/client-bundle/deer-flow-config.yaml`, wrap that entry in comments with the measurement recorded, matching the house style already used for the demoted `qwen3.8-27b-local` entry:

```yaml
  # Pacgate 2026-10-19: WITHDRAWN from the shipped picker - 25.0 GB against a
  # 16 GB AIPC card. On the dev box (96 GiB) it is excellent; on a client AIPC it
  # cannot fit, so Ollama spills to CPU and the run presents as a hang with no
  # error. Measured residency 25.0 GB (scripts/test-aipc-capacity-fit.ps1). Kept
  # here, commented, so a larger machine can restore it deliberately.
  # - name: nemotron-3.5-lightning-30b-local
  #   display_name: Nemotron 3.5 Lightning 30B (Local)
  #   description: 1M-token MOE. Requires 25 GB VRAM - NOT available on a 16 GB AIPC.
  #   use: langchain_openai:ChatOpenAI
  #   model: nemotron-3.5-lightning:30b-a3b
  #   api_key: ollama
  #   base_url: http://host.docker.internal:11434/v1
  #   max_tokens: 8192
  #   temperature: 0.1
  #   supports_thinking: true
  #   stream_chunk_timeout: 300
```

Apply the same treatment to `ornith-1.5-35b-local`, citing 22.0 GB.

**Critical:** the first ACTIVE entry in `models:` becomes `models[0]`, which is what an unpinned lane falls back to. After this edit, read the top of the list and confirm `models[0]` is `gemma4-12b-local`. If a large tag becomes `models[0]`, every unpinned lane loads it on each new thread - that was the 2026-10-17 defect.

- [ ] **Step 3: Point `PACGATE_MODEL_MID` at a tag that fits**

`qwen3.8:27b-mtp-q4_K_M` is 17.0 GB and is the Mid workflow tier default in both compose files. In **both** `compose.prod.yaml` (line 121) and `compose.bundle.yaml` (line 101):

```yaml
      # Was qwen3.8:27b-mtp-q4_K_M (17.0 GB), which cannot load on a 16 GB AIPC
      # card: the tier would spill to CPU and present as a stall. 9B at 6.6 GB
      # keeps the Mid tier usable on the hardware we ship to. Override in .env on
      # a machine that has the VRAM.
      PACGATE_MODEL_MID: ${PACGATE_MODEL_MID:-ornith-1.5:9b}
```

- [ ] **Step 4: Run the gate until it is green**

```powershell
pwsh -File scripts/test-aipc-capacity-fit.ps1 -Strict; "exit=$LASTEXITCODE"
```

Expected: exit `0`.

If it still fails on a **pre-pull** tag (check B3), that tag is still referenced by something. Find the reference before touching `ollama-models.txt`:

```powershell
Select-String -Path deploy\client-bundle\*.yaml,deploy\client-bundle\*.txt -Pattern '<tag>'
```

Remove a tag from `ollama-models.txt` **only** when the search shows no remaining reference. The gate's own B4 check catches the opposite mistake (a commented roster entry still being pre-pulled).

- [ ] **Step 5: Run the other two roster gates**

```powershell
pwsh -File scripts/test-auxiliary-model-pins.ps1
pwsh -File scripts/test-model-roster-consistency.ps1
```

Expected: auxiliary pins `RESULT: N of N checks passed`; roster consistency `RESULT: 13 of 13 checks passed`.

If roster consistency fails, a tier names a tag the pre-pull list no longer has. Prefer restoring the tag to `ollama-models.txt` over changing the tier, then decide separately whether the tag is worth the disk.

- [ ] **Step 6: Commit**

```bash
git add deploy/client-bundle/deer-flow-config.yaml deploy/client-bundle/compose.prod.yaml deploy/client-bundle/compose.bundle.yaml deploy/client-bundle/ollama-models.txt
git commit -m "fix(roster): withdraw the two models that cannot fit a 16 GB AIPC

nemotron-3.5-lightning:30b-a3b is 25.0 GB and ornith-1.5:35b is 22.0 GB, both
offered in the shipped picker against a 16 GB card. They fit the 96 GiB dev box,
which is exactly why they survived review. Commented out with the measurement
recorded so a larger machine can restore them deliberately.

PACGATE_MODEL_MID moves off qwen3.8:27b-mtp-q4_K_M (17.0 GB) to ornith-1.5:9b
(6.6 GB) in both compose files."
```

---

### Task 2: Make the capacity gate actually enforce

`-Strict` already works. The gate is registered in `$measurements`, and that list ignores exit codes by design, so a release can ship a 25 GB default and the suite still reports green. That is the whole defect: the knowledge exists, the enforcement does not.

**Files:**
- Create: `scripts/test-aipc-capacity-fit-strict.ps1`
- Modify: `scripts/run-all-checks.ps1` (remove from `$measurements` around line 519; add to `$gates` after the `test-sync-capability` line)
- Modify: `scripts/check-installer-syntax.ps1` (add the wrapper to `$targets`)

**Interfaces:**
- Consumes: a compliant roster from Task 1.
- Produces: `scripts/test-aipc-capacity-fit-strict.ps1`, which takes no arguments and exits with the `-Strict` verdict.

- [ ] **Step 1: Confirm the gate is green before promoting it**

```powershell
pwsh -File scripts/test-aipc-capacity-fit.ps1 -Strict; "exit=$LASTEXITCODE"
```

Expected: `exit=0`. Do not promote a failing gate.

- [ ] **Step 2: Create the wrapper**

The suite invokes every gate as `& $psLauncher -NoProfile -File $s` with no arguments, and `test-aipc-capacity-fit.ps1` only fails when given `-Strict`. Create `scripts/test-aipc-capacity-fit-strict.ps1`:

```powershell
# Thin wrapper so the suite can run the capacity gate in SHIPPING mode.
#
# WHY THIS EXISTS. run-all-checks.ps1 invokes each gate as
# `& $psLauncher -NoProfile -File $s` with no arguments, but
# test-aipc-capacity-fit.ps1 only fails when given -Strict. Registering the
# capacity script itself in $gates would therefore keep passing while the dev
# box's over-cap models shipped. The wrapper is the argument.
#
# The interactive command (`test-aipc-capacity-fit.ps1` with no flag) stays
# advisory on purpose: the 96 GiB dev box can run all of it, and a developer
# should not be blocked from seeing the full table.

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test-aipc-capacity-fit.ps1') -Strict
exit $LASTEXITCODE
```

- [ ] **Step 3: Prove the wrapper reproduces the strict verdict**

```powershell
pwsh -File scripts/test-aipc-capacity-fit-strict.ps1; "wrapper exit=$LASTEXITCODE"
```

Expected: `wrapper exit=0`. Then red-check it: temporarily revert one roster entry to its pre-Task-1 form, re-run (expect `exit=1`), and restore it. Do not commit the temporary revert.

- [ ] **Step 4: Remove it from `$measurements`**

Delete the line `'scripts/test-aipc-capacity-fit.ps1'` from the `$measurements = @(` array in `scripts/run-all-checks.ps1`.

- [ ] **Step 5: Add it to `$gates`**

After the `$gates += 'scripts/test-sync-capability.ps1'` line:

```powershell
# AIPC CAPACITY, promoted from a measurement to a gate 2026-10-19.
#
# It was registered non-blocking because "which models the shipped roster offers
# is a commercial decision". That decision is now made: a model larger than the
# target card cannot ship as a default. On a 16 GB AIPC an over-cap tag does not
# error - Ollama spills to CPU and the run presents as a hang, which is the exact
# symptom that made the AIPCs look broken.
#
# The script is not registered directly: the suite passes no arguments, and it
# only fails under -Strict. The wrapper supplies the switch.
$gates += 'scripts/test-aipc-capacity-fit-strict.ps1'
```

- [ ] **Step 6: Register the wrapper for syntax checking**

In `scripts/check-installer-syntax.ps1`, add `'scripts/test-aipc-capacity-fit-strict.ps1'` to the `$targets` array next to the existing `'scripts/test-aipc-capacity-fit.ps1'`.

- [ ] **Step 7: Run the suite**

```powershell
pwsh -File scripts/run-all-checks.ps1
```

Expected: `test-aipc-capacity-fit-strict.ps1` appears in the gate list and passes; `test-aipc-capacity-fit.ps1` no longer appears under Measurements; the gate count is one higher than before.

- [ ] **Step 8: Commit**

```bash
git add scripts/run-all-checks.ps1 scripts/check-installer-syntax.ps1 scripts/test-aipc-capacity-fit-strict.ps1
git commit -m "test(capacity): enforce the roster fit limit in the suite

-Strict already worked; the gate was registered in the measurements list, which
ignores exit codes by design, so a release could ship a 25 GB default and report
green. Promoted to the gates list behind a thin wrapper because the suite passes
no arguments."
```

---

### Task 3: Give matters a repairable external key

`POST /api/matters` accepts `external_key`, but nothing can change it afterwards, so the 59 matters with a NULL key can never be repaired.

**Files:**
- Modify: `pacgate-ai/crates/pacgate-tenant/src/error.rs` (the `From<sqlx::Error>` impl, line 24)
- Modify: `pacgate-ai/crates/pacgate-tenant/src/tenant_store.rs` (after `delete`, ~line 206)
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs` (after `get_matter`, ~line 256)
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs` (route near line 82)
- Test: `pacgate-ai/crates/pacgate-api/tests/integration.rs`

**Interfaces:**
- Produces: `PATCH /api/matters/:id` taking `{"external_key": "<string>"}` and returning the updated `Matter` JSON. `200` success; `404` when the matter is not in the caller's tenant; `409` when another matter in the tenant uses that key; `403` when the caller is not a platform admin. A blank key clears the field.
- Produces: `MatterStore::update_external_key(&self, tenant_id: &TenantId, matter_id: &MatterId, key: Option<&str>) -> Result<Matter, TenantError>`.
- Produces: `TenantError::ExternalKeyConflict(String)`.

- [ ] **Step 1: Write the failing integration test**

Append to `pacgate-ai/crates/pacgate-api/tests/integration.rs`. Reuse the app-and-token construction the existing matter test uses at ~line 385 - copy its setup lines rather than inventing a helper:

```rust
// ── PATCH /api/matters/:id - external_key is the cross-machine identity ──
//
// Without this route a matter's external_key is write-once: it can only be set
// at creation, so a matter created before the column existed can never be
// repaired. Cross-machine import then has to match on `name`, which is not
// unique (50 matters share one name on the dev box), so documents can attach to
// the wrong matter. These assertions pin the four behaviours that make it safe.
#[tokio::test]
async fn patch_matter_sets_external_key_and_rejects_duplicates() {
    // (setup: copy the app + auth-token construction used by the matter test above)
    // let (app, token) = ...;

    // Create two matters WITHOUT keys - they stand in for the 59 legacy rows.
    let mut ids: Vec<String> = Vec::new();
    for name in ["Patch Target A", "Patch Target B"] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/matters")
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(serde_json::json!({ "name": name }).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "matter creation should succeed");
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v["external_key"].is_null(), "a matter created without a key must have a null key");
        ids.push(v["id"].as_str().unwrap().to_string());
    }

    // 1. A free key -> 200 and the key comes back.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/matters/{}", ids[0]))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(r#"{"external_key":"MATTER-A-001"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "setting a free key must succeed");
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["external_key"].as_str(), Some("MATTER-A-001"));

    // 2. The same key on the other matter -> 409, NOT 500. The partial unique
    // index (tenant_id, external_key) enforces this, and a raw sqlx error would
    // surface as a 500 that reads like a server fault.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/matters/{}", ids[1]))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(r#"{"external_key":"MATTER-A-001"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT, "a duplicate key must be 409");

    // 3. A blank key clears the field instead of storing whitespace as identity.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/matters/{}", ids[1]))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(r#"{"external_key":"   "}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "a blank key is a clear, not an error");
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert!(v["external_key"].is_null(), "a whitespace key must be stored as null, never as '   '");

    // 4. An unknown id is a 404, matching get_matter.
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PATCH")
                .uri(format!("/api/matters/{}", uuid::Uuid::new_v4()))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(r#"{"external_key":"NOPE"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND, "an unknown id must be 404");
}
```

- [ ] **Step 2: Run the test to verify it fails**

```powershell
cargo test -p pacgate-api --test integration patch_matter_sets_external_key_and_rejects_duplicates
```

Expected: FAIL on the first PATCH assertion with `405 Method Not Allowed` where `200` was expected. A 405 (not a connection error) confirms the test reaches the router and the route is genuinely absent.

- [ ] **Step 3: Add the conflict variant**

In `pacgate-ai/crates/pacgate-tenant/src/error.rs`, add to `enum TenantError`:

```rust
    #[error("external key already in use: {0}")]
    ExternalKeyConflict(String),
```

Replace `impl From<sqlx::Error>`:

```rust
impl From<sqlx::Error> for TenantError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => TenantError::MatterNotFound("row not found".into()),
            // The partial unique index idx_matters_tenant_external_key enforces
            // (tenant_id, external_key) WHERE external_key IS NOT NULL. Without
            // this arm the caller sees a generic database error and the API
            // answers 500, which reads as "the server is broken" rather than
            // "that key is taken".
            sqlx::Error::Database(ref db)
                if db.constraint() == Some("idx_matters_tenant_external_key") =>
            {
                TenantError::ExternalKeyConflict("external_key already used in this tenant".into())
            }
            other => TenantError::Database(other.to_string()),
        }
    }
}
```

- [ ] **Step 4: Add the store method**

In `pacgate-ai/crates/pacgate-tenant/src/tenant_store.rs`, inside the `MatterStore` impl after `delete`:

```rust
    /// Set or clear a matter's external key.
    ///
    /// Scoped by tenant in the WHERE clause rather than by a prior read: a matter
    /// belonging to another tenant matches zero rows and reports NotFound, so a
    /// caller cannot probe for ids outside their tenant by watching for a
    /// different error.
    ///
    /// A duplicate key arrives as ExternalKeyConflict (see the From<sqlx::Error>
    /// arm) so the API can answer 409 instead of 500.
    pub async fn update_external_key(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        key: Option<&str>,
    ) -> Result<Matter, TenantError> {
        let row = sqlx::query(
            "UPDATE matters SET external_key = $1, updated_at = NOW()
             WHERE id = $2 AND tenant_id = $3
             RETURNING id, tenant_id, name, description, external_key, persona_id, created_by, created_at, updated_at",
        )
        .bind(key)
        .bind(matter_id.0)
        .bind(tenant_id.0)
        .fetch_one(&self.db)
        .await?;

        Ok(Matter {
            id: MatterId(row.get("id")),
            tenant_id: TenantId(row.get("tenant_id")),
            name: row.get("name"),
            description: row.get("description"),
            external_key: row.get("external_key"),
            persona_id: row.get("persona_id"),
            created_by: UserId(row.get("created_by")),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        })
    }
```

`fetch_one` maps `RowNotFound` to `MatterNotFound` through the existing `From` impl, which is the 404 path. Match the surrounding file's imports for `MatterId`, `TenantId`, `UserId` and `Row::get`.

- [ ] **Step 5: Add the handler**

In `pacgate-ai/crates/pacgate-api/src/matters.rs`, after `get_matter`:

```rust
#[derive(Debug, Deserialize)]
pub struct PatchMatterRequest {
    /// A missing field and an explicit null both mean "clear the key".
    pub external_key: Option<String>,
}

/// Set a matter's cross-machine identity.
///
/// WHY THIS EXISTS (2026-10-19). POST /api/matters accepts external_key, but
/// nothing could change it afterwards: this router served only GET, POST and
/// DELETE on /api/matters/:id. So the 59 matters created before the column
/// existed were permanently NULL-keyed, and cross-machine import had to match on
/// `name` - which is not unique (one name occurs 50 times on the dev box), so
/// documents could attach to the wrong matter. A write-once identity field is not
/// an identity field.
///
/// Deliberately narrow: only external_key. Renaming, re-describing and
/// re-persona are separate concerns with their own audit requirements.
pub async fn patch_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):          Path<String>,
    Json(req):         Json<PatchMatterRequest>,
) -> Result<Json<Matter>, ApiError> {
    // Admin only: the key is what qm and the sync tool bind a matter to, so any
    // attorney could otherwise capture another matter's inbound integration
    // traffic by claiming its key.
    if claims.system_role != crate::PLATFORM_ADMIN_ROLE {
        return Err(ApiError::forbidden(
            "Setting a matter external key requires the admin role.",
        ));
    }

    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    // Trim, and treat an all-whitespace key as an explicit clear rather than
    // storing "   " as an identity.
    let key = req.external_key.as_deref().map(str::trim).filter(|k| !k.is_empty());

    let matter = state
        .matter_store
        .update_external_key(&tenant_id, &matter_id, key)
        .await
        .map_err(|e| match e {
            TenantError::MatterNotFound(_) => ApiError::not_found("matter not found"),
            TenantError::ExternalKeyConflict(_) => ApiError::conflict(
                "another matter in this tenant already uses that external key",
            ),
            other => ApiError::internal(other.to_string()),
        })?;

    Ok(Json(matter))
}
```

If `PLATFORM_ADMIN_ROLE` is not re-exported at the crate root, use the same path `auth.rs` uses in `create_user`.

- [ ] **Step 6: Route it**

In `pacgate-ai/crates/pacgate-api/src/lib.rs`, after the delete route for `/api/matters/:id`:

```rust
        .route("/api/matters/:id", patch(matters::patch_matter))
```

Extend the axum import at the top of the file to include `patch` alongside `delete`, `get` and `post`.

- [ ] **Step 7: Run the test to verify it passes**

```powershell
cargo test -p pacgate-api --test integration patch_matter_sets_external_key_and_rejects_duplicates
```

Expected: PASS (200, 409, 200-with-null, 404).

- [ ] **Step 8: Run the affected crates**

```powershell
cargo test -p pacgate-api -p pacgate-tenant
```

Expected: all pass. If the new enum variant breaks an exhaustive match elsewhere, map `ExternalKeyConflict` explicitly to `ApiError::conflict` there rather than adding a catch-all that hides future variants.

- [ ] **Step 9: Commit**

```bash
git add pacgate-ai/crates/pacgate-tenant/src/error.rs pacgate-ai/crates/pacgate-tenant/src/tenant_store.rs pacgate-ai/crates/pacgate-api/src/matters.rs pacgate-ai/crates/pacgate-api/src/lib.rs pacgate-ai/crates/pacgate-api/tests/integration.rs
git commit -m "feat(matters): PATCH /api/matters/:id to repair external_key

external_key could only be set at creation, so matters created before the column
existed were permanently NULL-keyed and cross-machine import had to match on a
name that is not unique. Adds an admin-only PATCH that sets or clears it, with a
409 for a duplicate (mapped from the partial unique index rather than surfacing
as a 500) and a 404 scoped to the caller's tenant."
```

---

### Task 4: Let the operator backfill keys from the sync tool

The route alone fixes nothing; someone has to run it.

**Files:**
- Modify: `scripts/sync-pacgate-matters.ps1` (params at lines 100-120; new branch before the `# EXPORT` section at line ~230)
- Modify: `scripts/test-sync-capability.ps1` (after the S4 block)

**Interfaces:**
- Consumes: `PATCH /api/matters/:id` from Task 3.
- Produces: `-Action BackfillKeys -KeyPrefix <string> [-NameFilter <wildcard>]` sets `external_key = "<prefix>-<zero-padded sequence>"` on matters whose key is NULL and whose name matches. `-WhatIf` lists the plan without changing anything.

The script already provides `Write-Step`, `Write-Ok`, `Write-Warn`, `Write-Bad`, `Write-Note`, `$script:failures`, `Get-Token`, `New-Headers` and `Get-Api` (lines 123-161) - use them, do not redefine them.

- [ ] **Step 1: Add the failing assertions**

In `scripts/test-sync-capability.ps1`, after the S4 block:

```powershell
# ── S6: the backfill path exists and cannot invent identity silently ──────
Write-Host ''
Write-Host 'S6  external-key backfill is available and explicit' -ForegroundColor Cyan
if ($src -notmatch 'BackfillKeys') {
    Write-Fail 'no BackfillKeys action - the NULL-keyed matters have no repair path'
}
else {
    Write-Pass 'exposes a BackfillKeys action'
}
if ($src -match 'BackfillKeys' -and $src -notmatch '\$KeyPrefix') {
    Write-Fail 'backfill has no explicit prefix - it would fabricate identity without operator intent'
}
else {
    Write-Pass 'backfill requires an operator-supplied prefix'
}
if ($src -match "-Method\s+'?Patch'?") {
    Write-Pass 'uses PATCH, matching the repair route'
}
else {
    Write-Fail 'backfill does not PATCH - it cannot set a key on an existing matter'
}
```

- [ ] **Step 2: Run it to verify it fails**

```powershell
pwsh -File scripts/test-sync-capability.ps1
```

Expected: exit `1`, `S6  no BackfillKeys action`.

- [ ] **Step 3: Widen the action set and add parameters**

Change the `-Action` parameter (line ~102):

```powershell
    [Parameter(Mandatory = $true)]
    [ValidateSet('Export', 'Import', 'BackfillKeys')]
    [string]$Action,
```

Add immediately after it:

```powershell
    # BackfillKeys only: prefix for generated keys, e.g. "PF" -> PF-0001.
    # Required, so identity is never invented without the operator naming it.
    [string]$KeyPrefix,

    # BackfillKeys only: limit to matters whose name matches this wildcard.
    [string]$NameFilter = '*',
```

- [ ] **Step 4: Add the branch**

Immediately before the `# EXPORT` section:

```powershell
# ===========================================================================
# BACKFILL KEYS
# ===========================================================================
if ($Action -eq 'BackfillKeys') {
    if ([string]::IsNullOrWhiteSpace($KeyPrefix)) {
        Write-Bad '-KeyPrefix is required for BackfillKeys (for example -KeyPrefix PF).'
        Write-Note 'Keys are never generated without an explicit prefix: silently inventing'
        Write-Note 'identity would make two machines disagree in a new way.'
        exit 1
    }

    Write-Step "Authenticating to $BaseUrl"
    $h = New-Headers (Get-Token)
    Write-Ok "authenticated as $Email"

    Write-Step 'Finding matters without an external key'
    # NOT wrapped in @(...): Invoke-RestMethod emits a JSON array as a single
    # object, so @( ) around the CALL nests it and .Count becomes 1. That exact
    # mistake already made a re-import create duplicate matters here.
    $all = Get-Api '/api/matters' $h
    if ($null -eq $all) { $all = @() }
    $unkeyed = @($all | Where-Object { (-not $_.external_key) -and $_.name -like $NameFilter })

    if ($unkeyed.Count -eq 0) {
        Write-Ok 'every matter in scope already has an external key'
        exit 0
    }
    Write-Ok "$($unkeyed.Count) matter(s) need a key"

    $seq = 0
    foreach ($m in ($unkeyed | Sort-Object created_at)) {
        $seq++
        $key = '{0}-{1:D4}' -f $KeyPrefix, $seq
        if ($PSCmdlet.ShouldProcess("matter '$($m.name)'", "set external_key=$key")) {
            try {
                $body = @{ external_key = $key } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($m.id)" -Method Patch `
                    -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                Write-Ok "'$($m.name)' -> $key"
            }
            catch {
                $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                Write-Bad "'$($m.name)' -> $key failed (HTTP $status): $($_.Exception.Message)"
            }
        }
    }

    Write-Step 'Backfill complete'
    Write-Note 'Keys are now stable across machines, so Import can match exactly.'
    if ($script:failures -gt 0) { exit 1 }
    exit 0
}
```

- [ ] **Step 5: Run the capability gate**

```powershell
pwsh -File scripts/test-sync-capability.ps1
```

Expected: exit `0`, S6 passing.

- [ ] **Step 6: Prove it works without touching real data**

```powershell
$pw = ((Select-String -Path 'deploy/client-bundle/.env' -Pattern '^PACGATE_API_PASSWORD=').Line -replace '^PACGATE_API_PASSWORD=','').Trim()
pwsh -File scripts/sync-pacgate-matters.ps1 -Action BackfillKeys `
    -BaseUrl http://localhost:8089/pacgate -Email admin@pacgate-law.com -Password $pw `
    -KeyPrefix TESTKEYS -WhatIf
```

Expected: lists the plan. Confirm nothing changed:

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -t -c "select count(*) from matters where external_key is not null;"
```

Expected: unchanged from before the `-WhatIf` run. **Do not** run it for real against client matters in this task - assigning identity is the owner's decision (Task 6 records it).

- [ ] **Step 7: Commit**

```bash
git add scripts/sync-pacgate-matters.ps1 scripts/test-sync-capability.ps1
git commit -m "feat(sync): -Action BackfillKeys to repair matters with no external key

The PATCH route alone fixes nothing; someone has to run it. Backfill requires an
explicit -KeyPrefix so identity is never fabricated, supports -WhatIf, can be
scoped by name, and never touches a matter that already has a key. The
capability gate now asserts the action exists, requires a prefix, and uses PATCH."
```

---

### Task 5: Tell the operator what changed

**Files:**
- Modify: `deploy/client-bundle/README-client.md`

- [ ] **Step 1: Add a capacity section**

After the "Switching models" section:

````markdown
### If a model does not fit

The shipped picker only offers models that fit a 16 GB card. Two large models
previously listed (a 25 GB 30B and a 22 GB 35B) are withdrawn because on an AIPC
they do not report an error - the machine loads them, spills to CPU, and the run
looks like a hang with no output. That is the symptom that made these machines
look broken.

If you add a model yourself, check it first:

```powershell
# from the repo root
.\scripts\test-aipc-capacity-fit.ps1
```

It reports each model's measured size against this machine's budget and says
whether it fits. A model that does not fit will not produce an error at runtime -
it will just be slow, or appear stuck.
````

- [ ] **Step 2: Add a matter identity section**

Under "Moving matters between machines":

````markdown
### Which matter is which

A matter's `external_key` is what makes it the *same* matter on two machines.
Without one, sync matches on the matter's name, and names are not unique (a test
fixture can create dozens with one name), so a document can attach to the wrong
matter.

Setting a key requires an admin. Preview first - `-WhatIf` changes nothing:

```powershell
.\scripts\sync-pacgate-matters.ps1 -Action BackfillKeys `
    -BaseUrl http://localhost:8089/pacgate -Email admin@pacgate-law.com `
    -Password '<admin password>' -KeyPrefix PF -WhatIf

# then scope it to one group of matters and apply
.\scripts\sync-pacgate-matters.ps1 -Action BackfillKeys `
    -BaseUrl http://localhost:8089/pacgate -Email admin@pacgate-law.com `
    -Password '<admin password>' -KeyPrefix PF -NameFilter 'Acme*'
```

Keys come from the prefix you supply (`PF-0001`, `PF-0002`, ...). The tool never
invents a key on its own: a made-up identity would make two machines disagree in
a new way. Choose a prefix that means something to your firm.
````

- [ ] **Step 3: Commit**

```bash
git add deploy/client-bundle/README-client.md
git commit -m "docs(client): explain the capacity limit and matter identity

Records that an over-cap model does not error - it spills to CPU and looks like
a hang - and that external_key is what makes a matter the same matter on two
machines."
```

---

### Task 6: Record the remaining owner decisions

Not codeable. Written down so the next session does not re-derive them.

**Files:**
- Modify: `deploy/AIPC-PERF-ANALYSIS-2026-10-17.md` (section 9)
- Modify: `deploy/CROSS-STACK-AUTH-AND-SYNC-ANALYSIS-2026-10-19.md` (section 8f)

- [ ] **Step 1: Replace the perf doc's section 9 body with a status table**

```markdown
## 9. Decisions - status after 2026-10-19

| # | Decision | Status |
|---|---|---|
| 1 | What those AIPCs actually run (44 vs 183 tools) | **OPEN.** Needs a measurement on a real AIPC. It cannot be settled from this repo. |
| 2 | Which model should be `models[0]` on a 16 GB card | **RESOLVED.** `gemma4-12b-local` (7.2 GB). The two over-cap entries are withdrawn and the capacity gate now blocks in the suite. |
| 3 | Whether to re-enable `tool_search` | **OPEN.** Worth -8,089 tokens per call, but the 2026-09-12 regression is real and only a live A/B on an AIPC can settle it. |

Also resolved: `PACGATE_MODEL_MID` no longer defaults to a 17 GB tag.
```

- [ ] **Step 2: Add a status note to the sync doc's section 8f**

Append to that list:

```markdown
Status after 2026-10-19: item 1 (`external_key` unpopulated) is now **repairable** -
`PATCH /api/matters/:id` exists and `sync-pacgate-matters.ps1 -Action BackfillKeys`
drives it, but assigning keys to real client matters remains the owner's decision.
Item 2 (the duplicate test fixtures) is unchanged and still the owner's call.
Items 3-5 are unchanged.
```

- [ ] **Step 3: Commit**

```bash
git add deploy/AIPC-PERF-ANALYSIS-2026-10-17.md deploy/CROSS-STACK-AUTH-AND-SYNC-ANALYSIS-2026-10-19.md
git commit -m "docs: mark which AIPC and sync decisions this work closed"
```

---

## Verification

After all tasks:

```powershell
pwsh -File scripts/run-all-checks.ps1
```

Expected: every gate passes, including the newly blocking `test-aipc-capacity-fit-strict.ps1`, with `test-origin-coherence.ps1` and `test-sync-capability.ps1` still green.

Confirm the two guarantees:

```powershell
# 1. No shipped model can strand a 16 GB AIPC.
pwsh -File scripts/test-aipc-capacity-fit-strict.ps1; "exit=$LASTEXITCODE"

# 2. The repair route is mounted and behind auth (401 without a token).
curl.exe -s -o NUL -w "%{http_code}`n" -X PATCH `
  -H "Content-Type: application/json" -d '{\"external_key\":\"x\"}' `
  http://localhost:8089/pacgate/api/matters/00000000-0000-0000-0000-000000000000
```

Expected: `exit=0`, and `401` for the unauthenticated PATCH.

Note: Task 3 changes Rust, so the shipped images no longer match the tree and the release-provenance gate will report the tag as stale until a version bump and rebuild. That is the correct signal, not a failure of this plan.

## Self-Review

**Spec coverage.** Perf doc section 7 (proposed gate) maps to Task 2 - and note the gate itself already existed, so the work is registration, not construction. Section 9 item 2 (`models[0]`) maps to Task 1. Section 9 items 1 and 3 are deliberately left OPEN and recorded in Task 6: the 44-versus-183 tool count needs a measurement on a real AIPC, and `tool_search` carries a documented 2026-09-12 regression that only a live A/B can settle, so implementing either would be guessing. Sync doc section 3a (natural keys) and 8d (`external_key` 0 of 59) map to Tasks 3 and 4.

**Correction made during review.** My first draft invented Task 1 as "add a `-Strict` switch". Reading the file showed `-Strict` already exists at line 55 and already exits 1 with four failures; the "Run with -Strict once that decision is made" line that misled me is the *non-strict* branch telling an operator how to escalate. The plan was rewritten: the real defect is registration in `$measurements`, and the real work is Tasks 1-2 as written here.

**Placeholder scan.** No TBD. Two conditionals name their exact fallback: "copy the setup lines the existing matter test uses" (Task 3 Step 1) and "use the same path `auth.rs` uses for `PLATFORM_ADMIN_ROLE`" (Task 3 Step 5). Task 1 Step 4 uses a search-before-delete check rather than guessing which pre-pull tags are still referenced.

**Type consistency.** `TenantError::ExternalKeyConflict` is defined in Task 3 Step 3 and matched in Step 5. `update_external_key` takes `Option<&str>` (Step 4) and is called with the trimmed `Option<&str>` (Step 5). `PatchMatterRequest.external_key: Option<String>` matches the `{"external_key":"..."}` bodies in the test. `-KeyPrefix` and `-NameFilter` are consistent across Tasks 4 and 5.

**Deliberately excluded.** Re-enabling `tool_search` (unproven, prior regression). Deleting the 50 duplicate test fixtures (owner's data decision). Resolving `qm.config.jsonc` versus `QM_PUBLIC_URL` authority (a design decision, already recorded in the sync doc).
