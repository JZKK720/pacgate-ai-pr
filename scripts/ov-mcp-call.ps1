# Call an OpenViking MCP tool with auth + error handling handled.
#
# WHY THIS EXISTS: MCP tool FAILURES ride inside HTTP 200 responses with
# isError:true - checking the status code alone reports success for a failed
# call. This wrapper surfaces them as terminating errors, and handles the
# X-API-Key auth + SSE response format. Proven against the live server during
# the v0.1.25 audit (2026-10-09).
#
# NOTE: this OpenViking build (v0.4.16) is stateless per call - no
# initialize/session handshake is required. If a future build starts rejecting
# calls with "session required", re-add the initialize dance (initialize ->
# notifications/initialized -> call, carrying the mcp-session-id header).
#
# Usage:
#   .\scripts\ov-mcp-call.ps1 -Tool health
#   .\scripts\ov-mcp-call.ps1 -Tool find -Arguments '{"query":"settlement authority"}'
#   .\scripts\ov-mcp-call.ps1 -Tool remember -Arguments '{"messages":[{"role":"user","content":"Settlement authority confirmed."}]}'
#
# ARGUMENT FORM: pass -Arguments as a JSON OBJECT STRING. A PowerShell hashtable
# literal only works when the script is invoked in-session (dot-sourced or via
# & operator); `pwsh -File` stringifies hashtables to the lossy string
# "System.Collections.Hashtable", so the JSON-string form is the canonical CLI
# contract. The script also accepts a hashtable when called in-session.
#
# NOTE on remember: it takes messages:[{role,content}], NOT a bare string.
# A bare string fails with a pydantic "messages: Field required" error inside
# an HTTP 200 - exactly the failure mode this script surfaces loudly.
#
# Output: the parsed JSON-RPC result object. Throws (non-zero exit) when the
# tool reports isError:true, so it is safe inside gates and scripts.
param(
    [Parameter(Mandatory = $true)][string]$Tool,
    [Parameter(Mandatory = $false)][object]$Arguments = @{},
    [string]$BaseUrl = 'http://localhost:1933/mcp',
    # Defaults to OPENVIKING_ROOT_API_KEY from deploy/client-bundle/.env
    [string]$ApiKey
)
$ErrorActionPreference = 'Stop'

if (-not $ApiKey) {
    # Repo root = two levels up from this script (scripts/ov-mcp-call.ps1).
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $envFile = Join-Path $repoRoot 'deploy/client-bundle/.env'
    if (Test-Path $envFile) {
        $line = (Select-String -Path $envFile -Pattern '^OPENVIKING_ROOT_API_KEY=' | Select-Object -First 1).Line
        if ($line) { $ApiKey = $line.Substring('OPENVIKING_ROOT_API_KEY='.Length).Trim() }
    }
}
if (-not $ApiKey) { throw 'no API key: pass -ApiKey or set OPENVIKING_ROOT_API_KEY in deploy/client-bundle/.env' }

# ARGUMENT MARSHALLING: `pwsh -File` CANNOT pass a hashtable - it arrives as the
# lossy string "System.Collections.Hashtable". The canonical CLI form is a JSON
# OBJECT STRING:  -Arguments '{"query":"test"}'
# (Direct in-session invocation with a real hashtable also works.)
if ($Arguments -is [string]) {
    $trimmed = $Arguments.Trim()
    if ($trimmed -match 'System\.Collections\.Hashtable' -or $trimmed -eq '') {
        $Arguments = @{}
    } else {
        try { $Arguments = $trimmed | ConvertFrom-Json }
        catch { throw "-Arguments is a string but not valid JSON: $trimmed" }
    }
}

$callBody = @{ jsonrpc = '2.0'; id = 1; method = 'tools/call'; params = @{ name = $Tool; arguments = $Arguments } } | ConvertTo-Json -Depth 12 -Compress
$resp = Invoke-WebRequest -Uri $BaseUrl -Method Post -Headers @{ 'X-API-Key' = $ApiKey; Accept = 'application/json, text/event-stream' } `
    -ContentType 'application/json' -Body $callBody -TimeoutSec 300 -SkipHttpErrorCheck

$dataLine = ($resp.Content -split "`n" | Where-Object { $_ -match '^data:' } | Select-Object -First 1)
if (-not $dataLine) { throw "no SSE data line in response (HTTP $($resp.StatusCode)): $($resp.Content.Substring(0, [Math]::Min(200, $resp.Content.Length)))" }
$json = $dataLine.Substring(5).Trim() | ConvertFrom-Json

if ($json.error) { throw "JSON-RPC error: $($json.error.message)" }
$result = $json.result
if ($result.isError) {
    $text = ($result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
    throw "tool '$Tool' reported isError:true: $text"
}
return $result

