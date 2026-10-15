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

# Invoke an HTTP request and report Status / Body / Headers / Error as DATA rather
# than throwing, without relying on PowerShell 7-only parameters.
#
# WHY: `-SkipHttpErrorCheck` is PowerShell 7-only. Under the built-in Windows
# PowerShell 5.1 it raises ParameterBindingException BEFORE the request is sent,
# so on a client AIPC this script cannot call the MCP server at all. Same class as
# the defect fixed in deploy/client-bundle/install.ps1 (see
# deploy/DEFECT-ps51-native-stderr.md).
#
# The body of a non-2xx reply is read from $_.ErrorDetails.Message. Measured on
# both shells: PS 5.1's HttpWebResponse stream reads EMPTY (PowerShell has already
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

# -SkipHttpErrorCheck is PowerShell 7-only and threw ParameterBindingException on
# the built-in 5.1, so this script could not call the server at all on a client
# AIPC. A JSON-RPC-level failure still arrives as HTTP 200 and is handled below,
# so a non-2xx here is a real transport error and is surfaced with its body.
$resp = Invoke-ApiRequest -Uri $BaseUrl -Method Post -Body $callBody `
    -Headers @{ 'X-API-Key' = $ApiKey; Accept = 'application/json, text/event-stream' } `
    -TimeoutSec 300
if ($null -eq $resp.Status) {
    throw "no HTTP response from $BaseUrl : $($resp.Error)"
}
if ($resp.Status -lt 200 -or $resp.Status -ge 300) {
    throw "HTTP $($resp.Status) from $BaseUrl : $($resp.Body)"
}

$dataLine = ($resp.Body -split "`n" | Where-Object { $_ -match '^data:' } | Select-Object -First 1)
if (-not $dataLine) { throw "no SSE data line in response (HTTP $($resp.Status)): $($resp.Body.Substring(0, [Math]::Min(200, $resp.Body.Length)))" }
$json = $dataLine.Substring(5).Trim() | ConvertFrom-Json

if ($json.error) { throw "JSON-RPC error: $($json.error.message)" }
$result = $json.result
if ($result.isError) {
    $text = ($result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
    throw "tool '$Tool' reported isError:true: $text"
}
return $result

