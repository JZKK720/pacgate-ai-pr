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

## Status (updated 2026-11-02)

| Task | State |
|---|---|
| 1 - gate every configured laya checkpoint | **DONE** — four assertions in `scripts/test-laya-tools.ps1` L10 (mount, `.env.example`, `LAYA_MODELS` default, live round-trip), four cache states red-checked, `.env.example` uncommented |
| 2 - `compose.bench.yaml` benchmark override | **DEFERRED** by the operator on 2026-11-02. Decided dev-only, not shipped |
| 3 - retract the false qm-digest gap | **DONE** — recorded in "Verified starting state" above; the original laya-plan target was wrong and is corrected in place |
| 4 - document the benchmark ceiling | not started |
| 5 - full read-back | partially done — the gate sweep ran (81 pass / 0 fail / 1 known skip); the enable-path re-proof is outstanding |

**What Task 1 cost, for the next person writing an assertion here.** The first
version of the block went green and was wrong in three ways. Every one was found by
*reintroducing the defect*, never by reading the code back. Six earlier assertions in
this suite failed the same way. Treat a green result on a new assertion as no
evidence at all until you have made it red.

---

## Verified starting state

These were measured before writing the plan, not assumed:

| Claim | Verified result |
|---|---|
| No gate knows `LAYA_HF_CACHE` is required | `Select-String scripts/test-*.ps1 -Pattern LAYA_HF_CACHE` → **0 matches** |
| `LAYA_HF_CACHE` absent from the deployed `.env` | **absent** — see the corrected failure analysis below |
| Benchmarks never run in CI | **0** gate references `bench-laya-*` |
| qm digests untracked | **FALSE, re-verified 2026-11-02.** `compose.qm.yaml:19` pins `ghcr.io/yc-software/qm/core@sha256:bee03e7f2271...` by digest and the running container matches it. Digest pinning is the *stronger* form, so there was never a gap. The audit reported it without checking; the check is one `Select-String`. No code action, and nothing to retract in the laya plan - that document never made this claim. |
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

- [x] **Step 1: Write the three assertions**

Append immediately before the `Write-Host ''` / `$total = $script:pass + $script:fail` block at L415:

> **Written as shipped, then corrected twice by red-checking.** The version below is
> what landed. Three defects were found in it *after* it went green the first time,
> each by reintroducing the defect rather than by reasoning:
>
> 1. **Comment-vs-mount.** `$t -match 'LAYA_HF_CACHE'` over the whole file passes on
>    the comment alone, and both lanes have that comment. Deleting the mount while
>    keeping the comment still printed `[PASS]`. Now comment lines are stripped and
>    the match runs on non-comment lines only.
> 2. **Skip-on-crash.** Using `docker ps` (running only) meant a container that
>    **exited at boot** looked identical to "profile never enabled", so a dead
>    service summed green. Now `docker ps -a` separates absent (skip) from exited
>    (FAIL, with status and last log lines).
> 3. **No static teeth.** The only assertion able to catch the real defect was
>    inert on every machine where laya is not running - i.e. nearly all of them.
>    Added 2b: assert the `LAYA_MODELS` *default in both lanes* names both
>    checkpoints. That is static, survives a dead profile, and fails on a one-word
>    silent regression (`english` dropped ⇒ every English clause 500s).

```powershell
Write-Host ''
Write-Host 'L10 the laya profile cannot ship a checkpoint-less or half-loaded service' -ForegroundColor Cyan

# Measured 2026-11-02. Two failure modes, only one silent:
#   empty cache    -> container exits at boot (LocalEntryNotFoundError). Loud, safe.
#   PARTIAL cache  -> healthy, /health 200, loaded:["multilingual"], English -> HTTP 500.
# The partial case is the one this gate exists for, and it is why "the directory
# is non-empty" is not an assertion: it would pass here.

# 1. Both lanes must name the cache variable IN THE MOUNT, or the mount falls back to
#    a dev-box relative path that will not exist on an AIPC.
#
#    Comment lines are stripped first. Both lanes carry the string in a COMMENT on
#    the line above the mount ("then point LAYA_HF_CACHE at it"), so a whole-file
#    match passes after the mount itself is deleted - red-checked 2026-11-02 and it
#    did exactly that. This is the seventh vacuous assertion found in this gate
#    suite by red-checking; assume prose-matching assertions here are decoration.
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { Check "$lane exists" $false; continue }
    $mounts = @(Get-Content -LiteralPath $p |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'LAYA_HF_CACHE' })
    Check "$lane mounts laya's cache through LAYA_HF_CACHE" ($mounts.Count -ge 1) `
        'no non-comment line names LAYA_HF_CACHE; without it the mount falls back to a path that will not exist on an AIPC'
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

- [x] **Step 2: Run it to verify both red states**

Run: `pwsh -NoProfile -File scripts/test-laya-tools.ps1`
Expected today: **FAIL** on `.env.example sets LAYA_HF_CACHE uncommented` (it is commented — measured: `active LAYA_HF_CACHE lines: 0`), and **SKIP** on the behavioural pair because laya is not running.

> **RAN 2026-11-02: exactly as predicted** — `[FAIL] .env.example sets LAYA_HF_CACHE
> uncommented` and `[SKIP] running laya serves every configured checkpoint`, exit 1.
> This was the one step in the first draft whose expectation matched what happened.

- [x] **Step 3: Fix `.env.example`**

Replace the commented block with:

```dotenv
# REQUIRED when the laya profile is enabled. A relative value resolves against
# THIS directory (deploy/client-bundle), not your shell's cwd - so the default
# below means deploy/laya-hf-cache. Prefer an absolute path on any machine where
# in doubt. Stage the cache with scripts/stage-laya-models.ps1. An EMPTY cache
# makes the container exit at boot; a PARTIAL one reports healthy while the
# missing checkpoint's language returns HTTP 500. Set it before enabling the
# profile.
LAYA_HF_CACHE=../laya-hf-cache
```

> **Applied, then corrected 2026-11-02.** The first version omitted what the
> relative path is relative to. Verified with `docker compose -f compose.prod.yaml
> --profile laya config`: the shipped default resolves to
> `deploy/laya-hf-cache`, a sibling of the compose directory that nothing creates.
> It is the right value *for the compose file*, but an operator running
> `stage-laya-models.ps1 -OutDir ..\laya-hf-cache` from the repo root gets
> `D:\users\joeyzh\github-pr\laya-hf-cache` and then mounts an empty directory,
> which is the boot crash. The comment now states the resolution base.
> Also uncommented `LAYA_MODELS` with a note that it is not optional.

- [x] **Step 4: Verify green, then red-check the partial cache**

The version of this step below was **unrunnable**, and running it is how that was
found. Two defects, both verified:

- It started the probe as `--name laya-mt`, but the gate matches `name=^laya$`
  (`docker ps -a --filter 'name=^laya$'` returns `[]` for a container named
  `laya-mt`). The gate would print nothing and the expected `[FAIL]` could never
  appear.
- The cache it built had only `refs/main` and `snapshots/<sha>/multilingual`. That
  omits the snapshot root, so `laya-serve` dies with
  `FileNotFoundError: Incompatible model ... does not contain 'rl_agent_config.json'`
  before any HTTP surface exists. The documented `HTTP 500` was unreachable.

The **verified** procedure is the block below. Note it names the probe `laya`, and
uses `LAYA_MODELS=multilingual` because that is the configuration in which a
partial cache is silent rather than fatal.

```powershell
# The dev cache at .\laya-hf-cache is COMPLETE: `english` is the repo root and
# `multilingual` is a subfolder, so this one cache serves both checkpoints.
$src = 'laya-hf-cache\hub\models--convaiinnovations--laya'
$dst = "$env:TEMP\partial-cache\hub\models--convaiinnovations--laya"
$sha = '7b928d828b7b0e022f929d9bd2e44165aa270148'
New-Item -ItemType Directory -Force -Path "$dst\snapshots\$sha", "$dst\refs" | Out-Null
Copy-Item -LiteralPath "$src\refs\main" -Destination "$dst\refs\main"
Copy-Item -LiteralPath "$src\snapshots\$sha\multilingual" -Destination "$dst\snapshots\$sha\multilingual" -Recurse
Copy-Item -LiteralPath "$src\snapshots\$sha\config.json" -Destination "$dst\snapshots\$sha\config.json"

# Silent case: multilingual loads, english is built lazily and 500s.
docker run -d --name laya --network pacgate-ai-bundle_default `
  -e LAYA_PRELOAD=1 -e LAYA_MODELS=multilingual -e LAYA_MAX_LOADED=3 `
  -e HF_HUB_OFFLINE=1 `
  -v "$env:TEMP\partial-cache:/home/laya/.cache/huggingface:ro" `
  ghcr.io/jzkk720/laya-serve:0.2.12
Start-Sleep -Seconds 28
pwsh -NoProfile -File scripts/test-laya-tools.ps1 | Select-String 'English clause'
docker rm -f laya | Out-Null
Remove-Item -Recurse -Force "$env:TEMP\partial-cache" -ErrorAction SilentlyContinue
```

Expected: `[FAIL] a running laya can actually serve an English clause` with
`FAIL HTTPError HTTP Error 500`.

Then swap to the shipped default to exercise the other branch:

```powershell
# Fatal case: the default names both checkpoints, so the missing root weights
# crash the container instead. The gate must FAIL on 'the existing laya container
# is running', not skip.
docker run -d --name laya --network pacgate-ai-bundle_default `
  -e LAYA_PRELOAD=1 -e LAYA_MODELS=multilingual,english -e HF_HUB_OFFLINE=1 `
  -v "$env:TEMP\partial-cache:/home/laya/.cache/huggingface:ro" `
  ghcr.io/jzkk720/laya-serve:0.2.12
```

- [x] **RAN 2026-11-02: the red-check contradicted this plan in three places**

The steps above were written from reasoning. Running them changed the picture, and
the corrections are the substance of what this task taught:

1. **A partial cache does not reach `/health` at all under the shipped default.**
   `Router.preload()` builds every name `LAYA_MODELS` lists, and `laya/agent.py:664`
   raises `FileNotFoundError: Incompatible model: ... does not contain
   'rl_agent_config.json'` when the root checkpoint is absent. The `english`
   checkpoint *is* the repo root (`DEFAULT_MODELS["english"] = (BUNDLE_REPO, None)`),
   so "multilingual subfolder present, root weights absent" is a boot crash, not a
   healthy-but-500 service.

2. **The silent case needs a narrowed `LAYA_MODELS`.** With `LAYA_MODELS=multilingual`
   against that same cache the container is `Up`, `/health` is `200`,
   `loaded: ["multilingual"]`, Chinese works, and English returns `HTTP 500` —
   because the router builds `english` lazily on the first Latin clause. That is the
   state `[FAIL] a running laya can actually serve an English clause` catches, and it
   is the only assertion that does.

3. **The first version of the block SKIPped on a crashed container.** It tested
   `docker ps` (running only) and treated "not in `docker ps`" as "profile not
   enabled". So the boot-crash case from (1) produced a **green** summary against a
   dead service — the same vacuous-pass class this task exists to remove. Fixed:
   `docker ps -a` distinguishes *absent* (skip, legitimate) from *exited* (FAIL, with
   `docker ps -a` status and the last log lines in the detail).

Verified states, all measured against `ghcr.io/jzkk720/laya-serve:0.2.12`:

| Cache / config | Gate result |
|---|---|
| no `laya` container | `[SKIP] no laya container exists (the profile is opt-in)`, exit **0** |
| complete cache, `LAYA_MODELS=multilingual,english` | all pass, exit **0** |
| partial cache, `LAYA_MODELS=multilingual,english` | `[FAIL] the existing laya container is running` (exited 1, log quoted), exit **1** |
| partial cache, `LAYA_MODELS=multilingual` | `[FAIL] a running laya can actually serve an English clause` (HTTP 500), exit **1** |

- [x] **Step 5: Commit**

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

**Shipped or not, decided 2026-11-02: NOT shipped.** `scripts/package-bundle.ps1:74-84`
lists exactly `compose.prod.yaml` and `compose.bundle.yaml` plus named dirs; a new
override is not in that list and must not be added to it. This is a developer
re-measurement aid, not a client artifact - the shipped lane correctly publishes no
port, because laya holds model weights and only `pacgate-mcp` should reach it. State
this in the file header so nobody adds it to `$IncludeFiles` by reflex.

**Interfaces:**
- Consumes: the `laya` service from `compose.prod.yaml`, and the `-LayaUrl` parameter both benchmarks already accept (default `http://127.0.0.1:8000/v1/systemone`)
- Produces: nothing consumed by later tasks

**Design note — a dead wrapper was drafted first and rejected.** The obvious approach was a script that runs the benchmark *inside* the compose network. It cannot work: the `laya-serve` image is a Python runtime with no `pwsh` and none of the benchmark's tooling. Shipping a wrapper that can only exit 2 would be worse than no wrapper. The override below is simpler and actually runs.

- [ ] **Step 1: Write the failing check — prove the port is absent today**

Run:
```powershell
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya config --services | Select-String laya
docker port laya 2>&1
```
Expected: `laya` is listed but `docker port` reports no published ports (or the container is absent). This is the condition to be fixed.

**Correction (2026-11-02): `--profile laya` is required.** Without it,
`config --services` returns 8 services and **omits `laya`**, because the service
declares `profiles: ["laya"]` (`compose.prod.yaml:559`). Expected output without the
flag would send an implementer hunting a bug that does not exist.

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

**CORRECTED 2026-11-02 - the original target was wrong.** This task pointed at
`docs/superpowers/plans/2026-10-31-laya-local-decision-engine.md`'s "Still not
established" list. Verified: that file has **zero** matches for `qm`, and it holds
**two** sections with that heading (L117 and L170) - neither about qm. Appending a
qm-digest retraction there would attach an unrelated correction to a laya document
and close nothing. The four-gap record lives in *this* plan's own "Verified starting
state" table, which is where the retraction belongs.

**Files:**
- Modify: `docs/superpowers/plans/2026-11-02-verification-gaps.md` (the "Verified starting state" table)

- [x] **Step 1: Verify the qm digest claim is really true**

Run:
```powershell
Select-String -Path deploy/client-bundle/qm-pacgate/compose.qm.yaml -Pattern 'sha256:bee03e7f2271'
docker inspect qm-pacgate-core -f '{{.Config.Image}}'
```
Expected: the digest appears in the compose file and matches the running container.

- [x] **Step 2: Add a dated correction to the plan's own table**

Replace the qm row of "Verified starting state" with:

```markdown
| qm digests untracked | **FALSE, re-verified 2026-11-02.** `compose.qm.yaml:19` pins `ghcr.io/yc-software/qm/core@sha256:bee03e7f2271...` by digest and the running container matches it. Digest pinning is the *stronger* form, so there was never a gap. The audit reported it without checking; the check is one `Select-String`. No action, and nothing to retract in the laya plan - that document never made this claim. |
```

> **DONE 2026-11-02.** Applied to the "Verified starting state" table. Verified
> first: `Select-String -Path docs/superpowers/plans/2026-10-31-laya-local-decision-engine.md
> -Pattern qm` → **0 matches**, and that file has **two** `Still not established`
> headings (L117, L170), neither about qm. The original Step 2 would have attached an
> unrelated correction to a laya document and closed nothing. No separate commit was
> made for this task alone; the retraction landed with the gate corrections in
> `7897ddf` because both touched the same table.

- [x] **Step 3: Commit**

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
(Select-String -Path deploy/AIPC-DEPLOYMENT-HANDBOOK.md -Pattern '<what the numbers do not cover|这些数字未覆盖' -CaseSensitive:$false).Count
(Select-String -Path deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md -Pattern '<what the numbers do not cover|这些数字未覆盖' -CaseSensitive:$false).Count
```
Expected: **1 and 1** - the newly added limitation section, present in both.

**Correction (2026-11-02): counting `laya` cannot be the parity check.** Measured at
baseline, before any edit: EN = **5**, ZH = **7**. "Equal counts" is unachievable
today and, worse, a check that starts red cannot distinguish a wrong edit from the
pre-existing 5-vs-7. Parity must be asserted on the text this task adds - a marker
unique to the new section, one occurrence per language. The pre-existing 5-vs-7 is a
real asymmetry, but it is out of scope here; note it rather than silently fix it.

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
$fail=@(); $cannot=@(); Get-ChildItem scripts -Filter 'test-*.ps1' | ForEach-Object {
  $o = pwsh -NoProfile -File $_.FullName 2>&1 | Out-String
  if ($LASTEXITCODE -eq 2) { $cannot += $_.Name }
  elseif ($LASTEXITCODE -ne 0) { $fail += "[$LASTEXITCODE] $($_.Name)" }
}
"pass=$(82 - $fail.Count - $cannot.Count) fail=$($fail.Count) cannot=$($cannot.Count)"
$fail; $cannot
```

Expected: `fail=0`, `cannot=1`, the one being `test-chat-artifact-durability.ps1`.
That gate exits 2 **by design** when no thread reports an output file - it is a
data-absence skip, not a pass and not a regression. Corrected baseline (measured):
**81 pass / 0 fail / 1 cannot**, 82 scripts total. The earlier "82/82 ALL PASS"
wording was wrong and would have made a healthy run look broken.

Classifying exit 2 separately also resolves the apparent conflict with the Global
Constraint "exit 2 is never a pass": a CANNOT-CHECK is not a pass, but neither is it
a failure of the code under test - it must be *named*, never silently counted green.

Also required: clear the proxy variables first. A dead proxy at `127.0.0.1:7892`
makes `test-release-provenance.ps1` report `registry read failed` and exit 2, which
is an environment fault, not a defect. Without the clears, this sweep shows two
CANNOT-CHECKs instead of one.

- [ ] **Step 2: Prove the enable path once more, end to end**

Run:
```powershell
$env:LAYA_HF_CACHE = (Resolve-Path .\laya-hf-cache).Path   # repo root; NOT ..\laya-hf-cache
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya up -d laya
pwsh -NoProfile -File scripts/bench-laya-chinese-risk.ps1 -LayaUrl http://127.0.0.1:8000/v1/systemone
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya stop laya
docker compose -f deploy/client-bundle/compose.prod.yaml --profile laya rm -f laya
```
Expected: recall on 风险高 ≥ 0.86, then a teardown that touches **only** `laya`.

Two corrections. `(Resolve-Path ..\laya-hf-cache)` does not exist from the repo root
(staged cache is `.\laya-hf-cache`, gitignored at `.gitignore:226`); the stage
script's `-OutDir ..\laya-hf-cache` is written for a caller in
`deploy/client-bundle`, not the repo root. And `down` tears down the entire merged
project context - on this box the main stack project `pacgate-ai-bundle` is live, so
`stop` + `rm -f laya` is the safe teardown.

- [ ] **Step 3: Commit anything the read-back changed, or confirm clean**

Run: `git status --short`
Expected: empty.

---

## What this plan does NOT do

Honesty about scope, because a plan that implies it closed everything would be the same mistake the audit made:

- **It cannot create a PRC-contract benchmark.** That needs real documents. Task 4 makes the limitation visible so nobody over-reads the numbers.
- **It does not put benchmarks in CI.** They need a 9 GB model image and 2.8 GB of staged weights; running them per-commit is disproportionate. Task 2 makes them runnable on demand instead of by folklore.
- **It does not re-verify the other 82 gates.** They pass, and their own red-checks are the reason to believe them. Spot-checking them now would be reassurance, not verification.
