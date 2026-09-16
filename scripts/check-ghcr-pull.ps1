# Anonymous GHCR pull probe.
# 200 = public, 401/403 = private, 404 = tag or repo does not exist.
# Usage: .\scripts\check-ghcr-pull.ps1 -Targets "pacgate-ai/pacgate-api:latest","jzkk720/pacgate-api:0.1.2"
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Targets
)

$Accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"

function Test-GhcrImage {
    param([string]$Ref)

    # Split "ns[/sub]/img[:tag]" and "ns[/sub]/img@sha256:<digest>" alike.
    $ns, $rest = $Ref -split '/', 2
    if (-not $rest) { return [pscustomobject]@{ Ref = $Ref; Result = 'BAD-REF' } }

    if ($rest -match '@') {
        $imgName, $manifestRef = $rest -split '@', 2
    }
    elseif ($rest -match ':') {
        $imgName, $manifestRef = $rest -split ':', 2
    }
    else {
        $imgName = $rest
        $manifestRef = 'latest'
    }

    $scope = "repository:{0}/{1}:pull" -f $ns, $imgName

    $token = $null
    try {
        $token = (Invoke-RestMethod -Uri "https://ghcr.io/token?scope=$scope" -ErrorAction Stop).token
    }
    catch {
        return [pscustomobject]@{ Ref = $Ref; Result = 'TOKEN-FAILED' }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{ Ref = $Ref; Result = 'ANON-NOT-PERMITTED' }
    }

    try {
        $resp = Invoke-WebRequest -Uri "https://ghcr.io/v2/$ns/$imgName/manifests/$manifestRef" `
            -Method Head `
            -Headers @{ Accept = $Accept; Authorization = "Bearer $token" } `
            -ErrorAction Stop
        return [pscustomobject]@{ Ref = $Ref; Result = "HTTP $($resp.StatusCode) PUBLIC" }
    }
    catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'ERR' }
        $verdict = switch ("$code") {
            '401' { 'PRIVATE' }
            '403' { 'PRIVATE/forbidden' }
            '404' { 'NOT-FOUND (absent, or private-and-hidden)' }
            default { 'ERROR' }
        }
        return [pscustomobject]@{ Ref = $Ref; Result = "HTTP $code $verdict" }
    }
}

$Targets | ForEach-Object { Test-GhcrImage -Ref $_ } |
    ForEach-Object { '{0,-52} => {1}' -f $_.Ref, $_.Result }
