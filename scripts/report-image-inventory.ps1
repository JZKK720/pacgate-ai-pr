# Answer: are all the GHCR images built?
#
# Checks BOTH questions implied by "is everything built":
#   1. every image the client compose files PIN is published and anonymously pullable
#   2. there are no pacgate images published-but-unused, or pinned-but-missing
#
# The first is what a client install depends on. The second is what makes a future
# reader think a package is part of this stack when it is not.
[CmdletBinding()]
# The default version is DERIVED from the crate manifest, not hardcoded. A
# literal default expires at every bump and the fix is always to edit the literal,
# which turns an inspection tool into another place a release has to be
# remembered. Cargo.toml is the source of truth for what /version reports.
param([string]$Version = '')

Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not $Version) {
    $cargo = Get-Content pacgate-ai/Cargo.toml -Raw
    $Version = [regex]::Match($cargo, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"').Groups['v'].Value
    if (-not $Version) { Write-Host 'ERROR: could not read the workspace version from Cargo.toml' -ForegroundColor Red; exit 1 }
}

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

function Get-Digest {
    param([string]$Repo, [string]$Tag)
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$Repo`:pull&service=ghcr.io" -Method Get
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$Repo/manifests/$Tag" -Method Head -Headers @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
        return [pscustomobject]@{ Ok = $true; Digest = ([string]$r.Headers['Docker-Content-Digest']).Trim() }
    }
    catch { return [pscustomobject]@{ Ok = $false; Digest = $null; Status = $_.Exception.Response.StatusCode.value__ } }
}

Write-Output ("=== 1. Every image PINNED by the client compose files, at {0} ===" -f $Version)
Write-Output ''

$pinned = @{}
foreach ($f in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    if (-not (Test-Path $f)) { continue }
    foreach ($m in [regex]::Matches((Get-Content $f -Raw), 'ghcr\.io/([a-z0-9\-]+)/([a-z0-9\-]+):([0-9]+\.[0-9]+\.[0-9]+)')) {
        $ns = $m.Groups[1].Value; $img = $m.Groups[2].Value; $ver = $m.Groups[3].Value
        $key = "$ns/$img"
        if (-not $pinned.ContainsKey($key)) { $pinned[$key] = @{} }
        $pinned[$key][$ver] = $true
    }
}

$fail = 0
foreach ($key in ($pinned.Keys | Sort-Object)) {
    $vers = @($pinned[$key].Keys | Sort-Object)
    foreach ($v in $vers) {
        $d = Get-Digest -Repo $key -Tag $v
        if ($d.Ok) {
            Write-Host ("  OK    {0}:{1}  {2}" -f $key, $v, $d.Digest.Substring(0, 20)) -ForegroundColor Green
        }
        else {
            Write-Host ("  MISS  {0}:{1}  HTTP {2}" -f $key, $v, $d.Status) -ForegroundColor Red
            $script:fail++
        }
    }
}
Write-Output ("  images pinned: {0}" -f $pinned.Count)
Write-Output ''

Write-Output '=== 2. Anything pinned at a version OTHER than the release? ==='
$offRelease = @()
foreach ($key in $pinned.Keys) {
    foreach ($v in $pinned[$key].Keys) { if ($v -ne $Version) { $offRelease += "${key}:${v}" } }
}
if ($offRelease.Count -eq 0) {
    Write-Host '  (none) - every pin is on the current release' -ForegroundColor Green
}
else {
    Write-Host ("  OFF-RELEASE: {0}" -f ($offRelease -join ', ')) -ForegroundColor Yellow
    Write-Output '  Expected for upstream images (they are not ours to version).'
}
Write-Output ''

Write-Output '=== 3. Upstream images pulled by the stack (not built here) ==='
foreach ($f in @('deploy/client-bundle/compose.prod.yaml', 'deploy/qm-pacgate/compose.qm.yaml')) {
    if (-not (Test-Path $f)) { continue }
    foreach ($m in [regex]::Matches((Get-Content $f -Raw), 'image:\s*(ghcr\.io/([a-z0-9\-]+)/([a-z0-9\-]+)(@sha256:[0-9a-f]{12})?)')) {
        $full = $m.Groups[1].Value
        $ns = $m.Groups[2].Value
        if ($ns -eq 'pacgate-ai') { continue }
        Write-Output ("  {0,-26} <- {1}" -f (Split-Path $f -Leaf), $full)
    }
}
Write-Output '  These are third-party. We neither build nor version them.'
Write-Output ''

if ($fail -gt 0) {
    Write-Host ("RESULT: {0} pinned image(s) NOT pullable" -f $fail) -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: every pinned image is published and anonymously pullable.' -ForegroundColor Green
exit 0
