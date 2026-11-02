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
| `LAYA_HF_CACHE` absent from the deployed `.env` | **absent** — see the corrected failure analysis below |
| Benchmarks never run in CI | **0** gate references `bench-laya-*` |
| qm digests untracked | **FALSE** — `compose.qm.yaml:19` pins `sha256:bee03e7f2271...` |
| "No PRC benchmark exists" | **TRUE and unfixable here** — needs real firm contracts |

### CORRECTED 2026-11-02: how laya actually fails without weights

The first draft of this plan claimed an unset `LAYA_HF_CACHE` yields "a container
that passes `/health` and fails every clause call". That is **wrong**, and the
wrong version would have produced a vacuous assertion. Measured by running the
shipped image against two cache states:

| Cache state | Container | `/health` | Clause calls |
|---|---|---|---|
| **Empty** (no `models--`) | **exits at boot** — `LocalEntryNotFoundError: ... outgoing traffic has been disabled` | never serves | never — fails loudly |
| **Partial** (`multilingual` only, `english` missing) | **`running`, health `healthy`** | **`200`**, `loaded: ["multilingual"]` | Chinese **ok**; English **HTTP 500** |

So there are two distinct failure modes and the dangerous one is partial:

- An **empty** cache cannot ship silently. `LAYA_PRELOAD=1` makes the service
  refuse to start. Loud, safe.
- A **partial** cache ships silently: compose reports `healthy`, `/health` says
  `ok`, and only the language whose checkpoint is missing returns 500. That is
  exactly the en/zh deployment, where `LAYA_MODELS` defaults to
  `multilingual,english`.

**What this means for the assertions below.** "The hub directory is non-empty"
would **pass** the partial-cache state, so it is not a check - it is decoration.
The assertion must compare `/health`'s `loaded` list against the checkpoints
`LAYA_MODELS` actually names, and additionally prove an English round-trip,
because `loaded` is the service's own claim and a 500 is the observable fact.

---

### Task 1: Gate that laya can serve every checkpoint it is configured to load

**Why:** Measured 2026-11-02. A **partial** cache ships silently: compose reports
`healthy`, `/health` returns 200 with `loaded: ["multilingual"]`, Chinese clauses
work, and **English clauses return HTTP 500**. In an en/zh product that is a
missing feature nobody notices until a lawyer tries it. An **empty** cache is safe
by comparison - `LAYA_PRELOAD=1` makes the container exit at boot with
`LocalEntryNotFoundError`.

**Files:**
- Modify: `scripts/test-laya-tools.ps1` (append L10 before the summary block at L415)
- Modify: `deploy/client-bundle/.env.example` — uncomment `LAYA_HF_CACHE` with a required note

**Interfaces:**
- Consumes: `Check($name, $ok, $detail)` at L44 and `Skip($name, $why)` at L48, both already defined; `$src` at L59 (server.py text, in scope at the end of the script)
- Produces: nothing consumed by later tasks

**Design note — the first version of this assertion was vacuous.** It checked that
the hub directory was non-empty, which the partial-cache state **passes**. Three
assertions replace it, each targeting a state the experiment actually produced:
mount configured, `.env.example` uncommented, and `loaded` matching `LAYA_MODELS`
plus a live English round-trip.

- [ ] **Step 1: Write the three assertions**

Append immediately before the `Write-Host ''` / `$total = $script:pass + $script:fail` block at L415:

```powershell
Write-Host ''
Write-Host 'L10 the laya profile cannot ship a checkpoint-less or half-loaded service' -ForegroundColor Cyan

# Measured 2026-11-02. Two failure modes, only one silent:
#   empty cache    -> container exits at boot (LocalEntryNotFoundError). Loud, safe.
#   PARTIAL cache  -> healthy, /health 200, loaded:["multilingual"], English -> HTTP 500.
# The partial case is the one this gate exists for, and it is why "the directory
# is non-empty" is not an assertion: it would pass here.

# 1. Both lanes must name the cache variable, or the mount silently falls back to a
#    dev-box relative path that will not exist on an AIPC.
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { Check "$lane exists" $false; continue }
    $t = [System.IO.File]::ReadAllText((Resolve-Path $p))
    Check "$lane mounts laya's cache through LAYA_HF_CACHE" ($t -match 'LAYA_HF_CACHE') `
        'without it the mount falls back to a path that will not exist on an AIPC'
}

# 2. .env.example must set it UNCOMMENTED. A commented `#LAYA_HF_CACHE=` is what
#    shipped, and install.ps1 only tells the operator to copy the file - it does
#    not render a default - so a commented entry stays absent in the real .env.
$envExample = 'deploy/client-bundle/.env.example'
if (-not (Test-Path -LiteralPath $envExample)) {
    Check '.env.example exists' $false
}
else {
    $active = @(Get-Content -LiteralPath $envExample | Where-Object { $_ -match '^\s*LAYA_HF_CACHE\s*=' })
    Check '.env.example sets LAYA_HF_CACHE uncommented' ($active.Count -ge 1) `
        'a commented default ships, install.ps1 does not render one, so the client gets no value'
}

# 3. Behavioural, and the only assertion that catches the partial cache. Compare the
#    service's own `loaded` list against the checkpoints LAYA_MODELS asks for, then
#    prove an ENGLISH round-trip - `loaded` is the service's claim, a 500 is the fact.
$running = (& docker ps --filter 'name=^laya$' --format '{{.Names}}' 2>$null | Out-String).Trim()
if (-not $running) {
    Skip 'running laya serves every configured checkpoint' 'laya is not running (the profile is opt-in)'
}
else {
    $healthJson = (& docker exec laya python3 -c "import json,urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=6).read().decode())" 2>&1 | Out-String).Trim()
    $health = $null
    try { $health = $healthJson | ConvertFrom-Json } catch { }

    if (-not $health) {
        Check 'running laya answers /health with JSON' $false $healthJson
    }
    else {
        # Read the configured list from the LIVE container. If it cannot be read,
        # FAIL rather than assume a default: falling back to 'multilingual' here
        # would make a multilingual-only cache pass, which is precisely the state
        # this assertion exists to reject.
        $modelsRaw = (& docker exec laya sh -c 'printenv LAYA_MODELS' 2>&1 | Out-String).Trim()
        if (-not $modelsRaw -or $modelsRaw -match 'not found|No such|executable file') {
            Check 'LAYA_MODELS is readable from the running laya' $false `
                "printenv returned: '$modelsRaw' - without it, the checkpoints this service is meant to serve are unknown"
        }
        else {
            $want = @($modelsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $loaded = @($health.loaded)
            $missing = @($want | Where-Object { $loaded -notcontains $_ })
            Check 'every checkpoint in LAYA_MODELS is loaded' ($missing.Count -eq 0) `
                "LAYA_MODELS asks for [$($want -join ', ')] but the service loaded [$($loaded -join ', ')]; a missing checkpoint makes that language return HTTP 500 while compose still reports healthy"
        }

        # The observable fact, not the service's self-report.
        $enProbe = @'
import json, urllib.request, sys
body = json.dumps({"state": "The Supplier shall be liable for all losses without limitation.",
                    "questions": {"r": {"type": "noul", "instructions": "Is this risky?"}}}).encode()
req = urllib.request.Request("http://127.0.0.1:8000/v1/systemone", data=body,
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=90).read()
    print("OK")
except Exception as e:
    print("FAIL " + type(e).__name__ + " " + str(e)[:80])
'@
        $tmpEn = Join-Path $env:TEMP ("enprobe-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
        [System.IO.File]::WriteAllText($tmpEn, $enProbe, [System.Text.UTF8Encoding]::new($false))
        & docker cp $tmpEn "laya:/tmp/enprobe.py" 2>&1 | Out-Null
        $enOut = (& docker exec laya python /tmp/enprobe.py 2>&1 | Out-String).Trim()
        & docker exec laya rm -f /tmp/enprobe.py 2>&1 | Out-Null
        Remove-Item -LiteralPath $tmpEn -Force -ErrorAction SilentlyContinue
        Check 'a running laya can actually serve an English clause' ($enOut -match '^OK') `
            "English round-trip returned: $enOut - this is the partial-cache failure mode, where /health says ok and only English breaks"
    }
}
```

- [ ] **Step 2: Run it to verify both red states**

Run: `pwsh -NoProfile -File scripts/test-laya-tools.ps1`
Expected today: **FAIL** on `.env.example sets LAYA_HF_CACHE uncommented` (it is commented — measured: `active LAYA_HF_CACHE lines: 0`), and **SKIP** on the behavioural pair because laya is not running.

- [ ] **Step 3: Fix `.env.example`**

Replace the commented block with:

```dotenv
# REQUIRED when the laya profile is enabled. Point it at a staged HF cache
# (scripts/stage-laya-models.ps1). If unset, `--profile laya` still pulls and
# starts the image, and an EMPTY cache makes the container exit at boot - but a
# PARTIAL cache reports healthy while the missing checkpoint's language returns
# HTTP 500. Set it before enabling the profile.
LAYA_HF_CACHE=../laya-hf-cache
```

- [ ] **Step 4: Verify green, then red-check the partial cache**

Run: `pwsh -NoProfile -File scripts/test-laya-tools.ps1`
Expected: all pass, behavioural pair skipped.

Now prove assertion 3 catches the real defect:

```powershell
# Stage multilingual only - the partial cache that shipped silently.
$full = 'laya-hf-cache\hub\models--convaiinnovations--laya'
$part = "$env:TEMP\partial-cache\hub\models--convaiinnovations--laya"
$sha  = '7b928d828b7b0e022f929d9bd2e44165aa270148'
New-Item -ItemType Directory -Force -Path "$part\snapshots\$sha", "$part\refs" | Out-Null
Copy-Item "$full\refs\main" "$part\refs\main" -Force
Copy-Item -Recurse "$full\snapshots\$sha\multilingual" "$part\snapshots\$sha\multilingual" -Force
docker run -d --name laya-mt --network pacgate-ai-bundle_default `
  -e LAYA_PRELOAD=1 -e LAYA_MODELS=multilingual,english -e HF_HUB_OFFLINE=1 `
  -v "$env:TEMP\partial-cache:/home/laya/.cache/huggingface:ro" `
  ghcr.io/jzkk720/laya-serve:0.2.12
Start-Sleep -Seconds 50
pwsh -NoProfile -File scripts/test-laya-tools.ps1 | Select-String 'loaded|English clause'
docker rm -f laya-mt | Out-Null
Remove-Item -Recurse -Force "$env:TEMP\partial-cache" -ErrorAction SilentlyContinue
```

Expected: `[FAIL] every checkpoint in LAYA_MODELS is loaded` (asks for multilingual,english; loaded multilingual) **and** `[FAIL] a running laya can actually serve an English clause` with `FAIL HTTPError HTTP Error 500`.

Note: `LAYA_MODELS` must name **both** here even though the cache holds one, because that is what compose defaults to. With `LAYA_MODELS=multilingual` the same partial cache is *correct* and the assertions rightly pass — that distinction is the whole point.

- [ ] **Step 5: Commit**

```bash
git add scripts/test-laya-tools.ps1 deploy/client-bundle/.env.example
git commit -m "test(laya): catch the partial cache that reports healthy and 500s one language"
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
