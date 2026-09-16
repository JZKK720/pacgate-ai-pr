# Mutation test for the namespace/workflow checks.
#
# WHY THIS EXISTS
# ---------------
# A check that cannot fail is worse than no check, because it reports as
# coverage. This session already produced three such checks: audit-qm-bootstrap
# reported "no copy step" both BEFORE and AFTER the fix, test-workflow-namespace
# flagged its own explanatory comments twice, and an earlier readiness probe
# reported a fabricated variable name pulled out of a doc comment.
#
# So: break the workflow on purpose, one property at a time, and assert the
# suite NOTICES. Each mutation must be caught by a NAMED assertion - otherwise
# the assertion is decoration.
#
# The file is restored from a byte copy between runs, never from git, so the
# test works on a dirty tree.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$wf = '.github/workflows/build-ghcr.yml'
$test = './scripts/test-workflow-namespace.ps1'
# $script: scope is REQUIRED. The first version of this harness incremented
# plain $passed/$failed inside the function, which creates locals and leaves the
# script-level counters at zero - so it printed "0 passed, 0 failed" after a
# genuine failure and then exited 0. A test harness that cannot report its own
# failure. Same family as the $var: scope-qualifier trap: PowerShell resolves
# names against the enclosing scope for READING but ASSIGNS to the current one.
$script:passed = 0; $script:failed = 0
function Check($name, $good, $detail) {
    if ($good) { $script:passed++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $name" -ForegroundColor Red; Write-Host "         $detail" -ForegroundColor DarkGray }
}

$original = [System.IO.File]::ReadAllText((Resolve-Path $wf))
Write-Host '=== Mutation test: each mutation must be caught by name ==='
Write-Output ''

# name, exact text to replace, replacement, assertion text that must go red
$mutations = @(
    @{ N = 'a failed login no longer stops the build'
       From = "if: steps.login.outcome != 'success'"
       To   = 'if: always()'
       Want = 'a failed GHCR login stops the build job' }

    @{ N = 'the failed login only warns'
       From = 'echo "::error::GHCR login failed for the resolved namespace. No images were built or pushed."'
       To   = 'echo "::warning::GHCR login failed for the resolved namespace."'
       Want = 'a failed login is a hard ::error::, not a warning' }

    # REGEX, because the anchor spans a newline. A plain substring anchor would
    # have to hardcode CRLF-vs-LF, and the first attempt at this mutation missed
    # the point entirely: it rewrote the echo text and left `exit 1` in place, so
    # nothing was removed and the suite correctly stayed green. The mutation was
    # broken, not the check.
    @{ N   = 'the failed login does not exit'
       Rx  = '(secret GHCR_CLIENT_PAT\.[^\n]*)\r?\n\s*exit 1'
       To  = '$1'
       Want = 'a failed login exits non-zero' }

    @{ N = 'GHCR_CLIENT_PAT is no longer consulted'
       From = 'CLIENT_PAT: ${{ secrets.GHCR_CLIENT_PAT }}'
       To   = 'CLIENT_PAT: ""'
       Want = 'the build job can use a PAT for the pinned namespace' }

    @{ N = 'the namespace pin is removed'
       From = '  GHCR_NAMESPACE: pacgate-ai'
       To   = '  GHCR_NAMESPACE: ""'
       Want = 'the step reads the committed constant' }

    @{ N = 'the mirror rebuilds instead of retagging'
       From = 'imagetools create'
       To   = 'imagetools inspect'
       Want = 'mirror RETAGS rather than rebuilding' }

    @{ N = 'the mirror becomes blocking'
       From = 'have=0'
       To   = 'have=1'
       Want = 'mirror degrades to a warning when the PAT is absent' }

    @{ N = 'the client pin is rewritten to the mirror namespace'
       From = 'ghcr.io/pacgate-ai/pacgate-api'
       To   = 'ghcr.io/jzkk720/pacgate-api'
       Want = 'all 8 pins (4 images x 2 compose files) use the workflow namespace' }
)

try {
    foreach ($m in $mutations) {
        $text = [System.IO.File]::ReadAllText((Resolve-Path $wf))
        $target = if ($m.From -like 'ghcr.io/pacgate-ai/*') { 'deploy/client-bundle/compose.prod.yaml' } else { $wf }
        $body = [System.IO.File]::ReadAllText((Resolve-Path $target))

        # Verify the mutation actually CHANGED something before trusting a green
        # result. An unapplied mutation looks identical to an undetectable one.
        $mutated = if ($m.Rx) {
            [regex]::Replace($body, $m.Rx, $m.To, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        }
        else {
            if (-not $body.Contains($m.From)) {
                Check "mutation applied: $($m.N)" $false "anchor not found in $target : $($m.From)"
                continue
            }
            $body.Replace($m.From, $m.To)
        }

        if ($mutated -eq $body) {
            Check "mutation applied: $($m.N)" $false "regex matched nothing in $target : $($m.Rx)"
            continue
        }

        [System.IO.File]::WriteAllText((Resolve-Path $target), $mutated)
        try {
            $out = & pwsh -NoProfile -File $test 2>&1 | Out-String
            $caught = ($out -match [regex]::Escape($m.Want)) -and ($out -notmatch '0 failed')
            Check "caught: $($m.N)" $caught "expected '$($m.Want)' to go red; tail: $(($out -split "`n" | Select-Object -Last 2) -join ' ')"
        }
        finally {
            [System.IO.File]::WriteAllText((Resolve-Path $target), $body)
        }
    }
}
finally {
    [System.IO.File]::WriteAllText((Resolve-Path $wf), $original)
    Write-Host ''
    Write-Host 'Workflow restored.' -ForegroundColor DarkGray
}

# Restored file must be green again, or the harness itself corrupted something.
$out = & pwsh -NoProfile -File $test 2>&1 | Out-String
Check 'restored workflow passes the full suite' ($out -match '0 failed') ($out -split "`n" | Select-Object -Last 1)

Write-Output ''
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
