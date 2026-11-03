# Offline assertions for scripts/prune-ghcr-versions.ps1.
#
# Every case here is a way the pruner could destroy a shipped release or lie about
# its own success. They are asserted against synthetic fixtures shaped exactly like
# the GitHub Packages version listing, so the maths is verifiable without a
# credential - which matters, because the delete credential is the one thing this
# repo does not keep on disk (scopes 'gist, repo, workflow' only, measured
# 2026-11-03).
#
# Exit 0 = every assertion held. Exit 1 = a real defect.

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$prune = Join-Path $repo 'scripts/prune-ghcr-versions.ps1'

$script:passed = 0
$script:failed = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) {
        Write-Host "  PASS  $name" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "  FAIL  $name" -ForegroundColor Red
        if ($detail) { Write-Host "        $detail" -ForegroundColor Red }
        $script:failed++
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("prune-fx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function New-Fixture([string]$pkg, [string]$json) {
    Set-Content -Path (Join-Path $work "$pkg.json") -Value $json -Encoding UTF8
}

function Invoke-Prune([string]$pkgArg) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command `
        "& '$prune' -FixturePath '$work' -Packages @($pkgArg)" 2>&1 | Out-String
    return $out
}

try {
    Write-Host ''
    Write-Host '=== prune-ghcr-versions: safety assertions ===' -ForegroundColor Cyan

    # ── 1. Keeps the newest N, drops the rest ────────────────────────────────
    New-Fixture 'pacgate-api' @'
[
 {"id":1,"name":"sha256:aa","metadata":{"container":{"tags":["0.2.12"]}}},
 {"id":2,"name":"sha256:bb","metadata":{"container":{"tags":["0.2.13"]}}},
 {"id":3,"name":"sha256:cc","metadata":{"container":{"tags":["0.2.14"]}}},
 {"id":4,"name":"sha256:dd","metadata":{"container":{"tags":["0.2.15"]}}},
 {"id":5,"name":"sha256:ee","metadata":{"container":{"tags":["0.2.16","latest"]}}}
]
'@
    $o = Invoke-Prune "'pacgate-api'"
    Check 'the newest three releases are kept' (
        $o -match 'keep 0\.2\.16, 0\.2\.15, 0\.2\.14') $o
    Check 'an older release is scheduled' ($o -match '0\.2\.13') $o
    Check 'two versions are scheduled' ($o -match 'Versions to delete \(2\)') $o

    # ── 2. latest is never deleted ───────────────────────────────────────────
    Check 'latest is never in the delete set' ($o -notmatch 'latest\s+older release') $o

    # ── 3. A tag sharing latest's digest cannot be dropped ──────────────────
    # If latest -> the OLDEST version, then that version must be protected even
    # though it sorts outside the keep window.
    New-Fixture 'pacgate-mcp' @'
[
 {"id":1,"name":"sha256:11","metadata":{"container":{"tags":["0.2.10","latest"]}}},
 {"id":2,"name":"sha256:22","metadata":{"container":{"tags":["0.2.16"]}}},
 {"id":3,"name":"sha256:33","metadata":{"container":{"tags":["0.2.15"]}}},
 {"id":4,"name":"sha256:44","metadata":{"container":{"tags":["0.2.14"]}}}
]
'@
    $o2 = Invoke-Prune "'pacgate-mcp'"
    Check 'a version behind latest is protected' (
        $o2 -match 'shares a digest with latest') $o2
    Check 'the protected version is NOT scheduled' (
        $o2 -match 'Versions to delete \(0\)') $o2

    # ── 4. One digest carrying several tags is scheduled ONCE ───────────────
    # Measured on the real registry: 0.2.13 and the leftover tmp-del tag point at
    # the same manifest. Two rows would make the second DELETE answer 404 and
    # report a clean run as a failure.
    New-Fixture 'ocr-service' @'
[
 {"id":1,"name":"sha256:aa","metadata":{"container":{"tags":["0.2.13","tmp-del"]}}},
 {"id":2,"name":"sha256:bb","metadata":{"container":{"tags":["0.2.16","latest"]}}},
 {"id":3,"name":"sha256:cc","metadata":{"container":{"tags":["0.2.15"]}}},
 {"id":4,"name":"sha256:dd","metadata":{"container":{"tags":["0.2.14"]}}}
]
'@
    $o3 = Invoke-Prune "'ocr-service'"
    Check 'a multi-tag digest is one delete, not two' (
        $o3 -match 'Versions to delete \(1\)') $o3
    Check 'both tags are shown on that one row' (
        $o3 -match '0\.2\.13, tmp-del') $o3

    # ── 5. Non-semver tags do not crash the sort ────────────────────────────
    # Before the fix, [version]'tmp-del' threw and the dry run died after printing
    # a plan it then could not display.
    Check 'a junk tag does not break the report' (
        $o3 -notmatch 'Cannot convert value') $o3
    Check 'the run completes cleanly' ($o3 -match 'DRY RUN') $o3

    # ── 6. Unknown non-release tags are left alone ──────────────────────────
    New-Fixture 'laya-serve' @'
[
 {"id":1,"name":"sha256:aa","metadata":{"container":{"tags":["0.2.16","latest"]}}},
 {"id":2,"name":"sha256:bb","metadata":{"container":{"tags":["some-experiment"]}}}
]
'@
    $o4 = Invoke-Prune "'laya-serve'"
    Check 'an unknown non-release tag is left alone' (
        $o4 -match 'left alone: some-experiment') $o4

    # ── 7. Dry run is the default and deletes nothing ───────────────────────
    Check 'the default run is a dry run' ($o -match 'DRY RUN') $o
    Check 'the default run reports nothing deleted' (
        $o -notmatch 'deleted [1-9]') $o

    # ── 8. Fixtures can never be combined with -Execute ─────────────────────
    $o5 = & powershell -NoProfile -ExecutionPolicy Bypass -Command `
        "& '$prune' -FixturePath '$work' -Packages @('pacgate-api') -Execute -Force" 2>&1 | Out-String
    Check '-Execute with -FixturePath is refused' ($o5 -match 'REFUSED') $o5
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: the pruner cannot delete a kept release or misreport itself. ($($script:passed) passed)" -ForegroundColor Green
exit 0
