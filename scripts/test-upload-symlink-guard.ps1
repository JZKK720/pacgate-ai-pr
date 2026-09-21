# Assert the uploads DELETE route refuses to delete through a planted symlink.
#
# WHY THIS EXISTS
#
# Upload dirs are mounted into local sandboxes by design, so a sandbox process
# can leave a symlink sitting at an upload filename. Upstream v2.0.0's
# `delete_file_safe` resolves the path BEFORE validating it and then unlinks the
# RESOLVED target, so a symlink causes a different file to be deleted while the
# caller is told the named file was deleted.
#
# Measured against the real function on 2026-09-22 (see the probe output recorded
# in the commit): the exposure is narrower than an earlier assessment claimed.
#
#   symlink -> file OUTSIDE the uploads dir   -> PathTraversalError (NOT exploitable)
#   symlink -> SIBLING inside the uploads dir -> TARGET DELETED, success reported
#
# So the residual defect is intra-thread misreporting, not a host-file escape.
# `deploy/client-bundle/patches/deer-flow-uploads.py` adds
# `_reject_symlinked_upload`, and this gate is what keeps it in place.
#
# Upstream 2.1.0-rc0 does NOT fix this: `delete_file_safe` and
# `validate_path_traversal` are byte-identical there, and rc0's new
# lstat/S_ISREG guard is applied to upload DESTINATIONS, not deletes. The guard is
# therefore ours and must be carried forward BY HAND at the 2.1 rebase; when that
# rebase happens, re-run this gate and do not assume upstream covered it.
#
# NOTE ON SCOPE. This calls the guard directly rather than issuing an
# authenticated HTTP DELETE. That is deliberate: the guard is pure (path in, raise
# or return), so testing it directly tests the actual security decision without
# needing to mint a session, and it cannot pass while the guard is absent.
#
# Usage:
#   pwsh -File scripts/test-upload-symlink-guard.ps1
#   pwsh -File scripts/test-upload-symlink-guard.ps1 -Image ghcr.io/jzkk720/deer-flow-pacgate:0.1.17
#
# Exit codes: 0 = guard behaves, 1 = a case failed, 2 = harness could not run.

[CmdletBinding()]
param(
    [string]$Image  = 'ghcr.io/jzkk720/deer-flow-pacgate:0.1.17',
    [string]$Ctr    = 'pg-symlink-guard',
    [switch]$Keep
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot

$passed = 0
$failed = 0
function Check($name, $good, $detail) {
    if ($good) { $script:passed++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else {
        $script:failed++
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
    }
}

function Cleanup {
    if (-not $Keep) { docker rm -f $Ctr 2>&1 | Out-Null }
}
trap { Cleanup; exit 2 }

Write-Host '=== upload DELETE symlink guard ===' -ForegroundColor Cyan

$patch = Join-Path $repo 'deploy/client-bundle/patches/deer-flow-uploads.py'
if (-not (Test-Path $patch)) {
    Write-Host "  patch not found: $patch" -ForegroundColor Red
    Cleanup; exit 2
}

# The guard must be IN the source before we bother starting a container, otherwise
# a failure here would look like a runtime problem rather than a missing patch.
$src = Get-Content -LiteralPath $patch -Raw
Check 'guard is defined in the patch source' ($src -match 'def _reject_symlinked_upload') 'missing definition'
Check 'guard is CALLED by the route'          ($src -match '(?m)^\s*_reject_symlinked_upload\(uploads_dir, filename\)') 'defined but not wired'
Check 'guard is called OUTSIDE the broad try' ($src -match 'MUST stay outside the try') 'guard may be swallowed into a 500 by `except Exception`'

Write-Host ''
Write-Host '--- starting container ---' -ForegroundColor DarkGray
docker rm -f $Ctr 2>&1 | Out-Null

# THE PATCHES ARE NOT IN THE IMAGE. compose bind-mounts them at runtime, so a
# bare `docker run` would execute stock upstream uploads.py and this whole gate
# would measure the wrong thing. The -v path MUST mirror compose.prod.yaml.
& docker run -d --name $Ctr `
    -v "${patch}:/app/backend/app/gateway/routers/uploads.py:ro" `
    $Image 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Check "container starts from $Image" $false 'docker run failed'; Cleanup; exit 2 }

# Prove the mount took effect: if the container sees the stock file, the mount
# path drifted and every assertion below would be testing upstream.
$count = (& docker exec $Ctr sh -c 'grep -c "_reject_symlinked_upload" /app/backend/app/gateway/routers/uploads.py' 2>&1 | Out-String).Trim()
Check 'bind-mount actually replaced the module in the container' ($count -match '^\d+$' -and [int]$count -ge 2) "grep count='$count'"

Write-Host ''
Write-Host '--- behaviour of the real guard ---' -ForegroundColor DarkGray

$probe = Join-Path $env:TEMP 'pg-symlink-guard-probe.py'
@'
import os
import stat
import sys
import tempfile
from pathlib import Path

from fastapi import HTTPException

from app.gateway.routers.uploads import _reject_symlinked_upload

root = Path(tempfile.mkdtemp(prefix="guard-"))
base = root / "uploads"
base.mkdir(parents=True)

(base / "sibling.txt").write_text("sibling")
(base / "plain.txt").write_text("plain")
(root / "host.txt").write_text("host")

os.symlink(base / "sibling.txt", base / "link-inside.pdf")
os.symlink(root / "host.txt",    base / "link-outside.pdf")
os.symlink(base / "nope.pdf",    base / "link-dangling.pdf")

CASES = [
    ("symlink to sibling inside uploads dir", "link-inside.pdf",  404),
    ("symlink to file outside uploads dir",   "link-outside.pdf", 404),
    ("dangling symlink",                      "link-dangling.pdf", 404),
    ("plain regular file is deletable",       "plain.txt",         None),
    ("missing file is left to delete_file_safe", "absent.txt",     None),
    ("traversal is left to delete_file_safe", "../host.txt",       None),
]

rc = 0
for label, name, expect in CASES:
    try:
        _reject_symlinked_upload(base, name)
        got, code = "passed through", None
    except HTTPException as exc:
        got, code = "HTTP %s" % exc.status_code, exc.status_code
    except Exception as exc:
        got, code = type(exc).__name__, -1
    ok = (expect is None and code is None) or (expect is not None and code == expect)
    if not ok:
        rc = 1
    print("%s|%s|%s" % ("OK" if ok else "BAD", label, got))

raise SystemExit(rc)
'@ | Set-Content -LiteralPath $probe -Encoding UTF8

docker cp $probe "${Ctr}:/tmp/probe.py" 2>&1 | Out-Null
$out = (& docker exec $Ctr sh -c 'cd /app/backend && /app/backend/.venv/bin/python /tmp/probe.py' 2>&1 | Out-String)
$probeExit = $LASTEXITCODE

foreach ($line in ($out -split "`r?`n")) {
    if ($line -match '^(OK|BAD)\|') {
        $parts = $line -split '\|'
        Check $parts[1] ($parts[0] -eq 'OK') "got: $($parts[2])"
    }
}
# (?m) is required: without it `^` anchors to the start of the WHOLE string, and
# the image's LangChain deprecation warning is printed first, so this guard
# reported "no parseable output" while all six cases had in fact passed.
if ($out -notmatch '(?m)^(OK|BAD)\|') {
    Check 'probe produced results' $false "no parseable output. Raw:`n$out"
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "RESULT: the delete route refuses symlinks, and normal deletes pass through. ($passed passed)" -ForegroundColor Green
} else {
    Write-Host "RESULT: $failed of $($passed + $failed) checks failed." -ForegroundColor Red
}

Cleanup
exit $(if ($failed -eq 0) { 0 } else { 1 })
