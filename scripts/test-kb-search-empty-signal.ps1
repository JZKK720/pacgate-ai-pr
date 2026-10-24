# Guard: an empty `kb_search` must say WHY it is empty, not return a bare `[]`.
#
# WHY THIS EXISTS (measured 2026-10-24, live AIPC, thread eee62924)
#
# A lawyer asked for a summary of the firm's 互联网+/电商合规 material. The agent
# called `pacgate_kb_search` 18 times across the thread. Every call returned:
#
#     []
#
# The lawyer cannot distinguish that from "the firm has no such material" or
# "there is no such law". It is the same two characters in all three cases.
#
# What was actually happening: the run searched matter `a0409504`
# ("Firm Knowledge Base"), which has ZERO documents. `kb_search` was working
# perfectly - it returns hits on matters that have content. The tool was never
# broken; the corpus was empty, and the tool said so in the least useful way
# possible.
#
# This is a correctness problem, not a cosmetic one. In a legal product, "no
# results" is a factual claim about the world. Returning it when the truth is
# "nothing has been indexed yet" invites a lawyer to conclude the firm lacks
# authority it may actually hold - or to conclude the tool is broken and stop
# trusting it.
#
# WHAT IS ASSERTED
#   E1  an empty result is NOT returned as a bare `[]`
#   E2  the empty response names the matter that was searched
#   E3  the empty response distinguishes "no indexed documents" from
#       "documents exist but none matched"
#   E4  the empty response tells the caller what to do next
#   E5  a NON-empty result is still returned as a plain JSON array, so existing
#       consumers do not break
#
# Exit codes: 0 = all pass; 1 = a real failure; 2 = cannot check
#
# Usage:  pwsh -File scripts/test-kb-search-empty-signal.ps1

[CmdletBinding()]
param(
    [string]$ServerFile = 'deploy/pacgate-mcp/server.py'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== an empty kb_search must explain itself ===' -ForegroundColor Cyan

if (-not (Test-Path $ServerFile)) {
    Write-Host "`nCANNOT CHECK: missing server file: $ServerFile" -ForegroundColor Yellow
    exit 2
}

$text = Get-Content -Path $ServerFile -Raw -Encoding UTF8

# Isolate the pacgate_kb_search function body.
$start = $text.IndexOf('def pacgate_kb_search(')
if ($start -lt 0) {
    Write-Host "`nCANNOT CHECK: pacgate_kb_search not found in $ServerFile" -ForegroundColor Yellow
    exit 2
}
$rest = $text.Substring($start)
$end = $rest.IndexOf('@mcp.tool()')
if ($end -lt 0) { $end = $rest.Length }
$body = $rest.Substring(0, $end)

Write-Host ("  function body: {0} chars" -f $body.Length) -ForegroundColor DarkGray

# ── E1: no bare `[]` return ───────────────────────────────────────────────────
#
# The old body ended with `return json.dumps(results, ...)`, which serialises an
# empty list to exactly `[]`.
$bareEmpty = $body -match 'return\s+json\.dumps\(\s*results\s*,\s*ensure_ascii=False,\s*indent=2\s*\)\s*$'
Check 'E1 empty result is not returned as a bare []' (-not $bareEmpty) `
    "the function still ends with a plain json.dumps(results), so an empty search serialises to '[]' - indistinguishable from 'no such law exists'"

# ── E2: the empty response names the matter ───────────────────────────────────
$namesMatter = $body -match 'matter_id' -and ($body -match '(?i)no (indexed )?documents|not indexed|nothing (has been )?indexed|empty')
Check 'E2 empty response names the matter and says it is unindexed' $namesMatter `
    "without the matter id the caller cannot tell which corpus was empty"

# ── E3: distinguish unindexed from no-match ───────────────────────────────────
#
# Assert the three distinct reason codes rather than prose, so the gate tests the
# contract a caller can branch on rather than a particular sentence.
$hasNoDocs = $body -match 'no_documents'
$hasUnsani = $body -match 'nothing_sanitized'
$hasNoMatch = $body -match 'no_match'
Check 'E3 distinguishes "no indexed documents" from "none matched"' ($hasNoDocs -and $hasUnsani -and $hasNoMatch) `
    "these are different facts: one means the corpus is empty, one means nothing is sanitized yet, one means the query missed. A lawyer must be able to tell them apart, so each needs its own machine-readable reason (found: no_documents=$hasNoDocs nothing_sanitized=$hasUnsani no_match=$hasNoMatch)"

# ── E4: tells the caller what to do next ──────────────────────────────────────
$nextStep = $body -match '(?i)sanitiz|upload|ingest|index'
Check 'E4 empty response tells the caller what to do next' $nextStep `
    "an empty result with no next step leaves the caller stuck; the fix is usually 'upload and sanitize'"

# ── E5: non-empty results keep the old shape ──────────────────────────────────
$keepsShape = $body -match 'json\.dumps\(\s*results'
Check 'E5 non-empty results still return a plain JSON array' $keepsShape `
    "changing the success shape would break every existing consumer; only the empty case should change"

Write-Host ''
if ($failed -eq 0) {
    Write-Host "RESULT: $passed of $passed checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failed of $($passed + $failed) checks FAILED" -ForegroundColor Red
exit 1
