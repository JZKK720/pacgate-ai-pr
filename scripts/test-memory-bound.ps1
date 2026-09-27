# Asserts the NER memory bound exists at both layers.
#
# WHY: a sanitize job holds a 393 MiB detector set (measured 2026-09-27). With no
# bound, concurrency equals the Tokio worker count - 32 on the client hardware,
# which has no CPU cap in compose - so the worst case is 12.6 GiB and an
# out-of-memory kill.
#
# Neither bound is self-enforcing:
#   * an unset mem_limit is indistinguishable from a set one until the container
#     OOMs, and
#   * a permit acquired AFTER the detector build passes every behavioural test
#     while bounding nothing, because the allocation has already happened.
# So the ordering assertion checks SOURCE ORDER, which is the only thing that
# catches it.
#
# SCOPE: this asserts CONFIGURATION and SOURCE ORDER, not runtime behaviour.
# Proving the bound holds under concurrent load belongs to the live-stack suite.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== NER memory bound ===' -ForegroundColor Cyan

# The source BEFORE '#[cfg(test)]' only.
#
# This scoping is load-bearing and was found the hard way: a test that searched
# the whole file matched its OWN string literals and the `fn build_detectors`
# DEFINITION rather than the call site, so it failed against correct code. The
# same mistake here would make this gate assert nothing.
function Read-ProductionSource([string]$path) {
    $src = Get-Content $path -Raw
    $end = $src.IndexOf('#[cfg(test)]')
    if ($end -lt 0) { return $src }
    return $src.Substring(0, $end)
}

# 1. The in-process admission bound exists and is small.
$state = Read-ProductionSource 'pacgate-ai/crates/pacgate-api/src/state.rs'
$m = [regex]::Match($state, 'SANITIZE_MAX_CONCURRENT\s*:\s*usize\s*=\s*(\d+)')
if (-not $m.Success) {
    Fail 'state.rs does not define SANITIZE_MAX_CONCURRENT - concurrent sanitize jobs are unbounded, so peak memory is unbounded'
}
else {
    $n = [int]$m.Groups[1].Value
    if ($n -ge 1 -and $n -le 4) {
        Pass "SANITIZE_MAX_CONCURRENT = $n (peak detector memory ~$($n * 393) MiB)"
    }
    else {
        Fail "SANITIZE_MAX_CONCURRENT = $n; expected 1-4. At 393 MiB per job that is a $($n * 393) MiB peak, which is not a bound that helps"
    }
}

# 2. The permit is taken BEFORE the allocation. The ordering bug that passes every
#    functional test while bounding nothing.
$sanitize = Read-ProductionSource 'pacgate-ai/crates/pacgate-api/src/sanitize.rs'
$acquire = $sanitize.IndexOf('try_acquire_sanitize_slot')
# Match the CALL SIGNATURE, not the bare name: `fn build_detectors` sits near the
# top of the file, so the bare name matches the definition and the comparison
# would pass regardless of call order.
$build = $sanitize.IndexOf('build_detectors(state.config.ner_model_dir')

if ($acquire -lt 0) {
    Fail 'sanitize.rs never calls try_acquire_sanitize_slot - the admission bound is not wired in'
}
elseif ($build -lt 0) {
    Fail 'sanitize.rs never CALLS build_detectors - this gate cannot establish order from a definition, so it would pass vacuously'
}
elseif ($acquire -lt $build) {
    Pass 'the sanitize slot is acquired BEFORE build_detectors (order correct)'
}
else {
    Fail "the sanitize slot is acquired AFTER build_detectors (acquire at byte $acquire, call at byte $build) - it would bound nothing while passing every behavioural test"
}

# 2b. The permit must be held, not dropped. `let _ =` reads as correct in review.
if ($sanitize -match 'let _ = state\.try_acquire_sanitize_slot\(\)') {
    Fail 'the permit is bound with `let _ =`, which drops it immediately - the function would hold no slot at all'
}
elseif ($sanitize -match 'let _slot = state\.try_acquire_sanitize_slot\(\)') {
    Pass 'the permit is bound to `_slot` and held for the job'
}
else {
    Fail 'cannot find how the permit is bound; expected `let _slot = state.try_acquire_sanitize_slot()`'
}

# 3. Every BASE compose file defining the service caps memory. Same discovery rule
#    as test-ner-enabled.ps1: overrides inherit, so they need not repeat it, but a
#    contradiction is a failure.
$composeFiles = Get-ChildItem 'deploy/client-bundle' -Filter 'compose*.yaml'
$bases = 0
foreach ($f in $composeFiles) {
    $text = Get-Content $f.FullName -Raw
    if ($text -notmatch '(?m)^\s{2}pacgate-api:\s*$') { continue }
    $isOverride = $f.Name -like '*-override.yaml'
    if (-not $isOverride) { $bases++ }

    # Slice to THIS service's block, so a mem_limit on another service cannot
    # satisfy the check.
    $idx = $text.IndexOf("  pacgate-api:")
    $rest = $text.Substring($idx + 13)
    $nextSvc = [regex]::Match($rest, '(?m)^  [a-z]')
    $block = if ($nextSvc.Success) { $rest.Substring(0, $nextSvc.Index) } else { $rest }

    if ($block -match '(?m)^\s+mem_limit:\s*\S+') {
        $val = ([regex]::Match($block, '(?m)^\s+mem_limit:\s*(\S+)')).Groups[1].Value
        Pass "$($f.Name) sets mem_limit=$val on pacgate-api"
    }
    elseif ($isOverride) {
        Pass "$($f.Name) is a partial override; it inherits mem_limit from its base"
    }
    else {
        Fail "$($f.Name) defines pacgate-api but sets no mem_limit - an unbounded allocation other than the detector set would take the machine down instead of restarting the container"
    }
}
if ($bases -eq 0) {
    Fail 'found no BASE compose file defining pacgate-api - the discovery pattern is wrong, so this gate would pass vacuously'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-bound check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the NER memory bound holds at both layers' -ForegroundColor Green
exit 0
