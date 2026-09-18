# 016 - Make JZKK720 the Master of the Whole Build (E2E)

Status: IN PROGRESS. Tasks 1 and 2 are DONE (commits 2918487, e9fdece).
Task 3 is blocked on a user action.

Goal: make JZKK720/pacgate-ai-pr the release authority for all four Pacgate
images - code, tags, Actions and GHCR - so one account owns the build E2E.
pacgate-ai demotes to a read-only mirror.

This supersedes the 2026-09-17 model in e3413d3, which had the roles inverted.

## The proven blocker (dispatch evidence, run #10)

    #20 exporting manifest list sha256:b2abacef... done
    #20 ERROR: failed to push ghcr.io/jzkk720/pacgate-api:0.1.14
    ERROR: denied: permission_denied: write_package

The LOGIN SUCCEEDED and the job declares `permissions: packages: write`, so
this is NOT a token-scope problem. It is package OWNERSHIP:

    jzkk720/pacgate-api          repository=(empty)   exists, NOT repo-linked
    jzkk720/deer-flow-pacgate    repository=(empty)   exists, NOT repo-linked
    jzkk720/pacgate-mcp          404                  does not exist
    jzkk720/deer-flow-frontend   404                  does not exist

Contrast the fork, which publishes fine:

    pacgate-ai/pacgate-api  repository=pacgate-ai/pacgate-ai-pr   <- LINKED
    jzkk720/pacgate-api     repository=(empty)                    <- not linked

A package created BY a workflow is auto-linked to that repo and IS writable by
GITHUB_TOKEN. These two predate the repo and were created by a manual
`docker push`, so they never got the link.

CONSEQUENCE: a PAT with write:packages is REQUIRED. Task 3 is not optional.

RETRACTION: an earlier draft of this plan asserted "same owner => GITHUB_TOKEN
suffices => no PAT needed" and marked Task 3 skippable. That was WRONG - an
inference from token scope to write ability, which only a real dispatch could
distinguish. Do not re-derive it.

## DONE: Task 1 - JZKK720 Actions executes

Runs #1-#9 showed jobs=0; run #10 produced a real job. Correction: the earlier
audit called jobs=0 the "invalid-workflow signature". The real cause is the
package-ownership denial, which applies to all 8 pre-fix failures.

## DONE: Task 2 - namespace pinned to jzkk720 (commits 2918487, e9fdece)

  .github/workflows/build-ghcr.yml   pin flipped, warning inverted,
                                     GHCR_RELEASE_PAT, header rationale
  scripts/test-workflow-namespace.ps1  34 assertions (was 12)
  scripts/test-workflow-mutations.ps1  4 stale anchors; 9/9 caught

Two bugs found while doing it:

1. CASE. github.repository_owner preserves the account's real capitalization
   (JZKK720) while registry paths are lowercase (ghcr.io/jzkk720). A raw shell
   compare emits a warning about a 403 that will not happen - training the
   reader to ignore the warning that DOES matter. Both sides are lowercased.

2. MY INDENTATION BUG (fixed in e9fdece). The PAT rename left one continuation
   `echo` at 12 spaces where its neighbours are at 10. Inside `run: |` that is
   a shell script, so the line became an argument to the echo above instead of
   a command. It did not fail the run because that step is
   `if: login.outcome != 'success'` and the login succeeded - which is the
   danger: a latent break on the error path, firing only when someone needs it
   to explain a failure. Check indentation widths NUMERICALLY; 2 spaces are
   invisible to reading.

EXPECTED ONGOING FAILURE: test-workflow-namespace.ps1 reports the 8-pin check
as FAIL until Task 5 repins compose. That is the invariant working, not a bug.

## Task 3 - add GHCR_RELEASE_PAT (REQUIRED, user action)

  - Create a classic PAT as JZKK720 with write:packages, read:packages.
    Do NOT paste it into chat.
  - Add it as a repo secret named GHCR_RELEASE_PAT at
    https://github.com/JZKK720/pacgate-ai-pr/settings/secrets/actions
  - Re-run Task 4 and confirm the push step succeeds.

Alternative needing no PAT: delete the two UNLINKED packages in the GHCR UI,
then re-run - a package created by the workflow is auto-linked and
GITHUB_TOKEN can write it. Nothing pins their tags (0.1.0-0.1.2, superseded).
But deletion is IRREVERSIBLE, so it needs explicit owner approval.

2FA WALL: deleting repository variables hits a 2FA "Confirm access" prompt.
Do not attempt to bypass - it is the account owner's second factor.

## Task 4 - build the first release, flip packages public

  1. git rev-list -n1 v0.1.14        # MUST be the intended commit
     git push origin v0.1.14
     git ls-remote origin refs/tags/v0.1.14   # verify; do NOT trust --dry-run
  2. Confirm the run goes green. A failure at "Build & push" with
     `denied: permission_denied: write_package` means Task 3 is not done.
  3. Job logs need auth; the user's own git credential works:
       $c = "protocol=https`nhost=github.com`n`n" | git credential fill
       # extract password=..., NEVER print it
  4. Flip all four packages public. UI-ONLY: the REST PATCH .../visibility
     endpoint 404s for personal-account packages even with write:packages.
     New packages default PRIVATE; the only symptom is a failed anon pull.
  5. THE GATE - verify anonymously, all four must be HTTP 200:
       .\scripts\check-ghcr-pull.ps1 -Targets `
         "jzkk720/pacgate-api:0.1.14","jzkk720/pacgate-mcp:0.1.14", `
         "jzkk720/deer-flow-pacgate:0.1.14","jzkk720/deer-flow-frontend-pacgate:0.1.14"
     STOP if any is not 200. (401 = still private, 404 = tag absent.)
  6. Confirm the two historical client-visible bugs are fixed IN the images:
       docker run --rm --entrypoint cat .../pacgate-mcp:0.1.14 /app/requirements.txt
         # expect markitdown[docx,pptx,xlsx,pdf]>=0.1.5
       docker run --rm --entrypoint sh .../pacgate-api:0.1.14 -c \
         "grep -iE 'hnsw|ivfflat' /app/migrations/002_rag_schema.sql"
         # expect hnsw
  7. Confirm the FRONTEND image is BRANDED (guards the d22ef48 regression):
       docker run --rm --entrypoint sh .../deer-flow-frontend-pacgate:0.1.14 -c \
         "grep -rl pacgate /app/.next 2>/dev/null | wc -l"
         # expect > 0. Zero means the overrides step was skipped and the image
         # lost the PacGate customizations - the exact defect d22ef48 fixed.

## Task 5 - repoint every pin (ONLY after Task 4 step 5 passes)

  1. Confirm the check fails first: test-workflow-namespace.ps1 -StaticOnly
  2. Repin the 8 images in deploy/client-bundle/compose.prod.yaml and
     compose.bundle.yaml: ghcr.io/pacgate-ai/ -> ghcr.io/jzkk720/
     LEAVE the volcengine/openviking@sha256 pin and any yc-software/qm images.
  3. Sweep the 36 files mentioning jzkk720, CLASSIFYING each:
       client-facing (READMEs, client-bundle/README-client.md,
         AIPC*-HANDOFF-PROMPT*.md, DEPLOYMENT-GUIDE.md, handbooks/*) -> UPDATE
       build/CI (README-BUILD.md, build-*.ps1, the workflow) -> UPDATE
       dated records (plans/*, *AUDIT*.md, docs/superpowers/specs/*) ->
         DO NOT REWRITE; they record what was true then. Add a "superseded by
         plan 016" line only where a reader could run a stale command
       incidental (.gitignore, pacgate-ai/crates/**, patches/*.patch) ->
         INSPECT EACH; these are fixtures or upstream URLs, not image pins
     DO NOT BLIND-REPLACE "pacgate-ai": it is BOTH the GHCR namespace AND the
     build context path `pacgate-ai/Dockerfile` (a directory in this repo).
     Changing the second breaks the build.
  4. Re-run guards and RE-DIFF. Expect the namespace check to now PASS.
  5. Commit.

## Task 6 - fresh-clone E2E (not optional)

This dev box accumulates credentials, models and rendered gitignored configs
that mask fresh-clone failures.

  1. Clone to a real (non-8.3) temp dir:
       git clone --depth 1 https://github.com/JZKK720/pacgate-ai-pr.git $dir
  2. Confirm the compose pins resolve and no docker login is in the path.
  3. Pull all four anonymously from the clean clone - the client's experience.
  4. .\scripts\test-install-repo-pull.ps1      -> expect 29 passed, 0 failed
  5. .\scripts\audit-aipc-update-coverage.ps1  -> expect 11 of 11, 0 gaps
  6. Clean up. 7. Record evidence here. If anything failed, do NOT claim done.

## Task 7 - demote the fork in the docs

  1. deploy/README-BUILD.md: single model (JZKK720 = authority, pacgate-ai =
     read-only mirror), the secrets table (GHCR_RELEASE_PAT REQUIRED + why),
     both release paths (prefer dispatch).
  2. Supersede docs/superpowers/specs/2026-09-17-remove-jzkk720-image-mirror-design.md
     - it argued the OPPOSITE model and was implemented in e3413d3. Do not
     delete; add a SUPERSEDED header.
  3. Add the plan index entry; log the release in plans/007-delivery-log.md.
  4. Commit.

## Task 8 - sync the fork and verify parity

  1. git push origin main
  2. FORWARD-PORT d22ef48 (frontend overrides) - see the divergence below.
  3. Sync the fork in the browser (fork page -> Sync fork -> Update branch).
     Branch push to the fork also works via git; a TAG push does not.
  4. Verify with git ls-remote on BOTH remotes - identical SHAs.

## UNFIXED divergence requiring a forward-port

    origin/main = e9fdece   (has: install.ps1 fix, namespace flip)
    fork/main   = 0cd785e   (has: d22ef48 frontend-overrides CI fix)

NEITHER contains the other. The fork's d22ef48 is a real fix origin needs: the
workflow cloned upstream deer-flow and built it directly, SKIPPING
deploy/frontend-patches/files/ (5 branded files), so every CI-published
frontend image silently lost the PacGate customizations - measured as 0
pacgate-marked files in .next vs 9 in the locally-built image. Forward-port it
before the next frontend release.

## Global constraints

  - NEVER repin compose before the jzkk720 packages are public and anon-200.
  - Images are PUBLIC by design. No docker login ghcr.io on the client path.
  - pacgate-ai and jzkk720 are USER accounts, not orgs.
  - Tag push to origin works. Branch push to the fork works; TAG push does not.
  - ALWAYS verify with git ls-remote - never the UI, never a --dry-run (it
    reported success for a tag that did not exist).
  - BEFORE pushing any tag, run `git rev-list -n1 <tag>`. A stale local tag
    pushed the wrong commit and reproduced a documented failure.
  - AFTER any mutation suite, RE-DIFF the guarded file before committing.
    Confirm .git/mutation-guard-backup is absent first.
  - Guard scripts must be read with `git show <tag-sha>:<path>`, because a tag
    push builds from THE TAG'S COMMIT, not the working tree.
  - Version pins live in 4 files: Cargo.toml, Cargo.lock, both compose files.
    Use scripts/bump-release-version.ps1.

## Rollback

Task 5 is the dangerous one. If the client install breaks after repinning,
revert that commit: compose returns to ghcr.io/pacgate-ai/*, whose images stay
public and pullable - a safe instant fallback. Task 4's packages are additive.

## Known limits (do not try to "fix" these)

  - Visibility flip is UI-ONLY for personal accounts; the REST PATCH 404s.
  - A tag push builds from the tag's commit; dispatch decouples tag from code.
  - Non-existent jzkk720 packages report 403, not 404 - absence and privacy
    look identical anonymously.
  - A --dry-run push can report success for a ref that does not exist.
  - Deleting repository variables hits a 2FA wall. Flag it for the user.


docs(plan-016): record the transient release gap and the now-clean fork

Two things that must be on the record before the maintainer syncs the fork.

1. THE FORK IS NOW A CLEAN FAST-FORWARD TARGET. It was not before this work.
   pacgate-ai is a TRUE FORK of JZKK720/pacgate-ai-pr (fork=true, parent and
   source both JZKK720/pacgate-ai-pr). It held d22ef48, which origin lacked, so
   the two trees had diverged in BOTH directions. GitHub's only offer in that
   state is "Discard N commits" - destructive. The content was forward-ported in
   c87a75d and the fork merged in 45b210a so its commit is now an ANCESTOR.

     fork   0cd785e -> 7 behind, 0 ahead, ancestor of origin/main
     Sync fork is now a plain fast-forward that discards nothing.

   The merge is content-neutral: both sides added the identical 14-line step
   relative to merge base 0d065f9, and the step count in the file is verified
   to be exactly 1 afterwards (not 2) - the specific risk of merging a change
   already applied.

2. THERE IS A TRANSIENT RELEASE GAP, and it should be stated rather than
   discovered. Flipping GHCR_NAMESPACE to jzkk720 applies GLOBALLY, so a release
   dispatched from the FORK now also targets jzkk720 and hits the same
   permission_denied. Until access to the jzkk720 packages is granted, NO
   release can ship from either repo.

     Impact: release only. Clients are unaffected - all four
     ghcr.io/pacgate-ai/*:0.1.14 images remain PUBLIC (verified 200), and the
     compose pins are untouched, so every install and update keeps working.
     Escape hatch if an urgent release is needed before then: dispatch with the
     `namespace` input set to pacgate-ai, which the workflow routes through the
     old target (the precedence is input > pinned > owner).

Unblocking options, both user actions:
   A. Add a PAT with write:packages as repo secret GHCR_RELEASE_PAT on JZKK720.
      The workflow prefers it and falls back to GITHUB_TOKEN. Conservative.
   B. Delete the two UNLINKED packages (pacgate-api, deer-flow-pacgate) in the
      GHCR UI, then re-run. A package created by a workflow is auto-linked, so
      GITHUB_TOKEN can write the replacement. Nothing pins their tags (0.1.0-
      0.1.2, superseded), but deletion is IRREVERSIBLE and needs approval.

Note on B and the fork: if the deletion route is taken, the fork is ALSO the
right place to build from, because its packages are already workflow-linked to
pacgate-ai/pacgate-ai-pr. That does not by itself confer jzkk720 access, but it
removes a different failure class.

Verified at this commit: workflow YAML parses, structural validity 5/5,
17 namespace assertions pass, the frontend-overrides step is guarded three ways
(exists / actually copies / correct order), fork ancestor-check confirmed.
The one remaining test failure is the 8-pin consistency check, which is the
invariant working correctly until the repin that must FOLLOW the package flips.
