# Shared mutation-testing engine.
#
# WHY THIS EXISTS AS A MODULE
#
# "A check that cannot fail is worse than no check, because it reports as
# coverage." Three checks in this work were unfalsifiable before mutation testing
# existed here, and the first version of the mutant runner itself had two bugs
# (plain $passed/$failed incremented inside a function, so it printed
# "0 passed, 0 failed" after a genuine failure and exited 0; and a "caught" test
# that matched the [PASS] line's own text). Writing that logic twice invites the
# same bugs twice, so it lives here once.
#
# The contract for a caller:
#   - a list of mutations, each naming the assertion that MUST go red
#   - each mutation is applied, the suite is run, the mutation is reverted
#   - an unapplied mutation is reported as a FAILURE, never silently skipped
#
# That last point is the one that matters most. An unapplied mutation is
# indistinguishable from an undetectable defect, and silently treating it as a
# pass is exactly how a check becomes decoration.

function Invoke-MutationSuite {
    [CmdletBinding()]
    param(
        # Each: @{ N = name; From = literal; To = replacement; Rx = regex; Want = assertion text }
        [Parameter(Mandatory)][array]$Mutations,

        # Script to run after each mutation. Must print "[PASS] <text>" / "[FAIL] <text>".
        [Parameter(Mandatory)][string]$SuiteScript,
        # Extra args for the suite, e.g. -StaticOnly.
        [string[]]$SuiteArgs = @(),

        # Files to restore from a byte snapshot afterwards.
        [Parameter(Mandatory)][string[]]$GuardPaths
    )

    $script:mutPassed = 0
    $script:mutFailed = 0

    # EVERY file any mutation names is guarded, in addition to the caller's list.
    #
    # This is not a convenience - it prevents data loss. The first version
    # snapshotted only -GuardPaths, so a mutation naming a DIFFERENT file (the
    # coverage mutations target install.ps1 while the suite guards the workflow
    # and compose) was applied to a file that was never snapshotted and therefore
    # never restored. It silently left install.ps1 mutated, and the next suite
    # then reported failures caused by the corruption rather than by the code.
    #
    # A mutation harness that edits files it will not restore is worse than no
    # harness. Deriving the guard set from the mutations themselves makes the two
    # impossible to disagree.
    $guard = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $GuardPaths) { [void]$guard.Add((Resolve-Path -LiteralPath $p).Path) }
    foreach ($m in $Mutations) {
        if ($m.File) { [void]$guard.Add((Resolve-Path -LiteralPath $m.File).Path) }
    }

    function Check($name, $good, $detail) {
        if ($good) { $script:mutPassed++; Write-Host "  [PASS] $name" -ForegroundColor Green }
        else {
            $script:mutFailed++
            Write-Host "  [FAIL] $name" -ForegroundColor Red
            if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        }
    }

    $pwshArgs = @('-NoProfile', '-File', $SuiteScript) + $SuiteArgs

    # Snapshot every guarded file so restoration never depends on git state -
    # the harness must work on a dirty tree.
    $snapshots = @{}
    foreach ($p in $guard) {
        $snapshots[$p] = [System.IO.File]::ReadAllBytes($p)
    }

    function Restore-All {
        foreach ($k in $snapshots.Keys) { [System.IO.File]::WriteAllBytes($k, $snapshots[$k]) }
    }

    try {
        foreach ($m in $Mutations) {
            Restore-All

            # A mutation may name its own suite and args, so one runner can cover
            # several targets without assuming they share an entry point.
            $thisSuite = if ($m.Suite) { $m.Suite } else { $SuiteScript }
            $thisArgs = @('-NoProfile', '-File', $thisSuite) + $(if ($m.SuiteArgs) { $m.SuiteArgs } else { $SuiteArgs })

            # Which file does this mutation target? A mutation may name it.
            $target = if ($m.File) { (Resolve-Path -LiteralPath $m.File).Path } else { $snapshots.Keys | Select-Object -First 1 }
            $body = [System.IO.File]::ReadAllText($target)

            # Apply, and PROVE it changed something before trusting any result.
            $mutated = $null
            if ($m.Rx) {
                $mutated = [regex]::Replace($body, $m.Rx, $m.To,
                    [System.Text.RegularExpressions.RegexOptions]::Singleline)
                if ($mutated -eq $body) {
                    Check "mutation applied: $($m.N)" $false "regex matched nothing in $(Split-Path $target -Leaf): $($m.Rx)"
                    continue
                }
            }
            else {
                if (-not $body.Contains($m.From)) {
                    Check "mutation applied: $($m.N)" $false "anchor not found in $(Split-Path $target -Leaf): $($m.From)"
                    continue
                }
                $mutated = $body.Replace($m.From, $m.To)
            }

            [System.IO.File]::WriteAllText($target, $mutated)
            try {
                $out = & pwsh @thisArgs 2>&1 | Out-String
                $suiteExit = $LASTEXITCODE
                # EXIT CODE is the authoritative signal, not a text pattern. The
                # first version matched '0 failed', which only works for suites
                # that happen to print that string - audit-qm-bootstrap prints
                # "RESULT: 7 of 7 checks passed" and no "0 failed" anywhere, so
                # the harness reported a RESTORED, PERFECTLY HEALTHY file as
                # failing. A cross-suite harness cannot assume one suite's
                # summary format; the exit code is the contract.
                #
                # Only [FAIL] lines count towards "caught", because the suite
                # prints "[PASS] <same text>" on a healthy run - matching the
                # assertion text anywhere would report every mutation as caught.
                $failedNames = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' } | ForEach-Object { $_.Trim() })
                # Two ways to express "the suite noticed":
                #   - $m.Output : a regex on the FULL output, for suites that do
                #     not use the [FAIL] convention (audit-aipc-update-coverage
                #     prints a table with GAP and exits 1 - a report, not a suite).
                #   - otherwise: the assertion text must appear on a [FAIL] line.
                # Either way the EXIT CODE must be non-zero, so a suite that
                # prints a scary message and still exits 0 is not counted.
                $caught = if ($m.Output) {
                    ($suiteExit -ne 0) -and ($out -match $m.Output)
                }
                else {
                    ($suiteExit -ne 0) -and ($failedNames -match [regex]::Escape($m.Want))
                }
                Check "caught: $($m.N)" $caught "expected '$($m.Want)' to FAIL; exit=$suiteExit; saw: $(($failedNames -join ' | ').Trim())"
            }
            finally { Restore-All }
        }
    }
    finally {
        Restore-All
        Write-Host ''
        Write-Host 'Files restored.' -ForegroundColor DarkGray
    }

    # Restored files must be green again, or the harness corrupted something.
    # Exit code again - see the note above on why a text pattern does not work
    # across suites.
    $out = & pwsh @pwshArgs 2>&1 | Out-String
    $suiteExit = $LASTEXITCODE
    $leftOver = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' } | ForEach-Object { $_.Trim() })
    Check 'restored files pass the full suite' ($suiteExit -eq 0) "exit=$suiteExit; $(($leftOver -join ' | ').Trim())"

    Write-Output ''
    Write-Host ("{0} passed, {1} failed" -f $script:mutPassed, $script:mutFailed)
    return ($script:mutFailed -eq 0)
}
