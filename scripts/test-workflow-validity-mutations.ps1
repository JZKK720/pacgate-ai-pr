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
    # A needs: pointing at a job that does not exist must be caught by name.
    #
    # This INSERTS a bogus needs: rather than rewriting an existing one, because
    # the mirror job - the only job that ever declared `needs:` - was removed on
    # 2026-09-17 when jzkk720 became code-only. Without an insertion the
    # 'every needs: names an existing job' check would have nothing to inspect
    # and would pass vacuously, which is the exact failure mode this whole file
    # exists to prevent.
    @{ N = 'a needs: points at a job that does not exist'
       File = $wf
       From = "    runs-on: ubuntu-latest"
       To   = "    needs: build-and-push-typo`r`n    runs-on: ubuntu-latest"
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
       From = "    runs-on: ubuntu-latest"
       To   = "    runs-on: `"ubuntu-latest"
       Want = 'the workflow parses as YAML' }
)

$ok = Invoke-MutationSuite -Mutations $mutations -SuiteScript $test -GuardPaths @($wf)

if (-not $ok) { exit 1 }
exit 0
