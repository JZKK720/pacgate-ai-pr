# Does a local model actually complete a MULTI-STEP tool loop, or does it stop
# after the first call and report success?
#
# WHY THIS EXISTS (2026-11-04)
#
# This is the measurement the roster decision actually turns on, and it was
# never the throughput question. `pacgate-core/src/lib.rs` already records the
# failure in prose: with the local 12B as MAIN, a document workflow "drives one
# step (`list_documents`, `kb_search`) and stops - it never reaches
# `generate_docx`. The route still returns 200 and reports success, so the
# defect surfaced as an EMPTY RESULT rather than an error." Switching MAIN to
# the cloud model took the same test from 2 failed at 60.7 s to 19/19 at 18.2 s.
#
# So the question is not "how many tok/s" - a model that needs three round
# trips to reach the tool that writes the file is slower than one that needs
# one, whatever its decode rate. This probe measures:
#
#   step1_tool   did it request a tool call at all on the first turn?
#   step1_right  was it the CORRECT tool for the request?
#   step2_tool   after being fed the tool RESULT, did it request the NEXT tool?
#   final        did it ever reach the terminal tool (`generate_docx`)?
#   loop_ok      full chain: list -> read -> generate, in order, no stray calls
#
# A model can be fast and still fail `final`. A model can be slow and pass. The
# pass/fail column is what decides whether it can own a workflow tier.
#
# Usage:
#   pwsh -File scripts/bench-tool-loop.ps1
#   pwsh -File scripts/bench-tool-loop.ps1 -Models gemma4:12b-it-qat,ornith-1.5:35b -Json
[CmdletBinding()]
param(
    [string]$OllamaUrl = 'http://localhost:11434',

    [string[]]$Models = @(
        'gemma4:12b-it-qat',
        'ornith-1.5:35b',
        'nemotron-3.5-lightning:30b-a3b',
        'deepseek-v4.1-flash:cloud'
    ),

    # Context the stack actually runs these models at.
    [int]$NumCtx = 65536,

    [int]$MaxTokensPerStep = 512,

    # Thinking control. Left unset, whatever the model default is applies - and
    # that default is the trap: a thinking-capable model spends the per-step
    # budget on hidden reasoning and can emit ZERO tool calls, which presents as
    # a workflow that "does nothing" while every request returns 200.
    #
    # Two switches rather than one nullable bool because `pwsh -File` passes
    # every argument as a string, so `-Think false` cannot bind to a [bool].
    #   (neither)     model default
    #   -ThinkOff     measure tool-calling without the reasoning confound
    [switch]$ThinkOff,
    [switch]$ThinkOn,

    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Resolve the thinking override once. $null means "send nothing and let the
# model decide", which is how the stack behaves by default.
$Think = if ($ThinkOff) { $false } elseif ($ThinkOn) { $true } else { $null }

# The shipped tool surface, taken from deploy/pacgate-mcp/server.py so a model
# is not passing against a toy schema. The three that form the document chain
# are declared in full; the rest are present with real names and one-line
# descriptions because the DISTRACTOR SET is the point - a model that picks
# `pacgate_sanitize_text` when asked to write a .docx is a workflow failure
# that no throughput number would predict.
$distractors = @(
    @{ name = 'pacgate_kb_search';        desc = 'Semantic search across sanitised knowledge-base chunks.';        p = @('query') },
    @{ name = 'pacgate_connector_search'; desc = 'Search an external legal database connector.';                    p = @('query') },
    @{ name = 'pacgate_list_connectors';  desc = 'List configured external connectors.';                            p = @() },
    @{ name = 'pacgate_list_matters';     desc = 'List matters for the current tenant.';                            p = @() },
    @{ name = 'pacgate_read_memory';      desc = 'Read a memory entry by key.';                                     p = @('key') },
    @{ name = 'pacgate_write_memory';     desc = 'Write a memory entry by key.';                                    p = @('key', 'value') },
    @{ name = 'pacgate_get_workspace';    desc = 'Get the workspace descriptor for a matter.';                      p = @('matter_id') },
    @{ name = 'pacgate_upload_document';  desc = 'Upload a new document into a matter.';                            p = @('matter_id', 'path') },
    @{ name = 'pacgate_list_workflows';   desc = 'List available workflows, optionally filtered by category.';       p = @('category') },
    @{ name = 'pacgate_get_workflow';     desc = 'Get one workflow definition by id.';                              p = @('workflow_id') },
    @{ name = 'pacgate_execute_workflow'; desc = 'Execute a workflow by id against a matter.';                      p = @('workflow_id', 'matter_id') },
    @{ name = 'pacgate_convert_document'; desc = 'Convert a document between formats.';                             p = @('document_id', 'target_format') },
    @{ name = 'pacgate_ocr_document';     desc = 'OCR a scanned document into text.';                               p = @('document_id') },
    @{ name = 'pacgate_ocr_batch';        desc = 'OCR every scanned document in a matter.';                          p = @('matter_id') },
    @{ name = 'pacgate_sanitize_document';desc = 'Run the NER sanitizer over a stored document.';                    p = @('document_id') },
    @{ name = 'pacgate_verify_sanitized'; desc = 'Verify a document is fully sanitised.';                            p = @('document_id') },
    @{ name = 'pacgate_rescan_residue';   desc = 'Rescan a document for residual PII after sanitisation.';          p = @('document_id') },
    @{ name = 'pacgate_reset_sanitization'; desc = 'Admin: revert a document to its unsanitised original.';         p = @('document_id') },
    @{ name = 'pacgate_sanitize_text';    desc = 'Sanitise an arbitrary text string, returning redacted text.';     p = @('text') },
    @{ name = 'pacgate_clause_risk';      desc = 'Score a contract clause for legal risk.';                          p = @('clause') },
    @{ name = 'pacgate_clause_flags';     desc = 'List flagged clauses in a document.';                              p = @('document_id') },
    @{ name = 'pacgate_route_language';   desc = 'Detect the language of a string and route it.';                    p = @('text') }
)

function New-Tool([string]$Name, [string]$Description, [string[]]$Params) {
    $props = @{}
    foreach ($p in $Params) { $props[$p] = @{ type = 'string'; description = "The $p argument." } }
    # NOTE: `$params` is a PowerShell automatic variable (it aliases the parameter
    # set). Assigning a hashtable into it appears to work and then silently drops
    # keys, so the schema object is built as $schemaProps instead.
    $schemaProps = @{ type = 'object'; properties = $props }
    if (@($Params).Count -gt 0) { $schemaProps.required = @($Params) }
    @{ type = 'function'; function = @{ name = $Name; description = $Description; parameters = $schemaProps } }
}

$tools = @(
    (New-Tool 'pacgate_list_documents' 'List documents in a matter. Returns id, title and format for each.' @('matter_id')),
    (New-Tool 'pacgate_read_document'  'Read the sanitised text of one document by its id.' @('document_id')),
    (New-Tool 'pacgate_generate_docx'  'Generate a .docx deliverable into the matter and return its file path. This is the ONLY tool that writes a document.' @('matter_id', 'title', 'body'))
)
foreach ($d in $distractors) { $tools += (New-Tool $d.name $d.desc $d.p) }

$userTask = '针对 matter M-001，把项目说明文档整理成一份 .docx 交付物。' +
            '你需要：先列出该事项下的文档，读取项目说明，然后生成 docx。请逐步完成。'

function Invoke-Chat {
    param([array]$Messages, [string]$Model)
    $body = @{
        model    = $Model
        messages = $Messages
        tools    = $tools
        stream   = $false
        options  = @{ num_ctx = $NumCtx; temperature = 0; num_predict = $MaxTokensPerStep }
        # Bounded hold, so a crash mid-lane does not pin the weights for 5m.
        keep_alive = '2m'
    }
    if ($null -ne $Think) { $body.think = $Think }
    $json = $body | ConvertTo-Json -Depth 12 -Compress

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "$OllamaUrl/api/chat" -Method Post -Body $json `
        -ContentType 'application/json' -TimeoutSec 1800
    $sw.Stop()
    # Report how much of the per-step budget went to hidden reasoning. This is
    # the number that explains a turn which produced no tool call.
    $thinkLen = if ($r.message.thinking) { $r.message.thinking.Length } else { 0 }
    [pscustomobject]@{ Msg = $r.message; Ms = $sw.ElapsedMilliseconds; EvalTok = $r.eval_count; ThinkChars = $thinkLen }
}

# ---------------------------------------------------------------------------
# Host-memory safety.
#
# This script hit the same defect as bench-local-models.ps1: after a run it left a
# multi-gigabyte runner resident, and repeated runs walk host RAM down to the
# point where Windows stalls (observed: 3.4 GiB free afterwards). A tool loop is
# short, so the risk here is cumulative rather than a single spike - but the
# mitigation is the same, and it is applied before AND after each lane.
# ---------------------------------------------------------------------------

function Get-OllamaResident {
    try { (Invoke-RestMethod -Uri "$OllamaUrl/api/ps" -TimeoutSec 15).models } catch { @() }
}

function Clear-ResidentModels {
    $resident = @(Get-OllamaResident | Where-Object { $_.name })
    if ($resident.Count -eq 0) { return $true }
    $ok = $true
    foreach ($r in $resident) {
        try {
            Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post `
                -Body (@{ model = $r.name; prompt = ''; keep_alive = 0 } | ConvertTo-Json -Compress) `
                -ContentType 'application/json' -TimeoutSec 60 | Out-Null
        }
        catch { $ok = $false }
    }
    # Poll rather than sleep a fixed time.
    for ($i = 0; $i -lt 15; $i++) {
        if (@(Get-OllamaResident | Where-Object { $_.name }).Count -eq 0) { return $ok }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

function Get-FreeRAMGB {
    $os = Get-CimInstance Win32_OperatingSystem
    [math]::Round($os.FreePhysicalMemory / 1MB, 1)
}

$results = @()
foreach ($m in $Models) {
    Write-Host "`n=== $m ===" -ForegroundColor Cyan

    # Unload whatever the previous lane left behind before this one loads.
    if (-not (Clear-ResidentModels)) {
        Write-Host "  [warn] a runner did not unload; the next load may double-commit" -ForegroundColor Yellow
    }
    $freeBefore = Get-FreeRAMGB
    Write-Host ("  free host RAM: {0} GiB" -f $freeBefore)

    $messages = @(
        @{ role = 'system'; content = 'You are a legal document assistant. Use the provided tools. Do not answer from memory when a tool can supply the fact.' },
        @{ role = 'user'; content = $userTask }
    )

    $trace = @()
    $called = @()
    $loopOk = $false
    $failedAt = ''
    $totalMs = 0
    $totalTok = 0
    $totalThink = 0

    # Feed tool results back up to 5 turns. Five is past the point where a model
    # that CAN finish has finished; a model still wandering at turn 5 is the
    # "runs past 36 steps and never answers" failure this project already hit.
    for ($turn = 1; $turn -le 5; $turn++) {
        try {
            $step = Invoke-Chat -Messages $messages -Model $m
        }
        catch {
            $failedAt = "turn$turn HTTP: $($_.Exception.Message)"
            break
        }
        $totalMs += $step.Ms
        $totalTok += [int]$step.EvalTok
        $totalThink += [int]$step.ThinkChars
        $msg = $step.Msg
        $calls = @($msg.tool_calls | Where-Object { $_ })

        if ($calls.Count -eq 0) {
            # Distinguish "answered deliberately" from "burned the budget
            # thinking and emitted nothing useful". Only the latter is the
            # defect; both fail the chain if generate_docx was never reached.
            $trace += if ($step.ThinkChars -gt 0 -and -not $msg.content) { "t${turn}:THINK-ONLY($($step.ThinkChars)ch)" } else { "t${turn}:TEXT" }
            # No tool call. That is only acceptable if the chain already
            # completed; otherwise the model has stopped early, which is the
            # documented 12B failure mode.
            if ($called -contains 'pacgate_generate_docx') { $loopOk = $true }
            else { $failedAt = "turn$turn stopped after $($called -join '>')" }
            break
        }

        $messages += @{ role = 'assistant'; content = ''; tool_calls = $calls }
        foreach ($c in $calls) {
            $name = $c.'function'.name
            $args = $c.'function'.arguments
            $called += $name
            $trace += "t${turn}:$name"

            # Synthetic but well-formed results, shaped like the real tool output,
            # so the next turn has something real to reason over.
            $payload = switch -regex ($name) {
                'pacgate_list_documents' { '{"documents":[{"id":"D-100","title":"项目说明","format":"pdf"},{"id":"D-101","title":"验收标准","format":"docx"}]}' }
                'pacgate_read_document'  { '{"document_id":"D-100","text":"项目名称：浦江新城二期。交付范围：设计、施工、验收三个阶段。验收标准：按合同附件三执行。付款节点：预付30%，验收后60%，质保金10%。"}' }
                'pacgate_generate_docx'  { '{"file_path":"/data/matters/M-001/deliverables/项目说明_v1.docx","bytes":4628}' }
                default                  { '{"error":"unknown tool"}' }
            }
            $messages += @{ role = 'tool'; content = $payload; tool_name = $name }
        }

        if ($called -contains 'pacgate_generate_docx') {
            # Give the model one turn to acknowledge, but the chain has already
            # reached the terminal tool - that is the success condition.
            $loopOk = $true
            break
        }
    }

    $step1 = if ($trace.Count -gt 0 -and $trace[0] -match 't1:(\w+)') { $Matches[1] } else { '' }
    $step1Right = ($step1 -eq 'pacgate_list_documents')

    Write-Host ("  trace: {0}" -f ($trace -join ' -> '))
    Write-Host ("  reached generate_docx: {0}   step1_correct: {1}   {2}" -f $loopOk, $step1Right, $failedAt)
    Write-Host ("  {0} ms, {1} tokens generated across turns" -f $totalMs, $totalTok)

    $results += [pscustomobject]@{
        Model       = $m
        ChainOk     = $loopOk
        Step1Tool   = $step1
        Step1Right  = $step1Right
        Calls       = ($called -join '>')
        Turns       = $trace.Count
        Ms          = $totalMs
        EvalTokens  = $totalTok
        ThinkChars  = $totalThink
        FailedAt    = $failedAt
    }
}

# Release the last model. Leaving it resident is what dropped this box to 3.4 GiB
# free after an earlier run.
[void](Clear-ResidentModels)
Write-Host ("`nfinished; free host RAM: {0} GiB" -f (Get-FreeRAMGB))

if ($Json) {
    $results | ConvertTo-Json -Depth 4
}
else {
    Write-Output ''
    Write-Output '| Model | Chain complete | Step 1 correct | Call sequence | Turns | Wall ms |'
    Write-Output '|---|---|---|---|---|---|'
    foreach ($r in $results) {
        $ok = if ($r.ChainOk) { 'PASS' } else { 'FAIL' }
        $s1 = if ($r.Step1Right) { 'yes' } else { 'no' }
        Write-Output ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} |" -f `
            $r.Model, $ok, $s1, ($r.Calls -replace '\|', '/'), $r.Turns, $r.Ms)
    }
    Write-Output ''
    foreach ($r in $results) {
        if ($r.FailedAt) { Write-Output "- ``$($r.Model)`` stopped: $($r.FailedAt)" }
    }
}
