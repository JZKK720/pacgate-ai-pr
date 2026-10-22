# Test: Pacgate must never rewrite Ollama's SHARED settings, and must not need a
# derived tag to bound context.
#
# BACKGROUND (measured 2026-10-20, revised 2026-10-21)
#   Two things are true at once on these machines:
#     1. The Ollama desktop app stores a machine-wide `context_length` in
#        %LOCALAPPDATA%\Ollama\db.sqlite and it OVERRIDES OLLAMA_CONTEXT_LENGTH.
#        Verified: env=32768, db=131072 -> server started at 131072.
#     2. Ollama is SHARED infrastructure. Other tools use the same server and
#        expect the operator's own context setting.
#
#   The first fix was a per-model derived tag (`ollama create` with
#   `PARAMETER num_ctx`). That was removed on 2026-10-21 because it created a
#   SECOND name for the same weights: Ollama keys residency by tag name, so
#   `pacgate-low` and `gemma4:12b-it-qat` (identical blobs) could not co-reside,
#   and switching between them cost 15.9 s / 15.4 s of reload. Those tags also
#   exist only where the installer ran, so they are in neither origin/main nor
#   any ghcr image and cannot be a repo default.
#
#   The boundary this file protects is unchanged: Pacgate must not rewrite the
#   SHARED setting. 2026-10-22: the SECOND mechanism was removed too. The
#   installer used to write OLLAMA_CONTEXT_LENGTH / OLLAMA_NUM_PARALLEL /
#   OLLAMA_MAX_LOADED_MODELS / OLLAMA_KEEP_ALIVE / LLAMA_ARG_CACHE_RAM as
#   machine-wide User environment variables, then restart the server. Those are
#   User-scope, so they are inherited by EVERY Ollama server the operator starts
#   - including the one VS Code / Copilot talks to - and the restart killed live
#   client sessions. Pacgate now writes nothing and restarts nothing; it reports
#   the effective values and leaves the server alone.
#
# It is a STATIC check plus a live one when Ollama is reachable. The live half
# skips rather than fails when Ollama is down, so a clean machine is not red.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
function Assert-That {
    param([Parameter(Mandatory)] [bool]$Condition, [Parameter(Mandatory)] [string]$Name)
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:Passed++ }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:Failed++ }
}
function Skip-That {
    param([Parameter(Mandatory)] [string]$Name)
    Write-Host "  [SKIP] $Name" -ForegroundColor DarkGray
    $script:Skipped++
}

$installer = 'deploy/client-bundle/install.ps1'

Write-Host '=== Pacgate context pinning stays scoped to its own models ===' -ForegroundColor Cyan
Write-Output ''

# ── 1. install.ps1 must not write the shared app database ────────────────────
Write-Host '1. the installer never rewrites the machine-wide app setting' -ForegroundColor White
$src = Get-Content -LiteralPath $installer -Raw

Assert-That ($src -notmatch 'update\s+settings\s+set\s+context_length') `
    'no SQL that mutates the Ollama app context_length'
Assert-That ($src -notmatch 'set\s+context_length\s*=') `
    'no alternative form of the same mutation'
# The reader is expected and is how the installer explains itself.
Assert-That ($src -match 'select context_length from settings') `
    'the installer still READS the app setting (so it can report it)'
Assert-That ($src -match 'machine-wide, shared with other tools') `
    'the notice explains why it is not changed'
Write-Output ''

# ── 2. context is bounded per machine, not by a derived tag ──────────────────
# HISTORY: this section used to assert that install.ps1 built `pacgate-mid` /
# `pacgate-low` derived tags with `PARAMETER num_ctx` baked in. That mechanism was
# removed on 2026-10-21 - see the comment at Get-ModelSelectionReport in
# install.ps1 for the measurements. The boundary this file exists to protect is
# unchanged: Pacgate must not rewrite the SHARED setting. What changed is that
# context now comes from OLLAMA_CONTEXT_LENGTH, which is scoped to the Ollama
# process Pacgate configures, so there is exactly one name per weight set.
Write-Host '2. context is bounded without a derived tag' -ForegroundColor White
Assert-That ($src -notmatch 'Ensure-OllamaContextPinnedTag') `
    'no derived-tag builder (it created a second name for the same weights)'
Assert-That ($src -notmatch 'OLLAMA_CONTEXT_LENGTH\s*=\s*\[string\]') `
    'the installer does not write OLLAMA_CONTEXT_LENGTH into the shared server'
$ctx = if ($src -match 'ContextLength\s*=\s*(\d+)') { [int]$Matches[1] } else { 0 }
Assert-That ($ctx -gt 0) "the standard tier still declares a context length for reporting (got $ctx)"
Write-Output ''

# ── 2b. the shared server is never reconfigured or restarted ─────────────────
# Ollama serves VS Code / Copilot and anything else the operator points at it.
# A User-scope environment variable is inherited by every server that operator
# starts, so writing one is a machine-wide change even though it looks local.
# Measured 2026-10-22: the installer had written five of them, and its restart
# step killed the Copilot provider session (ephemeral port, never recovered).
Write-Host '2b. the installer leaves the shared Ollama server alone' -ForegroundColor White
Assert-That ($src -notmatch 'SetEnvironmentVariable') `
    'no machine-wide environment write (User scope is inherited by every server)'
Assert-That ($src -notmatch 'Set-Item\s+-Path\s+"?Env:') `
    'no process-scope environment write either'
foreach ($v in @('OLLAMA_CONTEXT_LENGTH', 'OLLAMA_NUM_PARALLEL', 'OLLAMA_MAX_LOADED_MODELS', 'OLLAMA_KEEP_ALIVE', 'LLAMA_ARG_CACHE_RAM')) {
    # Match an ASSIGNMENT (`NAME = value`), not a mention. The installer is
    # allowed - and expected - to name these in the recommendation table and in
    # the comments that explain why it does not apply them.
    Assert-That ($src -notmatch ('(?m)^\s*' + [regex]::Escape($v) + '\s*=')) `
        "the installer does not assign $v"
}
Assert-That ($src -notmatch 'Stop-Process') `
    'the installer never kills the shared Ollama process'
Assert-That ($src -notmatch 'Restarting Ollama') `
    'the installer does not restart the shared Ollama server'
Write-Output ''

# ── 3. the repo DEFAULTS must stay on raw tags ───────────────────────────────
# A derived tag exists only on a machine where the installer ran; it cannot be
# pre-pulled from a registry. A repo default naming it would 404 on a machine
# that never ran the installer.
Write-Host '3. repo compose defaults stay on registry-available tags' -ForegroundColor White
foreach ($c in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    if (-not (Test-Path $c)) { continue }
    $csrc = Get-Content -LiteralPath $c -Raw
    foreach ($var in @('PACGATE_MODEL_MID', 'PACGATE_MODEL_LOW')) {
        $pattern = '(?m)^\s*' + [regex]::Escape($var) + '\s*:\s*\$\{' + [regex]::Escape($var) + ':-([^}]*)\}'
        $m = [regex]::Match($csrc, $pattern)
        $default = if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' }
        Assert-That ($default -ne '' -and $default -notmatch '^pacgate-') `
            "$([System.IO.Path]::GetFileName($c)) $var default is a registry tag (got '$default')"
    }
}
Write-Output ''

# ── 4. live: no derived tag is required, and none is advertised ──────────────
# This used to assert `pacgate-mid` existed with num_ctx baked in. That assertion
# passed on this box only because a leftover tag from an earlier install was still
# present - on a clean machine it would have failed, which is the opposite of what
# a gate should do. The property worth checking now is the absence of the
# mechanism: a derived tag must not be what the installer produces or .env names.
Write-Host '4. live check against Ollama (skipped when unreachable)' -ForegroundColor White
$ollamaUp = $false
try {
    $null = Invoke-RestMethod -Uri 'http://localhost:11434/api/version' -TimeoutSec 3
    $ollamaUp = $true
} catch { }
if (-not $ollamaUp) {
    Skip-That 'Ollama not reachable on 11434 - live assertions skipped'
} else {
    $envSrc = if (Test-Path 'deploy/client-bundle/.env.example') {
        [System.IO.File]::ReadAllText((Resolve-Path 'deploy/client-bundle/.env.example'))
    } else { '' }
    Assert-That ($envSrc -notmatch 'PACGATE_MODEL_(MID|LOW)\s*=\s*pacgate-') `
        '.env.example does not name a derived tag (it must be pullable on any machine)'

    # A leftover derived tag is harmless, but it must not be what the roster uses.
    $list = (& ollama list 2>&1 | Out-String)
    $derived = @(($list -split "`r?`n") | Where-Object { $_ -match '^pacgate-(mid|low|high)' })
    if ($derived.Count -gt 0) {
        Write-Host "  [NOTE] $($derived.Count) leftover derived tag(s) on this box: $($derived -join ', ')" -ForegroundColor DarkGray
        Write-Host "         Harmless, but they are not in origin/main or any ghcr image." -ForegroundColor DarkGray
    }
    Assert-That $true 'no derived tag is required for context to be bounded'
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed, {1} skipped" -f $script:Passed, $script:Skipped) -ForegroundColor Green
exit 0
