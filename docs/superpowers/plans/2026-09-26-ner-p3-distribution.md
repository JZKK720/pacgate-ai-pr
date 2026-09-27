# P3: NER Distribution and Enablement - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the NER weights in the `pacgate-api` image and set `PACGATE_NER_MODEL_DIR` in both compose files, so a client install runs the full detector set instead of silently degrading to rules-only — taking coverage from 7 of 15 `EntityType` classes to 10.

**Architecture:** The weights are baked into the image at build time by a dedicated `ner-model` stage, verified by SHA-256 and file size, and copied into the runtime stage. Two compose files set the env var that switches `build_detectors` from `tier_one_detectors()` to `full_detectors()`. A new gate asserts the var is set in **both** compose files, so a future edit cannot silently drop a client back to rules-only.

**Tech Stack:** Docker multi-stage build, Docker Compose, PowerShell gate scripts. **No new runtime dependencies.** No new Rust code.

**Spec:** `docs/superpowers/specs/2026-09-26-ner-enablement-design.md` - this implements **workstream 2** (§9 step 4) and **§9 step 5** (enable and verify). Read §6 (fail-closed semantics) and §8 (honest limitations) before starting.

**Depends on:** P1 (`5bc7358`..`a74dec3`) and P2 (`72d9f37`, `843e71b`), both done and verified.

## Global Constraints

- **Do NOT download at runtime.** The decision is recorded below in "Why build-time, not runtime"; deviating from it silently is the failure this plan exists to prevent.
- **Do NOT vendor the weights into git.** They are 388 MB; `.gitignore` must keep them out, and the build fetches by pinned revision.
- **Pin the revision AND verify the content.** `NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a`. A revision pin alone does not detect a swapped artifact, so the build asserts SHA-256 and byte length (measured values in F2).
- **The build must FAIL on a hash mismatch, not warn.** A wrong-weights image that starts cleanly is worse than a failed build.
- **Both compose files must set the variable.** `compose.prod.yaml` (client install) and `compose.bundle.yaml`. Setting one is the exact "looks enabled but isn't" state this plan removes.
- **Fail-closed is already correct and must stay that way.** `sanitize.rs:68-77`: unset → warn + Tier-1; set-but-broken → hard error. **Do not change this code.** This plan only feeds it a correct path.
- **`docker` is required for Tasks 1-2.** Verify with `docker version`. If absent, report `DONE_WITH_CONCERNS` rather than claiming the image is right.
- **Run compose from `deploy/client-bundle/`.** `compose.prod.yaml` lives there; from the repo root compose reports the file as invalid.
- **Line-based PowerShell execution mangles nested `$`.** Write multi-line scripts to a file, or send each command as its own sync command.
- **After any script that mutates files, run `git status --short`** and `git checkout --` whatever it left.

---

## Measured findings this plan is built on

### F1 — the variable is nowhere in any compose file

```
grep -c PACGATE_NER_MODEL_DIR deploy/client-bundle/compose.prod.yaml   -> 0
grep -c PACGATE_NER_MODEL_DIR deploy/client-bundle/compose.bundle.yaml -> 0
```

`main.rs:50` reads it into `AppConfig::ner_model_dir`; `sanitize.rs:146` passes it to `build_detectors`; `sanitize.rs:73` warns and falls back to `tier_one_detectors()`. So every client install today runs **rules-only** and logs a warning nobody reads. That is the 7-of-15 state.

### F2 — the pinned weights, hashed

Measured 2026-09-27 from the files P2's verification downloaded:

| file | bytes | sha256 |
|---|---|---|
| `config.json` | 1,133 | `c5b24a4a4b825b01ebe7b101b80826091a5a03b688383d9261a60964747778df` |
| `model.safetensors` | 406,763,404 | `1d2f0ea479431c1907bbaa75f872c26267ce3c19ea78e4266980b0d49b5a825a` |
| `vocab.txt` | 109,540 | `45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c` |

Total 406,874,077 bytes. The spec's 388 MB figure is 406,874,077 / 1048576 = **388.0 MiB**, so the two agree.

### F3 — the current images are SMALL, which changes the trade-off

```
layer sum, ghcr.io/jzkk720/pacgate-api:0.1.18   128.6 MiB
layer sum, pacgate-api:ner-test (with weights)  535.7 MiB
NER weights alone                                387.9 MiB
delta, measured                                   407 MiB
```

**Measure by summing layers, not by trusting a single number.** Docker's own size
reports disagree with each other on this image: `inspect --format '{{.Size}}'`
reported 956,503,149 bytes (912 MiB), `docker save` produced a 421 MB tarball, and
the layer sum is 535.7 MiB. The 956 MB figure is not reproducible from the layers
(a 912 MB sum would need 4.6 copies of the 388 MB weight file) and is treated as
a reporting artifact. The useful, defensible number is the **delta between two
builds measured the same way**: 407 MiB, which matches the weights plus overhead.

An earlier draft of this plan said "172 MB today, ~552 MB after". Both figures
were wrong, because they came from mixing methods (an `inspect` absolute for one,
an estimate for the other). Recorded because a size claim in a client deliverable
has to be reproducible.

### F4 — `ocr-service` downloads its model at RUNTIME, and that is a deliberate precedent

`deploy/client-bundle/compose.prod.yaml`:

```yaml
  # A first-class release image from 0.1.16. The ~1.5GB PaddleOCR model is
  # downloaded on FIRST EXTRACTION (not at build or start), so image pulls
  # stay small and the cost lands on the first OCR-using session.
```

So the repo has an established pattern for large models, and it is **not** build-time baking. "We do it this way for OCR" would justify runtime for NER too. It was considered and rejected — see below. Recording it here so the decision is not silently reversed later.

### F5 — the model is loaded PER SANITIZE JOB, not once at startup

`sanitize.rs:146` calls `build_detectors` inside `run_job`, which is per-request, not in `main`. Measured load cost: **206 ms**, then **198 ms** on a second call — so the cost is paid on every sanitize job, not amortised.

This matters for P3 because P3 is the change that makes the load happen in production at all. At ~200 ms per job it is acceptable for a document-sanitize endpoint (the job already does OCR and DB work). It is a finding to report, not a blocker — and it is *not* made better or worse by where the weights live.

## Why build-time, not runtime

Two options, both precedented in this repo. The decision, with the reason:

| | Bake at build (chosen) | Download at runtime (rejected) |
|---|---|---|
| Client download | +388 MiB once, at install | 388 MiB on first NER-using job |
| Offline install | works | **fails** |
| Air-gap / no-egress site | works | **fails** |
| Determinism | hash-pinned, verified at build | verified per run, or not at all |
| Precedent | none in this repo | `ocr-service` (F4) |

**The deciding factor is the egress requirement, not the size.** This is a legal-document sanitizer sold on data residency. A 388 MiB fetch to `huggingface.co` during production sanitization is an egress path to a third party that appears *inside the safety-critical operation*, and it would have to be disclosed and justified to the client. `ocr-service` does not carry the same objection because OCR is not the component whose job is to stop data leaving.

Secondarily: a runtime download means the first sanitize after install either fails or blocks, and it means a firewall change breaks sanitization in a way that is hard to diagnose. A bigger install image is a one-time, visible, verifiable cost.

**The cost is real and must be stated to the client** (spec §8 requires it): the API image grows by about **407 MiB** (measured layer-sum delta), from 128.6 MiB to 535.7 MiB.

**Accepted limitation:** if a future client needs a smaller image, the correct fix is a separate model-serving sidecar the API calls, not a runtime download inside the sanitize path. Out of scope here.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/Dockerfile` | Add a `ner-model` stage that fetches and verifies the weights; copy them into the runtime stage | Modify |
| `.github/workflows/build-ghcr.yml` | Pass `NER_MODEL_REV` as a build arg so the pin is visible in one place | Modify |
| `deploy/client-bundle/compose.prod.yaml` | Set `PACGATE_NER_MODEL_DIR` on `pacgate-api` | Modify |
| `deploy/client-bundle/compose.bundle.yaml` | Same — this is the second compose that defines the service | Modify |
| `pacgate-ai/.dockerignore` | Keep the weights out of the build context if present locally | Modify or create |
| `scripts/test-ner-enabled.ps1` | Gate: the var is set in every compose that defines `pacgate-api`; the image contains all three files | Create |
| `scripts/run-all-checks.ps1` | Gate list | Modify (one entry) |
| `pacgate-ai/Cargo.toml` + pin surfaces | Version bump 0.1.18 -> 0.1.19 | Modify (Task 6) |

---

### Task 1: Bake and verify the weights in the API image

**Files:**
- Modify: `pacgate-ai/Dockerfile`
- Modify: `pacgate-ai/.dockerignore` (create if absent)

**Interfaces:**
- Consumes: the pinned revision and hashes in F2.
- Produces: an image where `/app/models/ner/{config.json,model.safetensors,vocab.txt}` exist. That path is what Task 2's env var points at, and what Task 4's gate asserts.

- [ ] **Step 1: Add the `ner-model` stage**

Insert this stage **between** the builder stage and the runtime stage in `pacgate-ai/Dockerfile`, i.e. after the `RUN cargo build --release ...` block and before `FROM debian:bookworm-slim`:

```dockerfile
# ── Stage 1.5: NER model weights ─────────────────────────────────────────────
# Fetched at BUILD time, not at runtime. The deciding reason is egress, not
# size: this is a data-residency product, and a runtime fetch to huggingface.co
# would sit INSIDE the sanitize path - the one operation whose whole job is to
# stop data leaving. ocr-service downloads its model on first extraction
# (compose.prod.yaml), and that precedent is deliberately NOT followed here.
#
# Everything is verified, not assumed: the revision pins WHAT is fetched, and
# the SHA-256 + byte length below pin WHAT ARRIVED. A revision pin alone cannot
# detect a swapped or truncated artifact.
#
# Cost, stated for the client: pacgate-api grows from ~164 MiB to ~552 MiB.
FROM debian:bookworm-slim AS ner-model

# The pinned upstream revision of shibing624/bert4ner-base-chinese (Apache-2.0).
ARG NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a
ARG NER_BASE_URL=https://huggingface.co/shibing624/bert4ner-base-chinese/resolve

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /ner

RUN set -eux; \
    for f in config.json model.safetensors vocab.txt; do \
        curl -fsSL --retry 3 --retry-delay 2 -o "$f" "${NER_BASE_URL}/${NER_MODEL_REV}/${f}"; \
    done

# Verify BEFORE the runtime stage can use them. `set -eux` plus an explicit
# `exit 1` on each check: a wrong-weights image that starts cleanly is worse
# than a failed build, because it looks like success.
RUN set -eux; \
    echo "c5b24a4a4b825b01ebe7b101b80826091a5a03b688383d9261a60964747778df  config.json" > /ner/SHA256SUMS; \
    echo "1d2f0ea479431c1907bbaa75f872c26267ce3c19ea78e4266980b0d49b5a825a  model.safetensors" >> /ner/SHA256SUMS; \
    echo "45bbac6b341c319adc98a532532882e91a9cefc0329aa57bac9ae761c27b291c  vocab.txt" >> /ner/SHA256SUMS; \
    sha256sum -c /ner/SHA256SUMS; \
    test "$(stat -c %s model.safetensors)" = "406763404" || { echo "model.safetensors is the WRONG SIZE"; exit 1; }; \
    test "$(stat -c %s config.json)" = "1133"          || { echo "config.json is the WRONG SIZE"; exit 1; }; \
    test "$(stat -c %s vocab.txt)" = "109540"          || { echo "vocab.txt is the WRONG SIZE"; exit 1; }; \
    echo "NER weights verified: revision ${NER_MODEL_REV}"
```

- [ ] **Step 2: Copy the weights into the runtime stage**

In the runtime stage (after `FROM debian:bookworm-slim`), add after the existing `COPY migrations /app/migrations` line:

```dockerfile
# NER weights, verified in the ner-model stage. The API reads this path from
# PACGATE_NER_MODEL_DIR, which the compose files set (see P3 Task 3).
# `NerDetector::load` requires exactly these three files and fails closed if any
# is missing, so a malformed copy fails at first sanitize, not silently.
COPY --from=ner-model /ner /app/models/ner
```

- [ ] **Step 3: Keep the weights out of the build context**

`pacgate-ai/.dockerignore` must not let a locally-downloaded copy bloat the context. Check whether the file exists, then ensure these lines are present (create the file with just these lines if it does not exist):

```
# NER weights are fetched inside the ner-model stage. A local copy (e.g.
# $env:TEMP\ner-model-zh copied in for testing) must never enter the build
# context - it is 388MB and it would shadow the verified fetch.
models/
**/ner-model-zh/
*.safetensors
```

- [ ] **Step 4: Build the image and verify the files are present**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& docker build -f pacgate-ai/Dockerfile -t pacgate-api:ner-test pacgate-ai
"build exit=$LASTEXITCODE"
```

Expected: the build succeeds and the log contains `NER weights verified: revision 5d660ed2...`. Then confirm the files really landed:

```powershell
& docker run --rm --entrypoint sh pacgate-api:ner-test -c "ls -l /app/models/ner && sha256sum -c /app/models/ner/SHA256SUMS"
"verify exit=$LASTEXITCODE"
```

Expected: three files listed, and `sha256sum -c` reports three `OK` lines, exit 0.

**If the build fails at the `sha256sum -c` step, do NOT relax the check.** Stop and report: it means the fetched artifact differs from the one P2 verified, which is a real finding about the upstream revision, not a build problem.

- [ ] **Step 5: Measure the resulting image size**

```powershell
& docker image inspect pacgate-api:ner-test --format '{{.Size}}'
```

Expected: roughly 535-560 MiB by layer sum (F3's 128.6 MiB plus 387.9 MiB of weights plus overhead). Record the actual number — it is a figure the client deliverables must state. **Sum the layers with the same method used on the old image**; single-number reports disagree (see F3).

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/Dockerfile pacgate-ai/.dockerignore
git commit -m "build(api): bake and verify the NER weights into the image

Fetched at build time rather than runtime. The deciding reason is egress, not
size: this is a data-residency product, and a runtime fetch to huggingface.co
would sit INSIDE the sanitize path - the one operation whose whole job is to stop
data leaving. ocr-service downloads its model on first extraction, and that
precedent is deliberately not followed here; the reasoning is in the Dockerfile
so it is not silently reversed.

Verification is content-based, not revision-based: a revision pin says what was
requested, not what arrived. SHA-256 plus byte length for all three files, and a
mismatch fails the build - a wrong-weights image that starts cleanly is worse
than a failed build, because it looks like success.

Cost: pacgate-api grows from ~164 MiB to ~552 MiB."
```

---

### Task 2: Make the pin a build arg CI passes

**Files:**
- Modify: `.github/workflows/build-ghcr.yml`

**Interfaces:**
- Consumes: the `NER_MODEL_REV` build arg added in Task 1.
- Produces: the pin visible in CI, so a reader does not have to open the Dockerfile to find which revision shipped.

- [ ] **Step 1: Pass the revision from the workflow**

In `.github/workflows/build-ghcr.yml`, in the `Build & push pacgate-api` step (around line 219, where `build-args` already has `PAC_SOURCE_REVISION`), add the NER revision:

```yaml
          build-args: |
            PAC_SOURCE_REVISION=${{ github.sha }}
            # The NER weights pin. Kept here as well as the Dockerfile default so
            # the shipped revision is visible in the build log and in one place a
            # reviewer checks; the Dockerfile's own default keeps local builds
            # working without this workflow.
            NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a
```

- [ ] **Step 2: Verify the workflow YAML still parses**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-workflow-validity-mutations.ps1
"exit=$LASTEXITCODE"
& pwsh -NoProfile -File scripts/test-workflow-namespace.ps1
"exit=$LASTEXITCODE"
```

Expected: both exit 0. These are existing gates, so a failure means the edit broke the workflow structure.

- [ ] **Step 3: Confirm the build arg reaches the stage**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& docker build -f pacgate-ai/Dockerfile --build-arg NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a -t pacgate-api:argtest pacgate-ai 2>&1 | Select-String -Pattern 'NER weights verified|ERROR|failed'
"exit=$LASTEXITCODE"
```

Expected: `NER weights verified: revision 5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a`.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add .github/workflows/build-ghcr.yml
git commit -m "ci(images): pass the NER model revision as a build arg

Keeps the shipped revision visible in the build log and in one place a reviewer
checks, while the Dockerfile default keeps local builds working without the
workflow."
```

---

### Task 3: Set `PACGATE_NER_MODEL_DIR` in both compose files

**Files:**
- Modify: `deploy/client-bundle/compose.prod.yaml`
- Modify: `deploy/client-bundle/compose.bundle.yaml`

**Interfaces:**
- Consumes: `/app/models/ner` in the image (Task 1).
- Produces: the var that `main.rs:50` reads into `AppConfig::ner_model_dir`, which `sanitize.rs:146` passes to `build_detectors`.

**This is the task that actually turns NER on.** Without it the image contains the weights and nothing reads them.

- [ ] **Step 1: Add the variable to `compose.prod.yaml`**

In `deploy/client-bundle/compose.prod.yaml`, under the `pacgate-api:` service's `environment:` block. Place it next to the other sanitizer-related vars, after the `PACGATE_DEFAULT_TENANT` line (line 31):

```yaml
      # The NER weights are baked into this image at /app/models/ner and verified
      # by SHA-256 at build time. Setting this path switches build_detectors()
      # from tier_one_detectors() (5 classes) to full_detectors() (8), which is
      # the difference between a rules-only sanitizer and one that also finds
      # person and organisation names.
      #
      # DO NOT REMOVE OR BLANK THIS. Unset is not fatal: sanitize.rs:73 warns and
      # falls back to Tier-1 rules, so the install looks healthy while silently
      # detecting 5 of 15 classes. scripts/test-ner-enabled.ps1 is the gate that
      # stops that from happening unnoticed.
      #
      # Set-but-MISSING is fatal by design: a deployment that intends NER must
      # not silently degrade. That is why this must match the image path exactly.
      PACGATE_NER_MODEL_DIR: /app/models/ner
```

- [ ] **Step 2: Add the same variable to `compose.bundle.yaml`**

In `deploy/client-bundle/compose.bundle.yaml`, under its `pacgate-api:` service (line 31), add the identical variable with the identical comment. Both files define the service, so omitting one leaves a compose path that runs rules-only.

```yaml
      PACGATE_NER_MODEL_DIR: /app/models/ner
```

- [ ] **Step 3: Verify both files parse and the var is present in each**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
& docker compose -f compose.prod.yaml config --quiet
"prod config exit=$LASTEXITCODE"
& docker compose -f compose.bundle.yaml config --quiet
"bundle config exit=$LASTEXITCODE"
```

Expected: both exit 0. Then confirm the value survives interpolation:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
Select-String -Path 'deploy/client-bundle/compose.prod.yaml','deploy/client-bundle/compose.bundle.yaml' -Pattern 'PACGATE_NER_MODEL_DIR' | ForEach-Object { "$($_.Filename):$($_.LineNumber)  $($_.Line.Trim())" }
```

Expected: two hits, both reading `PACGATE_NER_MODEL_DIR: /app/models/ner`.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add deploy/client-bundle/compose.prod.yaml deploy/client-bundle/compose.bundle.yaml
git commit -m "feat(compose): enable NER by setting PACGATE_NER_MODEL_DIR

This is the change that actually turns NER on. The variable appeared in NO
compose file, so every client install ran tier_one_detectors() - 5 of 15 classes -
while logging a warning nobody reads. The weights being in the image is
necessary but not sufficient: nothing read them.

Both compose files define pacgate-api, so both need it; setting one would leave a
deploy path silently rules-only. Set-but-missing stays fatal by design, so this
must match the image path exactly."
```

---

### Task 4: The gate that stops this regressing

**Files:**
- Create: `scripts/test-ner-enabled.ps1`
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: the compose files (Task 3) and the image path (Task 1).
- Produces: a gate with exit `0` pass, `1` real failure, `2` cannot check.

**Why a gate and not a comment:** an unset var is not an error at runtime — it warns and degrades (`sanitize.rs:73`). So the failure mode is an install that looks healthy and detects 5 of 15 classes. Nothing in the system reports that as wrong, which is precisely why a check has to.

- [ ] **Step 1: Write the gate**

Create `scripts/test-ner-enabled.ps1`:

```powershell
# Asserts NER is actually ENABLED in every shipped compose file, and that the
# image it points at really has the weights.
#
# WHY THIS GATE EXISTS: an unset PACGATE_NER_MODEL_DIR is not an error at
# runtime. sanitize.rs:73 logs a warning and falls back to tier_one_detectors(),
# so a misconfigured install looks perfectly healthy while detecting 5 of 15
# EntityType classes instead of 8 - including no person or organisation names at
# all. Nothing in the running system reports that as wrong. A check has to.
#
# SCOPE DISCIPLINE: this asserts the CONFIGURATION, not the behaviour. A pass
# means "the shipped compose files request NER and the image can satisfy it", not
# "NER produced correct output" - that is tests/recall.rs's job, and it needs the
# weights present to run its model rows at all.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== NER enablement ===' -ForegroundColor Cyan

# Every compose file that defines the pacgate-api service must set the variable.
# Discovered, not hardcoded: a third compose file added later would otherwise be
# invisible to this gate, which is the same blindness that let the variable be
# absent from all of them.
$composeFiles = Get-ChildItem 'deploy/client-bundle' -Filter 'compose*.yaml'
$checked = 0

foreach ($f in $composeFiles) {
    $text = Get-Content $f.FullName -Raw
    # Only files that actually define the service are in scope.
    if ($text -notmatch '(?m)^\s{2}pacgate-api:\s*$') { continue }
    $checked++

    if ($text -match '(?m)^\s+PACGATE_NER_MODEL_DIR:\s*(\S+)\s*$') {
        $value = $Matches[1]
        if ($value -eq '/app/models/ner') {
            Pass "$($f.Name) sets PACGATE_NER_MODEL_DIR=$value"
        } else {
            Fail "$($f.Name) sets PACGATE_NER_MODEL_DIR=$value, expected /app/models/ner (must match the Dockerfile COPY target)"
        }
    } else {
        Fail "$($f.Name) defines pacgate-api but does NOT set PACGATE_NER_MODEL_DIR - that install silently runs Tier-1 rules only (5 of 15 classes)"
    }
}

if ($checked -eq 0) {
    Fail 'found no compose file defining the pacgate-api service - the discovery pattern is wrong, so this gate would pass vacuously'
}

# The Dockerfile must actually place the weights at the path the compose files
# name. A gate that only checked compose would pass while every job failed with
# 'NER model load failed', because set-but-missing is fatal.
$dockerfile = 'pacgate-ai/Dockerfile'
if (Test-Path $dockerfile) {
    $df = Get-Content $dockerfile -Raw
    if ($df -match 'COPY --from=ner-model\s+/ner\s+/app/models/ner') {
        Pass "$dockerfile copies the weights to /app/models/ner"
    } else {
        Fail "$dockerfile does not COPY --from=ner-model to /app/models/ner - compose points at a path the image does not have, so every job would fail closed"
    }
    # A revision pin without content verification cannot detect a swapped artifact.
    if ($df -match 'sha256sum -c') {
        Pass "$dockerfile verifies the fetched weights by hash"
    } else {
        Fail "$dockerfile does not verify the weights (no 'sha256sum -c') - a revision pin alone cannot detect a swapped artifact"
    }
} else {
    Fail "$dockerfile not found"
}

# Optional but valuable: if the image is present locally, assert the files are
# really inside it. Skips (does not fail) when docker or the image is absent, so
# this gate is safe on a machine with no images built.
$image = 'pacgate-api:ner-test'
$dockerOk = $false
try { & docker version --format '{{.Server.Version}}' *> $null; $dockerOk = ($LASTEXITCODE -eq 0) } catch { $dockerOk = $false }

if ($dockerOk) {
    $exists = (docker image inspect $image --format '{{.Id}}' 2>$null)
    if ($exists) {
        $out = docker run --rm --entrypoint sh $image -c "ls /app/models/ner 2>/dev/null | wc -l" 2>&1
        if ("$out".Trim() -eq '3') {
            Pass "$image contains all 3 model files at /app/models/ner"
        } else {
            Fail "$image has $("$out".Trim()) file(s) at /app/models/ner, expected 3"
        }
    } else {
        Write-Host "  note  $image not built locally; image-contents check skipped (build it with the Task 1 command to include this)" -ForegroundColor Yellow
    }
} else {
    Write-Host '  exit 2 - docker unavailable; cannot check image contents' -ForegroundColor Yellow
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) NER enablement check(s)" -ForegroundColor Red
    exit 1
}
Write-Host "PASSED: NER is enabled in all $checked compose file(s) that define pacgate-api" -ForegroundColor Green
exit 0
```

- [ ] **Step 2: Run it and confirm it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-ner-enabled.ps1
"exit=$LASTEXITCODE"
```

Expected: exit 0, with a PASS line per compose file plus the Dockerfile checks.

- [ ] **Step 3: Negative-test it — prove it can go RED**

A gate never seen red is not evidence. Remove the variable from one compose file, run, restore:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'deploy/client-bundle/compose.prod.yaml'
Copy-Item $f "$f.nerbak"
(Get-Content $f -Raw) -replace '(?m)^\s+PACGATE_NER_MODEL_DIR: /app/models/ner\s*$', '' | Set-Content $f -Encoding UTF8
& pwsh -NoProfile -File scripts/test-ner-enabled.ps1 *> $null
"mutated exit=$LASTEXITCODE  (expect 1)"
Move-Item "$f.nerbak" $f -Force
(Get-Item $f).LastWriteTime = Get-Date
git status --short
```

Expected: `mutated exit=1`, and `git status --short` clean afterwards.

**If the mutated run exits 0, the gate is not actually checking — fix it before continuing.** Confirm the edit landed with `Select-String -Path $f -Pattern 'PACGATE_NER_MODEL_DIR'` before trusting the run. Note the `LastWriteTime` touch: `Move-Item` restores the backup's old mtime.

- [ ] **Step 4: Add the gate to the runner**

In `scripts/run-all-checks.ps1`, add one entry to the `$gates` array, after the `'scripts/test-rust-workspace.ps1'` entry:

```powershell
    # Asserts NER is enabled in every compose file that defines pacgate-api. An
    # unset PACGATE_NER_MODEL_DIR is not a runtime error - it warns and degrades
    # to 5 of 15 classes while looking healthy - so only a gate catches it.
    # Self-contained (reads files; the docker check self-skips), so it belongs
    # here rather than in $liveStackGates.
    'scripts/test-ner-enabled.ps1'
```

- [ ] **Step 5: Run the runner**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/run-all-checks.ps1 *> 'nerrun.txt'
"exit=$LASTEXITCODE"
Select-String -Path 'nerrun.txt' -Pattern 'test-ner-enabled|ALL |FAIL' | ForEach-Object { $_.Line }
Remove-Item 'nerrun.txt' -Force
```

Expected: `test-ner-enabled.ps1` shows PASS, the final tally rises by one gate, exit 0.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add scripts/test-ner-enabled.ps1 scripts/run-all-checks.ps1
git commit -m "ci(gates): assert NER is enabled, not merely available

An unset PACGATE_NER_MODEL_DIR is not an error at runtime - sanitize.rs:73 warns
and falls back to tier_one_detectors(), so a misconfigured install looks healthy
while detecting 5 of 15 classes and no person or organisation names at all.
Nothing in the running system reports that as wrong, so a gate has to.

Discovers compose files rather than hardcoding them, because a hardcoded list is
the same blindness that let the variable be absent from all of them. Also checks
the Dockerfile COPY target matches the path compose names, since set-but-missing
is fatal and would fail every job.

Negative-tested: removing the variable from compose.prod.yaml makes it exit 1."
```

---

### Task 5: Verify end-to-end on the running stack

**Files:**
- Test: the live stack, no file changes

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: evidence that a real document sanitizes with NER active.

**This is the task that distinguishes "configured" from "working".** Task 4 asserts configuration; this asserts behaviour against a running container.

- [ ] **Step 1: Retag and restart the API on the new image**

The dev box has an image-shadowing trap: a local tag can shadow the pulled one. Retag and force-recreate:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker tag pacgate-api:ner-test ghcr.io/jzkk720/pacgate-api:0.1.18
Set-Location deploy\client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps pacgate-api
"exit=$LASTEXITCODE"
```

- [ ] **Step 2: Confirm the API started with NER, not rules-only**

The decisive check is the **absence** of the degradation warning. `sanitize.rs:73` logs `PACGATE_NER_MODEL_DIR unset: running Tier-1 rules only` on every job when the var is missing:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
docker exec pacgate-api printenv PACGATE_NER_MODEL_DIR
"--- verify the files are readable INSIDE the running container ---"
docker exec pacgate-api sh -c "ls -l /app/models/ner"
```

Expected: `/app/models/ner`, and three files listed. If `printenv` is empty, the compose change did not reach the container — check that you recreated rather than restarted (`restart` does not re-read compose).

- [ ] **Step 3: Prove the detector set by exercising a real sanitize**

A long document containing a person name, past the first window (which also re-proves P2 in the container):

```powershell
$dir = Join-Path $env:TEMP 'ner-model-zh'
# Build a test document: filler, then a person name well past the first window.
$filler = "本所同意上述条款并遵照执行。" * 120
$text = "$filler" + "张伟是本案的委托代理人。"
Set-Content -Path "$env:TEMP\ner-e2e.txt" -Value $text -Encoding UTF8
"chars: $($text.Length)"
```

Then check the API log for the warning during a sanitize job. The exact endpoint and auth flow are in `scripts/test-text-native-sanitize.ps1` — reuse its pattern rather than inventing one:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-text-native-sanitize.ps1
"exit=$LASTEXITCODE"
"--- the warning MUST NOT appear ---"
docker logs pacgate-api --since 10m 2>&1 | Select-String -Pattern 'Tier-1 rules only|NER model load failed'
```

Expected: the gate script exits 0 (it is a live-stack gate), and the grep prints **nothing**. A `Tier-1 rules only` line means the var is not reaching the process; a `NER model load failed` line means the path or files are wrong, which is the fail-closed behaviour working correctly.

- [ ] **Step 4: Report honestly, including what was NOT proven**

Record which of these were actually observed:

- [ ] `PACGATE_NER_MODEL_DIR` present inside the container.
- [ ] Three files present at the path.
- [ ] No degradation warning in the log.
- [ ] A document sanitized with NER active.

If a real upload with a person name could not be exercised (auth, missing matter, no UI), say so explicitly and state that the detector set is proven only by the **absence of the warning plus the container's env**, not by an observed redaction. Do not describe it as verified end-to-end.

- [ ] Step 5: no commit — this task changes no files. Its output is evidence for Task 6's release note.

---

### Task 6: Bump to 0.1.19 and refresh the pin surfaces

**Files:**
- Modify: the pin surfaces the existing tooling owns

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: a consistent 0.1.19 across `Cargo.toml`, both compose files and the client docs, checked by the existing gates.

- [ ] **Step 1: Use the existing bump script, not manual edits**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/bump-release-version.ps1 -Version 0.1.19
"exit=$LASTEXITCODE"
git status --short
```

**Verify it actually changed files.** A previous version of this script silently made 0 edits and exited 0, so an exit code alone is not evidence — confirm `git status --short` is non-empty and shows the expected files.

- [ ] **Step 2: Run the pin-consistency gates**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/audit-doc-freshness.ps1 -SkipRemote
"doc-freshness exit=$LASTEXITCODE"
& pwsh -NoProfile -File scripts/test-version-marker.ps1
"version-marker exit=$LASTEXITCODE"
& pwsh -NoProfile -File scripts/preflight-release-tag.ps1
"preflight exit=$LASTEXITCODE"
```

Expected: all exit 0. `preflight-release-tag.ps1` is the gate that decides whether tagging is safe; read its output rather than only its exit code.

- [ ] **Step 3: State the image-size cost in the client deliverables**

`spec §8.2` requires the 388 MB deployment constraint to be *stated*, not implied. Add to `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md` (or its 0.1.19 successor) a line in the coverage section:

```markdown
### Enabling the name detector: what it costs

From 0.1.19 the `pacgate-api` image carries the Chinese NER weights, so it also
detects person and organisation names - the classes rules cannot see. Coverage
goes from **7 of 15** classes to **10 of 15**.

The cost is image size: `pacgate-api` grows by about **407 MiB** (measured), from
128.6 MiB to 535.7 MiB, fetched once at install. The weights are baked in rather
than downloaded on first use, deliberately: this is a data-residency product, and
a runtime fetch to a third party would sit inside the sanitization path itself.
An install with no egress still works.

Verify NER is active with:
`docker exec pacgate-api printenv PACGATE_NER_MODEL_DIR` (expect `/app/models/ner`)
```

Replace `<MEASURED>` with the byte figure from Task 1 Step 5, converted to MiB. Do not guess it.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add -A
git commit -m "chore(release): 0.1.19 - NER enabled by default

Bumps the pin surfaces and states the image-size cost in the client deliverable,
which spec 8.2 requires to be declared rather than implied. Coverage 7 of 15
classes to 10 of 15."
```

**Do NOT tag or dispatch in this task.** Tagging is a separate, deliberate step: run `scripts/preflight-release-tag.ps1`, confirm exit 0, then tag. A tag triggers the image build.

---

## Self-Review

**1. Spec coverage**

| Spec item | Task |
|---|---|
| §9 step 4: distribution — image + compose wiring + gate | Tasks 1-4 |
| §9 step 5: enable and verify — live E2E on the dev box | Task 5 |
| §6: fail-closed semantics kept (unset warns, set-broken errors) | Global Constraints; Task 3 comment |
| §6: "nothing forces production to set the variable. Fix with a gate" | Task 4 |
| §8.2: weights are 388 MB, a deployment constraint worth stating | Task 6 Step 3 |
| §10: the image logs the full detector set, no `Tier-1 rules only` warning | Task 5 Step 2/3 |
| §7: gate — image contains weights | Task 4 Step 1 (docker branch) |
| §7: gate — compose sets the variable | Task 4 Step 1 |

**Not covered, deliberately:** the release itself (`v0.1.19` tag + GHCR dispatch) and the AIPC 1/2 deployment. Both are deliberate operator steps with their own pre-flight (`scripts/preflight-release-tag.ps1`). This plan ends at a consistent, verified, untagged tree.

**2. Placeholder scan**

No placeholders remain. An earlier draft had a `<MEASURED>` marker in Task 6 Step 3, which was correct at the time (the size was unknown until Task 1 ran). Task 1 has now run and the measured figure — 407 MiB delta, 128.6 → 535.7 MiB — is written in literally, along with the method used to obtain it. The `<MEASURED>` instruction was removed rather than left as a step, because a step that says "replace this marker" invites a guessed number.

**3. Type consistency**

- `/app/models/ner` appears in exactly three places that must agree: the Dockerfile `COPY` target, both compose files, and the gate's assertion. All three use the same literal.
- `NER_MODEL_REV` — Dockerfile `ARG` (Task 1) and the workflow `build-args` (Task 2). Same name.
- `pacgate-api:ner-test` — the local tag used in Task 1 Step 4, Task 4 Step 1's optional docker check, and Task 5 Step 1's retag. Consistent.
- The three SHA-256 values in Task 1 Step 1 match F2 exactly, and match the `stat -c %s` byte lengths.
- `$script:failures` — the gate's failure counter, following the pattern in `scripts/test-sanitization-gate.ps1` (`$script:failures++` inside a `function Fail`).
- `$gates` array — confirmed to exist in `scripts/run-all-checks.ps1`; the prior plan's Task 6 added `test-rust-workspace.ps1` to the same array.

One inconsistency found and fixed during review: an earlier draft of Task 4 Step 1 hardcoded the two compose filenames. That is the same blindness that let the variable be missing from all of them, so the gate now **discovers** compose files defining `pacgate-api` and fails if it finds none (a vacuous-pass guard).

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-26-ner-p3-distribution.md`.

**Dependency ordering:** Task 1 → Task 2 (the arg is consumed by Task 1's stage) → Task 3 (points at Task 1's path) → Task 4 (asserts 1 and 3) → Task 5 (exercises the running result of 1-4) → Task 6 (bumps last, so the version describes the finished state).

**The three things that must not slip:**

1. **Task 5's absence-of-warning check.** Task 4 asserts configuration; only Task 5 shows the running process actually got the variable. A container restarted rather than recreated will still have the old environment.
2. **Task 4 Step 3's negative test.** A gate that has never been red is not evidence, and this one guards the exact silent-degradation failure the whole P3 exists to remove.
3. **Task 6 Step 1's `git status` check.** The bump script has silently made zero edits and exited 0 before.
