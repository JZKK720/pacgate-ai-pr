# P4: Bound the NER Memory Cost - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an out-of-memory kill from concurrent sanitize jobs impossible, then remove the per-job cost that creates the risk.

**Architecture:** Two independent layers, landed cheapest-first. An admission gate in `pacgate-api` caps *concurrent sanitize jobs* so peak memory is `limit x 393 MiB` by construction rather than by luck; a container memory limit plus restart policy bounds the blast radius if anything else ever allocates unboundedly. Only then does the `Arc<dyn Detector>` refactor make sense, because that is a correctness-sensitive change and should not be the first line of defence.

**Tech Stack:** Rust (crate `pacgate-api`, `tokio::sync::Semaphore` — **no new dependency**, the workspace tokio already has `features = ["full"]`), Docker Compose, PowerShell gate scripts.

**Spec:** `docs/superpowers/specs/2026-09-26-ner-enablement-design.md` - this implements the *enabled but unbounded* gap left by P3 (§9 step 5 shipped NER without bounding its cost). Findings measured in `/memories/repo/ner-per-job-load-memory.md`.

**Depends on:** P3 released as `v0.1.19`.

## Global Constraints

- **Do NOT share the `Sanitizer`.** `Sanitizer::new` mints a random per-job placeholder token (`pipeline.rs:37`) and that token is what stops two jobs from minting the same placeholder name (spec §6.2). Sharing the instance would reintroduce the cross-job cross-resolution defect found in plan 017 Task 12. Share the *detectors*, never the *Sanitizer*.
- **Admission control must fail closed, not drop.** A queued job waits; it is never silently skipped, because a skipped sanitize job means a document stays `pending` and silently unsearchable while the caller believes it succeeded.
- **The limit must be a named, documented constant**, not a bare integer, and it must be stated in the client deliverable alongside its memory arithmetic.
- **Do NOT change `MAX_TOKENS`, the model, or the tokenizer.** P2 and P3 are measured-working.
- **Do NOT change `sanitize.rs`'s detector-selection logic** (P3 Task 3's constraint still holds: unset warns + Tier-1, set-but-broken errors).
- **Both compose files must get identical treatment.** `compose.prod.yaml` and `compose.bundle.yaml` both define `pacgate-api`.
- **Gate exit codes:** `0` pass, `1` real failure, `2` cannot check. Never report a "cannot check" as a pass.
- **`docker` is required for Tasks 4-5.** Report `DONE_WITH_CONCERNS` if absent rather than claiming the limit is applied.
- **Run compose from `deploy/client-bundle/`.**
- **Line-based PowerShell execution mangles nested `$`.** Send one command per call, or write a script file.
- **After any mutation, `git status --short`** and restore. Note `Move-Item` restores the backup's *old mtime* — touch it, or cargo serves a stale binary.

---

## Measured findings this plan is built on

### F1 — the cost is 393 MiB of RETAINED memory per load, not 200 ms

Measured 2026-09-27 with an external sampler (`/proc` does not exist on Windows):

```
private      phase
   0.9 MiB   baseline
 392.9 MiB   after load 1     (+392.0)
 785.2 MiB   after load 2     (+392.3)
1177.3 MiB   after load 3     (+392.1)
1569.1 MiB   after load 4     (+391.8)   <- holding all four
   2.9 MiB   after dropping all
```

The weights are F32 safetensors, mmapped, and the pages go resident on the first
forward pass. Dropping the detector does not return them to the OS.

**This is not a leak.** Sequential jobs reuse the arena: RSS moved
1,330,212 -> 1,330,220 kB (**8 kB**) across three further sanitize jobs.

It is **N concurrent jobs x 393 MiB**, and N is currently unbounded.

### F2 — N is bounded by 32 on the client hardware, not by design

```
compose.prod.yaml pacgate-api:  NanoCpus=0  CpuQuota=0   (no --cpus)
container nproc:                32
container Threads:              65
container VmRSS:                1330212 kB  (1.27 GiB retained, idle-ish)
container Memory limit:         0 bytes (UNLIMITED)
```

No CPU cap means Tokio spawns one worker per available core, so up to 32 sanitize
jobs can be in flight simultaneously. Worst case **32 x 393 MiB = 12.6 GiB**.

### F3 — nothing limits concurrency today

```
grep -E 'ConcurrencyLimit|Semaphore|Buffer|RateLimit|tower::limit' pacgate-api/src/*.rs
  -> no matches
```

The only existing bound is a request **body** limit: `DefaultBodyLimit::max((max_upload_mb + 14) MB)` = 64 MB (`lib.rs:121`). That bounds one request's size, not how many run at once.

### F4 — `tokio::sync::Semaphore` needs no new dependency

```
pacgate-ai/Cargo.toml:  tokio = { version = "1", features = ["full"] }
```

`Semaphore` is in `tokio::sync`, covered by `full`. Tower is pinned at `0.4` in the
workspace; `tower::limit::ConcurrencyLimitLayer` would need the `limit` feature to
be enabled, so the `Semaphore` route is strictly cheaper.

### F5 — the cost did not exist before P3

`build_detectors` returns `tier_one_detectors()` — a regex detector with no
weights — when `PACGATE_NER_MODEL_DIR` is unset. Every client install ran that way
until 0.1.19. **Enabling NER created this cost**; the enablement and the risk are
one change, which is why the bound belongs in the same release.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-api/src/state.rs` | Hold the admission semaphore; document the limit constant | Modify |
| `pacgate-ai/crates/pacgate-api/src/main.rs` | Construct the semaphore | Modify |
| `pacgate-ai/crates/pacgate-api/src/sanitize.rs` | Acquire a permit around the detector build; explicit 503 when closed | Modify |
| `pacgate-ai/crates/pacgate-api/src/error.rs` | A `service_unavailable` (503) constructor | Modify |
| `deploy/client-bundle/compose.prod.yaml` + `compose.bundle.yaml` | Memory limit + restart policy | Modify |
| `scripts/test-memory-bound.ps1` | Gate: the limit is configured and the permit logic is present | Create |
| `scripts/run-all-checks.ps1` | Gate list entry | Modify |
| `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md` | State the memory requirement | Modify |

Tasks 5-6 are a **separate plan** (P5) and are named here only to show the shape; do not start them.

---

### Task 1: A `service_unavailable` error constructor

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/error.rs`
- Test: same file (`#[cfg(test)]`)

**Interfaces:**
- Consumes: nothing.
- Produces: `ApiError::service_unavailable(msg: impl Into<String>) -> ApiError` with HTTP status 503.

**Why a task and not a line:** every other rejection in this codebase is a client fault (400/404/409). This is the first *server-capacity* status, and it should be introduced with its status asserted rather than assumed — a wrong status here would make the API look broken to a caller instead of busy.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` block in `error.rs`, alongside the existing `conflict` test:

```rust
    #[test]
    fn service_unavailable_is_503_not_a_client_error() {
        let e = ApiError::service_unavailable("sanitize capacity");
        assert_eq!(
            e.status,
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            "capacity rejection must be 503: a 4xx would tell the caller their request was bad"
        );
        assert!(e.message.contains("capacity"));
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib service_unavailable_is_503 2>&1 | Out-String
```

Expected: FAIL to compile - `no function or associated item named 'service_unavailable'`.

- [ ] **Step 3: Write minimal implementation**

In `error.rs`, next to the existing `conflict` constructor:

```rust
    /// Server-capacity rejection: the request was well-formed, we had no room.
    ///
    /// Distinct from the 4xx constructors on purpose. A sanitize job allocates a
    /// 393 MiB NER detector set (measured 2026-09-27), so concurrency is bounded
    /// deliberately and a caller that arrives over the bound is asked to retry
    /// rather than told its request was wrong.
    pub fn service_unavailable(message: impl Into<String>) -> Self {
        Self {
            status: axum::http::StatusCode::SERVICE_UNAVAILABLE,
            message: message.into(),
        }
    }
```

Match the surrounding constructors' exact field names and types - read them first; do not guess.

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
```

Expected: `test result: ok.`, 0 failed.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/error.rs
git commit -m "feat(api): add a 503 constructor for capacity rejections

The first server-capacity status in this codebase - every existing rejection is a
client fault (400/404/409). Asserting the status rather than assuming it, because
a 4xx here would tell a caller their well-formed request was bad instead of busy."
```

---

### Task 2: The admission semaphore

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/state.rs`
- Modify: `pacgate-ai/crates/pacgate-api/src/main.rs`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `pub const SANITIZE_MAX_CONCURRENT: usize` (= 2) in `state.rs`.
  - `AppState::sanitize_slots: Arc<tokio::sync::Semaphore>`.
  - `AppState::try_acquire_sanitize_slot(&self) -> Option<tokio::sync::OwnedSemaphorePermit>`.

**Why 2 and not 4:** at 393 MiB per job, 2 concurrent peaks at ~790 MiB of detector
memory on top of a ~1.3 GiB baseline. 4 would peak near 2.9 GiB. Sanitization is
not a latency-critical endpoint - it is a document job that already does OCR and
database work - so favouring a smaller peak over throughput is the right default,
and it is a named constant so the number is arguable rather than buried.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` block in `state.rs` (if the file has none, create one at the end):

```rust
    #[test]
    fn the_admission_bound_is_small_deliberately_and_documented() {
        // 393 MiB per concurrent sanitize job, measured. This test is the tripwire
        // on the number: raising the constant without redoing that arithmetic
        // should require deleting an assertion that says why.
        assert_eq!(
            SANITIZE_MAX_CONCURRENT, 2,
            "changing this changes peak memory: 2 x 393 MiB = 786 MiB of detector \
             memory on top of a ~1.3 GiB baseline. Re-measure before raising it."
        );
        assert!(
            SANITIZE_MAX_CONCURRENT * 393 < 1024,
            "keep the detector-memory peak under 1 GiB"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib the_admission_bound_is_small 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find value 'SANITIZE_MAX_CONCURRENT' in this scope`.

- [ ] **Step 3: Add the constant and the semaphore field**

In `state.rs`, above the `AppState` struct:

```rust
/// How many sanitize jobs may hold a detector set at once.
///
/// A sanitize job builds its own detector set, and with NER enabled that is a
/// 393 MiB allocation of resident F32 weights (measured 2026-09-27). Without a
/// bound, concurrency equals the Tokio worker count - 32 on the client hardware,
/// which has no CPU cap - so the worst case is 32 x 393 MiB = 12.6 GiB and an
/// out-of-memory kill.
///
/// 2 keeps the detector peak near 786 MiB. The job is not latency-critical, so a
/// small bound with queueing is the right trade.
pub const SANITIZE_MAX_CONCURRENT: usize = 2;
```

Add the field to `AppState` (match the existing field style - `AppState` derives `Clone`, and `Arc<Semaphore>` is `Clone`, so no other change is needed):

```rust
    /// Admission control for sanitize jobs. See SANITIZE_MAX_CONCURRENT.
    pub sanitize_slots: Arc<tokio::sync::Semaphore>,
```

- [ ] **Step 4: Add the acquire helper**

In the `impl AppState` block:

```rust
    /// Take a sanitize slot, or `None` when all are in use.
    ///
    /// Non-blocking on purpose: the caller decides whether to wait or to return
    /// 503. Failing closed means a *rejected* job, never a silently skipped one -
    /// if a job were dropped instead, the document would stay `pending` and
    /// unsearchable while the caller believed it had succeeded.
    pub fn try_acquire_sanitize_slot(
        &self,
    ) -> Option<tokio::sync::OwnedSemaphorePermit> {
        self.sanitize_slots.clone().try_acquire_owned().ok()
    }
```

- [ ] **Step 5: Construct it in `main.rs`**

In `main.rs`, where `AppState` is built (the struct literal around line 212), add:

```rust
                // Admission control for the NER detector allocation. Built once,
                // shared by every request through the Arc in AppState.
                sanitize_slots: Arc::new(tokio::sync::Semaphore::new(
                    crate::state::SANITIZE_MAX_CONCURRENT,
                )),
```

**There may be more than one `AppState` literal in the codebase** (a test helper, the seed binary). Find every one and fix them all, or the build fails:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
Select-String -Path 'pacgate-ai\crates\pacgate-api\src\*.rs','pacgate-ai\crates\pacgate-api\src\bin\*.rs' -Pattern 'AppState \{' | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }
```

- [ ] **Step 6: Run tests to verify**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
& "$env:USERPROFILE\.cargo\bin\cargo.exe" clippy -p pacgate-api --all-targets 2>&1 | Select-String -Pattern '^error|Finished' | Out-String
```

Expected: all `test result: ok.`, and clippy `Finished`.

- [ ] **Step 7: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/state.rs pacgate-ai/crates/pacgate-api/src/main.rs
git commit -m "feat(api): bound concurrent sanitize jobs with an admission semaphore

Each job builds its own 393 MiB detector set (measured). With no CPU cap in
compose, concurrency equals the Tokio worker count - 32 on the client hardware -
so the worst case is 12.6 GiB and an OOM kill. Two slots keeps the detector peak
near 786 MiB; the endpoint is not latency-critical, so queueing beats a large
peak.

The constant carries its own arithmetic in a test, so raising it means deleting a
sentence that explains why it is small."
```

---

### Task 3: Acquire the slot around the detection work

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/sanitize.rs:114-150`
- Test: same file

**Interfaces:**
- Consumes: `ApiError::service_unavailable` (Task 1), `AppState::try_acquire_sanitize_slot` (Task 2).
- Produces: `run_job` holds a permit for the duration of the detector build and sanitize call.

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` block in `sanitize.rs`:

```rust
    /// The bound must be enforced where the allocation happens. A permit acquired
    /// and dropped before the detector build would bound nothing.
    #[test]
    fn run_job_takes_a_sanitize_slot_before_building_detectors() {
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/sanitize.rs"),
        )
        .expect("read own source");

        let acquire = src
            .find("try_acquire_sanitize_slot")
            .expect("run_job must acquire a sanitize slot");
        let build = src
            .find("build_detectors(")
            .expect("run_job must build detectors");
        assert!(
            acquire < build,
            "the slot must be acquired BEFORE build_detectors: acquiring after the \
             allocation would bound nothing (acquire at byte {acquire}, build at {build})"
        );
    }
```

This is a source-order assertion, which is unusual - and it is the right test here because the bug it prevents is an *ordering* bug that no amount of functional testing catches: a permit taken after the build still passes every behavioural test while bounding nothing.

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api --lib run_job_takes_a_sanitize_slot 2>&1 | Out-String
```

Expected: FAIL with `run_job must acquire a sanitize slot`.

- [ ] **Step 3: Implement**

In `run_job`, immediately before the detector build (currently line ~146):

```rust
    // Take an admission slot BEFORE building detectors. The 393 MiB allocation
    // happens inside build_detectors, so a permit taken afterwards would bound
    // nothing while still passing every behavioural test - which is why the test
    // above asserts source order rather than behaviour.
    //
    // Fail closed with 503 rather than queueing without limit: a caller that
    // arrives over the bound is told to retry. The permit is held until the end
    // of the function, so it covers the sanitize call too.
    let _slot = state.try_acquire_sanitize_slot().ok_or_else(|| {
        ApiError::service_unavailable(format!(
            "sanitize capacity: {} job(s) already running; retry shortly",
            crate::state::SANITIZE_MAX_CONCURRENT
        ))
    })?;

    let mut sanitizer = pacgate_redact::Sanitizer::new(
        build_detectors(state.config.ner_model_dir.as_deref())?,
        MappingVersion::CURRENT,
    );
```

`_slot` is deliberately underscore-prefixed-but-named: it is unused by the body but must not be dropped early, and `let _ =` would drop it immediately. Keep it bound for the rest of the function.

- [ ] **Step 4: Run tests to verify**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api 2>&1 | Select-String -Pattern 'test result|FAILED|^error' | Out-String
```

Expected: all `test result: ok.`.

- [ ] **Step 5: Prove the bound actually holds under load**

This is the step that matters. A permit that is acquired and immediately dropped passes the test above, so exercise it with real concurrent requests:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-text-native-sanitize.ps1 *> $null
"sequential gate exit=$LASTEXITCODE"
"RSS after: $(docker exec pacgate-api sh -c 'grep VmRSS /proc/1/status')"
```

Then fire concurrent jobs and confirm the 503 path is reachable. Reuse the auth and upload flow from `scripts/test-text-native-sanitize.ps1`; the assertion is that at most `SANITIZE_MAX_CONCURRENT` succeed at once and the rest return **503**, not that all succeed.

If concurrent jobs could not be driven (auth, missing fixtures), say so explicitly and report that the bound is proven only by the source-order test plus the constant's arithmetic - **not** by observed behaviour.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-api/src/sanitize.rs
git commit -m "feat(api): hold an admission slot across the detector build

The permit is taken BEFORE build_detectors, because that call is where the 393 MiB
allocation happens. A permit taken after it would bound nothing while passing every
behavioural test, so the guard is a source-order assertion rather than a
functional one - an ordering bug that functional tests cannot see.

Over the bound the answer is 503, not a silent skip: a dropped job would leave the
document pending and unsearchable while the caller believed it succeeded."
```

---

### Task 4: Bound the container as a second layer

**Files:**
- Modify: `deploy/client-bundle/compose.prod.yaml`
- Modify: `deploy/client-bundle/compose.bundle.yaml`

**Interfaces:**
- Consumes: Task 3's in-process bound.
- Produces: a hard ceiling so that *any* unbounded allocation - not just the one this plan found - restarts the container instead of taking the machine down.

**Why both layers.** The semaphore bounds the allocation we know about. The container limit bounds the ones we do not. They are not redundant: a permit leak, a future large buffer, or a second model would all slip past the semaphore and be caught here.

- [ ] **Step 1: Add the limit to `compose.prod.yaml`**

Under the `pacgate-api:` service, next to `restart:`:

```yaml
    # Hard memory ceiling, as defence in depth behind the in-process admission
    # bound (SANITIZE_MAX_CONCURRENT in state.rs).
    #
    # Arithmetic: a sanitize job holds a 393 MiB NER detector set (measured
    # 2026-09-27), and the process retains one arena at ~1.27 GiB when idle.
    # 2 concurrent jobs + baseline + OCR/DB headroom fits in 4 GiB. The limit is a
    # backstop for allocations the semaphore does not govern, so it is set
    # generously - it exists to turn a runaway into a restart, not to be the
    # primary control.
    #
    # Do NOT set this near the real peak: an OOM kill mid-sanitize leaves a
    # document pending, and a limit too tight would cause that under normal load.
    mem_limit: 4g
    restart: unless-stopped
```

If `restart: unless-stopped` already exists on this service, do not duplicate it - only add `mem_limit`.

- [ ] **Step 2: Add the same to `compose.bundle.yaml`**

Identical block under its `pacgate-api:` service, with the identical comment. Both files define the service.

- [ ] **Step 3: Verify the limit is actually applied**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
& docker compose -f compose.prod.yaml config --quiet
"prod config exit=$LASTEXITCODE"
& docker compose -f compose.bundle.yaml config --quiet
"bundle config exit=$LASTEXITCODE"
```

Expected: both exit 0. Then confirm the value survives interpolation:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
& docker compose -f compose.prod.yaml config | Select-String -Pattern 'mem_limit|restart'
```

Expected: `mem_limit: 4294967296` (compose normalises `4g` to bytes).

- [ ] **Step 4: Apply and confirm against the running container**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
& docker compose -f compose.prod.yaml up -d --force-recreate --no-deps pacgate-api
"exit=$LASTEXITCODE"
Start-Sleep -Seconds 8
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
"Memory limit now: $(docker inspect pacgate-api --format '{{.HostConfig.Memory}}') bytes"
```

Expected: `4294967296` (4 GiB), not `0`. **`restart` does not re-read compose - only `--force-recreate` applies a new limit**, so a plain restart would show the old `0` and look like the change failed.

- [ ] **Step 5: Confirm the container still starts and sanitizes**

A memory limit that is too low shows up as an immediate restart loop, so confirm it is functional, not merely configured:

```powershell
Set-Location 'c:\Users\cubecloud-io\github-pr\pacgate-ai-pr'
Start-Sleep -Seconds 10
"state: $(docker ps --filter name=pacgate-api --format '{{.Status}}')"
& pwsh -NoProfile -File scripts/test-text-native-sanitize.ps1 *> $null
"sanitize gate exit=$LASTEXITCODE"
"RSS: $(docker exec pacgate-api sh -c 'grep VmRSS /proc/1/status')"
```

Expected: `Up`, gate exit 0, RSS well under 4 GiB.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add deploy/client-bundle/compose.prod.yaml deploy/client-bundle/compose.bundle.yaml
git commit -m "fix(compose): cap pacgate-api memory at 4 GiB as a backstop

Defence in depth behind the in-process admission bound. The semaphore governs the
allocation we know about (the 393 MiB detector set); this governs the ones we do
not - a permit leak, a future buffer, a second model. Set generously on purpose:
it exists to turn a runaway into a restart, not to be the primary control, and a
limit near the real peak would cause OOM kills under normal load."
```

---

### Task 5: The gate that keeps both bounds

**Files:**
- Create: `scripts/test-memory-bound.ps1`
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: Task 2's constant, Task 3's acquire call, Task 4's `mem_limit`.
- Produces: a gate with exit `0` pass, `1` real failure, `2` cannot check.

**Why:** both bounds are configuration that nothing observable enforces. An unset `mem_limit` looks identical to a set one from a running container's perspective until it OOMs; a dropped permit acquisition passes every behavioural test - which this plan proved, since the ordering bug is invisible functionally.

- [ ] **Step 1: Write the gate**

Create `scripts/test-memory-bound.ps1`:

```powershell
# Asserts the NER memory bound exists at both layers.
#
# WHY: a sanitize job holds a 393 MiB detector set (measured 2026-09-27). With no
# bound, concurrency equals the Tokio worker count - 32 on the client hardware,
# which has no CPU cap - so the worst case is 12.6 GiB. Neither bound is
# self-enforcing: an unset mem_limit looks identical to a set one until it OOMs,
# and a permit acquired AFTER the detector build passes every behavioural test
# while bounding nothing.
#
# SCOPE: this asserts CONFIGURATION and SOURCE ORDER, not runtime behaviour.
# Proving the bound holds under concurrent load needs a running stack and belongs
# to the live-stack suite.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== NER memory bound ===' -ForegroundColor Cyan

# 1. The in-process admission bound exists and is small.
$state = Get-Content 'pacgate-ai/crates/pacgate-api/src/state.rs' -Raw
$m = [regex]::Match($state, 'SANITIZE_MAX_CONCURRENT\s*:\s*usize\s*=\s*(\d+)')
if (-not $m.Success) {
    Fail 'state.rs does not define SANITIZE_MAX_CONCURRENT - concurrent sanitize jobs are unbounded, so peak memory is unbounded'
}
else {
    $n = [int]$m.Groups[1].Value
    if ($n -ge 1 -and $n -le 4) {
        Pass "SANITIZE_MAX_CONCURRENT = $n (peak detector memory ~$($n * 393) MiB)"
    }
    else {
        Fail "SANITIZE_MAX_CONCURRENT = $n; expected 1-4. At 393 MiB per job this is a $($n * 393) MiB peak, which is not a bound that helps"
    }
}

# 2. The permit is taken BEFORE the allocation. This is the ordering bug that
#    passes every functional test while bounding nothing.
$sanitize = Get-Content 'pacgate-ai/crates/pacgate-api/src/sanitize.rs' -Raw
$acquire = $sanitize.IndexOf('try_acquire_sanitize_slot')
$build = $sanitize.IndexOf('build_detectors(')
if ($acquire -lt 0) {
    Fail 'sanitize.rs never calls try_acquire_sanitize_slot - the admission bound is not wired in'
}
elseif ($build -lt 0) {
    Fail 'sanitize.rs never calls build_detectors - this gate cannot establish order, so it would pass vacuously'
}
elseif ($acquire -lt $build) {
    Pass 'the sanitize slot is acquired BEFORE build_detectors (order is correct)'
}
else {
    Fail "the sanitize slot is acquired AFTER build_detectors (acquire at byte $acquire, build at $build) - it would bound nothing while passing every behavioural test"
}

# 3. Every BASE compose file defining the service caps memory. Same discovery
#    rule as test-ner-enabled.ps1: overrides inherit, so they are not required to
#    repeat it, but a contradiction is a failure.
$composeFiles = Get-ChildItem 'deploy/client-bundle' -Filter 'compose*.yaml'
$bases = 0
foreach ($f in $composeFiles) {
    $text = Get-Content $f.FullName -Raw
    if ($text -notmatch '(?m)^\s{2}pacgate-api:\s*$') { continue }
    $isOverride = $f.Name -like '*-override.yaml'
    if (-not $isOverride) { $bases++ }

    # Slice to the pacgate-api service block: a mem_limit on another service must
    # not satisfy this check.
    $idx = $text.IndexOf("  pacgate-api:")
    $rest = $text.Substring($idx)
    $nextSvc = [regex]::Match($rest.Substring(10), '(?m)^  [a-z]')
    $block = if ($nextSvc.Success) { $rest.Substring(0, $nextSvc.Index + 10) } else { $rest }

    if ($block -match '(?m)^\s+mem_limit:\s*\S+') {
        Pass "$($f.Name) sets mem_limit on pacgate-api"
    }
    elseif ($isOverride) {
        Pass "$($f.Name) is a partial override; it inherits mem_limit from its base"
    }
    else {
        Fail "$($f.Name) defines pacgate-api but sets no mem_limit - an unbounded allocation other than the detector set would take the machine down instead of restarting the container"
    }
}
if ($bases -eq 0) {
    Fail 'found no BASE compose file defining pacgate-api - the discovery pattern is wrong, so this gate would pass vacuously'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-bound check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the NER memory bound holds at both layers' -ForegroundColor Green
exit 0
```

- [ ] **Step 2: Run it and confirm it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-memory-bound.ps1
"exit=$LASTEXITCODE"
```

Expected: exit 0, six PASS lines.

- [ ] **Step 3: Negative-test it - all three checks independently**

A gate never seen red is not evidence. Test each assertion separately:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
# (a) the ordering check - the subtle one
$f = 'pacgate-ai/crates/pacgate-api/src/sanitize.rs'
Copy-Item $f "$f.mbbak"
(Get-Content $f -Raw) -replace 'try_acquire_sanitize_slot', 'no_such_call' | Set-Content $f -Encoding UTF8
& pwsh -NoProfile -File scripts/test-memory-bound.ps1 *> $null
"(a) acquire removed -> exit=$LASTEXITCODE (expect 1)"
Move-Item "$f.mbbak" $f -Force; (Get-Item $f).LastWriteTime = Get-Date

# (b) the compose check
$c = 'deploy/client-bundle/compose.prod.yaml'
Copy-Item $c "$c.mbbak"
(Get-Content $c -Raw) -replace '(?m)^\s+mem_limit:\s*4g\s*$', '' | Set-Content $c -Encoding UTF8
& pwsh -NoProfile -File scripts/test-memory-bound.ps1 *> $null
"(b) mem_limit removed -> exit=$LASTEXITCODE (expect 1)"
Move-Item "$c.mbbak" $c -Force; (Get-Item $c).LastWriteTime = Get-Date

git status --short
```

Expected: both `exit=1`, and a clean tree afterwards. **If either exits 0, that assertion is not checking - fix it before continuing.**

- [ ] **Step 4: Add to the runner**

In `scripts/run-all-checks.ps1`, after the `'scripts/test-ner-enabled.ps1'` entry:

```powershell
    # Asserts the NER memory bound at both layers. Neither is self-enforcing: an
    # unset mem_limit looks like a set one until it OOMs, and a permit acquired
    # after the detector build passes every behavioural test. Self-contained
    # (reads files; no docker needed), so it belongs here.
    'scripts/test-memory-bound.ps1'
```

- [ ] **Step 5: Run the runner**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/run-all-checks.ps1 *> 'mb.txt'
"exit=$LASTEXITCODE"
Select-String -Path 'mb.txt' -Pattern 'test-memory-bound|ALL |FAIL' | ForEach-Object { $_.Line }
Remove-Item 'mb.txt' -Force
```

Expected: `test-memory-bound.ps1` PASS, gate count 26, exit 0.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add scripts/test-memory-bound.ps1 scripts/run-all-checks.ps1
git commit -m "ci(gates): assert the NER memory bound at both layers

Neither bound is self-enforcing. An unset mem_limit is indistinguishable from a
set one until the container OOMs, and a permit acquired AFTER the detector build
passes every behavioural test while bounding nothing - so the ordering assertion
checks source order, which is the only thing that catches it.

Slices to the pacgate-api service block when looking for mem_limit, so a limit on
another service cannot satisfy the check. Discovery-based like test-ner-enabled,
with a vacuous-pass guard. Negative-tested on all three checks independently."
```

---

### Task 6: State the memory requirement in the client deliverable

**Files:**
- Modify: `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md`

**Interfaces:**
- Consumes: F1's measurement and Task 2's constant.
- Produces: no code.

**Why a task:** spec §8 requires deployment constraints to be *stated*. A 4 GiB requirement and a 393 MiB per-job allocation are sizing facts an operator needs before deploying, and an unstated one surfaces as a mystery OOM.

- [ ] **Step 1: Add the sizing section**

Add after the "Enabling the name detector: what it costs" section:

```markdown
### Memory: what the name detector needs at runtime

Enabling NER does not only grow the image. A sanitize job builds its own detector
set, which is a **393 MiB allocation of resident memory per concurrent job**.

Measured on 2026-09-27 (the weights are F32, so they go resident on the first pass
and are not returned to the OS when the job ends):

| | |
|---|---|
| per concurrent sanitize job | **393 MiB** |
| process baseline after sanitizing | ~1.3 GiB |
| **concurrent jobs allowed** | **2** (enforced in the API) |
| container memory ceiling | **4 GiB** |

Two jobs is deliberate, not an oversight: the endpoint is a document job, not a
latency-critical one, so it queues rather than allocating a larger peak. A request
that arrives when both slots are taken gets **HTTP 503** and should be retried -
that is capacity, not a fault in the request.

**Deployment requirement: give `pacgate-api` at least 4 GiB.** The container is
capped there so an unexpected allocation restarts it rather than taking the
machine down. The cap is a backstop, and the 2-job bound is the primary control.

Diagnose with:

```powershell
docker exec pacgate-api printenv PACGATE_NER_MODEL_DIR   # /app/models/ner = NER on
docker exec pacgate-api sh -c "grep VmRSS /proc/1/status" # resident, expect < 2 GiB idle
docker inspect pacgate-api --format '{{.HostConfig.Memory}}'  # expect 4294967296
```
```

- [ ] **Step 2: Verify the numbers against the code, not against memory**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
"=== the enforced concurrency ==="
Select-String -Path 'pacgate-ai\crates\pacgate-api\src\state.rs' -Pattern 'SANITIZE_MAX_CONCURRENT\s*:\s*usize\s*=' | ForEach-Object { $_.Line.Trim() }
"=== the enforced ceiling ==="
Select-String -Path 'deploy\client-bundle\compose.prod.yaml' -Pattern 'mem_limit' | ForEach-Object { $_.Line.Trim() }
"=== what the container actually has ==="
docker inspect pacgate-api --format '{{.HostConfig.Memory}}'
```

Expected: `2`, `mem_limit: 4g`, and `4294967296`. If the document disagrees with the code, fix the document.

- [ ] **Step 3: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md
git commit -m "docs(aipc1): state the runtime memory requirement for NER

393 MiB per concurrent sanitize job, 2 jobs allowed, 4 GiB container ceiling, and
what a 503 means. Spec 8 requires deployment constraints to be declared, and an
unstated memory requirement surfaces as a mystery OOM rather than a known limit."
```

---

## Deferred to P5 (a separate plan) - do NOT start here

**`Arc<dyn Detector>` so detector sets are shared.** This removes the cost rather
than bounding it: *N x 393 MiB* becomes **393 MiB total**.

The constraint, recorded so P5 does not get it wrong: **share the detectors, never
the `Sanitizer`.** `Sanitizer::new` mints a random per-job placeholder token
(`pipeline.rs:37`) and that token is what prevents two jobs minting the same
placeholder name (spec §6.2, and the cross-job defect from plan 017 Task 12).
`Sanitizer` stores `detectors: Vec<Box<dyn Detector>>` by value, so the refactor
touches `detect/mod.rs`, `pipeline.rs` and `verify.rs`.

It is second on purpose: it is a correctness-sensitive change to the redaction
core, and it should not be the first line of defence against an OOM.

---

## Self-Review

**1. Spec coverage**

| Item | Task |
|---|---|
| Bound the concurrent detector allocation | Tasks 2-3 |
| Introduce 503 correctly rather than assuming the status | Task 1 |
| Container-level backstop | Task 4 |
| Keep both bounds from silently regressing | Task 5 |
| State the deployment constraint (§8) | Task 6 |
| Do not break per-job placeholder isolation | Global Constraints; P5 section |

**2. Placeholder scan**

No placeholders. Task 1 Step 3 says "match the surrounding constructors' exact field names - read them first", which is a fidelity instruction rather than an omission: the values are given, only the field names must be confirmed against the file.

**3. Type consistency**

- `SANITIZE_MAX_CONCURRENT: usize` - `state.rs` (Task 2), referenced by `sanitize.rs` (Task 3), the test (Task 2 Step 1), and the gate (Task 5).
- `sanitize_slots: Arc<tokio::sync::Semaphore>` - added in Task 2 Step 3, built in Task 2 Step 5.
- `try_acquire_sanitize_slot() -> Option<OwnedSemaphorePermit>` - defined Task 2 Step 4, called Task 3 Step 3, textually asserted Task 5 Step 1.
- `ApiError::service_unavailable(...)` - defined Task 1 Step 3, called Task 3 Step 3.
- `mem_limit: 4g` - Task 4, asserted Task 5, documented Task 6.
- `_slot` is bound to a named variable, not `let _ =`, because `let _` drops immediately. Stated in Task 3 Step 3.

One inconsistency found and fixed in review: Task 4 Step 4 originally used `docker compose restart`, which does **not** re-read compose and would have shown the old `Memory=0` - making a correct change look failed. Changed to `--force-recreate`, with the reason stated.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-27-ner-p4-memory-bound.md`.

**Dependency ordering:** Task 1 -> Task 2 -> Task 3 (three layers of the same guard, each compiling), Task 4 independent, Task 5 asserts 2-4, Task 6 documents the result.

**The three things that must not slip:**

1. **Task 3 Step 5.** The source-order test proves *ordering*, not that the bound holds under concurrency. If real concurrent requests cannot be driven, say so rather than implying the bound was observed.
2. **Task 5 Step 3.** Three independent negative tests. The ordering one is the subtle case and the reason the gate exists.
3. **Task 4 Step 4's `--force-recreate`.** A plain `restart` will show the old limit and make a correct change look broken.
