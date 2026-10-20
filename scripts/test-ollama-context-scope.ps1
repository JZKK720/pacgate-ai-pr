# Test: Pacgate must pin context PER MODEL, never by rewriting the shared setting.
#
# BACKGROUND (measured 2026-10-20)
#   Two things are true at once on these machines:
#     1. The Ollama desktop app stores a machine-wide `context_length` in
#        %LOCALAPPDATA%\Ollama\db.sqlite and it OVERRIDES OLLAMA_CONTEXT_LENGTH.
#        Verified: env=32768, db=131072 -> server started at 131072.
#     2. Ollama is SHARED infrastructure. Other tools use the same server and
#        expect the operator's own context setting.
#
#   So the correct fix is a per-model derived tag (`ollama create` with
#   `PARAMETER num_ctx`), not a global rewrite. This test locks that boundary in:
#   it fails if install.ps1 ever writes the app database again, and it fails if
#   the pinned-tag logic stops producing a tag with num_ctx baked in.
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

# ── 2. the pinned-tag path exists and bakes num_ctx ──────────────────────────
Write-Host '2. the installer creates a per-model pinned tag' -ForegroundColor White
Assert-That ($src -match 'function Ensure-OllamaContextPinnedTag') `
    'Ensure-OllamaContextPinnedTag exists'
Assert-That ($src -match 'PARAMETER num_ctx') `
    'it writes `PARAMETER num_ctx` into the Modelfile'
Assert-That ($src -match 'ollama.*create|&\s*\$OllamaExe\s+create') `
    'it invokes `ollama create`'
$ctx = if ($src -match 'ContextLength\s*=\s*(\d+)') { [int]$Matches[1] } else { 0 }
Assert-That ($ctx -gt 0) "the standard tier declares a context length (got $ctx)"
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

# ── 4. live: the pinned tag really has num_ctx baked in ──────────────────────
Write-Host '4. live check against Ollama (skipped when unreachable)' -ForegroundColor White
$ollamaUp = $false
try {
    $null = Invoke-RestMethod -Uri 'http://localhost:11434/api/version' -TimeoutSec 3
    $ollamaUp = $true
} catch { }
if (-not $ollamaUp) {
    Skip-That 'Ollama not reachable on 11434 - live pin assertions skipped'
} else {
    $shown = & ollama show pacgate-mid --modelfile 2>&1 | Out-String
    if ($shown -match 'num_ctx\s+(\d+)') {
        Assert-That ([int]$Matches[1] -gt 0) "pacgate-mid has num_ctx=$($Matches[1]) baked in"
    } else {
        Assert-That $false 'pacgate-mid exists with num_ctx baked in (run install.ps1 to create it)'
    }
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED, {2} skipped" -f $script:Passed, $script:Failed, $script:Skipped) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed, {1} skipped" -f $script:Passed, $script:Skipped) -ForegroundColor Green
exit 0
