# Asserts the matter-memory concurrency guard is CONNECTED, not merely present.
#
# WHY: this guard was dead at THREE layers simultaneously and every unit test was
# green.
#   * the adapter sends If-Match          -> 6 passing tests
#   * check_revision compares correctly   -> 6 passing tests
#   * nothing incremented the counter     -> grep for 'revision.*+=' returned nothing
#   * nothing read the header             -> matters.rs had no HeaderMap at all
#   * check_revision had ZERO production call sites
# Reading any one layer suggested the mechanism was finished. Each piece was
# individually correct; the LINKS between them were missing.
#
# A source-level gate is blunt. It is also the only thing that can see the links,
# which is exactly what was wrong.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== matter memory guard ===' -ForegroundColor Cyan

$path = 'pacgate-ai/crates/pacgate-api/src/matters.rs'
if (-not (Test-Path $path)) {
    Fail "matters.rs not found at $path"
    Write-Host ''
    Write-Host "FAILED: cannot locate the handler; the gate would pass vacuously" -ForegroundColor Red
    exit 1
}

# Production code only. Searching the whole file matches the TESTS' own string
# literals and the function DEFINITIONS - which is how a P4 assertion managed to
# fail against correct code.
$src = Get-Content $path -Raw
$end = $src.IndexOf('#[cfg(test)]')
$prod = if ($end -lt 0) { $src } else { $src.Substring(0, $end) }

# 1. The increment exists. Without it the guard compares a constant to itself.
if ($prod -match 'fn\s+next_revision\s*\(') {
    Pass 'next_revision exists (the counter can advance)'
}
else {
    Fail 'no next_revision: nothing increments the revision, so check_revision compares a constant against itself and can never reject a stale caller'
}

$saveIdx = $prod.IndexOf('pub async fn save_matter_memory')
if ($saveIdx -lt 0) {
    Fail 'cannot find save_matter_memory - the gate would pass vacuously'
}
else {
    $save = $prod.Substring($saveIdx)

    # 2. The handler reads the header.
    if ($save -match 'headers:\s*HeaderMap') {
        Pass 'save_matter_memory accepts a HeaderMap'
    }
    else {
        Fail 'save_matter_memory does not accept a HeaderMap, so If-Match is discarded and 409 is unreachable'
    }

    # 3. The guard is CALLED. Defined-but-uncalled is the original defect.
    if ($save -match 'check_revision\(') {
        Pass 'save_matter_memory calls check_revision (the guard is connected)'
    }
    else {
        Fail 'save_matter_memory does not CALL check_revision - this was the original defect: defined, unit-tested, called from zero production sites'
    }

    # 4. The revision is assigned server-side.
    if ($save -match 'next_revision\(') {
        Pass 'save_matter_memory assigns the revision server-side'
    }
    else {
        Fail 'save_matter_memory never calls next_revision, so the stored revision is whatever the client sent - a stale client can reset the counter'
    }

    # 5. The write is atomic, and the truncating call is gone.
    if ($save -match 'write_atomic\(') {
        Pass 'save_matter_memory writes atomically'
    }
    else {
        Fail 'save_matter_memory does not write atomically: a crash mid-write leaves a truncated memory.json that cannot be parsed and has no backup'
    }
    if ($save -match 'std::fs::write\(&path') {
        Fail 'save_matter_memory still contains the truncate-then-write call'
    }
}

# 6. The adapter still opts in. A server-side guard nothing sends is useless.
$adapter = 'pacgate-adapters/python/pacgate_deerflow_adapter/storage.py'
if (Test-Path $adapter) {
    $a = Get-Content $adapter -Raw
    if ($a -match 'If-Match') {
        Pass 'the adapter still sends If-Match (the guard has a caller)'
    }
    else {
        Fail 'the adapter no longer sends If-Match, so the server-side guard is never exercised'
    }
}
else {
    Write-Host "  exit 2 - adapter not found at $adapter; cannot check the caller side" -ForegroundColor Yellow
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) memory-guard check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: the matter memory guard is connected at every link' -ForegroundColor Green
exit 0
