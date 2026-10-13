# Final end-to-end state check for the CURRENT delivery.
#
# The version is DERIVED, not hardcoded. It was '0.1.13' in seven places, which
# made this script a de-facto release pin: every bump turned it red, and the
# obvious fix is to update the literal - so the script had to be edited as part
# of shipping, and a forgotten edit read as a failed delivery. Deriving it from
# Cargo.toml (the source of truth for /version) means a bump needs no edit here,
# and the check keeps testing the same property: does the deployed state match
# what the source says it should be.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

$ok = $true
function Line($label, $value, $good) {
    $c = if ($good) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-34} {1}" -f $label, $value) -ForegroundColor $c
    if (-not $good) { $script:ok = $false }
}

# The version under test, read from the crate manifest.
$cargo = Get-Content pacgate-ai/Cargo.toml -Raw
$cv = ([regex]::Match($cargo, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"')).Groups['v'].Value
if (-not $cv) { Write-Host 'FAIL: could not read the workspace version from Cargo.toml' -ForegroundColor Red; exit 1 }
$V = $cv

Write-Host ("=== Delivery state for {0} ===" -f $V)
Write-Output ''

# Publish authority is a SINGLE remote. The `pacgate-ai` fork is a stale mirror
# that nothing client-facing reads (0 refs in both compose files, 0 in
# install.ps1), so asserting `fork == origin` could never hold and was removed
# rather than papered over. origin (JZKK720) is what clients clone and pull.
$origin = (git rev-parse HEAD).Trim()
Line 'local HEAD' $origin.Substring(0, 7) $true

# DERIVE the namespace from the pins, do not hardcode it. The two pin regexes
# below previously hardcoded `ghcr\.io/pacgate-ai/`, so after the plan-016 repin
# they matched NOTHING and printed empty strings - which then passed vacuously.
# An empty match is the dangerous case: it looks like agreement.
$prod = Get-Content deploy/client-bundle/compose.prod.yaml -Raw
$bundle = Get-Content deploy/client-bundle/compose.bundle.yaml -Raw
$nsMatch = [regex]::Match($prod, 'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/[a-z0-9\-]+:\d+\.\d+\.\d+')
$ns = $nsMatch.Groups['ns'].Value
Line 'image namespace (derived)' $ns ([bool]$ns)

$prodPins = @([regex]::Matches($prod, 'ghcr\.io/[A-Za-z0-9._-]+/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups['v'].Value })
$bundlePins = @([regex]::Matches($bundle, 'ghcr\.io/[A-Za-z0-9._-]+/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups['v'].Value })
$prodOk = ($prodPins.Count -gt 0) -and (@($prodPins | Where-Object { $_ -ne $V }).Count -eq 0)
$bundleOk = ($bundlePins.Count -gt 0) -and (@($bundlePins | Where-Object { $_ -ne $V }).Count -eq 0)
Line 'compose.prod.yaml pins' (($prodPins | Sort-Object -Unique) -join ', ') $prodOk
Line 'compose.bundle.yaml pins' (($bundlePins | Sort-Object -Unique) -join ', ') $bundleOk

Line "Cargo workspace version" $cv ($cv -eq $V)

Write-Output ''
Write-Host '=== GHCR images (anonymous pull) ==='
Write-Output ''
$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
# Five images from 0.1.16 onward; ocr-service was missing from this list.
#
# These are the only assertions here that can be red for a reason that is not a
# delivery fault: during the release window the tag is not pushed yet, so all five
# legitimately 404. On 0.1.28 that produced "SOME CHECKS FAILED" and made an
# otherwise-correct delivery read as broken. An unpublished tag is a state to
# report, not a fault to fail - so the 404s are counted and, when the LOCAL half
# of this script is entirely green, the script exits 2 (CANNOT CHECK) with the
# reason. If the local half is already wrong it still fails normally, because then
# there is a real delivery defect to report.
$missing = @()
foreach ($img in @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate', 'ocr-service')) {
    $repo = "$ns/$img"
    $status = 'ERROR'
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$repo`:pull&service=ghcr.io" -Method Get
        # -UseBasicParsing is REQUIRED. Without it Windows PowerShell 5.1
        # dispatches to the IE-based parser, which has no document to build for a
        # HEAD response and throws NullReferenceException - so this gate failed on
        # the default Windows shell while passing on PowerShell 7.
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$repo/manifests/$V" -Method Head -UseBasicParsing -Headers @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
        $status = "$($r.StatusCode)"
    }
    catch {
        # A transport failure (DNS, TLS, timeout) leaves Response null; keep the
        # ERROR marker so it is never confused with a real registry answer.
        $code = $_.Exception.Response.StatusCode.value__
        if ($code) { $status = "$code" } else { $status = "ERROR" }
    }
    if ($status -eq '404') { $missing += $img }
    Line "${img}:$V" $status ($status -eq '200')
}

Write-Output ''
if ($ok) {
    Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
    exit 0
}
# Every failure is an unpublished tag and nothing else is wrong: the release has
# not been built yet, so there is nothing to deliver and this is not a fault.
if ($missing.Count -gt 0 -and $missing.Count -eq 5) {
    Write-Host ("SKIP: NOT YET ASSERTABLE - no {0} image is published yet, so the registry half cannot be checked." -f $V) -ForegroundColor Yellow
    Write-Host '      Local state is in order. Push the release tag, wait for build-ghcr.yml, then re-run.' -ForegroundColor Yellow
    exit 2
}
Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red
exit 1
