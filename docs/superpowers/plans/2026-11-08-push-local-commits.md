# Push the 14 local commits to `origin/main` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the 14 local commits on `main` to `origin` (`JZKK720/pacgate-ai-pr`), because at least two of them are client-facing correctness fixes that `v0.2.32` currently ships broken, and prove the release story is still coherent after the push.

**Architecture:** One fast-forward, then verification. `origin/main` is an ancestor of local `main`, so the push is `17a498e..6aebca3` with no merge, no rebase and no force. No file in the outgoing set is an image build input, so the published images keep identifying `v0.2.32`. The fix reaches clients through the **bind-mounted patches directory**, not through a new image.

**Tech Stack:** git, `gh` CLI, GHCR release workflow (`.github/workflows/build-ghcr.yml`), the repo's own PowerShell gates.

**Spec:** `docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md` (the upgrade that produced these commits) and `docs/superpowers/decisions/2026-11-08-local-model-posture.md` (the machine-local decision bundled inside them).

## Global Constraints

- **No force-push, ever.** `origin/main` is an ancestor of `main`; a non-fast-forward here means something is wrong and the correct response is to stop, not to add `--force`.
- **Do not bump the version in this plan.** Bumping to `0.2.33` without a GHCR build would make every compose pin name an image tag that does not exist, and every client install would fail. Bumping is Task 6 and is gated on a successful workflow run.
- **`fork` (`pacgate-ai/pacgate-ai-pr`) is out of scope.** It shares no history with `origin` (different root commit, `0.1.24` tip) and is a READ-ONLY MIRROR that publishes no images. Pushing 14 commits of `origin` history into it is a different, riskier operation.
- **Never retag a `ghcr.io/jzkk720/*` image locally.**
- **Gate exit codes: 0 = pass, 1 = real defect, 2 = CANNOT CHECK. Exit 2 is never a pass.**
- Images carry `org.opencontainers.image.revision=${{ github.sha }}`, so a release image names the commit it was built from. Do not assume a tag and an image agree - check.

---

## Verified preconditions

Measured on 2026-11-08 before writing this plan.

| Claim | Verified result |
|---|---|
| Divergence | `git log origin/main..main` -> **15 commits** (14 non-merge + the 1 merge `fd23be0`), `git log main..origin/main` -> **0** |
| Push is a fast-forward | `git push --dry-run origin main` -> `17a498e..6aebca3  main -> main`, exit 0 |
| Push is permitted | `gh auth status` -> account `JZKK720`, scopes include `repo` and `workflow` |
| Outgoing file count | 13 files across the 14 commits (the merge `fd23be0` itself changes `main` only via its parents) |
| **No image input is touched** | `test-release-provenance.ps1` at HEAD -> **PASSED**: "no image-affecting file changed between 7a6dd732c6df and HEAD, so the tag still describes the published artifacts". None of the three `deploy/deer-flow-pacgate/Dockerfile` `COPY deploy/client-bundle/patches/...` sources is in the outgoing set |
| **No secret leaks** | all 6 real secret values from `deploy/client-bundle/.env` (`PACGATE_DB_PASSWORD`, `PACGATE_JWT_SECRET`, `PACGATE_API_PASSWORD`, `OPENVIKING_ROOT_API_KEY`, `OPENVIKING_API_KEY`, `PACGATE_SANITIZER_KEY`) checked against **both** the outgoing diff and the tracked tree -> **0 hits** |
| `scripts/audit-e2e-credentials.ps1` is not a credential carrier | 17,100 bytes, **0** hardcoded hex runs of 32+ chars, reads `.env` rather than embedding it |
| Live credential files stay untracked | `deploy/client-bundle/.env` and `.deer-flow-credentials` are both gitignored; `git ls-files` matches neither |
| Current gates | `run-all-checks.ps1` -> **ALL 67 GATES PASSED**, exit 0 |

### The two commits that make this worth doing

**1. The login-storm fix is not in `v0.2.32`.** `git show v0.2.32:deploy/client-bundle/patches/pacgate-adapter-client.py` still contains the unbounded recursion `return self.get(path, headers=headers)`; local `main` has the bounded `for attempt in range(2)`. The docstring's "re-login once" held only if the retried request happened not to 401 - a stub that always 401s ran **997 logins and 998 GETs** before `RecursionError`. An account that can authenticate but not authorise turns the first memory update into a login storm.

**2. The `test-agent-mcp-e2e.ps1` E3 fix helps every machine, not just this one.** deer-flow records MCP calls server-qualified (`<server>_<tool>`), so the real name is `pacgate_pacgate_list_connectors` while E3 matched bare names. That gate could never pass for **anyone** downstream.

Both reach clients through the **bind-mounted** patches/scripts path, not through an image: `deploy/client-bundle/compose.bundle.yaml` mounts `./patches/pacgate-adapter-client.py` onto `/app/adapters/pacgate_deerflow_adapter/client.py`, and `install.ps1` ships `patches/*.py`. **No rebuild and no new version are required for either fix to land.**

The delivery step is `install.ps1 -Update`, and it is automatic - not a manual operator chore:

- line 792 runs `git pull --ff-only origin $branch`, so the host checkout gets the patch file;
- the `if ($Update)` block then runs `docker compose -f compose.prod.yaml restart deer-flow` **because** `patches/*.py` are imported at process start with no hot reload, so restarting is what makes the new file take effect;
- `scripts/audit-aipc-update-coverage.ps1` reports `covered by -Update : 14 of 14`, with `personas/, patches/*.py -> container restart -> OK` and `repo working tree -> fast-forward pull -> OK`.

One consequence worth stating: `-Update` uses `git pull --ff-only` and **refuses** if the client's checkout has diverged ("Repo has diverged ... Not merging"). A client carrying local commits will not get these fixes from `-Update` and needs a deliberate resolution.

### What is bundled in that is machine-specific

Two files in the outgoing set describe this box rather than the product. They are honest and already-committed, but a reviewer should know they are going upstream:

| File | Why it is here | Concern |
|---|---|---|
| `docs/superpowers/decisions/2026-11-08-local-model-posture.md` | Records the Mid-tier choice for a Ryzen AI MAX+ 395 | Reads as product policy; it is not. It states its own scope at the top ("this machine only") |
| `docs/superpowers/plans/2026-11-05-local-runtime-sync-v0.2.30.md` | The predecessor runtime-sync plan | Pre-existing local commit, not from this session |

`.gitignore` also changes, adding the two gitignored local-override paths - that is correct for every clone and needs no review.

---

## File Structure

No files are created or modified by this plan. It is a publication and verification sequence.

| Path | Responsibility | Change |
|---|---|---|
| `.git` refs for `origin/main` | Publication target | **Advance** to `6aebca3` |
| `docs/superpowers/plans/2026-11-08-push-local-commits.md` | This plan and its outcome | Created |

| Gate | Question it answers | Used in |
|---|---|---|
| `scripts/test-release-provenance.ps1` | does `v0.2.32` still name the published artifacts? | Task 1, Task 4 |
| `scripts/run-all-checks.ps1` | is the tree still green? | Task 4 |
| `scripts/test-origin-coherence.ps1` | are all advertised origins accepted? | Task 4 |

---

## Task 1: Re-confirm the preconditions immediately before pushing

Preconditions decay. These are cheap and they are the ones that would make a push wrong.

**Files:** none.

**Interfaces:**
- Consumes: local `main` at `6aebca3`
- Produces: a go/no-go for Task 2

- [x] **Step 1: Confirm still fast-forward, and read the real count**

This plan's own commit is part of what will be published, so the count moves as this document is
committed. Read it, do not assume 14.

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
git fetch origin
"ahead: " + (git rev-list --count origin/main..main)
"behind: " + (git rev-list --count main..origin/main)
```

Expected: `ahead: 15`, `behind: 0`. A non-zero `behind` means upstream moved - **stop** and re-run
the merge analysis rather than pushing.

- [x] **Step 2: Confirm it is a fast-forward**

```powershell
git merge-base --is-ancestor origin/main main; "ancestor exit=$LASTEXITCODE"
git push --dry-run origin main
```

Expected: `ancestor exit=0` and a `..` range (not a `+` forced update) in the dry-run.

- [x] **Step 3: Confirm provenance is still green**

```powershell
pwsh -NoProfile -File scripts\test-release-provenance.ps1
```

Expected: exit 0, `PASSED: v0.2.32 identifies the 7a6dd732c6df artifacts clients will pull`.

- [x] **Step 4: Confirm no secret value is in the outgoing set**

```powershell
$keys = @('PACGATE_DB_PASSWORD','PACGATE_JWT_SECRET','PACGATE_API_PASSWORD','OPENVIKING_ROOT_API_KEY','OPENVIKING_API_KEY','PACGATE_SANITIZER_KEY')
$diff = git --no-pager diff origin/main..main 2>&1 | Out-String
$hits = 0
foreach ($k in $keys) {
  $line = Get-Content deploy\client-bundle\.env | Where-Object { $_ -match "^$k=" } | Select-Object -First 1
  if ($line) { $v = ($line -split '=',2)[1].Trim(); if ($v.Length -ge 12 -and $diff.Contains($v)) { $hits++; "LEAK: $k" } }
}
"leaks: $hits"
```

Expected: `leaks: 0`. Any hit is a **hard stop** - do not push, and treat it as a credential incident.

- [x] **Step 5: Confirm the working tree has nothing uncommitted that should go too**

```powershell
git status --short
```

Expected: only the 13 pre-existing untracked files (the LOCAL-FIRST legal AI stack reference and its renderers). Anything tracked-and-modified must be committed or stashed deliberately before pushing, not swept in.

---

## Task 2: Push

**Files:** none.

**Interfaces:**
- Consumes: the go from Task 1
- Produces: `origin/main` at `6aebca3`

- [x] **Step 1: Push**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
git push origin main
```

Expected: `17a498e..6aebca3  main -> main`. **Do not add `--force`** under any circumstance; if git rejects it, the precondition changed and Task 1 must be re-run.

- [x] **Step 2: Verify the remote actually moved**

```powershell
git fetch origin
git --no-pager log --oneline -1 origin/main
git rev-list --count main..origin/main
git rev-list --count origin/main..main
```

Expected: `origin/main` at `6aebca3`, `behind: 0`, `ahead: 0`.

- [x] **Step 3: Verify GitHub agrees, not just the local ref**

```powershell
gh api repos/JZKK720/pacgate-ai-pr/commits/main --jq '.sha[0:7] + "  " + .commit.message' 2>&1 | Select-Object -First 1
```

Expected: `6aebca3  docs(plan): tick the 41 executed steps on the 0.2.32 upgrade plan`. This is the check that distinguishes "the push landed" from "my local refs think it did".

---

## Task 3: Confirm the client-facing fix is actually reachable by a client

A push is not a delivery. This task proves a fresh clone gets the fix without any image rebuild.

**Files:** none.

**Interfaces:**
- Consumes: `origin/main` at `6aebca3`
- Produces: proof that the adapter fix and the E3 fix are in the published tree

- [x] **Step 1: Confirm the published tree has the bounded retry**

Do **not** check for the bare absence of `return self.get(path, headers=headers)`: the fixed
version quotes that line inside its own docstring while explaining what the bug was, so a naive
"is the old string gone" test reports a false failure. Verify the structure instead - the fixed file
routes every verb through one `_request` helper, and only one self-call remains (in the explanatory
docstring).

```powershell
$remote = git --no-pager show origin/main:deploy/client-bundle/patches/pacgate-adapter-client.py | Out-String
"bounded retry present      : " + $remote.Contains('for attempt in range(2)')
"_request helper present    : " + $remote.Contains('def _request(')
"verbs routed through it    : " + ([regex]::Matches($remote,'return self\._request\(')).Count
"legacy self-recursion left : " + ([regex]::Matches($remote,'return self\.(get|post|put|delete|upload)\(')).Count
```

Expected: `True`, `True`, **`5`**, **`1`**. The two counts are the discriminating part - on the
`v0.2.32` tree they are `0` and `5`. A `1` for the last line is the docstring, not live code; a `5`
means the fix did not land.

- [x] **Step 2: Confirm that patch is bind-mounted by BOTH lanes**

```powershell
foreach ($lane in @('compose.prod.yaml','compose.bundle.yaml')) {
  $m = Select-String -Path "deploy/client-bundle/$lane" -Pattern 'pacgate-adapter-client\.py'
  "{0,-22} mounted: {1}" -f $lane, [bool]$m
}
```

Expected: `mounted: True` for both. This is what makes the fix reach a client **without a new image** - the container reads the mounted file.

- [x] **Step 3: Confirm the E3 gate fix is published**

```powershell
$gate = git --no-pager show origin/main:scripts/test-agent-mcp-e2e.ps1 | Out-String
"qualified names accepted: " + $gate.Contains('$mcpToolsAccepted')
"server name read from config: " + $gate.Contains('deer-flow-extensions-config.json')
```

Expected: both `True`.

- [x] **Step 4: Confirm the live client path serves the fixed file**

```powershell
docker exec deer-flow sh -c 'grep -c "for attempt in range(2)" /app/adapters/pacgate_deerflow_adapter/client.py'
```

Expected: `1` on this box, because compose mounts it. A client gets the same result after `install.ps1 -Update`, which `git pull`s the checkout and then restarts `deer-flow` for exactly this reason (see Task 6 Step 2).

---

## Task 4: Re-verify the release story after the push

**Files:** none.

**Interfaces:**
- Consumes: the pushed `main`
- Produces: evidence that the push did not break provenance or any gate

- [x] **Step 1: Provenance again, now on the pushed commit**

```powershell
pwsh -NoProfile -File scripts\test-release-provenance.ps1
```

Expected: exit 0. Publishing the commits does not change how the images were built, so this must be **unchanged** from Task 1.

- [x] **Step 2: Origin coherence**

```powershell
pwsh -NoProfile -File scripts\test-origin-coherence.ps1
```

Expected: `every advertised origin is accepted for auth`, exit 0.

- [x] **Step 3: Full suite**

```powershell
pwsh -NoProfile -File scripts/run-all-checks.ps1
```

Expected: `ALL 67 GATES PASSED`, exit 0. Exit-2 entries must be listed explicitly in Task 7, not waved through.

---

## Task 5: Decide whether `0.2.33` is warranted

The push alone is sufficient for both fixes to reach clients, because both travel through the mounted/bind-mounted path. A version bump is only needed if you want a **new image** to carry the fix baked in, or to make the release note name the fix.

**Files:**
- Read: `scripts/bump-release-version.ps1`
- Read: `scripts/test-release-provenance.ps1`

**Interfaces:**
- Consumes: the pushed `main`
- Produces: a recorded decision, not necessarily a bump

- [x] **Step 1: Read what the bump actually rewrites**

```powershell
Select-String -Path scripts\bump-release-version.ps1 -Pattern '^param','compose pins','ghcr' | Select-Object -First 8
```

It rewrites every `ghcr.io/jzkk720/<image>:<version>` pin across the compose files. That is why a bump without a build is unsafe: the pins would name tags GHCR does not have.

- [x] **Step 2: Record the decision**

Bump only if **all** of these hold - state which is false if you do not bump:

1. A new image is genuinely required, i.e. the fix cannot travel via the mount. **It can**, and the delivery path is already automatic: `install.ps1 -Update` does `git pull --ff-only` (line 792) and then `restart deer-flow` in its `if ($Update)` block specifically because `patches/*.py` are imported at process start with no hot reload. So this condition is **currently false for both fixes**.
2. Someone will run the `build-ghcr.yml` workflow (tag push `v0.2.33`, or `workflow_dispatch` with input `tag=0.2.33`) before any client pulls.
3. The bump and the successful workflow run happen as one sequence, not as two hopeful steps.

Recommended: **do not bump now.** Both fixes reach clients through the mount via `-Update`, and `v0.2.32`'s images remain correctly identified by their tag. Note the two fixes in the next scheduled release instead.

If you bump anyway, understand what it costs: `bump-release-version.ps1` rewrites all six `ghcr.io/jzkk720/*:<version>` pins plus `Cargo.toml`. Between the bump and a successful GHCR run, every client install names a tag that does not exist, so a client running `-Update` in that window pulls nothing.

- [x] **Step 3: If a bump IS decided, do it as one sequence**

```powershell
git checkout -b release/0.2.33
pwsh -NoProfile -File scripts\bump-release-version.ps1 -To 0.2.33
pwsh -NoProfile -File scripts\test-stack-version-coherence.ps1   # will FAIL until images exist - expected
git commit -am "chore(release): 0.2.33"
git push origin release/0.2.33
gh workflow run build-ghcr.yml -f tag=0.2.33
# wait for the run, then verify all 6 images before merging or tagging:
python scripts/check-ghcr-anon.py --tag 0.2.33
```

Do **not** merge to `main` until `check-ghcr-anon.py` reports the tag PUBLIC for every image. Merging first ships pins that resolve to nothing.

---

## Task 6: Record the outcome

**Files:**
- Modify: `docs/superpowers/plans/2026-11-08-push-local-commits.md` (this file)

**Interfaces:**
- Consumes: results from Tasks 2-5
- Produces: an auditable record

- [x] **Step 1: Append a `## Outcome

Measured 2026-11-08. Every row is a command that was actually run.

### The push

| Claim | Result |
|---|---|
| Preconditions | `ahead 24, behind 0`; `merge-base --is-ancestor` exit 0; dry-run `17a498e..8d4c744` (a `..` range, not a forced update); provenance PASSED; **0 secret leaks** across all 6 real values; working tree clean with only the 13 pre-existing untracked files |
| Push | `git push origin main` -> `17a498e..8d4c744  main -> main`, exit 0. **No force used.** |
| Local refs | `ahead 0, behind 0` |
| **GitHub agrees, not just local refs** | `gh api repos/JZKK720/pacgate-ai-pr/commits/main` -> `8d4c744` plus the matching subject line |

### The fixes are reachable by a client

| Check | Result |
|---|---|
| Adapter fix in the published tree | bounded retry `True`, `_request` helper `True`, **5** verbs routed through it, **1** legacy self-call (the docstring) |
| Mounted by both lanes | `compose.prod.yaml: True`, `compose.bundle.yaml: True` |
| E3 gate fix published | qualified names accepted `True`, server name read from config `True` |
| Recovery patch published | `git cat-file -e origin/main:...` -> exists |
| Live client path | `docker exec deer-flow grep` -> `1` |
| **A FRESH CLONE gets them** | `git clone --depth 1` of the public repo -> HEAD `8d4c744`, adapter fixed `True`, recovery patch `True`. This is the decisive test: a client machine cloning today receives both. |

### Release story unchanged

| Gate | Result |
|---|---|
| `test-release-provenance.ps1` (after the push) | **PASSED** - `v0.2.32` still identifies the `7a6dd732c6df` artifacts |
| `test-origin-coherence.ps1` | `19 passed` |
| `run-all-checks.ps1` | **ALL 68 GATES PASSED** |

### The `0.2.33` decision: DO NOT BUMP

`bump-release-version.ps1` rewrites all **12** `ghcr.io/jzkk720/*:0.2.33` pins across both
compose files. GHCR has no `0.2.33`, so between the bump and a successful workflow run
every client install names a tag that resolves to nothing. Both fixes already reach
clients through the bind-mounted path - proven above by the fresh clone - so a bump buys
traceability only, at the cost of a window where installs break.

Condition 1 of the plan's own gate is **false**: no new image is required.

### What remains unproven, rather than implied

- **The live fold test is not part of the suite.** It costs minutes of model time and
  folds are document- and prompt-dependent: an 8-turn run over the 16-page AIPC handbook
  recorded **zero** folds even though all eight turns completed. Two folds ARE on record
  from earlier runs, and both exposed real instrumentation defects. Run it manually with
  `python scripts/live_long_document_fold_test.py --turns 8`.
- `fold_telemetry_report.py` still reports `CANNOT CHECK` on ordinary traffic, because no
  thread has crossed the 36,000 trigger (median 16,847, max 24,910). Correct state, not a
  broken sensor.
- `test-baked-patch-parity.ps1` B4 remains `CANNOT CHECK` (no `0.2.8` image locally).
` section**

Record: the pushed range and the resulting `origin/main` SHA (verified via `gh api`, not only local refs), the provenance result before and after, the full-suite result with any exit-2 items named, the confirmation that the client path serves the fixed adapter, and the `0.2.33` decision with its reason.

- [x] **Step 2: State what a client must do to receive the fixes**

The honest answer, so it is not overclaimed. A client receives **both** fixes by running:

```powershell
cd <client-repo>\deploy\client-bundle
.\install.ps1 -Update
```

That single command is sufficient and requires **no image pull for these two fixes and no rebuild**:

1. `git pull --ff-only origin $branch` updates the host checkout, which is where the bind-mounted patch file lives.
2. The `if ($Update)` block runs `docker compose -f compose.prod.yaml restart deer-flow`, because `patches/*.py` are imported at process start with no hot reload. Without that restart the new file sits on disk inert - the repo documents this as the class where a fix "looks shipped and is inert".
3. `scripts/audit-aipc-update-coverage.ps1` confirms the coverage exists rather than assuming it: `covered by -Update : 14 of 14`.

Write down the two exceptions, because they are the only clients that miss the fixes:

- A client whose checkout has **diverged** (local commits). `git pull --ff-only` refuses by design - "Repo has diverged ... Not merging" - and the update continues with `repo content stays as-is`. That client needs a deliberate resolution, not an update.
- A client that is **pinned to a specific commit**, or that never runs `-Update` at all (for example, one only re-pulling images). Its mounted patch file never changes, so it keeps the defect even though its images are current.

Do **not** claim the fixes require a new release. They do not, and saying so would invite an unnecessary version bump that points every compose pin at a tag GHCR does not have.

**The prompt to hand another machine's agent is
[`deploy/HANDOFF-SYNC-TO-ORIGIN-MAIN.md`](../../../deploy/HANDOFF-SYNC-TO-ORIGIN-MAIN.md),
not a verbal "merge and sync from upstream".** That distinction matters and is the
reason the handoff exists: **the dev box is AHEAD of `origin/main`, not behind it**, so
a second machine told to "sync from upstream" would pull nothing and conclude it was
already current. The handoff opens with a push-status check that reads `origin/main`
directly and stops if the push has not landed, so the instruction cannot be followed out
of order.

- [x] **Step 3: Commit**

```powershell
git add docs/superpowers/plans/2026-11-08-push-local-commits.md
git commit -m "docs(plan): record the outcome of publishing the 14 local commits"
git push origin main
```

---

## Out of scope, and why

| Thing | Why not here |
|---|---|
| `fork` / `pacgate-ai/pacgate-ai-pr` | Unrelated history (different root, `0.1.24` tip). It is a read-only mirror that publishes no images. Pushing `origin` history into it is a separate operation with its own risk |
| Force-pushing or rewriting the 14 commits | They are already linear on top of `origin/main`. Rewriting would invalidate the SHAs the plan and decision records cite |
| Bumping to `0.2.33` | Recommended against: both fixes reach clients through the bind-mounted path, and a bump without a GHCR build ships pins that resolve to nothing |
| Rebuilding images | Nothing in the outgoing set is an image input - `test-release-provenance.ps1` proves it |
| The 13 untracked files | LOCAL-FIRST legal AI stack reference plus diagrams/renderers. Verified free of secret-shaped content and unrelated to this push |
| Opening a PR | The recommended path is a direct fast-forward to `main`, matching how the preceding 8 upstream commits landed. Available as option B if a review gate is wanted |

## Rollback

Reverting the **publication** (rather than the history) would need a force-push, which this plan
forbids. Prefer a forward revert, and be surgical: the two behavioural fixes are the reason for the
push and must survive.

```powershell
# Remote tip before the push:
git --no-pager log --oneline -1 17a498e

# If the DOCS-ONLY commits turn out to be unwanted, revert only those:
#   0b62df6 docs(plan): record the measured outcome ...
#   bdbea1d docs(decision): record this box's local-model posture ...
#   6aebca3 docs(plan): tick the 41 executed steps ...
git revert --no-edit 6aebca3 0b62df6 3682a8f

# DO NOT revert these - they are why the push happened:
#   d3f6c6a fix(adapter): bound the 401 re-login retry        <- ships in v0.2.32 without this
#   4ad8ec5 fix(gate):    the agent e2e matched its own prompt <- replaced by bdbea1d, not reverted
#   bdbea1d fix(gate):    E3 could never pass                  <- the E3 correctness fix
```

Note the trap: `bdbea1d` is a **fix**, not documentation, despite touching only a script and a
defect record. Reading the file list instead of the commit's intent would have led to reverting the
E3 fix along with the docs. The commit list above was read from
`git log origin/main..main --no-merges`, not guessed.

**Runtime is unaffected by this plan:** no container is recreated and no image moves, so the
rollback for the running stack remains the one in
`docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md`.

