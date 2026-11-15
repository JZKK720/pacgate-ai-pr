# Handoff Prompt - bring another machine up to 0.2.35

> **For:** an agent running on a second Pacgate machine (AIPC #1/#2, or the client lane).
> **Prerequisite:** the release is PUBLISHED. Read "Is the release real?" below before doing anything.
> **Source of truth:** `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` for the full install; this file is only the delta.

## The direction, stated precisely because it is easy to invert

**`v0.2.35` is published and tagged, and it closes the gap the previous handoff described.**
Unlike the 0.2.34 delta, `origin/main` and the published images now agree, and the gate that
proves it passes.

| | state |
|---|---|
| `origin/main` | contains 0.2.35; the tag points INTO main, not past it |
| tag `v0.2.35` | annotated, peels to `2924798cb44a3dd66bf08d2ecfde8b78f351f872`, which is what the images were built from |
| GHCR `0.2.35` | **all six images published**, anonymously pullable, all labelled revision `2924798cb44a` |

`scripts/test-release-provenance.ps1` -> **exit 0**. That is the first time this gate has been
green since 0.2.33, and it is the objective evidence that tag, pin and artifact agree.

So this machine pulls from the registry like any other release. Nothing is waiting on a push,
and no fix is stranded outside a published image.

## Is the release real?

Read the answer rather than assuming it:

```powershell
cd <repo>
git fetch origin --tags
git rev-parse 'v0.2.35^{commit}'      # expect 2924798cb44a3dd66bf08d2ecfde8b78f351f872
# Tag FIRST (positional), then the images. `--tag 0.2.35 laya-serve` silently
# swallows laya-serve as the flag's value and checks only the default five.
python scripts/check-ghcr-anon.py 0.2.35 pacgate-api pacgate-mcp ocr-service `
    deer-flow-pacgate deer-flow-frontend-pacgate laya-serve
```

Six `PUBLIC` lines. The client path is an anonymous pull, since the install
deliberately needs no `docker login` - so a `PUBLIC` verdict here is exactly the
property that matters.

`scripts/test-release-provenance.ps1` is the stronger check: it reads each image's
`org.opencontainers.image.revision` label and refuses to bless the release unless every
published image came from the tagged commit. On 0.2.35 it reports **PASSED, exit 0** -
all six images on `2924798cb44a`, the tag peeling to that same commit, and nothing
image-affecting changed since.

## The gap 0.2.35 closes, kept here on purpose

Read this before you decide a green health check means a complete stack. The previous handoff
said it and was right about 0.2.34:

```
git merge-base --is-ancestor 9f0e0c8 v0.2.34   ->  false  (and false for v0.2.30..v0.2.34)
```

The redactor verdict fix `9f0e0c8` ("a model guess alone cannot block a document") reached
`main` on 2026-11-11, two days after `v0.2.34` was cut. It touches
`pacgate-ai/crates/pacgate-redact/src/{pipeline,verify}.rs`, which compile into `pacgate-api`,
so it could not travel by `git pull` or by a bind mount - only a new image could carry it.
For two releases the tag named artifacts that did not include it.

**`v0.2.35` contains it**, and the fix was verified on the live stack rather than inferred: a
document that had been `blocked` with 16 chunks on model-only evidence re-sanitized to
`verdict: pass` with `chunks_promoted: 15`, leaving the residue a reviewer still sees as public
bodies (欧盟法院, 北大) rather than client identity.

**That is why the re-sanitize step below is mandatory, not optional.** The verdict is computed
at sanitize time and stored, so a machine that pulls 0.2.35 keeps its old `blocked` rows until
each one is re-sanitized. The images are immutable; the verdicts already written are not
retroactively recomputed.

## What is actually in 0.2.35

One behavioural change, plus everything 0.2.34 already carried. Unlike the 0.2.34 delta, there
is no "fix that never shipped" left over.

| # | Change | Verify with |
|---|---|---|
| 1 | **The verifier no longer treats a model guess as proof of residue.** A `MatchSource::Model` span was decisive on its own, and because `verify()` re-runs detectors over the REDACTED text, a guess about absent text refused whole documents. Rule matches still block unconditionally; model spans stay in `residue`/`notes` for the reviewer. | `cargo test -p pacgate-redact` - **178 passed**; live: the blocked document re-sanitized to `verdict: pass`, `chunks_promoted: 15` |
| 2 | **Re-sanitize is required on this machine, not optional.** The verdict is stored at sanitize time, so old `blocked` rows stay blocked after the pull. | `POST /api/documents/:id/sanitize` with `{"data_level":"T3"}` - see step 6 below |

Carried unchanged from 0.2.34: the `kb_search` empty-signal suppression, the ingester denying
the two MCP authorization documents, the boundary-rule enforcement split (`not_implemented`
instead of silent passes), and the bind-mounted summarization/401-recovery fixes.

## The images and the patches travel DIFFERENTLY

| | What changed? | How it reaches you |
|---|---|---|
| **Images** (all six) | **YES** - `pacgate-api` carries the verdict fix; the other five are content-identical but republished under the new tag | `docker compose -f compose.prod.yaml pull` **fetches real layers** |
| **Patches** (`patches/*.py`, `server.py`) | carried from 0.2.34 | `git pull` **plus a container restart** - a pull alone is inert |

**Verified 2026-11-15**, the digests GHCR serves for `0.2.35`:

| image | GHCR `0.2.35` index |
|---|---|
| pacgate-api | `sha256:a154813306724ce9445c37e8f5dceafac8aadfc0e1135b81d1371ac42bfcbf4b` |
| pacgate-mcp | `sha256:51b72…` |
| ocr-service | `sha256:01ce5…` |
| deer-flow-pacgate | `sha256:038ed…` |
| deer-flow-frontend-pacgate | `sha256:721b2…` |

Re-derive rather than carry these forward: `scripts/report-ghcr-digests.ps1 -Version 0.2.35`.
The truncated entries are the script's own output; it prints full digests per image.

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

## Then re-sanitize the blocked documents - 0.2.35 is inert without it

The verdict is computed at sanitize time and STORED. Pulling 0.2.35 replaces the code that
computes it; it does not recompute verdicts already written. A machine can therefore run
0.2.35 with a fully green stack and still have documents blocked by the old rule.

Find them:

```sql
select d.id, d.name, count(*) as blocked
from kb_chunks c join documents d on d.id = c.document_id
where c.sanitization_state = 'blocked'
group by d.id, d.name order by blocked desc;
```

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -c "<the query above>"
```

For each one, re-run the sanitize. `data_level` is REQUIRED - omitting it returns
`422 missing field data_level`, which reads like a broken endpoint but is a validation error:

```powershell
# from inside the compose network, so nginx's browser-origin gate does not apply
docker exec pacgate-mcp python /tmp/san.py <admin-password> <document-id>
# POST /api/documents/<id>/sanitize  {"data_level":"T3"}
```

Expect `verdict: pass` and a non-zero `chunks_promoted`. If `verdict` stays `block`, the
remaining residue is **rule** evidence (checksum/pattern/context) and is *supposed* to block -
that is a real identifier, not this release's false positive, and it needs a human, not a retry.

Measured on the dev box: the one blocked document went from 16 blocked chunks to 15 sanitized
(one chunk was fully redacted away), leaving a residue of public bodies only.

`POST .../sanitize-rescan` is the read-only inspection: it reports `chunks_offending: 0` when
the new rule is satisfied, but it does NOT promote. Use `/sanitize` to actually reopen.

## Two things that will differ on another machine, and are not defects

- **`fold_telemetry_report.py` will say `CANNOT CHECK`.** Measured on the dev box: no
  thread has ever crossed the 36,000-token trigger, peak 24,910 (69%). Summarisation
  simply does not fire on ordinary traffic, so no telemetry exists. That is the correct
  answer, not a broken sensor.
- **`audit-recursion-regressions.ps1` may say `CANNOT CHECK`** for the same reason: no
  run has been deep enough to reach the wall since the fix.

Neither is a regression. A green result there would mean "the sensor works", not "the
feature works" - which is why the gate declines to claim it.
