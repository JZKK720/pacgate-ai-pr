# Assert pacgate-mcp's ERROR results are ACTIONABLE, not just descriptive.
#
# WHY THIS EXISTS (plan 035 P1, idea from OpenDCAI/DataFlow-WebUI)
#
# DataFlow-WebUI's best idea is `PipelineValidationIssue`, which carries both
# `suggested_fields` and `repair_hint` (`backend/app/schemas/pipelines.py:120-135`).
# A validation error that only DESCRIBES the fault leaves an agent with nothing to
# change, so it re-issues the same call. Measured locally in the pacgate sessions:
# 1,303 model calls for 16 user messages. Some of that multiple is retry loops.
#
# The two pacgate failure shapes this gate locks down:
#
#   _laya_unavailable_result  -> previously "laya is not configured" and nothing
#                                else. Retrying is the natural (wrong) next move.
#   _laya_truncation          -> previously "the tail was dropped" and nothing
#                                else. The caller must re-derive how much to cut,
#                                and guessing wrong re-truncates silently.
#   _laya_withheld_result     -> names the substitute tool but not its arguments.
#
# WHAT IS ASSERTED
#   1. each failure shape carries a `repair_hint` object;
#   2. the truncation hint is COMPUTED from laya's own numbers (fraction_read,
#      suggested_max_chars, suggested_parts), not a constant string;
#   3. the arithmetic is right for a real case, and degrades to None rather than
#      guessing when laya did not report enough;
#   4. the unavailable hint says the retry is pointless (`retry: none`), because
#      "retry the same call" is the failure mode being prevented;
#   5. the withheld hint names the substitute tool AND its arguments.
#
# Exit 2 means CANNOT CHECK (source absent) and must never be read as a failure.
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
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $passed passed, $failed failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== pacgate-mcp repair hints ==='

if (-not (Test-Path $ServerFile)) { CannotCheck "server source not found: $ServerFile" }
$src = Get-Content $ServerFile -Raw -Encoding UTF8

# A key must be asserted as a JSON KEY (`"repair_hint":`), never as a naked word.
# Measured while mutation-testing this gate: renaming `"repair_hint":` to
# `"repair_tip":` left the suite GREEN, because the function's own comment says
# "Same principle as `repair_hint` above". A prose mention satisfied the assertion.
# That is the exact failure mode this suite keeps re-learning - a gate that greps
# for a concept instead of the construct cannot fail.
$KEY = '"repair_hint"\s*:'

# ── 1. each failure shape declares a repair_hint ─────────────────────────────
Write-Host '1. every failure shape carries a repair_hint' -ForegroundColor White
foreach ($fn in @('_laya_unavailable_result', '_laya_truncation', '_laya_withheld_result')) {
    # Bound the slice at the NEXT top-level def, and strip comments before asserting,
    # so a comment mentioning the key cannot satisfy the check.
    $m = [regex]::Match($src, "(?s)def\s+$fn\s*\(.*?\n(?=def |@mcp\.tool)")
    Check "$fn is defined" ($m.Success) "could not locate $fn"
    if ($m.Success) {
        $code = ($m.Value -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' } ) -join "`n"
        Check "$fn emits a repair_hint key" ($code -match $KEY) "no `\`"repair_hint\`":` key in $fn's code - the result describes the fault without naming a next step"
    }
}

# ── 2. the truncation hint is COMPUTED, not a constant ───────────────────────
Write-Host ''
Write-Host '2. the truncation hint is computed from laya''s numbers' -ForegroundColor White
$helper = [regex]::Match($src, '(?s)def\s+_truncation_repair_hint\s*\(.*?\n(?=def )')
Check 'a dedicated hint builder exists' ($helper.Success) 'no _truncation_repair_hint(...) - a literal string cannot tell the caller how much to cut'
if ($helper.Success) {
    $body = $helper.Value
    Check 'it divides read by total (fraction_read)' ($body -match 'fraction_read') 'no fraction_read'
    Check 'it reports the readable size (suggested_max_chars)' ($body -match 'suggested_max_chars') 'no suggested_max_chars'
    Check 'it reports how many parts are needed (suggested_parts)' ($body -match 'suggested_parts') 'no suggested_parts'
    # A constant would contain no arithmetic. Require both the parameters and a divide.
    Check 'the values are derived, not hardcoded' (($body -match 'read' ) -and ($body -match 'dropped') -and ($body -match '/')) 'the hint does not consume read/dropped - it cannot be computed'
}

# ── 3. behavioural check of the arithmetic ───────────────────────────────────
Write-Host ''
Write-Host '3. the arithmetic is correct and degrades safely' -ForegroundColor White
$w = Join-Path $env:TEMP ('hint-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $w -Force | Out-Null
try {
    # Extract the real source of the helper into a tiny harness so we test the
    # SHIPPED function, not a re-typed copy.
    $fnSrc = [regex]::Match($src, '(?s)def\s+_truncation_repair_hint\s*\(.*?(?=\ndef\s)').Value
    if (-not $fnSrc) { $fnSrc = $helper.Value }
    $harness = @"
import json
from typing import Any
$fnSrc

cases = [
    (400, 100, 400, 0.8, 2),   # read 400 of 500 -> 2 parts
    (400, 0,   None, None, None),
    (None, 100, None, None, None),
]
for read, dropped, want_max, want_frac, want_parts in cases:
    h = _truncation_repair_hint(read, dropped)
    print(json.dumps({
        'read': read, 'dropped': dropped,
        'max': h.get('suggested_max_chars'),
        'frac': h.get('fraction_read'),
        'parts': h.get('suggested_parts'),
        'want_max': want_max, 'want_frac': want_frac, 'want_parts': want_parts,
        'action': h.get('action'), 'has_retry': bool(h.get('retry')),
    }))
"@
    $harness | Set-Content (Join-Path $w 'h.py') -Encoding UTF8
    $out = (python (Join-Path $w 'h.py') 2>&1) -join "`n"
    $rows = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim().StartsWith('{')) { try { $rows += ($line | ConvertFrom-Json) } catch {} }
    }
    Check 'the helper runs' ($rows.Count -eq 3) "expected 3 cases, parsed $($rows.Count) :: $out"
    if ($rows.Count -ge 1) {
        $r0 = $rows[0]
        Check 'read 400 / dropped 100 -> suggested_max_chars 400' ($r0.max -eq 400) "got $($r0.max)"
        Check 'read 400 / dropped 100 -> fraction_read 0.8' ($r0.frac -eq 0.8) "got $($r0.frac)"
        Check 'read 400 / dropped 100 -> suggested_parts 2' ($r0.parts -eq 2) "got $($r0.parts)"
        Check 'the hint carries an action' ($r0.action -eq 'split_clause') "got '$($r0.action)'"
        Check 'the hint carries a retry instruction' ($r0.has_retry) 'no retry guidance'
    }
    if ($rows.Count -ge 2) {
        Check 'dropped=0 yields no split size (nothing was cut)' ($null -eq $rows[1].max) "got $($rows[1].max)"
    }
    if ($rows.Count -ge 3) {
        Check 'missing numbers yield no invented values' (($null -eq $rows[2].max) -and ($null -eq $rows[2].parts)) "got max=$($rows[2].max) parts=$($rows[2].parts)"
    }
}
finally {
    Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
}

# ── 4. the unavailable hint refuses to suggest a pointless retry ──────────────
Write-Host ''
Write-Host '4. an unconfigured service does not suggest retrying' -ForegroundColor White
$unavail = [regex]::Match($src, '(?s)def\s+_laya_unavailable_result\s*\(.*?\n(?=def )').Value
$unavailCode = ($unavail -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
Check 'the unavailable hint exists' ($unavailCode -match $KEY) "no `\`"repair_hint\`":` key"
Check 'it says the retry is pointless' ($unavailCode -match "retry\W+none|none\W+.*the call is correct") 'retry guidance missing or does not say "none" - a caller will re-issue the same call'
Check 'it names what must be configured' ($unavailCode -match 'PACGATE_LAYA_URL') 'does not name the env var to set'

# ── 5. the withheld hint names the substitute AND its arguments ──────────────
Write-Host ''
Write-Host '5. a language-withheld verdict names the substitute call' -ForegroundColor White
$withheld = [regex]::Match($src, '(?s)def\s+_laya_withheld_result\s*\(.*?\n(?=# -|def )').Value
$withheldCode = ($withheld -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
Check 'the withheld hint exists' ($withheldCode -match $KEY) "no `\`"repair_hint\`":` key"
Check 'it names pacgate_clause_risk' ($withheldCode -match 'pacgate_clause_risk') 'does not name the substitute tool'
Check 'it supplies the substitute arguments' ($withheldCode -match '"arguments"\s*:') 'names the tool but not its arguments - the caller re-derives them and often re-issues the same call'
Check 'it forbids retrying this tool' ($withheldCode -match 'do not retry') 'does not say not to retry this tool'

# ── 6. each timeout tunable is read once, so its default cannot diverge ──────
#
# WHY (measured 2026-11-28): PACGATE_SANITIZE_TIMEOUT was read into a module
# constant defaulting to 700, and ALSO re-read inline at one call site with a
# hardcoded default of 600. With the variable unset, that one path got 600s while
# every other path got 700s - and it is the path taken only when the first response
# has no readable body, so the shortfall stays invisible until a document is big
# enough to need the extra 100s (a full-document sanitize was measured at ~655s).
# An operator override also failed to reach it. The rule: a tunable is read ONCE.
Write-Host '6. each timeout tunable is read once, so its default cannot diverge' -ForegroundColor White
foreach ($var in @('PACGATE_SANITIZE_TIMEOUT', 'PACGATE_LAYA_TIMEOUT')) {
    $envReads = @(($src -split '\r?\n') | Where-Object { $_.TrimStart() -notmatch '^#' } |
        Where-Object { $_ -match ([regex]::Escape($var) + '\s*"') })
    Check "$var is read exactly once" ($envReads.Count -eq 1) `
        ("found $($envReads.Count): " + (($envReads | ForEach-Object { $_.Trim() }) -join ' | '))
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host "RESULT: $passed passed, $failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: pacgate-mcp failure results are actionable. ($passed passed)" -ForegroundColor Green
exit 0
