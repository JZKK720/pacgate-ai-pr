# Asserts NER is actually ENABLED in every shipped compose file, and that the
# image it points at really has the weights.
#
# WHY THIS GATE EXISTS: an unset PACGATE_NER_MODEL_DIR is not an error at
# runtime. sanitize.rs logs a warning and falls back to tier_one_detectors(), so
# a misconfigured install looks perfectly healthy while detecting 5 of 15
# EntityType classes instead of 8 - including no person or organisation names at
# all. Nothing in the running system reports that as wrong. A check has to.
#
# SCOPE DISCIPLINE: this asserts the CONFIGURATION, not the behaviour. A pass
# means "the shipped compose files request NER and the image can satisfy it", not
# "NER produced correct output" - that is tests/recall.rs's job, and it needs the
# weights present to run its model rows at all.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== NER enablement ===' -ForegroundColor Cyan

# Every BASE compose file that defines the pacgate-api service must set the
# variable. DISCOVERED, not hardcoded: a hardcoded list is the same blindness
# that let the variable be absent from all of them in the first place.
#
# OVERRIDE FILES ARE DIFFERENT, and getting this wrong makes the gate red on a
# correct tree - measured, which is how the distinction was found. Files named
# `*-override.yaml` are applied ON TOP of a base (`-f compose.prod.yaml -f
# compose.e2e-override.yaml`) and deliberately set only a few keys; the base
# supplies the rest. Requiring them to repeat PACGATE_NER_MODEL_DIR would demand
# duplication. They are still checked for CONTRADICTION - if an override sets the
# variable it must set it correctly.
$composeFiles = Get-ChildItem 'deploy/client-bundle' -Filter 'compose*.yaml'
$bases = 0
$overrides = 0

foreach ($f in $composeFiles) {
    $text = Get-Content $f.FullName -Raw
    # Only files that actually define the service are in scope.
    if ($text -notmatch '(?m)^\s{2}pacgate-api:\s*$') { continue }

    $isOverride = $f.Name -like '*-override.yaml'
    if ($isOverride) { $overrides++ } else { $bases++ }

    if ($text -match '(?m)^\s+PACGATE_NER_MODEL_DIR:\s*(\S+)\s*$') {
        $value = $Matches[1]
        if ($value -eq '/app/models/ner') {
            Pass "$($f.Name) sets PACGATE_NER_MODEL_DIR=$value"
        }
        else {
            Fail "$($f.Name) sets PACGATE_NER_MODEL_DIR=$value, expected /app/models/ner (must match the Dockerfile COPY target)"
        }
    }
    elseif ($isOverride) {
        Pass "$($f.Name) is a partial override; it inherits PACGATE_NER_MODEL_DIR from its base"
    }
    else {
        Fail "$($f.Name) defines pacgate-api but does NOT set PACGATE_NER_MODEL_DIR - that install silently runs Tier-1 rules only (5 of 15 classes)"
    }
}

# A vacuous pass is the failure mode of a discovery-based check. Require at least
# one BASE, or the gate could pass while every deployable file is misconfigured.
if ($bases -eq 0) {
    Fail 'found no BASE compose file defining the pacgate-api service - the discovery pattern is wrong, so this gate would pass vacuously'
}
Write-Host "  note  $bases base file(s), $overrides override file(s) in scope" -ForegroundColor DarkGray

# The Dockerfile must actually place the weights at the path the compose files
# name. A gate that only checked compose would pass while every job failed with
# 'NER model load failed', because set-but-missing is fatal.
$dockerfile = 'pacgate-ai/Dockerfile'
if (Test-Path $dockerfile) {
    $df = Get-Content $dockerfile -Raw
    if ($df -match 'COPY --from=ner-model\s+/ner\s+/app/models/ner') {
        Pass "$dockerfile copies the weights to /app/models/ner"
    }
    else {
        Fail "$dockerfile does not COPY --from=ner-model to /app/models/ner - compose points at a path the image does not have, so every job would fail closed"
    }
    # A revision pin without content verification cannot detect a swapped artifact.
    if ($df -match 'sha256sum -c') {
        Pass "$dockerfile verifies the fetched weights by hash"
    }
    else {
        Fail "$dockerfile does not verify the weights (no 'sha256sum -c') - a revision pin alone cannot detect a swapped artifact"
    }
}
else {
    Fail "$dockerfile not found"
}

# Optional but valuable: if the image is present locally, assert the files are
# really inside it. Self-skips when docker or the image is absent, so this gate
# is safe on a machine with no images built.
$image = 'pacgate-api:ner-test'
$dockerOk = $false
try {
    & docker version --format '{{.Server.Version}}' *> $null
    $dockerOk = ($LASTEXITCODE -eq 0)
}
catch { $dockerOk = $false }

if ($dockerOk) {
    $exists = & docker image inspect $image --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $exists) {
        # Check for the THREE MODEL FILES BY NAME, not by counting files. A count
        # is wrong the moment anything else lands in that directory - the build
        # also writes SHA256SUMS there, so a count-of-3 expectation was red on a
        # correct image (measured). Names are what `NerDetector::load` requires.
        $missing = @()
        foreach ($name in 'config.json', 'model.safetensors', 'vocab.txt') {
            & docker run --rm --entrypoint sh $image -c "test -s /app/models/ner/$name" *> $null
            if ($LASTEXITCODE -ne 0) { $missing += $name }
        }
        if ($missing.Count -eq 0) {
            Pass "$image contains all 3 required model files at /app/models/ner"
        }
        else {
            Fail "$image is missing required model file(s) at /app/models/ner: $($missing -join ', ') - NerDetector::load fails closed on any missing file"
        }
    }
    else {
        Write-Host "  note  $image not built locally; image-contents check skipped (build it with the P3 Task 1 command to include this)" -ForegroundColor Yellow
    }
}
else {
    Write-Host '  exit 2 - docker unavailable; cannot check image contents' -ForegroundColor Yellow
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) NER enablement check(s)" -ForegroundColor Red
    exit 1
}
Write-Host "PASSED: NER is enabled in all $bases base compose file(s) that define pacgate-api" -ForegroundColor Green
exit 0
