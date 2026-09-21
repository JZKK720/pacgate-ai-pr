# Guard against stale documentation.
#
# WHY THIS EXISTS: deploy/DEPLOYMENT-GUIDE.md regressed TWICE. Plan 004 fixed it
# once, and by 2026-09-21 it again asserted 'every pin is 0.1.14' while the real
# release was 0.1.17, and named a build-input tag (`deer-flow-backend:2.1.0`) that
# does not exist on GHCR. Both classes of rot are mechanical, so a gate should
# catch them.
#
# SCOPE DISCIPLINE (learned by testing this guard against the real doc):
#   * Behaviour, not prose. An earlier version scanned every bare `0.1.x` and
#     failed on legitimate text: the `time` crate version (0.3.55), the historical
#     "reset from the 0.1.3 era", and the deliberate note that
#     `ghcr.io/jzkk720/qm-pacgate` was NEVER published. A guard that always fires
#     gets ignored, so prose is out of scope.
#   * Only two things are checked: (a) our pin surfaces agree with each other and
#     the doc mentions the current release, and (b) every image tag the doc uses as
#     a BUILD INPUT resolves. A doc may freely say an image does not exist - refs
#     within +/-2 lines of such a disclaimer are skipped.
#
# Exit codes: 0 = consistent and resolvable;  1 = stale/missing reference
#
# Usage:
#   pwsh -File scripts/audit-doc-freshness.ps1
#   pwsh -File scripts/audit-doc-freshness.ps1 -SkipRemote

[CmdletBinding()]
param(
    [string[]]$Docs = @('deploy/DEPLOYMENT-GUIDE.md'),
    [string]$Compose = 'deploy/client-bundle/compose.prod.yaml',
    [switch]$SkipRemote
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:failures = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }

Write-Host '=== 1. pin surfaces agree ===' -ForegroundColor Cyan
$cargo = Get-Content 'pacgate-ai/Cargo.toml' -Raw
$mv = [regex]::Match($cargo, '(?m)^version\s*=\s*"([^"]+)"')
if (-not $mv.Success) { Fail 'cannot read version from pacgate-ai/Cargo.toml'; exit 1 }
$authoritative = $mv.Groups[1].Value

$composeText = Get-Content $Compose -Raw
# @(...) IS LOAD-BEARING: Sort-Object -Unique collapses a single distinct value to
# a bare [string], and indexing a string yields its first CHARACTER - so [0]
# silently became "0" instead of "0.1.17". Same trap as
# scripts/detect-literal-credentials.ps1.
$composeVersions = @([regex]::Matches($composeText, 'ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:([0-9]+\.[0-9]+\.[0-9]+)') |
                     ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

Write-Host "  Cargo.toml  : $authoritative"
Write-Host "  compose     : $($composeVersions -join ', ')"

if ($composeVersions.Count -ne 1) {
    Fail "compose pins more than one version: $($composeVersions -join ', ')"
} elseif ($composeVersions[0] -ne $authoritative) {
    Fail "Cargo.toml ($authoritative) and compose ($($composeVersions[0])) disagree"
} else {
    Pass "pin surfaces agree ($authoritative)"
}

Write-Host ''
Write-Host '=== 2. pinned images (from compose) ===' -ForegroundColor Cyan
$pinnedImages = @([regex]::Matches($composeText, 'ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:[0-9]+\.[0-9]+\.[0-9]+') |
                  ForEach-Object { ($_.Value -split ':')[0] } | Sort-Object -Unique)
if ($pinnedImages.Count -eq 0) { Fail "no versioned image pins found in $Compose"; exit 1 }
$pinnedImages | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Host '=== 3. docs mention the current release ===' -ForegroundColor Cyan
foreach ($doc in $Docs) {
    if (-not (Test-Path $doc)) { Fail "doc not found: $doc"; continue }
    if ((Get-Content $doc -Raw) -match [regex]::Escape($authoritative)) {
        Pass "$doc mentions $authoritative"
    } else {
        Fail "$doc never mentions the current release $authoritative"
    }
}

Write-Host ''
Write-Host '=== 4. pinned images resolve at the release version ===' -ForegroundColor Cyan
if ($SkipRemote) {
    Write-Host '  (skipped -SkipRemote)' -ForegroundColor DarkGray
} else {
    foreach ($img in $pinnedImages) {
        $ref = "$img`:$authoritative"
        $o = & docker buildx imagetools inspect $ref --format '{{json .Manifest}}' 2>&1 | Out-String
        if ($o -match 'digest') { Pass $ref } else { Fail "$ref does not resolve (404/missing)" }
    }
}

Write-Host ''
Write-Host '=== 5. build-input tags named in docs resolve ===' -ForegroundColor Cyan
if ($SkipRemote) {
    Write-Host '  (skipped -SkipRemote)' -ForegroundColor DarkGray
} else {
    $instruct = '(?i)(^\s*#?\s*FROM\b|\bdocker\s+(build|pull|push)\b|^\s*#?\s*-?\s*image\s*:)'
    $disclaim = '(?i)(404|never published|not published|does not exist|do not exist|MISS\b)'

    foreach ($doc in $Docs) {
        if (-not (Test-Path $doc)) { continue }
        $lines = Get-Content $doc
        $checked = 0

        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch $instruct) { continue }

            # skip when the doc is describing non-existence. Window is ±4 lines:
            # the real doc puts the disclaimer two lines above the tag inside a
            # comment block, so a tighter window produced a false positive.
            $lo = [Math]::Max(0, $i - 4); $hi = [Math]::Min($lines.Count - 1, $i + 4)
            if ((($lines[$lo..$hi]) -join ' ') -match $disclaim) { continue }

            foreach ($mm in [regex]::Matches($lines[$i], 'ghcr\.io/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+')) {
                $ref = $mm.Value
                $checked++
                $o = & docker buildx imagetools inspect $ref --format '{{json .Manifest}}' 2>&1 | Out-String
                if ($o -match 'digest') { Pass $ref }
                else { Fail "$doc L$($i+1): build input $ref does not resolve" }
            }
        }
        if ($checked -eq 0) { Write-Host "  ($doc names no build-input tags)" -ForegroundColor DarkGray }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $($script:failures) stale/missing reference(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: pin surfaces agree, docs are current, and every referenced tag resolves.' -ForegroundColor Green
exit 0
