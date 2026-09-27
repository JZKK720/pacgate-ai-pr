# Asserts the memory SCOPE rule is defined AND enforced AND still correctly shaped.
#
# WHY: this is the second guard in this subsystem at risk of the same failure - a
# correct rule that nothing calls. The If-Match guard was dead at THREE layers
# while six unit tests passed. A scope check is a comment until the handler calls
# it, and a scope check that refuses PROSE is a gate that gets disabled.
#
# The asymmetry check is the unusual part and the one that matters most here: if
# the scope check ever moves to the NER detectors, it starts refusing PersonName
# and OrgName, which would reject legitimate process summaries like "the firm
# reviewed the matter". That is how a gate gets turned off.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== memory scope ===' -ForegroundColor Cyan

# Production source only: searching the whole file matches the tests' own string
# literals and the function DEFINITIONS, which is how a P4 assertion managed to
# fail against correct code.
function Read-Production([string]$path) {
    $src = Get-Content $path -Raw
    $end = $src.IndexOf('#[cfg(test)]')
    if ($end -lt 0) { return $src }
    return $src.Substring(0, $end)
}

$scopePath = 'pacgate-ai/crates/pacgate-api/src/memory_scope.rs'
if (-not (Test-Path $scopePath)) {
    Fail 'memory_scope.rs not found: the scope rule is undefined'
}
else {
    $scope = Read-Production $scopePath

    if ($scope -match 'pub const MEMORY_MAX_BYTES') {
        Pass 'MEMORY_MAX_BYTES is defined (oversized content can be refused)'
    }
    else {
        Fail 'no MEMORY_MAX_BYTES: a payload holding matter content cannot be refused by size'
    }

    if ($scope -match 'pub fn check_memory_scope') {
        Pass 'check_memory_scope is defined'
    }
    else {
        Fail 'no check_memory_scope'
    }

    # The ASYMMETRY must stay. Identifiers gate; names must not.
    if ($scope -match 'tier_one_detectors') {
        Pass 'the check uses the Tier-1 detectors (identifiers, not names)'
    }
    else {
        Fail 'the check does not use tier_one_detectors'
    }
    if ($scope -match 'full_detectors|NerDetector') {
        Fail 'the scope check uses NER: it would refuse PersonName/OrgName and reject legitimate process summaries such as "the firm reviewed the matter"'
    }
    else {
        Pass 'the scope check does NOT use NER, so prose stays allowed'
    }
}

# The handler must CALL it, refuse with 422, and do so BEFORE touching the disk.
$matters = Read-Production 'pacgate-ai/crates/pacgate-api/src/matters.rs'
$saveIdx = $matters.IndexOf('pub async fn save_matter_memory')
if ($saveIdx -lt 0) {
    Fail 'cannot find save_matter_memory - the gate would pass vacuously'
}
else {
    $save = $matters.Substring($saveIdx)

    if ($save -match 'check_memory_scope\(') {
        Pass 'save_matter_memory calls check_memory_scope'
    }
    else {
        Fail 'save_matter_memory does NOT call check_memory_scope - the rule is a comment, which is how the If-Match guard came to be dead at three layers'
    }

    if ($save -match 'unprocessable') {
        Pass 'an out-of-scope memory is refused with 422'
    }
    else {
        Fail 'save_matter_memory does not refuse with 422'
    }

    $scopeCall = $save.IndexOf('check_memory_scope(')
    $fsAccess = $save.IndexOf('std::fs::')
    if ($scopeCall -ge 0 -and ($fsAccess -lt 0 -or $scopeCall -lt $fsAccess)) {
        Pass 'the scope check runs BEFORE any filesystem access'
    }
    else {
        Fail 'the scope check runs AFTER a filesystem access - a refused write could already have modified the file'
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-scope check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the memory scope rule is defined, enforced, and correctly asymmetric' -ForegroundColor Green
exit 0
