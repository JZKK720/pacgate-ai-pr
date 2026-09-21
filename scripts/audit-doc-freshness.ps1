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
    # SCOPE: the client-facing docs, not just the deployment guide. Scoping this
    # to one file is why the guard read GREEN while README.md/README-ZH.md and the
    # two handbooks still advertised the superseded `pacgate-ai` namespace at
    # 0.1.0/0.1.3/0.1.14 - one of those tags does not exist at all. A guard that
    # cannot see a file cannot fail on it.
    [string[]]$Docs = @(
        'deploy/DEPLOYMENT-GUIDE.md',
        'README.md',
        'README-ZH.md',
        'deploy/AIPC-DEPLOYMENT-HANDBOOK.md',
        'deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md',
        'deploy/SETUP-AND-OPERATIONS.md',
        'deploy/SETUP-AND-OPERATIONS-ZH.md'
    ),
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

# ── 6. namespace consistency ─────────────────────────────────────────────
#
# WHY THIS CHECK EXISTS - the previous five could not catch the bug they were
# meant to catch. README.md declared `ghcr.io/pacgate-ai/*` to be "the ONLY image
# namespace" and said `jzkk720` "publishes no images - mostly 404", which is the
# exact INVERSE of the truth and was misdirecting clients. None of the checks
# above flagged it:
#   * check 3 only asserts the doc mentions the current VERSION (0.1.17). The
#     README still mentioned 0.1.17 elsewhere, so it passed.
#   * check 5 only asserts referenced tags RESOLVE. `pacgate-ai/pacgate-api:0.1.3`
#     genuinely still resolves - it is just superseded - so it passed too.
# "A stale-but-working reference" is invisible to both. Only a namespace check
# sees it.
#
# The expected namespace is DERIVED from the compose pins (see the pattern note
# above: the semver tag is what excludes the digest-pinned third-party image).
# A doc may legitimately name the legacy namespace while describing HISTORY, so
# references within +/-3 lines of a history marker are exempt - the same
# close-proximity exemption idiom used by check 5 for non-existence claims.
Write-Host ''
Write-Host '=== 6. image namespace consistency ===' -ForegroundColor Cyan

$expectedNs = [regex]::Match($composeText,
    'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/[a-z0-9\-]+:\d+\.\d+\.\d+').Groups['ns'].Value
if (-not $expectedNs) {
    Fail 'cannot derive the expected image namespace from the compose pins'
} else {
    Pass "expected namespace derived from compose: $expectedNs"
    # BILINGUAL BY NECESSITY. Every other pattern in this file is English-only,
    # and on this repo that is a bug: README-ZH.md, AIPC-DEPLOYMENT-HANDBOOK-ZH.md
    # and SETUP-AND-OPERATIONS-ZH.md are real, maintained surfaces. A header
    # reading "历史发布表（保留以追溯，已被取代）" (historical, superseded) matched
    # nothing in an English-only marker set, so four deliberately-historical rows
    # were reported as stale. Same class of mistake as the CJK credential
    # encoding bug: assuming ASCII where the data is not ASCII.
    $historyMark = '(?i)(histor|legacy|superseded|deprecat|previous|renamed|plan 016|no longer|corrected 20|never published|not published|does not exist|do not exist|the \d+\.\d+\.\d+ era|when the namespace was|历史|已被取代|从未发布|不再发布|已弃用|追溯)'
    # Third-party namespaces are legitimate and never "stale". Keep this list
    # explicit rather than inferring it: a silent allowlist is how a check stops
    # checking. `v2` is NOT a namespace - it is the registry API path in URLs like
    # https://ghcr.io/v2/<repo>/manifests/<ref>, and it was a false positive
    # until this exclusion was added.
    $thirdParty = @('volcengine', 'bytedance', 'yc-software', 'v2')
    foreach ($doc in $Docs) {
        if (-not (Test-Path $doc)) { continue }
        $lines = @(Get-Content $doc)
        # SECTION STATE, not line proximity.
        #
        # A proximity window was tried first and was WRONG in both directions: at
        # +/-3 and +/-6 it flagged my own deliberately-historical table rows, and
        # at +/-8 it reached DOWN into the adjacent "Historical release table"
        # heading and exempted genuine staleness in the current table sitting just
        # above it. The two tables are adjacent, so no window can separate them.
        #
        # Instead: entering a heading that names history opens an exempt section,
        # and the next heading closes it. That is what "historical" actually means
        # in a document - a span of lines, not a radius.
        $headingRe = '^(#{1,6}\s|\*\*[^*]+\*\*\s*$|>\s*\*\*)'
        $inHistory = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # A line that NAMES history is itself a historical statement, so it is
            # exempt and it opens an exempt section. Checking this BEFORE the
            # heading test matters: my own correction notes are bold blockquotes
            # like "**`ghcr.io/jzkk720/*` is the ONLY ... `pacgate-ai` is a legacy
            # mirror**" which contain inline asterisks and so never matched the
            # `\*\*[^*]+\*\*\s*$` heading shape - they were reported as stale
            # while saying the opposite.
            if ($lines[$i] -match $historyMark) { $inHistory = $true; continue }
            if ($lines[$i] -match $headingRe) { $inHistory = $false; continue }
            if ($inHistory) { continue }

            $found = @([regex]::Matches($lines[$i], 'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/') |
                       ForEach-Object { $_.Groups['ns'].Value } |
                       Where-Object { $_ -ne $expectedNs -and $thirdParty -notcontains $_ } |
                       Select-Object -Unique)
            if ($found.Count -eq 0) { continue }

            Fail "$doc L$($i+1): names '$($found -join ', ')', expected '$expectedNs' (pins use it). Put it under a heading that names history if this is deliberate."
        }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $($script:failures) stale/missing reference(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: pin surfaces agree, docs are current, and every referenced tag resolves.' -ForegroundColor Green
exit 0
