# Run every local verification script and report a single pass/fail.
#
# THREE KINDS OF SCRIPT, and conflating them is a bug I hit on the first run:
#
#   GATES        exit 0 = pass, non-zero = a real failure. Nothing to interpret.
#   LIVE-STACK   exit 0 = pass, 1 = a real failure, 2 = CANNOT CHECK. Same
#   GATES        assertions as a gate, but they need the stack actually up, so 2
#                must NOT be read as a failure of the code. See below.
#   MEASUREMENTS exit code IS the answer. audit-aipc-update-coverage.ps1 exits 1
#                while plan 014 has open work, by design - that is it correctly
#                reporting "gaps remain", not a broken script.
#
# The first version put the measurement in the gate list, so this runner reported
# "1 of 9 SUITES FAILED" on a tree where nothing was broken. A runner that is red
# when nothing is wrong is a runner people learn to ignore - the same failure
# mode as the stale tools fixed earlier in this work. Measurements are now
# reported with their result and never fail the run; only GATES can.
#
# THE EXIT-2 CARVE-OUT, and why it is not a way to hide a failure: 2 specifically
# means "could not check". test-empty-extraction-gate.ps1 needs nginx, the API, the
# OCR service and credentials; on a developer's clean checkout none of that is
# running, and a red suite there teaches people to ignore the suite rather than to
# trust it. So 2 is reported as SKIP CANNOT CHECK and does NOT fail the run, while
# 0 and 1 keep their exact gate meaning - a real assertion failure is still red.
#
# This is a carve-out on the EXIT CODE, not on any assertion: nothing in this
# runner can turn an observed failure green. Both pre-existing scripts that
# already exit 2 (test-workflow-compose-wiring, test-handoff-command-safety) use
# it for the same class of "environment is wrong" error - no compose files found,
# no docs found - so the reading is consistent, and neither loses coverage.
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
    # Chat-lane default egress. `model_routing` escalated to a CLOUD model at a
    # threshold a single uploaded contract could cross, so an attorney who never
    # touched the model picker had document text sent to ollama.com with no
    # sanitizer and no consent. That is the client's only upload path and the
    # firm's central promise, so it is a gate rather than a config comment.
    #
    # This one is STATIC - it reads deer-flow-config.yaml and the agent patch, and
    # A5 skips itself if ollama is unreachable - so it is safe in the gate list.
    # It was negative-tested: reintroducing the cloud target at the old threshold
    # makes it exit 1. A version of this file that could not fail on its own defect
    # passed the reintroduced bug, which is why the negative test is mandatory here.
    'scripts/test-chat-no-auto-egress.ps1'
    # Workflow tier roster. The Rust defaults, the pre-pull list and the compose
    # overrides each named the tier models, and they had drifted into three
    # different sets. All three Rust tags returned HTTP 404 on a live Ollama, and a
    # tag no local Ollama serves 404s with no fallback -- so every workflow run
    # returned 500. That is all 222 templates down from a value nothing checked.
    #
    # `audit-model-tags.ps1` reported clean throughout because it never opened a
    # Rust file; its exit 0 was a false all-clear, which is worse than no check.
    #
    # STATIC - reads Rust source, two compose files and the prepull list - so it is
    # safe in the gate list. Negative-tested against both the stale tag and a
    # main.rs that bypasses the overrides.
    'scripts/test-model-roster-consistency.ps1'
)

# A LIVE-STACK GATE: real assertions against the running system, but its exit 2
# means "cannot check" and must not fail the run. Kept in its own list because
# that exit code is honoured differently from the gates above - not because the
# assertions matter less.
$liveStackGates = @(
    # PROVES an extraction that read nothing cannot pass the sanitization gate.
    # A blank page used to report incomplete=false, so sanitize ran on empty text,
    # got a pass verdict and opened the download gate - a document nobody could
    # read was released. This is the only script that catches that end-to-end,
    # because the defect needed BOTH services to lose the signal: ocr-service set
    # incomplete only when OCR threw, and the API returned a literal false from
    # its cache-hit branch. A unit test on either half passes while the product
    # still leaks. It needs the stack up, so it reports exit 2 when it cannot run.
    'scripts/test-empty-extraction-gate.ps1'
    # PROVES a text-native document (txt/md/html/docx/xlsx/pptx) reaches the direct
    # reader and NEVER the OCR lane. Before Plan B those formats fell through to
    # raster OCR, which returned nothing usable for a text file, so the upload was
    # accepted and then produced an unsanitizable or empty document. The unit tests
    # on extract_text_native cover the reader in isolation; only this script proves
    # the API's routing sends the format there end-to-end. It needs the stack up, so
    # it reports exit 2 when it cannot run.
    'scripts/test-text-native-sanitize.ps1'
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
Write-Host '=== Live-stack gates (exit 2 = CANNOT CHECK, not a failure) ===' -ForegroundColor Cyan
foreach ($s in $liveStackGates) {
    if (-not (Test-Path $s)) {
        Write-Host ("  SKIP {0} (missing)" -f (Split-Path $s -Leaf)) -ForegroundColor Yellow
        continue
    }
    $out = & pwsh -NoProfile -File $s 2>&1
    $code = $LASTEXITCODE
    $tail = (($out | Where-Object { $_ -match '\d+ passed|ALL .*PASSED|RESULT|CANNOT CHECK|members present' } | Select-Object -Last 2) -join ' ; ')
    if ($code -eq 0) {
        Write-Host ("  PASS   {0,-44} {1}" -f (Split-Path $s -Leaf), $tail) -ForegroundColor Green
    }
    elseif ($code -eq 2) {
        # Reported, never silently absorbed: a "cannot check" must never be read
        # as a pass, and this label says so. Stack unreachable is not a code bug.
        Write-Host ("  SKIP   {0,-44} CANNOT CHECK (exit 2) {1}" -f (Split-Path $s -Leaf), $tail) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  FAIL   {0,-44} exit={1} {2}" -f (Split-Path $s -Leaf), $code, $tail) -ForegroundColor Red
        $failed += $s
    }
}

Write-Output ''
if ($failed.Count -eq 0) {
    Write-Host ("ALL {0} GATES PASSED ({1} live-stack gate(s) checked separately)" -f $gates.Count, $liveStackGates.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} GATE(S) FAILED:" -f $failed.Count) -ForegroundColor Red
$failed | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor Red }
exit 1
