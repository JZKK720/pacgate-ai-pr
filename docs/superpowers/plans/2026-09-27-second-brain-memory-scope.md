# Second Brain: Scope the Memory Lanes, Then Gate Them - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the sanitizer's own persistent memory from becoming a sanitization bypass — by scoping what each lane may hold, enforcing that scope at the write path we own, and covering the native lane we do not.

**Architecture:** Three independently shippable steps in the order the user chose. **(3)** Add a content-scope check using the detectors that already exist, so "memory holds process, not matter facts" becomes mechanically testable rather than a comment. **(1)** Enforce it in `save_matter_memory`, mirroring how `kb_chunks` refuses to be searchable until `sanitized`. **(2)** Close the native deer-flow lane, which the adapter does **not** cover.

**Tech Stack:** Rust (`pacgate-api`, reusing `pacgate-redact` — already a dependency), Python (adapter unchanged), PowerShell gate. **No new dependencies, no new PII model.**

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` §5.2 (memory interface contract). Findings measured in `/memories/repo/second-brain-four-lanes.md`.

**Depends on:** P5 (`6d923e3`) — the guard, the atomic write and the revision are the foundation the gate sits on.

## Global Constraints

- **Do NOT build a PII model or add an ML dependency.** The scope check uses the detectors that already exist in `pacgate-redact`.
- **Do NOT gate on name detection.** The NER model catches `PersonName`/`OrgName`, and a memory summary legitimately contains "the user", "the firm". Gating on names would reject valid process summaries — a false-positive machine that gets disabled. Gate on **identifier classes** (things with checksums or unambiguous shapes) and on **size**.
- **Fail closed for identifiers, fail open for prose.** A detected identifier is a hard refusal. Prose is not. This asymmetry is the design, not an oversight.
- **Do NOT change the adapter.** `pacgate-adapters/python/.../storage.py` is correct; its 6 tests must keep passing untouched.
- **Do NOT make the revision or the atomic write worse.** Both were fixed in P5 and are load-bearing.
- **The existing round-trip contract must hold**: caller body fields survive untouched; only server-owned fields (`revision`) are added. An integration assertion depends on this.
- **`cargo` is NOT on PATH.** `& "$env:USERPROFILE\.cargo\bin\cargo.exe"` from `pacgate-ai/`.
- **The integration test needs `pacgate-test-postgres`.** Start it with `docker start pacgate-test-postgres` and confirm with `docker ps` (NOT `docker ps -a`, which prints port mappings for **exited** containers — that mistake cost a round already).
- **After any mutation, `git status --short`** and restore. `Move-Item` restores the backup's old mtime; touch it or cargo serves a stale binary.
- **A guard is only real where it can REJECT.** Every task's test must fail when the guard is removed. This codebase has already shipped one guard that was dead at three layers while every unit test passed.

---

## Measured findings this plan is built on

### F1 — four lanes, three isolation keys, one gated

| lane | key | writer | gated? | last write |
|---|---|---|---|---|
| RAG `kb_chunks` | tenant+matter | pacgate-api | **YES** | live |
| Matter memory | tenant+matter | pacgate-api | no → **this plan** | 09-20 |
| deer-flow memory *(adapter)* | tenant+matter | deer-flow → adapter → same endpoint | no → **this plan** | 09-20 |
| deer-flow memory *(native)* | **user+agent** | **deer-flow, direct** | no → **step 2** | 09-19 |
| OpenViking | account/peer/user | deer-flow + qm, direct | no — accepted | **09-26, live** |

### F2 — deer-flow's memory ALREADY routes through pacgate-api

```yaml
# deploy/client-bundle/deer-flow-config.yaml:262
memory:
  storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage
```

So step 1 covers the adapter lane **for free**. This corrects an earlier framing of
step 2 as "route deer-flow through pacgate-api" — that is already done.

The **native** lane is separate and proven by schema:
`data/deer-flow/users/<u>/agents/<agent>/memory.json` uses
`workContext`/`personalContext`/`topOfMind`/`recentMonths` (v1.0), not the
adapter's `facts[]`/`revision` (v2.0). Different writer.

### F3 — the lanes are currently CLEAN, so this is prevention not remediation

Ran the real `tier_one_detectors()` over all three file-lane files: **0 detections,
0 placeholders.** The content is narrated process:

> "The user performs data sanitization and redaction tasks, specifically managing
> document processing at various data levels (e.g., T3) within a professional firm
> environment."

**Do not claim a leak exists.** The risk is structural: the write path accepts
anything, so the first matter-fact summary enters an ungated store. That is why the
work is worth doing and why the plan must not overstate it.

### F4 — the live lane is the one we do not own

OpenViking has 5.1 MB written through 09-26. The file lanes are dormant since 09-20.
`pacgate-api` is not in OpenViking's write path at all (deer-flow holds its own
credential). So step 2 is explicitly a **decision**, not a fix: either disable the
native writer, or accept and audit.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-api/src/memory_scope.rs` | **New.** What the memory lanes may and may not hold, as a pure function. | Create |
| `pacgate-ai/crates/pacgate-api/src/lib.rs` | Module list + re-export | Modify |
| `pacgate-ai/crates/pacgate-api/src/matters.rs` | Enforce the scope in `save_matter_memory` | Modify |
| `pacgate-ai/crates/pacgate-api/tests/integration.rs` | End-to-end refusal proof | Modify |
| `deploy/pacgate-mcp/server.py` | Document the scope at the tool boundary | Possibly modify |
| `scripts/test-memory-scope.ps1` | Gate: the scope check is wired and load-bearing | Create |
| `scripts/run-all-checks.ps1` | Gate list | Modify |

`memory_scope.rs` is its own file because the rule is a **policy** that both the
handler and the tests must share, and because a policy buried in a handler is a
policy nobody can review.

---

### Step 3, Task 1: The scope rule as a pure function

**Files:**
- Create: `pacgate-ai/crates/pacgate-api/src/memory_scope.rs`
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs`

**Interfaces:**
- Consumes: `pacgate_redact::detect::tier_one_detectors()`, `pacgate_redact::detect::Detector` (both already dependencies of this crate).
- Produces:
  - `pub const MEMORY_MAX_BYTES: usize` — the payload ceiling.
  - `pub enum MemoryScopeViolation { Identifier { entity: String, count: usize }, TooLarge { bytes: usize, limit: usize } }`
  - `pub fn check_memory_scope(memory: &serde_json::Value) -> Result<(), MemoryScopeViolation>`

- [ ] **Step 1: Write the failing test**

Create `memory_scope.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn obj(json: &str) -> serde_json::Value {
        serde_json::from_str(json).expect("test fixture is valid JSON")
    }

    /// The rule this whole step exists to make mechanical: memory holds PROCESS,
    /// not matter facts. A process summary is prose about what was done.
    #[test]
    fn a_process_summary_is_allowed() {
        let m = obj(r#"{
            "version": "2.0",
            "facts": [
                {"category": "context", "content": "The user is sanitizing a document at level T3."}
            ],
            "user": {"topOfMind": {"summary": "Working through redaction for one matter."}}
        }"#);
        assert_eq!(check_memory_scope(&m), Ok(()), "narrated process must be allowed");
    }

    /// A real identifier is the thing that must NOT be stored here. A resident ID
    /// passes a checksum, so this is unambiguous - not a judgement call.
    #[test]
    fn a_checksum_valid_resident_id_is_refused() {
        let m = obj(r#"{"facts":[{"content":"Client ID 11010519491231002X on file"}]}"#);
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::Identifier { entity, count }) => {
                assert_eq!(entity, "CN_ID");
                assert_eq!(count, 1);
            }
            other => panic!("a resident ID must be refused, got {other:?}"),
        }
    }

    #[test]
    fn a_mobile_and_an_email_are_refused() {
        for (json, expect) in [
            (r#"{"facts":[{"content":"call 13812345678"}]}"#, "CN_MOBILE"),
            (r#"{"facts":[{"content":"mail a@b.com"}]}"#, "EMAIL"),
        ] {
            match check_memory_scope(&obj(json)) {
                Err(MemoryScopeViolation::Identifier { entity, .. }) => {
                    assert_eq!(entity, expect, "wrong entity for {json}")
                }
                other => panic!("expected a refusal for {json}, got {other:?}"),
            }
        }
    }

    /// The deliberate ASYMMETRY: a person NAME must NOT be refused. The NER model
    /// catches PersonName/OrgName, and a process summary legitimately says "the
    /// firm" or "the user". Gating on names would reject valid summaries and the
    /// gate would be disabled within a week.
    #[test]
    fn a_person_or_org_name_is_allowed_because_prose_needs_it() {
        let m = obj(r#"{"facts":[{"content":"The firm reviewed the matter with the user."}]}"#);
        assert_eq!(
            check_memory_scope(&m), Ok(()),
            "names are Tier-2 and must not gate this lane"
        );
    }

    /// Matter facts look like content. A memory lane holding a contract dump is
    /// out of scope regardless of whether any single value matches a pattern.
    #[test]
    fn an_oversized_payload_is_refused() {
        let big = "x".repeat(MEMORY_MAX_BYTES + 1);
        let m = obj(&format!(r#"{{"facts":[{{"content":"{big}"}}]}}"#));
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::TooLarge { bytes, limit }) => {
                assert!(bytes > limit, "{bytes} should exceed {limit}");
            }
            other => panic!("an oversized payload must be refused, got {other:?}"),
        }
    }

    /// The boundary is inclusive: a payload exactly at the limit is fine.
    #[test]
    fn a_payload_exactly_at_the_limit_is_allowed() {
        // Fill to exactly MEMORY_MAX_BYTES of serialised bytes.
        let mut m = obj(r#"{"facts":[]}"#);
        let overhead = serde_json::to_vec(&m).unwrap().len();
        let fill = MEMORY_MAX_BYTES - overhead;
        m["facts"] = serde_json::json!([{"content": "x".repeat(fill - 30)}]);
        let bytes = serde_json::to_vec(&m).unwrap().len();
        assert!(bytes <= MEMORY_MAX_BYTES, "fixture is {bytes}, over the limit");
        assert_eq!(check_memory_scope(&m), Ok(()));
    }

    /// A JSON string that merely CONTAINS a UUID or a long number is not an
    /// identifier. The detectors decide, not a shape heuristic - a shape scan
    /// already produced 1062 UUID matches in one ungated store.
    #[test]
    fn a_uuid_is_not_an_identifier() {
        let m = obj(r#"{"facts":[{"content":"document 1b3c2e48-22e1-4fcc-849a-8477d7196b19"}]}"#);
        assert_eq!(check_memory_scope(&m), Ok(()), "a UUID is an internal reference, not PII");
    }

    /// Counts must be reported, so a refusal is diagnosable rather than a bare no.
    #[test]
    fn multiple_identifiers_are_counted() {
        let m = obj(r#"{"facts":[{"content":"13812345678 and a@b.com"}]}"#);
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::Identifier { count, .. }) => {
                assert_eq!(count, 2, "both identifiers must be counted")
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib memory_scope 2>&1 | Out-String
```

Expected: FAIL to compile. Note the module must be declared (`pub mod memory_scope;` in `lib.rs`) or the file is not compiled and you get no test output at all.

- [ ] **Step 3: Implement**

Add above the test module in `memory_scope.rs`, and `pub mod memory_scope;` plus `pub use memory_scope::{check_memory_scope, MemoryScopeViolation, MEMORY_MAX_BYTES};` to `lib.rs`:

```rust
//! What the persistent-memory lanes may hold.
//!
//! The rule, in one line: **memory holds process, not matter facts.**
//!
//! Memory is conversational context - what was done, what is in flight, user
//! preferences about interaction. Matter facts (party names, identifiers, account
//! numbers) belong in the RAG lane, where `kb_chunks.sanitization_state` already
//! gates retrieval. A memory store that accepts matter facts becomes a second,
//! ungated copy of client data that a later chat turn can retrieve and feed back
//! to an LLM - a sanitization bypass in the sanitizer's own memory.
//!
//! ## The deliberate asymmetry
//!
//! Identifiers are refused; prose is not. Only classes with a checksum or an
//! unambiguous shape gate this lane - `CnResidentId`, `Uscc`, `CnMobile`,
//! `BankCard`, `Email` (the Tier-1 set `tier_one_detectors()` produces).
//!
//! **`PersonName`, `OrgName` and `Location` are NOT checked**, even though the NER
//! model can find them. A process summary legitimately contains "the firm", "the
//! user", "the client". Gating on names would reject valid summaries, and a gate
//! that fires on legitimate traffic gets disabled - which is how the guard in
//! `matters.rs` ended up dead at three layers while every test passed.
//!
//! Names in memory are a real, documented residual risk. They are accepted here on
//! the grounds that the alternative is a gate nobody keeps.

use pacgate_redact::detect::{tier_one_detectors, Detector};

/// Ceiling on a memory payload.
///
/// Matter facts look like *content*; process summaries do not. A memory document
/// holding a contract dump is out of scope even when no single value matches a
/// pattern, and size is the only check that sees that.
///
/// 64 KiB is roughly 30x the largest memory file observed on the dev box (2.5 KB),
/// so it is a boundary against a category error rather than a working constraint.
pub const MEMORY_MAX_BYTES: usize = 64 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum MemoryScopeViolation {
    /// A checksum- or shape-validated identifier was found. Hard refusal.
    Identifier { entity: String, count: usize },
    /// The payload is too large to be a process summary.
    TooLarge { bytes: usize, limit: usize },
}

/// Decide whether `memory` may be stored in a persistent-memory lane.
pub fn check_memory_scope(memory: &serde_json::Value) -> Result<(), MemoryScopeViolation> {
    let bytes = serde_json::to_vec(memory)
        .map_err(|_| MemoryScopeViolation::TooLarge { bytes: usize::MAX, limit: MEMORY_MAX_BYTES })?
        .len();
    if bytes > MEMORY_MAX_BYTES {
        return Err(MemoryScopeViolation::TooLarge { bytes, limit: MEMORY_MAX_BYTES });
    }

    // Scan the serialised text so nested fields are covered without walking the
    // tree by hand - a value hidden in `user.topOfMind.summary` counts the same as
    // one in `facts[]`.
    let text = serde_json::to_string(memory).unwrap_or_default();

    let detectors = tier_one_detectors();
    let mut count = 0usize;
    let mut first: Option<String> = None;
    for d in &detectors {
        // A detector error is a refusal, not a pass: we cannot assert scope with
        // no evidence. `detect` is deterministic and infallible for the Tier-1
        // set, so this arm is defensive.
        let found = d
            .detect(&text)
            .map_err(|_| MemoryScopeViolation::Identifier { entity: "detector-error".into(), count: 0 })?;
        for m in found {
            count += 1;
            if first.is_none() {
                first = Some(m.entity.code().to_string());
            }
        }
    }

    if count > 0 {
        return Err(MemoryScopeViolation::Identifier {
            entity: first.unwrap_or_else(|| "unknown".to_string()),
            count,
        });
    }
    Ok(())
}
```

- [ ] **Step 4: Run tests to verify they pass**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib memory_scope 2>&1 | Select-String -Pattern 'test result|FAILED|panicked' | Out-String
```

Expected: `test result: ok. 9 passed`.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/memory_scope.rs pacgate-ai/crates/pacgate-api/src/lib.rs
git commit -m "feat(api): define what the persistent-memory lanes may hold

The rule: memory holds PROCESS, not matter facts. A memory store that accepts
matter facts becomes a second, ungated copy of client data that a later chat turn
can retrieve and feed to an LLM - a sanitization bypass in the sanitizer's own
memory.

Deliberate asymmetry: identifiers are refused, prose is not. Only classes with a
checksum or an unambiguous shape gate this lane. PersonName/OrgName/Location are
NOT checked even though NER can find them, because a process summary legitimately
says 'the firm' and 'the user'. Gating on names would reject valid summaries, and
a gate that fires on legitimate traffic gets disabled - which is how the guard in
matters.rs ended up dead at three layers while every test passed.

Names in memory are a documented residual risk, accepted because the alternative
is a gate nobody keeps. Measured first: the lanes are currently CLEAN (0 detector
hits across all three files), so this is prevention, not remediation."
```

---

### Step 3, Task 2: Enforce the scope at the write path

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs`
- Test: same file

**Interfaces:**
- Consumes: `crate::check_memory_scope`, `crate::MemoryScopeViolation` (Task 1).
- Produces: `save_matter_memory` refuses out-of-scope content with **422 Unprocessable Entity**.

- [ ] **Step 1: Write the failing test**

Add to `matters.rs`'s test module:

```rust
    /// The scope rule must be ENFORCED, not merely defined. A correct
    /// `check_memory_scope` the handler never calls is the exact shape of the
    /// defect this codebase already shipped once: defined, unit-tested, called
    /// from nowhere.
    #[test]
    fn the_save_handler_enforces_the_memory_scope() {
        let prod = production_source();
        let save = &prod[prod
            .find("pub async fn save_matter_memory")
            .expect("save_matter_memory must exist")..];

        assert!(
            save.contains("check_memory_scope("),
            "save_matter_memory must CALL check_memory_scope"
        );
        // The refusal must be the 422 arm, not a 400 or a 500: the body is
        // well-formed JSON (not a bad request) and the server is not broken.
        assert!(
            save.contains("unprocessable"),
            "an out-of-scope memory must be refused with 422, not 400 or 500"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib the_save_handler_enforces 2>&1 | Out-String
```

Expected: FAIL with `save_matter_memory must CALL check_memory_scope`.

- [ ] **Step 3: Add the 422 constructor**

In `error.rs`, next to `conflict` and `service_unavailable`:

```rust
    /// 422 Unprocessable Entity - the request is well-formed but out of scope.
    ///
    /// Used for memory content that is not permitted in a persistent-memory lane.
    /// A 400 would be wrong (nothing is malformed) and a 500 would be wrong (the
    /// server is fine). 422 says exactly what happened: we understood it and
    /// refuse to store it.
    pub fn unprocessable(msg: impl Into<String>) -> Self {
        Self {
            status: StatusCode::UNPROCESSABLE_ENTITY,
            code: "unprocessable",
            message: msg.into(),
        }
    }
```

- [ ] **Step 4: Enforce in the handler**

In `save_matter_memory`, immediately after the `is_object` check and **before** any matter lookup or file access:

```rust
    // Scope check FIRST: before the matter lookup and before any filesystem
    // access, so a refused write cannot have touched anything.
    //
    // This is the mechanical half of "memory holds process, not matter facts". The
    // policy lives in memory_scope.rs; without this call it would be a comment.
    crate::check_memory_scope(&memory).map_err(|v| match v {
        crate::MemoryScopeViolation::Identifier { entity, count } => ApiError::unprocessable(format!(
            "memory may hold process, not matter facts: {count} {entity} identifier(s) found. \
             Matter facts belong in the RAG lane, which is sanitization-gated."
        )),
        crate::MemoryScopeViolation::TooLarge { bytes, limit } => ApiError::unprocessable(format!(
            "memory payload is {bytes} bytes, over the {limit}-byte limit: this looks like \
             content rather than a process summary"
        )),
    })?;
```

- [ ] **Step 5: Run tests to verify**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
& "$env:USERPROFILE\.cargo\bin\cargo.exe" clippy -p pacgate-api --all-targets 2>&1 | Select-String -Pattern '^error|Finished' | Out-String
```

Expected: all `test result: ok.`, clippy `Finished`.

- [ ] **Step 6: Negative-test the enforcement**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'
Copy-Item $f "$f.scopebak"
(Get-Content $f -Raw) -replace 'crate::check_memory_scope\(&memory\)', 'let _ = &memory; let _unused: Result<(), crate::MemoryScopeViolation> = Ok(()); let _ = |v: crate::MemoryScopeViolation| v; let _fake =' | Set-Content $f -Encoding UTF8
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib the_save_handler_enforces 2>&1 | Select-String -Pattern 'test result|FAILED' | Out-String
Move-Item "$f.scopebak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: `FAILED`. If it passes, the assertion is not checking the call site. If the mutation fails to compile, that is also acceptable evidence **only if** you confirm the replacement actually changed the file — check with `Select-String -Path $f -Pattern 'check_memory_scope'` first.

- [ ] **Step 7: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/matters.rs pacgate-ai/crates/pacgate-api/src/error.rs
git commit -m "feat(api): enforce the memory scope at the write path

check_memory_scope is now CALLED, and the check runs before the matter lookup and
before any filesystem access, so a refused write cannot have touched anything.

422 rather than 400 or 500: the body is well-formed JSON and the server is fine.
422 says exactly what happened - we understood it and refuse to store it.

This is the mechanical half of 'memory holds process, not matter facts'. Without
this call the policy in memory_scope.rs would be a comment, which is precisely how
the If-Match guard ended up dead at three layers while every unit test passed.

Negative-tested: cutting the call makes the enforcement assertion fail."
```

---

### Step 3, Task 3: Prove it end to end, and gate it

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/tests/integration.rs`
- Create: `scripts/test-memory-scope.ps1`
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: the running router harness in `integration.rs`, plus `pacgate-test-postgres`.
- Produces: an end-to-end refusal proof, and a gate.

- [ ] **Step 1: Add the end-to-end assertions**

In `integration.rs`, in `full_api_flow`, after the existing revision/409 assertions:

```rust
        // ── 6c. The memory SCOPE is enforced end to end ──
        //
        // Memory holds process, not matter facts. These assert the refusal through
        // the real router, because a policy that is only unit-tested is a policy
        // that can be unwired without anyone noticing.

        // A checksum-valid resident ID must be refused with 422.
        let with_id = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(r#"{"facts":[{"content":"Client ID 11010519491231002X"}]}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            with_id.status(),
            StatusCode::UNPROCESSABLE_ENTITY,
            "an identifier in memory must be refused with 422, not stored"
        );

        // A process summary must still be accepted - the gate must not fire on
        // legitimate traffic, or it gets disabled.
        let prose = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/matters/{matter_id}/memory"))
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .header("if-match", (revision + 1).to_string())
                    .body(Body::from(
                        r#"{"facts":[{"content":"The firm reviewed the matter with the user."}]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            prose.status(),
            StatusCode::OK,
            "a process summary must be accepted: a gate that fires on legitimate \
             traffic gets disabled"
        );
```

- [ ] **Step 2: Run it against the test Postgres**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker start pacgate-test-postgres
Start-Sleep -Seconds 6
docker ps --filter name=pacgate-test-postgres --format '{{.Status}}'   # must NOT be empty
Set-Location pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --test integration -- --ignored --test-threads=1 2>&1 | Select-String -Pattern 'test result|FAILED|422|process summary' | Out-String
```

Expected: `test result: ok. 2 passed`.

**If `docker ps` shows nothing, the database is not up** — `docker ps -a` printing a port mapping is NOT evidence, because it shows mappings for exited containers too. That mistake cost a round earlier in this work.

- [ ] **Step 3: Negative-test the end-to-end refusal**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'
Copy-Item $f "$f.e2escopebak"
# Neuter the scope check while keeping the call site textually present.
(Get-Content $f -Raw) -replace 'crate::check_memory_scope\(&memory\)\.map_err', 'Ok::<(), crate::MemoryScopeViolation>(()).map_err' | Set-Content $f -Encoding UTF8
Select-String -Path $f -Pattern 'Ok::<\(\), crate::MemoryScopeViolation>' | ForEach-Object { "mutation applied at L$($_.LineNumber)" }
Set-Location pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --test integration -- --ignored --test-threads=1 2>&1 | Select-String -Pattern 'test result|FAILED|must be refused with 422' | Out-String
Set-Location ..
Move-Item "$f.e2escopebak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: `FAILED` on the 422 assertion.

- [ ] **Step 4: Write the gate**

Create `scripts/test-memory-scope.ps1`:

```powershell
# Asserts the memory SCOPE rule is defined AND enforced AND still correctly shaped.
#
# WHY: this is the second guard in this subsystem to be at risk of the same
# failure - a correct rule that nothing calls. The If-Match guard was dead at three
# layers while six unit tests passed. A scope check is a comment until the handler
# calls it, and a scope check that refuses PROSE is a gate that gets disabled.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== memory scope ===' -ForegroundColor Cyan

$scopePath = 'pacgate-ai/crates/pacgate-api/src/memory_scope.rs'
if (-not (Test-Path $scopePath)) {
    Fail "memory_scope.rs not found: the scope rule is undefined"
}
else {
    $scope = Get-Content $scopePath -Raw
    $end = $scope.IndexOf('#[cfg(test)]')
    $scopeProd = if ($end -lt 0) { $scope } else { $scope.Substring(0, $end) }

    if ($scopeProd -match 'pub const MEMORY_MAX_BYTES') {
        Pass 'MEMORY_MAX_BYTES is defined'
    } else {
        Fail 'no MEMORY_MAX_BYTES: an oversized payload (matter content) cannot be refused'
    }
    if ($scopeProd -match 'pub fn check_memory_scope') {
        Pass 'check_memory_scope is defined'
    } else {
        Fail 'no check_memory_scope'
    }

    # The ASYMMETRY must stay: identifiers gate, names do not. If this ever starts
    # checking names, legitimate process summaries get refused and the gate dies.
    if ($scopeProd -match 'tier_one_detectors') {
        Pass 'the check uses the Tier-1 detectors (identifiers, not names)'
    } else {
        Fail 'the check does not use tier_one_detectors - if it moved to NER it would now refuse prose'
    }
    if ($scopeProd -match 'full_detectors|NerDetector') {
        Fail 'the scope check uses NER: it would refuse PersonName/OrgName and reject legitimate process summaries'
    } else {
        Pass 'the scope check does NOT use NER (prose stays allowed)'
    }
}

# The handler must CALL it, and refuse with 422.
$matters = Get-Content 'pacgate-ai/crates/pacgate-api/src/matters.rs' -Raw
$mEnd = $matters.IndexOf('#[cfg(test)]')
$mProd = if ($mEnd -lt 0) { $matters } else { $matters.Substring(0, $mEnd) }
$saveIdx = $mProd.IndexOf('pub async fn save_matter_memory')
if ($saveIdx -lt 0) {
    Fail 'cannot find save_matter_memory - the gate would pass vacuously'
}
else {
    $save = $mProd.Substring($saveIdx)
    if ($save -match 'check_memory_scope\(') {
        Pass 'save_matter_memory calls check_memory_scope'
    } else {
        Fail 'save_matter_memory does NOT call check_memory_scope - the rule is a comment, which is how the If-Match guard came to be dead at three layers'
    }
    if ($save -match 'unprocessable') {
        Pass 'an out-of-scope memory is refused with 422'
    } else {
        Fail 'save_matter_memory does not refuse with 422'
    }
    # Ordering: the scope check must precede any filesystem access.
    $scopeCall = $save.IndexOf('check_memory_scope(')
    $fsAccess = $save.IndexOf('std::fs::')
    if ($scopeCall -ge 0 -and $fsAccess -ge 0 -and $scopeCall -lt $fsAccess) {
        Pass 'the scope check runs BEFORE any filesystem access'
    } elseif ($scopeCall -ge 0 -and $fsAccess -lt 0) {
        Pass 'the scope check runs before any filesystem access (none in this handler)'
    } else {
        Fail 'the scope check runs AFTER a filesystem access - a refused write could have touched the file'
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-scope check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the memory scope rule is defined, enforced, and correctly asymmetric' -ForegroundColor Green
exit 0
```

- [ ] **Step 5: Run the gate and negative-test it**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-memory-scope.ps1
"clean exit=$LASTEXITCODE  (expect 0)"

$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'
Copy-Item $f "$f.gatebak"
(Get-Content $f -Raw) -replace 'crate::check_memory_scope\(&memory\)', 'let _skip_scope = (&memory); let _fake' | Set-Content $f -Encoding UTF8
& pwsh -NoProfile -File scripts/test-memory-scope.ps1 *> $null
"mutated exit=$LASTEXITCODE  (expect 1)"
Move-Item "$f.gatebak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: `0` then `1`, clean tree.

- [ ] **Step 6: Add to the runner**

In `scripts/run-all-checks.ps1`, after `'scripts/test-memory-guard.ps1'`:

```powershell
    # Asserts the memory SCOPE rule is defined, enforced, and still correctly
    # asymmetric (identifiers gate, prose does not). The second guard in this
    # subsystem, so it gets the same treatment as the first: a source-level check,
    # because per-piece correctness already hid one broken chain here.
    'scripts/test-memory-scope.ps1'
```

- [ ] **Step 7: Run the runner and commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/run-all-checks.ps1 *> 'ms.txt'
"exit=$LASTEXITCODE"
Select-String -Path 'ms.txt' -Pattern 'memory-scope|ALL |FAILED' | ForEach-Object { $_.Line }
Remove-Item 'ms.txt' -Force

git add pacgate-ai/crates/pacgate-api/tests/integration.rs scripts/test-memory-scope.ps1 scripts/run-all-checks.ps1
git commit -m "test(api): prove the memory scope end to end, and gate the asymmetry

End-to-end through the real router: an identifier is refused with 422, and a
process summary is still ACCEPTED. The second assertion is the important one - a
gate that fires on legitimate traffic gets disabled, which is how the If-Match
guard came to be dead at three layers.

The gate checks the shape of the rule, not just its presence: it fails if the
scope check ever moves to NER, because that would start refusing PersonName and
OrgName and reject legitimate process summaries like 'the firm reviewed the
matter'.

Negative-tested: cutting the call makes both the gate and the end-to-end test fail."
```

---

### Step 1, Task 4: Decide the read-side and document the boundary

**Files:**
- Modify: `deploy/pacgate-mcp/server.py`
- Modify: `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the boundary documented where a caller and an operator will see it.

**Why a task:** the gates assert the code. They do not tell a future agent *why* the asymmetry exists, and the asymmetry looks like a bug to anyone who has not read this plan. Recording it at the tool boundary is what stops someone "fixing" it.

- [ ] **Step 1: Document the scope at the MCP tool boundary**

In `deploy/pacgate-mcp/server.py`, in the docstring of the tool that writes matter memory (find it with `Select-String -Pattern 'memory' server.py`), add:

```python
    SCOPE: this tool writes a persistent-memory lane, which holds PROCESS, not
    matter facts. Content containing identifiers (resident ID, USCC, mobile, bank
    card, email) is refused with 422, and oversized payloads are refused as
    content rather than summary. Matter facts belong in the RAG lane, which is
    sanitization-gated before retrieval.

    Person and organisation NAMES are deliberately NOT refused: a process summary
    legitimately says "the firm" or "the user", and a check that refused those
    would reject valid summaries. Do not "fix" that asymmetry - it is the reason
    the gate is still enabled.
```

- [ ] **Step 2: State it in the client deliverable**

Add to `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md`, after the coverage section:

```markdown
## Where client data may and may not be stored

The stack has four persistent-memory surfaces. Only one is sanitization-gated, and
the difference matters for how the system is deployed.

| surface | holds | gated? |
|---|---|---|
| Document index (RAG) | sanitized document text | **yes** — unsearchable until sanitized |
| Matter memory | process notes about a matter | **write-time scope check** |
| Agent memory | process notes about an agent's work | via matter memory |
| OpenViking | conversational context | **no** — accepted limitation |

**Matter memory and agent memory hold process, not matter facts.** Content that
contains an identifier is refused at write time with HTTP 422. Matter facts belong
in the document index, where the sanitization gate already applies. This is
enforced, not advisory — see `pacgate-ai/crates/pacgate-api/src/memory_scope.rs`.

Two things are deliberately **not** blocked, and should be stated rather than
implied away:

- **Names and organisations are allowed in memory.** A process summary says "the
  firm reviewed the matter", and refusing that would make the memory lane
  unusable. Person names in memory are therefore a residual risk that depends on
  the summaries themselves staying about *process*.
- **OpenViking is not gated at write time.** It is a third-party component
  (AGPL-3.0) reached directly by the research layer, and the accepted position is
  that it holds conversational context only. If a workflow is ever changed to push
  matter documents into it, that position no longer holds and would need
  revisiting.
```

- [ ] **Step 3: Verify the documented numbers against the code**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
"=== the scope limit in code ==="
Select-String -Path 'pacgate-ai\crates\pacgate-api\src\memory_scope.rs' -Pattern 'MEMORY_MAX_BYTES:\s*usize' | ForEach-Object { $_.Line.Trim() }
"=== the refusal status in code ==="
Select-String -Path 'pacgate-ai\crates\pacgate-api\src\error.rs' -Pattern 'UNPROCESSABLE_ENTITY' | ForEach-Object { $_.Line.Trim() }
"=== the gate count ==="
(Select-String -Path 'scripts\run-all-checks.ps1' -Pattern "^\s*'scripts/test-.*\.ps1'\s*$").Count
```

Expected: the limit, the status, and the gate count as documented. Fix the document if it disagrees with the code, never the reverse.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add deploy/pacgate-mcp/server.py deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md
git commit -m "docs: state the memory scope where callers and operators will see it

The two residual risks are stated rather than implied away: names ARE allowed in
memory (a process summary says 'the firm', and refusing that would make the lane
unusable), and OpenViking is NOT gated at write time because it is a third-party
component reached directly by the research layer.

Recording the asymmetry at the tool boundary is what stops a future reader
'fixing' it into a gate that refuses legitimate traffic."
```

---

### Step 2, Task 5: Close the native deer-flow lane (a DECISION, not a fix)

**Files:**
- Modify: `deploy/client-bundle/deer-flow-config.yaml` and/or `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md`
- Test: the check below

**Interfaces:**
- Consumes: nothing.
- Produces: either the native lane is disabled, or it is documented as an accepted residual with a detection check.

**This task is a decision and the plan does not pre-empt it.** Two defensible answers, and both are recorded so the choice is deliberate:

| option | pro | con |
|---|---|---|
| **A. Disable the native writer** | removes the ungated lane entirely | changes deer-flow behaviour; the user loses per-agent memory |
| **B. Accept + detect** | no behaviour change | an ungated store keeps growing |

**Do NOT pick silently.** Present both to the user with the measured facts and let them choose. The `agents_api: enabled: true` setting in `deer-flow-config.yaml` (plan 021) is what provisions agents and is adjacent to this — check whether the native writer can be turned off without breaking agent provisioning before recommending A.

- [ ] **Step 1: Determine whether the native lane is still written**

The files date from 09-19/09-20, so this lane may already be inactive. Establish before acting:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
"=== newest native-agent memory write ==="
Get-ChildItem 'deploy\client-bundle\data\deer-flow\users' -Recurse -Filter 'memory.json' -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 3 |
  ForEach-Object { "  {0}  {1}" -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.FullName.Replace((Get-Location).Path,'') }
"=== today's date for comparison: $(Get-Date -Format 'yyyy-MM-dd') ==="
```

If the newest write is days old and nothing re-creates the files, the lane is
inactive by observation, which is **evidence but not a guarantee** — nothing
prevents a future deer-flow version from writing it again.

- [ ] **Step 2: Add a detection check either way**

Regardless of A or B, a check that the native lane has not grown is worth having,
because B's whole premise is "we accept it and watch it":

```powershell
# Append to scripts/test-memory-guard.ps1 (do not create a second gate for this).
Write-Host ''
Write-Host '--- native deer-flow agent memory (ungated lane) ---' -ForegroundColor Cyan
$native = Get-ChildItem 'deploy/client-bundle/data/deer-flow/users' -Recurse -Filter 'memory.json' -ErrorAction SilentlyContinue
if ($native) {
    $newest = ($native | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $ageDays = [math]::Round(((Get-Date) - $newest).TotalDays, 1)
    Write-Host "  note  $($native.Count) native agent memory file(s); newest ${ageDays}d old" -ForegroundColor Yellow
    Write-Host "        This lane does NOT route through pacgate-api and is therefore NOT scope-gated." -ForegroundColor Yellow
    Write-Host "        Accepted residual (see /memories/repo/second-brain-four-lanes.md)." -ForegroundColor Yellow
    # A file written TODAY means something is now actively using an ungated lane:
    # that changes the risk shape and should be surfaced, not silently tolerated.
    if ($ageDays -lt 1) {
        Fail "a native agent memory file was written in the last 24h - the ungated lane is ACTIVE, so step 2's 'accepted residual' position no longer holds"
    }
}
else {
    Pass 'no native deer-flow agent memory files present'
}
```

- [ ] **Step 3: Present the decision**

Write both options into `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md` with the measured facts, and **ask the user which one to take**. Do not implement A without an explicit answer — it changes behaviour a user may rely on.

- [ ] **Step 4: Commit whatever was decided**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add scripts/test-memory-guard.ps1 deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md
git commit -m "docs+gate: surface the native deer-flow memory lane

deer-flow's memory is ALREADY routed through pacgate-api via storage_class, so it
is scope-gated for free. The gap is its NATIVE agents/<x>/memory.json, keyed
user+agent - a third isolation key, proven a different writer by schema
(workContext/topOfMind v1.0, not the adapter's facts[]/revision v2.0).

Measured: that lane's newest write is days old, so it may already be inactive. The
gate now fails if a file appears in the last 24h, because that would mean the lane
is live and the 'accepted residual' position no longer holds.

Disabling the native writer is NOT done here: it changes deer-flow behaviour a user
may rely on, so it is a decision to be taken explicitly."
```

---

## Self-Review

**1. Coverage**

| item | task |
|---|---|
| (3) scope rule, mechanical | Task 1 |
| (3) enforced at write | Task 2 |
| (3) proven end to end + gate | Task 3 |
| (1) read-side boundary documented | Task 4 |
| (2) native lane decision + detection | Task 5 |
| The asymmetry (why names are allowed) recorded where it will be read | Tasks 1, 4 |

**2. Placeholder scan**

No placeholders. Task 5 is explicitly a decision with both options given and an instruction not to pick silently — that is a stated handoff, not a gap. Task 4 Step 1 says "find it with `Select-String`" because the exact docstring location depends on the file's current shape.

**3. Type consistency**

- `MEMORY_MAX_BYTES: usize` — Task 1, referenced by the test, the gate (Task 3), and Task 4's doc.
- `MemoryScopeViolation::{Identifier, TooLarge}` — Task 1, matched in Task 2 Step 4 and Task 3 Step 4.
- `check_memory_scope(&serde_json::Value) -> Result<(), MemoryScopeViolation>` — defined Task 1, called Task 2 Step 4, textually asserted Task 3 Steps 1 and 4.
- `ApiError::unprocessable` — added Task 2 Step 3, called Task 2 Step 4, asserted Task 3.
- `production_source()` in `matters.rs` tests — **already exists** from P5; Task 2 Step 1 reuses it rather than defining a second helper.
- `revision` / `revision + 1` in Task 3 Step 1 — from P5's assertions in the same function, already in scope.

One inconsistency found and fixed in review: Task 3's first draft negated the scope call via a fragile multi-line `-replace` that would not have compiled, making the negative test vacuous. Replaced with a single-token substitution whose application is confirmed by `Select-String` before the result is trusted — the same discipline that caught the P4 ordering test failing against correct code.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-27-second-brain-memory-scope.md`.

**Ordering:** Step 3 (Tasks 1-3) → Step 1 (Task 4) → Step 2 (Task 5, a decision). Tasks 1→2→3 are strictly dependent. Task 4 documents what 1-3 built. Task 5 needs a user answer.

**The two things that must not slip:**

1. **Task 3 Step 1's second assertion.** A process summary must still be ACCEPTED. Without it, the only tested behaviour is refusal, and a gate that refuses everything passes that test while being useless.
2. **Task 5 must not be silently actioned.** Disabling deer-flow's native memory changes behaviour a user may rely on. Both options go to the user with the measured facts.
