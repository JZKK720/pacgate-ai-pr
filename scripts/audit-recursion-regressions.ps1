# Audit: are deer-flow runs still dying on `Recursion limit reached`?
#
# WHY THIS EXISTS
#
# Six runs were killed by "Recursion limit of 1000 reached" between 2026-10-27 and
# 2026-10-28 (115-118 LLM calls, 3M+ tokens each). The fix shipped as a prompt
# change: convergence discipline in patches/deer-flow-prompt.py, because the
# killing runs were doing legitimate diverse work (259 bash calls, 259 DISTINCT
# commands) and no threshold separates them from successful runs.
#
# A prompt fix is not assertable the way a clamp is. It changes model behaviour,
# and only a run that is LONG ENOUGH to approach the old wall (~115 LLM calls over
# 12-19 minutes) can demonstrate it. Every gate in this repo uses short probes, so
# none of them can answer the question that actually matters here:
#
#     "has a run hit the recursion wall since the fix went live?"
#
# Without this audit that question is answered by somebody remembering to grep the
# database, which is not a control. This makes it a repeatable measurement.
#
# WHAT IT REPORTS
#   - runs since the recorded baseline, split success / recursion / other error
#   - the DEEPEST successful run since the baseline (LLM calls) - the single best
#     signal of whether the convergence prompt is holding
#   - every recursion error since the baseline, named with its timestamp#
# Exit codes
#   0 = no recursion error since the baseline (the fix is holding so far)
#   1 = a recursion error occurred AFTER the baseline (a real regression)
#   2 = cannot check (no database, or no runs since the baseline yet)
#
# Exit 2 is the correct answer on a quiet box: four trivial runs cannot prove
# anything about a wall that needs ~115 LLM calls to reach. Reporting 2 rather than
# 0 keeps "not exercised" from being mistaken for "verified".
#
# Usage:
#   pwsh -File scripts/audit-recursion-regressions.ps1
#   pwsh -File scripts/audit-recursion-regressions.ps1 -Baseline '2026-10-27 00:00:00'
#   pwsh -File scripts/audit-recursion-regressions.ps1 -DeepEnough 100 -Json
#
# This is a read-only measurement. It changes nothing and is safe on a schedule.

[CmdletBinding()]
param(
    # UTC timestamp, 'yyyy-MM-dd HH:mm:ss', of the moment the prompt fix went live.
    # Recorded when deer-flow was recreated with the patched prompt baked into the
    # bind-mounted file. Override it to audit a different window.
    [string]$Baseline = '2026-10-28 04:00:00',

    # A run at or above this many LLM calls counts as deep enough to have
    # meaningfully exercised the convergence prompt. The historical kills landed at
    # 114-118, and the deepest SUCCESS was 138, so 100 is a defensible floor.
    [int]$DeepEnough = 100,

    [string]$DbPath = 'deploy/client-bundle/data/deer-flow/data/deerflow.db',

    [switch]$Json
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not (Test-Path $DbPath)) {
    if ($Json) { '{"status":"cannot-check","reason":"deerflow.db not found"}' } else {
        Write-Host "`nCANNOT CHECK: run database not found: $DbPath" -ForegroundColor Yellow
        Write-Host '  Start the stack once so deer-flow creates its run database, then re-run.' -ForegroundColor DarkGray
    }
    exit 2
}

# Read-only. Python is used rather than a sqlite module because the repo already
# relies on python for its DB probes and it keeps this gate independent of any
# PowerShell SQL add-on being present on a client box.
$py = @'
import sqlite3, json, sys
db = sys.argv[1]
baseline = sys.argv[2]
try:
    c = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
    c.row_factory = sqlite3.Row
    rows = list(c.execute(
        "select status, llm_call_count, error, created_at from runs order by created_at"))
except Exception as e:
    print(json.dumps({"error": str(e)}))
    raise SystemExit(0)

def norm(s):
    return (s or "").replace("T", " ")[:19]

after = [r for r in rows if norm(r["created_at"]) >= baseline]
recursion = [r for r in after if "ecursion limit" in (r["error"] or "")]
other_err = [r for r in after
             if r["status"] != "success" and "ecursion limit" not in (r["error"] or "")]
succ = [r for r in after if r["status"] == "success"]
deep = [r for r in succ if (r["llm_call_count"] or 0) > 0]
deepest = max(((r["llm_call_count"] or 0) for r in deep), default=0)

print(json.dumps({
    "total_runs": len(rows),
    "since_baseline": len(after),
    "success": len(succ),
    "recursion": [{"at": norm(r["created_at"]), "calls": r["llm_call_count"]}
                  for r in recursion],
    "other_errors": [{"at": norm(r["created_at"]),
                      "calls": r["llm_call_count"],
                      "error": (r["error"] or "")[:80]} for r in other_err],
    "deepest_success_calls": deepest,
    "first_run_at": norm(after[0]["created_at"]) if after else None,
    "last_run_at": norm(after[-1]["created_at"]) if after else None,
}))
'@

$tmp = Join-Path $env:TEMP ("rec_audit_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".py")
try {
    Set-Content -Path $tmp -Value $py -Encoding UTF8
    $out = & python $tmp (Resolve-Path $DbPath).Path $Baseline 2>$null | Out-String
} finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

$line = @($out -split "`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
if (-not $line) {
    if ($Json) { '{"status":"cannot-check","reason":"python probe returned nothing"}' } else {
        Write-Host "`nCANNOT CHECK: the database probe returned no JSON. Is python on PATH?" -ForegroundColor Yellow
    }
    exit 2
}

$d = $line | ConvertFrom-Json
if ($d.error) {
    Write-Host "`nCANNOT CHECK: $($d.error)" -ForegroundColor Yellow
    exit 2
}

if ($Json) {
    [pscustomobject]@{
        baseline      = $Baseline
        total_runs    = $d.total_runs
        since_baseline= $d.since_baseline
        success       = $d.success
        recursion     = @($d.recursion).Count
        deepest_calls = $d.deepest_success_calls
        deep_enough   = ($d.deepest_success_calls -ge $DeepEnough)
    } | ConvertTo-Json -Depth 4
    if (@($d.recursion).Count -gt 0) { exit 1 }
    exit 0
}

Write-Host '=== deer-flow recursion regressions ===' -ForegroundColor Cyan
Write-Host "  baseline (fix went live): $Baseline"
Write-Host "  database: $DbPath"
Write-Host "  total runs on record:     $($d.total_runs)"
Write-Host "  runs since baseline:      $($d.since_baseline)"
if ($d.since_baseline -gt 0) {
    Write-Host "  window:                   $($d.first_run_at) -> $($d.last_run_at)" -ForegroundColor DarkGray
}
Write-Host ''

$recCount = @($d.recursion).Count
if ($recCount -eq 0) {
    Write-Host "  [PASS] no Recursion limit error since the baseline" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] $recCount run(s) hit the recursion wall AFTER the baseline" -ForegroundColor Red
    foreach ($r in $d.recursion) {
        Write-Host "         $($r.at)  llm=$($r.calls)" -ForegroundColor Red
    }
}

if (@($d.other_errors).Count -gt 0) {
    Write-Host "  [INFO] $((@($d.other_errors)).Count) other non-success run(s) - not this defect:" -ForegroundColor DarkGray
    foreach ($e in $d.other_errors) {
        Write-Host "         $($e.at)  llm=$($e.calls)  $($e.error)" -ForegroundColor DarkGray
    }
}

# The depth signal. A prompt fix cannot be demonstrated by short runs, so say so
# rather than implying the fix is proven.
$deepest = $d.deepest_success_calls
Write-Host ''
if ($deepest -ge $DeepEnough) {
    Write-Host "  [PASS] deepest successful run reached $deepest LLM calls (>= $DeepEnough) - the prompt was exercised near the old wall" -ForegroundColor Green
} else {
    Write-Host "  [INFO] deepest successful run since baseline: $deepest LLM calls (need >= $DeepEnough to exercise the fix)" -ForegroundColor Yellow
    Write-Host "         the historical kills landed at 114-118 calls, so no run since the fix has come near the wall yet." -ForegroundColor DarkGray
    Write-Host "         A quiet result here is NOT evidence the convergence prompt works - it is evidence it has not been tested." -ForegroundColor DarkGray
}

Write-Host ''
if ($recCount -gt 0) {
    Write-Host "RESULT: REGRESSION - $recCount recursion error(s) after the baseline." -ForegroundColor Red
    exit 1
}
if ($deepest -lt $DeepEnough) {
    Write-Host "RESULT: no regression, but NOT exercised - no run reached $DeepEnough LLM calls. Cannot claim the fix works yet." -ForegroundColor Yellow
    exit 2
}
Write-Host "RESULT: no recursion error after the baseline, and a run deep enough to test the fix succeeded." -ForegroundColor Green
exit 0
