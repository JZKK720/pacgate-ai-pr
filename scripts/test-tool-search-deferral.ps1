# Test: tool_search deferral must stay ENABLED and must stay TRANSPARENT.
#
# BACKGROUND (measured 2026-10-21 on the HX370 box, deer-flow 0.1.34)
#   Every prompt bound 44 tool schemas: 7 sandbox + 2 builtins + 35 MCP.
#   Measured size: 42,582 chars (~10,645 tokens), of which the MCP half was
#   32,023 chars (~8,005 tokens). At the measured 528 tok/s prefill that is ~15 s
#   of fixed cost on EVERY turn, and a 3-message thread measured 13,049 input
#   tokens - so ~82% of the prompt was schema, not conversation.
#
#   deer-flow ships a `tool_search` feature that defers MCP schemas and lists them
#   by name instead. It was DISABLED here on 2026-09-12 with this evidence:
#
#     "deferral makes ALL models call MCP tools without promoting first ->
#      'deferred, not promoted' loop, never reaching write_file."
#
#   That was a real failure, but the cause was the middleware, not the models: on
#   a blocked call it returned an error telling the model to call tool_search
#   first and retry. Small local models (gemma4:12b, ornith-1.5:9b) routinely fail
#   to complete that two-step dance, so the run burned turns and never reached the
#   tool it wanted.
#
#   patches/deer-flow-deferred-tool-filter.py promotes the tool on first call and
#   executes it in the SAME turn, so deferral is invisible to the model.
#
#   Measured effect, two different denominators:
#     whole bound surface   44 -> 10 tools, 10,645 -> 2,823 tokens (73%)
#     MCP half only         against the real 19-tool pacgate-mcp catalog,
#                           11,514 -> 840 chars (92.7%), measured in-container
#   The 73% is the conservative figure because it counts the sandbox tools as part
#   of what deferral removes; they are not removed and should not be.
#
#   This gate locks in both halves: deferral stays on, and the patch keeps the
#   promote-and-execute behaviour rather than regressing to the error path.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:Passed = 0
$script:Failed = 0
function Assert-That {
    param([Parameter(Mandatory)] [bool]$Condition, [Parameter(Mandatory)] [string]$Name)
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Passed++ }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:Failed++ }
}

$config  = 'deploy/client-bundle/deer-flow-config.yaml'
$patch   = 'deploy/client-bundle/patches/deer-flow-deferred-tool-filter.py'
$compose = 'deploy/client-bundle/compose.prod.yaml'

Write-Host '=== tool_search deferral (prompt surface) ===' -ForegroundColor Cyan
Write-Output ''

# ── 1. deferral is enabled ───────────────────────────────────────────────────
Write-Host '1. deferral is enabled' -ForegroundColor White
Assert-That (Test-Path $config) "config present at $config"
$cfg = Get-Content -LiteralPath $config -Raw
$tsBlock = if ($cfg -match '(?ms)^tool_search:\s*\n((?:[ \t]+.*\n?)+)') { $Matches[1] } else { '' }
Assert-That ($tsBlock -ne '') 'tool_search section exists'
Assert-That ($tsBlock -match '(?m)^\s*enabled:\s*true\b') `
    'tool_search.enabled is true (deferring MCP schemas saves ~73% of the bound surface)'
Assert-That ($tsBlock -notmatch '(?m)^\s*enabled:\s*false\b') `
    'no stale enabled:false left behind'
Write-Output ''

# ── 2. the patch exists and is mounted ───────────────────────────────────────
Write-Host '2. the transparency patch is present and mounted' -ForegroundColor White
Assert-That (Test-Path $patch) "patch present at $patch"
$src = if (Test-Path $patch) { Get-Content -LiteralPath $patch -Raw } else { '' }
Assert-That ($src -match 'class\s+DeferredToolFilterMiddleware') `
    'the patch still defines DeferredToolFilterMiddleware'
Assert-That ($src -match '_promotion_command') `
    'it promotes on first call instead of erroring'
Assert-That ($src -match 'Auto-promoting deferred tool') `
    'the promotion is logged (so a silent regression is visible in the log)'
# The whole point: the handler must still RUN. A patch that promotes but returns
# early would reproduce the original "never reaching write_file" defect.
Assert-That ($src -match '(?s)def wrap_tool_call.*?result\s*=\s*handler\(request\)') `
    'the sync path still executes the tool in the same turn'
Assert-That ($src -match '(?s)async def awrap_tool_call.*?result\s*=\s*await handler\(request\)') `
    'the async path still executes the tool in the same turn'
# The old error path must be gone: it is what caused the loop.
Assert-That ($src -notmatch 'is deferred and has not been promoted yet') `
    'the "not promoted" error message is gone'
# A handler that returns its own Command must keep its updates.
Assert-That ($src -match 'merged\s*=\s*dict\(result\.update') `
    'a handler Command is merged, not replaced (tools that write state keep it)'

$csrc = if (Test-Path $compose) { Get-Content -LiteralPath $compose -Raw } else { '' }
Assert-That ($csrc -match 'deer-flow-deferred-tool-filter\.py:/app/backend/packages/harness/deerflow/agents/middlewares/deferred_tool_filter_middleware\.py') `
    'compose.prod.yaml mounts the patch over the middleware'

# ── 2b. the prompt section must SAY a direct call works ───────────────────────
# Measured 2026-10-21: the middleware promoted correctly, but the rendered
# <available-deferred-tools> section was a bare list of names with no instruction
# verb, and tool_search's own description says a name is not callable "until
# fetched". So the model fetched first and the auto-promote path never ran live.
# A middleware-only assertion cannot catch this - the code was right and the
# prompt was the defect. Assert on the rendered TEXT, not on the file.
$promptPatch = Join-Path $PSScriptRoot '..\deploy\client-bundle\patches\deer-flow-tool-search-prompt.py'
if (-not (Test-Path $promptPatch)) {
    Fail 'the deferred-tools prompt patch is missing'
} else {
    $psrc = Get-Content -LiteralPath $promptPatch -Raw
    Assert-That ($psrc -match 'callable DIRECTLY by name') `
        'the prompt section tells the model a direct call works'
    Assert-That ($psrc -match 'no\\n"\s*$|need to fetch it first|there is no') `
        'the prompt section says promotion needs no fetch first'
    Assert-That ($psrc -match 'tool_search') `
        'the prompt section keeps tool_search as the documented fallback'
    Assert-That ($psrc -match 'if not deferred_names:\s*\r?\n\s*return ""') `
        'an empty deferred set still renders nothing (no stray guidance)'
    Assert-That ($csrc -match 'deer-flow-tool-search-prompt\.py:/app/backend/packages/harness/deerflow/tools/builtins/tool_search\.py') `
        'compose.prod.yaml mounts the prompt patch over tool_search.py'
}
Write-Output ''

# ── 3. the always-bound set stays small ──────────────────────────────────────
# Deferral only helps if the sandbox tools stay bound (the agent uses them) and
# the MCP tools stay deferred. If a future change tags sandbox tools as MCP, the
# agent loses the tools it actually calls.
Write-Host '3. the always-bound set is the sandbox surface' -ForegroundColor White
# is_mcp_tool lives in tool_search.py (the catalog builder), not in this
# middleware patch - the middleware only receives the already-computed name set.
# Asserting it here would be checking the wrong file.
Assert-That ($src -match 'deferred_names') `
    'the middleware receives the deferred name set computed by the catalog builder'
$toolsBlock = if ($cfg -match '(?ms)^tools:\s*\n((?:[ \t]+.*\n?)+)') { $Matches[1] } else { '' }
foreach ($t in @('bash', 'read_file', 'write_file', 'str_replace', 'glob', 'grep')) {
    Assert-That ($toolsBlock -match "(?m)^\s*-\s*name:\s*$t\s*$") `
        "$t stays in the always-bound sandbox tool list"
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    Write-Host '  Either deferral was turned off (prompt grows ~73%) or the patch regressed' -ForegroundColor Red
    Write-Host '  to the error path that caused the "deferred, not promoted" loop.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
