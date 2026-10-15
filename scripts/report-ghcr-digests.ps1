# Record GHCR digests for the five release images, and whether :latest matches.
#
# WHY THIS EXISTS: after a tag-triggered rebuild we need to know (a) every tag is
# still pullable, and (b) whether :latest moved with it. A rebuild that updates
# the version tag but leaves :latest behind would be a real inconsistency for
# anyone pulling :latest.
#
# NAMESPACE: read from `.github/workflows/build-ghcr.yml` (`GHCR_NAMESPACE`), the
# declared single source of truth. Do NOT hardcode it here. This file previously
# hardcoded `pacgate-ai/*` - the READ-ONLY MIRROR that publishes NO images - so
# every version tag came back HTTP 404 while `:latest` still resolved to a stale
# 0.1.14-era build, which made the output look half-healthy. Same defect
# `deploy/build-images.ps1` had; it was fixed there on 2026-09-18 (plans/016)
# but this script was missed.
#
# Note on byte-identity: Docker builds are NOT reproducible by default - layer
# tar entries carry mtimes - so the digest WILL change across a rebuild even when
# the source is identical. Changed digests are not evidence of a different build;
# the source sha is what proves provenance, and the release tag names it.
[CmdletBinding()]
param(
    [string]$Version = '',
    # Deliberate override. Empty = read GHCR_NAMESPACE from the workflow.
    [string]$Namespace = ''
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot = <repo>\scripts; the repo root is one level up.
$Root = Split-Path -Parent $PSScriptRoot

# Resolve the GHCR namespace from its declared single source of truth, exactly as
# deploy/build-images.ps1 does. Keeping one copy of the value is the whole point.
function Resolve-GhcrNamespace([string]$RepoRoot, [string]$Override) {
    if ($Override) { return $Override }
    $wf = Join-Path $RepoRoot ".github/workflows/build-ghcr.yml"
    if (Test-Path $wf) {
        $m = Select-String -Path $wf -Pattern '^\s*GHCR_NAMESPACE:\s*(\S+)' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    Write-Host "WARN: could not read GHCR_NAMESPACE from $wf; using fallback 'jzkk720'." -ForegroundColor Yellow
    return "jzkk720"
}

$Ns = Resolve-GhcrNamespace $Root $Namespace

if (-not $Version) {
    Set-Location $Root
    $cargo = Get-Content pacgate-ai/Cargo.toml -Raw
    $Version = [regex]::Match($cargo, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"').Groups['v'].Value
    if (-not $Version) { Write-Host 'ERROR: could not read the workspace version from Cargo.toml' -ForegroundColor Red; exit 1 }
}
# Must match the release set the workflow publishes and verifies
# (build-ghcr.yml publish-verify loop) and the compose pins in
# deploy/client-bundle/compose.prod.yaml. ocr-service was previously missing.
$images = @('pacgate-api', 'pacgate-mcp', 'ocr-service', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate')
$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

function Get-Digest {
    param([string]$Repo, [string]$Tag)
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$Repo`:pull&service=ghcr.io" -Method Get
        $hdr = @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
        # -UseBasicParsing: Windows PowerShell 5.1 otherwise tries to build a DOM
        # and throws a NullReferenceException with no usable status code.
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$Repo/manifests/$Tag" -Method Head -Headers $hdr -UseBasicParsing
        # Header comes back as a collection; normalise to a single string.
        $d = [string]$r.Headers['Docker-Content-Digest']
        return [pscustomobject]@{ Ok = $true; Digest = $d.Trim(); Status = [int]$r.StatusCode }
    }
    catch {
        # A transport failure (DNS, TLS, timeout) has no Response object at all;
        # report 0 so the caller never renders a blank status.
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        return [pscustomobject]@{ Ok = $false; Digest = $null; Status = $status }
    }
}

Write-Output ("=== GHCR state for {0} (namespace {1}) ===" -f $Version, $Ns)
Write-Output ''
Write-Output ("  {0,-32} {1,-12} {2,-12} {3}" -f 'image', $Version, 'latest', 'sync')
Write-Output ("  {0,-32} {1,-12} {2,-12} {3}" -f ('-' * 32), ('-' * 12), ('-' * 12), '----')

$bad = 0
foreach ($img in $images) {
    $repo = "$Ns/$img"
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
Write-Host ("All {0} images pullable anonymously for {1}. Source provenance: the tag names the commit it was built from." -f $images.Count, $Version) -ForegroundColor Green
exit 0
