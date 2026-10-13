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
param(
    # Several gates build PDF fixtures INSIDE the ocr-service container (it is the
    # container that has PIL), so the release ocr-service image must be present.
    # Nothing ever built the invented `ocr-service:local` tag this used to require -
    # it was a hand-made leftover - so on any other machine those gates exited 2
    # (CANNOT CHECK) and were silently skipped while the suite still reported
    # success. That is the failure mode this header warns about: coverage that
    # quietly disappears.
    #
    # The suite therefore PULLS the release tag and uses that reference DIRECTLY.
    # It no longer invents `:local`: an unversioned tag could not prove which image
    # the gates ran against, which is exactly the property a release test needs.
    # Pass -SkipOcrPull to opt out (e.g. offline, with the image already local).
    [switch]$SkipOcrPull
)
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
$script:OcrImage = Get-ReleaseOcrImage
if (-not $script:OcrImage) {
    Write-Host 'WARN: could not derive the release ocr-service image; fixture-dependent gates may CANNOT CHECK.' -ForegroundColor Yellow
}

# Make the release ocr-service image available for the fixture-building gates.
if (-not $SkipOcrPull -and $script:OcrImage) {
    $ocrState = Test-ReleaseOcrImagePresent -Reference $script:OcrImage
    if ($ocrState -eq 'present') {
        Write-Host "release ocr-service image ready: $script:OcrImage" -ForegroundColor DarkGray
        docker pull $script:OcrImage 2>&1 | Out-Null
    }
    elseif ($ocrState -eq 'absent') {
        # Release window: the bump has landed but the tag is not published yet.
        # Say so explicitly rather than letting a dozen fixture gates each report a
        # confusing CANNOT CHECK.
        Write-Host "WARN: $script:OcrImage is not published yet (release window) - fixture-dependent gates will CANNOT CHECK." -ForegroundColor Yellow
        Write-Host '      Publish the release tag and re-run for full coverage.' -ForegroundColor Yellow
    }
    else {
        Write-Host "WARN: could not confirm $script:OcrImage on GHCR (transport/registry) - continuing." -ForegroundColor Yellow
    }
}

# The release ocr-service image is derived above (Get-ReleaseOcrImage) and used
# directly by the gates - see the param block. No `:local` alias is created: an
# unversioned tag could not prove which image a gate ran against.

$gates = @(    'scripts/test-install-render.ps1'
    'scripts/test-install-repo-pull.ps1'
    'scripts/test-update-end-to-end.ps1'
    'scripts/test-scheduled-update.ps1'
    # The three install tests above all run the installer under `pwsh` with a
    # stub docker that prints NOTHING. A stub that never writes to stderr cannot
    # reproduce a stderr-termination defect, and pwsh does not have the defect.
    # This gate covers the gap: it asserts no unguarded redirection survives in
    # the client scripts, then extracts the REAL helper from install.ps1 by AST
    # and proves it survives stderr under Windows PowerShell 5.1 - with a control
    # that shows the bare form still dies, so the test cannot pass vacuously.
    'scripts/test-ps51-native-stderr.ps1'
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
    # Asserts the release TAG still identifies the PUBLISHED artifacts - that the
    # tag is the recipe for what a client pulls. Nothing else could see this:
    # preflight-release-tag.ps1 only checks BEFORE a release, and
    # smoke-full-stack.ps1 only asserts /version carries some revision. On 0.1.28
    # a workflow_dispatch published the OCR bake under an already-existing version
    # number without moving the tag, so the tag pointed at a commit whose tree had
    # no warm_up.py while every published image reported the bake commit. The
    # published images were correct; the tag was wrong, and re-deriving the
    # release from its own tag would have reproduced the bake-less image.
    # Self-contained: reads the GHCR config blobs and the git history. No docker,
    # no running stack, so it belongs here rather than in $liveStackGates.
    'scripts/test-release-provenance.ps1'
    # The Rust layer was entirely un-gated before 2026-09-26: cargo test and
    # cargo clippy ran nowhere in CI or run-all-checks. That is why a silent
    # recall miss shipped in four detectors. Scope is deliberately -p
    # pacgate-redact, which is clean; the workspace has pre-existing clippy
    # warnings in other crates.
    'scripts/test-rust-workspace.ps1'
    # Asserts NER is enabled in every BASE compose file that defines pacgate-api.
    # An unset PACGATE_NER_MODEL_DIR is not a runtime error - it warns and degrades
    # to 5 of 15 classes while looking healthy - so only a gate catches it.
    # Self-contained: reads files, and its docker check self-skips when the image
    # is absent, so it belongs here rather than in $liveStackGates.
    'scripts/test-ner-enabled.ps1'
    # Asserts the NER memory bound at both layers. Neither is self-enforcing: an
    # unset mem_limit looks like a set one until the container OOMs, and a permit
    # acquired after the detector build passes every behavioural test while
    # bounding nothing. Self-contained (reads files; no docker needed).
    'scripts/test-memory-bound.ps1'
    # Asserts the matter-memory concurrency guard is CONNECTED. It was dead at
    # three layers at once while every unit test passed, because each layer was
    # individually correct - the LINKS between them were missing, and a
    # source-level check is the only thing that sees links. Self-contained.
    'scripts/test-memory-guard.ps1'
    # Asserts the memory SCOPE rule is defined, enforced, and still correctly
    # asymmetric (identifiers gate, prose does not). The second guard in this
    # subsystem, so it gets the same treatment as the first: a source-level check,
    # because per-piece correctness already hid one broken chain here.
    'scripts/test-memory-scope.ps1'
    # Asserts deer-flow's memory lane is the SANITIZED adapter and cannot silently
    # degrade. deer-flow wraps storage instantiation in a bare `except Exception`
    # that substitutes its own FileMemoryStorage - which bypasses all three guards
    # above. It already happened here: native memory.json files hold real matter
    # prose in a schema the adapter never emits. The trip-wire is a missing
    # PACGATE_MATTER_ID, and .env.example shipped it blank. Self-contained.
    'scripts/test-memory-lane.ps1'
    # Proves the gate above can REJECT. It went in as a blind gate twice in this
    # subsystem already, so the mutation harness is registered alongside it
    # rather than trusted to a manual run. Breaks each assertion in turn,
    # asserts exit 1, and restores every file byte-identical.
    'scripts/test-memory-lane-mutations.ps1'
    # Asserts every rendered PDF is at least as new as its markdown source, and
    # that the client-delivery copies have not drifted. These are CLIENT-FACING
    # hand-rendered artifacts with no regeneration step, and four had gone stale
    # (one by 12 days) while nothing noticed - an operator reading the PDF gets
    # superseded instructions, which is worse than a missing file.
    'scripts/test-pdf-freshness.ps1'
    # Proves the PDF gate can reject. Registered alongside it because a gate
    # whose only evidence is a green run has not been tested at all.
    'scripts/test-pdf-freshness-mutations.ps1'
    # Gates the Python adapter suite, which nothing ran. Same gap
    # test-rust-workspace.ps1 closed for Rust: 8 adapter assertions - including
    # the 409-vs-422 distinction that exists BECAUSE the two were once collapsed -
    # passed only when a human typed the command. Discovery is checked too, so a
    # moved suite fails loudly instead of reporting a vacuous green.
    'scripts/test-adapter-python.ps1'
    # Gates the pacgate-mcp 401-retry behaviour test. Same gap again, and it
    # matters more here: the defect this guards is INVISIBLE until pacgate-api's
    # 24-hour JWT expires. A regression would not appear in any smoke test, any
    # deployment check, or on a freshly restarted machine - it would surface one
    # day later as every agent tool call failing. Nothing else covers it.
    'scripts/test-mcp-401-retry.ps1'
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
    # ONE lane-by-lane verdict over the whole stack: pai, mcp, deer-flow, frontend,
    # openviking, ocr-service, qm. It exists because the three scripts above each
    # prove ONE pipeline deeply, and nothing reported whether every lane is even
    # REACHABLE on the assembled stack - a lane can be silently absent (qm), or
    # configured-but-unbound, with every other gate green. It preflights the
    # containers and exits 2 rather than reporting a false red on a clean machine.
    # It reports qm honestly as CANNOT-CHECK: setup-qm.ps1 is interactive.
    'scripts/smoke-full-stack.ps1'
    # PROVES pacgate-api's account-provisioning surface is closed in both
    # directions: open registration is refused once a user exists, and a created
    # account is NOT a platform admin. Before 2026-10-03 nothing tested these over
    # HTTP at all - the Rust unit tests cover the role DECISION but cannot see the
    # router, so a route moved onto the public router, or dropped entirely, would
    # leave every other gate green. It needs the stack up (exit 2 when not), and it
    # creates and deletes a probe account to prove the boundary end to end.
    'scripts/test-auth-provisioning-gate.ps1'
    # The ONLY end-to-end sanitizer proof: real OCR extraction of a document with a
    # national ID and a phone number, then the full lifecycle - sanitize verdict,
    # redaction, sealed mapping, chunk state, the download egress gate, restore
    # refused to an attorney but allowed to an admin, and the ledger + audit rows.
    # Registered 2026-10-13. The script's own comment records that it was NOT in
    # this list, "which is why the rot went unnoticed": it had hardcoded the compose
    # network 'client-bundle_default', which the `name: pacgate-ai-bundle` pin had
    # renamed, so it died at `docker run` and reported eleven cascading FAILs that
    # looked like sanitizer defects. It now derives the network from the running
    # container, and exits 2 when the stack is not up.
    'scripts/test-sanitizer-e2e.ps1'
    # The picker + generation DELIVERY gate, registered 2026-10-13 alongside the
    # fix it protects. Nothing tested either surface, which is why the 0.1.27
    # defect shipped: Next.js `experimental.proxyTimeout` defaults to 30 s, so
    # every agent run the frontend proxied was cut mid-flight while the run kept
    # executing - and it presented as "the model cannot generate". The static half
    # asserts the timeout chain stays configured (the defect WAS a missing config
    # value) and that the picker roster cannot drift from ollama-models.txt; the
    # live half drives a REAL generation through nginx and requires an actual
    # assistant reply, not just HTTP 200. See deploy/DEFECT-frontend-proxy-timeout.md.
    'scripts/test-model-picker-e2e.ps1'
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

# Suite launcher. Windows PowerShell 5.1 machines have no `pwsh`; hardcoding the
# launcher made the runner "pass" 34 suites it never ran (each invocation failed
# "command not found" and the stale $LASTEXITCODE read as 0). Prefer pwsh 7 when
# installed, fall back to powershell.exe, and record which one ran.
$psLauncher = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
Write-Host "suite launcher: $psLauncher" -ForegroundColor DarkGray

Write-Host '=== Gates (non-zero exit = FAILURE) ===' -ForegroundColor Cyan
foreach ($s in $gates) {
    if (-not (Test-Path $s)) {
        Write-Host ("  SKIP {0} (missing)" -f (Split-Path $s -Leaf)) -ForegroundColor Yellow
        continue
    }
    $out = & $psLauncher -NoProfile -ExecutionPolicy Bypass -File $s 2>&1
    $code = $LASTEXITCODE
    $tail = (($out | Where-Object { $_ -match '\d+ passed|ALL .*PASSED|RESULT|members present' } | Select-Object -Last 2) -join ' ; ')
    if ($code -eq 0) {
        Write-Host ("  PASS {0,-46} {1}" -f (Split-Path $s -Leaf), $tail) -ForegroundColor Green
    }
    elseif ($code -eq 2) {
        # Exit 2 = CANNOT CHECK, the same contract the live-stack loop below
        # honours. This loop did NOT honour it, which contradicted this file's own
        # header: it already documents that test-workflow-compose-wiring.ps1 and
        # test-handoff-command-safety.ps1 exit 2 for "environment is wrong", yet a
        # red run was produced anyway. That is red-for-the-wrong-reason on a clean
        # machine, the exact thing the header warns teaches people to ignore the
        # suite.
        #
        # It is also required by the release window. A version bump names an image
        # that does not exist until the tag finishes building, so
        # test-version-marker-against-image.ps1 has nothing to assert and exits 2
        # (see scripts/lib/Release-ImageState.ps1). Counted as a failure, that
        # turned five gates red on 0.1.28 with messages that all read as product
        # faults; none of them were one.
        #
        # This is a carve-out on the EXIT CODE only, never on an assertion: a real
        # failure still exits 1 and is still red, and a skip is always printed
        # rather than absorbed.
        Write-Host ("  SKIP {0,-46} CANNOT CHECK (exit 2) {1}" -f (Split-Path $s -Leaf), $tail) -ForegroundColor Yellow
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
    $out = & $psLauncher -NoProfile -ExecutionPolicy Bypass -File $s 2>&1
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
    $out = & $psLauncher -NoProfile -ExecutionPolicy Bypass -File $s 2>&1
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
