# Guard: `summarization.trigger` must clear the UNREMOVABLE per-call token
# floor, and `summarization.keep` must leave real headroom under it.
#
# WHY THIS EXISTS (measured 2026-10-23, v0.2.3, live AIPC).
#
# The shipped config had:
#
#     summarization:
#       trigger: { type: tokens, value: 12000 }
#       keep:    { type: tokens, value: 12000 }
#
# and a document run ("42 steps and no report") never terminated.
#
# THE MECHANISM
#
# LangChain's `SummarizationMiddleware._should_summarize` fires on EITHER:
#
#   (a) the message-token counter >= trigger, or
#   (b) `_should_summarize_based_on_reported_tokens`: the LAST AIMessage's
#       `usage_metadata.total_tokens` >= trigger.
#
# (b) is the one that bites, and it is NOT the same number as (a). The provider
# reports the WHOLE request: system prompt + tool schemas + messages. Measured
# on this box:
#
#     system prompt (lead_agent SYSTEM_PROMPT_TEMPLATE)   3,220 tok
#     45 tool schemas (get_available_tools, subagent on) 11,508 tok
#     -> unremovable floor                               14,728 tok
#
# and the floor observed live across thread d46320fd was 10,018..13,889 tok.
# The 14,728 figure is the authoritative one: it is what the request actually
# carries, measured from the live tool set rather than inferred from a delta.
#
# Summarization can only remove MESSAGES. It cannot remove the system prompt or
# the tool schemas. So with trigger=12000 the reported total was over the
# trigger on EVERY call, including immediately after a summarization pass. The
# lane fired, replaced the history with a summary, and the next call was still
# over 12000 - so it fired again. Forever.
#
# Measured on thread d46320fd:
#
#     step 402  total=15097  cutoff=2  -> summarize
#     step 410  total=15196  cutoff=3  -> summarize
#     step 419  total=15315  cutoff=4  -> summarize
#     step 428  total=17007  cutoff=16 -> summarize
#     step 437  total=15353  cutoff=5  -> summarize
#     step 446  total=15425  cutoff=4  -> summarize   (still going)
#
# Six passes, each one a full extra LLM call on the SAME single Ollama runner
# slot as the user's chat. The run burned 1,000,467 lead-agent input tokens over
# 66 LLM calls and produced no closing message.
#
# `keep` IS NOT THE LEVER. Replaying the real middleware against the live
# checkpoint at step 446, with the reported-token path active:
#
#     keep=12000 -> post-summarization 16,289 tok -> fires again
#     keep= 8000 -> post-summarization 11,392 tok -> fires again
#     keep= 6000 -> post-summarization 10,699 tok -> fires again
#     keep= 4000 -> post-summarization  5,093 tok -> fires again
#
# All four are under the 12000 trigger on the COUNTER path, yet all four still
# fire, because reported = counter + floor and the floor alone exceeds 12000.
# Lowering `keep` only shrinks the preserved suffix; it cannot shrink the floor.
#
# Simulated 40 agent steps with the real middleware, reported = counter + floor,
# counting summarization passes (40 = treadmill):
#
#     trigger  keep | floor 10k  14.7k  18k  22k
#     -------  ---- | ---------  -----  ---  ---
#      12000   6000 |   40 TREAD  40 T   40T  40T
#      24000   6000 |    7        40T   40T  40T
#      28000   6000 |    5         6    40T  40T
#      32000   6000 |    4         5     6   40T
#      36000   6000 |    3         4     4    5
#
# WHAT IT CHECKS
#   S1  trigger > floor + margin            (the exact defect: a trigger below the
#                                            unremovable floor can never converge)
#   S2  keep < trigger                      (a pass must remove something)
#   S3  trigger is a token trigger, not messages/fraction
#   S3b keep is a token budget
#   S4  trim_tokens_to_summarize >= trigger - keep
#                                           (the summarizer must see the whole
#                                            span it replaces; a smaller trim
#                                            silently drops the OLDEST content,
#                                            which on a document task is the part
#                                            read first)
#   S5  keep + summary reserve < trigger    (a pass must buy real headroom, not
#                                            just barely dip under the trigger)
#
# S1's floor is the measured 14,728 (system prompt + 45 tool schemas). The margin
# defaults to 8000 so the trigger also survives a heavier tool set or a longer
# system prompt without silently regressing into the treadmill.
#
# S5 uses a 2000-token reserve: the largest summary message measured on this box
# was 1146 tokens (4559 chars, Chinese), and the reserve must also absorb the
# dynamic-context reminder that summarization deliberately preserves.
#
# Exit codes: 0 = all pass;  1 = a real failure;  2 = cannot check
#
# Usage:  pwsh -File scripts/test-summarization-treadmill.ps1
#         pwsh -File scripts/test-summarization-treadmill.ps1 -Configs <path>

[CmdletBinding()]
param(
    [string[]]$Configs = @(
        'deploy/client-bundle/deer-flow-config.yaml',
        'deploy/deer-flow-pacgate/config.yaml'
    ),
    # Tokens reserved for the summary message that replaces the summarized span.
    [int]$SummaryReserve = 2000,
    # Unremovable per-call overhead: system prompt + tool schemas.
    [int]$FloorTokens = 14728,
    # How far above the floor the trigger must sit.
    [int]$FloorMargin = 8000
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$script:failures = 0
$script:checks = 0

function Check($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) {
        Write-Host "  [PASS] $label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

# ── Line-oriented reader for the `summarization:` block only ─────────────────
#
# Same constraint as test-auxiliary-model-pins.ps1: the AIPCs ship Windows
# PowerShell 5.1, which has no ConvertFrom-Yaml. This reads exactly the four
# scalars the invariant needs and nothing else.
#
# The block uses both shapes in this repo:
#
#     trigger:
#       - type: tokens
#         value: 12000
#
#     keep:
#       type: tokens
#       value: 12000
#
# so the reader tracks the last `type:`/`value:` pair seen inside each sub-key.
function Read-SummarizationConfig {
    param([string]$Path)

    $result = @{
        present      = $false
        enabled      = $null
        triggerType  = $null
        triggerValue = $null
        keepType     = $null
        keepValue    = $null
        trim         = $null
    }

    $section = ''
    $sub = ''

    foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
        $line = $raw -replace '\s+$', ''
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*#') { continue }

        # Top-level key at column 0 ends any section.
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):') {
            $section = $Matches[1]
            $sub = ''
            if ($section -eq 'summarization') { $result.present = $true }
            continue
        }

        if ($section -ne 'summarization') { continue }

        # Sub-key at 2-space indent: `trigger:`, `keep:`, `enabled:`, `trim_...:`
        if ($line -match '^  ([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$') {
            $sub = $Matches[1]
            $inline = $Matches[2].Trim()
            if ($sub -eq 'enabled' -and $inline) {
                $result.enabled = ($inline -match '^(?i)true$')
            }
            if ($sub -eq 'trim_tokens_to_summarize' -and $inline -match '^\d+$') {
                $result.trim = [int]$inline
            }
            continue
        }

        # `- type: tokens` (list form) or `type: tokens` (map form)
        if ($line -match '^\s+-?\s*type:\s*(\S+)') {
            if ($sub -eq 'trigger') { $result.triggerType = $Matches[1] }
            elseif ($sub -eq 'keep') { $result.keepType = $Matches[1] }
            continue
        }
        if ($line -match '^\s+-?\s*value:\s*(\d+)') {
            if ($sub -eq 'trigger') { $result.triggerValue = [int]$Matches[1] }
            elseif ($sub -eq 'keep') { $result.keepValue = [int]$Matches[1] }
            continue
        }
    }

    return $result
}

Write-Host '=== summarization must converge, not treadmill ===' -ForegroundColor Cyan
Write-Host ("  floor={0} tok (system prompt + tool schemas), margin={1}, summary reserve={2}" -f `
        $FloorTokens, $FloorMargin, $SummaryReserve) -ForegroundColor DarkGray

foreach ($cfg in $Configs) {
    $path = if ([System.IO.Path]::IsPathRooted($cfg)) { $cfg } else { Join-Path $repo $cfg }
    Write-Host ''
    Write-Host "--- $cfg" -ForegroundColor Cyan
    if (-not (Test-Path $path)) { Die "missing config: $path" }

    $s = Read-SummarizationConfig -Path $path

    if (-not $s.present) {
        Write-Host '  [skip] no summarization: section - the lane is inactive' -ForegroundColor DarkGray
        continue
    }
    if ($s.enabled -ne $true) {
        Write-Host '  [skip] summarization is not enabled - no invariant to hold' -ForegroundColor DarkGray
        continue
    }

    Write-Host ("  trigger        : {0} {1}" -f $s.triggerType, $s.triggerValue) -ForegroundColor DarkGray
    Write-Host ("  keep           : {0} {1}" -f $s.keepType, $s.keepValue) -ForegroundColor DarkGray
    Write-Host ("  trim_to_summar : {0}" -f $s.trim) -ForegroundColor DarkGray

    if ($null -eq $s.triggerValue -or $null -eq $s.keepValue) {
        Die "could not read trigger/keep values from $cfg - the reader or the file changed shape"
    }

    # ── S3: only a token trigger has a comparable `keep`. ────────────────────
    Check 'S3 trigger is a token trigger' ($s.triggerType -eq 'tokens') `
        "trigger type is '$($s.triggerType)'; this gate compares token budgets and cannot reason about messages/fraction"
    Check 'S3b keep is a token budget' ($s.keepType -eq 'tokens') `
        "keep type is '$($s.keepType)'; a message-count keep does not bound the token total"

    # ── S1: the exact defect - trigger below the unremovable floor. ──────────
    #
    # The reported-token path compares the provider's total_tokens (system
    # prompt + tool schemas + messages) against the trigger. Summarization
    # cannot remove the first two, so a trigger at or below the floor is over
    # the threshold on every call and the lane can never converge.
    $minTrigger = $FloorTokens + $FloorMargin
    Check "S1 trigger > floor + margin ($minTrigger)" ($s.triggerValue -gt $minTrigger) `
        "trigger=$($s.triggerValue) is not above floor=$FloorTokens + margin=$FloorMargin = $minTrigger; the reported-token path compares system prompt + tool schemas + messages against the trigger, and summarization cannot remove the first two, so the lane re-fires on every call and never converges"

    # ── S2: a pass must actually remove something. ───────────────────────────
    Check 'S2 keep < trigger' ($s.keepValue -lt $s.triggerValue) `
        "keep=$($s.keepValue) trigger=$($s.triggerValue): the preserved suffix alone fills the trigger, so summarization re-fires on the next model call and never converges"

    # ── S5: a pass must buy real headroom, not just dip under the trigger. ───
    $post = $s.keepValue + $SummaryReserve
    Check "S5 keep + summary reserve ($SummaryReserve) < trigger" ($post -lt $s.triggerValue) `
        "keep=$($s.keepValue) + reserve=$SummaryReserve = $post, which is not below trigger=$($s.triggerValue); the post-summarization state stays over the trigger and the lane fires again immediately"

    # ── S4: the summarizer must be able to see the span it replaces. ─────────
    #
    # `trim_tokens_to_summarize` caps the material handed to the summary model.
    # The span being replaced is roughly (trigger - keep) tokens, so a trim below
    # that silently drops the OLDEST messages - on a document task, the part the
    # agent read first. It does not break convergence, so it is a separate check.
    if ($null -ne $s.trim) {
        $span = $s.triggerValue - $s.keepValue
        Check "S4 trim_tokens_to_summarize >= trigger - keep ($span)" ($s.trim -ge $span) `
            "trim=$($s.trim) is below the $span-token span being replaced; the summary would be built from a truncated view that drops the oldest content"
    } else {
        Write-Host '  [skip] S4 trim_tokens_to_summarize is unset' -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "RESULT: $($script:checks) of $($script:checks) checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
