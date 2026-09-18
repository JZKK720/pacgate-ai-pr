# Mutation test for the namespace/workflow checks.
#
# WHY THIS EXISTS
# ---------------
# A check that cannot fail is worse than no check, because it reports as
# coverage. This work already produced three such checks: audit-qm-bootstrap
# reported "no copy step" both BEFORE and AFTER the fix, and test-workflow-namespace
# flagged its own explanatory comments twice.
#
# So: break the workflow on purpose, one property at a time, and assert the
# suite NOTICES by name. Each mutation must be caught by a NAMED assertion -
# otherwise the assertion is decoration.
#
# The engine lives in scripts/lib/mutation-harness.ps1. It verifies each mutation
# actually changed something before trusting the result, because an unapplied
# mutation is indistinguishable from an undetectable defect.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot 'lib/mutation-harness.ps1')

$wf = '.github/workflows/build-ghcr.yml'
$compose = 'deploy/client-bundle/compose.prod.yaml'
$test = './scripts/test-workflow-namespace.ps1'

Write-Host '=== Mutation test: workflow + namespace checks ==='
Write-Output ''

# -StaticOnly: this harness re-invokes the suite once per mutation and the
# behavioural section starts a docker container each run. That nesting blows past
# the caller's budget and surfaces as a timeout rather than a result. The
# mutations all target static properties, and the behavioural layer still runs in
# the full gate suite.
$mutations = @(
    @{ N = 'a failed login no longer stops the build'
       File = $wf
       From = "if: steps.login.outcome != 'success'"
       To   = 'if: always()'
       Want = 'a failed GHCR login stops the build job' }

    @{ N = 'the failed login only warns'
       File = $wf
       From = 'echo "::error::GHCR login failed for the resolved namespace. No images were built or pushed."'
       To   = 'echo "::warning::GHCR login failed for the resolved namespace."'
       Want = 'a failed login is a hard ::error::, not a warning' }

    # REGEX, because the anchor spans a newline. A plain substring anchor would
    # have to hardcode CRLF-vs-LF, and the first attempt at this mutation missed
    # the point entirely: it rewrote the echo text and left `exit 1` in place, so
    # nothing was removed and the suite correctly stayed green. The mutation was
    # broken, not the check.
    @{ N = 'the failed login does not exit'
       File = $wf
       Rx = '(secret GHCR_RELEASE_PAT\.[^\n]*)\r?\n\s*exit 1'
       To = '$1'
       Want = 'a failed login exits non-zero' }

    @{ N = 'GHCR_RELEASE_PAT is no longer consulted'
       File = $wf
       From = 'secrets.GHCR_RELEASE_PAT || secrets.GITHUB_TOKEN'
       To   = 'secrets.GITHUB_TOKEN'
       Want = 'GHCR_RELEASE_PAT is optional - it falls back to the automatic token' }

    @{ N = 'the namespace pin is removed'
       File = $wf
       From = "  GHCR_NAMESPACE: jzkk720`r`n"
       To   = ''
       Want = 'workflow declares the pinned GHCR_NAMESPACE constant' }

    @{ N = 'the credential warning is removed'
       # SINGLE backslashes: in a PowerShell single-quoted string they are
       # literal, so the regex engine receives what is written here.
       #
       # The comparison is on the LOWERCASED pair (ns_lc/owner_lc), so that is
       # what the anchor must match. Anchoring on the old raw `$ns != $OWNER_NS`
       # would leave this mutation unapplied - and a mutation that cannot apply
       # is indistinguishable from a defect that cannot be detected.
       File = $wf
       Rx   = 'if \[ "\$ns_lc" != "\$owner_lc" \][^\n]*\r?\n'
       To   = ''
       Want = 'WARNS when the token owner differs from the pinned namespace' }

    @{ N = 'the PAT is routed through a step output'
       File = $wf
       From = '          password: ${{ secrets.GHCR_RELEASE_PAT || secrets.GITHUB_TOKEN }}'
       To   = '          password: ${{ steps.ns.outputs.token }}'
       Want = 'GHCR_RELEASE_PAT is optional - it falls back to the automatic token' }

    @{ N = 'the PAT is copied into $GITHUB_OUTPUT'
       File = $wf
       From = '          echo "actor=$ns" >> "$GITHUB_OUTPUT"'
       To   = '          echo "PAC_TOKEN_EOF" >> "$GITHUB_OUTPUT"'
       Want = 'the PAT is not copied into $GITHUB_OUTPUT' }

    # NOTE: two mutations were removed here on 2026-09-17, when the
    # `mirror-upstream` job was deleted and jzkk720 became code-only. They broke
    # `imagetools create` and `have=0` in that job, so their anchors no longer
    # exist in the workflow. They were NOT repointed at other lines: the
    # properties they asserted (retag-not-rebuild, degrade-to-warning) belonged
    # to the mirror job and left with it.

    # The compose pins must name the namespace the workflow publishes to. The
    # original name for this mutation referenced the mirror namespace; the
    # property it actually tests is namespace CONSISTENCY between the workflow
    # and the compose pins, which is what a wrong pin breaks.
    #
    # DIRECTION MATTERS, and it had to be inverted when the authority moved.
    # This mutation rewrites a CORRECT pin INTO a non-publishing namespace, so
    # the anchor must name the CURRENT correct value (jzkk720). It previously
    # anchored on `ghcr.io/pacgate-ai/pacgate-api` - which after the repin no
    # longer exists in compose, so the mutation could not APPLY. A mutation that
    # cannot apply is indistinguishable from a defect that cannot be detected:
    # it would have reported "FAIL: mutation applied" while the consistency check
    # it names went untested.
    @{ N = 'a compose pin is rewritten to a non-publishing namespace'
       File = $compose
       From = 'ghcr.io/jzkk720/pacgate-api'
       To   = 'ghcr.io/pacgate-ai/pacgate-api'
       Want = 'all 8 pins (4 images x 2 compose files) use the workflow namespace' }
)

# --- the coverage table itself ---------------------------------------------
#
# audit-aipc-update-coverage.ps1 is a MEASUREMENT, not a suite: it prints a table
# and exits non-zero while gaps remain. It reported 11 of 11 only after its
# marker table was edited, and a coverage tool that goes all-green when its own
# rules are loosened is precisely the kind of thing that lies. So break the
# BEHAVIOUR it claims to measure and require the table to notice.
#
# Each of these names its own Suite, because the thing under test is the coverage
# table, not the namespace suite. They are deliberately NOT appended to
# $mutations above: the first attempt did that, which meant they ran against the
# namespace suite where they cannot fail - and because that invocation never
# guarded install.ps1, it left the file mutated. Two failures from one mistake.
$install = 'deploy/client-bundle/install.ps1'
$coverage = './scripts/audit-aipc-update-coverage.ps1'

$ok = Invoke-MutationSuite -Mutations $mutations -SuiteScript $test -SuiteArgs @('-StaticOnly') `
    -GuardPaths @($wf, $compose)

Write-Output ''
Write-Host '=== Mutation test: update-coverage table ===' -ForegroundColor Cyan
Write-Output ''

$coverageMutations = @(
    @{ N = 'step 7f re-staging is removed (the qm R2 gap reopens)'
       File = $install
       Suite = $coverage
       From = 'Re-staging the qm runtime config from the tracked source'
       To   = 'Skipping qm re-stage'
       Want = 'qm runtime config'
       Output = 'GAP' }

    @{ N = 'step 7e staleness probe is removed'
       File = $install
       Suite = $coverage
       From = 'http://localhost:$frontPort/version'
       To   = 'http://localhost:$frontPort/not-the-endpoint'
       Want = 'staleness marker'
       Output = 'GAP' }

    @{ N = 'the qm restart guidance is removed'
       File = $install
       Suite = $coverage
       From = 'compose.qm.yaml restart'
       To   = 'compose.qm.yaml ps'
       Want = 'qm stack'
       Output = 'GAP' }
)

$ok2 = Invoke-MutationSuite -Mutations $coverageMutations -SuiteScript $coverage `
    -GuardPaths @($install)

Write-Output ''
Write-Host '=== Mutation test: untracked-file guard ===' -ForegroundColor Cyan
Write-Output ''

# The untracked-file guard is the one that can LIE most easily, because both
# failure directions look like success:
#
#   - reverting to the old bare `git status --porcelain` makes a scratch file
#     skip the whole repo refresh. The suite would still pass if its CASE 6 did
#     not exist, and on a real machine the ONLY symptom is "images updated, repo
#     silently stayed old".
#   - deleting the collision check lets the pull proceed into git's own abort.
#
# So both directions are mutated here, and the suite must NOTICE BY NAME.
$repoPull = './scripts/test-install-repo-pull.ps1'

$untrackedMutations = @(
    # REVERT TO THE DEFECT. Dropping --untracked-files=no restores the old
    # behaviour where any untracked file blocks the refresh.
    @{ N = 'the guard counts untracked files again (the original defect)'
       File = $install
       Suite = $repoPull
       From = 'git status --porcelain --untracked-files=no'
       To   = 'git status --porcelain'
       Want = 'did NOT skip the repo update' }

    # The collision pre-check is what turns git's raw abort into an actionable
    # message. Remove it and the refusal becomes an unexplained git error.
    #
    # Asserts INSTALLER-SPECIFIC wording ('Cannot refresh the repo'). An earlier
    # version asserted 'would be overwritten', which also matches GIT's own abort
    # text ("would be overwritten by merge"), so renaming the installer's message
    # was invisible and this mutation went undetected - a mutation that silently
    # does nothing is indistinguishable from a defect nothing catches.
    # Asserts on the ASSERTION NAME, not the message text. `Want` is matched
    # against the suite's '[FAIL] <name>' lines, so a substring of the installer's
    # MESSAGE never matches anything - that mistake made this report as uncaught
    # while the two failures above it showed it plainly WAS caught.
    @{ N = 'the untracked collision pre-check is removed'
       File = $install
       Suite = $repoPull
       From = 'Cannot refresh the repo:'
       To   = 'Refreshing anyway:'
       Want = 'refused with the installer' }

    # Quotepath: without it git C-quotes non-ASCII paths and the comparison
    # silently fails, so a Chinese-named collision would NOT be detected and the
    # pull would reach git's own abort instead.
    #
    # Targets the NON-ASCII case specifically (CASE 8). If an ASCII collision
    # also existed in that fixture the block would still fire and mask this bug,
    # which is why the two cases are kept apart.
    @{ N = 'the collision check loses core.quotepath=false'
       File = $install
       Suite = $repoPull
       From = "git -c core.quotepath=false ls-files --others --exclude-standard"
       To   = "git ls-files --others --exclude-standard"
       Want = 'non-ASCII collision WAS detected' }
)

$ok3 = Invoke-MutationSuite -Mutations $untrackedMutations -SuiteScript $repoPull `
    -GuardPaths @($install)

if (-not $ok -or -not $ok2 -or -not $ok3) { exit 1 }
exit 0
