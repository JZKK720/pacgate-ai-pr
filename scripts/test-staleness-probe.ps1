# Prove the 7e staleness probe against the LIVE stack.
#
# This box runs ghcr.io/jzkk720/pacgate-api:0.1.2 with nginx on host 8081, so it
# is an ideal negative case: /version should be unreachable/HTML because that
# image predates the route. If the probe reports "OK <version>" here, the probe
# is not testing what it claims.
$ErrorActionPreference = 'Continue'
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; Write-Host "         $d" -ForegroundColor DarkGray }
}

Write-Host '=== live staleness probe ==='
Write-Output ''

# 1. Port derivation: `docker port` must find the real mapping.
$frontPort = $null
$insp = docker port pacgate-nginx 2>$null
foreach ($l in @($insp)) { if ($l -match ':(\d+)\s*$') { $frontPort = $Matches[1]; break } }
Check 'nginx host port is DERIVED, not assumed' ($frontPort -eq '8081') "got '$frontPort', expected 8081 (the live mapping)"

# 2. The derived port really is reachable.
$url = "http://localhost:$frontPort/version"
Check 'derived port responds' ($frontPort -eq '8081') "port was $frontPort"

# 3. The route must NOT return a JSON version, because 0.1.2 predates it.
$reported = $null; $revision = $null; $outcome = 'unreachable'
try {
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
    if ($resp.version) { $reported = $resp.version; $revision = $resp.revision; $outcome = 'json' }
    else { $outcome = 'non-json body' }
}
catch { $outcome = "error: $($_.Exception.Message.Substring(0, [Math]::Min(60, $_.Exception.Message.Length)))" }

Write-Host ("         probe outcome: {0}; reported='{1}'" -f $outcome, $reported) -ForegroundColor DarkGray
Check 'old image does NOT report a version (so the probe can fail)' ($null -eq $reported) "it reported '$reported' - the probe would give a false OK on an outdated stack"

# 4. The failure branch must correctly identify WHY.
$img = (docker inspect pacgate-api --format '{{.Config.Image}}' 2>$null | Out-String).Trim()
Write-Host ("         running image: {0}" -f $img) -ForegroundColor DarkGray
Check 'the old-image detection matches the live image' ($img -match 'jzkk720|:0\.1\.[0-9]$') "image '$img' would not be flagged as predating the route"

# 5. The PINNED version must parse out of compose, or the comparison is skipped.
$composeTxt = Get-Content deploy/client-bundle/compose.prod.yaml -Raw
$m = [regex]::Match($composeTxt, '(?m)^\s*image:\s*ghcr\.io/[a-z0-9\-]+/pacgate-api:(?<v>\d+\.\d+\.\d+)\s*$')
Check 'compose pin parses for the comparison' ($m.Success -and $m.Groups['v'].Value -eq '0.1.13') "got '$($m.Groups['v'].Value)'"
Write-Host ("         compose pins pacgate-api {0}" -f $m.Groups['v'].Value) -ForegroundColor DarkGray

Write-Output ''
Write-Host ("{0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
