# Final end-to-end state check for the 0.1.13 delivery.
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

Write-Host '=== Delivery state ==='
Write-Output ''

$origin = (git rev-parse HEAD).Trim()
$fork = ((git ls-remote https://github.com/pacgate-ai/pacgate-ai-pr.git refs/heads/main) -split '\s+')[0]
Line 'origin HEAD' $origin.Substring(0, 7) $true
Line 'fork HEAD' $fork.Substring(0, 7) $true
Line 'fork == origin' $(if ($fork -eq $origin) { 'yes' } else { 'NO' }) ($fork -eq $origin)

# Pins must all read 0.1.13
$prod = Get-Content deploy/client-bundle/compose.prod.yaml -Raw
$bundle = Get-Content deploy/client-bundle/compose.bundle.yaml -Raw
$prodPins = ([regex]::Matches($prod, 'ghcr\.io/pacgate-ai/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups['v'].Value })
$bundlePins = ([regex]::Matches($bundle, 'ghcr\.io/pacgate-ai/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups['v'].Value })
$allPins = @($prodPins) + @($bundlePins)
Line 'compose.prod.yaml pins' ($prodPins -join ', ') (@($prodPins | Where-Object { $_ -ne '0.1.13' }).Count -eq 0)
Line 'compose.bundle.yaml pins' ($bundlePins -join ', ') (@($bundlePins | Where-Object { $_ -ne '0.1.13' }).Count -eq 0)

# Cargo workspace version
$cargo = Get-Content pacgate-ai/Cargo.toml -Raw
$cv = ([regex]::Match($cargo, '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"')).Groups['v'].Value
Line 'Cargo workspace version' $cv ($cv -eq '0.1.13')

Write-Output ''
Write-Host '=== GHCR images (anonymous pull) ==='
Write-Output ''
$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
foreach ($img in @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate')) {
    $repo = "pacgate-ai/$img"
    $status = 'ERROR'
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$repo`:pull&service=ghcr.io" -Method Get
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$repo/manifests/0.1.13" -Method Head -Headers @{ Authorization = "Bearer $($tok.token)"; Accept = $accept }
        $status = "$($r.StatusCode)"
    }
    catch { $status = "$($_.Exception.Response.StatusCode.value__)" }
    # ${img} not $img - in a double-quoted string PowerShell reads "$img:" as a
    # SCOPE qualifier (like $env:), not a variable followed by a colon, so
    # "$img:0.1.13" renders as just the version. Same family of bug as using
    # $Args as a parameter name.
    Line "${img}:0.1.13" $status ($status -eq '200')
}

Write-Output ''
if ($ok) {
    Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host 'SOME CHECKS FAILED' -ForegroundColor Red
exit 1
