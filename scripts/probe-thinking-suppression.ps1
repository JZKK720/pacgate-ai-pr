# Does a local model return CONTENT, or burn its whole budget on hidden reasoning?
#
# WHY THIS EXISTS (2026-11-04)
#
# This is the defect that makes every pacgate-ai document and prompt "go through
# endless steps without getting any end-result":
#
#   * the model emits hidden `reasoning` tokens,
#   * the visible content comes back EMPTY,
#   * the HTTP response is 200 and finish_reason is "length",
#   * every caller sees success, so nothing reports an error.
#
# Already recorded in this repo twice (pacgate-core/src/lib.rs and the gemma4
# picker entries in deer-flow-config.yaml), and re-measured 2026-11-04:
#
#   gemma4:12b-it-qat, title prompt, max_tokens 400, no suppression
#     -> 400/400 tokens, 986 chars of reasoning, content = ""  (finish=length)
#
# The fix is NOT model size. A 7.5B and a 74B both fail the same way. The fix is
# sending the right suppression for the endpoint, and WHICH knob works differs
# per backend:
#
#   /api/chat   (native)      -> `think: false`
#   /v1/chat   (OpenAI compat) -> `reasoning_effort: "none"`   (`think` is ignored)
#
# This probe measures all of that per model against BOTH endpoints, so a picker
# entry is configured on evidence rather than on a comment copied from another
# model.
#
# WHAT IT REPORTS PER VARIANT
#   content_chars  visible output length - 0 means the run produced nothing
#   reasoning_chars hidden reasoning length
#   tokens / finish  budget consumed and why it stopped
#   ok             content non-empty AND finish != "length"
#
# Usage:
#   pwsh -File scripts/probe-thinking-suppression.ps1
#   pwsh -File scripts/probe-thinking-suppression.ps1 -Models nemotron-3.5-bolt:e4b-q8_0 -Markdown
[CmdletBinding()]
param(
    [string]$OllamaUrl = 'http://localhost:11434',

    [string[]]$Models = @(
        'nemotron-3.5-bolt:e4b-q8_0',
        'nemotron-3.5-bolt:74b-a9b-iq2',
        'gemma4:12b-it-qat'
    ),

    # A realistic utility budget. Utility lanes (title, memory, summarizer) are
    # the ones that fire constantly and are most damaged by a reasoning burn.
    [int]$MaxTokens = 300,

    # Free host RAM floor; loading a 24 GB model on a 61 GB box with 24 GB
    # already committed to WSL will freeze the desktop (measured 2026-11-04).
    [double]$MinHeadroomGB = 4,

    [switch]$Markdown
)

$ErrorActionPreference = 'Continue'
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# A title-shaped prompt: short answer expected, which is exactly where a
# reasoning model with no suppression spends everything and returns "".
$Prompt = 'Summarise this matter in a 6-word title: 浦江新城二期设计施工验收总承包合同，含质保金条款。'

function Get-FreeRAMGB {
    [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
}
function Get-Resident { try { @((Invoke-RestMethod "$OllamaUrl/api/ps" -TimeoutSec 15).models) } catch { @() } }
function Clear-Resident {
    $r = @(Get-Resident | Where-Object { $_.name })
    if ($r.Count -eq 0) { return }
    foreach ($x in $r) {
        try {
            Invoke-RestMethod "$OllamaUrl/api/generate" -Method Post -TimeoutSec 60 `
                -Body (@{ model = $x.name; prompt = ''; keep_alive = 0 } | ConvertTo-Json -Compress) `
                -ContentType 'application/json' | Out-Null
        } catch { }
    }
    for ($i = 0; $i -lt 12; $i++) {
        if (@(Get-Resident | Where-Object { $_.name }).Count -eq 0) { return }
        Start-Sleep -Milliseconds 700
    }
}

# --- native /api/chat, with and without think:false -------------------------
function Invoke-Native([string]$Model, [object]$Think) {
    $body = @{
        model      = $Model
        messages   = @(@{ role = 'user'; content = $Prompt })
        stream     = $false
        keep_alive = '2m'
        options    = @{ num_predict = $MaxTokens; temperature = 0 }
    }
    if ($null -ne $Think) { $body.think = $Think }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "$OllamaUrl/api/chat" -Method Post -TimeoutSec 900 `
            -Body ($body | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json'
        $sw.Stop()
        $content = "$($r.message.content)"
        $thinkTxt = "$($r.message.thinking)"
        [pscustomobject]@{
            ContentChars   = $content.Trim().Length
            ReasoningChars = $thinkTxt.Length
            Tokens         = $r.eval_count
            Finish         = $r.done_reason
            Ms             = $sw.ElapsedMilliseconds
            Ok             = ($content.Trim().Length -gt 0 -and $r.done_reason -ne 'length')
            Err            = ''
        }
    }
    catch {
        $sw.Stop()
        [pscustomobject]@{ ContentChars = 0; ReasoningChars = 0; Tokens = ''; Finish = 'ERR'; Ms = $sw.ElapsedMilliseconds; Ok = $false; Err = $_.Exception.Message }
    }
}

# --- OpenAI-compatible /v1/chat/completions ---------------------------------
function Invoke-OpenAI([string]$Model, [hashtable]$Extra) {
    $body = @{
        model       = $Model
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        temperature = 0
        stream      = $false
    }
    foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "$OllamaUrl/v1/chat/completions" -Method Post -TimeoutSec 900 `
            -Body ($body | ConvertTo-Json -Depth 8 -Compress) -ContentType 'application/json'
        $sw.Stop()
        $msg = $r.choices[0].message
        $content = "$($msg.content)"
        $reason = "$($msg.reasoning)"
        if (-not $reason) { $reason = "$($msg.reasoning_content)" }
        [pscustomobject]@{
            ContentChars   = $content.Trim().Length
            ReasoningChars = $reason.Length
            Tokens         = $r.usage.completion_tokens
            Finish         = $r.choices[0].finish_reason
            Ms             = $sw.ElapsedMilliseconds
            Ok             = ($content.Trim().Length -gt 0 -and $r.choices[0].finish_reason -ne 'length')
            Err            = ''
        }
    }
    catch {
        $sw.Stop()
        [pscustomobject]@{ ContentChars = 0; ReasoningChars = 0; Tokens = ''; Finish = 'ERR'; Ms = $sw.ElapsedMilliseconds; Ok = $false; Err = $_.Exception.Message }
    }
}

# --- structured output (json_schema) - the "document generation" path -------
# deer-flow-config.yaml records that ornith-1.5:9b fails this with
# "Failed to initialize samplers: failed to parse grammar" while gemma4 handles
# it. A local model promoted to a document tier must survive this.
$Schema = @{
    type       = 'object'
    properties = @{
        title  = @{ type = 'string' }
        party  = @{ type = 'string' }
        staged = @{ type = 'array'; items = @{ type = 'string' } }
    }
    required   = @('title', 'party', 'staged')
}
function Invoke-Grammar([string]$Model) {
    $body = @{
        model           = $Model
        messages        = @(@{ role = 'user'; content = 'Extract the contract title, the buyer, and the delivery stages as JSON.' })
        max_tokens      = 400
        temperature     = 0
        stream          = $false
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'contract'; strict = $true; schema = $Schema } }
        # Structured extraction must not spend its budget thinking.
        reasoning_effort = 'none'
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod "$OllamaUrl/v1/chat/completions" -Method Post -TimeoutSec 900 `
            -Body ($body | ConvertTo-Json -Depth 12 -Compress) -ContentType 'application/json'
        $sw.Stop()
        $txt = "$($r.choices[0].message.content)"
        $parsed = $null
        try { $parsed = $txt | ConvertFrom-Json } catch { }
        [pscustomobject]@{
            Ok       = [bool]$parsed
            Detail   = if ($parsed) { 'valid JSON' } else { "non-JSON/empty: $($txt.Trim().Substring(0, [Math]::Min(60, $txt.Trim().Length)))" }
            Ms       = $sw.ElapsedMilliseconds
        }
    }
    catch {
        $sw.Stop()
        [pscustomobject]@{ Ok = $false; Detail = "ERR $($_.Exception.Message)"; Ms = $sw.ElapsedMilliseconds }
    }
}

Write-Host "=== thinking suppression probe ===" -ForegroundColor White
Write-Host "prompt: utility-shaped (6-word title)   max_tokens: $MaxTokens"
Write-Host ("host free RAM: {0} GiB" -f (Get-FreeRAMGB))

$tags = try { @((Invoke-RestMethod "$OllamaUrl/api/tags" -TimeoutSec 15).models) } catch { @() }
$installed = @{}
foreach ($t in $tags) { $installed[$t.name] = $t.size }

$native = @(); $openai = @(); $grammar = @()
foreach ($m in $Models) {
    Write-Host "`n--- $m ---" -ForegroundColor Cyan
    if (-not $installed.ContainsKey($m)) {
        Write-Host "  [SKIP] not installed" -ForegroundColor Yellow
        continue
    }
    $needGB = [math]::Round($installed[$m] / 1e9, 1)
    $free = Get-FreeRAMGB
    Clear-Resident
    if ($needGB -gt $free) {
        Write-Host ("  [REFUSED] {0} GB of weights vs {1} GiB free - would page and freeze the desktop" -f $needGB, $free) -ForegroundColor Red
        continue
    }

    # Native endpoint: default, then think:false.
    $d = Invoke-Native $m $null
    $f = Invoke-Native $m $false
    $native += [pscustomobject]@{ Model = $m; Variant = 'native default';       K = $d }
    $native += [pscustomobject]@{ Model = $m; Variant = 'native think=false';   K = $f }

    # OpenAI-compatible: bare (what a picker entry WITHOUT the fix sends), then
    # reasoning_effort=none (what deer-flow needs for these backends).
    $b = Invoke-OpenAI $m @{}
    $n = Invoke-OpenAI $m @{ reasoning_effort = 'none' }
    $openai += [pscustomobject]@{ Model = $m; Variant = '/v1 bare (no fix)';       K = $b }
    $openai += [pscustomobject]@{ Model = $m; Variant = '/v1 reasoning_effort=none'; K = $n }

    $g = Invoke-Grammar $m
    $grammar += [pscustomobject]@{ Model = $m; Grammar = $g }

    foreach ($row in @(
        @{ V = 'native default';         R = $d },
        @{ V = 'native think=false';     R = $f },
        @{ V = '/v1 bare';               R = $b },
        @{ V = '/v1 reasoning_effort=none'; R = $n })) {
        Write-Host ("  {0,-28} content={1,4}ch reasoning={2,5}ch tok={3,4} finish={4,-10} {5}ms  {6}" -f `
            $row.V, $row.R.ContentChars, $row.R.ReasoningChars, $row.R.Tokens, $row.R.Finish, $row.R.Ms, $(if ($row.R.Ok) { 'OK' } else { 'FAIL' }))
        if ($row.R.Err) { Write-Host "     err: $($row.R.Err)" -ForegroundColor DarkYellow }
    }
    Write-Host ("  grammar/json_schema: {0}  ({1}, {2}ms)" -f $(if ($g.Ok) { 'OK' } else { 'FAIL' }), $g.Detail, $g.Ms) `
        -ForegroundColor $(if ($g.Ok) { 'Green' } else { 'Red' })
}

Clear-Resident

if ($Markdown) {
    Write-Output ''
    Write-Output "### Thinking suppression (native `/api/chat`)"
    Write-Output ''
    Write-Output '| Model | Variant | Content chars | Reasoning chars | Tokens | Finish | ms | Verdict |'
    Write-Output '|---|---|---|---|---|---|---|---|'
    foreach ($r in $native) {
        Write-Output ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f `
            $r.Model, $r.Variant, $r.K.ContentChars, $r.K.ReasoningChars, $r.K.Tokens, $r.K.Finish, $r.K.Ms, $(if ($r.K.Ok) { 'OK' } else { 'FAIL' }))
    }
    Write-Output ''
    Write-Output '### Thinking suppression (OpenAI-compatible `/v1`, what the picker uses)'
    Write-Output ''
    Write-Output '| Model | Variant | Content chars | Reasoning chars | Tokens | Finish | ms | Verdict |'
    Write-Output '|---|---|---|---|---|---|---|---|'
    foreach ($r in $openai) {
        Write-Output ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f `
            $r.Model, $r.Variant, $r.K.ContentChars, $r.K.ReasoningChars, $r.K.Tokens, $r.K.Finish, $r.K.Ms, $(if ($r.K.Ok) { 'OK' } else { 'FAIL' }))
    }
    Write-Output ''
    Write-Output '### Structured output (`response_format: json_schema`)'
    Write-Output ''
    Write-Output '| Model | Verdict | Detail | ms |'
    Write-Output '|---|---|---|---|'
    foreach ($r in $grammar) {
        Write-Output ("| ``{0}`` | {1} | {2} | {3} |" -f $r.Model, $(if ($r.Grammar.Ok) { 'OK' } else { 'FAIL' }), $r.Grammar.Detail, $r.Grammar.Ms)
    }
    Write-Output ''
    Write-Output "_Measured $((Get-Date).ToString('yyyy-MM-dd HH:mm')) on $env:COMPUTERNAME._"
}
