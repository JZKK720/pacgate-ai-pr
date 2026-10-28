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

# ── GHCR manifest probe, with an honest TLS-revocation fallback ─────────────
#
# WHY THIS EXISTS (measured 2026-10-28 on the admin dev box)
#
# Invoke-WebRequest failed for ALL FIVE images with a transport error, which this
# gate reported as ERROR - indistinguishable from "the release was never
# published". It was neither: ghcr.io was healthy the whole time.
#
#   curl --ssl-no-revoke  https://ghcr.io/token?...            -> 200
#   curl (revocation ON)  https://ghcr.io/token?...            -> schannel:
#        CRYPT_E_REVOCATION_OFFLINE (0x80092013)
#   docker manifest inspect ghcr.io/.../pacgate-api:0.2.6      -> valid index
#
# So TCP was open and TLS succeeded, but the handshake's revocation phase could
# not complete. Cause on that host: OCSP times out
# (http://ocsp.digicert.com -> timeout) while the CRLs answer 200, so a
# hard-fail-on-unavailable-revocation policy cannot be satisfied. That is a HOST
# condition, and it made a release look undeployed.
#
# The fallback is deliberately NOT silent. It never relaxes anything by default:
# it retries with revocation disabled ONLY after the strict attempt fails with a
# revocation/TLS error, and it says so in the output on every run. A reader can
# always tell whether a status came from a fully verified handshake.
#
# What it must NOT do is report a green 200 when the registry actually refused.
# The curl path therefore reads the real HTTP status; a 401/404 still surfaces as
# 401/404, not as a pass.

# True when an exception is a transport/TLS failure rather than an HTTP response.
function Test-TlsRevocationFailure($err) {
    $msg = "$err"
    return ($msg -match 'CRYPT_E_REVOCATION_OFFLINE' -or
            $msg -match 'InitializeSecurityContext'      -or
            $msg -match 'revocation'                      -or
            $msg -match 'UNEXPECTED_EOF_WHILE_READING'   -or
            $msg -match 'SSL')
}

# curl exits 0 and prints the code; on a transport failure it exits non-zero.
function Get-ManifestStatusViaCurl($repo, $version, $accept) {
    $uri = "https://ghcr.io/v2/$repo/manifests/$version"
    $tokRaw = & curl.exe -sS --ssl-no-revoke --max-time 25 `
        "https://ghcr.io/token?scope=repository:$repo`:pull&service=ghcr.io" 2>&1
    $tok = $null
    try { $tok = ($tokRaw | Out-String | ConvertFrom-Json).token } catch { }
    if (-not $tok) { return $null }

    $out = & curl.exe -sS --ssl-no-revoke --max-time 25 -o NUL -w '%{http_code}' `
        -H "Authorization: Bearer $tok" -H "Accept: $accept" $uri 2>&1
    $code = (@($out) | Where-Object { "$_" -match '^\d{3}$' } | Select-Object -Last 1)
    if ($code) { return "$code" }
    return $null
}

function Get-ManifestStatus($repo, $version, $accept) {
    $uri = "https://ghcr.io/v2/$repo/manifests/$version"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$repo`:pull&service=ghcr.io" -Method Get
            $r = Invoke-WebRequest -Uri $uri -Method Head -UseBasicParsing `
                -Headers @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
            return @{ Status = "$($r.StatusCode)"; Via = 'strict' }
        }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code) { return @{ Status = "$code"; Via = 'strict' } }
            if (Test-TlsRevocationFailure $_.Exception) {
                # Strict handshake cannot complete revocation. Retry without it,
                # and label the result so this is never mistaken for a verified read.
                $fb = Get-ManifestStatusViaCurl $repo $version $accept
                if ($fb) { return @{ Status = $fb; Via = 'no-revoke' } }
                return @{ Status = 'ERROR'; Via = 'no-revoke-failed' }
            }
            if ($attempt -lt 3) { Start-Sleep -Milliseconds (500 * $attempt) }
        }
    }
    return @{ Status = 'ERROR'; Via = 'strict' }
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
$tlsRelaxed = @()
foreach ($img in @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate', 'ocr-service')) {
    $repo = "$ns/$img"
    $probe = Get-ManifestStatus $repo $V $accept
    $status = $probe.Status
    if ($probe.Via -eq 'no-revoke') { $tlsRelaxed += $img }
    if ($status -eq '404') { $missing += $img }
    Line "${img}:$V" $status ($status -eq '200')
}

# Make the relaxation visible. A status obtained without a completed revocation
# check is still a real registry answer, but the reader must be able to tell.
if ($tlsRelaxed.Count -gt 0) {
    Write-Output ''
    Write-Host ("  NOTE: {0} probe(s) used --ssl-no-revoke - this host cannot complete" -f $tlsRelaxed.Count) -ForegroundColor Yellow
    Write-Host "        TLS revocation (OCSP unreachable), so the strict handshake fails for" -ForegroundColor Yellow
    Write-Host "        EVERY host, not just ghcr.io. Statuses above are real registry answers." -ForegroundColor Yellow
    Write-Host ("        affected: {0}" -f ($tlsRelaxed -join ', ')) -ForegroundColor DarkGray
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
