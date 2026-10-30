# Assert that a caller cannot lift the lead-agent recursion budget above our
# ceiling, and that the clamp is the one actually mounted.
#
# WHY THIS EXISTS (measured on this box, 2026-10-28)
#
# The chat UI sends `recursion_limit: 1000` on EVERY run (upstream
# src/core/threads/hooks.ts - a large-budget default meant for deep research).
# `build_run_config()` in the gateway defaulted the budget to 100 and then ran:
#
#     for k, v in request_config.items():
#         if k not in ("configurable", "context"):
#             config[k] = v          # <- overwrote the 100 with 1000
#
# LangGraph counts each graph SUPER-STEP against that number, so the deliberate
# 100 applied to API callers only while the UI silently ran at 1000. The result
# was not a caught loop but a total loss: on this box seven runs each spent all
# 1000 supersteps over ~16 minutes and 3M+ tokens, then failed with a bare
# `GraphRecursionError`. 12 of 16 failed runs were this error, at BOTH 100 and
# 1000 - so simply matching the two numbers would not have been enough; the
# budget needed a ceiling that a client cannot raise.
#
# The deepest SUCCESSFUL run here reached 694 super-steps (77 LLM calls), and the
# worst observed super-steps-per-LLM-call ratio is 5.45, so a legitimate run at
# the 138-call observed ceiling can need ~3780 super-steps. The ceiling is
# therefore 4000 - a runaway bound, not a budget - and env-tunable via
# DEERFLOW_MAX_RECURSION_LIMIT so a genuinely deeper workload can be raised
# without editing the image.
#
# An earlier draft used 500, reasoning that 1000 super-steps was ~100 LLM calls
# and 500 was 7x need. Reading langgraph's own per-checkpoint `step` counter
# disproved that and showed 500 would abort a run that actually succeeded. This
# gate now pins the number so the reasoning cannot silently regress.
#
# WHY THIS GATE ALSO CHECKS THE DEPLOYED FILE
#
# A correct patch file that is not mounted does nothing, and a correct mount onto
# a path upstream renamed silently lands on nothing. So this asserts the compose
# mount, the Dockerfile bake, and then imports the module FROM THE RUNNING
# CONTAINER and exercises it. The static checks alone would have passed while the
# container kept running the old code.
#
# Exit 2 means CANNOT CHECK (no container, or no Python in it) and must never be
# read as a failure of the code - the same contract run-all-checks.ps1 honours.

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:Passed = 0
$script:Failed = 0
function Assert-That {
    param([Parameter(Mandatory)] [bool]$Condition, [Parameter(Mandatory)] [string]$Name)
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Passed++ }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:Failed++ }
}

# A native command that writes to stderr is a TERMINATING error under Windows
# PowerShell 5.1 once stderr is redirected, so every capture goes through here.
function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script 2>&1 | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

$patch  = 'deploy/client-bundle/patches/deer-flow-run-recursion-cap.py'
$upath  = '/app/backend/app/gateway/services.py'
$prod   = 'deploy/client-bundle/compose.prod.yaml'
$bundle = 'deploy/client-bundle/compose.bundle.yaml'
$dockerfile = 'deploy/deer-flow-pacgate/Dockerfile'

Write-Host '=== run recursion cap ===' -ForegroundColor Cyan

# ── 1. the patch file itself ────────────────────────────────────────────────
Write-Host '1. the patch file' -ForegroundColor White
Assert-That (Test-Path $patch) "patch exists at $patch"
if (-not (Test-Path $patch)) {
    Write-Host ''
    Write-Host "RESULT: $($script:Passed) passed, $($script:Failed) failed" -ForegroundColor Red
    exit 1
}
$src = Get-Content -LiteralPath $patch -Raw

# It must be a FULL file, not a fragment: compose bind-mounts it straight over
# services.py, so anything less than the whole module breaks the gateway import.
Assert-That ($src -match '(?m)^def build_run_config\(') 'the patch is a whole file (defines build_run_config)'
Assert-That ($src -match '(?m)^_PACGATE_MAX_RECURSION_LIMIT\s*=\s*int\(') 'the ceiling is a named, env-tunable constant'
Assert-That ($src -match 'DEERFLOW_MAX_RECURSION_LIMIT') 'the ceiling can be raised without editing the image'
Assert-That ($src -match '"4000"') 'the default ceiling is 4000 - the measured runaway bound, not a budget'
Assert-That ($src -notmatch '"500"') 'the unsound 500 default has not come back'
Assert-That ($src -match 'if k == "recursion_limit":') 'the merge special-cases recursion_limit'

# The specific defect: recursion_limit was assigned straight through. Assert the
# clamp branch runs FIRST and `continue`s, so the plain `config[k] = v` on the last
# line can never be reached for recursion_limit. Checking for the mere absence of
# an assignment would be wrong: the plain assignment must survive for every OTHER
# key (model_name, agent_name, ...), so the ordering is what matters.
$clampAt  = $src.IndexOf('if k == "recursion_limit":')
$plainAt  = $src.LastIndexOf('config[k] = v')
$contAt   = if ($clampAt -ge 0) { $src.IndexOf('continue', $src.IndexOf('config[k] = requested')) } else { -1 }
Assert-That ($clampAt -ge 0 -and $clampAt -lt $plainAt) `
    'the recursion_limit clamp is evaluated before the plain pass-through'
Assert-That ($contAt -gt $clampAt -and $contAt -lt $plainAt) `
    'the clamp continues past the plain pass-through (so it cannot overwrite the ceiling)'

# ── 2. both compose lanes mount it, and the audit tracks it ─────────────────
Write-Host ''
Write-Host '2. the deployment actually applies it' -ForegroundColor White
foreach ($cf in @($prod, $bundle)) {
    $txt = if (Test-Path $cf) { Get-Content -LiteralPath $cf -Raw } else { '' }
    $leaf = Split-Path $cf -Leaf
    Assert-That ($txt -match [regex]::Escape("deer-flow-run-recursion-cap.py:$upath")) `
        "$leaf mounts the patch over services.py"
}
$dsrc = if (Test-Path $dockerfile) { Get-Content -LiteralPath $dockerfile -Raw } else { '' }
Assert-That ($dsrc -match [regex]::Escape("patches/deer-flow-run-recursion-cap.py $upath")) `
    'the Dockerfile recipe bakes it (a standalone run is covered too)'
$audit = Get-Content -LiteralPath 'scripts/audit-deer-flow-patches.ps1' -Raw
Assert-That ($audit -match 'deer-flow-run-recursion-cap\.py') `
    'the rebase audit maps the new patch to its upstream path'

# ── 3. live behaviour, read from the running container ──────────────────────
# Static checks above would stay green while the container ran the old module.
Write-Host ''
Write-Host '3. live behaviour in the running container' -ForegroundColor White
$running = Invoke-NativeCapture { docker ps --filter 'name=deer-flow' --format '{{.Names}} {{.Status}}' }
$healthy = $running -match '(^|\n)deer-flow\s+Up[^\n]*healthy'
if (-not $healthy) {
    Write-Host '  [skip] CANNOT CHECK: deer-flow is not running healthy.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "RESULT: $($script:Passed) passed, $($script:Failed) failed (live checks skipped)" -ForegroundColor Yellow
    if ($script:Failed -gt 0) { exit 1 } else { exit 2 }
}

$probe = @'
import sys
sys.path.insert(0, "/app/backend")
from app.gateway.services import build_run_config, _PACGATE_MAX_RECURSION_LIMIT
out = []
out.append("CEILING=%d" % _PACGATE_MAX_RECURSION_LIMIT)
def probe(label, req):
    out.append("%s=%s" % (label, build_run_config("gate", req, None).get("recursion_limit")))
probe("UI1000", {"recursion_limit": 1000})
probe("NONE", None)
probe("LOW50", {"recursion_limit": 50})
probe("STR900", {"recursion_limit": "900"})
probe("HUGE", {"recursion_limit": 1000000})
probe("JUNK", {"recursion_limit": "nonsense"})
print("\n".join(out))
'@
$probe | Out-File -Encoding ascii (Join-Path $env:TEMP 'rec_cap_gate_probe.py') -NoNewline
Invoke-NativeCapture { docker cp (Join-Path $env:TEMP 'rec_cap_gate_probe.py') deer-flow:/tmp/rec_cap_gate_probe.py } | Out-Null
$live = Invoke-NativeCapture { docker exec deer-flow /app/backend/.venv/bin/python /tmp/rec_cap_gate_probe.py }
Remove-Item (Join-Path $env:TEMP 'rec_cap_gate_probe.py') -ErrorAction SilentlyContinue

$ceiling = if ($live -match 'CEILING=(\d+)') { [int]$Matches[1] } else { 0 }
$ui      = if ($live -match 'UI1000=(\S+)')    { $Matches[1] } else { '' }
$none    = if ($live -match 'NONE=(\S+)')      { $Matches[1] } else { '' }
$low     = if ($live -match 'LOW50=(\S+)')     { $Matches[1] } else { '' }
$str     = if ($live -match 'STR900=(\S+)')    { $Matches[1] } else { '' }
$huge    = if ($live -match 'HUGE=(\S+)')      { $Matches[1] } else { '' }
$junk    = if ($live -match 'JUNK=(\S+)')      { $Matches[1] } else { '' }

Assert-That ($ceiling -ge 200) "the deployed ceiling is a real budget ($ceiling), not a stub"

# The clamp semantics, stated honestly:
#  - the UI's hardcoded 1000 is now UNDER the ceiling, so it passes through
#    unchanged. That is the correct outcome: 1000 is a proven-safe budget (runs
#    have succeeded inside it) and the ceiling exists to stop a caller asking for
#    an unbounded or runaway budget, not to shrink a working one.
#  - the ceiling must still BIND above itself, which is what stops a thrashing
#    run from being handed an arbitrarily large budget.
Assert-That ($ui -eq '1000') "the UI's 1000 sits under the $ceiling ceiling and passes through (got '$ui')"
# Pacgate 2026-10-30: this assertion used to PIN the defect. The comment above it
# called 100 "the documented server default" and treated a run that died at 100
# as correct behaviour. It is not: 100 super-steps is ~10 model calls, because
# nine middleware after_model/before_model hooks are each their own graph node.
# Measured deepest non-looping workloads on this stack: 5767, 3154 and 1589
# super-steps - a 100 default is below all three, and the old 500 ceiling was
# below all three as well. The default must therefore be the CEILING, so a caller
# that sends no config gets the same budget as one that sends the UI's 1000.
Assert-That ($none -eq '4000') "an API run with no config gets the ceiling, not a 100 floor (got '$none')"
Assert-That ($low -eq '50') "a caller asking for LESS than the default is still honoured (got '$low')"
Assert-That ($str -eq '900') "a string-typed 900 is coerced to an int, not dropped (got '$str')"
Assert-That ($huge -eq "$ceiling") "a runaway 1000000 request is clamped down to the $ceiling ceiling (got '$huge')"
$ceilingDefault = '4000'
Assert-That ($junk -eq $ceilingDefault) "a non-integer value keeps the default (the ceiling) instead of crashing (got '$junk')"

Write-Host ''
$colour = if ($script:Failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:Passed) passed, $($script:Failed) failed" -ForegroundColor $colour
if ($script:Failed -gt 0) { exit 1 } else { exit 0 }
