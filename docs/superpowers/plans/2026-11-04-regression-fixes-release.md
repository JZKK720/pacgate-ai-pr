# Regression Fixes — Release and Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the four verified regression fixes (empty-response guard, CJK full-text search, batched embeddings, retrieval cap) on a real release, without corrupting the already-published `v0.2.24` artifacts.

**Architecture:** Two independent lanes. **Lane A** verifies code on this dev box using a local-only image tag and a gitignored compose override — no version number is touched. **Lane B** is the client-facing release: one version bump, one tag, CI publishes, clients `install.ps1 -Update`. Lane A exists because `v0.2.24` is already published and immovable.

**Tech Stack:** Rust (workspace at `pacgate-ai/`), PostgreSQL 16 + pgvector, Ollama, Docker Compose, PowerShell 7, GitHub Actions → GHCR.

## Global Constraints

- **`v0.2.24` is published and must not be re-published under its own number.** It is tagged at commit `93067b29ade1`; all 6 GHCR images carry revision `93067b29ade1`; `scripts/test-release-provenance.ps1` asserts this. Re-publishing an existing version from newer `main` is the documented 0.1.28 defect — see the header of `scripts/test-release-provenance.ps1`.
- **Never retag a `ghcr.io/jzkk720/*` image locally.** That makes the local tag disagree with the registry digest. `scripts/verify-delivery-state.ps1` and `scripts/test-stack-version-coherence.ps1` exist to detect this.
- Next version is **`0.2.25`** — `bump-release-version.ps1` computes it; do not hand-edit.
- Every image-affecting change must land **before** the tag, never after. Files that reach an image: `pacgate-ai/**`, `deploy/pacgate-mcp/**`, `deploy/laya-serve/**`, `deploy/ocr-service/**`, `deploy/deer-flow-pacgate/**`, `deploy/deer-flow-frontend-pacgate/**`.
- Pre-existing red gates, **not** caused by this work and out of scope: `test-pdf-freshness.ps1`, `test-pdf-freshness-mutations.ps1`, `test-chat-no-auto-egress.ps1`, `test-compose-healthchecks.ps1`.
- Do not `docker pull` over a local dev build, and do not `docker tag` a local build over a `ghcr.io` name.

---

## File Structure

| Path | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-llm/src/lib.rs` | Reject unusable completions at the transport boundary | already modified |
| `pacgate-ai/crates/pacgate-agent/src/lib.rs` | Defense-in-depth on the natural-return path | already modified |
| `pacgate-ai/migrations/009_cjk_fulltext.sql` | CJK tsvector + `cjk_tsquery()` | new |
| `pacgate-ai/crates/pacgate-rag/src/lib.rs` | Migration include, `cjk_tsquery` call, `MAX_CONTEXT_CHARS` | already modified |
| `pacgate-ai/crates/pacgate-rag/src/embed.rs` | Batched `/v1/embeddings` | already modified |
| `pacgate-ai/crates/pacgate-core/src/http.rs` | Proxy test made env-independent | already modified |
| `deploy/client-bundle/compose.local-dev-override.yaml` | Gitignored dev-lane image override | new |
| `deploy/REGRESSION-FIXES-2026-11-04.md` | Evidence record | new |

---

## Task 1: Separate the two concerns into two commits

**Files:**
- Modify: (staging only — no file contents change)

**Interfaces:**
- Consumes: nothing
- Produces: commit `A` = model roster + benchmarks; commit `B` = regression fixes

Two unrelated changes are currently mixed in one working tree. The roster change touches client config; the fix change touches Rust. A reviewer must be able to reject one without the other.

- [ ] **Step 1: Confirm what is actually modified**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
git --no-pager status --short
```

Expected: 13 modified, 6 untracked (exactly the list in the previous session).

- [ ] **Step 2: Stage and commit the model-roster + benchmark work (commit A)**

```powershell
git add deploy/client-bundle/.env.example `
        deploy/client-bundle/compose.bundle.yaml `
        deploy/client-bundle/compose.prod.yaml `
        deploy/client-bundle/deer-flow-config.yaml `
        deploy/client-bundle/install.ps1 `
        deploy/client-bundle/ollama-models.txt `
        pacgate-ai/crates/pacgate-core/src/lib.rs `
        scripts/test-aipc-capacity-fit.ps1 `
        deploy/BENCHMARK-LOCAL-MODELS-2026-11-04.md `
        scripts/bench-local-models.ps1 `
        scripts/bench-tool-loop.ps1 `
        scripts/probe-thinking-suppression.ps1
git commit -m "feat(models): retire gemma4:12b, promote nemotron-3.5-bolt:e4b-q8_0 to LOW tier

Measured at the shipped 65536 context: decode 97.2 tok/s vs 31.5, prefill
1162 tok/s vs 526. It also passes json_schema structured output, the property
that had forced gemma4 to hold the tier.

TRADE-OFF accepted: its context ceiling IS 65536 and a larger request is
silently clamped, where gemma4 declared 262144.

Also adds the benchmark and probe scripts the decision was made with, and the
two bolt tags to the capacity-fit size table so they are measured rather than
reported as 'needs review'.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

- [ ] **Step 3: Stage and commit the regression fixes (commit B)**

```powershell
git add pacgate-ai/crates/pacgate-llm/src/lib.rs `
        pacgate-ai/crates/pacgate-agent/src/lib.rs `
        pacgate-ai/crates/pacgate-rag/src/lib.rs `
        pacgate-ai/crates/pacgate-rag/src/embed.rs `
        pacgate-ai/crates/pacgate-core/src/http.rs `
        pacgate-ai/migrations/009_cjk_fulltext.sql `
        deploy/REGRESSION-FIXES-2026-11-04.md
git commit -m "fix(llm,rag): stop reporting an empty completion as success; make CJK search work

Four measured defects, all producing 'endless steps with no end-result':

1. An empty completion was a success at EVERY layer. finish_reason was
   declared and never read. A model that spent its 300-token budget on hidden
   reasoning returned content='' with finish=length and HTTP 200, and the
   workflow returned 200 with final_content=''. interpret_choice() now rejects
   that case with an error naming the cause.

2. The keyword half of hybrid search matched ZERO of 918 Chinese chunks.
   to_tsvector('english') does not segment Han text: a whole sentence became
   one lexeme. Migration 009 splits to one token per character and queries
   with the phrase operator. 质保金: 0 -> 3 hits, 验收: 0 -> 88.

3. embed_batch looped single requests at ~2.07s fixed overhead each.
   One batched request is 28.8x faster (68,316ms -> 2,375ms for 32 chunks).

4. Retrieval had no ceiling; chunks run up to 6,006 chars. Capped at
   MAX_CONTEXT_CHARS = 12,000 on a char boundary.

Also fixes a proxy test that failed on any box exporting NO_PROXY=localhost.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

- [ ] **Step 4: Verify both commits and a clean tree**

```powershell
git --no-pager log --oneline -2
git --no-pager status --short
```

Expected: two commits, empty status output.

- [ ] **Step 5: Confirm the provenance gate is now RED (this is expected and is the whole reason Lane B exists)**

```powershell
pwsh -NoProfile -File scripts/test-release-provenance.ps1 2>&1 | Select-String 'PASS|FAIL|revision'
```

Expected: **FAIL** — an image-affecting file (`pacgate-ai/crates/**`) changed between `93067b29ade1` and `HEAD`. Before the commit it passed; committing the fix is what consumes `0.2.24`. A version bump is now mandatory for any client-facing delivery.

---

## Task 2: Make the dev lane honest (local-only image, no ghcr retag)

**Files:**
- Create: `deploy/client-bundle/compose.local-dev-override.yaml`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: `pacgate-api:local-dev` image tag; compose project `pacgate-dev`

The previous session's deploy was unsafe: it built a local image and tagged it `ghcr.io/jzkk720/pacgate-api:0.2.24`, so a local tag claimed to be a published artifact. The published digest has been restored. This task makes the dev path explicit so it cannot recur.

- [ ] **Step 1: Write the failing check first — assert no local tag shadows a ghcr name**

```powershell
# Run this NOW. It should find zero offenders after the restore in Task 0.
docker images --format '{{.Repository}}:{{.Tag}}' |
  Where-Object { $_ -like 'ghcr.io/jzkk720/*' } |
  ForEach-Object {
    $t = $_
    $digest = (docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' |
               Where-Object { $_ -like "$t *" }) -replace '.*\s(sha256:\S+)$','$1'
    if ($digest -eq 'sha256:' -or [string]::IsNullOrWhiteSpace($digest)) { Write-Host "NO REGISTRY DIGEST: $t" }
  }
```

Expected: no output. If a tag prints, it is a local build masquerading as published — `docker pull` it.

- [ ] **Step 2: Create the dev override file**

```yaml
# Local-only override for verifying an unreleased build against the real stack.
#
# WHY THIS EXISTS
#
# On 2026-11-04 a local `docker build` was tagged straight over
# `ghcr.io/jzkk720/pacgate-api:0.2.24`. The running container then reported a
# revision that no published artifact had, and the published digest became
# unreachable under its own name on this box. The published image has since been
# re-pulled; this file exists so the same shortcut is never the easy path again.
#
# The rule: a local build gets a LOCAL tag. Anything under ghcr.io/ is a
# published artifact and is only ever produced by CI.
#
# Usage:
#   docker build -f pacgate-ai/Dockerfile -t pacgate-api:local-dev ^
#     --build-arg PAC_SOURCE_REVISION=$(git rev-parse --short=12 HEAD) pacgate-ai
#   docker compose -p pacgate-dev -f compose.bundle.yaml -f compose.local-dev-override.yaml up -d
#   ... verify ...
#   docker compose -p pacgate-dev -f compose.bundle.yaml -f compose.local-dev-override.yaml down
#
# Do NOT point a client at this project. compose.bundle.yaml remains the client
# path and every pin in it must stay a published ghcr tag.

services:
  pacgate-api:
    image: pacgate-api:local-dev
```

- [ ] **Step 3: Gitignore it so a client bundle can never carry it**

```powershell
Add-Content .gitignore "`n# Local dev-lane image override (see compose.local-dev-override.yaml).`ndeploy/client-bundle/compose.local-dev-override.yaml"
```

- [ ] **Step 4: Verify the override renders and rewrites only that one image**

```powershell
cd deploy/client-bundle
docker compose -p pacgate-dev -f compose.bundle.yaml -f compose.local-dev-override.yaml config 2>&1 |
  Select-String 'image:'
```

Expected: `pacgate-api:local-dev` appears for `pacgate-api`; every other line still shows `ghcr.io/jzkk720/...:0.2.24`.

- [ ] **Step 5: Commit**

```powershell
git add .gitignore deploy/client-bundle/compose.local-dev-override.yaml
git commit -m "chore(dev): separate the local build lane from the published image lane

A local build was tagged over ghcr.io/jzkk720/pacgate-api:0.2.24 on 2026-11-04,
so the published digest became unreachable under its name and the running
container reported a revision no artifact had. This override gives local builds
their own tag and project name so that shortcut is no longer the easy path.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 3: Dev-lane verification of the fixed code

**Files:**
- Modify: none (verification only)

**Interfaces:**
- Consumes: `pacgate-api:local-dev` from Task 2
- Produces: a green dev stack running the fixed binary

- [ ] **Step 1: Build with the real revision**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
$sha = git rev-parse --short=12 HEAD
docker build -f pacgate-ai/Dockerfile -t pacgate-api:local-dev --build-arg PAC_SOURCE_REVISION=$sha pacgate-ai
```

Expected: `naming to docker.io/library/pacgate-api:local-dev done`.

- [ ] **Step 2: Bring up the dev project**

```powershell
cd deploy/client-bundle
docker compose -p pacgate-dev -f compose.bundle.yaml -f compose.local-dev-override.yaml up -d pacgate-api
Start-Sleep -Seconds 25
docker ps --filter name=pacgate-api --format '{{.Names}} {{.Status}} {{.Image}}'
```

Expected: `Up ... (healthy)` and image `pacgate-api:local-dev`.

- [ ] **Step 3: Assert migration 009 ran**

```powershell
docker logs pacgate-api --tail 40 2>&1 | Select-String 'RAG migrations applied'
```

Expected: the line ends with `+ 009_cjk_fulltext`.

- [ ] **Step 4: Assert CJK keyword search returns hits**

```powershell
docker exec pacgate-dev-db psql -U pacgate -d pacgate -tAc "SELECT count(*) FROM kb_chunks WHERE content_tsv @@ cjk_tsquery('验收');"
```

Expected: a non-zero count (88 on the 2026-11-04 corpus). A `0` means the migration or the query expression regressed.

- [ ] **Step 5: Assert an unsuppressed empty completion is rejected**

```powershell
$body = @{ model='nemotron-3.5-bolt:e4b-q8_0'
           messages=@(@{role='user';content='Summarise this matter in a 6-word title: 浦江新城二期总承包合同。'})
           max_tokens=60; stream=$false } | ConvertTo-Json -Depth 6 -Compress
(Invoke-RestMethod 'http://localhost:11434/v1/chat/completions' -Method Post -Body $body `
   -ContentType 'application/json' -TimeoutSec 300).choices[0] |
  Select-Object finish_reason, @{n='content_len';e={ "$($_.message.content)".Length }}
```

Expected: `finish_reason=length` with `content_len=0`. That is the shape `interpret_choice()` converts into a named error instead of an empty success.

- [ ] **Step 6: Run the document-generation e2e**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-document-generation-e2e.ps1
```

Expected: `RESULT: 19 passed, 0 failed`.

- [ ] **Step 7: Tear the dev project down**

```powershell
cd deploy/client-bundle
docker compose -p pacgate-dev -f compose.bundle.yaml -f compose.local-dev-override.yaml down
```

Expected: containers removed. `-v` is deliberately omitted so the Postgres volume survives.

---

## Task 4: Bump to 0.2.25

**Files:**
- Modify: `pacgate-ai/Cargo.toml`, `deploy/client-bundle/compose.prod.yaml`, `deploy/client-bundle/compose.bundle.yaml` (all via the script)

**Interfaces:**
- Consumes: commits from Tasks 1–2
- Produces: workspace version `0.2.25`, every compose pin at `0.2.25`

- [ ] **Step 1: Bump with the repo's script, never by hand**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/bump-release-version.ps1 -To 0.2.25
```

Expected: reports the files it rewrote. If it refuses, read its message — it checks `Cargo.toml` and both compose files agree.

- [ ] **Step 2: Confirm no `0.2.24` pin survives in a compose file**

```powershell
Select-String -Path deploy/client-bundle/compose.prod.yaml,deploy/client-bundle/compose.bundle.yaml `
              -Pattern 'ghcr\.io/jzkk720/[a-z0-9\-]+:0\.2\.24'
```

Expected: no output.

- [ ] **Step 3: Confirm docs and historical notes were NOT rewritten**

```powershell
git --no-pager diff --stat
```

Expected: only `Cargo.toml`, `compose.prod.yaml`, `compose.bundle.yaml` (plus `Cargo.lock`). Any `deploy/BENCHMARK-*` or `patches/*` file in the diff is a bug — those carry historical version strings as facts.

- [ ] **Step 4: Commit**

```powershell
git add pacgate-ai/Cargo.toml pacgate-ai/Cargo.lock `
        deploy/client-bundle/compose.prod.yaml deploy/client-bundle/compose.bundle.yaml
git commit -m "chore(release): 0.2.25

Carries the empty-response guard, CJK full-text search, batched embeddings and
the retrieval context cap.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 5: Pre-release gate run

**Files:**
- Modify: none

**Interfaces:**
- Consumes: `0.2.25` workspace
- Produces: a green suite except the four known-red gates

- [ ] **Step 1: Rust tests**

```powershell
cd pacgate-ai
cargo test --workspace --offline
```

Expected: every `test result: ok`. Any `FAILED` blocks the release.

- [ ] **Step 2: The Rust workspace gate**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-rust-workspace.ps1
```

Expected: `PASS pacgate-redact: tests + clippy clean`, exit 0.

- [ ] **Step 3: The full suite, and compare against the known-red baseline**

```powershell
pwsh -NoProfile -File scripts/run-all-checks.ps1 2>&1 | Select-String 'FAIL|GATE\(S\)'
```

Expected: exactly **four** failures, all pre-existing: `test-pdf-freshness.ps1`, `test-pdf-freshness-mutations.ps1`, `test-chat-no-auto-egress.ps1`, `test-compose-healthchecks.ps1`. A fifth failure is a regression introduced by this work — stop and fix it.

- [ ] **Step 4: Preflight the tag**

```powershell
pwsh -NoProfile -File scripts/preflight-release-tag.ps1 2>&1 | Select-String 'PASS|FAIL|refusing|exists'
```

Expected: passes, and `v0.2.25` is reported as not yet existing. If it complains the tag exists, stop — do not force.

---

## Task 6: Tag, publish, verify

**Files:**
- Modify: none

**Interfaces:**
- Consumes: green gates, `0.2.25`
- Produces: `v0.2.25` tag, 6 GHCR images at revision `<tag commit>`

- [ ] **Step 1: Push the commits first**

```powershell
git push origin main
```

Expected: 3 commits accepted.

- [ ] **Step 2: Tag and push the tag (this is what fires CI)**

```powershell
git tag -a v0.2.25 -m "Pacgate AI 0.2.25"
git push origin v0.2.25
```

Expected: `build-ghcr.yml` triggers on the `v0.2.*` tag push. Do **not** use `workflow_dispatch` — a dispatch checks out `main` while publishing the tag number, which is exactly how 0.1.28's tag stopped describing its artifacts.

- [ ] **Step 3: Watch the run**

```powershell
gh run list --workflow=build-ghcr.yml --limit 3
gh run watch
```

Expected: success. All six images published.

- [ ] **Step 4: Assert provenance from the registry**

```powershell
pwsh -NoProfile -File scripts/test-release-provenance.ps1
```

Expected: `PASS all 6 published images share one revision (<tag commit>)` and `PASSED: v0.2.25 identifies the <commit> artifacts clients will pull`. If it says an image-affecting file changed between the tag and HEAD, something landed after the tag — the tag is now wrong and must not be moved; release `0.2.26` instead.

- [ ] **Step 5: Report the digests**

```powershell
pwsh -NoProfile -File scripts/report-ghcr-digests.ps1
```

Expected: a digest per image, archived with the release.

---

## Task 7: Client install verification on a clean clone

**Files:**
- Modify: none

**Interfaces:**
- Consumes: published `0.2.25`
- Produces: evidence the client path works from scratch

**This is the only valid test for install-path changes** — this dev box has credentials, pulled models and rendered configs that hide first-run failures.

- [ ] **Step 1: Clone into a temp directory and run the installer**

```powershell
$tmp = Join-Path $env:TEMP 'pacgate-clean-verify'
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 --branch v0.2.25 https://github.com/JZKK720/pacgate-ai-pr.git $tmp
cd $tmp\deploy\client-bundle
pwsh -File install.ps1
```

Expected: completes without a 404 on any model tag and without needing `docker login ghcr.io`.

- [ ] **Step 2: Assert the tier models resolve**

```powershell
docker compose -p pacgate-ai-bundle -f compose.bundle.yaml exec pacgate-api `
  sh -c 'wget -qO- http://localhost:8080/version'
```

Expected: `revision` matching the `v0.2.25` commit, `version: 0.2.25`.

- [ ] **Step 3: Assert the LOW tier model is present**

```powershell
ollama list | Select-String 'nemotron-3.5-bolt:e4b-q8_0'
```

Expected: present. If absent, `ollama-models.txt` and the tier pin disagree — the 404 class of defect.

- [ ] **Step 4: Verify provenance and coherence on the clean stack**

```powershell
pwsh -File scripts/test-stack-version-coherence.ps1
pwsh -File scripts/verify-delivery-state.ps1
```

Expected: both pass.

- [ ] **Step 5: Clean up**

```powershell
cd $env:TEMP; Remove-Item 'pacgate-clean-verify' -Recurse -Force
```

---

## Task 8: Fix `test-compose-healthchecks.ps1` (unmasks real validation)

**Files:**
- Modify: `scripts/test-compose-healthchecks.ps1`

**Interfaces:**
- Consumes: nothing
- Produces: a gate that actually validates compose healthchecks

It fails for both compose files with:

```
compose.prod.yaml rendered config is not JSON: ... key 'no_proxy' ... 'NO_PROXY'
```

PowerShell's `ConvertFrom-Json` collapses case-insensitively. The gate has been silently unable to see healthcheck regressions.

- [ ] **Step 1: Reproduce and find the parse site**

```powershell
pwsh -NoProfile -File scripts/test-compose-healthchecks.ps1 2>&1 | Select-String 'not JSON'
Select-String -Path scripts/test-compose-healthchecks.ps1 -Pattern 'ConvertFrom-Json'
```

Expected: two failures. There are exactly **two** parse sites:
- **line 78** — `$cfg = $cfgJson | ConvertFrom-Json` (the declared compose config)
- **line 148** — `$liveCfg = (& docker compose -f compose.prod.yaml config --format json 2>$null) | ConvertFrom-Json` (the live rendered config)

Both need the fix; fixing only one leaves the other failing.

- [ ] **Step 2: Add `-AsHashtable` at BOTH call sites (lines 78 and 148)**

```powershell
# line 78, before
try { $cfg = $cfgJson | ConvertFrom-Json } catch {
# line 78, after
try { $cfg = $cfgJson | ConvertFrom-Json -AsHashtable } catch {

# line 148, before
try { $liveCfg = (& docker compose -f compose.prod.yaml config --format json 2>$null) | ConvertFrom-Json } finally { Pop-Location }
# line 148, after
try { $liveCfg = (& docker compose -f compose.prod.yaml config --format json 2>$null) | ConvertFrom-Json -AsHashtable } finally { Pop-Location }
```

`-AsHashtable` returns case-SENSITIVE keys, so the downstream property access must change from dot notation to indexing. Find every `$cfg.<something>` and `$liveCfg.<something>` in the file and convert:

```powershell
$cfg.services[$name].healthcheck.test      # before
$cfg['services'][$name]['healthcheck']['test']   # after
```

- [ ] **Step 3: Assert the gate now reaches its real assertions**

```powershell
pwsh -NoProfile -File scripts/test-compose-healthchecks.ps1; "exit=$LASTEXITCODE"
```

Expected: either `RESULT: 0 failure(s)` or a **real** healthcheck failure. A JSON-parse failure is no longer acceptable output.

- [ ] **Step 4: Mutation-check that it can still fail**

```powershell
# Temporarily remove a healthcheck from one service, run the gate, confirm FAIL, then restore.
git stash push deploy/client-bundle/compose.bundle.yaml
# ... edit out one healthcheck block ...
pwsh -NoProfile -File scripts/test-compose-healthchecks.ps1; "exit=$LASTEXITCODE"
git checkout deploy/client-bundle/compose.bundle.yaml
```

Expected: `exit=1` while the healthcheck is missing. A gate that cannot fail is not a gate.

- [ ] **Step 5: Commit**

```powershell
git add scripts/test-compose-healthchecks.ps1
git commit -m "test(compose): parse rendered config with -AsHashtable so the gate can run

ConvertFrom-Json collapses NO_PROXY and no_proxy into one key and throws, so both
compose files were reported 'not JSON' and the gate never reached its healthcheck
assertions. It has been unable to detect a healthcheck regression.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Self-Review

**Spec coverage**

| Requirement | Task |
|---|---|
| Land the four fixes on a release | 1 (commit B), 4, 6 |
| Answer: bump or rebuild 0.2.24? | Global Constraints + Task 1 Step 5 (provenance red) |
| No local tag shadowing ghcr | Task 2 |
| Verify before releasing | Task 3, 5 |
| Publish correctly | Task 6 |
| Prove the client path | Task 7 |
| Stop the masked gate | Task 8 |

**Placeholder scan:** no TBD/TODO; every step carries a real command or diff. Task 8 Step 4 describes an intentional manual edit, with the exact restore command.

**Type consistency:** `interpret_choice(choice: Choice) -> Result<(Option<String>, Vec<ToolCall>)>` matches its only caller, `complete()`. `cjk_tsquery(text) RETURNS tsquery` is used identically in the index and in `keyword_search`. `merge_results(..., max_chars: usize)` matches its single caller via `search_capped`. `EmbedBatchRequest { model, input: Vec<String> }` matches the `/v1/embeddings` array form.

**Known gap, deliberate:** Task 3 proves the fix on **this** box. It cannot prove the 65536 context ceiling is safe for a workload that needs more, because nothing in the stack requests more today. If a workflow ever needs >65536, `nemotron-3.5-bolt:e4b-q8_0` is the wrong tag and must be overridden per tier.
