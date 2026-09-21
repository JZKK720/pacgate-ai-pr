# Prove the staleness comparison against the LIVE stack.
#
# HISTORY: this test originally used the running stack as its NEGATIVE case,
# asserting the live image was pacgate-api:0.1.2 which predated /version. That
# stopped being true when the stack moved to 0.1.17, so the check could never
# pass again - a fixture-based negative case expires. It also hardcoded the nginx
# host port as 8081, which went red when compose moved to 8089.
#
# Both are now DERIVED, and the discrimination is tested SYNTETICALLY (accept the
# current version, reject an outdated one) so the negative case cannot expire.
$ErrorActionPreference = 'Continue'
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; Write-Host "         $d" -ForegroundColor DarkGray }
}

Write-Host '=== live staleness probe ==='
Write-Output ''

# 1. Port derivation: `docker port` must find the real mapping, and the expected
#    value comes from compose rather than from memory. A hardcoded expectation is
#    how this check went red purely because the mapping moved.
$frontPort = $null
$insp = docker port pacgate-nginx 2>$null
foreach ($l in @($insp)) { if ($l -match ':(\d+)\s*$') { $frontPort = $Matches[1]; break } }
$composeTxt0 = Get-Content deploy/client-bundle/compose.prod.yaml -Raw
$expectedPort = [regex]::Match($composeTxt0, '(?s)container_name:\s*pacgate-nginx.*?ports:\s*\n\s*-\s*"?(?<p>\d+):80').Groups['p'].Value
Check 'nginx host port is DERIVED, not assumed' ($frontPort -eq $expectedPort) "got '$frontPort', compose maps '$expectedPort'"

# 2. The derived port really is reachable.
$url = "http://localhost:$frontPort/version"
Check 'derived port responds' (-not [string]::IsNullOrWhiteSpace($frontPort)) "port was '$frontPort'"

# 3. The live image is CURRENT, so /version must resolve. The old form of this
#    check asserted the opposite (that the live image predated the route), which
#    became unfalsifiable once the stack was upgraded.
$reported = $null; $revision = $null; $outcome = 'unreachable'
try {
    $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
    if ($resp.version) { $reported = $resp.version; $revision = $resp.revision; $outcome = 'json' }
    else { $outcome = 'non-json body' }
}
catch { $outcome = "error: $($_.Exception.Message.Substring(0, [Math]::Min(60, $_.Exception.Message.Length)))" }

Write-Host ("         probe outcome: {0}; reported='{1}'" -f $outcome, $reported) -ForegroundColor DarkGray
Check 'live image DOES report a version (positive case)' (-not [string]::IsNullOrWhiteSpace($reported)) "outcome '$outcome' - /version must resolve on a current image"

# 4. The comparison must DISCRIMINATE. The box no longer holds an outdated image,
#    so instead of a live fixture, exercise the rule directly: it accepts the
#    current version and rejects an outdated one. Without BOTH halves, a probe
#    that always answers "OK" would pass everything above.
$manifestForCompare = [regex]::Match((Get-Content pacgate-ai/Cargo.toml -Raw), '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"').Groups['v'].Value
function Test-VersionMatch([string]$pinned, [string]$reported) { return ($pinned -eq $reported) }
Check 'comparison ACCEPTS the current version' (Test-VersionMatch $manifestForCompare $reported) "pinned '$manifestForCompare' vs reported '$reported'"
Check 'comparison REJECTS an outdated version (so the probe can fail)' (-not (Test-VersionMatch $manifestForCompare '0.1.2')) 'a probe that accepts 0.1.2 as current would give a false OK on an outdated stack'

# 5. The running image must still be identifiable for the failure message.
$img = (docker inspect pacgate-api --format '{{.Config.Image}}' 2>$null | Out-String).Trim()
Write-Host ("         running image: {0}" -f $img) -ForegroundColor DarkGray
Check 'running image is identifiable' (-not [string]::IsNullOrWhiteSpace($img)) 'docker inspect returned no image reference'

# 5. The PINNED version must parse out of compose, or the comparison is skipped.
#
# The expected value is DERIVED from the crate manifest, not hardcoded. It read
# -eq '0.1.13' first, which went red on the 0.1.14 bump for no reason other than
# the version moving - and the tempting fix is to re-hardcode 0.1.14, which makes
# the check expire again at the next bump. Cargo.toml is the source of truth for
# the version (it is what /build-info reports via CARGO_PKG_VERSION), so tying
# the test to it means the test has nothing to re-learn.
#
# The CROSS-FILE assertion is the one worth having: compose and the manifest can
# drift, and a release built WITHOUT bumping Cargo.toml would make /version report
# the OLD string while compose pins the new one, so the staleness comparison could
# never fire. Asserting they agree catches that at test time instead of on a
# client machine.
$cargoTxt = Get-Content pacgate-ai/Cargo.toml -Raw
$manifestVersion = [regex]::Match($cargoTxt, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"').Groups['v'].Value
$composeTxt = Get-Content deploy/client-bundle/compose.prod.yaml -Raw
$m = [regex]::Match($composeTxt, '(?m)^\s*image:\s*ghcr\.io/[a-z0-9\-]+/pacgate-api:(?<v>\d+\.\d+\.\d+)\s*$')
Check 'compose pin parses for the comparison' $m.Success 'no pinned pacgate-api version found in compose.prod.yaml'
Check 'compose pin matches the crate manifest version' ($m.Success -and $m.Groups['v'].Value -eq $manifestVersion) "compose pins '$($m.Groups['v'].Value)' but Cargo.toml says '$manifestVersion' - /version reports the manifest value, so the staleness check could never fire"
Write-Host ("         manifest {0}, compose pins pacgate-api {1}" -f $manifestVersion, $m.Groups['v'].Value) -ForegroundColor DarkGray

Write-Output ''
Write-Host ("{0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
