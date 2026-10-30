# Guard: a BAKED patch and its bind mount must not silently diverge.
#
# WHY THIS EXISTS (measured 2026-10-30)
#
# Two of the 25 patches are both COPYed into the deer-flow image AND bind-mounted
# over the same destination at runtime:
#
#   patches/deer-flow-loop-detection.py     -> agents/middlewares/loop_detection_middleware.py
#   patches/deer-flow-run-recursion-cap.py  -> app/gateway/services.py
#
# The Dockerfile claims "the mount is what lets the fix ship without an image
# rebuild, and both point at the same file, so they cannot diverge." That was true
# when written and false the moment the source changed without a rebuild: measured
# on the 0.2.7 image, its baked copy still reads
#
#   config: dict[str, Any] = {"recursion_limit": 100}
#
# while the tracked source now defaults to `_PACGATE_MAX_RECURSION_LIMIT`. The
# running stack is CORRECT because the mount wins. The image is stale, and becomes a
# live regression the moment anything runs without the mount - a bare
# `docker run <image>`, a debug shell, a future compose lane that forgets the mount.
#
# WHAT IS ASSERTED
#   B1 every baked patch file exists
#   B2 every baked patch has a matching mount in BOTH compose lanes, so a stale bake
#      can only ever be masked - never live. A baked-only patch is a silent
#      time bomb; this is the assertion that matters.
#   B3 the mount target and the COPY destination agree, so the mount really does
#      shadow the bake
#   B4 (live, advisory) report whether the image's baked copy still matches the
#      tracked source, so a needed rebuild is visible instead of discovered later
#
# Exit 2 means CANNOT CHECK and must never be read as a failure.
[CmdletBinding()]
param(
    [string]$Image = 'ghcr.io/jzkk720/deer-flow-pacgate:0.2.8'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$dockerfile = 'deploy/deer-flow-pacgate/Dockerfile'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$script:passed = 0
$script:failed = 0
$script:warned = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function Note($m) { $script:warned++; Write-Host "  [warn] $m" -ForegroundColor Yellow }

Write-Host '=== baked patch vs mount parity ===' -ForegroundColor Cyan
Check 'the Dockerfile exists' (Test-Path $dockerfile) $dockerfile
if (-not (Test-Path $dockerfile)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$df = Get-Content $dockerfile -Raw

# Every `COPY deploy/client-bundle/patches/<file> <dest>` in the recipe.
$baked = @()
foreach ($m in [regex]::Matches($df, '(?m)^\s*COPY\s+deploy/client-bundle/patches/([A-Za-z0-9._-]+\.py)\s+(\S+)\s*$')) {
    $baked += [pscustomobject]@{ File = $m.Groups[1].Value; Dest = $m.Groups[2].Value.Trim() }
}

Write-Host ("         {0} baked patch(es): {1}" -f $baked.Count, (($baked | ForEach-Object { $_.File }) -join ', ')) -ForegroundColor DarkGray

if ($baked.Count -eq 0) {
    Write-Host '  [skip] no patches are baked into the image - nothing to reconcile.'
    Write-Host 'RESULT: 0 passed, 0 failed (nothing baked)'
    exit 0
}

foreach ($b in $baked) {
    # ── B1 ───────────────────────────────────────────────────────────────────
    $srcPath = "deploy/client-bundle/patches/$($b.File)"
    Check "B1 $($b.File) exists as a tracked patch" (Test-Path $srcPath) $srcPath

    # ── B2 / B3 ──────────────────────────────────────────────────────────────
    $expectedMount = "./patches/$($b.File):$($b.Dest)"
    foreach ($c in $composes) {
        $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
        # B2: the mount must exist at all.
        $hasMount = $body -match [regex]::Escape("./patches/$($b.File):")
        Check "B2 $($b.File) is mounted in $(Split-Path -Leaf $c)" `
              $hasMount `
              "a baked patch with no mount cannot be hot-fixed; the image copy becomes the only copy and goes stale"
        # B3: and it must land on the SAME destination the COPY wrote to, or the
        # mount does not shadow the bake.
        if ($hasMount) {
            Check "B3 $($b.File) mounts onto the same target the Dockerfile COPY wrote" `
                  ($body -match [regex]::Escape($expectedMount)) `
                  "expected './patches/$($b.File):$($b.Dest)'"
        }
    }
}

# ── B4 (live, advisory) ──────────────────────────────────────────────────────
# Report drift, do not fail on it: a baked copy that is stale but fully masked by a
# mount is a REBUILD REMINDER, not a running defect. Saying so plainly is better than
# either hiding it or turning the suite red for something that is currently harmless.
$imagePresent = $false
try {
    docker image inspect $Image 2>$null | Out-Null
    $imagePresent = ($LASTEXITCODE -eq 0)
} catch { $imagePresent = $false }

if (-not $imagePresent) {
    Write-Host ''
    Write-Host "  [skip] CANNOT CHECK: $Image is not present locally. Pull it for the drift report." -ForegroundColor Yellow
} else {
    foreach ($b in $baked) {
        $srcPath = "deploy/client-bundle/patches/$($b.File)"
        if (-not (Test-Path $srcPath)) { continue }
        $srcHash = (Get-FileHash $srcPath -Algorithm SHA256).Hash
        $bakedHash = (docker run --rm --entrypoint sh $Image -c "sha256sum $($b.Dest) 2>/dev/null | cut -d' ' -f1" 2>$null | Select-Object -First 1)
        if (-not $bakedHash) {
            Note "B4 could not hash $($b.Dest) inside $Image"
            continue
        }
        if ($bakedHash.Trim() -eq $srcHash) {
            Write-Host "  [PASS] B4 $($b.File): the image's baked copy matches the tracked source" -ForegroundColor Green
            $script:passed++
        } else {
            Note "B4 $($b.File): the image's baked copy is STALE (masked by the mount). Rebuild before relying on a bare 'docker run'."
        }
    }
}

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } elseif ($script:warned -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed, $($script:warned) warning(s)" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
