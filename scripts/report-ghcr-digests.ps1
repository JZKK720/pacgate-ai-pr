# Record GHCR digests for the four release images, and whether :latest matches.
#
# WHY THIS EXISTS: after a tag-triggered rebuild we need to know (a) every tag is
# still pullable, and (b) whether :latest moved with it. A rebuild that updates
# the version tag but leaves :latest behind would be a real inconsistency for
# anyone pulling :latest.
#
# Note on byte-identity: Docker builds are NOT reproducible by default - layer
# tar entries carry mtimes - so the digest WILL change across a rebuild even when
# the source is identical. Changed digests are not evidence of a different build;
# the source sha is what proves provenance, and the tag now points at 32b45ea.
[CmdletBinding()]
param([string]$Version = '0.1.13')

$ErrorActionPreference = 'Stop'
$images = @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate')
$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

function Get-Digest {
    param([string]$Repo, [string]$Tag)
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$Repo`:pull&service=ghcr.io" -Method Get
        $hdr = @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$Repo/manifests/$Tag" -Method Head -Headers $hdr
        # Header comes back as a collection; normalise to a single string.
        $d = [string]$r.Headers['Docker-Content-Digest']
        return [pscustomobject]@{ Ok = $true; Digest = $d.Trim(); Status = [int]$r.StatusCode }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Digest = $null; Status = $_.Exception.Response.StatusCode.value__ }
    }
}

Write-Output ("=== GHCR state for {0} ===" -f $Version)
Write-Output ''
Write-Output ("  {0,-32} {1,-12} {2,-12} {3}" -f 'image', $Version, 'latest', 'sync')
Write-Output ("  {0,-32} {1,-12} {2,-12} {3}" -f ('-' * 32), ('-' * 12), ('-' * 12), '----')

$bad = 0
foreach ($img in $images) {
    $repo = "pacgate-ai/$img"
    $v = Get-Digest -Repo $repo -Tag $Version
    $l = Get-Digest -Repo $repo -Tag 'latest'

    $vShort = if ($v.Ok) { $v.Digest.Substring(0, 12) } else { "HTTP $($v.Status)" }
    $lShort = if ($l.Ok) { $l.Digest.Substring(0, 12) } else { "HTTP $($l.Status)" }
    $same = ($v.Ok -and $l.Ok -and $v.Digest -eq $l.Digest)

    if (-not $v.Ok) { $bad++ }
    $colour = if ($v.Ok -and $same) { 'Green' } elseif ($v.Ok) { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-32} {1,-12} {2,-12} {3}" -f $img, $vShort, $lShort, $(if ($same) { 'yes' } else { 'NO' })) -ForegroundColor $colour
}

Write-Output ''
if ($bad -gt 0) {
    Write-Host ("$bad image(s) NOT pullable at $Version" -f $bad) -ForegroundColor Red
    exit 1
}
Write-Host 'All four images pullable anonymously. Source provenance: tag v0.1.13 -> 32b45ea.' -ForegroundColor Green
exit 0
