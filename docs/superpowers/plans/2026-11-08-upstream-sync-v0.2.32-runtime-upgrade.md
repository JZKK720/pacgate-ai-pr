# Upstream Sync to v0.2.32 and Runtime Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring this dev box's running Pacgate stack from 0.2.30 up to the 0.2.32 release the tree now pins, close the config drift the jump exposes, and prove the PDF-outline and recursion-floor fixes that are the entire reason for the release.

**Architecture:** Two phases, deliberately separated. **Phase A (history)** is already complete in `fd23be0` and is history-only - this document records it so an executor does not repeat it. **Phase B (runtime)** is the real work, and it is an *environment* migration, not a code migration: the six images are published and anonymously pullable (proven below), and the tree's own gates already name every stale service. Nothing here edits application code.

**Tech Stack:** Docker Compose (client bundle lane, plus the gitignored `compose.local-model-override.yaml`), GHCR-published images, Ollama, PostgreSQL 16 + pgvector, PowerShell 7, Rust workspace at `pacgate-ai/`.

**Spec:** `docs/superpowers/plans/2026-11-05-local-runtime-sync-v0.2.30.md` (the predecessor plan for the 0.1.33 -> 0.2.30 migration; its Global Constraints still bind and are restated below) plus `deploy/DEFECT-recursion-budget-floor.md` (the defect this release fixes).

## Global Constraints

- **Never retag a `ghcr.io/jzkk720/*` image locally.** A local tag that disagrees with the registry digest is exactly what `scripts/test-stack-version-coherence.ps1` and `scripts/test-release-provenance.ps1` exist to catch.
- **`PACGATE_SANITIZER_KEY` must be set per deployment and must not be shared between client sites.** Already set on this box (64 hex chars, verified).
- **`LAYA_MODELS` must keep both `multilingual` and `english`.** A partial load ships *silently*: compose reports `healthy`, `/health` returns 200, and only the missing language returns 500. Already correct on this box.
- **Do not mount anything over `/home/laya/.cache/huggingface`.** A bind mount REPLACES the image layer, hiding every baked weight (proven 2026-11-02 in `compose.prod.yaml`).
- **`laya` is behind the `laya` profile.** `docker compose config --images` omits it by design; a pull of the default lane does not fetch it. It is not running on this box and that is not a defect.
- **Gate exit codes: 0 = pass, 1 = real defect, 2 = CANNOT CHECK. Exit 2 is never a pass.**
- **A fresh clone is the only valid test for install-path changes.** This box accumulates credentials, pulled models, and rendered gitignored configs. Nothing in this plan is proof that a clean AIPC install works.
- **`deploy/client-bundle/deer-flow-config.local.yaml` is a COPY, not an include.** It is gitignored and it does not follow upstream. After this upgrade it MUST be regenerated, or deer-flow silently keeps serving 0.2.30 settings out of a 0.2.32 image. See Task 3.

---

## Verified starting state

Measured on this box on 2026-11-08 before writing the plan, not assumed.

| Claim | Verified result |
|---|---|
| Local `main` had diverged | `ahead 9, behind 8` of `origin/main` |
| Upstream-only commits | 8, `1876560..17a498e` |
| Local-only commits | 9, `4ad8ec5..969e0be` |
| Divergence is textual and small | `git merge-tree --write-tree` -> exactly **one** conflicted path: `deploy/client-bundle/.env.example` |
| The one conflict was documentation-only | Both sides appended different Firecrawl paragraphs; the merge keeps both (they are complementary, not alternatives) |
| Merge completed | `fd23be0`, `main...origin/main [ahead 10]` (0 behind), backup branch `backup/pre-sync-2026-11-08` -> `969e0be` |
| Tree version | `pacgate-ai/Cargo.toml` -> `version = "0.2.32"` |
| Running stack version | all five release containers -> `:0.2.30` |
| **Stack is stale, per the repo's own gate** | `test-stack-version-coherence.ps1` -> `9 passed, 5 failed`; all five are the same fact |
| Release provenance | `test-release-provenance.ps1` -> **PASSED**: `v0.2.32` identifies the `7a6dd732c6df` artifacts clients will pull |
| Images are published | anonymous `check-ghcr-anon.py --tag 0.2.32` -> all 6 PUBLIC |
| **Images actually PULL** | `docker pull ghcr.io/jzkk720/pacgate-mcp:0.2.32` -> **exit 0**, digest `sha256:cb33113c…`; `ocr-service:0.2.32` -> exit 0 |
| Local image cache | only `:0.2.30` for the five release services (plus the `:0.2.32` pulled above) |
| Model roster unchanged between 0.2.30 and 0.2.32 | `ollama-models.txt` is byte-identical at both refs |
| All roster tags already on this box | `nemotron-3.5-bolt:e4b-q8_0`, `nomic-embed-text:latest`, `deepseek-v4.1-flash:cloud`, `glm-5.3-flash:cloud`, `ornith-1.5:9b` all present |
| No new DB migrations | `pacgate-ai/migrations/` is byte-identical at 0.2.30 and 0.2.32 (stops at `009_cjk_fulltext.sql`) |
| Local-only fixes are genuinely absent upstream | each checked by `git log origin/main --grep` **and** by reading the upstream file body |
| **The release's headline fix is RED on this box** | `test-pdf-outline-extraction.ps1` -> `2 passed, 5 failed`; `ModuleNotFoundError: No module named 'pymupdf4llm'`, `headings=0 outline=0` |
| Local rendered config is now stale | `deer-flow-config.local.yaml` lacks `pdf_converter: auto` and the 2026-11-06 comment block; it is a snapshot taken at 0.2.30 |
| Static gates on the merged tree | installer syntax clean; model roster `14 of 14`; compose healthchecks `0 failure(s)`; baked patch parity `16 passed, 0 failed`; firecrawl wiring `19 passed, 0 failed`; `audit-deer-flow-patches` OK; `audit-model-tags` OK |
| Hardware | **Ryzen AI MAX+ 395 / Radeon 8060S unified-memory iGPU** - the MAX+ class, NOT the shipped HX370 / RX 7600 XT 16 GB client class. The 74B `nemotron-3.5-bolt:74b-a9b-iq2` (24 GB on disk) is present and is the ONLY reason `compose.local-model-override.yaml` exists |
| Residency is size-one on this box (MEASURED 2026-11-08) | Loading `nemotron-3.5-bolt:e4b-q8_0` **evicted** a resident 74B, and loading `ornith-1.5:9b` **evicted** a resident e4b. `ollama ps` never showed two of them at once. This is the fact that decides Task 2 |
| 74B actually runs here (MEASURED) | `nemotron-3.5-bolt:74b-a9b-iq2` -> `done_reason: stop`, 51.9 tok/s decode, 46 tok/s prefill, `4.2 GB` resident at 131072 ctx, 100% GPU. It is a working model on this machine, not a paper entry |
| 74B needs a real token budget | At `num_predict: 16..24` the 74B returns `content: ""` with `done_reason: "length"` - all budget spent on `thinking`, exactly the trap `LOCAL-MODEL-PICKER-74B.md` documents. It answers correctly at `num_predict: 400` |
| e4b vs ornith throughput here (MEASURED, warm) | e4b `e4b-q8_0`: prefill 1274 tok/s, decode 58.9 then 34.2 tok/s. ornith `ornith-1.5:9b`: prefill 992 tok/s, decode 33.4 / 33.8 tok/s. **e4b wins both axes on this box** - the opposite of the upstream comment's "ornith 1263 vs 1080" ordering |
| Local picker roster is unmodelled by the gates | `test-model-picker-e2e.ps1` reads the **tracked** `deer-flow-config.yaml` only (`$cfg` at line 128). The local 74B entry and the local config are therefore never validated by it |
| Capacity gate | `test-aipc-capacity-fit.ps1` -> `RESULT: no unconditional over-cap model`, exit 0. It budgets the 16 GB CLIENT class, which is why the 74B must stay out of the tracked roster |
| Live `.env` | `PACGATE_MODEL_MID=ornith-1.5:9b`, `PACGATE_MODEL_LOW=nemotron-3.5-bolt:e4b-q8_0`, `PACGATE_SANITIZER_KEY` set, `LAYA_MODELS=multilingual,english` |
| No untracked path collides with upstream | all 13 untracked files checked with `git cat-file -e origin/main:<path>` -> none present |

### What upstream adds, in one paragraph each

**PDF outline extraction (the reason for the release).** `deer-flow` prefers `pymupdf4llm` and silently falls back to MarkItDown when the module is missing. It was missing, so every PDF lost its typographic hierarchy - 0 outline entries where `pymupdf4llm` yields 51 on the same 65-page CJK PDF. With no outline the uploads middleware hands the agent an unnavigable document, which is the measured cause of three 87-104-call, 3.2-3.5M-token runs that all died in `GraphRecursionError` with nothing delivered. The release installs `pymupdf4llm==2.1` / `pymupdf==2.1` behind a constraint file, adds `deploy/client-bundle/patches/deer-flow-file-conversion.py` to strip `<mark>`/`<br>` from heading titles, and adds `scripts/test-pdf-outline-extraction.ps1` as a dependency gate with a `>= 10 entries` control so a near-empty outline cannot pass.

**Recursion floor.** The 2026-10-28 fix was a CEILING (clamp a caller down to 4000). It never raised a caller UP, and the chat UI asks for exactly 1000 on every run, so the ceiling was never binding. 22 recorded runs died at exactly 1000 while the deepest SUCCESSFUL run needed 937 super-steps / 109 LLM calls. The release adds `DEERFLOW_MIN_RECURSION_LIMIT` (default 2000) so a UI-supplied 1000 arrives as 2000.

**Model tier residency.** `PACGATE_MODEL_MID` moves from `ornith-1.5:9b` to the same tag as LOW (`nemotron-3.5-bolt:e4b-q8_0`), for residency rather than capability: one resident model means no reload between a Mid and a Low call. This box's live `.env` still pins MID to `ornith-1.5:9b`, which is now a deliberate per-machine override rather than the shipped default - see Task 2 for why that is a decision to make, not a drift to fix.

---

## File Structure

| Path | Responsibility | Change |
|---|---|---|
| `deploy/client-bundle/.env` | Live deployment config (gitignored) | **Modify** only if Task 2 decides to adopt the MID default |
| `deploy/client-bundle/deer-flow-config.local.yaml` | Machine-local rendered config (gitignored) | **Regenerate** from the new tracked config, re-applying the 74B block |
| `deploy/client-bundle/compose.prod.yaml` | The lane this box runs | Read only - pins 0.2.32 |
| `deploy/client-bundle/compose.local-model-override.yaml` | Machine-local mount override (gitignored) | Read only |
| `scripts/test-stack-version-coherence.ps1` | Proves every container matches its pin | Run - acceptance gate for Task 4 |
| `scripts/test-pdf-outline-extraction.ps1` | Proves the converter is present and yields headings | Run - acceptance gate for Task 5 |
| `scripts/test-run-recursion-cap.ps1` | Proves both the cap and the floor hold | Run - acceptance gate for Task 5 |
| `scripts/smoke-full-stack.ps1` | Live lane smoke | Run - Task 6 |
| `scripts/test-legal-journey.ps1` | Matter -> upload -> OCR -> sanitize -> review -> search -> qm -> recall | Run - Task 6 |
| `scripts/audit-e2e-credentials.ps1` | Are the credentials VALID, not merely present | Run - Task 6 |
| `docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md` | This plan and its measured outcome | Created |

No application source is touched by this plan. If a task appears to need a source edit, stop: that is a defect to file, not a step to improvise.

---

## Task 1: Record the merge outcome and confirm the local fixes still exist

Phase A is done (`fd23be0`). This task exists so the executor does not re-merge, and so the local-only work is proven present before an image swap can mask a regression.

**Files:**
- Read: `deploy/client-bundle/patches/pacgate-adapter-client.py`
- Read: `scripts/audit-e2e-credentials.ps1`
- Read: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: commit `fd23be0` on `main`
- Produces: confidence that `_request()` bounded retry, `audit-e2e-credentials`, and the 74B picker docs all survived

- [x] **Step 1: Confirm the merge commit is HEAD's parent line**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
git --no-pager log --oneline -3
```

Expected: `fd23be0` at HEAD, then `17a498e`, `f19b8c1`.

- [x] **Step 2: Confirm the tree is at 0.2.32 and nothing is behind**

```powershell
git --no-pager status -sb
Select-String -Path pacgate-ai\Cargo.toml -Pattern '^version'
```

Expected: `## main...origin/main [ahead 10]` with **no** `behind`, and `version = "0.2.32"`.

- [x] **Step 3: Confirm the bounded 401 retry is the merged version, not upstream's recursion**

```powershell
Select-String -Path deploy\client-bundle\patches\pacgate-adapter-client.py -Pattern 'for attempt in range\(2\)'
```

Expected: exactly one match. Zero matches means the merge silently took upstream's recursive `if self._relogin_if_401(resp) is None: return self.get(...)` and the login-storm defect is back.

- [x] **Step 4: Confirm both local gates are still registered**

```powershell
foreach ($g in @('audit-e2e-credentials','test-pdf-outline-extraction','test-firecrawl-wiring')) {
  "{0}: {1}" -f $g, (Select-String -Path scripts\run-all-checks.ps1 -Pattern $g | Measure-Object).Count
}
```

Expected: `1` for each. `0` means upstream's rewrite of `run-all-checks.ps1` dropped the registration.

- [x] **Step 5: No commit needed**

Phase A is already committed. If any step above fails, that is a merge defect: fix it, re-run the four static gates listed in "Verified starting state", and commit with `fix(sync): ...` before proceeding to Task 2.

---

## Task 2: Record the local-model posture, and correct the MID tier against this box's measurement

**This box is not a client.** It is a Ryzen AI MAX+ 395 with a Radeon 8060S unified-memory iGPU, so the binding resource is not OS-visible RAM (Windows reports 31.6 GiB) and not a 16 GB dedicated card - it is the iGPU carve-out, which is the same point `deploy/LOCAL-MODEL-PICKER-74B.md` makes. Everything below follows from two things measured on 2026-11-08 rather than assumed:

1. **Only one local model can be resident at a time here.** Loading `nemotron-3.5-bolt:e4b-q8_0` evicted a resident `74b-a9b-iq2`; loading `ornith-1.5:9b` evicted a resident `e4b-q8_0`. `ollama ps` never showed two at once.
2. **The 74B genuinely runs here**, at 51.9 tok/s decode / 46 tok/s prefill / 4.2 GB resident - it is a usable model, not a paper entry. It needs `num_predict` well above 24 or it returns an empty body with `done_reason: "length"`.

Upstream now ships `PACGATE_MODEL_MID=nemotron-3.5-bolt:e4b-q8_0` (the same tag as LOW) for *residency*. This box pins MID to `ornith-1.5:9b`. Because residency is size-one regardless of which pair you pick, upstream's one-resident-model argument is satisfied by **e4b = MID = LOW**, whereas ornith = MID forces an eviction on every Mid/Low alternation. The throughput ordering upstream records does not reproduce here.

**Files:**
- Modify: `deploy/client-bundle/.env` (gitignored) - one line
- Create: `docs/superpowers/decisions/2026-11-08-local-model-posture.md`

**Interfaces:**
- Consumes: the measurements in "Verified starting state"
- Produces: an adopted `.env` MID value, and a decision record; no code

- [x] **Step 1: Re-read the upstream rationale verbatim before overriding it**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
Select-String -Path deploy\client-bundle\.env.example -Pattern 'MID changed 2026-11-07' -Context 0,12
```

The claim to test is: *"One tag means one resident model and no reload between a Mid and a Low call. The recorded trade-off is ingestion: ornith measured 1263 tok/s prefill vs 1080 here, while this tag wins generation 81 vs 64 tok/s."*

- [x] **Step 2: Confirm residency is size-one on this box**

```powershell
# Load the 74B, then load the e4b, and watch the 74B disappear.
$b1 = @{model='nemotron-3.5-bolt:74b-a9b-iq2'; prompt='ok'; stream=$false; keep_alive='15m'; options=@{num_predict=8}} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' -Method Post -Body $b1 -ContentType 'application/json' -TimeoutSec 900 | Out-Null
ollama ps
$b2 = @{model='nemotron-3.5-bolt:e4b-q8_0'; prompt='ok'; stream=$false; keep_alive='15m'; options=@{num_predict=8}} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' -Method Post -Body $b2 -ContentType 'application/json' -TimeoutSec 600 | Out-Null
ollama ps
```

Expected: one row each time, and it is a different row the second time. Two rows would invalidate the premise and you should stop and re-measure rather than continue.

- [x] **Step 3: Re-measure the two candidates, warm, on this box**

```powershell
$ctx = ('The matter concerns a cross-border supply agreement. ' * 120)
function Measure-Model($model) {
  $b = @{model=$model; prompt=$ctx; stream=$false; options=@{num_predict=128}} | ConvertTo-Json -Depth 5
  $r = Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600
  "{0,-32} prompt_tok={1,5} prefill={2,6:N0} tok/s decode={3,6:N1} tok/s" -f `
    $model, $r.prompt_eval_count, ($r.prompt_eval_count / ($r.prompt_eval_duration/1e9)), ($r.eval_count / ($r.eval_duration/1e9))
}
Measure-Model 'nemotron-3.5-bolt:e4b-q8_0'   # warmup
Measure-Model 'nemotron-3.5-bolt:e4b-q8_0'
Measure-Model 'ornith-1.5:9b'               # warmup, also evicts e4b
Measure-Model 'ornith-1.5:9b'
```

Expected on this box (recorded 2026-11-08): e4b ~1274 prefill / ~34-59 decode; ornith ~992 prefill / ~34 decode. If ornith wins prefill decisively on your run, that is grounds to keep ornith - the point is that the decision rests on a number from this machine.

- [x] **Step 4: Write the decision record**

```powershell
New-Item -ItemType Directory -Force docs\superpowers\decisions | Out-Null
```

Create `docs/superpowers/decisions/2026-11-08-local-model-posture.md`. It must state, with the measured numbers: this machine's hardware class (MAX+ 395 / 8060S, **not** the HX370 client class); that residency is size-one; the two MID options and their measured throughput here; that the 74B is a working option on this box **and must never enter `ollama-models.txt`** (that list is the client pre-pull contract and the 74B is 150% over the 16 GB client budget per `test-aipc-capacity-fit.ps1`); and the chosen MID value with its reason.

- [x] **Step 5: Adopt the MID value in `.env`, one line**

```powershell
cd deploy\client-bundle
# Use whichever Step 4 recorded. Shown here: adopt upstream's e4b, since it won both axes here.
(Get-Content .env) -replace '^PACGATE_MODEL_MID=ornith-1\.5:9b$', 'PACGATE_MODEL_MID=nemotron-3.5-bolt:e4b-q8_0' |
  Set-Content .env -Encoding utf8NoBOM
Select-String -Path .env -Pattern '^PACGATE_MODEL_(MAIN|MID|LOW)='
```

Expected: MID and LOW both `nemotron-3.5-bolt:e4b-q8_0`, MAIN still `deepseek-v4.1-flash:cloud` (cloud is intentional per the 2026-08-30 decision - do not "fix" it).

- [x] **Step 6: Verify the roster gate still accepts the pair**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts\test-model-roster-consistency.ps1
```

Expected: `RESULT: 14 of 14 checks passed`, exit 0. A4 asserts Main and Mid are DISTINCT - this passes because MAIN is the cloud model. If you had set MID equal to MAIN it would fail, correctly.

- [x] **Step 7: Commit the decision record**

```powershell
git add docs/superpowers/decisions/2026-11-08-local-model-posture.md
git commit -m "docs(decision): record this box's local-model posture and the Mid tier it picks"
```

`.env` is gitignored and is not committed.

---

## Task 3: Regenerate the machine-local rendered config

`deer-flow-config.local.yaml` is a **copy** of the tracked config with the 74B block uncommented. It does not follow upstream, so it still carries 0.2.30 settings. If it is not regenerated, the 0.2.32 image mounts a 0.2.30 config and the PDF-outline fix's config half (`pdf_converter: auto` plus its explanatory block) is absent. This is the silent-drift trap `deploy/LOCAL-MODEL-PICKER-74B.md` warns about in the section "The one caveat: this file is a snapshot".

**Files:**
- Modify: `deploy/client-bundle/deer-flow-config.local.yaml` (gitignored)
- Read: `deploy/client-bundle/deer-flow-config.yaml`

**Interfaces:**
- Consumes: `deploy/client-bundle/deer-flow-config.yaml` at the merged HEAD (now contains `pdf_converter: auto`)
- Produces: a local variant that is the tracked config plus exactly the 74B uncomment

- [x] **Step 1: Prove the drift exists before regenerating**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle
git --no-pager diff --no-index -U0 -- deer-flow-config.yaml deer-flow-config.local.yaml |
  Select-String -Pattern '^[-+]' | Measure-Object | Select-Object -ExpandProperty Count
Select-String -Path deer-flow-config.local.yaml -Pattern 'pdf_converter'
```

Expected before the fix: a non-trivial line count AND **no** `pdf_converter` match. An absent setting is the drift: the code defaults to `auto`, so behaviour is correct, but the shipped rationale is gone from the file the container actually mounts.

- [x] **Step 2: Regenerate from the new tracked config, bounded explicitly**

The naive `^  #   ` rule is a **trap**: it also matches the next commented block (`qwen3.8-27b-local`), which would silently activate a model that is deliberately retired from the picker. Bound the block by the entry line and stop at the first non-continuation line.

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle
$src = Get-Content deer-flow-config.yaml
$out = New-Object System.Collections.Generic.List[string]
$state = 'idle'
foreach ($line in $src) {
    if ($state -eq 'idle' -and $line -match '^  # - name: nemotron-bolt-74b-local\s*$') {
        $state = 'in'; $out.Add(($line -replace '^  # - ', '  - ')); continue
    }
    if ($state -eq 'in') {
        if ($line -match '^  #   ') { $out.Add(($line -replace '^  #   ', '    ')); continue }
        $state = 'done'
    }
    $out.Add($line)
}
$out | Set-Content deer-flow-config.local.yaml -Encoding utf8NoBOM
"lines: $($out.Count)"
```

- [x] **Step 3: Verify exactly ONE picker entry became active**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle
Select-String -Path deer-flow-config.local.yaml -Pattern '^\s*- name:' | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }
```

Expected (verified 2026-11-08): six model entries - `nemotron-bolt-7b-local`, `nemotron-bolt-7b-memory`, `nemotron-bolt-74b-local`, `ornith-1.5-9b-local`, `deepseek-v4.1-flash-cloud`, `glm-5.3-flash-cloud`. **`qwen3.8-27b-local` must NOT appear** - if it does, the loop over-ran and you activated a deliberately disabled model.

- [x] **Step 4: Verify the diff is exactly one hunk and touches nothing in `uploads:`**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle
$d = git --no-pager diff --no-index -U0 -- deer-flow-config.yaml deer-flow-config.local.yaml 2>&1
"hunks: " + ($d | Select-String -Pattern '^@@' | Measure-Object).Count
"uploads drift: " + ($d | Select-String -Pattern 'pdf_converter|auto_convert' | Measure-Object).Count
```

Expected: `hunks: 1` and `uploads drift: 0`. A second hunk means the 74B boundary is wrong. Non-zero uploads drift means the new tracked `pdf_converter: auto` block was dropped or mangled - that is the config half of the release's headline fix.

- [x] **Step 5: Verify it is valid YAML and the 74B is not first**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle
python -c "import yaml; d=yaml.safe_load(open('deer-flow-config.local.yaml',encoding='utf-8')); n=[m.get('name') for m in d.get('models',[])]; print('models:',n); assert 'nemotron-bolt-74b-local' in n, '74B missing'; assert n[0]!='nemotron-bolt-74b-local', 'the 74B must never be first'; assert 'qwen3.8-27b-local' not in n, 'qwen must stay commented'; print('OK')"
```

Expected: `models: [...]`, then `OK`, exit 0. The "never first" assertion is the one that matters commercially: the first entry is what an unpinned run inherits, and the 74B is ~12x slower per token than the e4b on a run that did not ask for it.

- [x] **Step 6: Confirm the mount override still points at this file**

```powershell
Select-String -Path compose.local-model-override.yaml -Pattern 'deer-flow-config.local.yaml'
```

Expected: one match binding `./deer-flow-config.local.yaml:/app/backend/config.yaml:ro`. A changed bind-mounted file does not recreate a container - Task 4's `--force-recreate` is what makes this take effect.

- [x] **Step 7: Note what this step is NOT gated by**

`scripts/test-model-picker-e2e.ps1` reads only the **tracked** `deer-flow-config.yaml` (`$cfg`, line 128). Nothing in the repo validates the local variant. Steps 3-5 above are therefore the entire verification of this file, and they are manual on purpose - do not skip them on the assumption that a gate covers it.

- [x] **Step 8: No commit needed**

The file is gitignored by design. `.gitignore:247`.

---

## Task 4: Pull the 0.2.32 images and recreate the five release services

The one gate that is red is red for exactly one reason: the containers are old. This task closes it.

**Files:**
- Read: `deploy/client-bundle/compose.prod.yaml`
- Read: `deploy/client-bundle/compose.local-model-override.yaml`

**Interfaces:**
- Consumes: the 0.2.32 images already proven pullable and partially pulled
- Produces: a stack whose every container matches its pin; `test-stack-version-coherence.ps1` exit 0

- [x] **Step 1: Pull every pinned image, tolerating the documented network class**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
foreach ($i in @('pacgate-api','pacgate-mcp','ocr-service','deer-flow-pacgate','deer-flow-frontend-pacgate')) {
  for ($a=1; $a -le 5; $a++) {
    docker pull "ghcr.io/jzkk720/${i}:0.2.32" 2>&1 | Select-Object -Last 2
    if ($LASTEXITCODE -eq 0) { break }
    "retry $a for $i"; Start-Sleep -Seconds 15
  }
  if ($LASTEXITCODE -ne 0) { throw "pull failed for $i after 5 attempts" }
}
```

A `lookup ghcr.io: no such host` or `short read: unexpected EOF` here is the network class the 2026-11-05 plan already recorded - **retry, do not conclude the release is broken**. A `denied` or `manifest unknown` is different: stop and treat it as a real publish defect.

- [x] **Step 2: Prove all five images are now local at the right tag**

```powershell
foreach ($i in @('pacgate-api','pacgate-mcp','ocr-service','deer-flow-pacgate','deer-flow-frontend-pacgate')) {
  $t = docker images --format '{{.Repository}}:{{.Tag}}' | Where-Object { $_ -eq "ghcr.io/jzkk720/${i}:0.2.32" }
  "{0}: {1}" -f $i, ($(if ($t) { 'PRESENT' } else { 'MISSING' }))
}
```

Expected: five `PRESENT`.

- [x] **Step 3: Recreate the five release services, including the local override**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.local-model-override.yaml `
    up -d --force-recreate pacgate-api pacgate-mcp ocr-service deer-flow deer-flow-frontend
```

`--force-recreate` is required: a changed bind-mounted config does not recreate a container, and Task 3 changed exactly such a file. Omitting the second `-f` drops the 74B picker entry - the stack still runs, which is what makes that mistake easy to miss.

- [x] **Step 4: Wait for health, and read it rather than assuming**

```powershell
Start-Sleep -Seconds 25
docker ps --filter 'name=~^(pacgate-api|pacgate-mcp|ocr-service|deer-flow|deer-flow-frontend)$' `
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

Expected: all five running their `:0.2.32` image, `(healthy)` where a healthcheck exists. `deer-flow` takes longest; if it is `starting`, wait and re-read rather than recreating again.

- [x] **Step 5: Run the acceptance gate**

```powershell
pwsh -NoProfile -File scripts\test-stack-version-coherence.ps1
```

Expected: **exit 0**, `14 passed`. This is the task's definition of done. Exit 1 with the same five "MIXED STACK" lines means the recreate did not take - check `docker ps` for a container that never restarted.

- [x] **Step 6: Commit nothing**

Images and running containers are environment state, not repository content. The tree was already committed in Task 1/2.

---

## Task 5: Prove the release's two headline fixes on the upgraded stack

This is the whole point of the upgrade. Both gates are run **inside the recreated container**, so they are proving the image, not the tree.

**Files:**
- Read: `scripts/test-pdf-outline-extraction.ps1`
- Read: `scripts/test-run-recursion-cap.ps1`

**Interfaces:**
- Consumes: the recreated `deer-flow` container from Task 4
- Produces: exit 0 from both gates; the recorded before/after counts for the plan outcome

- [x] **Step 1: Prove the converter is now installed**

```powershell
docker exec deer-flow /app/backend/.venv/bin/python -c "import pymupdf4llm, pymupdf; print('present', pymupdf.__version__)"
```

Expected: `present 2.1`. `ModuleNotFoundError` means you are still looking at a 0.2.30 container - re-check `docker inspect deer-flow --format '{{.Config.Image}}'`.

- [x] **Step 2: Run the PDF outline gate**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts\test-pdf-outline-extraction.ps1
```

Expected: **exit 0**, all 7 assertions pass. The red baseline to compare against is recorded in this plan's "Verified starting state": `2 passed, 5 failed`, `headings=0 outline=0`, and 7 control failures on the HTML-stripping unit tests. In particular O4 (`>= 10 entries`) and O6 (no raw HTML in titles) must flip to PASS.

- [x] **Step 3: Run the recursion gate**

```powershell
pwsh -NoProfile -File scripts\test-run-recursion-cap.ps1
```

Expected: exit 0. It asserts **both** halves: a client cannot raise the budget above `DEERFLOW_MAX_RECURSION_LIMIT` (4000 default) **and** cannot pin it below `DEERFLOW_MIN_RECURSION_LIMIT` (2000 default). A gate that only checks the ceiling is the pre-0.2.32 half-fix.

- [x] **Step 4: Confirm the floor is what the container actually runs**

```powershell
docker exec deer-flow sh -c 'grep -n "_PACGATE_MIN_RECURSION_LIMIT" /app/backend/app/gateway/services.py | head -5'
```

Expected: non-empty. The patch is bind-mounted from the tree, so this also proves the mount survived the recreate.

- [x] **Step 5: Confirm no patch regressed under the new image**

```powershell
pwsh -NoProfile -File scripts\audit-deer-flow-patches.ps1
pwsh -NoProfile -File scripts\audit-recursion-regressions.ps1
```

Expected: patch audit `=== OK: every patched upstream path still exists at the target ===`; recursion audit `RESULT: fix EVIDENCED`. The recursion audit's `[INFO] deepest successful run since baseline` is informational - a quiet result is not evidence either way, and it says so.

- [x] **Step 6: Commit nothing, but record the numbers**

Note the PDF gate's before (`2 passed, 5 failed`) and after counts, and the recursion gate's result. They go into this plan's outcome section in Task 7.

---

## Task 6: Prove the lanes still work end to end

A green version gate proves the images are the right ones. It does not prove the stack works. This task is the one that does.

**Files:**
- Read: `scripts/smoke-full-stack.ps1`
- Read: `scripts/test-legal-journey.ps1`
- Read: `scripts/audit-e2e-credentials.ps1`

**Interfaces:**
- Consumes: the running 0.2.32 stack
- Produces: exit 0 from the credential audit and the legal journey; the smoke result

- [x] **Step 1: Check credential VALIDITY, not presence**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts\audit-e2e-credentials.ps1
```

Exit 2 (`CANNOT CHECK`) means the stack is down - that is a normal skip on a dev box and **not** a pass. Exit 1 means a credential the lane depends on is genuinely invalid: fix it with `scripts/set-connector-key.ps1` for a connector key, or re-provision the app credential.

- [x] **Step 2: Run the full-stack smoke**

```powershell
pwsh -NoProfile -File scripts/smoke-full-stack.ps1
```

Expected: exit 0. Note any lane it reports as skipped, and why - a skipped lane is not a verified lane.

- [x] **Step 3: Run the legal journey**

```powershell
pwsh -NoProfile -File scripts\test-legal-journey.ps1
```

This is the end-to-end evidence: matter -> upload -> OCR -> sanitize -> review -> search -> qm -> recall. It now also names the failing step when it dies (`275037b`), so a failure is actionable rather than a bare trace.

- [x] **Step 4: Confirm cross-stack credentials still agree**

```powershell
pwsh -NoProfile -File scripts\test-cross-stack-credentials.ps1
```

Expected: exit 0, or exit 2 if one of the two `.env` files is absent (normal on a fresh clone). This answers "do the two env files AGREE", which is a different question from Step 1's "is each credential VALID".

- [x] **Step 5: Run the whole gate suite once**

```powershell
pwsh -NoProfile -File scripts/run-all-checks.ps1
```

Expected: no exit 1. Exit 2 entries are CANNOT CHECK and need to be listed explicitly in the outcome, not waved through. This is the slowest step; give it 20+ minutes.

- [x] **Step 6: Commit nothing**

---

## Task 7: Record the outcome and the rollback

**Files:**
- Modify: `docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md` (this file)

**Interfaces:**
- Consumes: the gate results from Tasks 4-6
- Produces: a plan an auditor can read without re-running anything

- [x] **Step 1: Append a measured outcome section**

Add a `## Outcome` section recording, with real numbers: the coherence gate's pass/fail count, the PDF gate's before and after, the recursion gate result, the smoke/legal/credential/suite results, and any lane left CANNOT CHECK with its reason. Mark the checkboxes above that actually ran. Do not record an unrun gate as passed.

- [x] **Step 2: State the rollback explicitly**

```powershell
# Runtime: one command back to 0.2.30, images still local
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.local-model-override.yaml `
    up -d --force-recreate pacgate-api deer-flow deer-flow-frontend pacgate-mcp ocr-service

# History: fd23be0 is a merge; the pre-merge tip is on its own branch
git log --oneline -1 backup/pre-sync-2026-11-08
```

- No migrations were added between 0.2.30 and 0.2.32, so the rollback needs no SQL. Record that fact, because it is the reason the rollback is cheap.
- [x] **Step 3: Commit the outcome**

```powershell
git add docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md
git commit -m "docs(plan): record the measured outcome of the 0.2.32 runtime upgrade"
```

---

## Outcome

Measured on this box on 2026-11-08, after the work in this plan. Every row is a command that was
actually run; nothing here is inferred from a neighbouring green result.

### History

| Claim | Result |
|---|---|
| Merge adopted | `fd23be0` - `main` went from `ahead 9, behind 8` to `ahead 12, behind 0` |
| Conflict count | 1 (`deploy/client-bundle/.env.example`), documentation-only, both sides kept |
| Pre-merge backup | branch `backup/pre-sync-2026-11-08` -> `969e0be` |
| Tree version | `pacgate-ai/Cargo.toml` -> `0.2.32` |
| Release provenance | `test-release-provenance.ps1` -> **PASSED**: `v0.2.32` identifies the `7a6dd732c6df` artifacts clients pull |
| Local fixes preserved | bounded `for attempt in range(2)` retry present (1 match); `audit-e2e-credentials`, `test-pdf-outline-extraction`, `test-firecrawl-wiring` all still registered in `run-all-checks.ps1` |

### Runtime

| Gate | Before | After |
|---|---|---|
| `test-stack-version-coherence.ps1` | **9 passed, 5 failed** - all five running `:0.2.30` | **14 passed, exit 0** - all five on `:0.2.32` |
| `test-pdf-outline-extraction.ps1` | **2 passed, 5 failed** - `ModuleNotFoundError: pymupdf4llm`, `headings=0 outline=0`, 7 control failures | **7 passed, all green** - `pymupdf 2.1`, `headings=54 outline=51` |
| `test-run-recursion-cap.ps1` | (not runnable meaningfully before - the floor did not exist) | **43 passed, 0 failed** |
| `audit-recursion-regressions.ps1` | - | `fix EVIDENCED - no caller-budget regression, and 6 run(s) delivered files` |
| `audit-deer-flow-patches.ps1` | - | `OK: every patched upstream path still exists at the target` |
| `audit-e2e-credentials.ps1` | - | `6 passed, 4 warning(s)`, exit 0 - every required credential VALID (connector keys absent by design) |
| `test-cross-stack-credentials.ps1` | - | `every shared credential agrees across both stacks`, 0 warnings |
| `smoke-full-stack.ps1` | - | `passed: 20 failed: 0 skipped: 1` - every reachable lane passed |
| `test-legal-journey.ps1` | - | `19 assertions passed`, `full legal journey PASSED, all lanes verified` |
| `test-agent-mcp-e2e.ps1` | **7 passed, 1 failed** (E3) | **9 passed, 0 failed** - `called: pacgate_pacgate_list_connectors` |
| `test-qm-currentness.ps1` | **exit 1** - 3 staged definition files behind | **exit 0** - `30 file(s) identical`, `qm is current` |
| **`run-all-checks.ps1`** | - | **`ALL 67 GATES PASSED`**, exit 0 (18 live-stack gates checked separately) |

Images: all five pulled anonymously and their local `RepoDigests` match the registry -
`pacgate-api 6273177`, `pacgate-mcp cb33113`, `ocr-service 419a5e4`, `deer-flow-pacgate 7019a03`,
`deer-flow-frontend-pacgate ff70b1d`. `report-ghcr-digests.ps1 -Version 0.2.32` -> "All 5 images
pullable anonymously", with `:latest` in sync.

### Two defects found while executing this plan

**1. `test-agent-mcp-e2e.ps1` E3 could never pass.** deer-flow records MCP calls as
`<serverName>_<toolName>`, so the real name is the doubled `pacgate_pacgate_list_connectors`, while
E3 matched against bare names derived from `server.py`. The tool loop was working the whole time -
deer-flow's log showed the tool auto-promoting and pacgate-mcp answering 200 - and the gate's FAIL
message asserted the opposite in the same words a real regression would use. Fixed and
red-checked both ways: `8 passed, 1 failed` with the qualified names excluded, `9 passed, 0 failed`
when restored. Recorded in `deploy/DEFECT-agent-mcp-gate-name-qualification.md`.

**2. The running qm container still had the pre-fix Firecrawl bug.** `test-qm-currentness.ps1`
went red because the merge changed three `deploy/qm-pacgate` files that `-Update` never re-stages.
This was not cosmetic: `docker exec qm-pacgate-core grep markdown /layer/tools/.../firecrawl_qm.py`
showed the old `result.get("markdown", "")` on line 70 - the exact defect that makes
`firecrawl-qm scrape <url>` print NOTHING and exit 0, which an agent then reads as "this page has no
content". After re-staging, the same probe shows `md = data.get("markdown") or ""` at line 108.

Because `sandbox/tools` and `sandbox/skills` are **bind-mounted** into `qm-pacgate-core`, refreshing
the staged files applied the fix live with **no restart**, so the stack was not bounced while
anyone could be working. The three refreshed files are gitignored machine-local state, so nothing
was committed for this.

### Assumptions made, and why

- **MID tier moved to `nemotron-3.5-bolt:e4b-q8_0`.** Decided on measurement, not on upstream's
  comment: residency here is size-one (loading e4b evicted a resident 74B, and loading ornith
  evicted a resident e4b), and e4b measured 1274 tok/s prefill / 34-59 decode against ornith's
  992 / 34. Upstream records the opposite prefill ordering, so its trade-off does not reproduce
  here. Full reasoning in `docs/superpowers/decisions/2026-11-08-local-model-posture.md`.
- **`deer-flow-config.local.yaml` was regenerated rather than edited.** The naive
  `^  #   ` uncomment rule also matches the retired `qwen3.8-27b-local` block; the plan's bounded
  loop was used instead, and the result is asserted to contain exactly one extra active entry.
- **Main was not pushed.** `main` is 12 ahead of `origin/main`. Publishing is a maintainer
  decision, and `fork` shares no history with `origin` at all, so it is a separate operation.

### Left undone, deliberately

| Thing | Why |
|---|---|
| `test-baked-patch-parity.ps1` B4 | `[skip] CANNOT CHECK: ghcr.io/jzkk720/deer-flow-pacgate:0.2.8 is not present locally` - a historical drift report against a 0.2.8 image this box never pulled. Exit 2 is not a pass, and it is not a failure either. |
| `preflight-docker-egress.ps1` | `CANNOT CHECK - no probe image`. |
| The 13 untracked files | The LOCAL-FIRST legal AI stack reference, its diagrams and renderers. Verified to carry no secret-shaped content and to collide with nothing upstream. Unrelated to this upgrade. |
| `laya-serve:0.2.32` | Behind the `laya` profile; not running; nothing in this box's lanes uses it. |
| Pruning the `:0.2.30` images | Keeps the rollback cheap. |

### Rollback

```powershell
# Runtime: one command back to 0.2.30, those images are still local
docker compose -f deploy/client-bundle/compose.prod.yaml -f deploy/client-bundle/compose.local-model-override.yaml `
    up -d --force-recreate pacgate-api deer-flow deer-flow-frontend pacgate-mcp ocr-service

# History: fd23be0 is a merge; the pre-merge tip is on its own branch
git log --oneline -1 backup/pre-sync-2026-11-08
```

No DB migrations were added between 0.2.30 and 0.2.32 - `pacgate-ai/migrations/` is byte-identical
at both refs and stops at `009_cjk_fulltext.sql` - so the rollback needs no SQL. That is why it is
cheap.

### One environment note worth keeping

The first anonymous-registry probes failed with `http 0` / `WinError 10061`. That was **not** a
publish or network-to-GHCR fault: `HTTP_PROXY` and `HTTPS_PROXY` were set to `http://127.0.0.1:7890`
and nothing was listening on that port. With the proxy variables cleared, the same probes returned
`token http 200` and all five digests. If a registry check returns `http 0` on this box, clear the
proxy variables before concluding anything about the release.


| Thing | Why not here |
|---|---|
| Rebuilding any image | All six are published, anonymous-pullable, and two were pulled successfully; a local build would create a tag that disagrees with the registry digest |
| Running `install.ps1 -Update` | It is the *client* path. The compose recreate is narrower and reversible. The installer's behaviour on a fresh clone is a separate verification and this box cannot test it |
| `git reset --hard` anywhere | The repository's own plans record that this destroyed a fix on 2026-11-01 |
| Pulling `laya-serve:0.2.32` or starting the `laya` profile | It is behind the `laya` profile, is not running today, and nothing in this box's lanes depends on it |
| Pruning the 0.2.30 images | Keeps the rollback cheap until Task 6 is green |
| Pushing `main` to `origin` or `fork` | `main` is now 10 ahead of `origin/main`. Whether the local-only commits get published is a maintainer decision, not an upgrade step - and `fork` shares no history with `origin` at all, so it is a separate operation |
| Committing the 13 untracked files | They are the LOCAL-FIRST legal AI stack reference plus its diagrams and renderers. Unrelated to this upgrade; verified to carry no secret-shaped content and to collide with nothing upstream |
| Fixing `gemma4:12b-it-qat` showing as resident | It is retired from the roster but still pulled on this box. Harmless while nothing routes to it; cleaning it up is hygiene, not this upgrade |

