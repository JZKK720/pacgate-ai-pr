# Report how far our pinned qm is behind upstream, and whether it is safe to move.
#
# WHY THIS EXISTS (2026-11-23)
#
# The qm pin drifted from 0.1.4 to six releases behind without anyone noticing, and the
# reason was structural: NOTHING in this repo ever asked upstream what the current version
# was. Every gate asked a local question - does the staged copy match the tracked copy, does
# the config agree with the pin's manifest, is the container healthy. All of them passed
# while the dependency aged.
#
# That is the same failure shape as every other defect found in this repo's gates: a check
# that is green about something nobody re-derives. A pin is meant to make a build
# reproducible; it is not meant to make the dependency invisible.
#
# WHAT THIS DOES
#
#   D1  our pin               (from deploy/qm-pacgate/package.json)
#   D2  upstream latest       (npm dist-tag "latest", i.e. the STABLE channel - not "next")
#   D3  releases behind       (semver distance, so "we are 6 behind" is a number, not a vibe)
#   D4  whether the bump is CONFIG-COMPATIBLE - the only question that decides the cost
#
# D4 is the one that matters. The upgrade from 0.1.4 is not "change the number": upstream
# rebuilt the service topology (5 services -> 2), so `qm check` rejects our config and
# deploy/client-bundle/setup-qm.ps1 aborts the client install on that failure. This script
# reports that as COMPATIBLE or NEEDS-MIGRATION per candidate version, so the decision is
# made from evidence rather than from a version number.
#
# EXIT CODES. This is a REPORT, not a gate that can fail:
#   0 = pin is current, or the drift is reported
#   2 = cannot check (no network / npm unavailable). Never read as "current".
#
# It is deliberately non-blocking. A newer upstream release must not turn the suite red -
# that would be a gate failing on someone else's release schedule, which teaches people to
# ignore red. The suite's job is to make the drift VISIBLE; choosing when to move is a
# decision, and it belongs to the team.

[CmdletBinding()]
param(
    [string]$DeploymentDir = '',
    # Check every published version rather than only the latest two. Slower (npm install
    # per version) but answers "is there ANY version we can take cheaply?".
    [switch]$AllVersions
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DeploymentDir) { $DeploymentDir = Join-Path $repoRoot 'deploy/qm-pacgate' }

$passed = 0; $warnings = 0
function Ok($m) { $script:passed++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function Warn($m) { $script:warnings++; Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host '=== qm upstream drift (are we stuck on an old qm?) ==='

$pkgPath = Join-Path $DeploymentDir 'package.json'
if (-not (Test-Path -LiteralPath $pkgPath)) {
    Write-Host "SKIP: CANNOT CHECK - $pkgPath not found" -ForegroundColor Yellow
    exit 2
}

$pinned = ([regex]::Match((Get-Content -LiteralPath $pkgPath -Raw),
    '"@yc-software/qm"\s*:\s*"(?<v>\d+\.\d+\.\d+)"')).Groups['v'].Value
if (-not $pinned) {
    Write-Host "SKIP: CANNOT CHECK - no @yc-software/qm version in $pkgPath" -ForegroundColor Yellow
    exit 2
}
Write-Host ("         pinned: {0}" -f $pinned) -ForegroundColor DarkGray

# ── D2. Upstream STABLE. `latest` is the stable channel; `next` is a prerelease. ────────
# Reading `next` here would report a GitHub prerelease as "the latest", which is exactly
# how a team gets pushed onto an unstable line by a status check.
$distTags = $null
try {
    $raw = & npm view '@yc-software/qm' dist-tags --json 2>$null | Out-String
    if ($LASTEXITCODE -eq 0 -and $raw.Trim()) { $distTags = $raw | ConvertFrom-Json }
} catch { }
if (-not $distTags -or -not $distTags.latest) {
    Write-Host 'SKIP: CANNOT CHECK - could not read npm dist-tags (offline?)' -ForegroundColor Yellow
    exit 2
}

$latest = $distTags.latest
$nextTag = $distTags.next
Write-Host ("         upstream stable: {0}{1}" -f $latest,
    $(if ($nextTag) { "  (prerelease 'next': $nextTag)" } else { '' })) -ForegroundColor DarkGray

if ($pinned -eq $latest) {
    Ok "pin $pinned is the current stable upstream release"
    Write-Host ''
    Write-Host "RESULT: qm is current. ($passed passed, $warnings warning(s))" -ForegroundColor Green
    exit 0
}

# ── D3. How far behind? Compare numerically, not by string. ─────────────────────────────
function ConvertTo-Ver([string]$v) {
    # Strip any prerelease suffix first: [version] cannot parse "0.1.19-rc.1", and a
    # prerelease tag appearing in the list would otherwise cast-fail the whole count.
    $core = ($v -replace '-.*$', '')
    $p = $core -split '\.'
    if ($p.Count -lt 3) { return [version]::new([int]$p[0], [int]$p[1], 0) }
    return [version]::new([int]$p[0], [int]$p[1], [int]$p[2])
}
$pinVer = ConvertTo-Ver $pinned
$latestVer = ConvertTo-Ver $latest

# The comparison must DISCRIMINATE, or a report that always says "current" would pass.
# Exercised synthetically so it cannot expire as upstream moves - the same lesson
# test-staleness-probe.ps1 records about its own fixture-based negative case.
function Test-IsBehind([version]$pin, [version]$latest) { return ($latest -gt $pin) }
if (-not (Test-IsBehind ([version]'0.1.4') ([version]'0.1.18'))) {
    Warn 'drift comparison FAILED its own positive case (0.1.4 vs 0.1.18 should be behind)'
}
if (Test-IsBehind ([version]'0.1.18') ([version]'0.1.18')) {
    Warn 'drift comparison FAILED its own negative case (0.1.18 vs 0.1.18 must not be behind)'
}

$behind = Test-IsBehind $pinVer $latestVer

if ($behind) {
    # Count published releases between the pin and stable, inclusive of stable.
    #
    # ConvertFrom-Json on a JSON array returns the elements, but wrapping the pipeline
    # in @() first produces a SINGLE item (the array object) - count=1, and the loop below
    # then iterated over the raw JSON text. Assign first, wrap second.
    $all = @()
    try {
        $rawAll = & npm view '@yc-software/qm' versions --json 2>$null | Out-String
        if ($LASTEXITCODE -eq 0 -and $rawAll.Trim()) {
            $parsed = $rawAll | ConvertFrom-Json
            $all = @($parsed | ForEach-Object { [string]$_ })
        }
    } catch { }
    $between = @($all | Where-Object {
        $v = $_ -replace '-.*$', ''
        (ConvertTo-Ver $v) -gt $pinVer -and (ConvertTo-Ver $v) -le $latestVer
    })
    Warn ("pin {0} is behind upstream stable {1} by {2} release(s)" -f $pinned, $latest, $between.Count)
    Info ("candidates: " + (($between | ForEach-Object { $_ -replace '-.*$','' } |
        Sort-Object { ConvertTo-Ver $_ } -Unique | ForEach-Object { $_.ToString() }) -join ', '))
}
else {
    Ok "pin $pinned is not behind upstream stable $latest"
    Write-Host ''
    Write-Host "RESULT: qm is current. ($passed passed, $warnings warning(s))" -ForegroundColor Green
    exit 0
}

# ── D4. Is the bump CONFIG-COMPATIBLE? The only question that sets the cost. ────────────
#
# `qm check` against OUR config is the honest test: it is the same command
# setup-qm.ps1 runs, and it aborts the client install when it fails. Comparing version
# numbers would not show that upstream renamed the topology.
$cfg = Join-Path $DeploymentDir 'qm.config.jsonc'
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("qmdrift-{0}" -f [guid]::NewGuid().ToString('N'))
$verdict = 'unknown'
try {
    if (-not (Test-Path -LiteralPath $cfg)) {
        Info 'cannot run the compatibility probe: qm.config.jsonc not found'
    }
    else {
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        Copy-Item -LiteralPath $cfg -Destination (Join-Path $sandbox 'qm.config.jsonc') -Force
        # Must run FROM the sandbox: `qm check` looks for qm.config.jsonc in the current
        # directory, so invoking it from the repo root reports "no qm.config.jsonc" -
        # which would read as an incompatible config when nothing was ever tested.
        # That is the "verdict about absence of evidence" defect; the exit code alone
        # cannot tell the two apart, so the message is checked as well.
        Push-Location $sandbox
        try {
            $out = & npm exec --yes --package="@yc-software/qm@$latest" -- qm check 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally { Pop-Location }

        if ($out -match 'no qm\.config\.jsonc in') {
            $verdict = 'unknown'
            Info 'the probe never ran (qm could not find the config it was given) - NOT a compatibility verdict'
        }
        elseif ($code -eq 0) {
            $verdict = 'compatible'
            Ok "upstream $latest accepts our qm.config.jsonc unchanged - the bump is cheap"
        }
        else {
            $verdict = 'needs-migration'
            $reason = ($out -split "`n" | Where-Object { $_ -match 'error:|unknown service' } | Select-Object -First 1)
            Warn ("upstream {0} REJECTS our config - the bump needs a migration" -f $latest)
            Info ("reason: " + ($reason -replace '\s+',' ').Trim())
            Info 'cost: rewrite qm.config.jsonc, regenerate compose.qm.yaml, re-prove the client install.'
            Info 'see deploy/qm-pacgate/UPSTREAM-0.1.19-VERDICT.md - this is planned work, not a version edit.'
        }
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("RESULT: pin {0}, upstream stable {1}, verdict {2}. Drift REPORTED, not blocked." -f `
    $pinned, $latest, $verdict) -ForegroundColor Yellow
Write-Host '  A newer upstream release must not turn the suite red, so this exits 0 by design.' -ForegroundColor DarkGray
Write-Host '  The point is that the drift can no longer go unnoticed.' -ForegroundColor DarkGray
exit 0
