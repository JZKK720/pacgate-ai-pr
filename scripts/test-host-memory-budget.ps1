# Test: the host-memory budget that keeps the stack from paging must stay in place.
#
# BACKGROUND (measured 2026-10-21 on the HX370 box, Ollama 0.40.6)
#   "deer-flow is slow" was originally investigated as a VRAM problem. It was not:
#   the discrete card held 6.4 GiB free while the HOST had 0.03 MB available and
#   71.1 GB committed against an 86.98 GB commit limit.
#
#   The largest host-side consumer was llama.cpp's prompt cache, which defaults to
#   8192 MiB of HOST RAM and is unrelated to VRAM:
#
#     cache state: 4 prompts, 6506.381 MiB (limits: 8192.000 MiB, ...)
#
#   It was also not earning its keep. gemma4 is a sliding-window hybrid, and
#   llama.cpp logged "forcing full prompt re-processing due to lack of cache data
#   (likely due to SWA ...)". Measured reuse: 22.8% of requested prompt tokens,
#   with 48.5% of prefill events getting ZERO reuse.
#
#   Bounding it is cheap and easy to drop silently in a future refactor, which is
#   what this gate prevents. It is a STATIC check.
#
# SCOPE - what this change deliberately does NOT do
#   An earlier revision also wrote %USERPROFILE%\.wslconfig to cap the WSL VM.
#   That was reverted: .wslconfig is per-user and machine-wide, governing every
#   WSL distro rather than only Docker, so writing it is the same boundary
#   violation that test-ollama-context-scope.ps1 exists to prevent - one layer
#   down. The WSL ceiling is an operator decision and is documented, not applied.
#   Section 2 below locks that boundary in so it cannot creep back.

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

$installer = 'deploy/client-bundle/install.ps1'
$envExample = 'deploy/client-bundle/.env.example'

Write-Host '=== Host memory budget (llama.cpp prompt cache) ===' -ForegroundColor Cyan
Write-Output ''

Assert-That (Test-Path $installer) "installer present at $installer"
$src = Get-Content -LiteralPath $installer -Raw

# ── 1. the prompt cache is bounded, in every tier ────────────────────────────
# The installer REPORTS this value; it does not apply it. Ollama is shared with
# VS Code / Copilot, so a User-scope variable would change the whole machine.
Write-Host '1. llama.cpp prompt cache is capped' -ForegroundColor White
Assert-That ($src -match 'LLAMA_ARG_CACHE_RAM') `
    'installer reports LLAMA_ARG_CACHE_RAM (prompt cache is HOST RAM, unrelated to VRAM)'
Assert-That ($src -match 'CacheRamMiB') `
    'the value comes from the hardware profile rather than a magic number at the call site'
# Every tier must carry it: a missing one silently falls back to the 8192 MiB default.
# The keys can be on separate lines within the returned object, so this matches
# across newlines but stays non-greedy so each tier's own value is captured.
$tiers = [regex]::Matches($src, "(?s)Tier\s*=\s*'(high|big-ram-small-vram|standard|constrained)'.*?CacheRamMiB\s*=\s*(\d+)")
Assert-That ($tiers.Count -eq 4) "all four residency tiers set CacheRamMiB (found $($tiers.Count))"
foreach ($t in $tiers) {
    $mib = [int]$t.Groups[2].Value
    Assert-That ($mib -gt 0 -and $mib -le 4096) "tier '$($t.Groups[1].Value)' caps the cache at $mib MiB (<= 4096)"
}

# ── 2. model selection belongs to the operator, not to a derived tag ────────
# The installer used to `ollama create` derived tags (pacgate-mid / pacgate-low)
# with num_ctx baked in. That was removed on 2026-10-21 for three reasons, all
# measured: the tags exist in no image and no origin/main, so every deployment
# diverged from the published artifact; they created a SECOND name for the same
# weights, and Ollama keys residency by name, so the pair evicted each other
# (15.9 s / 15.4 s reloads, 56 llama-server starts and 13 evictions in one day);
# and they froze one context per tier instead of letting the machine decide.
Write-Host '2. model selection stays with the operator' -ForegroundColor White
Assert-That ($src -notmatch 'Ensure-OllamaContextPinnedTag') `
    'the derived-tag builder is gone'
# Match the CALL, not the phrase: the explanatory comment above deliberately
# quotes `ollama create` to record why it was removed, and a gate that cannot tell
# code from prose would forbid documenting the decision.
Assert-That ($src -notmatch '(?m)^\s*[^#\r\n]*&\s*\$OllamaExe\s+create') `
    'the installer no longer runs `ollama create`'
Assert-That ($src -notmatch 'PinnedPrefix') `
    'no leftover pinned-tag naming'
Assert-That ($src -match 'function\s+Get-ModelSelectionReport') `
    'a report-only model selection helper exists'
# The report must not write. A helper that quietly rewrote .env would reintroduce
# the same divergence under a different name.
$reportBody = if ($src -match '(?s)function\s+Get-ModelSelectionReport\s*\{.*?\n\}') { $Matches[0] } else { '' }
Assert-That ($reportBody -ne '' -and $reportBody -notmatch 'WriteAllText|SetEnvironmentVariable') `
    'the model selection helper writes nothing'
# Context is whatever the operator's own Ollama server is configured for. The
# installer reports the tier's recommendation and must not apply it.
Assert-That ($src -notmatch 'OLLAMA_CONTEXT_LENGTH\s*=\s*\[string\]') `
    'context is not written into the shared server (reported, not applied)'

# ── 3. the installer still never touches the shared Ollama app setting ──────
# Guarded in full by test-ollama-context-scope.ps1; asserted here too because a
# memory-ceiling change is exactly the kind of edit that invites a shortcut.
Write-Host '3. boundaries held' -ForegroundColor White
Assert-That ($src -notmatch 'update\s+settings\s+set\s+context_length') `
    'the shared Ollama app context_length is still never written'
# The same boundary applies to the HOST, not just to Ollama. .wslconfig is
# per-user and machine-wide: it governs every WSL distro, not only Docker. An
# earlier revision of this change wrote it, which was the same mistake the
# context-scope gate exists to prevent, one layer down. The installer must not
# take over host-wide tuning; it may only report it.
Assert-That ($src -notmatch '\.wslconfig') `
    'the installer does not write .wslconfig (host-wide, affects every WSL distro)'
Assert-That ($src -notmatch 'autoMemoryReclaim') `
    'the installer does not set WSL autoMemoryReclaim'

# ── 4. the runtime knobs are documented where operators will look ──────────
Write-Host '4. documented' -ForegroundColor White
if (Test-Path $envExample) {
    $ex = Get-Content -LiteralPath $envExample -Raw
    Assert-That ($ex -match 'LLAMA_ARG_CACHE_RAM') '.env.example documents LLAMA_ARG_CACHE_RAM'
    Assert-That ($ex -match 'HOST RAM') '.env.example says the prompt cache is host RAM, not VRAM'
} else {
    Assert-That $false ".env.example missing at $envExample"
}

# ── 5. KV cache quantization stays an OPERATOR lever, not an installer default ─
# Measured 2026-10-21 on a real 8,002-char Chinese document, 8 deterministic
# questions, identical context (32768):
#     f16 (default)  9.7 GB runner   8/8
#     q8_0           7.0 GB runner   8/8
# So it is a real 2.7 GB saving with no observed quality loss. It is still NOT
# shipped, because VRAM is not the binding constraint on this box (6.4 GiB free).
# The property to protect is that the installer does not silently quantize a
# shared server's KV cache - that is the operator's call, and it is the same
# boundary as the context setting one layer up.
Write-Host '5. KV cache quantization is not applied by the installer' -ForegroundColor White
Assert-That ($src -notmatch 'OLLAMA_KV_CACHE_TYPE') `
    'the installer does not set OLLAMA_KV_CACHE_TYPE (operator lever, quality trade-off)'

Write-Output ''
if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    Write-Host '  The host memory budget regressed. Without it the box pages during a' -ForegroundColor Red
    Write-Host '  workflow and every lane looks slow for a reason that is not the model.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
