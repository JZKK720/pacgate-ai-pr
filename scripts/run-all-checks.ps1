# Run every local verification script and report a single pass/fail.
#
# TWO KINDS OF SCRIPT, and conflating them is a bug I hit on the first run:
#
#   GATES        exit 0 = pass, non-zero = a real failure. Nothing to interpret.
#   MEASUREMENTS exit code IS the answer. audit-aipc-update-coverage.ps1 exits 1
#                while plan 014 has open work, by design - that is it correctly
#                reporting "gaps remain", not a broken script.
#
# The first version put the measurement in the gate list, so this runner reported
# "1 of 9 SUITES FAILED" on a tree where nothing was broken. A runner that is red
# when nothing is wrong is a runner people learn to ignore - the same failure
# mode as the stale tools fixed earlier in this work. Measurements are now
# reported with their result and never fail the run; only GATES can.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$gates = @(
    'scripts/test-install-render.ps1'
    'scripts/test-install-repo-pull.ps1'
    'scripts/test-update-end-to-end.ps1'
    'scripts/test-scheduled-update.ps1'
    'scripts/test-workflow-namespace.ps1'
    # The workflow LIBRARY must be served, not the 10 built-in Rust definitions.
    # This one is STATIC - it reads compose files, needs no containers, no
    # credentials and no running stack - so it is safe as a gate.
    #
    # It exists because fixing one compose file and forgetting another is a real
    # event in this repo, not a hypothetical: the first fix landed only in
    # compose.prod.yaml, leaving compose.bundle.yaml carrying the ORIGINAL defect
    # (mount on deer-flow, no WORKFLOWS_DIR) with nothing objecting. It also
    # caught a dead workflows mount still sitting on deer-flow in prod.
    #
    # The RUNTIME counterpart (asserting the API actually returns 222) is in the
    # measurements list below, not here: it exits 2 for "cannot check" when the
    # stack is down, and a gate that goes red on a clean machine is the exact
    # failure mode this runner's header warns about.
    'scripts/test-workflow-compose-wiring.ps1'
    # Runs immediately after, and proves the guard above can actually FAIL. The
    # injection harness found two real defects a human review did not: a
    # case-insensitive -match that let a COMMENT satisfy the env check (so the
    # guard passed a file with the key deleted), and a dead workflows mount still
    # on deer-flow. Static and safe - it mutates a throwaway temp copy only.
    'scripts/test-workflow-compose-wiring-mutations.ps1'
    # Client-facing handoff docs must not instruct a deployable-but-wrong action.
    # Three docs told the on-site engineer to clone the FORK, and the AIPC
    # handbook asserted the two repos were "identical ... so either clone works".
    # That was true when written and became FALSE the next day, when 26 commits
    # landed on JZKK720 that the fork did not have - so a machine deployed from
    # the fork silently serves 10 built-in workflows instead of the firm's 222.
    # Static: reads markdown only, no stack required.
    'scripts/test-handoff-command-safety.ps1'
    # Structural validity, separate from the string-match checks above. The
    # 0.1.14 release produced NO images because a job-level `if:` referenced the
    # `env` context, which invalidated the entire workflow file - so every run
    # died before any job started, including the build job that had been working.
    # Grepping for strings cannot catch that: the bad line contains every word the
    # other checks look for. Validity is structural, so it gets its own gate.
    'scripts/check-workflow-validity.ps1'
    'scripts/test-workflow-validity-mutations.ps1'
    # Runs LAST of the workflow checks, and by design it MUTATES the workflow and
    # compose files between runs, restoring each time. Kept in the gate list
    # because a suite whose assertions cannot fail reads as coverage while
    # providing none - which has already happened three times in this work.
    'scripts/test-workflow-mutations.ps1'
    # Same reasoning for the qm checks. The port-coupling assertions guard R1 of
    # deploy/qm-pacgate/INTEGRATION-MAP.md, which was previously an assumption
    # nobody verified.
    'scripts/test-qm-mutations.ps1'
    'scripts/test-qm-restage.ps1'
    'scripts/test-staleness-probe.ps1'
    'scripts/audit-qm-bootstrap.ps1'
    'scripts/test-qm-sandbox-fingerprint.ps1'
    'scripts/test-version-marker.ps1'
    'scripts/test-version-marker-against-image.ps1'
    'scripts/verify-delivery-state.ps1'
    'scripts/verify-surviving-components.ps1'
    'scripts/check-installer-syntax.ps1'
)

$measurements = @(
    'scripts/audit-aipc-update-coverage.ps1'
    # Runtime counterpart of test-workflow-compose-wiring.ps1: asserts the API
    # actually SERVES the firm's library (222 workflows / 46 categories) rather
    # than the 10 built-ins. A measurement, not a gate, because it needs the
    # stack up and credentials - it exits 2 for "could not check" when either is
    # missing, and exit 2 must never be read as a failure of the CODE.
    'scripts/test-workflow-library-served.ps1'
)

$failed = @()

Write-Host '=== Gates (non-zero exit = FAILURE) ===' -ForegroundColor Cyan
foreach ($s in $gates) {
    if (-not (Test-Path $s)) {
        Write-Host ("  SKIP {0} (missing)" -f (Split-Path $s -Leaf)) -ForegroundColor Yellow
        continue
    }
    $out = & pwsh -NoProfile -File $s 2>&1
    $code = $LASTEXITCODE
    $tail = (($out | Where-Object { $_ -match '\d+ passed|ALL .*PASSED|RESULT|members present' } | Select-Object -Last 2) -join ' ; ')
    if ($code -eq 0) {
        Write-Host ("  PASS {0,-46} {1}" -f (Split-Path $s -Leaf), $tail) -ForegroundColor Green
    }
    else {
        Write-Host ("  FAIL {0,-46} exit={1} {2}" -f (Split-Path $s -Leaf), $code, $tail) -ForegroundColor Red
        $failed += $s
    }
}

Write-Output ''
Write-Host '=== Measurements (exit code is the RESULT, not a failure) ===' -ForegroundColor Cyan
foreach ($s in $measurements) {
    if (-not (Test-Path $s)) {
        Write-Host ("  SKIP {0} (missing)" -f (Split-Path $s -Leaf)) -ForegroundColor Yellow
        continue
    }
    $out = & pwsh -NoProfile -File $s 2>&1
    $code = $LASTEXITCODE
    $gaps = (($out | Where-Object { $_ -match 'covered by -Update|still needing a human' }) -join ' ; ')
    $label = if ($code -eq 0) { 'complete' } else { 'open work remains' }
    $c = if ($code -eq 0) { 'Green' } else { 'Yellow' }
    $clean = ($gaps -replace '\s+', ' ').Trim()
    Write-Host ("  {0,-46} {1}  [{2}]" -f (Split-Path $s -Leaf), $label, $clean) -ForegroundColor $c
}

Write-Output ''
if ($failed.Count -eq 0) {
    Write-Host ("ALL {0} GATES PASSED" -f $gates.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} GATE(S) FAILED:" -f $failed.Count) -ForegroundColor Red
$failed | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor Red }
exit 1
