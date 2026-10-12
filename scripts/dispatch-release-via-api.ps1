# Dispatch the build-ghcr workflow for a given tag.
#
# WHY A SCRIPT RATHER THAN A ONE-LINER. The token must never reach the console:
# this repo has a recorded incident of a credential being printed to a transcript,
# so the value is captured into a variable, used in a header, and never written to
# any stream. Only the HTTP status is printed. A one-liner inline in a shell makes
# that discipline easy to break by accident.
#
# Usage: pwsh -File scripts/dispatch-release-via-api.ps1 -Tag 0.1.22
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$Owner = 'JZKK720',
    [string]$Repo  = 'pacgate-ai-pr',
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

# Invoke an HTTP request and report Status / Body / Headers / Error as DATA rather
# than throwing, without relying on PowerShell 7-only parameters.
#
# WHY: `-SkipHttpErrorCheck` is PowerShell 7-only. Under the built-in Windows
# PowerShell 5.1 it raises ParameterBindingException BEFORE the request is sent, so
# on a client AIPC this dispatch could not reach the API at all. Same class as the
# defect fixed in deploy/client-bundle/install.ps1 (see
# deploy/DEFECT-ps51-native-stderr.md).
#
# The body of a non-2xx reply is read from $_.ErrorDetails.Message. Measured on both
# shells: PS 5.1's HttpWebResponse stream reads EMPTY (PowerShell has already
# consumed it) and PS 7's HttpResponseMessage.Content is DISPOSED by the time the
# catch runs, so neither of the obvious routes works.
function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'Get',
        [string]$Body,
        [hashtable]$Headers,
        [int]$TimeoutSec = 30
    )
    $result = [pscustomobject]@{ Status = $null; Body = ''; Headers = $null; Error = $null }
    try {
        $p = @{ Uri = $Uri; Method = $Method; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
        if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
        if ($Headers) { $p.Headers = $Headers }
        $r = Invoke-WebRequest @p
        $result.Status = [int]$r.StatusCode
        $result.Body = [string]$r.Content
        $result.Headers = $r.Headers
    }
    catch {
        $wr = $_.Exception.Response
        if ($wr) { $result.Status = [int]$wr.StatusCode }
        $body = [string]$_.ErrorDetails.Message
        if ($body) { $result.Body = $body }
        if (-not $wr -and -not $body) { $result.Error = "$($_.Exception.Message)" }
    }
    return $result
}

# Ask the configured credential helper for the GitHub token. `git credential fill`
# reads a request on stdin and writes protocol/host/username/password on stdout.
$req = "protocol=https`nhost=github.com`n`n"
$cred = $req | git credential fill 2>$null
$token = ($cred | Select-String -Pattern '^password=(.*)$').Matches[0].Groups[1].Value

if (-not $token) {
    Write-Host 'ERROR: the credential helper returned no token for github.com.' -ForegroundColor Red
    Write-Host '       Sign in to GitHub in this environment, or push once to prime it.' -ForegroundColor Yellow
    exit 1
}

$uri  = "https://api.github.com/repos/$Owner/$Repo/actions/workflows/build-ghcr.yml/dispatches"
$body = @{ ref = $Branch; inputs = @{ tag = $Tag } } | ConvertTo-Json -Compress -Depth 5

# Header built inline; $token is never echoed, interpolated into a log, or written
# to a file.
$resp = Invoke-ApiRequest -Uri $uri -Method Post -Body $body -TimeoutSec 30 -Headers @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$cred = $null   # drop the reference; nothing above materialized the value

if ($null -eq $resp.Status) {
    Write-Output "dispatch failed (no response): $($resp.Error)"
    exit 1
}
Write-Output "dispatch tag=$Tag -> HTTP $($resp.Status)  (204 = accepted)"
if ($resp.Status -ne 204) {
    Write-Output "body: $($resp.Body)"
    exit 1
}
