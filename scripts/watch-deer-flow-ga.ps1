# Tell whether upstream has cut the deer-flow release we are waiting on.
#
# WHY THIS EXISTS
#
# plans/023-deer-flow-2.1-upgrade.md is PREP IN PROGRESS and "Blocked on upstream
# v2.1.0 GA for execution". Its trigger is "the non-rc v2.1.0 tag appears on
# bytedance/deer-flow, or the backend image resolves to a new digest" - but until
# now nothing checked that, so the trigger depended on somebody remembering to
# look. The plan itself names the cost: "the elapsed time between 'GA tagged' and
# '0.1.x shipped' should be dominated by verification rather than by patch
# archaeology."
#
# This closes that loop. It is safe to run on a schedule.
#
# THE CORRECTNESS PROPERTY THAT MATTERS
#
# The failure mode to avoid is reporting "not yet" when the probe actually
# failed - that silently converts a broken watcher into a watcher that never
# fires, which is worse than no watcher. So:
#
#   200            -> FOUND      (exit 0)
#   404            -> NOT YET    (exit 1)   <- the only normal negative
#   anything else  -> ERROR      (exit 2)   <- never reported as NOT YET
#   token failure  -> ERROR      (exit 2)
#
# A control probe runs FIRST against a tag known to exist. If the control fails,
# the whole check is reported as ERROR rather than as a negative, so a network or
# credential problem can never masquerade as "upstream has not released yet".
#
# Usage:
#   pwsh -File scripts/watch-deer-flow-ga.ps1
#   pwsh -File scripts/watch-deer-flow-ga.ps1 -RunAudit
#   pwsh -File scripts/watch-deer-flow-ga.ps1 -TargetTag v2.2.0
#
# Exit codes: 0 = target tag found, 1 = not yet, 2 = check could not be trusted.

[CmdletBinding()]
param(
    [string]$TargetTag = 'v2.1.0',
    [string]$ControlTag = 'v2.1.0-rc0',
    [switch]$RunAudit,
    [string]$CurrentTag = 'v2.0.0',
    [string]$Repo = 'bytedance/deer-flow-backend'
)

$ErrorActionPreference = 'Continue'

$Accept = 'application/vnd.oci.image.index.v1+json,' +
          'application/vnd.docker.distribution.manifest.list.v2+json,' +
          'application/vnd.docker.distribution.manifest.v2+json'

function Get-GhcrToken {
    param([string]$Repo)
    $uri = "https://ghcr.io/token?scope=repository:${Repo}:pull&service=ghcr.io"
    $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 30 -ErrorAction Stop
    if (-not $resp.token) { throw "token endpoint returned no token for $Repo" }
    return $resp.token
}

function Get-ManifestStatus {
    param([string]$Repo, [string]$Tag, [string]$Token)
    $code = & curl.exe -s -o NUL -w '%{http_code}' -m 30 -H "Authorization: Bearer $Token" -H "Accept: $Accept" "https://ghcr.io/v2/$Repo/manifests/$Tag" 2>&1
    return ("$code" | Out-String).Trim()
}

function Get-ManifestDigest {
    param([string]$Repo, [string]$Tag, [string]$Token)
    $hdrs = & curl.exe -s -I -m 30 -H "Authorization: Bearer $Token" -H "Accept: $Accept" "https://ghcr.io/v2/$Repo/manifests/$Tag" 2>&1
    $m = ($hdrs | Out-String) -split "`r?`n" | Where-Object { $_ -match '(?i)^docker-content-digest:\s*(\S+)' } | Select-Object -First 1
    if ($m -and $m -match '(?i)docker-content-digest:\s*(\S+)') { return $Matches[1] }
    return ''
}

Write-Host '=== deer-flow upstream release watch ===' -ForegroundColor Cyan
Write-Host "  repository : $Repo"
Write-Host "  pinned to  : $CurrentTag"
Write-Host "  waiting on : $TargetTag"
Write-Host ''

try {
    $token = Get-GhcrToken -Repo $Repo
} catch {
    Write-Host "RESULT: ERROR - could not obtain a GHCR token. $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'This is a probe failure, NOT a statement about the release.' -ForegroundColor Yellow
    exit 2
}

# --- control first ----------------------------------------------------------
# Deliberately ordered before the real probe. If we asked about the target first
# and the registry was unreachable, a non-200 could be misread as "not released
# yet". The control makes that impossible: a broken path shows up as ERROR before
# any negative can be reported.
$controlCode = Get-ManifestStatus -Repo $Repo -Tag $ControlTag -Token $token

if ($controlCode -ne '200') {
    Write-Host ("CONTROL FAILED: {0} returned {1}, expected 200." -f $ControlTag, $controlCode) -ForegroundColor Red
    Write-Host 'The probe cannot be trusted, so the target was NOT evaluated.' -ForegroundColor Yellow
    Write-Host 'RESULT: ERROR (control probe failed). This does not mean the release is absent.' -ForegroundColor Red
    exit 2
}
Write-Host ("  [ok] control: {0} -> 200" -f $ControlTag) -ForegroundColor DarkGray

# --- the real question ------------------------------------------------------
$targetCode = Get-ManifestStatus -Repo $Repo -Tag $TargetTag -Token $token

switch ($targetCode) {
    '200' {
        $digest = Get-ManifestDigest -Repo $Repo -Tag $TargetTag -Token $token
        Write-Host ''
        Write-Host ("RESULT: FOUND - {0} exists." -f $TargetTag) -ForegroundColor Green
        Write-Host ("  digest: {0}" -f $digest)

        $rcDigest = Get-ManifestDigest -Repo $Repo -Tag $ControlTag -Token $token
        if ($digest -and $rcDigest -and $digest -eq $rcDigest) {
            Write-Host '  NOTE: identical to the prerelease digest. The tag was likely' -ForegroundColor Yellow
            Write-Host '        re-pointed rather than a new build. Verify before acting.' -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host 'Next: plans/023-deer-flow-2.1-upgrade.md section 2 (Execution at GA).' -ForegroundColor Cyan
        Write-Host "  1. pwsh -File scripts/audit-deer-flow-patches.ps1 -BaseRef $CurrentTag -TargetRef $TargetTag"

        if ($RunAudit) {
            $audit = Join-Path $PSScriptRoot 'audit-deer-flow-patches.ps1'
            if (Test-Path $audit) {
                Write-Host ''
                Write-Host '--- running the patch audit ---' -ForegroundColor DarkGray
                & pwsh -NoProfile -File $audit -BaseRef $CurrentTag -TargetRef $TargetTag
                Write-Host ("  audit exit: {0} (0 = all patched paths still exist)" -f $LASTEXITCODE)
            } else {
                Write-Host "  audit script not found: $audit" -ForegroundColor Yellow
            }
        }
        exit 0
    }
    '404' {
        Write-Host ''
        Write-Host ("RESULT: NOT YET - {0} does not exist upstream." -f $TargetTag) -ForegroundColor Yellow
        Write-Host '  This is the expected state while 2.1.0 is at rc. Nothing to do.'
        exit 1
    }
    default {
        Write-Host ''
        Write-Host ("RESULT: ERROR - unexpected status {0} for {1}." -f $targetCode, $TargetTag) -ForegroundColor Red
        Write-Host 'Not treated as "not yet": the check could not be trusted.' -ForegroundColor Yellow
        exit 2
    }
}
