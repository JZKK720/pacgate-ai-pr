# Pre-flight before creating a release tag. Aborts on any failure.
# Written as a file because multi-line commands get split line-by-line in the
# interactive terminal, and leading '#' lines then read as separate commands.
#
# The version is DERIVED from pacgate-ai/Cargo.toml, never hardcoded. This script
# previously named 0.1.18 in 13 places and was run for a 0.1.19 release, where it
# checked the WRONG version end to end: it validated that the pins read 0.1.18
# (they read 0.1.19), looked for tag v0.1.18, and queried GHCR for 0.1.18. Every
# one of those checks passed vacuously because 0.1.18 was already a finished
# release with its tag and images in place. A pre-flight that cannot fail on the
# version it is releasing is not a pre-flight.
$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$fail = 0
function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

# 0. Resolve the version being released, from the single source of truth.
$cargoLine = (Select-String -Path 'pacgate-ai/Cargo.toml' -Pattern '^version\s*=' | Select-Object -First 1).Line
if (-not $cargoLine -or $cargoLine -notmatch '(\d+\.\d+\.\d+)') {
    Write-Host '=== PRE-FLIGHT: cannot determine the release version ===' -ForegroundColor Red
    Write-Host "  [FAIL] no `version = \"x.y.z\"` found in pacgate-ai/Cargo.toml" -ForegroundColor Red
    Write-Host '' -ForegroundColor Red
    Write-Host 'FAILED (1) - refusing to run with an unknown version' -ForegroundColor Red
    exit 1
}
$version = $Matches[1]
$tag = "v$version"

Write-Host "=== PRE-FLIGHT: release $version ===" -ForegroundColor Cyan
Ok "version $version derived from pacgate-ai/Cargo.toml (not hardcoded)"

# 1. working tree clean, ignoring this script's own file (it is tooling, not release content)
$thisScript = 'scripts/preflight-release-tag.ps1'
$s = @(git status --porcelain | Where-Object { $_ -notmatch [regex]::Escape($thisScript) })
if ($s) { Bad "working tree dirty:`n$($s -join "`n")" } else { Ok 'working tree clean (this script ignored)' }

# 2. synced with origin/main
git fetch origin 2>&1 | Out-Null
$ab = (git rev-list --left-right --count origin/main...HEAD) -split '\s+'
if ($ab[0] -eq '0' -and $ab[1] -eq '0') { Ok 'origin/main and HEAD are in sync (0/0)' }
else { Bad "out of sync with origin/main: behind=$($ab[0]) ahead=$($ab[1])" }

# 3. record the exact commit being released
$head = git rev-parse HEAD
Ok "HEAD = $($head.Substring(0,7))  $(git log --oneline -1 --format=%s)"

# 4. version pins must all read the version being released.
$cargo = (Select-String -Path 'pacgate-ai/Cargo.toml' -Pattern '^version' | Select-Object -First 1).Line
if ($cargo -match [regex]::Escape($version)) { Ok "Cargo.toml -> $($cargo.Trim())" } else { Bad "Cargo.toml is not $version`: $cargo" }

foreach ($f in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    # Match ONLY an `image:` pin with a semver tag:  image: ghcr.io/<ns>/<name>:0.1.18
    #
    # The first version of this matched `ghcr\.io/[^:]+:([0-9.]+)` anywhere on the
    # line, which also hit `ghcr.io/volcengine/openviking@sha256:46f9...` and
    # extracted "46" - reporting a false failure against a correct file. Anchor on
    # `image:` and require the version to be the whole tag, and skip `@sha256:`
    # digest references, which are pinned by digest on purpose (a third-party
    # upstream image we do not version).
    $pins = @(Select-String -Path $f -Pattern '(?m)^\s*image:\s+ghcr\.io/([^/\s]+)/([^\s:@]+):(\d+\.\d+\.\d+)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[3].Value } | Sort-Object -Unique)
    if ($pins.Count -eq 1 -and $pins[0] -eq $version) { Ok "$f pins only $version" }
    elseif ($pins.Count -eq 0) { Bad "$f has no semver image pin found (regex or file changed)" }
    else { Bad "$f pins multiple/other versions: $($pins -join ', ')" }
}

# 5. the tag must not already exist
$lt = git rev-parse -q --verify "refs/tags/$tag" 2>&1
$rt = git ls-remote --tags origin $tag 2>&1
if (-not $lt -and -not $rt) { Ok "$tag absent locally and on origin" }
else { Bad "$tag already exists (local='$lt' remote='$rt')" }

# 6. the images must not already exist
$ghcr = python scripts/check-ghcr-anon.py $version 2>&1 | Select-Object -Last 1
if ($ghcr -match 'NOT public|404') { Ok "GHCR $version not published yet ($($ghcr.Trim()))" }
else { Bad "GHCR $version already has images: $ghcr" }

# 7. the workflow must still trigger on this tag pattern
$wf = Get-Content '.github/workflows/build-ghcr.yml' -Raw
if ($wf -match '"v0\.1\.\*"') { Ok 'workflow still triggers on v0.1.*' }
else { Bad 'workflow no longer triggers on v0.1.* - a tag push would do NOTHING' }

# 8. namespace must resolve identically on both paths
if ($wf -match '(?m)^\s*GHCR_NAMESPACE:\s*(\S+)') { Ok "GHCR_NAMESPACE = $($Matches[1]) (used by BOTH tag push and dispatch)" }
else { Bad 'GHCR_NAMESPACE not found in the workflow' }

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'PRE-FLIGHT PASSED - safe to tag' -ForegroundColor Green
    Write-Host "  release commit: $head"
    exit 0
}
Write-Host "PRE-FLIGHT FAILED ($fail problem(s)) - do NOT tag" -ForegroundColor Red
exit 1
