# Guard: a BAKED patch and its bind mount must not silently diverge.
#
# WHY THIS EXISTS
#
# A patch that is both COPYed into the deer-flow image and bind-mounted over the
# same destination at runtime can silently diverge: the mount wins at run time,
# so a stale bake goes unnoticed until the image is run without the mount.
#
# Historical note: this gate was written for the loop-detection and recursion-cap
# patches. Both were retired on 2026-11-24 because upstream v2.2.0 absorbed them
# (windowed, per-run keyed tool-frequency guard; clamping against
# AppConfig.max_recursion_limit). The check itself is generic: it re-derives the
# baked set from the Dockerfile, so it covers whatever is baked today.
#
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
    # Default to the tag the bundle pins rather than a literal. A hardcoded tag here
    # goes stale on every release AND the failure mode looks like a real finding:
    # measured 2026-10-05, this defaulted to 0.2.8 (thirty releases old) and warned
    # that two baked copies were STALE, while the actual 0.2.37 image matched all
    # three exactly. An advisory check that indicts a good image is worse than no
    # check, because it trains the reader to ignore the warning.
    [string]$Image = ''
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not $Image) {
    $bundle = 'deploy/client-bundle/compose.bundle.yaml'
    $pin = if (Test-Path $bundle) {
        Select-String -Path $bundle -Pattern 'image:\s*\S*deer-flow-pacgate:(?<v>\d+\.\d+\.\d+)' |
            Select-Object -First 1
    }
    if (-not $pin) {
        # Do NOT fall back to a literal. A literal reintroduces exactly the defect this
        # derivation exists to remove, and it would do so invisibly - the check would
        # run against an obsolete image and report its drift as a finding.
        Write-Host "  [skip] CANNOT CHECK: could not read a deer-flow-pacgate tag from $bundle" -ForegroundColor Yellow
        Write-Host "  Pass -Image explicitly. B4 stays unreported rather than reporting on the wrong image." -ForegroundColor Yellow
        exit 2
    }
    $Image = "ghcr.io/jzkk720/deer-flow-pacgate:$($pin.Matches[0].Groups['v'].Value)"
    Write-Host "  comparing against $Image (derived from the bundle pin)" -ForegroundColor DarkGray
}

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

# Every `COPY deploy/client-bundle/<src> <dest>` in the recipe, where <src> is a
# tracked file (patches/foo.py) or a tracked directory (memory-prompts). The
# mount side is asserted below exactly as the bake sees it: a file bake must
# have a file mount at the same destination; a directory bake must have a
# directory mount of the same source at the same destination.
$baked = @()
foreach ($m in [regex]::Matches($df, '(?m)^\s*COPY\s+deploy/client-bundle/(patches/[A-Za-z0-9._-]+\.py|memory-prompts)\s+(\S+)\s*$')) {
    $rel = $m.Groups[1].Value
    $kind = if ($rel -like 'patches/*') { 'file' } else { 'dir' }
    $baked += [pscustomobject]@{ File = $rel; Dest = $m.Groups[2].Value.Trim(); Kind = $kind }
}

Write-Host ("         {0} baked patch(es): {1}" -f $baked.Count, (($baked | ForEach-Object { $_.File }) -join ', ')) -ForegroundColor DarkGray

if ($baked.Count -eq 0) {
    Write-Host '  [skip] no patches are baked into the image - nothing to reconcile.'
    Write-Host 'RESULT: 0 passed, 0 failed (nothing baked)'
    exit 0
}

foreach ($b in $baked) {
    # ── B1 ───────────────────────────────────────────────────────────────────
    $srcRel = if ($b.Kind -eq 'file') { "deploy/client-bundle/$($b.File)" } else { "deploy/client-bundle/$($b.File)" }
    Check "B1 $($b.File) exists as a tracked asset" (Test-Path $srcRel) $srcRel

    # Mount fragment as it appears in compose: file bakes mount the file, a
    # directory bake mounts the directory.
    $mountSrc = if ($b.Kind -eq 'file') { "./$($b.File)" } else { "./$($b.File)" }
    $expectedMount = "${mountSrc}:$($b.Dest)"
    foreach ($c in $composes) {
        $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
        # B2: the mount must exist at all.
        $hasMount = $body -match [regex]::Escape("${mountSrc}:")
        Check "B2 $($b.File) is mounted in $(Split-Path -Leaf $c)" `
              $hasMount `
              "a baked asset with no mount cannot be hot-fixed; the image copy becomes the only copy and goes stale"
        # B3: and it must land on the SAME destination the COPY wrote to, or the
        # mount does not shadow the bake. Directory mounts need a trailing :ro
        # tolerantly: compose accepts "src:dst" and "src:dst:ro".
        if ($hasMount) {
            $pattern = [regex]::Escape($expectedMount) + '(:ro)?'
            Check "B3 $($b.File) mounts onto the same target the Dockerfile COPY wrote" `
                  ($body -match $pattern) `
                  "expected '$expectedMount' (optionally with :ro)"
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
        if ($b.Kind -eq 'file') {
            $srcPath = "deploy/client-bundle/$($b.File)"
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
        } else {
            # Directory bake: hash every file under it and compare as a set.
            $srcDir = "deploy/client-bundle/$($b.File)"
            if (-not (Test-Path $srcDir)) { continue }
            $srcFiles = Get-ChildItem -Recurse -File $srcDir | ForEach-Object {
                $_.FullName.Substring((Resolve-Path $srcDir).Path.Length + 1).Replace('\','/')
            }
            $mismatch = @()
            foreach ($rel in $srcFiles) {
                $srcHash = (Get-FileHash (Join-Path $srcDir $rel) -Algorithm SHA256).Hash
                $bakedHash = (docker run --rm --entrypoint sh $Image -c "sha256sum '$($b.Dest)/$rel' 2>/dev/null | cut -d' ' -f1" 2>$null | Select-Object -First 1)
                if (-not $bakedHash -or $bakedHash.Trim() -ne $srcHash) { $mismatch += $rel }
            }
            if ($mismatch.Count -eq 0) {
                Write-Host "  [PASS] B4 $($b.File): the image's baked directory matches the tracked source ($($srcFiles.Count) files)" -ForegroundColor Green
                $script:passed++
            } else {
                Note "B4 $($b.File): $($mismatch.Count) of $($srcFiles.Count) file(s) differ or are missing in the image (e.g. $($mismatch[0])). Rebuild before relying on a bare 'docker run'."
            }
        }
    }
}

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } elseif ($script:warned -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed, $($script:warned) warning(s)" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
