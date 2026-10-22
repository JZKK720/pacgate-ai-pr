# Guard: every AUXILIARY model path must be pinned by name, not left to default.
#
# WHY THIS EXISTS (measured 2026-10-17, v0.1.31).
#
# `title.model_name` was unset in BOTH shipped deer-flow configs. TitleMiddleware
# then took its `else` branch:
#
#     if config.model_name:  model = create_chat_model(name=config.model_name)
#     else:                  model = create_chat_model()   # -> factory picks models[0]
#
# and `models[0]` is `nemotron-3.5-lightning-30b-local`, whose Ollama tag
# `nemotron-3.5-lightning:30b-a3b` measures **25 GB resident** (`ollama ps`).
# Title generation runs on EVERY new thread, so the first message of a fresh
# thread loaded a 25 GB model onto the single Ollama runner slot. On the 16 GB
# AIPC dGPUs that model does not fit at all: it either OOMs or evicts the model
# the user's chat is already on, and the following real call pays a full reload.
#
# Verified on the live container before the fix:
#     title.enabled   : True
#     title.model_name: None
#     => resolved title model: nemotron-3.5-lightning-30b-local (25 GB)
#
# Nothing in the repo asserted what an auxiliary lane resolves to. The memory
# lane was pinned on 2026-10-07 (same class of bug, 43k-token loop); the title
# lane was missed for an unknown length of time. This gate closes the class, not
# the instance: it checks EVERY auxiliary lane that exists in the config schema.
#
# WHAT IT CHECKS
#   A1  title.model_name is set            (the exact defect)
#   A2  memory.model_name is set           (the 2026-10-07 defect, kept from returning)
#   A3  all three resolve to a model in `models`  (otherwise: runtime HTTP 404)
#   A4  all auxiliary lanes converge on ONE Ollama tag (WARN only - divergence is a
#       legitimate opt-in, but each distinct tag is another resident model)
#
# Lanes covered: `title` and `memory` were the two known lanes. `summarization`
# was added 2026-10-17 after it was measured to fall back to models[0] as well -
# `_create_summarization_middleware` builds its own model and never receives the
# chat model, so it does NOT follow the user's picker choice.
#
# FAILS ONLY on A1-A3. A4 is advisory, so a deliberate split is not blocked.
#
# Exit codes: 0 = all pass;  1 = a real failure;  2 = cannot check
#
# Usage:  pwsh -File scripts/test-auxiliary-model-pins.ps1
#         pwsh -File scripts/test-auxiliary-model-pins.ps1 -Configs <path>   # negative test

[CmdletBinding()]
param(
    [string[]]$Configs = @(
        'deploy/client-bundle/deer-flow-config.yaml',
        'deploy/deer-flow-pacgate/config.yaml'
    )
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$script:failures = 0
$script:checks = 0
$script:warnings = 0
$script:advisories = 0

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

function Warn($label, $detail = '') {
    $script:warnings++
    Write-Host "  [warn] $label" -ForegroundColor Yellow
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

# ── A deliberately small, PS 5.1-safe reader for the two keys we care about ──
#
# The repo's other gates avoid a YAML dependency (the AIPCs ship Windows
# PowerShell 5.1, which has no ConvertFrom-Yaml), so this is a line-oriented
# state machine over exactly three constructs, not a general parser:
#
#   top-level `models:`        -> an indented list of `- name: <n>` entries, each
#                                 carrying an indented `model: <tag>`
#   top-level `title:`         -> indented `model_name: <name>`
#   top-level `memory:`        -> indented `model_name: <name>`
#   top-level `summarization:` -> indented `model_name: <name>`
#
# It ignores comments and blank lines, and stops treating `- name:` as a model
# entry the moment any other top-level key starts (so the `tools:` section's
# `- name: bash` entries cannot leak into the model list).
function Read-ModelConfig {
    param([string]$Path)

    $models = New-Object System.Collections.ArrayList
    $titleModel = $null
    $memoryModel = $null
    $summarizationModel = $null
    $summarizationEnabled = $null

    $inModels = $false
    $section = ''
    $current = $null

    foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
        $line = $raw -replace '\s+$', ''
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*#') { continue }

        # Top-level key: no leading whitespace, `key:` at column 0.
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):') {
            $section = $Matches[1]
            $inModels = ($section -eq 'models')
            $current = $null
            continue
        }

        if ($inModels -and $line -match '^\s*-\s*name:\s*(\S+)') {
            $current = @{ name = $Matches[1]; tag = $null }
            [void]$models.Add($current)
            continue
        }

        # `model:` only - `model_name:` has `_` where the colon must be, so it
        # cannot match here. Guards against reading a pin as a tag.
        if ($inModels -and $current -ne $null -and $line -match '^\s+model:\s*(\S+)') {
            $current.tag = $Matches[1]
            continue
        }

        if ($section -eq 'title'  -and $line -match '^\s+model_name:\s*(\S+)') { $titleModel  = $Matches[1]; continue }
        if ($section -eq 'memory' -and $line -match '^\s+model_name:\s*(\S+)') { $memoryModel = $Matches[1]; continue }
        if ($section -eq 'summarization') {
            if ($line -match '^\s+model_name:\s*(\S+)') { $summarizationModel = $Matches[1]; continue }
            if ($line -match '^\s+enabled:\s*(\S+)')   { $summarizationEnabled = ($Matches[1] -match '^(?i)true$'); continue }
        }
    }

    return @{
        models               = $models
        title                = $titleModel
        memory               = $memoryModel
        summarization        = $summarizationModel
        summarizationEnabled = $summarizationEnabled
    }
}

Write-Host '=== auxiliary model lanes are pinned by name ===' -ForegroundColor Cyan

foreach ($cfg in $Configs) {
    $path = if ([System.IO.Path]::IsPathRooted($cfg)) { $cfg } else { Join-Path $repo $cfg }
    Write-Host ''
    Write-Host "--- $cfg" -ForegroundColor Cyan
    if (-not (Test-Path $path)) { Die "missing config: $path" }

    $parsed = Read-ModelConfig -Path $path
    $models = $parsed.models
    $title  = $parsed.title
    $memory = $parsed.memory
    $summ   = $parsed.summarization

    if ($models.Count -eq 0) { Die "no models parsed from $cfg - the reader or the file changed shape" }

    $byName = @{}
    foreach ($m in $models) { if ($m.name) { $byName[$m.name] = $m } }

    Write-Host ("  models defined : {0}" -f (($models | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor DarkGray
    foreach ($lane in @(
        @{ n = 'title';         v = $title  },
        @{ n = 'memory';        v = $memory },
        @{ n = 'summarization'; v = $summ   }
    )) {
        $shown = if ($lane.v) { $lane.v } else { '<UNSET -> falls back to models[0]>' }
        Write-Host ("  {0,-14}: {1}" -f $lane.n, $shown) -ForegroundColor DarkGray
    }

    # ── A1: the title lane must be pinned. This is the 2026-10-17 defect. ─────
    Check "A1 title.model_name is set" ($null -ne $title -and $title -ne '') `
        "unset means title_middleware.py calls create_chat_model() with no name, which resolves to models[0] ('$($models[0].name)') and loads that model on EVERY new thread"

    # ── A2: the memory lane must be pinned (2026-10-07, 43k-token loop). ───────
    Check "A2 memory.model_name is set" ($null -ne $memory -and $memory -ne '') `
        "unset means the background memory updater uses models[0] with no generation cap and can loop on the single Ollama runner slot"

    # ── A3/A3b: every ACTIVE pin must name a model that exists, or runtime 404s.
    Check "A3 title.model_name names a defined model" ($title -and $byName.ContainsKey($title)) `
        "'$title' is not in this file's models: list - ollama would return HTTP 404 with no fallback"
    Check "A3b memory.model_name names a defined model" ($memory -and $byName.ContainsKey($memory)) `
        "'$memory' is not in this file's models: list - ollama would return HTTP 404 with no fallback"

    # ── A2b/A3c: the summarizer must be pinned, but ONLY when it is enabled. ──
    # deer-flow's SummarizationConfig defaults `enabled` to False, so a config with
    # no summarization: section (or enabled: false) has an INACTIVE lane that needs
    # no pin. Asserting a pin there would be a false positive.
    $summActive = ($parsed.summarizationEnabled -eq $true)
    if ($summActive) {
        Check "A2b summarization.model_name is set" ($null -ne $summ -and $summ -ne '') `
            "the summarization lane is ENABLED but unpinned, so _create_summarization_middleware builds its own model from models[0] ('$($models[0].name)'); it never receives the chat model, so it does NOT follow the user's picker choice"
        Check "A3c summarization.model_name names a defined model" ($summ -and $byName.ContainsKey($summ)) `
            "'$summ' is not in this file's models: list - ollama would return HTTP 404 with no fallback"
    } else {
        Write-Host "  [skip] A2b/A3c summarization lane is not enabled in this config - no pin required" -ForegroundColor DarkGray
    }

    # ── A4: advisory - each distinct tag is another resident model. ──────────
    $tags = @()
    foreach ($lane in @(
        @{ n = 'title';         v = $title  },
        @{ n = 'memory';        v = $memory },
        @{ n = 'summarization'; v = $summ   }
    )) {
        if ($lane.v -and $byName.ContainsKey($lane.v) -and $byName[$lane.v].tag) {
            $tags += [pscustomobject]@{ lane = $lane.n; tag = $byName[$lane.v].tag }
        }
    }
    $distinct = @($tags | ForEach-Object { $_.tag } | Sort-Object -Unique)
    if ($distinct.Count -le 1 -and $tags.Count -gt 0) {
        Write-Host ("  [ok]   A4 all auxiliary lanes converge on one resident model ({0})" -f $distinct[0]) -ForegroundColor Green
    } elseif ($distinct.Count -gt 1) {
        $detail = ($tags | ForEach-Object { "$($_.lane)=$($_.tag)" }) -join ', '
        Warn "A4 auxiliary lanes resolve to $($distinct.Count) DIFFERENT tags ($detail)" `
            'each distinct tag is a separate model load and a separate resident footprint on a card that may only hold one - confirm this split is intended'
    }

    $script:advisories++
}

Write-Host ''
if ($script:failures -eq 0) {
    $msg = "RESULT: $($script:checks) of $($script:checks) checks passed"
    if ($script:warnings -gt 0) { $msg += " ($($script:warnings) advisory warning(s))" }
    Write-Host $msg -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
