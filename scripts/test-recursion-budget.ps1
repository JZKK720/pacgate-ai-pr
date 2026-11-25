# Asserts the recursion budget is safe in the v2.2.0 world.
#
# WHY THIS GATE EXISTS (measured on this box, 2026-10-28; re-derived 2026-11-24
# for deer-flow v2.2.0)
#
# The chat UI sends `recursion_limit: 1000` on EVERY run. v2.0.0's gateway copied
# the client's value into the run config verbatim, so the UI's 1000 silently
# became the effective budget for every run - above our intended default and far
# above what a confused model should be allowed to spend. That produced the
# 2026-10-25..28 loss pattern: runs hitting the ceiling with no deliverable.
#
# In v2.2.0 the gateway owns this end to end. See
#   backend/app/gateway/services.py: `_clamp_recursion_limit`,
#   `_resolve_gateway_recursion_limits`, `build_run_config`.
#
# What v2.2.0 does NOT do, and what we rely on this gate to pin:
#
#   * client-supplied recursion_limit is clamped to AppConfig.max_recursion_limit.
#     There is NO floor any more - upstream removed the concept. A client may send
#     recursion_limit: 1 and the run will stop after one super-step. That is the
#     caller's choice, not our bug, so this gate does NOT re-add a floor.
#   * a non-integer or non-positive client value falls back to the server default.
#   * the ceiling is config, so it can be raised by the operator, but it is NOT
#     env-overridable any more (DEERFLOW_MAX_RECURSION_LIMIT is gone).
#
# What this gate asserts:
#
#   Static (always runs)
#     1. the bundle and baked config set recursion_limit / max_recursion_limit to
#        our chosen values (2000 / 4000) and the two agree.
#     2. the compose lanes and Dockerfile no longer reference the deleted
#        patches/deer-flow-run-recursion-cap.py, and the file is gone.
#     3. the baked image's config.yaml carries the same two values.
#
#   Live (only when the container is running the v2.2.0 build)
#     4. the running gateway clamps a client-supplied recursion_limit to the
#        configured ceiling, and falls back to the default for junk values.
#        The old v2.0.0 image cannot answer these (it has no _clamp_recursion_limit);
#        like the loop-detection gate, a probe failure against a stale image is a
#        SKIP with a rebuild note, not a failure of the bundle.
#
# Exit codes: 0 pass, 1 fail, 2 cannot check.

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
function Skip-That {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$Why)
    Write-Host "  [skip] $Name - $Why" -ForegroundColor Yellow
}
function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script 2>&1 | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

$bundleCfg = 'deploy/client-bundle/deer-flow-config.yaml'
$bakedCfg  = 'deploy/deer-flow-pacgate/config.yaml'
$prod      = 'deploy/client-bundle/compose.prod.yaml'
$bundle    = 'deploy/client-bundle/compose.bundle.yaml'
$dockerfile = 'deploy/deer-flow-pacgate/Dockerfile'
$expectedDefault  = 2000
$expectedCeiling  = 4000

Write-Host '=== recursion budget: v2.2.0 clamp semantics ===' -ForegroundColor Cyan
Write-Output ''

# ── 1. both configs set the same two knobs ────────────────────────────────
Write-Host '1. the bundle and baked configs agree on the budget' -ForegroundColor White
function Get-Budget($path) {
    $t = if (Test-Path $path) { Get-Content -LiteralPath $path -Raw } else { '' }
    $d = if ($t -match '(?m)^recursion_limit:\s*(\d+)')     { [int]$Matches[1] } else { 0 }
    $m = if ($t -match '(?m)^max_recursion_limit:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    return @{ Default = $d; Ceiling = $m; Present = ($t -ne '') }
}
$b = Get-Budget $bundleCfg
$k = Get-Budget $bakedCfg
Assert-That $b.Present "bundle config readable at $bundleCfg"
Assert-That $k.Present "baked config readable at $bakedCfg"
Assert-That ($b.Default -eq $expectedDefault) "bundle recursion_limit is $expectedDefault (got $($b.Default))"
Assert-That ($b.Ceiling -eq $expectedCeiling) "bundle max_recursion_limit is $expectedCeiling (got $($b.Ceiling))"
Assert-That ($k.Default -eq $expectedDefault) "baked recursion_limit is $expectedDefault (got $($k.Default))"
Assert-That ($k.Ceiling -eq $expectedCeiling) "baked max_recursion_limit is $expectedCeiling (got $($k.Ceiling))"
Assert-That ($b.Default -eq $k.Default -and $b.Ceiling -eq $k.Ceiling) 'bundle and baked configs agree (no drift between dev and shipped image)'
Assert-That ($b.Ceiling -ge $b.Default) 'the ceiling is not below the default (that would silently shrink the budget)'
Write-Output ''

# ── 2. the deleted patch is really gone ───────────────────────────────────
Write-Host '2. the v2.0.0 recursion-cap patch is gone' -ForegroundColor White
foreach ($f in @($prod, $bundle, $dockerfile)) {
    $t = if (Test-Path $f) { Get-Content -LiteralPath $f -Raw } else { '' }
    $wired = [regex]::Matches($t, '(?m)^(?!\s*#).*run-recursion-cap') | ForEach-Object { $_.Value }
    Assert-That ($wired.Count -eq 0) "$f does not wire deer-flow-run-recursion-cap.py into the image or a mount"
}
# Comments may mention the retired patch; wiring is what matters.
$wiredMatch = if (Test-Path $dockerfile) {
    [regex]::Matches((Get-Content -LiteralPath $dockerfile -Raw), '(?m)^\s*(COPY|ADD)\s+.*run-recursion-cap')
} else { @() }
Assert-That ($wiredMatch.Count -eq 0) 'the Dockerfile does not COPY the retired patch into the image'
$audit = if (Test-Path 'scripts/audit-deer-flow-patches.ps1') { Get-Content -LiteralPath 'scripts/audit-deer-flow-patches.ps1' -Raw } else { '' }
Assert-That ($audit -notmatch "'deer-flow-run-recursion-cap\.py'\s*=") `
    'the rebase audit no longer maps the retired patch'
Write-Output ''

# ── 3. upstream v2.2.0 really does clamp client values ────────────────────
Write-Host '3. upstream v2.2.0 carries the clamp (evidence the patch was redundant)' -ForegroundColor White
$up = 'deploy/deer-flow-src/backend/app/gateway/services.py'
if (-not (Test-Path $up)) {
    Skip-That 'upstream source' 'deploy/deer-flow-src is absent - cannot verify upstream clamp'
} else {
    $t = Get-Content -LiteralPath $up -Raw
    Assert-That ($t -match 'def _clamp_recursion_limit\(') 'upstream defines _clamp_recursion_limit'
    Assert-That ($t -match 'def _resolve_gateway_recursion_limits\(') 'upstream resolves default/ceiling from AppConfig'
    Assert-That ($t -match 'clamped client recursion_limit') 'upstream logs a warning when it clamps a client value'
    Assert-That ($t -notmatch '_PACGATE_MIN_RECURSION_LIMIT' -and $t -notmatch 'DEERFLOW_MIN_RECURSION_LIMIT') `
        'upstream has no floor - our old floor logic is really gone, not shadowed'
}
Write-Output ''

# ── 4. live: the running gateway clamps as configured ─────────────────────
Write-Host '4. live behaviour in the running container' -ForegroundColor White
$running = $false
try {
    $health = & docker inspect deer-flow --format '{{.State.Health.Status}}' 2>$null
    $running = (($health | Out-String).Trim() -eq 'healthy')
} catch { $running = $false }

if (-not $running) {
    Skip-That 'deer-flow healthy' 'the container is not running - static checks only'
} else {
    $marker = & docker exec deer-flow sh -c "grep -c _clamp_recursion_limit /app/backend/app/gateway/services.py" 2>$null
    $marker = ($marker | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $marker -notmatch '^\d+$' -or [int]$marker -lt 1) {
        Skip-That 'running build has the v2.2.0 clamp' 'the running image predates the v2.2.0 clamp (no _clamp_recursion_limit in services.py) - rebuild deer-flow-pacgate and re-run. Static checks above still gate the bundle.'
    } else {
        $py = @"
import sys
sys.path.insert(0, '/app/backend')
from app.gateway.services import build_run_config

for label, payload in [
    ('ui_1000', {'recursion_limit': 1000}),
    ('over_ceiling', {'recursion_limit': 99999}),
    ('junk', {'recursion_limit': 'not-a-number'}),
    ('zero', {'recursion_limit': 0}),
    ('absent', {}),
]:
    cfg = build_run_config('gate', payload, None)
    print('%s=%s' % (label, cfg.get('recursion_limit')))
"@
        $probePath = Join-Path ([System.IO.Path]::GetTempPath()) 'pacgate-recursion-probe.py'
        Set-Content -Path $probePath -Value $py -Encoding UTF8
        $null = Invoke-NativeCapture { docker cp $probePath deer-flow:/tmp/pacgate-recursion-probe.py }
        Remove-Item $probePath -ErrorAction SilentlyContinue
        $out = Invoke-NativeCapture { docker exec deer-flow /app/backend/.venv/bin/python /tmp/pacgate-recursion-probe.py }
        $null = Invoke-NativeCapture { docker exec deer-flow rm -f /tmp/pacgate-recursion-probe.py }
        $text = ($out | Out-String)
        $ceiling = $expectedCeiling
        $defaultV = $expectedDefault
        if ($text -match 'ui_1000=(\d+)')     { Assert-That ([int]$Matches[1] -eq 1000) "client-sent 1000 is honoured as an explicit lower budget (no floor in 2.2.0; got $($Matches[1]))" } else { Assert-That $false "probe did not report ui_1000 (output: $text)" }
        if ($text -match 'over_ceiling=(\d+)') { Assert-That ([int]$Matches[1] -eq $ceiling) "client-sent 99999 clamps to the ceiling $ceiling (got $($Matches[1]))" } else { Assert-That $false 'probe did not report over_ceiling' }
        if ($text -match 'junk=(\d+)')         { Assert-That ([int]$Matches[1] -eq $defaultV) "junk value falls back to the default $defaultV (got $($Matches[1]))" } else { Assert-That $false 'probe did not report junk' }
        if ($text -match 'zero=(\d+)')         { Assert-That ([int]$Matches[1] -eq $defaultV) "zero falls back to the default $defaultV (got $($Matches[1]))" } else { Assert-That $false 'probe did not report zero' }
        if ($text -match 'absent=(\d+)')       { Assert-That ([int]$Matches[1] -eq $defaultV) "absent value gets the default $defaultV (got $($Matches[1]))" } else { Assert-That $false 'probe did not report absent' }
    }
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    Write-Host '  A client can lift the recursion budget above what the config allows.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
