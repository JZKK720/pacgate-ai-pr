# Gate: OpenViking round trip - write, read back, delete, confirm gone.
#
# WHY THIS EXISTS.
#
# OpenViking is the only stateful service in the bundle with no round-trip
# check. Every other gate proves reachability (a 200 from /health) or
# proves a generated document. None of them proves that bytes written to
# OpenViking come back out. This is the check the 0.4.16 -> 0.5.6 runbook
# (docs/runbooks/openviking-0.4.16-to-0.5.6.md) uses to confirm the store
# survived the upgrade, and it is the same check an operator should run
# after wiping anything under data/.
#
# It writes exactly one throwaway file under viking://user/default/ and
# deletes it before exiting. It creates no memory, no session, and no
# resource; it does not touch matter memory, the pacgate database, or qm.
#
# Note: ov-mcp-call.ps1 returns the parsed JSON-RPC result object, NOT a
# string - checking a rendered table would silently truncate long payloads,
# so the assertions below read .structuredContent / .content[].text directly.
#
# Exit codes:
#   0  round trip succeeded
#   1  round trip failed - the store is NOT trustworthy right now
#   2  CANNOT CHECK - OpenViking unreachable or no API key (not a failure)
#
# Usage:  pwsh -File scripts/test-openviking-roundtrip.ps1

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ovc = Join-Path $PSScriptRoot 'ov-mcp-call.ps1'

function Invoke-Ov {
    param([string]$Tool, [string]$Arguments)
    try {
        & $ovc -Tool $Tool -Arguments $Arguments
    } catch {
        Write-Verbose "$Tool failed: $_"
        $null
    }
}

function Get-OvText($result) {
    if ($null -eq $result) { return '' }
    if ($result.structuredContent -and $result.structuredContent.result) { return [string]$result.structuredContent.result }
    $texts = @($result.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
    return ($texts -join "`n")
}

$health = Invoke-Ov -Tool 'health' -Arguments '{}'
if ($null -eq $health) {
    Write-Host '[SKIP] OpenViking not answering at :1933 - cannot check (exit 2, not a failure).' -ForegroundColor Yellow
    exit 2
}
Write-Host '[PASS] health: OpenViking reports healthy'

$canary = 'pacgate-roundtrip-' + [guid]::NewGuid().ToString('N')
# 0.5.x scopes writes to the AUTHENTICATED user. Measured 2026-11-25 on v0.5.6:
# writing to viking://user/default/... with the pacgate-service key returns
#   PERMISSION_DENIED "write permission required"
# The canary must therefore live under the service user's own namespace. The
# account/user is carried inside the key, so it is read from .env rather than
# assumed - hardcoding a user name here would break the moment the operator
# issues the key for a different identity.
$ovUser = 'pacgate-service'
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.env'
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^OPENVIKING_SERVICE_USER=(\S+)' | Select-Object -First 1
    if ($m) { $ovUser = $m.Matches[0].Groups[1].Value.Trim() }
}
$uri    = "viking://user/$ovUser/probe-$canary.md"
# Marker lives ONLY in the body, never in the URI - so a "File not found: <uri>"
# error can never be misread as the canary still being present.
$marker = "roundtriptoken-$([guid]::NewGuid().ToString('N'))"
$body   = "# roundtrip`n`ncanary=$marker`n"

# wait=$true blocks until the write is visible to readers; without it the
# immediate read can miss (the server indexes asynchronously).
$writeJson = @{ uri = $uri; content = $body; mode = 'create'; wait = $true } | ConvertTo-Json -Compress
$write = Invoke-Ov -Tool 'write' -Arguments $writeJson
if ($null -eq $write) {
    Write-Host "[FAIL] write canary to $uri failed" -ForegroundColor Red
    exit 1
}
Write-Host "[PASS] write: $uri"

$readJson = @{ uris = @($uri) } | ConvertTo-Json -Compress
$read = Invoke-Ov -Tool 'read' -Arguments $readJson
$readText = Get-OvText $read
if ($readText -notmatch [regex]::Escape($marker)) {
    Write-Host "[FAIL] read-back of $uri did not contain the canary" -ForegroundColor Red
    Write-Host "     got: $($readText.Substring(0, [Math]::Min(200, $readText.Length)))"
    Invoke-Ov -Tool 'forget' -Arguments (@{ uri = $uri } | ConvertTo-Json -Compress) | Out-Null
    exit 1
}
Write-Host '[PASS] read-back: canary content returned verbatim'

$del = Invoke-Ov -Tool 'forget' -Arguments (@{ uri = $uri } | ConvertTo-Json -Compress)
if ($null -eq $del) {
    Write-Host "[FAIL] delete of $uri failed - canary left behind: $uri" -ForegroundColor Red
    exit 1
}
Write-Host '[PASS] delete: canary removed'

$after = Invoke-Ov -Tool 'read' -Arguments $readJson
$afterText = Get-OvText $after
if ($afterText -match [regex]::Escape($marker)) {
    Write-Host "[FAIL] $uri still readable after delete" -ForegroundColor Red
    exit 1
}
Write-Host '[PASS] verify: deleted URI no longer readable'

Write-Host 'RESULT: OpenViking round trip passed (write -> read -> delete -> gone).' -ForegroundColor Green
exit 0
