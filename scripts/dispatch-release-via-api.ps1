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
try {
    $resp = Invoke-WebRequest -Uri $uri -Method Post -Body $body `
        -Headers @{
            Authorization          = "Bearer $token"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        } `
        -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 30
    Write-Output "dispatch tag=$Tag -> HTTP $($resp.StatusCode)  (204 = accepted)"
    if ($resp.StatusCode -ne 204) {
        Write-Output "body: $($resp.Content)"
        exit 1
    }
}
catch {
    Write-Output "dispatch failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # Drop the reference; nothing above should have materialized the value.
    $token = $null
    $cred  = $null
}
