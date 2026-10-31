# Guard: an agent run must actually INVOKE an MCP tool, end to end.
#
# WHY THIS EXISTS (measured 2026-10-31)
#
# smoke-full-stack.ps1 says so itself, at the deer-flow lane:
#
#   "agent->MCP invocation NOT exercised: it needs a deer-flow session, and there is
#    no committed agent-run E2E. Do not read this lane as fully verified."
#
# Everything below that gap stayed green while the gap existed:
#
#   test-mcp-tool-surface.ps1     proves pacgate-mcp ADVERTISES its tools. It never
#                                 starts an agent, so a tool that advertises but
#                                 cannot be CALLED passes.
#   test-mcp-argument-paths.ps1   proves MCP ARGUMENTS get path-translated. It drives
#                                 a synthetic ToolNode, not the real graph.
#   test-document-generation-e2e  runs a workflow through pacgate-api, which is a
#                                 different path from the agent's tool loop.
#
# The measured cost of that gap: a prompt change introduced one unescaped brace into
# SYSTEM_PROMPT_TEMPLATE, str.format() read `{"command":` as a format field, and EVERY
# agent run died at construction with KeyError: '"command"'. The full suite was green.
# Only a live chat run caught it, by accident.
#
# So this gate's real job is to make "the agent can still start and call a tool" an
# assertion rather than something a human happens to notice.
#
# WHAT IS ASSERTED
#   E1  deer-flow is healthy and authenticates; the tool names are derived from source
#   E2  an agent run COMPLETES (the KeyError-class defect dies here)
#   E3  the run invoked at least one real advertised MCP tool - a text-only reply
#       does not count, because that is exactly what a broken tool loop produces
#   E4  a tool-call record came back, so the call did not fail after being issued
#
# Exit 2 means CANNOT CHECK (stack down / no credential) and is never a pass.
[CmdletBinding()]
param(
    [string]$NginxUrl    = 'http://localhost:8089',
    [string]$Email       = 'admin@pacgate-law.com',
    [string]$Password    = '',
    [int]$TimeoutSec     = 300,
    [string]$ServerFile  = 'deploy/pacgate-mcp/server.py'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== agent -> MCP end to end ===' -ForegroundColor Cyan

# ── E1: the tool names come from SOURCE, not a hardcoded list ────────────────
# Same derivation test-mcp-tool-surface.ps1 uses: adding a tool needs no edit here,
# while REMOVING one still fails, because the file and the running server must agree.
if (-not (Test-Path $ServerFile)) { CannotCheck "server source not found: $ServerFile" }
$mcpTools = @([regex]::Matches((Get-Content $ServerFile -Raw),
    '(?m)^(?:async )?def\s+(pacgate_[a-z0-9_]+)\(') | ForEach-Object { $_.Groups[1].Value })
$mcpTools = @($mcpTools | Sort-Object -Unique)
Check 'E1 the pacgate MCP tool names were derived from source' `
      ($mcpTools.Count -ge 5) `
      "derived $($mcpTools.Count) tool name(s) from $ServerFile"
Write-Host ("         tools: {0}" -f (($mcpTools | Select-Object -First 6) -join ', ')) -ForegroundColor DarkGray

# ── credentials ──────────────────────────────────────────────────────────────
# The deer-flow admin is NOT the pacgate-api principal. Resolve exactly as
# test-model-picker-e2e.ps1 does, including the env-var name, which a first draft of
# this gate would have guessed as a bare `password =` key.
function Resolve-DeerFlowPassword {
    if ($Password) { return $Password }
    if ($env:PACGATE_DEERFLOW_PASSWORD) { return $env:PACGATE_DEERFLOW_PASSWORD }
    $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.deer-flow-credentials'
    if (Test-Path -LiteralPath $f) {
        $m = Select-String -LiteralPath $f -Pattern '^\s*PACGATE_DEERFLOW_PASSWORD\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    return $null
}
$dfPassword = Resolve-DeerFlowPassword
if (-not $dfPassword) {
    CannotCheck 'no deer-flow credential (set -Password, PACGATE_DEERFLOW_PASSWORD, or deploy/client-bundle/.deer-flow-credentials)'
}

# deer-flow auth is a COOKIE SESSION plus a CSRF header, not a bearer token. Every
# one of these details is load-bearing and was copied from the gate that passes:
# `username=` (not `email=`, even though the JSON API uses `email`), `-WebSession`,
# and X-CSRF-Token read from the `csrf_token` cookie.
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Get-Csrf {
    ($session.Cookies.GetCookies($NginxUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value
}

try {
    $null = Invoke-WebRequest -Uri "$NginxUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = $Email; password = $dfPassword } `
        -WebSession $session -UseBasicParsing -TimeoutSec 25
} catch {
    $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
    CannotCheck "deer-flow login failed at $NginxUrl (HTTP $code)"
}
Check 'E1 authenticated to deer-flow' ($null -ne (Get-Csrf))

# ── E2: an agent run completes ────────────────────────────────────────────────
try {
    $thread = (Invoke-WebRequest -Uri "$NginxUrl/api/threads" -Method Post -Body '{}' `
            -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = (Get-Csrf) } `
            -WebSession $session -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
} catch {
    CannotCheck "POST /api/threads failed ($($_.Exception.Message))"
}
$threadId = $thread.thread_id
if (-not $threadId) { CannotCheck 'POST /api/threads returned no thread_id' }

# The prompt is chosen to REQUIRE a tool: "list the connectors" has no answer the
# model can produce from its own weights, so a reply with no tool call means the tool
# loop is not working - which is precisely what is under test.
# `role = 'user'` on input, not `type` (the payload uses `role` going in and `type`
# coming back out; conflating them is how this kind of gate first reports a false FAIL).
$body = @{
    input   = @{
        messages = @(@{
            role    = 'user'
            content = 'Call the pacgate_list_connectors tool and tell me which connectors exist. You must call the tool; do not answer from memory.'
        })
    }
    context = @{ thread_id = $threadId }
} | ConvertTo-Json -Depth 12 -Compress

try {
    $r = Invoke-WebRequest -Uri "$NginxUrl/api/threads/$threadId/runs/wait" -Method Post -Body $body `
        -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = (Get-Csrf) } `
        -WebSession $session -UseBasicParsing -TimeoutSec $TimeoutSec
} catch {
    $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
    Check 'E2 an agent run completes (the KeyError-class defect)' $false `
          "the run failed with HTTP $code - if the prompt template gained a stray brace, apply_prompt_template raises KeyError here"
    Write-Host ''
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor Red
    exit 1
}
Check 'E2 an agent run completes (the KeyError-class defect)' ($r.StatusCode -eq 200) "got HTTP $($r.StatusCode)"

# ── E3/E4: it actually called an MCP tool ─────────────────────────────────────
# Accept both payload shapes: `messages` at the top level of a runs/wait response, or
# nested under `.values` from /state. Assuming one is how the sibling gate first
# reported a false FAIL on a healthy stack.
$json = $null
try { $json = $r.Content | ConvertFrom-Json } catch { }
$msgs = @()
if ($json) {
    if ($json.messages) { $msgs = @($json.messages) }
    elseif ($json.values -and $json.values.messages) { $msgs = @($json.values.messages) }
}
$serialized = if ($msgs.Count -gt 0) { ($msgs | ConvertTo-Json -Depth 20) } else { [string]$r.Content }

# A text reply alone does NOT count. Look for an advertised tool name appearing in a
# tool-call record.
$called = @()
foreach ($tn in $mcpTools) {
    if ($serialized -match [regex]::Escape($tn)) { $called += $tn }
}
$called = @($called | Sort-Object -Unique)

Check 'E3 the run invoked at least one real MCP tool' `
      ($called.Count -ge 1) `
      'none of the advertised tool names appear in the run payload - the agent replied without calling a tool'
if ($called.Count -ge 1) {
    Write-Host ("         called: {0}" -f ($called -join ', ')) -ForegroundColor DarkGray
}

Check 'E4 a tool-call record came back (the call did not fail after issuance)' `
      ($serialized -match 'tool_call_id|tool_calls|ToolMessage|tool_result') `
      'a tool was named but no tool-call record is present - the call was issued and produced nothing'

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
