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
    # install.ps1 -Update executes the OLD body after refreshing the repo, because
    # PowerShell parses a whole script before running it. Any step defined BEFORE
    # the repo refresh was therefore undeliverable in a single update - the machine
    # would keep running the previous version's early steps. install.ps1 now hands
    # off once (hash-keyed) to the script the refresh just wrote; this gate proves
    # it, including a control that reproduces the loss.
    'scripts/test-installer-self-update.ps1'
    # Pacgate must NOT reconfigure a shared Ollama server. The machine-wide
    # context setting belongs to the operator (other tools use the same server),
    # so context is pinned per model via a derived tag instead. This gate fails
    # if the installer ever writes the app database again, and fails if the repo
    # defaults start naming a derived tag that no registry can serve.
    'scripts/test-ollama-context-scope.ps1'
    # tool_search deferral removes ~73% of the bound tool schema from EVERY prompt
    # (measured 10,645 -> 2,823 tokens). It was disabled because the middleware
    # told the model to call tool_search first and retry, which small local models
    # never completed. The patch promotes-and-executes in one turn. The static test
    # proves the code and the mount; the runtime test proves it actually runs.
    'scripts/test-tool-search-deferral.ps1'
    'scripts/test-deferred-tool-runtime.ps1'
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
    # Baked-weights integrity. 0.1.28 bakes the PP-OCRv4 det/rec/cls weights into
    # the ocr-service image, but both compose files went on mounting a
    # `paddleocr-models` volume over /root/.paddleocr - and a mount point SHADOWS
    # the image's directory, so anything the volume lacks is fetched from
    # paddleocr.bj.bcebos.com again. That is the CDN dependency the bake exists to
    # delete, and the cold path measured 269.9s against a 300s client timeout.
    # The volume was being defended as "harmless", which is true only for a volume
    # Docker has just created; measured on this box, a foreign volume made the
    # baked tree invisible. Both the mount and the now-unused volume declaration
    # were removed, and this gate asserts the PROPERTY that nothing in the tree
    # shadows the baked path. It also pins the two ways the bake could rot
    # silently: a warm_up.py that stops matching app.py's construction, and a
    # smoke lane flipped back to REQUIRING the mount. Red-checked by
    # reintroducing each of the three.
    #
    # STATIC - reads the Dockerfile, every compose in deploy/, and the smoke
    # script - so it needs no containers and is safe in the gate list. The live
    # counterpart is smoke-full-stack.ps1 lane 6.
    'scripts/test-ocr-bake-integrity.ps1'

    # Closes the loop on the two findings AUDIT-2026-10-14-v0.1.29.md recorded as
    # "found and recorded, not fixed", which then shipped for ten days: no compose
    # declared a healthcheck, and nothing armed the /initialize setup-token gate.
    #
    # Both were fixed by hand on 2026-10-14, and this gate is what keeps them fixed.
    # It is static by default (reads the rendered compose config; no containers
    # needed), so it is safe here. Pass -Live to also execute every rendered
    # healthcheck against its container.
    #
    # It earned its place immediately: its first run caught that a `git checkout --`
    # had silently reverted the setup-token edit, leaving a commit whose message
    # claimed a fix it did not contain.
    #
    # ASCII-ONLY by design, because the client AIPC has only Windows PowerShell 5.1
    # and 5.1 cannot parse a BOM-less script holding non-ASCII literals.
    'scripts/test-compose-healthchecks.ps1'

    # PROVES no literal credential value is tracked. Registered 2026-10-15, after
    # this exact script - which existed for a year - failed to notice a LIVE
    # pacgate-api password sitting in a PUBLIC repo. Two reasons it was blind, both
    # fixed before registering it here:
    #
    #   1. Its md-Password rule required a BOLD field name (`| **Password** |`).
    #      deploy/BENCHMARK-REPORT-2026-10-08.md used `| Password |` and a
    #      header-declared table with no per-row label at all. Neither matched.
    #   2. It had NO exit statement, so it always returned 0 and could not have
    #      failed CI even if the rule had fired. A detector that cannot fail is
    #      documentation, not a control.
    #
    # It is now shape-agnostic (bold/plain/labelled/unlabelled), exits 1 on findings,
    # and reads with -Encoding UTF8 - without which PowerShell 5.1 decodes a UTF-8
    # CJK label as mojibake and every CJK rule silently misses (measured: the same
    # planted credential scanned CLEAN, exit 0 on 5.1 and was found after the fix).
    # ASCII-only, so 5.1 can parse it.
    'scripts/detect-literal-credentials.ps1'
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
    # The DOCUMENT GENERATION lane, registered 2026-10-13. The picker gate above
    # proves a generation is DELIVERED; this one proves a workflow actually
    # PRODUCES a document. They are different failures: the picker defect lost the
    # reply in transit, while this lane can break in the workflow loader, the
    # persona composer, the AgentLoop, the LLM gateway, the docx tools, the matter
    # store, or the tenant storage root - and every one of those layers had a
    # separate defect this month.
    #
    # It asserts the whole chain and not the HTTP status: the execute call names
    # the workflow, a step reports generate_docx in tools_used, the run names a
    # document id, that id resolves through the API, the file EXISTS on disk at
    # DATA_DIR/storage_path, it is a real OOXML package with word/document.xml, and
    # the body is non-empty CJK. The last one is not decoration - the 0.1.26 defect
    # was a byte-slicing panic on Chinese text, so "HTTP 200" would have passed
    # while the product was broken.
    #
    # The workflow id is a Chinese overview-table workflow: short, and it
    # exercises the CJK round trip end to end.
    # The FORMAT COVERAGE lane, registered 2026-10-14. This is a legal workspace, so
    # "we can read and write every format we accept" is a compliance property, not a
    # feature. Coverage was previously split three ways with holes between them:
    # text-native-sanitize proved extraction+sanitization, ocr-extraction proved the
    # raster lane, document-generation proved DOCX only - and NOTHING proved
    # conversion for any format, or that the format lists agree with each other.
    #
    # It walks every accepted format through upload -> extract -> sanitize -> convert,
    # and - the part that had never been asserted anywhere - DOWNLOADS the document and
    # inspects the bytes. That last step is how the CRITICAL finding in §EGRESS was
    # made: after a `verdict=pass` sanitization, download still served the ORIGINAL file
    # with the raw identifiers, for all seven formats, because the sanitizer persists a
    # state flag rather than a sanitized artifact. See
    # deploy/DEFECT-sanitized-content-not-served.md.
    #
    # Two PDF kinds are covered deliberately: an image-only scan (which must go through
    # OCR) and a PDF with a real text layer (which the converter can read). They behave
    # differently, and an image-only PDF makes markitdown return ok=true with 0 chars.
    # The DOCUMENT GENERATION lane, registered 2026-10-13. The picker gate above
    # proves a generation is DELIVERED; this one proves a workflow actually
    # PRODUCES a document. They are different failures: the picker defect lost the
    # reply in transit, while this lane can break in the workflow loader, the persona
    # composer, the AgentLoop, the LLM gateway, the docx tools, the matter store, or
    # the tenant storage root - and every one of those layers had a separate defect
    # this month. See the header of that script for the full assertion list, and
    # deploy/DEFECT-agent-loop-max-rounds.md for the round-cap behaviour it pins.
    'scripts/test-document-generation-e2e.ps1'
    # officecli, registered 2026-10-14. It is enabled in deer-flow's extension config
    # and smoke counted it as one of "3 MCP servers enabled" - which was its ENTIRE
    # coverage. Counting a tool is not testing it, and this is the richest document tool
    # in the stack: its own description instructs the model to validate, check for
    # leftover placeholders and screenshot before delivering.
    #
    # This drives the real MCP stdio protocol (initialize -> tools/list -> tools/call)
    # and asserts a document it creates and edits: the tool is advertised WITH its
    # delivery-gate instructions, create/add/save produce a real OOXML file on disk,
    # validate reports zero errors, and the added text reads back out. That last
    # assertion is what separates "save returned success" from "the edit landed".
    #
    # Container-only: officecli exists only in deer-flow-pacgate, so it exits 2 when
    # that image is not present.
    'scripts/test-officecli-mcp.ps1'
    'scripts/test-format-coverage-e2e.ps1'
    # THE EDGES, registered 2026-10-18. Every other live-stack gate here tests a
    # COMPONENT or a public endpoint. Nothing tested the LANES BETWEEN components,
    # and that is exactly where three separate defects survived a green suite:
    # qm held a pacgate-api password the API rejected; qm's OPENVIKING_API_KEY
    # authenticated with nothing (no per-client key is registered in the service,
    # and OpenViking /health needs no key so the obvious check passed); and the qm
    # bridge ran as the deployment admin instead of a least-privilege account.
    #
    # `smoke-full-stack.ps1` above reports lane REACHABILITY, which is a different
    # question - a lane can be up and the credential on it dead. The decisive
    # difference is that this gate probes from the CALLER's side, inside its own
    # container with its own resident environment (E6, E7). A host-side probe
    # cannot prove those, because host and container do not share an environment -
    # which is precisely how a 401 on qm's copy stayed invisible.
    #
    # It also reports container PROVENANCE, after this box was found running a mix:
    # pacgate-api + openviking from compose.bundle.yaml, the rest from
    # compose.prod.yaml, while both declare `name: pacgate-ai-bundle` (same project).
    # Exits 2 when nothing is reachable, so a clean machine is not a false red.
    'scripts/test-lane-connectivity.ps1'
    # qm CURRENTNESS, registered 2026-10-18. `install.ps1 -Update` deliberately does
    # NOT restart the qm stack - "a restart of the co-working stack is user-visible
    # (qm is where staff work)" - which is the right call, and which means qm can sit
    # on stale definitions or a stale .env indefinitely while -Update reports success.
    # That is exactly what happened: qm held a pacgate-api password the API rejected,
    # through every update and a fully green suite.
    #
    # The answer is not to auto-restart a staff-facing stack. It is to make staleness
    # visible so the operator restarts when nobody is mid-session. This gate is
    # read-only - it starts nothing and restarts nothing.
    #
    # Q1 compares the staged deploy against tracked source (the -Update re-stage), by
    # content, so a silently-failed stage that leaves last release's definitions is
    # caught. Q3 compares each running container's LIVE env against its .env, which is
    # the check that catches a corrected file the container never picked up.
    # Exits 2 when qm is not deployed, since that is normal on a box without it.
    'scripts/test-qm-currentness.ps1'
    # BROWSER-ORIGIN and OAuth reachability, registered 2026-10-19.
    #
    # This is the gate whose ABSENCE let a client-facing auth breakage ship through
    # a fully green 40-gate suite. test-lane-connectivity.ps1 probes from INSIDE
    # containers, so it proves service-to-service lanes; it never sends a browser
    # Origin header. The auth gates therefore all passed while every sign-in from
    # another computer returned 403 - refused BEFORE authentication, so it read as
    # "blocked from OAuth" rather than as a wrong password.
    #
    # O1  every origin this machine advertises is not 403 (422/400/401 = reached auth)
    # O2  the frontend port :8090 is represented, not just the ingress port
    # O3  DEER_FLOW_TRUSTED_ORIGINS covers the machine and matches GATEWAY_CORS_ORIGINS
    # O4  both allowlists are substitution-derived from one value
    # O5  the OIDC discovery document advertises a browser-reachable issuer
    #
    # O5 exists because OAuth is a BROWSER redirect: the issuer is resolved on the
    # user's machine, so a localhost issuer sends every remote user to their own
    # loopback and sign-in can never complete - with no server-side error at all.
    # Token exchange keeps working via the in-cluster OIDC_TOKEN_ENDPOINT, which is
    # why a server-side probe passed while browser sign-in was dead.
    #
    # It sends a deliberately WRONG credential (creates no state) and exits 2 when
    # the stack is down, so a clean machine is not a false red.
    'scripts/test-origin-coherence.ps1'
)


$measurements = @(
    'scripts/audit-aipc-update-coverage.ps1'
    # Runtime counterpart of test-workflow-compose-wiring.ps1: asserts the API
    # actually SERVES the firm's library (222 workflows / 46 categories) rather
    # than the 10 built-ins. A measurement, not a gate, because it needs the
    # stack up and credentials - it exits 2 for "could not check" when either is
    # missing, and exit 2 must never be read as a failure of the CODE.
    'scripts/test-workflow-library-served.ps1'
    # Counts rows already mislabeled `sanitized` that still carry raw PII, and
    # names the affected documents. A MEASUREMENT rather than a gate because the
    # code fix is forward-only: an affected row needs a human to re-sanitize or
    # delete it, and no commit can turn this green. See
    # deploy/DEFECT-sanitized-content-not-served.md.
    'scripts/audit-sanitized-chunk-egress.ps1'

    # Auxiliary model lanes must be pinned BY NAME. Registered 2026-10-17, after
    # `title.model_name` was found unset in BOTH shipped configs - which sent title
    # generation to `models[0]`, a 25 GB `ollama ps` resident, on EVERY new thread.
    # On the 16 GB AIPC dGPUs that model does not fit, so it either OOMs or evicts
    # the model the user's chat is already on; the following call pays a full reload
    # and the 420 s stream idle watchdog eventually kills it.
    #
    # The memory lane was pinned for the SAME class of bug on 2026-10-07 (a 43k-token
    # loop on the single Ollama runner slot). The title lane was missed, and
    # `summarization` was missed too - measured the same day to fall back to
    # models[0] as well, because the middleware builds its own model and never
    # receives the chat model. Nothing in the repo asserted what an auxiliary lane
    # resolves to, so all three could regress silently.
    #
    # STATIC - reads the two tracked configs only, no containers and no YAML module
    # (the AIPCs ship Windows PowerShell 5.1, which has no ConvertFrom-Yaml).
    # Red-checked by reintroducing each pin's removal and by pinning a non-existent
    # model name; the summarization assertions correctly SKIP when that lane is
    # disabled, since deer-flow defaults `enabled` to false.
    'scripts/test-auxiliary-model-pins.ps1'

    # Capacity fitness, registered 2026-10-17. `audit-model-tags.ps1` already gates
    # tag OBTAINABILITY (HTTP 404 at runtime); nothing gated whether a tag can
    # actually RUN on the smallest supported client GPU, and those are different
    # failures - an un-fittable model pulls fine, lists fine, then spills to CPU or
    # evicts the chat model.
    #
    # The dev box for this project has a 96 GiB iGPU carve-out, so every over-cap
    # model runs there happily and the defect is invisible until it reaches a 16 GB
    # AIPC. That is precisely why this needs a gate rather than a review.
    #
    # PROMOTED TO A GATE 2026-10-19. It was registered here because "which models
    # the SHIPPED roster offers is a product decision that is still open". That
    # call is now made: a model larger than the target card cannot ship as a
    # default - on a 16 GB AIPC it does not error, it spills to CPU and presents
    # as a hang, which is the symptom that made these machines look broken.
    #
    # It is enforced through scripts/test-aipc-capacity-fit-strict.ps1 (registered
    # in $gates), not from here. This loop ignores exit codes by design, and the
    # script only fails under -Strict - so registering it here would have kept
    # reporting green while the 17 GB mid tier shipped. Kept in the measurements
    # list so the full size table is still printed on every suite run.
    'scripts/test-aipc-capacity-fit.ps1'
)

# Cross-stack credential agreement, registered 2026-10-17. This is the gate
# whose ABSENCE let a real divergence survive: the deployment has TWO .env files
# (client-bundle/.env and client-bundle/qm-pacgate/.env, separate compose projects
# at separate directories), and four keys are shared BY VALUE with nothing
# synchronising them. PACGATE_API_PASSWORD diverged, so qm-pacgate-core held a value
# that returns 401 against pacgate-api - proved by login probe, 200 vs 401.
#
# The whole 39-gate suite stayed green through it, because every existing test
# drives pacgate-api using client-bundle/.env and NOTHING crossed the stack
# boundary. Registered as a GATE, not a measurement: there is no judgement call
# here, shared secrets agreeing is a hard requirement.
#
# It exits 2 (CANNOT CHECK) on a fresh clone where neither .env exists - those
# files are gitignored and per-machine by design.
$gates += 'scripts/test-cross-stack-credentials.ps1'
# CROSS-MACHINE TRANSFER, registered 2026-10-19.
#
# The question "how do Matters, skills, tools, templates and recorded matters
# reach the other AIPC?" had NO answer in this repository - no export route, no
# import route, no replication script, no documentation. It was not broken, it
# had never been built, and a capability that does not exist passes every gate
# because nothing asserts that it should.
#
# This gate asserts the capability exists and stays coherent: the tool parses,
# every API route it calls is actually served by pacgate-api, it is keyed on the
# natural keys that exist (tenant slug, user email, matters.external_key) rather
# than on per-machine uuids, it never deletes a matter, and it moves no password
# hashes. Those are exactly the ways a sync tool fails destructively.
#
# It is static (no live stack needed), so it runs everywhere.
$gates += 'scripts/test-sync-capability.ps1'
# AIPC CAPACITY, promoted from a measurement to a gate 2026-10-19.
#
# The model roster decision was left open on purpose ("which models the SHIPPED
# roster offers is a product decision"). It is now made: a model larger than the
# target card cannot ship as a default. On a 16 GB AIPC an over-cap tag does not
# error - Ollama spills to CPU and the run presents as a hang, which is the exact
# symptom that made the AIPCs look broken.
#
# The capacity SCRIPT is still listed in $measurements so its full size table is
# printed on every run, but that loop ignores exit codes by design. This wrapper
# supplies -Strict and is what actually blocks.
$gates += 'scripts/test-aipc-capacity-fit-strict.ps1'
# SKILLS AND WORKFLOW TEMPLATES, registered 2026-10-19.
#
# These are declared must-haves on every machine, and NOTHING asserted them. The
# suite had gates for MCP (2) and workflows (7) but zero for skills, and zero that
# treated the template lane as an artifact set with a tracked source and a shipped
# copy that must agree.
#
# The trap it closes: the skills do NOT ship inside the digest-pinned sandbox
# image. Inspecting ghcr.io/jzkk720/pacgate-sandboxes at its pinned digest shows
# tools (pacgate-qm, firecrawl-qm, claude, codex) and not one SKILL.md. Skills
# arrive only through the compose bind-mount plus the tracked directory, so
# deleting or renaming that directory breaks every machine at once with no build
# failure and no error - the agent simply stops discovering a capability.
#
# K1 every tracked skill has SKILL.md with usable frontmatter (name+description)
# K2 the bind mount is present, since the image carries no skills
# K3 the tracked template set matches the shipped client-bundle copy
# K4 every template declares id, name and steps
#
# Static, so it runs everywhere. Red-checked two ways: deleting a SKILL.md and
# stripping another's frontmatter each make it exit 1.
$gates += 'scripts/test-skills-and-templates.ps1'

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
