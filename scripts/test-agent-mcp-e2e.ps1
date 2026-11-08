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

# ── E1c: the names an assistant tool_call ACTUALLY carries are SERVER-QUALIFIED ─
# MEASURED 2026-11-08, on the 0.2.32 stack. deer-flow registers MCP tools as
# `<serverName>_<toolName>`, so a call to `pacgate_list_connectors` on the server
# named `pacgate` is recorded as `pacgate_pacgate_list_connectors`:
#
#   deerflow.agents.middlewares.deferred_tool_filter_middleware - INFO -
#     Auto-promoting deferred tool 'pacgate_pacgate_list_connectors' on first call
#
# E3 used to exact-match the bare names above against that recorded name, so it
# could NEVER pass on a run that called a pacgate tool. The tool loop was working -
# pacgate-mcp answered 200 and the tool auto-promoted - while the gate reported a
# failure. A gate that cannot pass is as useless as one that cannot fail, and this
# one is worse than most because its FAIL message reads exactly like a real
# regression ("the agent replied without calling one").
#
# The prefix is READ from the live extensions config, not hardcoded: renaming the
# server must change the accepted names with it, and a config that loses the
# `pacgate` server should fail loudly rather than silently accept bare names.
$extCfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/deer-flow-extensions-config.json'
$serverNames = @()
if (Test-Path $extCfg) {
    try {
        $srv = (Get-Content $extCfg -Raw | ConvertFrom-Json).mcpServers
        $serverNames = @($srv.PSObject.Properties.Name)
    } catch {
        CannotCheck "could not parse $extCfg ($($_.Exception.Message))"
    }
}
Check 'E1c the extensions config names the pacgate MCP server' `
      ($serverNames -contains 'pacgate') `
      "servers: $(($serverNames | Sort-Object) -join ', ')"

# Accept BOTH forms. The qualified form is what is recorded; the bare form is kept
# so this gate still works against a deer-flow that does not namespace, and so a
# future upstream change back to bare names does not produce a false FAIL.
$mcpToolQualified = @($mcpTools | ForEach-Object { "pacgate_$_" })
$mcpToolsAccepted  = @($mcpTools + $mcpToolQualified | Sort-Object -Unique)
Write-Host ("         accepted call names: {0} (+{1} server-qualified)" -f `
    ($mcpTools.Count), ($mcpToolQualified.Count)) -ForegroundColor DarkGray

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

# ── E1b: the model the picker DEFAULTs to must actually be installed ────────
# WHY THIS EXISTS (measured 2026-11-05, this box)
#
# A run that omits `context.model_name` resolves to `models[0]` in the
# deer-flow-config `models:` list. On this machine models[0] is
# `nemotron-bolt-7b-local` -> `nemotron-3.5-bolt:e4b-q8_0`, and that tag was
# NEVER PULLED. Every such run returned in 0.7 s with:
#
#   status=error, deerflow_error_fallback=true,
#   "LLM request failed: Error code: 404 - model 'nemotron-3.5-bolt:e4b-q8_0'
#    not found"
#
# Meanwhile a run that explicitly selected an installed model succeeded, so the
# stack looked half-working and the model picked in the UI got blamed. The
# failure is entirely avoidable: it is a missing `ollama pull`, and the roster
# already declares which tags must exist. Nothing checked the DEFAULT one.
#
# This asserts the roster's first entry by TAG, against Ollama directly, so the
# cause is named here instead of being discovered from a UI screenshot.
try {
    $roster = (Invoke-WebRequest -Uri "$NginxUrl/api/models" -WebSession $session -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json
    $defaultEntry = @($roster.models) | Select-Object -First 1
    $defaultTag = if ($defaultEntry) { [string]$defaultEntry.model } else { '' }
    Check 'E1b the picker roster names a default model tag' ([bool]$defaultTag) 'models[0] carried no model tag'

    if ($defaultTag) {
        $installed = @()
        try {
            $tags = (Invoke-WebRequest -Uri 'http://localhost:11434/api/tags' -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
            $installed = @($tags.models | ForEach-Object { $_.name })
        } catch { }

        if ($installed.Count -eq 0) {
            Write-Host "  [SKIP] E1b could not read ollama /api/tags; cannot confirm '$defaultTag'" -ForegroundColor Yellow
        } else {
            $have = $installed -contains $defaultTag
            Check "E1b the DEFAULT picker model '$defaultTag' is installed" $have `
                "models[0] is '$($defaultEntry.name)' -> '$defaultTag', which is NOT in ollama. Any run that omits context.model_name resolves to it and fails in <1 s with a 404 'model not found' - pull it: ollama pull $defaultTag"
        }
    }
} catch {
    Write-Host "  [SKIP] E1b could not read the picker roster ($($_.Exception.Message))" -ForegroundColor Yellow
}

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

    # DIAGNOSE, do not guess. This path used to blame the prompt template
    # unconditionally, and on 2026-11-04 that sent the investigation to the wrong
    # place: the run had not raised KeyError at all, the model was simply running on
    # the CPU at ~1-2 tokens/second, so /runs/wait never returned within the client
    # timeout. A gate that names the wrong cause is worse than one that only says
    # "failed", so the GPU state is checked before the message is chosen.
    $hint = 'if the prompt template gained a stray brace, apply_prompt_template raises KeyError here'
    $gpuNote = ''
    try {
        $gpu = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/test-ollama-gpu-residency.ps1') -WarnOnly 2>&1 | Out-String
        if ($gpu -match 'NO GPU device|ONLY CPU|on the CPU') {
            $hint = "the model is NOT on a GPU, so a single step takes minutes - this is the hang, not a template bug"
            $gpuNote = 'ollama GPU gate: ' + (($gpu -split "`n" | Where-Object { $_ -match 'FAIL|SKIP|PASS' } | ForEach-Object { $_.Trim() }) -join ' | ')
        }
    } catch { }

    Check 'E2 an agent run completes (the KeyError-class defect)' $false `
          "the run failed with HTTP $code after ~${TimeoutSec}s - $hint"
    if ($gpuNote) { Write-Host "         $gpuNote" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor Red
    exit 1
}
Check 'E2 an agent run completes (the KeyError-class defect)' ($r.StatusCode -eq 200) "got HTTP $($r.StatusCode)"

# ── E2b: the run did not degrade into an error fallback ──────────────────────
# MEASURED 2026-11-05: with the LOW-tier model absent, deer-flow still returns
# HTTP 200 for `/runs/wait`. It swallows the upstream 404 into an `ai` message whose
# content is "LLM request failed: Error code: 404 ... model 'x' not found", marked
# `deerflow_error_fallback: true`. E2 alone therefore cannot tell a real answer from
# a total model outage. The marker is explicit and worth asserting directly.
#
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

$fallback = @($msgs | Where-Object { $_.additional_kwargs -and $_.additional_kwargs.deerflow_error_fallback })
$why = if ($fallback.Count -gt 0) { ($fallback | ForEach-Object { $_.additional_kwargs.error_detail } | Select-Object -First 1) } else { $null }
Check 'E2b the run produced an answer, not an LLM error fallback' ($fallback.Count -eq 0) `
    "deer-flow returned an error fallback instead of a reply: $why"

# ── E3/E4: it actually called an MCP tool ─────────────────────────────────────
# STRUCTURED RECORDS ONLY. WHY (measured 2026-11-05, this box):
#   The previous version scanned the WHOLE serialized payload for an advertised tool
#   name. But the gate's own prompt says "Call the pacgate_list_connectors tool", and
#   that prompt is echoed back inside the human message - so the check matched ITS OWN
#   PROMPT and reported `called: pacgate_list_connectors` on a run where the model had
#   404'd and no tool ran at all. It was green on a totally broken agent lane, and it
#   was green for the same reason it was green during the 0.1.33 era: the assertion
#   could not distinguish "the agent called a tool" from "the word appears somewhere".
#   A tool call must therefore be read from a `tool_calls` field on an ASSISTANT
#   message, or from a tool-role message that answers one - never from free text, and
#   never from a human turn.
$called = @()
$toolRecord = $false
foreach ($m in $msgs) {
    # A human turn is the PROMPT. It can name every tool and prove nothing.
    if ($m.type -in @('human', 'user')) { continue }

    if ($m.tool_calls) {
        foreach ($tc in @($m.tool_calls)) {
            $name = if ($tc.name) { $tc.name } elseif ($tc.function -and $tc.function.name) { $tc.function.name } else { $null }
            if ($name -and ($mcpToolsAccepted -contains $name)) { $called += $name; $toolRecord = $true }
        }
    }
    if ($m.additional_kwargs -and $m.additional_kwargs.tool_calls) {
        foreach ($tc in @($m.additional_kwargs.tool_calls)) {
            $name = if ($tc.name) { $tc.name } elseif ($tc.function -and $tc.function.name) { $tc.function.name } else { $null }
            if ($name -and ($mcpToolsAccepted -contains $name)) { $called += $name; $toolRecord = $true }
        }
    }
    if ($m.additional_kwargs -and $m.additional_kwargs.tool_call_id) { $toolRecord = $true }
    if ($m.tool_call_id) { $toolRecord = $true }
    if ($m.type -in @('tool', 'tool_result')) { $toolRecord = $true }
}
$called = @($called | Sort-Object -Unique)

Check 'E3 the run invoked at least one real MCP tool' `
      ($called.Count -ge 1) `
      'no assistant tool_calls record names an advertised MCP tool - the agent replied without calling one (a tool name appearing only in the prompt does not count)'
if ($called.Count -ge 1) {
    Write-Host ("         called: {0}" -f ($called -join ', ')) -ForegroundColor DarkGray
}

Check 'E4 a tool-call record came back (the call did not fail after issuance)' `
      $toolRecord `
      'a tool was named but no tool-call record is present - the call was issued and produced nothing'

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
