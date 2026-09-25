# Guard: every LOCAL model tag the stack requests must actually be obtainable.
#
# WHY THIS EXISTS: three separate stale-tag defects were found on 2026-09-21, all
# the same class and none detectable by reading:
#   1. deer-flow-config.yaml default was `gemma4:12b-it-q8_0`, but ollama-models.txt
#      pre-pulls `gemma4:12b-it-qat`. A machine would install one tag and request
#      another.
#   2. two further deer-flow entries (`gemma4:26b-a4b-it-q8_0`, `qwen3.5:9b-q8_0`)
#      named tags that are NOT pre-pulled and NOT installed anywhere.
#   3. OpenViking's ov.conf.template VLM named `q8_0` while the live ov.conf had
#      already been corrected to `qat` by hand - so a FRESH install would render
#      the broken value while this dev box kept working.
#
# The failure mode is silent until runtime: ollama returns
#   HTTP 404 {"error":{"message":"model '<tag>' not found"}}
# and the agent run fails outright - no fallback, no warning. A freshly installed
# AIPC looks healthy and breaks on first use.
#
# WHAT IT CHECKS: every local (non-`:cloud`) tag requested by a tracked config must
# appear in ollama-models.txt, the list `install.ps1` pre-pulls. `:cloud` tags are
# exempt: they carry no weight layers and route through ollama.com.
#
# Exit codes: 0 = consistent;  1 = a requested local tag is never fetched

[CmdletBinding()]
param(
    [string[]]$Configs = @(
        'deploy/client-bundle/deer-flow-config.yaml',
        'deploy/client-bundle/openviking/ov.conf.template'
    ),
    [string]$PrePullList = 'deploy/client-bundle/ollama-models.txt',
    # Optional: also require the tag to be present in a running ollama.
    [switch]$CheckInstalled,
    [string]$OllamaBase = 'http://localhost:11434'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$script:failures = 0
$script:warnings = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warnings++ }
function Pass($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }

# Ollama treats a bare name as ':latest' (`ollama list` shows only
# `nomic-embed-text:latest`, while ov.conf.template and plans/007 both say the bare
# `nomic-embed-text`). Comparing raw strings therefore produced a FALSE POSITIVE:
# the guard flagged a tag that is genuinely the same model. Normalise before
# comparing, or the guard cries wolf and people stop reading it.
function Normalize-Tag([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $t }
    $v = $t.Trim().Trim('"', "'")
    if ($v -notmatch ':') { return "$v`:latest" }
    return $v
}

# ── 1. the pre-pull list is the authority ────────────────────────────────────
Write-Host '=== 1. pre-pull list (what install.ps1 fetches) ===' -ForegroundColor Cyan
if (-not (Test-Path $PrePullList)) { Fail "pre-pull list not found: $PrePullList"; exit 1 }

# Strip comments; keep bare tag lines. Normalise so a bare name matches ':latest'.
$prePulled = @(
    Get-Content $PrePullList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object { Normalize-Tag $_ } |
        Sort-Object -Unique
)
if ($prePulled.Count -eq 0) { Fail "$PrePullList contains no tags"; exit 1 }
$prePulled | ForEach-Object { Write-Host "  $_" }

# ── 2. collect requested LOCAL tags from each config ────────────────────────
Write-Host ''
Write-Host '=== 2. requested local tags per config ===' -ForegroundColor Cyan

$requested = @{}   # tag -> list of sources
foreach ($cfg in $Configs) {
    if (-not (Test-Path $cfg)) { Fail "config not found: $cfg"; continue }
    $text = Get-Content $cfg -Raw

    # Commented-out entries (a leading '#') are deliberately disabled; skip them so
    # a disabled model does not trip the guard.
    $tags = @()
    foreach ($line in (Get-Content $cfg)) {
        if ($line -match '^\s*#') { continue }
        # YAML `model: <tag>` and JSON `"model": "<tag>"`
        if ($line -match '^\s*model:\s*(\S+)') { $tags += Normalize-Tag $Matches[1] }
        elseif ($line -match '"model"\s*:\s*"([^"]+)"') { $tags += Normalize-Tag $Matches[1] }
    }
    $tags = @($tags | Where-Object { $_ } | Sort-Object -Unique)
    Write-Host "  $cfg"
    if ($tags.Count -eq 0) { Write-Host '    (no model tags)' }
    foreach ($t in $tags) {
        Write-Host "    $t"
        if (-not $requested.ContainsKey($t)) { $requested[$t] = @() }
        $requested[$t] += $cfg
    }
}

# ── 3. every requested local tag must be pre-pulled ─────────────────────────
Write-Host ''
Write-Host '=== 3. requested-but-never-fetched tags ===' -ForegroundColor Cyan

$bad = @()
foreach ($tag in ($requested.Keys | Sort-Object)) {
    if ($tag -like '*:cloud' -or $tag -like '*cloud*') {
        Write-Host "  [skip] $tag  (:cloud - no local weights needed)" -ForegroundColor DarkGray
        continue
    }
    if ($prePulled -contains $tag) {
        Pass "$tag"
    } else {
        $bad += $tag
        Fail "$tag is requested by $($requested[$tag] -join ', ') but NOT pre-pulled by $PrePullList"
    }
}

if ($bad) {
    Write-Host ''
    Write-Host '  Meaning: these models are INSTALLED on the machines (so a run works today)' -ForegroundColor DarkGray
    Write-Host '  but are ABSENT from the pre-pull list, so a FUTURE rebuild or re-image that' -ForegroundColor DarkGray
    Write-Host '  relies on install.ps1 alone will come up missing them, and the agent will' -ForegroundColor DarkGray
    Write-Host '  fail at runtime with:' -ForegroundColor DarkGray
    foreach ($t in $bad) { Write-Host "    HTTP 404  model '$t' not found" -ForegroundColor DarkGray }
}

# ── 4. optional: is it actually installed here? ─────────────────────────────
if ($CheckInstalled) {
    Write-Host ''
    Write-Host '=== 4. installed locally? ===' -ForegroundColor Cyan
    try {
        $installed = @((Invoke-RestMethod "$OllamaBase/api/tags" -TimeoutSec 10).models.name)
    } catch {
        Warn "ollama not reachable at $OllamaBase - skipping the installed check"
        $installed = @()
    }
    if ($installed.Count -gt 0) {
        foreach ($tag in ($requested.Keys | Sort-Object)) {
            if ($tag -like '*cloud*') { continue }
            if ($installed -contains $tag) { Pass "$tag installed" }
            else { Warn "$tag pre-pulled but NOT yet installed on THIS machine" }
        }
    }
}

# ── 4b. workflow tier roster tags count as REQUESTED ────────────────────────
#
# Collected BEFORE section 5 so the "pre-pulled but never requested" check knows
# about them. Without this, a tier tag requested only via compose or the Rust
# defaults was reported as unused -- a false positive that trains the reader to
# ignore the warning. This file's own note about `nomic-embed-text` records the
# same failure: a guard that cries wolf is a guard nobody reads.
$coreLibPath    = 'pacgate-ai/crates/pacgate-core/src/lib.rs'
$tierMainRsPath = 'pacgate-ai/crates/pacgate-api/src/main.rs'
$tierTags       = @()
$tierSources    = @{}

if (Test-Path $coreLibPath) {
    $coreSrc = Get-Content $coreLibPath -Raw
    foreach ($c in @('DEFAULT_MAIN_TAG', 'DEFAULT_MID_TAG', 'DEFAULT_LOW_TAG')) {
        $m = [regex]::Match($coreSrc, "$c\s*:\s*&'static str\s*=\s*""([^""]+)""")
        if ($m.Success) {
            $t = Normalize-Tag $m.Groups[1].Value
            $tierTags += $t
            if (-not $tierSources.ContainsKey($t)) { $tierSources[$t] = @() }
            $tierSources[$t] += "$coreLibPath ($c)"
        }
    }
}
foreach ($compose in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    if (-not (Test-Path $compose)) { continue }
    $csrc = Get-Content $compose -Raw
    foreach ($var in @('PACGATE_MODEL_MAIN', 'PACGATE_MODEL_MID', 'PACGATE_MODEL_LOW')) {
        $pat = [regex]::Escape($var) + '\s*:\s*\$\{' + [regex]::Escape($var) + ':-([^}]+)\}'
        $m = [regex]::Match($csrc, $pat)
        if ($m.Success) {
            $t = Normalize-Tag $m.Groups[1].Value.Trim()
            $tierTags += $t
            if (-not $tierSources.ContainsKey($t)) { $tierSources[$t] = @() }
            $tierSources[$t] += "$compose ($var)"
        }
    }
}
$tierTags = @($tierTags | Where-Object { $_ } | Sort-Object -Unique)
foreach ($t in $tierTags) {
    if (-not $requested.ContainsKey($t)) { $requested[$t] = @() }
    foreach ($s in $tierSources[$t]) { $requested[$t] += $s }
}

# ── 5. note pre-pulled-but-unused (wasted download, not a failure) ──────────
Write-Host ''
Write-Host '=== 5. pre-pulled but never requested ===' -ForegroundColor Cyan
$unused = $prePulled | Where-Object { -not $requested.ContainsKey($_) }
if ($unused) {
    foreach ($t in $unused) {
        # Entries commented out in ollama-models.txt are documentation, not requests.
        Warn "$t is pre-pulled but no active config requests it"
    }
} else {
    Pass 'every pre-pulled tag is referenced by a config'
}

# ── 6. the WORKFLOW TIER roster (Rust + compose) ────────────────────────────
#
# WHY THIS SECTION EXISTS: this audit returned exit 0 through a defect that took
# down every workflow. The tier tags lived in `pacgate-core/src/lib.rs` and nothing
# here ever opened a Rust file, so three tags that all returned HTTP 404 were
# invisible to a guard whose entire purpose is stale model tags.
#
# An audit that reports clean on the class of defect it exists to catch is worse
# than no audit: it is the reason nobody looked. `test-model-roster-consistency.ps1`
# owns the pass/fail assertions for this; section 6 reports it here so this file
# cannot stay silent about the surface it used to skip.
Write-Host ''
Write-Host '=== 6. workflow tier roster (Rust defaults + compose overrides) ===' -ForegroundColor Cyan

$coreLib   = 'pacgate-ai/crates/pacgate-core/src/lib.rs'
$tiermainRs = 'pacgate-ai/crates/pacgate-api/src/main.rs'
$rosterChecked = $false

if ((Test-Path $coreLib) -and (Test-Path $tiermainRs)) {
    $mainSrc = Get-Content $tiermainRs -Raw

    if ($tierTags.Count -eq 0) {
        Fail "$coreLib declares no DEFAULT_*_TAG constants - the tier roster moved; update this section"
    } else {
        Write-Host "  Rust tier fallbacks: $($tierTags -join ', ')"
        foreach ($tag in $tierTags) {
            if ($prePulled -contains $tag) { Pass "$tag (tier fallback) is pre-pulled" }
            else { Fail "$tag is a tier fallback but NOT pre-pulled - the fallback is what applies when an override is unset, so it is a latent HTTP 404 on every workflow" }
        }

        # The override mechanism must actually be wired, or the constants above are
        # applied unconditionally and this whole section checks a dead path.
        if ($mainSrc -match 'ModelConfig::from_env\s*\(') {
            Pass 'pacgate-api resolves tiers via ModelConfig::from_env (overrides honored)'
        } else {
            Fail 'pacgate-api does not call ModelConfig::from_env, so PACGATE_MODEL_* is ignored and the tier tags are hardcoded again'
        }

        # Compose overrides must exist and agree with the pre-pull list.
        foreach ($compose in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
            if (-not (Test-Path $compose)) { Warn "missing $compose - cannot verify its tier overrides"; continue }
            $csrc = Get-Content $compose -Raw
            foreach ($var in @('PACGATE_MODEL_MAIN', 'PACGATE_MODEL_MID', 'PACGATE_MODEL_LOW')) {
                $pat = [regex]::Escape($var) + '\s*:\s*\$\{' + [regex]::Escape($var) + ':-([^}]+)\}'
                $m = [regex]::Match($csrc, $pat)
                if (-not $m.Success) { Fail "$compose does not set $var"; continue }
                $tag = Normalize-Tag $m.Groups[1].Value.Trim()
                if ($prePulled -contains $tag) { Pass "$compose $var=$tag is pre-pulled" }
                else { Fail "$compose $var=$tag is NOT pre-pulled - a fresh install would 404 on the first workflow run" }
            }
        }
        $rosterChecked = $true
    }
} else {
    Warn "tier roster files not found; skipping section 6"
}

# Delegate the full assertion set (including the 'main.rs still hardcodes' case)
# to the dedicated gate, so this audit cannot pass where that gate would fail.
$rosterGate = 'scripts/test-model-roster-consistency.ps1'
if (Test-Path $rosterGate) {
    Write-Host ''
    Write-Host '  delegating the full tier-roster assertions to the dedicated gate...' -ForegroundColor DarkGray
    & pwsh -NoProfile -File $rosterGate *> $null
    if ($LASTEXITCODE -eq 0) {
        Pass 'test-model-roster-consistency.ps1 passed'
    } elseif ($LASTEXITCODE -eq 2) {
        Warn 'test-model-roster-consistency.ps1 could not check (exit 2)'
    } else {
        Fail 'test-model-roster-consistency.ps1 FAILED - run it for the details'
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $($script:failures) requested local tag(s) are missing from the pre-pull list." -ForegroundColor Red
    Write-Host '  Fix: add the tag to ollama-models.txt, or remove/disable the model entry.' -ForegroundColor Red
    Write-Host '  A tag already installed on the machines works TODAY, but will be missing' -ForegroundColor DarkGray
    Write-Host '  after any rebuild or re-image that relies on install.ps1 alone.' -ForegroundColor DarkGray
    exit 1
}
$surfaces = if ($rosterChecked) { 'config + Rust tier roster' } else { 'config' }
Write-Host "RESULT: every requested local tag is pre-pulled. (surfaces: $surfaces; $($script:warnings) warning(s))" -ForegroundColor Green
exit 0
