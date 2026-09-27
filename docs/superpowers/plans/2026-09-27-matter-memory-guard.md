# Matter Memory: Make the Concurrency Guard Real - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close a live last-write-wins data-loss window on matter memory by making the existing `If-Match` guard actually enforced at the server, increment the revision so the guard has something to compare, and make the write atomic so a crash cannot truncate the file.

**Architecture:** Three independent breaks in one chain, fixed in dependency order. The server must **read** `If-Match` (it currently discards all headers), `check_revision` must be **called** (it is dead code), the revision must **increment** (nothing ever changes it), and the write must become **atomic** (it is a truncate-then-write). The adapter is already correct and needs no change — which is itself the finding, since its passing tests are why this looked done.

**Tech Stack:** Rust (`pacgate-api`: `axum` header extraction, `std::fs` + rename), PostgreSQL (none — this lane is file-based). **No new dependencies**; the adapter is unchanged.

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` §5.2 (the memory interface contract). Findings measured in `/memories/repo/matter-memory-dead-guard.md`.

**Depends on:** nothing. Independent of P1-P4.

## Global Constraints

- **Do NOT change the adapter.** `pacgate-adapters/python/.../storage.py` already reads the revision, sends `If-Match`, and raises `MatterMemoryConflict` on 409. It is correct. Its 6 tests must keep passing untouched.
- **`None` must stay allowed.** `check_revision`'s doc comment records the decision: requiring `If-Match` would break a caller that does not send one, so the unconditional write path stays. Do not make the header mandatory.
- **Fail closed, but only for a caller that opted in.** A request with no `If-Match` writes unconditionally (backwards compatible). A request **with** `If-Match` that mismatches gets 409 and **the file must not be touched**.
- **Do NOT put the revision in a query parameter, body field, or custom header.** It must be the HTTP `If-Match` header, because that is what the adapter already sends.
- **The increment must be server-side.** The server owns the counter; a client-supplied `revision` in the body must not be trusted as the new value.
- **The atomic write must not change the file's directory or name.** Same path, same JSON shape - only the write mechanism changes.
- **`cargo` is NOT on PATH.** `& "$env:USERPROFILE\.cargo\bin\cargo.exe"` from `pacgate-ai/`.
- **Clippy:** `cargo clippy -p pacgate-api --all-targets -- -D warnings` must stay clean. Note there is a **pre-existing** `unused variable: doc_store_for_asserts` warning in `tests/integration.rs`; do not chase it.
- **After any mutation, `git status --short`** and restore.
- **A guard is only real where it can REJECT.** The single most important instruction in this plan: every task's test must fail when the guard is removed. Two layers of this chain already have green tests that prove nothing.

---

## Measured findings this plan is built on

### F1 - the chain is broken at three independent points

| layer | state | evidence |
|---|---|---|
| Adapter | **correct** | `storage.py:81` sends `If-Match`; `:91` raises `MatterMemoryConflict`; 6 passing tests |
| Server handler | **absent** | `grep 'HeaderMap\|TypedHeader' matters.rs` -> no header access at all, so `If-Match` is discarded |
| The counter | **never moves** | `grep -r 'revision.*+ 1\|revision.*+=' pacgate-ai/crates` -> **no match** |

```
$ Select-String -Path 'pacgate-api/src/matters.rs' -Pattern 'HeaderMap|If-Match'
  L71, L283, L315   # comments only - no production header access
$ Select-String -Path 'pacgate-api/src/matters.rs' -Pattern 'check_revision'
  L79   fn check_revision(...)          # the definition
  L286, L292, L298, L308, L317, L318     # six #[cfg(test)] assertions
  -> zero production call sites
```

### F2 - why two layers of tests pass while the property is absent

- The adapter's tests assert the **client sends** the right header. True.
- `check_revision`'s tests assert the **function compares** correctly. True.
- Nothing asserts the server **calls** it, or that the counter **moves**.
- `test_memory_revision.py` structurally cannot catch this: it tests a correct client against a mocked server.

So "wired up" was inferred from two green test suites rather than from a call site.

### F3 - the write is non-atomic

```rust
// matters.rs:239
std::fs::write(&path, bytes)
```

Whole-file truncate-then-write. A crash, OOM kill, or full disk mid-write leaves a
**truncated or empty** `memory.json` with no backup. `mem_limit: 4g` plus
`restart: unless-stopped` (P4) makes an OOM kill during a write a live path, and
`get_matter_memory` would then fail to parse the file at all - so the matter's
memory becomes unreadable, not merely stale.

### F4 - the memory lane has no sanitization gate

`save_matter_memory` accepts any JSON object. DEFECT 2 from the 2026-09-18
research, still open. **Out of scope here** (recorded in the plan's final section):
gating content is a design decision, not a wiring fix, and conflating it with this
plan would make both harder to review.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-api/src/matters.rs` | `save_matter_memory`, `check_revision`, `memory_revision`, the atomic write | Modify |
| `pacgate-ai/crates/pacgate-api/tests/integration.rs` | End-to-end proof through the router | Modify |
| `pacgate-ai/crates/pacgate-api/src/lib.rs` | Router - only if a header-reading layer is needed | Possibly modify |

One file carries the fix. That is deliberate: the defect is a missing call, not a
missing component, and a large change would obscure that.

---

### Task 1: The revision must move

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs`
- Test: same file

**Interfaces:**
- Consumes: `memory_revision(&serde_json::Value) -> u64` (existing).
- Produces: `fn next_revision(current: &serde_json::Value) -> u64` - the value a *successful* write should store.

**This task comes first** because wiring `check_revision` in before the counter moves would produce a guard that compares a constant against itself - it would accept a stale write forever while looking correct. Fixing the order is what makes the next task's test meaningful.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` module in `matters.rs`:

```rust
    /// The counter must advance on a successful write, or the guard compares a
    /// constant against itself and can never reject a stale caller.
    ///
    /// This is the assertion whose absence let the guard be "wired up" in three
    /// places while doing nothing: nothing in the workspace incremented it.
    #[test]
    fn the_next_revision_always_advances() {
        assert_eq!(next_revision(&serde_json::json!({})), 1, "absent reads as 0, so next is 1");
        assert_eq!(next_revision(&serde_json::json!({ "revision": 0 })), 1);
        assert_eq!(next_revision(&serde_json::json!({ "revision": 5 })), 6);
        // A corrupt value must not freeze the counter at a constant: whatever it
        // reads as, the next value is strictly greater.
        assert_eq!(next_revision(&serde_json::json!({ "revision": "nope" })), 1);
        assert_eq!(next_revision(&serde_json::json!({ "revision": -3 })), 1);
    }

    /// The property that makes the guard work, stated directly.
    #[test]
    fn a_stale_caller_is_rejected_after_a_write_advances_the_counter() {
        let before = serde_json::json!({ "revision": 4 });
        let after = serde_json::json!({ "revision": next_revision(&before) });

        // The client that read revision 4 is now stale: its claim must fail.
        assert!(
            check_revision(&after, Some(4)).is_err(),
            "a caller holding the pre-write revision must be rejected after the write"
        );
        // The client that read the NEW revision succeeds.
        assert!(check_revision(&after, Some(5)).is_ok());
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib the_next_revision_always_advances 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find function 'next_revision' in this scope`.

- [ ] **Step 3: Write minimal implementation**

Add to `matters.rs`, next to `memory_revision`:

```rust
/// The revision a successful write should store.
///
/// Server-owned on purpose: the caller's `If-Match` is a claim about what it
/// *read*, never a value to store. Trusting a body field here would let a stale
/// client reset the counter, which is the failure this whole mechanism exists to
/// prevent.
///
/// Always strictly greater than what `memory_revision` read, including when the
/// stored value is absent or corrupt - a counter that can fail to advance is a
/// guard that can never reject.
fn next_revision(current: &serde_json::Value) -> u64 {
    memory_revision(current).saturating_add(1)
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib 2>&1 | Select-String -Pattern 'test result|FAILED' | Out-String
```

Expected: `test result: ok.`, count up by 2.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/matters.rs
git commit -m "fix(api): add the revision increment matter memory never had

grep across the workspace for any revision increment returned nothing:
default_matter_memory sets revision 0, memory_revision reads it, check_revision
compares it, and no code ever changed it. So the guard compared a constant against
itself and could never reject a stale caller - it would have looked correct and
done nothing.

Server-owned: the caller's If-Match is a claim about what it READ, never a value
to store. A body-supplied revision would let a stale client reset the counter.
Always strictly greater, including when the stored value is absent or corrupt - a
counter that can fail to advance is a guard that can never reject."
```

---

### Task 2: Read `If-Match` and call the guard

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs`
- Test: same file

**Interfaces:**
- Consumes: `check_revision(&Value, Option<u64>) -> Result<(), ApiError>` (existing, currently dead), `next_revision` (Task 1).
- Produces: `fn if_match_revision(headers: &HeaderMap) -> Result<Option<u64>, ApiError>` - parses the header, or 400 on a malformed value.

**Read this before implementing.** `save_matter_memory` currently takes no headers at all. Adding `HeaderMap` to an axum handler signature is the whole fix for this task, and **header extraction order matters**: all `FromRequestParts` extractors must precede the body extractor, so `HeaderMap` goes **before** `Json(memory)`. Getting that wrong is a compile error, not a silent bug, but it will look like the extractor "doesn't work".

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` module:

```rust
    /// A malformed If-Match must be a client error, not a silent unconditional
    /// write. Silently ignoring a header the caller believes is guarding them is
    /// the worst outcome: they think they are protected.
    #[test]
    fn a_malformed_if_match_is_rejected_not_ignored() {
        use axum::http::HeaderMap;
        use axum::http::header::IF_MATCH;

        let mut h = HeaderMap::new();
        h.insert(IF_MATCH, "not-a-number".parse().unwrap());
        let err = if_match_revision(&h).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::BAD_REQUEST);

        // Absent is allowed - the unconditional path stays.
        assert_eq!(if_match_revision(&HeaderMap::new()).unwrap(), None);

        // A well-formed value parses.
        let mut ok = HeaderMap::new();
        ok.insert(IF_MATCH, "7".parse().unwrap());
        assert_eq!(if_match_revision(&ok).unwrap(), Some(7));
    }

    /// The guard must be reachable from the handler. If `save_matter_memory` does
    /// not read headers, `If-Match` is discarded and 409 is unreachable no matter
    /// how correct `check_revision` is - which was the actual state of this code.
    #[test]
    fn the_save_handler_actually_reads_the_if_match_header() {
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/matters.rs"),
        )
        .expect("read own source");
        // Scope to production code: searching the whole file matches this test's
        // own string literal, which is exactly the mistake made in P4.
        let prod = &src[..src.find("#[cfg(test)]").expect("file must have tests")];

        let save_start = prod
            .find("pub async fn save_matter_memory")
            .expect("save_matter_memory must exist");
        let save_body = &prod[save_start..];

        assert!(
            save_body.contains("HeaderMap"),
            "save_matter_memory must take a HeaderMap, or If-Match is discarded \
             and 409 is unreachable"
        );
        assert!(
            save_body.contains("if_match_revision("),
            "save_matter_memory must CALL if_match_revision"
        );
        assert!(
            save_body.contains("check_revision("),
            "save_matter_memory must CALL check_revision - defined-but-uncalled is \
             the state that let this guard be dead at three layers"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib if_match 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find function 'if_match_revision'`.

- [ ] **Step 3: Implement the parser**

Add to `matters.rs` (and add `use axum::http::HeaderMap;` to the imports):

```rust
/// Parse the `If-Match` header into an expected revision.
///
/// `Ok(None)` means the header was absent: the caller opted out of the guard, and
/// the write proceeds unconditionally. That is a deliberate decision recorded on
/// `check_revision` - requiring the header would break a caller that does not send
/// one.
///
/// A present-but-unparseable value is a **400**, never `Ok(None)`. Silently
/// ignoring a header the caller believes is protecting them is the worst possible
/// outcome: they think they are guarded while writing unconditionally.
fn if_match_revision(headers: &HeaderMap) -> Result<Option<u64>, ApiError> {
    let Some(raw) = headers.get(axum::http::header::IF_MATCH) else {
        return Ok(None);
    };
    let text = raw
        .to_str()
        .map_err(|_| ApiError::bad_request("If-Match header is not valid ASCII"))?;
    let text = text.trim().trim_matches('"');
    let value: u64 = text
        .parse()
        .map_err(|_| ApiError::bad_request(format!("If-Match must be a revision number, got {text:?}")))?;
    Ok(Some(value))
}
```

- [ ] **Step 4: Wire it into the handler**

Change `save_matter_memory`'s signature and body. `HeaderMap` goes **before** the body extractor:

```rust
pub async fn save_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(memory): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
```

Then, after the `matter_store.get(...)` existence check and the path computation, and **before** any write:

```rust
    // Read the guard BEFORE touching the file. A conflict must leave the file
    // exactly as it was - a 409 that already truncated the file is worse than no
    // guard, because the caller believes nothing was written.
    let expected = if_match_revision(&headers)?;

    let current = if path.exists() {
        let existing = std::fs::read(&path)
            .map_err(|e| ApiError::internal(format!("failed to read matter memory: {e}")))?;
        serde_json::from_slice(&existing)
            .map_err(|e| ApiError::internal(format!("failed to parse matter memory: {e}")))?
    } else {
        default_matter_memory()
    };

    check_revision(&current, expected)?;
```

- [ ] **Step 5: Set the revision server-side before serializing**

Still in `save_matter_memory`, after the guard passes and before serializing:

```rust
    // The server owns the counter: `If-Match` is a claim about what the caller
    // READ, never the value to store. Assigning it here is what makes the guard
    // meaningful on the NEXT request.
    let mut memory = memory;
    if let Some(obj) = memory.as_object_mut() {
        obj.insert(
            "revision".to_string(),
            serde_json::Value::from(next_revision(&current)),
        );
    }
```

- [ ] **Step 6: Run tests to verify**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
& "$env:USERPROFILE\.cargo\bin\cargo.exe" clippy -p pacgate-api --all-targets 2>&1 | Select-String -Pattern '^error|Finished' | Out-String
```

Expected: `test result: ok.` and clippy `Finished`.

- [ ] **Step 7: Negative-test the wiring**

The three assertions above are textual. Prove the wiring is load-bearing by removing the call and confirming the test fails:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'
Copy-Item $f "$f.wirebak"
(Get-Content $f -Raw) -replace 'check_revision\(&current, expected\)\?;', 'let _ = &current;' | Set-Content $f -Encoding UTF8
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib the_save_handler_actually_reads 2>&1 | Select-String -Pattern 'test result|FAILED' | Out-String
Move-Item "$f.wirebak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: `FAILED`. If it passes, the assertion is not checking the call site.

- [ ] **Step 8: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/matters.rs
git commit -m "fix(api): enforce If-Match on matter memory writes

save_matter_memory took no headers at all, so If-Match was discarded and 409 was
unreachable however correct check_revision was. check_revision itself was dead
code: defined, asserted six times, called from zero production sites.

A malformed If-Match is a 400, never a silent unconditional write. Silently
ignoring a header the caller believes is protecting them is the worst outcome -
they think they are guarded while writing unconditionally.

The revision is assigned server-side after the guard passes: the caller's
If-Match is a claim about what it READ, never a value to store, and trusting a
body field would let a stale client reset the counter.

Negative-tested: removing the check_revision call makes the wiring assertion fail."
```

---

### Task 3: Make the write atomic

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/matters.rs`
- Test: same file

**Interfaces:**
- Consumes: nothing new.
- Produces: `fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()>`.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` module:

```rust
    /// The write must be all-or-nothing. `std::fs::write` truncates first, so a
    /// crash mid-write leaves a truncated or empty memory.json - and
    /// get_matter_memory cannot parse that, so the matter's memory is unreadable
    /// rather than merely stale, with no backup to recover from.
    #[test]
    fn an_atomic_write_leaves_no_partial_file() {
        let dir = std::env::temp_dir().join(format!("pacgate-atomic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("memory.json");

        // Overwriting an existing file must not leave the target in a partial
        // state at any point: the new content appears whole.
        std::fs::write(&path, b"{\"old\":true}").unwrap();
        write_atomic(&path, b"{\"new\":true}").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"{\"new\":true}");

        // A fresh write works too.
        let fresh = dir.join("fresh.json");
        write_atomic(&fresh, b"{\"ok\":1}").unwrap();
        assert_eq!(std::fs::read(&fresh).unwrap(), b"{\"ok\":1}");

        // No temp file is left behind.
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains("tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The handler must use it. A correct helper that the handler does not call is
    /// the exact failure shape this whole plan exists to fix.
    #[test]
    fn the_save_handler_writes_atomically() {
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/matters.rs"),
        )
        .expect("read own source");
        let prod = &src[..src.find("#[cfg(test)]").expect("file must have tests")];
        let save = &prod[prod.find("pub async fn save_matter_memory").expect("handler exists")..];

        assert!(
            save.contains("write_atomic("),
            "save_matter_memory must write atomically"
        );
        assert!(
            !save.contains("std::fs::write(&path"),
            "the truncate-then-write call must be gone from the handler"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib an_atomic_write 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find function 'write_atomic'`.

- [ ] **Step 3: Implement**

Add to `matters.rs`:

```rust
/// Write `bytes` to `path` atomically: a reader sees either the old file or the
/// new one, never a partial one.
///
/// `std::fs::write` truncates the target before writing, so a crash, an OOM kill,
/// or a full disk mid-write leaves a truncated or empty file. That is
/// unrecoverable here: `get_matter_memory` cannot parse it, there is no backup,
/// and `mem_limit: 4g` plus a restart policy makes an OOM kill during a write a
/// live path rather than a theoretical one.
///
/// Temp file in the SAME directory (so the rename is same-filesystem and
/// therefore atomic), then rename over the target.
///
/// fsync before rename is deliberate: without it the rename can be durable while
/// the contents are not, which on a power loss yields a valid-looking file of the
/// wrong length. The cost is one flush per memory write, which this lane can
/// afford.
fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let tmp = dir.join(format!(
        ".memory.json.tmp-{}",
        std::process::id()
    ));

    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }

    match std::fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            // Clean up rather than leaving a stray temp file behind on failure.
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}
```

- [ ] **Step 4: Use it in the handler**

Replace in `save_matter_memory`:

```rust
    std::fs::write(&path, bytes)
        .map_err(|e| ApiError::internal(format!("failed to write matter memory: {e}")))?;
```

with:

```rust
    write_atomic(&path, &bytes)
        .map_err(|e| ApiError::internal(format!("failed to write matter memory: {e}")))?;
```

- [ ] **Step 5: Run tests to verify**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
```

Expected: `test result: ok.`.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/matters.rs
git commit -m "fix(api): write matter memory atomically

std::fs::write truncates the target before writing, so a crash, OOM kill or full
disk mid-write leaves a truncated or empty memory.json. That is unrecoverable:
get_matter_memory cannot parse it and there is no backup, so the matter memory
becomes unreadable rather than stale. mem_limit 4g plus a restart policy makes an
OOM kill during a write a live path, not a theoretical one.

Temp file in the same directory so the rename is same-filesystem and therefore
atomic, fsync before rename so a power loss cannot leave a durable rename over
non-durable contents, and the temp file is removed if the rename fails."
```

---

### Task 4: Prove the whole chain through the router

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/tests/integration.rs`

**Interfaces:**
- Consumes: the running `build_router(state)` harness already in that file (two `AppState` literals exist; use the one with a real `FsDocumentStore`/`MatterStore` if it has one, otherwise follow that file's existing setup pattern).
- Produces: an end-to-end proof that a second stale write is rejected with 409 **and leaves the file untouched**.

**Why this task exists even though each unit is tested:** the entire defect was that per-unit tests passed while the property was absent. Only a test through the router can catch a guard that is correct in three places and connected in none.

- [ ] **Step 1: Write the failing test**

Add to `integration.rs`. Adapt the auth/matter setup to whatever that file already does - do not invent a new harness:

```rust
/// The property that was absent while every unit test passed: a stale write is
/// rejected AND the file is unchanged.
///
/// Each of the three pieces had green tests. Nothing tested them TOGETHER, which
/// is why the guard could be dead at every layer and still look finished.
#[tokio::test]
async fn a_stale_memory_write_is_rejected_and_leaves_the_file_intact() {
    // ... build `app` and a matter id using this file's existing pattern ...

    // 1. A first write succeeds and advances the revision.
    let first = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/matters/{matter_id}/memory"))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(r#"{"facts":["initial"]}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK, "the first write must succeed");

    let body = axum::body::to_bytes(first.into_body(), usize::MAX).await.unwrap();
    let written: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let rev = written["revision"].as_u64().expect("the server must assign a revision");
    assert!(rev >= 1, "the revision must have advanced from the default 0, got {rev}");

    // 2. A caller holding the PREVIOUS revision is rejected.
    let stale = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/matters/{matter_id}/memory"))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .header("if-match", "0")
                .body(Body::from(r#"{"facts":["stale-overwrite"]}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        stale.status(),
        StatusCode::CONFLICT,
        "a caller holding a stale revision must get 409, not a silent overwrite"
    );

    // 3. The guard must not have touched the file: read it back and assert the
    //    FIRST write's content survives. A 409 that already truncated the file
    //    would be worse than no guard.
    let read = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(format!("/api/matters/{matter_id}/memory"))
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = axum::body::to_bytes(read.into_body(), usize::MAX).await.unwrap();
    let after: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(
        after["facts"][0], "initial",
        "the rejected write must not have modified the file"
    );

    // 4. A caller holding the CURRENT revision succeeds, and advances again.
    let good = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/matters/{matter_id}/memory"))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .header("if-match", rev.to_string())
                .body(Body::from(r#"{"facts":["second"]}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(good.status(), StatusCode::OK, "a current revision must be accepted");
}
```

- [ ] **Step 2: Run it and confirm it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --test integration a_stale_memory_write 2>&1 | Out-String
```

If the harness needs a live Postgres and it is not reachable, the test will fail to connect. In that case report `DONE_WITH_CONCERNS` and state which parts of the chain are proven only by unit tests - do **not** mark the step complete.

- [ ] **Step 3: Negative-test the end-to-end proof**

A test that passes because it asserts nothing is the exact trap this plan addresses:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'
Copy-Item $f "$f.e2ebak"
(Get-Content $f -Raw) -replace 'check_revision\(&current, expected\)\?;', 'let _ = (&current, expected);' | Set-Content $f -Encoding UTF8
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --test integration a_stale_memory_write 2>&1 | Select-String -Pattern 'test result|FAILED|assertion' | Out-String
Move-Item "$f.e2ebak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: **FAILED**, on the 409 assertion. If it passes with the guard removed, the test is not proving the property - fix it before continuing.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/tests/integration.rs
git commit -m "test(api): prove the memory guard end to end, including file integrity

Each of the three pieces had green unit tests, which is exactly why the guard
could be dead at every layer and still look finished. This asserts them together:
a first write advances the revision, a stale caller gets 409, the file still
contains the FIRST write's content afterwards, and a current revision succeeds.

The file-integrity assertion is the one that matters most: a 409 that had already
truncated the file would be worse than no guard, because the caller would believe
nothing was written.

Negative-tested: removing the check_revision call makes it fail on the 409."
```

---

### Task 5: Add the gate that notices if any link is cut again

**Files:**
- Create: `scripts/test-memory-guard.ps1`
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: the source of `matters.rs`.
- Produces: a gate, exit `0` pass / `1` fail / `2` cannot check.

**This is the task that prevents recurrence.** Nothing in the suite could have caught the original defect, because every piece was individually correct. A source-level gate is blunt but it is the only thing that sees *the links between* the pieces.

- [ ] **Step 1: Write the gate**

Create `scripts/test-memory-guard.ps1`:

```powershell
# Asserts the matter-memory concurrency guard is CONNECTED, not merely present.
#
# WHY: this guard was dead at three layers simultaneously and every unit test was
# green. The adapter sends If-Match (6 passing tests). check_revision compares
# correctly (6 passing tests). Nothing incremented the counter, nothing read the
# header, and check_revision was called from zero production sites. Reading any
# one layer suggested the mechanism was done.
#
# A source-level gate is blunt. It is also the only thing that can see the LINKS
# between the pieces, which is precisely what was missing.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== matter memory guard ===' -ForegroundColor Cyan

$path = 'pacgate-ai/crates/pacgate-api/src/matters.rs'
$src = Get-Content $path -Raw
# Production code only. Searching the whole file matches the TESTS' own string
# literals and the function DEFINITIONS, which is how a P4 assertion managed to
# fail against correct code.
$end = $src.IndexOf('#[cfg(test)]')
$prod = if ($end -lt 0) { $src } else { $src.Substring(0, $end) }

# 1. The increment exists. Without it the guard compares a constant to itself.
if ($prod -match 'fn\s+next_revision\s*\(') {
    Pass 'next_revision exists (the counter can advance)'
} else {
    Fail 'no next_revision: nothing increments the revision, so check_revision compares a constant against itself and can never reject a stale caller'
}

# 2. The handler reads the header. Without this, If-Match is discarded.
$saveIdx = $prod.IndexOf('pub async fn save_matter_memory')
if ($saveIdx -lt 0) {
    Fail 'cannot find save_matter_memory - the gate would pass vacuously'
} else {
    $save = $prod.Substring($saveIdx)

    if ($save -match 'headers:\s*HeaderMap') {
        Pass 'save_matter_memory accepts a HeaderMap'
    } else {
        Fail 'save_matter_memory does not accept a HeaderMap, so If-Match is discarded and 409 is unreachable'
    }

    # 3. The guard is CALLED. Defined-but-uncalled is the original defect.
    if ($save -match 'check_revision\(') {
        Pass 'save_matter_memory calls check_revision (the guard is connected)'
    } else {
        Fail 'save_matter_memory does not CALL check_revision - this was the original defect: defined, unit-tested, called from zero production sites'
    }

    # 4. The revision is assigned server-side.
    if ($save -match 'next_revision\(') {
        Pass 'save_matter_memory assigns the revision server-side'
    } else {
        Fail 'save_matter_memory never calls next_revision, so the stored revision is whatever the client sent - a stale client can reset the counter'
    }

    # 5. The write is atomic.
    if ($save -match 'write_atomic\(') {
        Pass 'save_matter_memory writes atomically'
    } else {
        Fail 'save_matter_memory does not write atomically: a crash mid-write leaves a truncated memory.json that cannot be parsed and has no backup'
    }
    if ($save -match 'std::fs::write\(&path') {
        Fail 'save_matter_memory still contains the truncate-then-write call'
    }
}

# 6. The adapter still opts in. A server-side guard nothing sends is useless.
$adapter = 'pacgate-adapters/python/pacgate_deerflow_adapter/storage.py'
if (Test-Path $adapter) {
    $a = Get-Content $adapter -Raw
    if ($a -match 'If-Match') {
        Pass 'the adapter still sends If-Match (the guard has a caller)'
    } else {
        Fail "the adapter no longer sends If-Match, so the server-side guard is never exercised"
    }
} else {
    Write-Host "  exit 2 - adapter not found at $adapter; cannot check the caller side" -ForegroundColor Yellow
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-guard check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the matter memory guard is connected at every link' -ForegroundColor Green
exit 0
```

- [ ] **Step 2: Run it and confirm it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-memory-guard.ps1
"exit=$LASTEXITCODE"
```

Expected: exit 0, six PASS lines.

- [ ] **Step 3: Negative-test each link independently**

This gate exists because per-piece correctness hid a broken chain, so test **each link separately**:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai\crates\pacgate-api\src\matters.rs'

# (a) cut the guard call
Copy-Item $f "$f.gbak"
(Get-Content $f -Raw) -replace 'check_revision\(&current, expected\)\?;', 'let _ = &current;' | Set-Content $f -Encoding UTF8
& pwsh -NoProfile -File scripts/test-memory-guard.ps1 *> $null
"(a) check_revision call removed -> exit=$LASTEXITCODE (expect 1)"
Move-Item "$f.gbak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date

# (b) freeze the counter
(Get-Content $f -Raw) -replace 'fn next_revision', 'fn unused_next_revision' | Set-Content $f -Encoding UTF8
& pwsh -NoProfile -File scripts/test-memory-guard.ps1 *> $null
"(b) next_revision removed -> exit=$LASTEXITCODE (expect 1)"
git checkout -- $f; (Get-Item $f).LastWriteTime = Get-Date

git status --short
```

Expected: both `exit=1`, clean tree afterwards.

- [ ] **Step 4: Add it to the runner**

In `scripts/run-all-checks.ps1`, after `'scripts/test-memory-bound.ps1'`:

```powershell
    # Asserts the matter-memory concurrency guard is CONNECTED. It was dead at
    # three layers at once while every unit test passed, because each layer was
    # individually correct. Source-level, but the only thing that sees the links.
    # Self-contained (reads files).
    'scripts/test-memory-guard.ps1'
```

- [ ] **Step 5: Run the runner**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/run-all-checks.ps1 *> 'mg.txt'
"exit=$LASTEXITCODE"
Select-String -Path 'mg.txt' -Pattern 'memory-guard|ALL |FAILED' | ForEach-Object { $_.Line }
Remove-Item 'mg.txt' -Force
```

Expected: `test-memory-guard.ps1` PASS, gate count 27, exit 0.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add scripts/test-memory-guard.ps1 scripts/run-all-checks.ps1
git commit -m "ci(gates): assert the memory guard is connected, not merely present

This guard was dead at three layers at once while every unit test was green: the
adapter sends If-Match (6 passing tests), check_revision compares correctly (6
passing tests), nothing incremented the counter, nothing read the header, and
check_revision had zero production call sites. Reading any one layer suggested the
mechanism was finished.

A source-level gate is blunt. It is also the only thing that can see the LINKS
between the pieces, which is exactly what was missing. Checks five links plus the
adapter's opt-in, and slices to production source so it cannot match the tests'
own string literals.

Negative-tested per link: cutting the check_revision call and removing
next_revision each make it exit 1."
```

---

## Deliberately NOT in this plan

**The memory lane still has no sanitization gate.** `save_matter_memory` accepts
any JSON object; DEFECT 2 from the 2026-09-18 research. It is excluded because
gating *content* is a design decision (what counts as sanitized? does the caller
attest, or does the server re-scan?) rather than a wiring fix, and bundling it
here would make both changes harder to review - the same reasoning that kept
`CaseNumber` out of P1.

It matters more, not less, after this plan: once the revision guard works, a
concurrent write is *rejected* rather than lost, so the lane becomes safe against
losing data while still accepting unsanitized content.

**Also excluded:** the doubled `data/tenants/tenants/` path. Functionally
consistent (one helper, isolation intact), so it is a readability trap rather than
a defect. Changing it would move every existing memory file.

---

## Self-Review

**1. Spec coverage**

| Item | Task |
|---|---|
| The revision must advance (F1) | Task 1 |
| `If-Match` must be read (F1) | Task 2 Steps 3-4 |
| `check_revision` must be called (F1, dead code) | Task 2 Step 4 |
| Revision assigned server-side | Task 2 Step 5 |
| Atomic write (F3) | Task 3 |
| The property proven, not the pieces (F2) | Task 4 |
| Recurrence prevention | Task 5 |
| Sanitization gate (F4) | Excluded, with the reason stated |

**2. Placeholder scan**

One deliberate elision: Task 4 Step 1's test uses `// ... build `app` and a matter id using this file's existing pattern ...` because that file has two harnesses and the correct one depends on which has a real `MatterStore`. The plan says to adapt rather than invent, and Step 2 explicitly instructs `DONE_WITH_CONCERNS` if the harness needs an unreachable Postgres rather than reporting success. Every other step carries literal content.

**3. Type consistency**

- `next_revision(&serde_json::Value) -> u64` - Task 1 Step 3, used Task 1 tests, Task 2 Step 5, gate check 1 and 4.
- `if_match_revision(&HeaderMap) -> Result<Option<u64>, ApiError>` - Task 2 Step 3, used Step 4, tested Step 1.
- `check_revision(&Value, Option<u64>) -> Result<(), ApiError>` - **existing**, unchanged signature.
- `write_atomic(&Path, &[u8]) -> std::io::Result<()>` - Task 3 Step 3, used Step 4, tested Step 1.
- `HeaderMap` before `Json` in the handler signature - Task 2 Step 4, stated explicitly because axum requires `FromRequestParts` extractors first.
- `ApiError::bad_request` and `ApiError::conflict` - both confirmed present (`error.rs`).

One inconsistency found and fixed in review: Task 1 was originally ordered *after* the wiring. That is wrong and the plan now says why - wiring `check_revision` in before the counter moves produces a guard comparing a constant against itself, which accepts stale writes forever while looking correct. Increment first, then connect.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-27-matter-memory-guard.md`.

**Dependency ordering:** Task 1 -> Task 2 (the guard is meaningless without the increment), Task 3 independent, Task 4 asserts 1-3 together, Task 5 prevents recurrence.

**The two things that must not slip:**

1. **Task 4 Step 3.** Removing the guard must make the end-to-end test fail on the 409. If it still passes, the test proves nothing - and that is the exact failure mode this entire plan exists to correct.
2. **Task 1 before Task 2.** A guard whose counter never moves is worse than no guard, because it reads as protection.
