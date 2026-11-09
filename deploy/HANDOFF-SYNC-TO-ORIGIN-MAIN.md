# Handoff Prompt - bring another machine up to 0.2.34

> **For:** an agent running on a second Pacgate machine (AIPC #1/#2, or the client lane).
> **Prerequisite:** the release is PUBLISHED. Read "Is the release real?" below before doing anything.
> **Source of truth:** `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` for the full install; this file is only the delta.

## The direction, stated precisely because it is easy to invert

**`v0.2.34` is published and tagged.** Unlike the previous delta, this one is NOT
"fixes that exist only on the dev box" - it is a normal release, and the images
changed.

| | state |
|---|---|
| `origin/main` | contains 0.2.34 |
| tag `v0.2.34` | annotated, points at `HEAD_PLACEHOLDER`, and that commit is what the images were built from |
| GHCR `0.2.34` | **all six images published**, anonymously pullable |

So this machine pulls from the registry like any other release. There is nothing to
reconcile and nothing waiting on a push.

## Is the release real?

Read the answer rather than assuming it:

```powershell
cd <repo>
git fetch origin --tags
git rev-parse 'v0.2.34^{commit}'      # expect HEAD_PLACEHOLDER...
# Tag FIRST (positional), then the images. `--tag 0.2.34 laya-serve` silently
# swallows laya-serve as the flag's value and checks only the default five.
python scripts/check-ghcr-anon.py 0.2.34 pacgate-api pacgate-mcp ocr-service `
    deer-flow-pacgate deer-flow-frontend-pacgate laya-serve
```

Six `PUBLIC` lines. The client path is an anonymous pull, since the install
deliberately needs no `docker login` - so a `PUBLIC` verdict here is exactly the
property that matters.

`scripts/test-release-provenance.ps1` is the stronger check: it reads each image's
`org.opencontainers.image.revision` label and refuses to bless the release unless every
published image came from the tagged commit.

## What is actually in 0.2.34

Four changes worth knowing. 43 commits since `v0.2.32`.

| # | Change | Verify with |
|---|---|---|
| 1 | **`kb_search` no longer presents unrelated neighbours as results.** pgvector returns the nearest chunks for ANY query, so a query sharing no term with the corpus used to come back looking like an answer. The API now suppresses a result set in which no chunk contains a query term, which is what makes the caller's `no_match` branch reachable. | `scripts/test-kb-search-empty-signal.ps1` - **6 of 6**, including the new E6 |
| 2 | **The KB ingester denies the two MCP authorization documents.** They hold a plaintext CourtListener token and five plaintext passwords and sit beside `OPERATOR.md`, which was already denied. Compiled into the image, so it needed a rebuild to take effect - which is why it is in this release and was not in 0.2.32. | the `pacgate-ai` unit test `the_credential_documents_are_denied` |
| 3 | **Boundary rules no longer overstate themselves.** `EnforcementPoint` was written on 35 rules and read nowhere. The prompt now separates rules enforced outside the model from self-check; one gate (citation verification against sanitised text) is genuinely built, and the other 15 report `not_implemented` instead of passing silently. | `cargo test -p pacgate-persona` |
| 4 | Carry-over bind-mounted fixes: bounded 401 re-login, fold-recovery index, context-pressure hint, fold telemetry | `scripts/test-summarization-recovery.ps1` - **22 of 22** |

## The images and the patches travel DIFFERENTLY

This is the part that changed since the last handoff. Read it before pulling.

| | What changed? | How it reaches you |
|---|---|---|
| **Images** (all six) | **YES** - `pacgate-api` and `pacgate-mcp` contain new code, and the tag is new | `docker compose -f compose.prod.yaml pull` **fetches real layers** |
| **Patches** (`patches/*.py`, `server.py`) | yes, and they are bind-mounted | `git pull` **plus a container restart** - a pull alone is inert |

**Verified 2026-11-09**, the digests GHCR serves for `0.2.34`:

| image | GHCR `0.2.34` |
|---|---|
| pacgate-api | `sha256:432550ac8840…` |
| pacgate-mcp | `sha256:deb5942bdd6f…` |
| ocr-service | `sha256:ebbb77186b71…` |
| deer-flow-pacgate | `sha256:7f0a46b74d57…` |
| deer-flow-frontend-pacgate | `sha256:6f6faf7fd2a3…` |
| laya-serve | `sha256:1542feb38b30…` |

The previous handoff said "no image pull at all" and that pulling would report
*"up to date"*. **That was true of the 0.2.32 delta and is false of this one.** An
operator who carries the old instruction forward will pull nothing and run old code
while every health check stays green.

## Bring this machine up

```powershell
cd <repo>
git rev-parse --abbrev-ref HEAD      # must print: main

cd deploy\client-bundle
.\install.ps1 -Update
```

That is the whole procedure. It does the three things that matter, and all are already
wired:

1. `docker compose -f compose.prod.yaml pull` - **transfers the new layers this time.**
2. `git pull --ff-only origin $branch` updates the checkout - which is where the
   bind-mounted patch files live. **This is the step that brings the patch fixes.**
3. The `if ($Update)` block runs `docker compose -f compose.prod.yaml restart deer-flow`,
   **because** `patches/*.py` are imported at process start with no hot reload. Without
   that restart the new files sit on disk inert - the repo documents this as the class
   where a fix "looks shipped and is inert".

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

The staged audit does all of this, in dependency order, and refuses to report a pass for
a stage it could not evaluate:

```powershell
pwsh -File scripts/audit-post-deploy.ps1
```

Run the individual checks by hand if you want to see each one:

```powershell
# 1. The patches are on disk (not just claimed)
Select-String deploy\client-bundle\patches\pacgate-adapter-client.py -Pattern 'for attempt in range\(2\)'

# 2. The patches are LIVE in the container - the check that catches "inert"
docker exec deer-flow sh -c 'grep -c "recoverable handles" /app/backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py'
docker exec deer-flow sh -c 'grep -c "for attempt in range(2)" /app/adapters/pacgate_deerflow_adapter/client.py'

# 3. Images are what the pins name (a MIXED STACK means a container never restarted)
pwsh -NoProfile -File scripts/test-stack-version-coherence.ps1

# 4. The structural gates
pwsh -NoProfile -File scripts/test-summarization-recovery.ps1   # expect 22 passed
pwsh -NoProfile -File scripts/test-kb-search-empty-signal.ps1    # expect 6 passed

# 5. The lanes actually work
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1            # expect 9 passed, 0 failed
pwsh -NoProfile -File scripts/audit-e2e-credentials.ps1         # exit 2 = CANNOT CHECK, not a pass
```

**Check 2 is the one that matters.** Checks 1 and 4 can pass while the running container
still serves the old code, because the patch is mounted and loaded at process start. If
either `docker exec` prints `0`, the restart did not take - re-run
`docker compose -f compose.prod.yaml restart deer-flow` and check again.

## Two things that will differ on another machine, and are not defects

- **`fold_telemetry_report.py` will say `CANNOT CHECK`.** Measured on the dev box: no
  thread has ever crossed the 36,000-token trigger, peak 24,910 (69%). Summarisation
  simply does not fire on ordinary traffic, so no telemetry exists. That is the correct
  answer, not a broken sensor.
- **`audit-recursion-regressions.ps1` may say `CANNOT CHECK`** for the same reason: no
  run has been deep enough to reach the wall since the fix.

Neither is a regression. A green result there would mean "the sensor works", not "the
feature works" - which is why the gate declines to claim it.
