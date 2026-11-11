# Plan 033 - Sync local repo with upstream, pin the stack to GHCR 0.2.32, and verify the full runtime

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring this checkout from its 0.2.6-era AIPC2 branch onto upstream `main` (0.2.32), keep every local-only fix that upstream never took, pin all five Pacgate images to `0.2.32`, and prove the running stack matches the pin with gates and live assertions.

**Architecture:** One merge commit (`upstream/main` into `main`) resolves 12 conflict hunks across 7 files, then a small "re-apply what upstream lacks" pass restores four local-only fixes that the merge cannot carry because upstream has no counterpart. The runtime is then moved by editing the compose pins and `.env` model tags, pulling the published images, and recreating the stack. Verification is layered: static gates first (no stack needed), then image identity, then live lane assertions.

**Tech Stack:** git 2.55, PowerShell 7.6 (`pwsh`; PS 5.1 only where a gate explicitly tests it), Docker 29.9 + Compose, Ollama (ROCm, AMD RX 7600 XT 16 GB), Rust workspace (`pacgate-ai`), Python 3.12 inside `deer-flow`.

## Global Constraints

- Never `git reset --hard`, `git checkout -- <path>`, or auto-stash. This is a live install and the 32 local-only commits have no remote backup.
- Do not rebuild or re-tag images. `0.2.32` is already published for all five Pacgate images plus `laya-serve`; the change is a pin, not a build.
- Do not use Windows PowerShell 5.1 to run `install.ps1` or any gate that shells out to `docker`; native stderr becomes a terminating error under `$ErrorActionPreference = 'Stop'`. Use `pwsh`.
- Do not propose `docker login ghcr.io` for the client path. The images are public; verify with an anonymous manifest HEAD.
- Do not re-flag cloud chat models (`deepseek-v4.1-flash:cloud`, `glm-5.3-flash:cloud`) as a residency bug. That egress is a decided trade-off (2026-08-30). The RAG pipeline stays on-device.
- Do not use em-dashes in visible copy; use hyphens.
- Every gate claim must be shown, not asserted. A gate that cannot fail is not a gate.
- `deploy/client-bundle/.env` is gitignored and holds live secrets. Edit it in place; never commit it.

---

## Verified state (evidence gathered 2026-11-08)

| Claim | Verdict | Evidence |
| --- | --- | --- |
| `origin/main` and `upstream/main` are the same commit | **TRUE** | both `17a498ea` |
| Local `main` is behind upstream | **TRUE** | `git rev-list --left-right --count main...upstream/main` = `40  160` |
| Local `main` is ahead of `fork/main` | **TRUE** | `git rev-list --left-right --count main...fork/main` = `212  0` |
| Merge base | `44f7f43b` | `git merge-base main upstream/main` |
| Upstream delta since base | 167 files, +29105 / -953 | `git diff --stat 44f7f43b upstream/main` |
| Local delta since base | 34 files, +2255 / -76 | `git diff --stat 44f7f43b main` |
| Local commits upstream does not have (by patch-id) | **32** | `git cherry -v upstream/main main` |
| Merge conflicts | **12 hunks in 7 files** | `git merge-tree --write-tree main upstream/main` |
| `0.2.32` published for all five images + `laya-serve` | **TRUE** | anonymous GHCR `tags/list` per repo |
| Running stack | `0.2.6` on all five Pacgate services | `docker ps` |
| Local `.env` model tags | `MID=ornith-1.5:9b`, `LOW=gemma4:12b-it-qat` | `deploy/client-bundle/.env` |
| Upstream `.env.example` model tags | `MID=LOW=nemotron-3.5-bolt:e4b-q8_0` | `git show upstream/main:deploy/client-bundle/.env.example` |
| `nemotron-3.5-bolt:e4b-q8_0` present locally | **FALSE** | `ollama list` |
| `gemma4:12b-it-qat` present locally | **TRUE** (7.2 GB) | `ollama list` |
| GPU | AMD RX 7600 XT, 16 GB, ROCm `gfx1102` | `scripts/test-ollama-gpu-residency.ps1` header + `Win32_VideoController` |
| `PACGATE_SANITIZER_KEY` in local `.env` | **ABSENT** | `Select-String` over `.env` |
| `PACGATE_LAYA_URL` / `LAYA_IMAGE` in local `.env` | **ABSENT** (compose defaults apply) | same |

### Local-only fixes upstream does NOT have (must be re-applied after the merge)

| Fix | Local artifact | Upstream state |
| --- | --- | --- |
| MCP HTTP client read timeout 900 s + per-server header forwarding | `deploy/client-bundle/patches/deer-flow-mcp-client.py` + 2 compose mounts | **file absent**, no mount, no `httpx_client_factory` anywhere |
| MCP server returns JSON on the POST (`json_response=True`) | `deploy/pacgate-mcp/server.py` | **absent** |
| Memory proxy preserves query parameters | `deploy/frontend-patches/files/src/app/api/memory/route.ts` and `[...path]/route.ts` | **absent** (upstream has the files, without the `backendUrl.search` lines) |
| `reasoning_effort` kwarg-collision guard on the thinking-ENABLED path | `deploy/client-bundle/patches/deer-flow-model-factory.py` | **absent** (upstream guards only the disabled path) |

### Local-only fixes upstream ALREADY has (drop the local duplicate)

- `pacgate_write_memory` `headers=` kwarg on `PacgateApi.post` - upstream `server.py:203` has it.
- `setup-qm.ps1` bare-email `ADMIN_GRANTS` fix - auto-merges.
- `Invoke-WithNativeStderr` helper - upstream has 42 call sites vs our 40.

---

## File structure

| File | Responsibility in this plan |
| --- | --- |
| `.gitignore` | Union of both sides' new ignore rules (Task 2) |
| `deploy/client-bundle/install.ps1` | Take upstream's pull-diagnosis logic; keep our `2>$null` capture comment (Task 2) |
| `scripts/audit-deer-flow-patches.ps1` | Keep our completeness check, take upstream's `$patchMap` (Task 2) |
| `scripts/remediate-sanitized-chunk-egress.ps1` | Take upstream's SQL (checksum filter is now wrong), keep our tenant column (Task 2) |
| `scripts/test-loop-detection-window.ps1` | Take upstream's `Invoke-NativeCapture` wholesale (Task 2) |
| `scripts/test-mcp-tool-surface.ps1` | Take upstream's `ConvertFrom-JsonArray`, keep our empty-source exit 1 (Task 2) |
| `scripts/test-release-provenance.ps1` | Take upstream's `Get-ShadowedPath` wholesale (Task 2) |
| `deploy/client-bundle/compose.prod.yaml`, `compose.bundle.yaml` | Pin `0.2.32`; keep the `deer-flow-mcp-client.py` mount (Tasks 3, 4) |
| `deploy/client-bundle/.env` | Model tags, `PACGATE_SANITIZER_KEY` (Task 4) |
| `deploy/client-bundle/ollama-models.txt` | Upstream's version is authoritative (auto-merges) |
| `deploy/pacgate-mcp/server.py` | Verify `json_response=True` survived the auto-merge (Task 3) |

---

## Task 1: Safety snapshot and working branch

**Files:** none modified.

**Interfaces:**
- Consumes: nothing.
- Produces: branch `sync/upstream-0.2.32`; a restorable snapshot at `_local-backup-<timestamp>/`; a bundle at `_local-backup-<timestamp>/pre-sync.bundle`.

- [ ] **Step 1: Confirm the tree is clean apart from the known untracked plan**

Run:
```powershell
cd C:\Users\pacga\github-pr\pacgate-law\pacgate-ai-pr
git status --porcelain=v1
```
Expected: exactly one line, `?? plans/032-aipc-memory-prompt-rollout.md`. Anything else must be committed or moved aside before continuing.

- [ ] **Step 2: Snapshot the live data and env**

Run:
```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dst = "_local-backup-$stamp"
New-Item -ItemType Directory -Path $dst | Out-Null
Copy-Item deploy\client-bundle\.env "$dst\.env" -Force
Copy-Item deploy\client-bundle\data\deer-flow\checkpoints.db "$dst\checkpoints.db" -Force
Copy-Item deploy\client-bundle\data\deer-flow\.jwt_secret "$dst\.jwt_secret" -Force
git bundle create "$dst\pre-sync.bundle" --all
"snapshot: $dst"
```
Expected: `snapshot: _local-backup-<stamp>` and a bundle of roughly the repo size. `_local-backup-*/` is already gitignored.

- [ ] **Step 3: Create the working branch**

Run:
```powershell
git switch -c sync/upstream-0.2.32
```
Expected: `Switched to a new branch 'sync/upstream-0.2.32'`.

- [ ] **Step 4: Record the pre-sync runtime baseline**

Run:
```powershell
docker ps --format '{{.Names}}\t{{.Image}}' | Sort-Object | Tee-Object -FilePath "_local-backup-$stamp\pre-sync-containers.txt"
```
Expected: five `ghcr.io/jzkk720/*:0.2.6` lines plus the non-Pacgate services. This file is the "before" for Task 7.

---

## Task 2: Merge `upstream/main` and resolve the 12 conflict hunks

**Files:**
- Modify: `.gitignore`
- Modify: `deploy/client-bundle/install.ps1`
- Modify: `scripts/audit-deer-flow-patches.ps1`
- Modify: `scripts/remediate-sanitized-chunk-egress.ps1`
- Modify: `scripts/test-loop-detection-window.ps1`
- Modify: `scripts/test-mcp-tool-surface.ps1`
- Modify: `scripts/test-release-provenance.ps1`

**Interfaces:**
- Consumes: branch `sync/upstream-0.2.32` from Task 1.
- Produces: a merge commit whose tree contains upstream `17a498ea` plus the 32 local-only commits. Later tasks assume `deploy/client-bundle/patches/deer-flow-mcp-client.py` still exists and is still mounted.

- [ ] **Step 1: Start the merge**

Run:
```powershell
git merge --no-ff --no-commit upstream/main
```
Expected: `Automatic merge failed; fix conflicts and then commit the result.` with 7 conflicted paths.

- [ ] **Step 2: Resolve `.gitignore` - keep BOTH sides**

Replace the single conflict block with the union, in this order:

```gitignore
# Pre-upgrade safety snapshots (deer-flow SQLite data + .env). Machine-local,
# can be hundreds of MB, and carries live credentials - never tracked.
/_local-backup-*/

# Gate-suite and upgrade transcripts written during a session.
/checks-*.log
/upgrade-*.log

# Staged laya weights (staged per machine, never committed). laya-weights/ is the
# staging target for the laya-serve BUILD CONTEXT: the weights are baked into that
# image, so CI needs them present only at build time.
laya-hf-cache/
deploy/laya-serve/laya-weights/

# Local dev-lane image override (see the file's own header for why).
# A local build must never be tagged over a published ghcr artifact.
deploy/client-bundle/compose.local-dev-override.yaml
```

- [ ] **Step 3: Resolve `deploy/client-bundle/install.ps1` hunk 1 - take upstream**

Upstream's version is strictly better: it derives `$dirtyBranch` instead of re-reading `HEAD`, guards `$localHead` being empty, and drops the `catch { }` that swallowed the diagnosis. Replace the whole conflict block with:

```powershell
                        $remoteHead = (Invoke-WithNativeStderr { git rev-parse "origin/$dirtyBranch" 2>$null } | Out-String).Trim()
                        $localHead = (Invoke-WithNativeStderr { git rev-parse HEAD 2>$null } | Out-String).Trim()
                        if ($remoteHead -and $localHead -and $remoteHead -ne $localHead) {
                            $behindRef = $remoteHead.Substring(0, 7)
                        }
                    }
                }
                $cur = (Invoke-WithNativeStderr { git rev-parse HEAD 2>$null } | Out-String).Trim()
                if ($cur -and $cur.Length -ge 7) { $cur = $cur.Substring(0, 7) } else { $cur = $null }
```

- [ ] **Step 4: Resolve `deploy/client-bundle/install.ps1` hunk 2 - take upstream's comment**

Both comments say the same thing; upstream's names the enforcing gate. Replace the conflict block with:

```powershell
        # Convention in this file (and enforced by scripts/test-ps51-native-stderr.ps1):
        # no executable `2>&1` anywhere - under PS 5.1 a native process writing to
        # stderr raises while it is being redirected, and the pipeline dies. The
        # helper flips ErrorActionPreference, and the redirect is `2>$null` so the
        # probe's stderr cannot kill the update. Success is judged by the marker we
        # asked for, not by exit code, so a missing marker falls through to WARN.
```

- [ ] **Step 5: Resolve `scripts/audit-deer-flow-patches.ps1` - keep our completeness check, take upstream's map**

Our side replaced the map with a comment because the map moved to the top of the file. Upstream still defines it here. The correct resolution is to keep the comment (the map is already defined at line ~62 on our side) and delete upstream's duplicate definition. Replace the conflict block with:

```powershell
# (defined near the top, before the completeness check)
```

Then widen the map at the top of the file. Our map has 8 entries; upstream's has 10; and our own `deer-flow-mcp-client.py` mount is in neither. The completeness check below **reports** (it does not fail) any mounted patch missing from the map, so leaving the gaps open produces a yellow NOTE on every audit run and leaves the new mounts unchecked. The map must read:

```powershell
$patchMap = [ordered]@{
    'deer-flow-agent.py'       = 'backend/packages/harness/deerflow/agents/lead_agent/agent.py'
    'deer-flow-loop-detection.py' = 'backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py'
    'deer-flow-artifacts.py'   = 'backend/app/gateway/routers/artifacts.py'
    'deer-flow-prompt.py'      = 'backend/packages/harness/deerflow/agents/lead_agent/prompt.py'
    'deer-flow-sync.py'        = 'backend/packages/harness/deerflow/tools/sync.py'
    'deer-flow-thread-runs.py' = 'backend/app/gateway/routers/thread_runs.py'
    'deer-flow-uploads.py'     = 'backend/app/gateway/routers/uploads.py'
    'deer-flow-run-recursion-cap.py' = 'backend/app/gateway/services.py'
    'deer-flow-worker.py'      = 'backend/packages/harness/deerflow/runtime/runs/worker.py'
    # Pacgate 2026-11-06: heading titles rendered into the agent's prompt carried
    # raw pymupdf4llm markup ("**<mark>1.1 ...</mark>**") on 59 of 241 headings.
    'deer-flow-file-conversion.py' = 'backend/packages/harness/deerflow/utils/file_conversion.py'
    # Pacgate 2026-10-30: MCP tool ARGUMENTS were never path-translated.
    'deer-flow-mcp-args.py'    = 'backend/packages/harness/deerflow/mcp/tools.py'
    # Pacgate 2026-10-11: MCP HTTP client read timeout + per-server headers.
    # LOCAL-ONLY - upstream has no counterpart for this patch.
    'deer-flow-mcp-client.py'  = 'backend/packages/harness/deerflow/mcp/client.py'
}
```

- [ ] **Step 6: Resolve `scripts/remediate-sanitized-chunk-egress.ps1` - take upstream's SQL, keep our tenant column**

Upstream removed the checksum filter because a checksum-invalid ID-shaped run is a real leak since 2026-11-02. Our tenant column is still required. Replace both conflict blocks so the query reads:

```sql
SELECT c.document_id::text || '|' || c.tenant_id::text
FROM kb_chunks c
JOIN documents d ON d.id = c.document_id
WHERE c.sanitization_state = 'sanitized'
  AND ($rawPredicate)
GROUP BY c.document_id, c.tenant_id
ORDER BY c.tenant_id, c.document_id
LIMIT $Limit;
```

- [ ] **Step 7: Resolve `scripts/test-loop-detection-window.ps1` - take upstream wholesale**

Upstream's `Invoke-NativeCapture` is the same fix with a measured reproduction attached, and its call sites drop the `2>&1` that our version still passes. For all three hunks take the `upstream/main` side verbatim. Then confirm no `2>&1` remains:

```powershell
Select-String -Path scripts\test-loop-detection-window.ps1 -Pattern '2>&1'
```
Expected: no output.

- [ ] **Step 8: Resolve `scripts/test-mcp-tool-surface.ps1` - take upstream's parser, keep our exit 1**

Take the `upstream/main` side of the conflict (the `ConvertFrom-JsonArray` rewrite). Our separate addition - exiting 1 when the source declares zero tools - is outside the conflict block and survives. Verify:

```powershell
Select-String -Path scripts\test-mcp-tool-surface.ps1 -Pattern 'if \(\$expected\.Count -eq 0\)'
```
Expected: one match.

- [ ] **Step 9: Resolve `scripts/test-release-provenance.ps1` - take upstream wholesale**

Upstream replaced the hand-maintained `$bindMounted` list with `Get-ShadowedPath`, which derives the shadowing from the compose files themselves. Our `$bindMounted` fix is subsumed. Take the `upstream/main` side of both hunks, then confirm the old variable is gone:

```powershell
Select-String -Path scripts\test-release-provenance.ps1 -Pattern 'bindMounted|\$overridden'
```
Expected: no output.

- [ ] **Step 10: Confirm no conflict markers remain anywhere**

Run:
```powershell
git diff --check
Select-String -Path (git ls-files) -Pattern '^(<<<<<<<|>>>>>>>) ' -ErrorAction SilentlyContinue
```
Expected: no output from either.

- [ ] **Step 11: Verify the local-only artifacts survived the auto-merge**

Run:
```powershell
Test-Path deploy\client-bundle\patches\deer-flow-mcp-client.py
Select-String -Path deploy\client-bundle\compose.prod.yaml,deploy\client-bundle\compose.bundle.yaml -Pattern 'deer-flow-mcp-client.py'
Select-String -Path deploy\pacgate-mcp\server.py -Pattern 'json_response=True'
Select-String -Path deploy\frontend-patches\files\src\app\api\memory\route.ts -Pattern 'backendUrl.search'
```
Expected: `True`, two mount matches, one `json_response=True`, one `backendUrl.search`.

- [ ] **Step 12: Commit the merge**

Run:
```powershell
git add -A
git commit -m "merge: sync upstream/main (0.2.32) into the AIPC2 stack

Resolves 12 conflict hunks across 7 files. Upstream wins where it
supersedes a local fix (loop-detection capture helper, release-provenance
shadow detection, sanitizer checksum filter, installer pull diagnosis);
local wins where it adds coverage upstream lacks (patch-map completeness
check, empty-source exit 1, tenant-scoped repair query, gitignore rules).

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```
Expected: one merge commit. `git rev-list --left-right --count main...upstream/main` now reports `41  0` - zero on the right means nothing upstream is missing. (The left count is 40 pre-existing local commits plus this merge; `git cherry -v upstream/main main` still shows 32, because 8 of the 40 are merge commits or commits whose patch upstream already carries.)

---

## Task 3: Re-apply the four local-only fixes upstream never took

**Files:**
- Modify: `deploy/pacgate-mcp/server.py`
- Modify: `deploy/frontend-patches/files/src/app/api/memory/route.ts`
- Modify: `deploy/frontend-patches/files/src/app/api/memory/[...path]/route.ts`
- Modify: `deploy/client-bundle/patches/deer-flow-model-factory.py`

**Interfaces:**
- Consumes: the merged tree from Task 2.
- Produces: a tree where the MCP long-call lane, the memory query-parameter lane, and the thinking-enabled `reasoning_effort` guard are all present. Task 7 asserts each one live.

- [ ] **Step 1: Confirm which of the four actually need re-applying**

Run:
```powershell
Select-String -Path deploy\pacgate-mcp\server.py -Pattern 'json_response=True'
Select-String -Path deploy\frontend-patches\files\src\app\api\memory\route.ts -Pattern 'backendUrl.search'
Select-String -Path deploy\client-bundle\patches\deer-flow-model-factory.py -Pattern 'if "reasoning_effort" in effective_wte'
```
Expected: the first two already match (they auto-merged). The third is expected to be **absent** - that is the one to add.

- [ ] **Step 2: Add the thinking-enabled `reasoning_effort` guard**

In `deploy/client-bundle/patches/deer-flow-model-factory.py`, inside the `if thinking_enabled and has_thinking_settings:` branch, immediately after `model_settings_from_config.update(effective_wte)`, insert:

```python
            # Pacgate 2026-10-10: same kwarg-collision guard as the
            # when_thinking_disabled branch below, mirrored for the
            # thinking-ENABLED path. when_thinking_enabled may set
            # reasoning_effort (e.g. "none" for glm-5.3-flash:cloud, whose
            # thinking channel burns the entire max_tokens budget on Ollama's
            # /v1 endpoint even when thinking is requested). The caller (lead
            # agent) also passes reasoning_effort as a constructor kwarg ->
            # ChatOpenAI() got multiple values for keyword argument
            # 'reasoning_effort'. Config wins; drop the caller kwarg.
            if "reasoning_effort" in effective_wte:
                kwargs.pop("reasoning_effort", None)
```

- [ ] **Step 3: Verify the patch still parses**

Run:
```powershell
python -c "import ast,sys; ast.parse(open(r'deploy/client-bundle/patches/deer-flow-model-factory.py',encoding='utf-8').read()); print('OK')"
```
Expected: `OK`.

- [ ] **Step 4: Commit**

Run:
```powershell
git add deploy/client-bundle/patches/deer-flow-model-factory.py
git commit -m "fix(model-factory): keep the reasoning_effort guard on the thinking-enabled path

Upstream guards only when_thinking_disabled. The enabled path still
collides with the lead agent's constructor kwarg for cloud models whose
when_thinking_enabled sets reasoning_effort.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 4: Pin the stack to 0.2.32 and reconcile `.env`

**Files:**
- Modify: `deploy/client-bundle/compose.prod.yaml`
- Modify: `deploy/client-bundle/compose.bundle.yaml`
- Modify: `deploy/client-bundle/.env` (gitignored)

**Interfaces:**
- Consumes: the merged tree from Tasks 2-3.
- Produces: both compose lanes pinning `0.2.32` on all five Pacgate images; `.env` carrying the model tags and the sanitizer key the 0.2.32 images expect.

- [ ] **Step 1: Confirm the pins the merge produced**

Run:
```powershell
Select-String -Path deploy\client-bundle\compose.prod.yaml,deploy\client-bundle\compose.bundle.yaml -Pattern 'ghcr.io/jzkk720/'
```
Expected: every Pacgate image line reads `:0.2.32`. If any still reads `:0.2.6`, the merge took our side of that hunk - change it to `0.2.32`.

- [ ] **Step 2: Confirm the two lanes agree on every pin**

Run:
```powershell
$prod = (Select-String -Path deploy\client-bundle\compose.prod.yaml -Pattern 'image: ghcr\.io/jzkk720/(\S+)').Matches.Groups[1].Value | Sort-Object
$bundle = (Select-String -Path deploy\client-bundle\compose.bundle.yaml -Pattern 'image: ghcr\.io/jzkk720/(\S+)').Matches.Groups[1].Value | Sort-Object
Compare-Object $prod $bundle
```
Expected: no output (identical sets). `laya-serve` appears only in `compose.prod.yaml` under the `laya` profile - if it shows as a difference, that is expected and correct.

- [ ] **Step 3: Add the sanitizer key the 0.2.32 API expects**

Run:
```powershell
$key = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
Add-Content -Path deploy\client-bundle\.env -Value "PACGATE_SANITIZER_KEY=$key"
Select-String -Path deploy\client-bundle\.env -Pattern 'PACGATE_SANITIZER_KEY'
```
Expected: one line, 64 hex characters. Without it the sanitizer derives identifier tokens from the JWT secret, which rotates on reinstall and silently breaks token stability across upgrades.

- [ ] **Step 4: Decide the model tags (see the open decision in the handoff)**

The upstream default is `MID=LOW=nemotron-3.5-bolt:e4b-q8_0`. On this machine that tag is **not installed**, so pinning it before Task 8 would leave the API pointing at a missing model. Two valid orders:

- **Order A (recommended, no downtime gap):** keep `MID=ornith-1.5:9b`, `LOW=gemma4:12b-it-qat` for the 0.2.32 bring-up, then switch in Task 8 after the pull succeeds.
- **Order B:** pull `nemotron-3.5-bolt:e4b-q8_0` first (Task 8 Step 1), then set both tags here.

Record the choice in the commit message. Do not leave `.env` pointing at a tag `ollama list` does not show.

- [ ] **Step 5: Verify the rendered config parses**

Run:
```powershell
cd deploy\client-bundle
docker compose -f compose.prod.yaml -f compose.bundle.yaml config --quiet
```
Expected: exit 0, no output. A non-zero exit here means a YAML or interpolation error that would fail the recreate.

- [ ] **Step 6: Commit the pin**

Run:
```powershell
cd C:\Users\pacga\github-pr\pacgate-law\pacgate-ai-pr
git add deploy/client-bundle/compose.prod.yaml deploy/client-bundle/compose.bundle.yaml
git commit -m "chore(deploy): pin the stack to the published 0.2.32 images

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 5: Static gates (no stack required)

**Files:** none modified unless a gate fails.

**Interfaces:**
- Consumes: the merged tree from Tasks 2-4.
- Produces: a green static suite, which is the precondition for touching the running stack.

- [ ] **Step 1: Run the full gate suite**

Run:
```powershell
pwsh -NoProfile -File scripts\run-all-checks.ps1 -SkipOcrPull 2>&1 | Tee-Object -FilePath checks-0.2.32.log
```
Expected: `ALL <n> GATES PASSED`. Exit 2 (`CANNOT CHECK`) is reported as SKIP and does not fail the run; exit 1 is a real failure.

- [ ] **Step 2: Triage any failure by class**

For each `[FAIL]`, decide which of the three classes it is before changing anything:

- **Gate defect** (the gate is wrong about a correct tree) - fix the gate, and add the mutation that would have caught it.
- **Real regression** (the merge dropped something) - fix the code.
- **Environment** (needs a running stack or a gitignored checkout) - it should have exited 2; if it exited 1, that is a gate defect.

- [ ] **Step 3: Confirm the two gates that specifically cover this change**

Run:
```powershell
pwsh -NoProfile -File scripts\test-baked-patch-parity.ps1
pwsh -NoProfile -File scripts\test-compose-healthchecks.ps1
```
Expected: both exit 0. `test-baked-patch-parity` is the one that catches a baked patch with no mount in both lanes - the exact shape of the `deer-flow-mcp-client.py` fix.

Note: `test-baked-patch-parity.ps1` defaults `-Image` to `deer-flow-pacgate:0.2.8`, which is stale. Its B1-B3 assertions are static and unaffected, but B4 (the advisory "is the bake stale" check) will report against the wrong image. Pass the current tag explicitly:

```powershell
pwsh -NoProfile -File scripts\test-baked-patch-parity.ps1 -Image ghcr.io/jzkk720/deer-flow-pacgate:0.2.32
```
Expected: B1-B3 pass; B4 reports whether the 0.2.32 bake still matches the tracked source. A B4 drift warning is advisory, not a failure - the bind mount wins at runtime.

- [ ] **Step 4: Confirm the Rust workspace still builds**

Run:
```powershell
cargo test --workspace --manifest-path pacgate-ai\Cargo.toml 2>&1 | Select-Object -Last 25
```
Expected: all test binaries pass, including the four new `pacgate-redact` test files upstream added (`correlation_and_location`, `identifier_classes`, `regional_coverage`, `token_idempotency`, `tokenisation_2026_11_03`).

---

## Task 6: Pull the images and recreate the stack

**Files:** none modified.

**Interfaces:**
- Consumes: green static suite from Task 5.
- Produces: a running stack whose every Pacgate container is `0.2.32`.

- [ ] **Step 1: Prove the images are public before pulling**

Run:
```powershell
foreach ($r in @('pacgate-api','deer-flow-pacgate','deer-flow-frontend-pacgate','pacgate-mcp','ocr-service')) {
  $t = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:jzkk720/$r`:pull&service=ghcr.io" -UseBasicParsing).token
  $h = Invoke-WebRequest -Method Head -Uri "https://ghcr.io/v2/jzkk720/$r/manifests/0.2.32" `
        -Headers @{ Authorization = "Bearer $t"; Accept = 'application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' } -UseBasicParsing
  "$r : $($h.StatusCode)"
}
```
Expected: five `200` lines. A `401` means the package is still private and the client install path is broken - stop and fix visibility before continuing.

- [ ] **Step 2: Pull**

Run:
```powershell
cd deploy\client-bundle
docker compose -f compose.prod.yaml -f compose.bundle.yaml pull
```
Expected: five `Pulled` lines for `0.2.32`. `pgvector`, `nginx`, and the pinned `openviking` digest report `Already exists`.

- [ ] **Step 3: Recreate**

Run:
```powershell
docker compose -f compose.prod.yaml -f compose.bundle.yaml up -d
```
Expected: `Recreated` for the five Pacgate services; `Running` for the rest. A container that stays `Running` while its pin changed is the partial-recreate defect `test-stack-version-coherence.ps1` exists to catch.

- [ ] **Step 4: Wait for health, then assert identity**

Run from the **repo root** (the gate resolves `deploy/client-bundle/compose.prod.yaml` relative to the working directory):

```powershell
cd C:\Users\pacga\github-pr\pacgate-law\pacgate-ai-pr
Start-Sleep -Seconds 45
pwsh -NoProfile -File scripts\test-stack-version-coherence.ps1
```
Expected: exit 0, every pinned service running the image its pin names.

---

## Task 7: Live verification of the lanes this upgrade touches

**Files:** none modified unless an assertion fails.

**Interfaces:**
- Consumes: the running `0.2.32` stack from Task 6.
- Produces: evidence that each lane the merge or the pin could have broken still works.

- [ ] **Step 1: Health and version**

Run:
```powershell
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | Sort-Object
Invoke-RestMethod http://localhost:8089/version -UseBasicParsing | ConvertTo-Json
```
Expected: all five `(healthy)`; the payload reports `"version": "0.2.32"` and `"revision": "17a498ea..."`. The nginx route `location = /version` proxies to `pacgate-api:/build-info`, which is the only endpoint that reports the baked revision.

- [ ] **Step 2: MCP tool surface and argument paths**

Run:
```powershell
pwsh -NoProfile -File scripts\test-mcp-tool-surface.ps1
pwsh -NoProfile -File scripts\test-mcp-argument-paths.ps1
```
Expected: both exit 0. The second is the gate for the `deer-flow-mcp-args.py` patch upstream added; the first is the gate our empty-source fix protects.

- [ ] **Step 3: The MCP long-call lane (our local-only fix)**

Run:
```powershell
pwsh -NoProfile -File scripts\test-agent-mcp-e2e.ps1
```
Expected: exit 0. This exercises a tool call long enough to exceed the SDK's 300 s default read timeout, which is what `deer-flow-mcp-client.py` raises to 900 s.

- [ ] **Step 4: Memory lane, including query parameters**

Run:
```powershell
pwsh -NoProfile -File scripts\test-memory-lane.ps1
pwsh -NoProfile -File scripts\test-memory-prompt-stability.ps1
```
Expected: both exit 0. Then confirm the query-parameter fix by hand. The route lives in the Next.js frontend, which is published on `:8090` (nginx `:8089` fronts the UI but only special-cases `location = /api/memory`):

```powershell
$r = Invoke-WebRequest "http://localhost:8090/api/memory/search?q=test&limit=1" -UseBasicParsing -SkipHttpErrorCheck
$r.StatusCode
```
Expected: not `400`. A `400` here means the proxy dropped the query string. Compare against the same call without the query string - if both return the same status, the parameters are being discarded.

- [ ] **Step 5: Sanitizer and CJK search (the two 0.2.32 behaviour changes)**

Run:
```powershell
pwsh -NoProfile -File scripts\test-sanitizer-e2e.ps1
pwsh -NoProfile -File scripts\test-kb-search-empty-signal.ps1
```
Expected: both exit 0. Then prove the CJK full-text migration actually applied. The query below is verified to run against the current database (it returns `0` today, which is the defect):

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -tAc "SELECT count(*) FROM kb_chunks WHERE to_tsvector('simple', regexp_replace(content,'([一-鿿])',' \1 ','g')) @@ plainto_tsquery('simple','结算条款');"
```
Expected after the upgrade: a non-zero count. `0` means migration `009_cjk_fulltext.sql` did not run and the keyword half of hybrid search is still inert. Confirm the migration's own artifacts exist (both are absent today, which is the pre-upgrade baseline):

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -tAc "SELECT count(*) FROM pg_proc WHERE proname='cjk_tsquery';"
docker exec pacgate-db psql -U pacgate -d pacgate -tAc "SELECT indexname FROM pg_indexes WHERE tablename='kb_chunks' AND indexname='idx_kb_chunks_content_tsv';"
```
Expected after the upgrade: `1` and `idx_kb_chunks_content_tsv`. There is no `_sqlx_migrations` table in this schema - migrations are applied idempotently from `include_str!` at startup, so the artifacts themselves are the only reliable evidence.

- [ ] **Step 6: Legal journey and document generation**

Run:
```powershell
pwsh -NoProfile -File scripts\test-legal-journey.ps1
pwsh -NoProfile -File scripts\test-document-generation-e2e.ps1
```
Expected: both exit 0. These are the two end-to-end lanes the 0.2.32 release notes touch most.

- [ ] **Step 7: Record the evidence**

Run:
```powershell
docker ps --format '{{.Names}}\t{{.Image}}' | Sort-Object | Tee-Object -FilePath checks-0.2.32-containers.txt
```
Then write `deploy/SYNC-2026-11-08-0.2.32.md` with: the pre-sync baseline from Task 1 Step 4, the post-sync list, the gate suite result, and one line per live assertion with its exit code. Commit it.

---

## Task 8: Model migration (only if the decision in Task 4 Step 4 is "switch")

**Files:**
- Modify: `deploy/client-bundle/.env`
- Modify: `deploy/client-bundle/openviking/ov.conf` (or the `OPENVIKING_CONF_CONTENT` line in `.env`)

**Interfaces:**
- Consumes: a healthy `0.2.32` stack from Task 7.
- Produces: `MID` and `LOW` on one resident tag, and the OpenViking VLM on the same tag, so a 16 GB card never evicts one model to load another.

- [ ] **Step 1: Pull the tag**

Run:
```powershell
ollama pull nemotron-3.5-bolt:e4b-q8_0
ollama list | Select-String 'nemotron-3.5-bolt'
```
Expected: a 9.8 GB entry. If the pull fails, stop - do not change `.env` to a tag that is not installed.

- [ ] **Step 2: Prove it is GPU-resident and schema-valid before switching**

Run:
```powershell
ollama run nemotron-3.5-bolt:e4b-q8_0 "reply with the single word ok"
ollama ps
```
Expected: `ollama ps` shows `100% GPU` and a context of `65536`. A `CPU` or split processor line means the card cannot hold it and the switch must be abandoned.

- [ ] **Step 3: Switch the tags**

Run:
```powershell
$envPath = 'deploy\client-bundle\.env'
(Get-Content $envPath) -replace '^PACGATE_MODEL_MID=.*', 'PACGATE_MODEL_MID=nemotron-3.5-bolt:e4b-q8_0' `
                        -replace '^PACGATE_MODEL_LOW=.*', 'PACGATE_MODEL_LOW=nemotron-3.5-bolt:e4b-q8_0' |
  Set-Content $envPath -Encoding utf8
Select-String -Path $envPath -Pattern '^PACGATE_MODEL_'
```
Expected: `MAIN` unchanged, `MID` and `LOW` both `nemotron-3.5-bolt:e4b-q8_0`.

- [ ] **Step 4: Switch the OpenViking VLM**

In `deploy/client-bundle/.env`, inside `OPENVIKING_CONF_CONTENT`, change `"model": "gemma4:12b-it-q8_0"` to `"model": "nemotron-3.5-bolt:e4b-q8_0"`. The tag is vision-capable (gemma4 architecture + CLIP encoder), which is why upstream retired the separate VLM.

- [ ] **Step 5: Recreate the two consumers and re-assert residency**

Run:
```powershell
cd deploy\client-bundle
docker compose -f compose.prod.yaml -f compose.bundle.yaml up -d pacgate-api openviking
Start-Sleep -Seconds 30
cd C:\Users\pacga\github-pr\pacgate-law\pacgate-ai-pr
pwsh -NoProfile -File scripts\test-ollama-gpu-residency.ps1
pwsh -NoProfile -File scripts\test-model-roster-consistency.ps1
```
Expected: both exit 0, and `ollama ps` shows exactly one resident model.

- [ ] **Step 6: Retire the old tags only after a green run**

Run:
```powershell
ollama rm gemma4:12b-it-qat
```
Expected: removed. Do this **last** - it is the only step that is not trivially reversible, and `gemma4:12b-it-qat` is the current fallback if the new tag misbehaves.

---

## Task 9: Push and record

**Files:** none modified.

**Interfaces:**
- Consumes: everything above.
- Produces: `fork/main` carrying the sync, so the next `install.ps1 -Update` on any machine can fast-forward.

- [ ] **Step 1: Confirm the divergence is now one-directional**

Run:
```powershell
git rev-list --left-right --count main...upstream/main
```
Expected: `44  0` - 41 after the merge, plus the Task 3 and Task 4 commits, plus the Task 7 evidence commit. Zero on the right is the property that matters: nothing upstream is missing, so `install.ps1 -Update` can fast-forward on any machine.

- [ ] **Step 2: Push to the fork**

Run:
```powershell
git push fork sync/upstream-0.2.32:main
```
Expected: a fast-forward on `fork/main`. Do **not** push to `origin` - that is the upstream namespace.

- [ ] **Step 3: Update the plan index**

Add a row to `plans/README.md`:

```markdown
| 033 | Sync to upstream 0.2.32 and pin the GHCR stack | P1 | **DONE** - 12 conflict hunks resolved, 4 local-only fixes re-applied, 5 images on 0.2.32, live lanes green (2026-11-08) |
```

Commit it.

---

## Self-review

**Spec coverage**

| Request | Task |
| --- | --- |
| Sync and merge local with upstream | 2 |
| Pin to the GHCR image stack | 4, 6 |
| Validate and verify upstream is ahead | 1 (baseline), 2 Step 12, 9 Step 1 |
| Evaluate whether upstream fixes are in our runtimes | 3 (the four gaps), 7 (live assertions) |
| Comprehensively upgrade the full stack | 6, 7, 8 |
| Plan everything first | this document |

**Placeholder scan:** no `TBD`, no "add appropriate handling", no "similar to Task N". Every code step carries the literal text to insert.

**Type consistency:** `$dirtyBranch`, `$shadowedChanges`, `Get-ShadowedPath`, `Invoke-NativeCapture`, `ConvertFrom-JsonArray` are all upstream names used consistently. `$bindMounted` and `$overridden` are removed in Task 2 Step 9 and never referenced again.

**Known gap, stated rather than hidden:** Task 4 Step 4 is a real decision, not a placeholder. It is called out in the handoff because the answer changes the order of Tasks 6 and 8.
