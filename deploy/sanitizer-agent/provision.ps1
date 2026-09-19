# Create (or refresh) the 'sanitizer' agent in deer-flow.
# Idempotent: an existing sanitizer agent is updated, not duplicated.
# Usage: powershell -File deploy/sanitizer-agent/provision.ps1 [-DeerFlowUrl http://localhost:8089]
param(
    [string]$DeerFlowUrl = "http://127.0.0.1:8089"
)
$ErrorActionPreference = 'Stop'

$soul = Get-Content -Raw (Join-Path $PSScriptRoot 'SOUL.md')
$description = 'Client-identity sanitizer: redacts party/project identifiers before cloud analysis. Review surface only - the mapping stays sealed.'

$body = @{
    name        = 'sanitizer'
    description = $description
    soul        = $soul
} | ConvertTo-Json -Depth 4

# deer-flow's agent create returns 400 when the name exists; use update then.
$existing = Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -TimeoutSec 10 -ErrorAction SilentlyContinue
$hasSanitizer = $false
if ($existing -and $existing.agents) {
    $hasSanitizer = ($existing.agents | Where-Object { $_.name -eq 'sanitizer' }).Count -gt 0
}

if ($hasSanitizer) {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents/sanitizer" -Method Put -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent updated'
} else {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent created'
}
