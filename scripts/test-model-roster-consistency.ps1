# PROVES the workflow tier model roster is consistent across every artifact that
# names it, so a fresh install cannot 404 on the first workflow run.
#
# WHY THIS EXISTS
#
# Three artifacts independently named the workflow tier models, and they had
# drifted into three different sets:
#
#   pacgate-core Rust defaults : nemotron3:33b, qwen3.6:27b, qwen3.5:9b
#   ollama-models.txt prepull  : gemma4:12b-it-qat, qwen3.8:27b-mtp-q4_K_M
#   installed on this box      : gemma4:12b-it-qat, qwen3.8-flash-next:125b, ...
#
# All three Rust tags returned HTTP 404 on the live Ollama. A tag no local Ollama
# serves returns 404 with NO fallback, and nothing validated it at install time, so
# the failure lands on the user: every `/api/workflows/:id/execute` returns 500 the
# moment a workflow needs a model. That is all 222 workflow templates down at once,
# from a value nothing was checking.
#
# `scripts/audit-model-tags.ps1` reported clean through all of this because its
# scan list covers YAML/JSON configs and never opened a Rust file. Its exit 0 was
# therefore a false all-clear on exactly this defect -- which is worse than no
# check, because it stops anyone looking.
#
# ASSERTS:
#   A1 the Rust default tags match the compose PACGATE_MODEL_* defaults
#      (source and config must not disagree about the same roster)
#   A2 every compose tier tag appears in ollama-models.txt, so a fresh install
#      pre-pulls it rather than 404ing on first use
#   A3 pacgate-api actually READS the overrides -- it calls `from_env`, not the
#      fallback constructor. Reverting that call silently re-hardcodes the roster
#      and this whole mechanism becomes decorative.
#   A4 the three tier names are distinct fields of intent (Main != Mid), i.e. the
#      Mid tier was not left pointing at the Main model by a careless edit
#   A5 the Rust fallbacks are not left advertising tags the repo never installs
#
# Exit: 0 = all pass, 1 = a real failure, 2 = cannot check.
#
# Usage: pwsh -File scripts/test-model-roster-consistency.ps1

[CmdletBinding()]
param(
    [string]$CoreLib = '',
    [string]$MainRs = '',
    [string]$ProdCompose = '',
    [string]$BundleCompose = '',
    [string]$Prepull = '',
    [switch]$RequireOllama
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $CoreLib)       { $CoreLib       = Join-Path $repo 'pacgate-ai/crates/pacgate-core/src/lib.rs' }
if (-not $MainRs)        { $MainRs        = Join-Path $repo 'pacgate-ai/crates/pacgate-api/src/main.rs' }
if (-not $ProdCompose)   { $ProdCompose   = Join-Path $repo 'deploy/client-bundle/compose.prod.yaml' }
if (-not $BundleCompose) { $BundleCompose = Join-Path $repo 'deploy/client-bundle/compose.bundle.yaml' }
if (-not $Prepull)       { $Prepull       = Join-Path $repo 'deploy/client-bundle/ollama-models.txt' }

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

Write-Host '=== workflow tier roster consistency ===' -ForegroundColor Cyan
foreach ($f in @($CoreLib, $MainRs, $ProdCompose, $BundleCompose, $Prepull)) {
    if (-not (Test-Path $f)) { Die "missing file: $f" }
}

# ── Read the Rust defaults ───────────────────────────────────────────────────
$coreSrc = Get-Content $CoreLib -Raw
function RustConst([string]$name) {
    $m = [regex]::Match($coreSrc, "$name\s*:\s*&'static str\s*=\s*""([^""]+)""")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}
$rustMain = RustConst 'DEFAULT_MAIN_TAG'
$rustMid  = RustConst 'DEFAULT_MID_TAG'
$rustLow  = RustConst 'DEFAULT_LOW_TAG'
if (-not ($rustMain -and $rustMid -and $rustLow)) {
    Die "could not read DEFAULT_MAIN_TAG / _MID_TAG / _LOW_TAG from $CoreLib"
}
Write-Host "  Rust fallbacks : main=$rustMain mid=$rustMid low=$rustLow"

# ── Read the compose tier defaults ───────────────────────────────────────────
# Parsed from the ${VAR:-default} form so the check sees the value an operator
# gets with no environment set, which is the value a fresh install uses.
function ComposeDefault([string]$path, [string]$var) {
    $src = Get-Content $path -Raw
    # Built from single-quoted pieces on purpose: a double-quoted "${var:-...}"
    # is PowerShell variable interpolation, not a regex, and PowerShell treats
    # `${var:-...}` as an invalid variable reference (the colon). Escaping the
    # dollar is not enough either - the braces still interpolate.
    $pattern = [regex]::Escape($var) + '\s*:\s*\$\{' + [regex]::Escape($var) + ':-([^}]+)\}'
    $m = [regex]::Match($src, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}
$prodMain = ComposeDefault $ProdCompose 'PACGATE_MODEL_MAIN'
$prodMid  = ComposeDefault $ProdCompose 'PACGATE_MODEL_MID'
$prodLow  = ComposeDefault $ProdCompose 'PACGATE_MODEL_LOW'
$bunMain  = ComposeDefault $BundleCompose 'PACGATE_MODEL_MAIN'
$bunMid   = ComposeDefault $BundleCompose 'PACGATE_MODEL_MID'
$bunLow   = ComposeDefault $BundleCompose 'PACGATE_MODEL_LOW'

Check "the API compose files declare all three tier overrides" `
    ([bool]($prodMain -and $prodMid -and $prodLow -and $bunMain -and $bunMid -and $bunLow)) `
    "prod=($prodMain,$prodMid,$prodLow) bundle=($bunMain,$bunMid,$bunLow) - an absent override means the Rust fallback applies, which is the drift this file exists to stop"

if ($script:failures -gt 0) { Write-Host "`nRESULT: cannot continue without the tier overrides`n" -ForegroundColor Red; exit 1 }

Write-Host "  prod   tiers   : main=$prodMain mid=$prodMid low=$prodLow"
Write-Host "  bundle tiers   : main=$bunMain mid=$bunMid low=$bunLow"

# ── A1: Rust fallbacks must equal the compose defaults ───────────────────────
Check "A1a Rust Main fallback == compose Main default" ($rustMain -eq $prodMain -and $rustMain -eq $bunMain) `
    "rust='$rustMain' prod='$prodMain' bundle='$bunMain'"
Check "A1b Rust Mid fallback == compose Mid default" ($rustMid -eq $prodMid -and $rustMid -eq $bunMid) `
    "rust='$rustMid' prod='$prodMid' bundle='$bunMid'"
Check "A1c Rust Low fallback == compose Low default" ($rustLow -eq $prodLow -and $rustLow -eq $bunLow) `
    "rust='$rustLow' prod='$prodLow' bundle='$bunLow'"

# ── A2: every tier tag must be pre-pulled on a fresh install ─────────────────
$prepullSrc = Get-Content $Prepull -Raw
$prepullTags = @($prepullSrc -split "`r?`n" | ForEach-Object {
    $t = $_.Trim()
    if ($t -like '#*' -or -not $t) { return }
    if ($t -like '>>*') { return $t.Substring(2).Trim() }
    return $t
} | Where-Object { $_ })
Write-Host "  prepull tags   : $($prepullTags -join ', ')"

foreach ($pair in @(@('Main', $prodMain), @('Mid', $prodMid), @('Low', $prodLow))) {
    $tier = $pair[0]; $tag = $pair[1]
    Check "A2 $tier tier tag '$tag' is in ollama-models.txt" ($prepullTags -contains $tag) `
        "a fresh install would not pre-pull it; Ollama returns HTTP 404 for a missing tag with no fallback, so the first workflow run fails"
}

# ── A3: pacgate-api must READ the overrides ──────────────────────────────────
$mainSrc = Get-Content $MainRs -Raw
$usesFromEnv = $mainSrc -match 'ModelConfig::from_env\s*\('
$usesHardcoded = $mainSrc -match 'ModelConfig::default_local_with_base_url\s*\('
Check "A3 pacgate-api reads the tier overrides (ModelConfig::from_env)" $usesFromEnv `
    "main.rs does not call from_env, so PACGATE_MODEL_* is ignored, the Rust fallbacks apply unconditionally, and these assertions pass while the mechanism is decorative"
Check "A3b pacgate-api does not hardcode the roster" (-not $usesHardcoded) `
    "main.rs still calls default_local_with_base_url, which bypasses the per-tier overrides entirely"

# ── A4: the tiers must not collapse onto one model ───────────────────────────
# Gemma for Main+Low is deliberate (Low is the fast same-model lane), but a Mid
# tier equal to Main means Mid no longer buys anything.
Check "A4 Main and Mid tiers are distinct models" ($prodMain -ne $prodMid) `
    "main='$prodMain' mid='$prodMid' - the Mid tier would add nothing over Main"

# ── A5: the Rust fallbacks must not name tags nothing installs ───────────────
# The original defect exactly: Rust named nemotron3:33b / qwen3.6:27b / qwen3.5:9b,
# none of which any artifact installed or served.
foreach ($pair in @(@('Main', $rustMain), @('Mid', $rustMid), @('Low', $rustLow))) {
    $tier = $pair[0]; $tag = $pair[1]
    Check "A5 $tier fallback '$tag' is a tag this repo installs" ($prepullTags -contains $tag) `
        "the fallback is what applies if an override is missing, so a fallback outside the prepull list is a latent 404"
}

# ── Installed-state report (informational: the dev box roster may legitimately
#    differ from the client roster, so this never fails the gate) ─────────────
$ollamaUp = $false
$installed = @()
try {
    $tagsRaw = & ollama list 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ollamaUp = $true
        $installed = @($tagsRaw | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
    }
} catch { }

if ($ollamaUp) {
    Write-Host ''
    Write-Host "  installed on THIS box ($($installed.Count) tags) - report only:" -ForegroundColor DarkGray
    foreach ($pair in @(@('Main', $prodMain), @('Mid', $prodMid), @('Low', $prodLow))) {
        $tier = $pair[0]; $tag = $pair[1]
        $expect = if ($tag -match ':') { $tag } else { "$tag`:latest" }
        if ($installed -contains $expect -or $installed -contains $tag) {
            Write-Host "    $tier  $tag  present" -ForegroundColor DarkGray
        } else {
            $mark = if ($tag -match 'cloud$') { 'cloud tag (no local weights)' } else { 'NOT INSTALLED HERE - client roster may differ; the prepull list is what guarantees a fresh install' }
            Write-Host "    $tier  $tag  $mark" -ForegroundColor DarkGray
        }
    }
} elseif ($RequireOllama) {
    Die 'ollama is unreachable and -RequireOllama was set'
}

Write-Host ''
if ($script:failures -eq 0) {
    Write-Host "RESULT: $($script:checks) of $($script:checks) checks passed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:failures) of $($script:checks) checks FAILED" -ForegroundColor Red
exit 1
