# Mutation test for the workflow-validity check.
#
# WHY: this check exists because a job-level `if:` referencing `env` silently
# invalidated the ENTIRE workflow file, so the 0.1.14 release ran no jobs and
# produced no images - while everything local stayed green. A check written in
# response to an outage must be proven to fail on that same input, or it is
# decoration and the outage can repeat.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot 'lib/mutation-harness.ps1')

$wf = '.github/workflows/build-ghcr.yml'
$test = './scripts/check-workflow-validity.ps1'

Write-Host '=== Mutation test: workflow validity ==='
Write-Output ''

$mutations = @(
    # THE ACTUAL OUTAGE. Reverting the guard to `env` must be caught by name.
    @{ N = 'the job-level if: goes back to the env context (the real outage)'
       File = $wf
       From = "if: `${{ vars.GHCR_MIRROR_NAMESPACE != '' }}"
       To   = "if: `${{ env.GHCR_MIRROR_NAMESPACE != '' }}"
       Want = 'no job-level if: uses an unavailable context' }

    @{ N = 'the guard is deleted entirely'
       File = $wf
       # SINGLE-quoted, so PowerShell passes the regex through literally. Written
       # with doubled backslashes first, which made the pattern match nothing and
       # was reported as an UNAPPLIED mutation rather than a false pass.
       Rx   = '(?m)^\s+if:\s*\$\{\{\s*vars\.GHCR_MIRROR_NAMESPACE[^\r\n]*\r?\n'
       To   = ''
       Want = 'the mirror guard reads vars' }

    @{ N = 'a needs: points at a job that does not exist'
       File = $wf
       From = "    needs: build-and-push"
       To   = "    needs: build-and-push-typo"
       Want = 'every needs: names an existing job' }

    # The FIRST attempt at this was `mirror-upstream:` -> `mirror-upstream:::`,
    # which is perfectly VALID YAML - it just renames the job to
    # "mirror-upstream::". The check correctly stayed green and the MUTATION was
    # at fault. Verified by parsing the mutated file: it yielded
    # jobs == ['build-and-push', 'mirror-upstream::'].
    #
    # An unterminated quoted scalar is a genuine parse error.
    @{ N = 'the YAML is broken outright'
       File = $wf
       From = "    needs: build-and-push`r`n    runs-on: ubuntu-latest"
       To   = "    needs: build-and-push`r`n    runs-on: `"ubuntu-latest"
       Want = 'the workflow parses as YAML' }
)

$ok = Invoke-MutationSuite -Mutations $mutations -SuiteScript $test -GuardPaths @($wf)

if (-not $ok) { exit 1 }
exit 0
