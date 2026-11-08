# Handoff Prompt - bring another machine up to the post-0.2.32 fixes

> **For:** an agent running on a second Pacgate machine (AIPC #1/#2, or the client lane).
> **Prerequisite:** the dev box has ALREADY pushed. Read "Is the push done?" below before doing anything.
> **Source of truth:** `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` for the full install; this file is only the delta.

## The direction, stated precisely because it is easy to invert

| | commit | contains the fixes? |
|---|---|---|
| `origin/main` (JZKK720/pacgate-ai-pr) | whatever was last pushed | **only after the push lands** |
| the dev box's `main` | 23 commits ahead | yes, locally only |

The dev box is **ahead of** `origin/main`, not behind it. So:

- **Another machine cannot "sync from origin" to get these fixes until the dev box
  pushes.** Pulling early is safe but fetches nothing new.
- **Do not ask a second machine to reconcile or merge anything.** There is nothing on
  its side to reconcile; the work is on the dev box and has to travel outward.

## Is the push done?

Run this on the machine you are working from, and read the answer rather than assuming
it:

```powershell
cd <repo>
git fetch origin
git log --oneline -1 origin/main
# Does origin/main already contain the adapter fix?
git show origin/main:deploy/client-bundle/patches/pacgate-adapter-client.py |
    Select-String 'for attempt in range\(2\)'
```

- **No output** -> the push has NOT landed. Stop. The dev box must push first;
  nothing you do on this machine will bring the fixes across.
- **A match** -> the push has landed, and you can proceed to "Bring this machine up".

## What is coming (so you can verify it arrived, not just trust it)

Six things, all delivered through **bind-mounted files**, none through a new image:

| # | Change | Verify with |
|---|---|---|
| 1 | Bounded 401 re-login in the adapter (was unbounded recursion: 997 logins / 998 GETs before `RecursionError`) | the grep above |
| 2 | `test-agent-mcp-e2e.ps1` E3 accepts server-qualified MCP names (it could never pass before) | `9 passed, 0 failed` |
| 3 | Fold-recovery index: a summarised range keeps tool names, paths and headings | `scripts/test-summarization-recovery.ps1` |
| 4 | Context-pressure hint at 85% of the fold budget (advisory text, no tool schema) | `R12a`/`R12b` in that gate |
| 5 | Fold telemetry to `/data/deer-flow/data/pacgate-fold-telemetry.jsonl` | `scripts/fold_telemetry_report.py` |
| 6 | `scripts/calibrate_context_band.py` + `scripts/live_long_document_fold_test.py` | run them; both may legitimately report CANNOT CHECK |

**No version bump is needed and none is included.** `test-release-provenance.ps1`
confirms no image-affecting file changed, so `v0.2.32` still identifies the published
images. Do not bump pins to a tag GHCR has not built.

## Bring this machine up

```powershell
cd <repo>\deploy\client-bundle
.\install.ps1 -Update
```

That is the whole procedure. It does the two things that matter, and both are already
wired:

1. `git pull --ff-only origin $branch` updates the checkout - which is where the
   bind-mounted patch files live.
2. The `if ($Update)` block runs `docker compose -f compose.prod.yaml restart deer-flow`,
   **because** `patches/*.py` are imported at process start with no hot reload. Without
   that restart the new files sit on disk inert.

Verified coverage: `scripts/audit-aipc-update-coverage.ps1` -> `covered by -Update : 14
of 14`, with `personas/, patches/*.py -> container restart -> OK`.

## If `-Update` refuses to pull

It will, and it is supposed to, when the checkout has local commits:

```
[WARN] Repo has diverged from origin/<branch> - not fast-forwardable.
       Local commits exist that the remote does not have. Not merging.
```

That is a guard, not a failure. Diagnose before doing anything else:

```powershell
git fetch origin
git status -sb                      # read "ahead N, behind M" - do not guess
git log --oneline origin/main..HEAD # what this machine has that the remote does not
```

If `ahead` is 0, the machine did not diverge and the pull should not have refused -
investigate rather than forcing. If `ahead` is non-zero, this machine carries work that
must be preserved; a rebase or merge is a decision for a human, never a default.

**Do not run `git reset --hard`.** This repository's own plans record that doing so
destroyed a fix on 2026-11-01.

## Verify after the update, in this order

```powershell
# 1. The fixes are on disk (not just claimed)
Select-String deploy\client-bundle\patches\pacgate-adapter-client.py -Pattern 'for attempt in range\(2\)'
Test-Path deploy\client-bundle\patches\deer-flow-summarization-recovery.py

# 2. They are live in the container, not merely checked out
docker exec deer-flow sh -c 'grep -c "recoverable handles" /app/backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py'

# 3. The structural gate
pwsh -NoProfile -File scripts/test-summarization-recovery.ps1   # expect 22 passed

# 4. The lane actually works
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1            # expect 9 passed, 0 failed
pwsh -NoProfile -File scripts/audit-e2e-credentials.ps1         # exit 2 = CANNOT CHECK, not a pass
```

## Two things that will differ on another machine, and are not defects

- **`fold_telemetry_report.py` will say `CANNOT CHECK`.** Measured on the dev box: no
  thread has ever crossed the 36,000-token trigger, peak 24,910 (69%). Summarisation
  simply does not fire on ordinary traffic, so no telemetry exists. That is the correct
  state, not a broken sensor. `scripts/live_long_document_fold_test.py --turns 8` is how
  to force a real fold if you need to exercise it.
- **`calibrate_context_band.py` will print "0 of N reach the trigger"** and tell you not
  to lower the band. That is its intended output on a workload without long document
  runs.

## Do not do these

- **Do not clone the `pacgate-ai` fork.** It is a different history and serves the wrong
  workflow set silently. `origin` must be `JZKK720/pacgate-ai-pr`.
- **Do not `docker login ghcr.io`.** Images are public by design; the client install is
  done by our on-site engineer. A failed anonymous pull means visibility flipped or the
  tag does not exist - check with `python scripts/check-ghcr-anon.py <tag>`.
- **Do not copy `compose.local-model-override.yaml` or `deer-flow-config.local.yaml`
  from the dev box.** They are gitignored, machine-specific, and describe a Ryzen AI
  MAX+ 395 host with the 74B model. The shipped config is the client contract.
- **Do not "fix" the cloud chat models.** `deepseek-*-cloud` routing through ollama.com
  is the recorded 2026-08-30 decision.
