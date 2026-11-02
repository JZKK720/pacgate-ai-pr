# Closing the Verification Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the four "known gaps" from the 2026-11-02 audit impossible to ship silently, by converting each into a check that fails when the gap exists.

**Architecture:** Each gap becomes one gate assertion with a red-check proving it can fail. Two gaps were wrong when re-verified and are closed by documentation rather than code. No new frameworks, no abstraction: existing gate scripts, existing patterns.

**Tech Stack:** PowerShell 7 gate scripts under `scripts/`, Python stdlib for behavioural probes, Docker Compose for lane reads.

## Global Constraints

- Gate exit codes: **0 = pass, 1 = real defect, 2 = CANNOT CHECK**. Exit 2 is never a pass.
- Every new assertion must be **red-checked**: reintroduce the defect, observe the named assertion fail, restore.
- No assertion may match prose. Assert parsed JSON fields or parsed YAML, not vocabulary.
- Never `git reset --hard` with uncommitted work in the tree (this destroyed a fix on 2026-11-01).
- `deploy/pacgate-mcp/server.py` is bind-mounted read-only in both lanes, so editing it does **not** require a version bump. Do not bump.
- Chinese assertions use the exact bytes the product emits; a Unicode-escaped copy silently tests something else.

---

## Verified starting state

These were measured before writing the plan, not assumed:

| Claim | Verified result |
|---|---|
| No gate knows `LAYA_HF_CACHE` is required | `Select-String scripts/test-*.ps1 -Pattern LAYA_HF_CACHE` → **0 matches** |
| `LAYA_HF_CACHE` absent from the deployed `.env` | **absent** — service starts, `/health` passes, every clause call fails |
| Benchmarks never run in CI | **0** gate references `bench-laya-*` |
| qm digests untracked | **FALSE** — `compose.qm.yaml:19` pins `sha256:bee03e7f2271...` |
| "No PRC benchmark exists" | **TRUE and unfixable here** — needs real firm contracts |

---

### Task 1: Gate `LAYA_HF_CACHE` is set when the laya profile is active

**Why:** The single highest-risk gap. A fresh AIPC running `--profile laya` gets a healthy container that fails every clause call, because `/health` returns 200 with **no checkpoint loaded**. The failure surfaces to a lawyer as a broken feature, days later.

**Files:**
- Modify: `scripts/test-laya-tools.ps1` (append L10 after L9)
- Modify: `deploy/client-bundle/.env.example` — make `LAYA_HF_CACHE` uncommented with a comment that it is required for the profile

**Interfaces:**
- Consumes: `$src` (server.py text), `Check`/`Skip` helpers already defined in the script
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing assertion**

Append before the closing summary block in `scripts/test-laya-tools.ps1`:

```powershell
Write-Host ''
Write-Host 'L10 the laya profile cannot start without a model cache' -ForegroundColor Cyan

# Measured 2026-11-02: LAYA_HF_CACHE is absent from the deployed .env, and no
# gate referenced it. A fresh AIPC enabling `--profile laya` gets a container that
# passes /health (which loads no checkpoint) and fails every clause call. That is
# the exact failure /health cannot detect, so it must be caught before start.

# 1. Both lanes must default the mount somewhere explicit, never to a bare ../ path
#    that only exists on a dev box.
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { Check "$lane exists" $false; continue }
    $t = [System.IO.File]::ReadAllText((Resolve-Path $p))
    Check "$lane references LAYA_HF_CACHE for the model mount" ($t -match 'LAYA_HF_CACHE') `
        'without it the mount falls back to a dev-box path that will not exist on an AIPC'
}

# 2. .env.example must present it as required, not optional. This is prose in a
#    template, so assert the variable is present UNCOMMENTED - a commented
#    `#LAYA_HF_CACHE=` is exactly what produced the failure.
$envExample = 'deploy/client-bundle/.env.example'
if (-not (Test-Path -LiteralPath $envExample)) {
    Check '.env.example exists' $false
}
else {
    $lines = Get-Content -LiteralPath $envExample
    $active = @($lines | Where-Object { $_ -match '^\s*LAYA_HF_CACHE\s*=' })
    Check '.env.example sets LAYA_HF_CACHE uncommented' ($active.Count -ge 1) `
        'a commented default is what shipped, and the service then started with no weights'
}

# 3. If a laya container is running, its mount must actually resolve to a
#    checkpoint. Behavioural: a running service with an empty cache is the
#    condition being guarded.
$running = (& docker ps --filter 'name=^laya$' --format '{{.Names}}' 2>$null | Out-String).Trim()
if (-not $running) {
    Skip 'running laya has a populated cache' 'laya is not running (the profile is opt-in)'
}
else {
    $hub = (& docker exec laya sh -c 'ls /home/laya/.cache/huggingface/hub 2>/dev/null' 2>&1 | Out-String).Trim()
    $hasModel = $hub -match 'models--'
    Check 'running laya can see a staged checkpoint' $hasModel `
        "hub contents: '$hub' - the container is healthy in name only"
}
```

- [ ] **Step 2: Run it to verify it fails for the right reason**

Run: `pwsh -NoProfile -File scripts/test-laya-tools.ps1`
Expected: FAIL on `.env.example sets LAYA_HF_CACHE uncommented` (it is commented today). The two lane assertions should PASS (both lanes already reference it).

- [ ] **Step 3: Fix `.env.example` so the assertion can pass**

Change the commented block to an uncommented, explained default:

```dotenv
# REQUIRED when the laya profile is enabled. Point it at a staged HF cache
# (see scripts/stage-laya-models.ps1). If this is unset the laya container still
# starts and /health still returns 200, but every clause call fails - /health
# does not load a checkpoint. Set it before `--profile laya up`.
LAYA_HF_CACHE=../laya-hf-cache
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-laya-tools.ps1`
Expected: `RESULT: ... (N passed, 1 skipped)` with the skip naming the non-running laya profile.

- [ ] **Step 5: Red-check the behavioural half**

```powershell
# Start laya pointed at an EMPTY cache - the exact AIPC failure.
New-Item -ItemType Directory -Force -Path "$env:TEMP\empty-cache" | Out-Null
docker run -d --name laya-mt --network pacgate-ai-bundle_default `
  -e LAYA_PRELOAD=1 -e LAYA_MODELS=multilingual -e HF_HUB_OFFLINE=1 `
  -v "$env:TEMP\empty-cache:/home/laya/.cache/huggingface:ro" `
  ghcr.io/jzkk720/laya-serve:0.2.12
Start-Sleep -Seconds 20
pwsh -NoProfile -File scripts/test-laya-tools.ps1 | Select-String 'staged checkpoint'
docker rm -f laya-mt | Out-Null
```

Expected: `[FAIL] running laya can see a staged checkpoint` with `hub contents: ''`. Then removing the container returns the gate to a skip.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-laya-tools.ps1 deploy/client-bundle/.env.example
git commit -m "test(laya): gate the model cache the laya profile silently requires"
```

---

### Task 2: Give the benchmarks a runnable path against the compose service

**Why:** Benchmarks never run in CI, and cannot run from the host because the laya service publishes no port (correctly). So the only accuracy numbers are ones a developer produces by hand, which is how a benchmark decays into folklore.

**Files:**
- Create: `deploy/client-bundle/compose.bench.yaml`
- Modify: `deploy/client-bundle/.env.example` (document the override next to `LAYA_HF_CACHE`)

**Interfaces:**
- Consumes: the `laya` service from `compose.prod.yaml`, and the `-LayaUrl` parameter both benchmarks already accept (default `http://127.0.0.1:8000/v1/systemone`)
- Produces: nothing consumed by later tasks

**Design note — a dead wrapper was drafted first and rejected.** The obvious approach was a script that runs the benchmark *inside* the compose network. It cannot work: the `laya-serve` image is a Python runtime with no `pwsh` and none of the benchmark's tooling. Shipping a wrapper that can only exit 2 would be worse than no wrapper. The override below is simpler and actually runs.

- [ ] **Step 1: Write the failing check — prove the port is absent today**

Run:
```powershell
docker compose -f deploy/client-bundle/compose.prod.yaml config --services | Select-String laya
docker port laya 2>&1
```
Expected: `laya` is listed but `docker port` reports no published ports (or the container is absent). This is the condition to be fixed.

- [ ] **Step 2: Create the override**

Create `deploy/client-bundle/compose.bench.yaml`:

```yaml
# Benchmark override (2026-11-02). Adds a loopback-published port to laya so the
# accuracy benchmarks can run from the host, WITHOUT changing the shipped default.
#
# laya publishes no port in compose.prod.yaml on purpose: it holds model weights
# and only pacgate-mcp should reach it. This file is the explicit opt-in for a
# developer who needs to re-measure.
#
#   docker compose -f compose.prod.yaml -f compose.bench.yaml --profile laya up -d laya
#   pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1
#   docker compose -f compose.prod.yaml -f compose.bench.yaml --profile laya down
#
# Loopback only: 127.0.0.1, never 0.0.0.0. The weights and the model are not
# exposed to the network just because someone wants a number.
services:
  laya:
    ports:
      - "127.0.0.1:8000:8000"
```

- [ ] **Step 3: Verify the override composes and publishes the port**

Run:
```powershell
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.bench.yaml config --services
$env:LAYA_HF_CACHE = (Resolve-Path ../laya-hf-cache).Path
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.bench.yaml --profile laya up -d laya
Start-Sleep -Seconds 40
docker port laya
```
Expected: services list includes `laya` with no compose error, and `docker port laya` prints `8000/tcp -> 127.0.0.1:8000`.

- [ ] **Step 4: Verify both benchmarks run through the override**

Run:
```powershell
pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1
pwsh -NoProfile -File scripts/bench-laya-clause-flags.ps1 -Contracts 25
```
Expected: Chinese `recall high` ≥ 0.86 with exit 0; English prints the four AUC rows with exit 0. Both exit 2 if the port is not published, which proves the override is what enables them.

- [ ] **Step 5: Document the override in `.env.example`**

Add directly above `LAYA_HF_CACHE`:

```dotenv
# To re-measure clause accuracy, add the benchmark override (loopback port only):
#   docker compose -f compose.prod.yaml -f compose.bench.yaml --profile laya up -d laya
#   pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1
```

- [ ] **Step 6: Tear down and confirm the default is unchanged**

Run:
```powershell
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.bench.yaml --profile laya down
docker port laya 2>&1
```
Expected: container removed; `docker port` reports no such container. The shipped lane still publishes nothing.

- [ ] **Step 7: Commit**

```bash
git add deploy/client-bundle/compose.bench.yaml deploy/client-bundle/.env.example
git commit -m "feat(bench): opt-in loopback port so the accuracy benchmarks are runnable"
```

---

### Task 3: Correct the audit record where re-verification contradicted it

**Why:** The 2026-11-02 audit reported four gaps. On re-verification one was false (qm digests **are** tracked at `compose.qm.yaml:19`). Leaving a false gap in the record is worse than having the gap: someone will spend a day closing something already closed.

**Files:**
- Modify: `docs/superpowers/plans/2026-10-31-laya-local-decision-engine.md` (the benchmark section's "Still not established")

- [ ] **Step 1: Verify the qm digest claim is really true**

Run:
```powershell
Select-String -Path deploy/client-bundle/qm-pacgate/compose.qm.yaml -Pattern 'sha256:bee03e7f2271'
docker inspect qm-pacgate-core -f '{{.Config.Image}}'
```
Expected: the digest appears in the compose file and matches the running container.

- [ ] **Step 2: Add a dated correction to the plan**

Append to the "Still not established" list:

```markdown
- **CORRECTION 2026-11-02.** An earlier version of this list claimed the qm stack
  images were "never version-audited". That was wrong: `compose.qm.yaml:19` pins
  `ghcr.io/yc-software/qm/core@sha256:bee03e7f2271...` by digest, and the running
  container matches it. Digest pinning is the stronger form, so there was no gap.
  The audit reported it without checking; the check is one `Select-String`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-10-31-laya-local-decision-engine.md
git commit -m "docs(plan): retract a false audit gap - qm digests were already tracked"
```

---

### Task 4: Record the gap that cannot be closed, so nobody promises it

**Why:** "No PRC-executed-contract benchmark exists" is true, and no gate can fix it: it needs documents that only the firm has. What can be prevented is someone reading the CCL-DRR numbers as validation on real Chinese deals.

**Files:**
- Modify: `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` and `-ZH.md` (the laya paragraph)
- Test: `scripts/test-pdf-freshness.ps1` (existing, must stay green after re-render)

- [ ] **Step 1: Add the limitation to both handbooks, in both languages**

English, inside the existing laya paragraph:

```markdown
   **What the numbers do not cover.** The Chinese calibration is measured on
   CCL-DRR, whose clauses are drafted from statute text, not taken from executed
   contracts. The English figures come from CUAD, which is US commercial
   contracts. Neither is a benchmark of real PRC deal documents, so treat a
   Chinese `high` as a queue for review, never as a legal conclusion.
```

Chinese, in the mirrored position:

```markdown
   **这些数字未覆盖的范围。** 中文校准基于 CCL-DRR，其条款由法条文本生成，并非取自
   已签署合同；英文数字来自 CUAD，均为美国商事合同。两者都不是真实中国交易文件的
   基准，因此中文的 `high` 只意味着"应进入人工复核队列"，不构成法律结论。
```

- [ ] **Step 2: Verify language parity**

Run:
```powershell
(Select-String -Path deploy/AIPC-DEPLOYMENT-HANDBOOK.md -Pattern 'laya').Count
(Select-String -Path deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md -Pattern 'laya').Count
```
Expected: equal counts.

- [ ] **Step 3: Re-render and sync the PDFs**

Run:
```powershell
python safe_markdown_to_pdf.py deploy/AIPC-DEPLOYMENT-HANDBOOK.md deploy/AIPC-DEPLOYMENT-HANDBOOK.pdf
python safe_markdown_to_pdf.py deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf
Copy-Item deploy/AIPC-DEPLOYMENT-HANDBOOK*.pdf deploy/client-delivery/docs/ -Force
pwsh -NoProfile -File scripts/test-pdf-freshness.ps1
```
Expected: `PASSED: rendered PDFs are current and the client-delivery copies are in sync`.

- [ ] **Step 4: Commit**

```bash
git add deploy/AIPC-DEPLOYMENT-HANDBOOK*.md deploy/AIPC-DEPLOYMENT-HANDBOOK*.pdf deploy/client-delivery/docs/
git commit -m "docs(aipc): state what the clause benchmarks do not cover"
```

---

### Task 5: Full read-back

- [ ] **Step 1: Run every gate**

Run:
```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'
$fail=@(); Get-ChildItem scripts -Filter 'test-*.ps1' | ForEach-Object {
  $o = pwsh -NoProfile -File $_.FullName 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { $fail += "[$LASTEXITCODE] $($_.Name)" }
}
if ($fail.Count -eq 0) { 'ALL PASS' } else { $fail }
```
Expected: `ALL PASS` (82 today, 82 after Task 1 adds assertions to an existing gate).

- [ ] **Step 2: Prove the enable path once more, end to end**

Run:
```powershell
$env:LAYA_HF_CACHE = (Resolve-Path ..\laya-hf-cache).Path
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya up -d laya
docker compose -f deploy/client-bundle/compose.bench.yaml -f deploy/client-bundle/compose.prod.yaml --profile laya up -d laya
pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya down
```
Expected: recall on 风险高 ≥ 0.86, then clean teardown.

- [ ] **Step 3: Commit anything the read-back changed, or confirm clean**

Run: `git status --short`
Expected: empty.

---

## What this plan does NOT do

Honesty about scope, because a plan that implies it closed everything would be the same mistake the audit made:

- **It cannot create a PRC-contract benchmark.** That needs real documents. Task 4 makes the limitation visible so nobody over-reads the numbers.
- **It does not put benchmarks in CI.** They need a 9 GB model image and 2.8 GB of staged weights; running them per-commit is disproportionate. Task 2 makes them runnable on demand instead of by folklore.
- **It does not re-verify the other 82 gates.** They pass, and their own red-checks are the reason to believe them. Spot-checking them now would be reassurance, not verification.
