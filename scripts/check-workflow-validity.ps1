# Validate the workflow file structurally, offline.
#
# WHY THIS EXISTS
# ---------------
# The 0.1.14 release produced NO images, and the failure was not a build error:
# the workflow file itself was REJECTED as invalid, so every run died before a
# single job started. `build-and-push` - which had worked for the 0.1.13 release -
# never ran at all.
#
# The cause was one expression in a job-level `if:` that referenced `env`, which
# is NOT an available context there - only github / needs / vars / inputs are.
# GitHub reported "Unrecognized named-value: 'env'" and discarded the whole file.
# (That job has since been removed; the rule below still guards the general
# class, so a future job cannot reintroduce it.)
#
# What made this expensive was the BLAST RADIUS. An expression CI cannot evaluate
# silently invalidates the entire pipeline, so a guard added to a NEW optional job
# took down the existing REQUIRED one. Same family as the earlier bugs in this
# work where a check reported success because the thing it inspected had gone
# away - here a workflow failed to run while everything local stayed green,
# because nothing local parsed the workflow the way GitHub does.
#
# The existing test-workflow-namespace.ps1 could not catch it: it greps for
# STRINGS, and the bad line contains the expected words. Validity is a structural
# property, so it needs its own check. This is the cheapest version of that -
# YAML parse plus the specific context rules that are violated silently.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d = '') {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

$wf = '.github/workflows/build-ghcr.yml'
Write-Host '=== workflow structural validity ==='
Write-Output ''

Check 'the workflow file exists' (Test-Path $wf) $wf
$raw = Get-Content -LiteralPath $wf -Raw

# ── 1. YAML parses ──────────────────────────────────────────────────────────
$doc = $null
try {
    $doc = ConvertFrom-Yaml -ErrorAction Stop $raw 2>$null
}
catch {
    # ConvertFrom-Yaml is not always available; fall back to python.
    $py = @'
import sys, yaml, json
try:
    d = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
    print(json.dumps(sorted(d.get('jobs', {}).keys())))
except Exception as e:
    print("ERROR: " + str(e)); sys.exit(1)
'@
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'wfcheck.py'
    [System.IO.File]::WriteAllText($tmp, $py, [System.Text.UTF8Encoding]::new($false))
    $out = & python $tmp $wf 2>&1 | Out-String
    Check 'the workflow parses as YAML' ($LASTEXITCODE -eq 0) $out.Trim()
    # The job list comes back from the same parse, so nothing is assumed twice.
    $jobs = @()
    if ($LASTEXITCODE -eq 0) {
        $jobs = ($out.Trim() -replace '[\[\]\"]', '' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

# ── 2. No job-level `if:` uses a context that is unavailable there ─────────
#
# This is THE bug. Restricting it to job-level `if:` matters: at STEP level the
# `env` context IS valid, and a blanket ban would flag correct code.
#
# Parsed by indentation rather than by YAML, because the point is to inspect what
# an author wrote, and a hand-rolled walk keeps this dependency-free.
$lines = Get-Content -LiteralPath $wf
$validJobIfContexts = @('github', 'needs', 'vars', 'inputs')

$jobIfIssues = @()
$inJobs = $false
$currentJob = $null
foreach ($line in $lines) {
    if ($line -match '^jobs:\s*$') { $inJobs = $true; continue }
    if (-not $inJobs) { continue }
    # A job key sits at exactly two spaces of indentation.
    if ($line -match '^  ([A-Za-z0-9_\-]+):\s*$') { $currentJob = $Matches[1]; continue }
    # A job-level `if:` sits at exactly four spaces.
    if ($line -match '^    if:\s*(?<expr>.*)$') {
        $expr = $Matches['expr']
        foreach ($m in [regex]::Matches($expr, '(?<![\w.])(?<ctx>[a-z_][a-z0-9_]*)\s*\.')) {
            $ctx = $m.Groups['ctx'].Value
            if ($validJobIfContexts -notcontains $ctx) {
                $jobIfIssues += "job '$currentJob' if: uses '$ctx' - not available at job level (allowed: $($validJobIfContexts -join ', '))"
            }
        }
    }
}
Check 'no job-level if: uses an unavailable context' ($jobIfIssues.Count -eq 0) ($jobIfIssues -join ' ; ')

# ── 3. Every `needs:` names a job that exists ──────────────────────────────
if ($jobs.Count -gt 0) {
    $badNeeds = @()
    # NO `$` ANCHOR, and no `[^...]` class that has to stop at a line ending.
    #
    # The first version was '(?m)^\s+needs:\s*(?<v>[^\r\n]+)$' and it matched
    # NOTHING - not one line, on a file that plainly contains `needs:`.
    #
    # Reason: in .NET, `$` in Multiline mode matches at the position before a
    # LINE FEED (\n). It does not match before a CARRIAGE RETURN. With CRLF
    # endings the character after `build-and-push` is \r, so `$` had nothing to
    # match, `[^\r\n]+` could not extend past the \r, and every match failed.
    #
    # The check therefore scanned zero needs: lines and passed. Vacuously - it
    # reported success by finding nothing to inspect, which is the exact failure
    # mode this whole file exists to prevent. A mutation test caught it: a
    # deliberate typo in a needs: target went undetected.
    #
    # `[^\r\n]+` is already bounded to one line, so the anchor bought nothing and
    # cost correctness. Dropping it is the fix.
    foreach ($m in [regex]::Matches($raw, '(?m)^\s+needs:\s*(?<v>[^\r\n]+)')) {
        # Strip list brackets and quotes in one pass. The first version tried to
        # inline a character class containing both quote types, which PowerShell
        # cannot lex inside a single-quoted string - the parser saw an unexpected
        # token and refused the file.
        $needsValue = $m.Groups['v'].Value -replace '[\[\]]', '' -replace "['`"]", ''
        foreach ($n in ($needsValue -split ',')) {
            $n = $n.Trim()
            if ($n -and $jobs -notcontains $n) { $badNeeds += $n }
        }
    }
    # Guard against the vacuous pass repeating: if the scan finds nothing but the
    # file visibly declares needs:, the pattern has broken again.
    $needsCount = ([regex]::Matches($raw, '(?m)^\s+needs:\s*[^\r\n]+')).Count
    Check 'the needs: scan actually saw the declarations' `
        ($needsCount -ge 1 -or $raw -notmatch '(?m)^\s+needs:') `
        "scanned 0 needs: declarations - the pattern is broken, so this check proves nothing"
    Check 'every needs: names an existing job' ($badNeeds.Count -eq 0) "unknown job(s): $($badNeeds -join ', ') (jobs: $($jobs -join ', '))"
}
else {
    Check 'job list available for the needs: check' $false 'YAML parse did not yield jobs'
}

Write-Output ''
Write-Host ("{0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
