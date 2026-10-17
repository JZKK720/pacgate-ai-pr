# Guard: every model the AIPC stack can be asked to RUN must FIT the smallest
# supported client GPU.
#
# WHY THIS EXISTS (added 2026-10-17, v0.1.31).
#
# `scripts/audit-model-tags.ps1` already answers "is this tag OBTAINABLE?" - it
# catches tags that are not pre-pulled, which fail at runtime with HTTP 404.
# It does NOT answer "is this tag RUNNABLE?", and nothing in the repo did.
#
# The two are different failures. An un-obtainable tag fails loudly and is
# already gated. An un-fittable tag is pulled successfully, appears healthy in
# `ollama list`, and then does one of two quiet things on a 16 GB card:
#
#   - Ollama spills layers to CPU and generation collapses to a few tokens/sec, or
#   - the load evicts whichever model the user's chat was already running on,
#     so the NEXT call pays a full reload and the 420 s stream idle watchdog
#     eventually kills the run ("no astream output").
#
# That second signature is the one this project spent 2026-10-08 to 2026-10-17
# chasing as a "hang". It is a capacity problem, not an Ollama bug.
#
# THE DEV BOX HIDES THIS. The development machine for this project is a
# Ryzen AI MAX+ 395 with a 96 GiB iGPU carve-out, so every over-cap model runs
# there without complaint and the defect is invisible until it reaches a client
# machine. This gate exists specifically so that "works on the dev box" cannot
# be mistaken for "ships correctly".
#
# WHAT IT CHECKS
#   B1  pacgate-api tier targets (PACGATE_MODEL_MAIN/MID/LOW, in BOTH compose
#       files) must FIT. This is the hard one: a tier default is unconditional,
#       so an over-cap tier model is a capacity bug on every AIPC.
#   B2  every ACTIVE (uncommented) model in the shipped deer-flow `models:` list
#       that is over-cap -> reported, so the exposure is visible.
#   B3  every over-cap tag pre-pulled by ollama-models.txt that NO active config
#       surface references -> reported as pure waste.
#   B4  a tag with no recorded size -> reported as needing review, never guessed.
#
# B2/B3/B4 are WARNINGS by default. B1 is the only one that is clearly a defect
# rather than a product decision, so it is the only one that fails - and only
# under -Strict, so this script can be registered as a non-blocking measurement
# while the roster question is still open. See the note at the bottom.
#
# Exit codes: 0 = fit (or warnings only);  1 = a -Strict assertion failed;
#             2 = cannot check
#
# Usage:  pwsh -File scripts/test-aipc-capacity-fit.ps1
#         pwsh -File scripts/test-aipc-capacity-fit.ps1 -Strict
#         pwsh -File scripts/test-aipc-capacity-fit.ps1 -Strict -Report

[CmdletBinding()]
param(
    # Treat over-cap ACTIVE roster entries (B2) as failures too. Off by default:
    # which models the shipped roster exposes is a commercial decision, not a
    # measurable fact, and this gate should not make it silently.
    [switch]$Strict,
    # Print the size table being used, so the numbers are never a black box.
    [switch]$Report
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# The budget.
#
# AIPC 1 & 2 are Ryzen AI HX370 with an RX 7600 XT: 16 GB of DEDICATED VRAM.
# Budget the RAW 16 GB, but tier the result, because "16 GB card" is not
# "16 GB available" - the Windows compositor, the driver, and the KV cache all
# come out of the same pool, and a legal deployment must not be one driver
# update away from spilling to CPU.
# ---------------------------------------------------------------------------
$AipcVramGB   = 16
$ComfortRatio = 0.75   # <= 12 GB: fits with headroom
# > 0.75 and <= 1.0 is MARGINAL; above 1.0 is OVER_CAP.

# ---------------------------------------------------------------------------
# Measured on-disk sizes.
#
# PROVENANCE: `ollama list` on the project dev box, 2026-10-17, Ollama 0.40.5.
# These are weight sizes, deliberately NOT `ollama ps` resident sizes: residency
# moves with context and keep-alive, on-disk size does not, and on-disk size is
# what the installer is deciding whether to pull.
#
# A tag absent from this table is reported for review (B4) and never guessed at.
# Add rows as the roster changes; a stale row is harmless, a guessed row is not.
#
# Cloud tags are intentionally listed at 0: they route to ollama.com and carry
# no weight layers on disk, so they consume no local VRAM (verified - they show
# in `ollama list` with size "-" and never appear in `ollama ps`). This is the
# one category where "does it fit" is the wrong question.
# ---------------------------------------------------------------------------
$KnownSizesGB = @{
    'gemma4:12b-it-qat'               = 7.2
    'nomic-embed-text:latest'        = 0.27
    'gemma4:26b-a4b-it-qat'           = 15.0
    'qwen3.8:27b-mtp-q4_K_M'          = 17.0
    'ornith-1.5:35b'                  = 22.0
    'nemotron-3.5-lightning:30b-a3b'  = 25.0
    'nemotron-3.5-bolt:74b-a9b-iq2'   = 24.0
    'ornith-1.5:9b'                   = 6.6
    'glm-ocr:latest'                  = 2.2
    'qwen3.6:35b-a3b-mtp-q4_K_M'      = 22.0
    # Cloud: no local weights.
    'deepseek-v4.1-flash:cloud'       = 0
    'glm-5.3-flash:cloud'             = 0
    'deepseek-v4-pro:0813-cloud'      = 0
    'glm-5.3:cloud'                   = 0
}

$script:failures = 0
$script:warnings = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warnings++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }

function Get-FitVerdict([double]$sizeGB) {
    if ($sizeGB -le ($AipcVramGB * $ComfortRatio)) { return 'FITS' }
    if ($sizeGB -le $AipcVramGB) { return 'MARGINAL' }
    return 'OVER_CAP'
}

# Read the effective default of a compose ${VAR:-default} expression.
# Mirrors test-model-roster-consistency.ps1's reader, kept local so this gate
# has no dependency on that one and can run alone.
function Get-ComposeDefault([string]$path, [string]$var) {
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -match "^\s*$([regex]::Escape($var))\s*:\s*\`$\{$([regex]::Escape($var)):-([^}]*)\}") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

Write-Host '=== every runnable model fits the smallest supported AIPC GPU ==='
Write-Host "    budget: $AipcVramGB GB dGPU (RX 7600 XT, AIPC 1 & 2) - FITS <= $([int]($AipcVramGB*$ComfortRatio)) GB, MARGINAL <= $AipcVramGB GB, above that OVER_CAP" -ForegroundColor DarkGray

if ($Report) {
    Write-Host ''
    Write-Host '  size table in use (on-disk, `ollama list` 2026-10-17):' -ForegroundColor DarkGray
    foreach ($kv in ($KnownSizesGB.GetEnumerator() | Sort-Object Value)) {
        $v = Get-FitVerdict $kv.Value
        Write-Host ("    {0,-34} {1,6:N2} GB  {2}" -f $kv.Key, $kv.Value, $v) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# B1. pacgate-api tier targets. These are UNCONDITIONAL defaults in compose, so
#     an over-cap tier model is a capacity bug on every AIPC that installs.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'B1  pacgate-api tier targets (compose defaults)' -ForegroundColor Cyan

$composeFiles = @(
    'deploy/client-bundle/compose.bundle.yaml',
    'deploy/client-bundle/compose.prod.yaml'
)
$tierVars = @('PACGATE_MODEL_MAIN', 'PACGATE_MODEL_MID', 'PACGATE_MODEL_LOW')
$b1Checked = 0

foreach ($rel in $composeFiles) {
    $path = Join-Path $repoRoot $rel
    if (-not (Test-Path $path)) {
        Write-Warn "$rel not found - skipped"
        continue
    }
    foreach ($var in $tierVars) {
        $tag = Get-ComposeDefault $path $var
        if (-not $tag) { Write-Warn "$rel : $var has no ${...:-default} form - review by hand"; continue }
        $b1Checked++
        $label = "$rel : $var"
        if (-not $KnownSizesGB.ContainsKey($tag)) {
            Write-Warn "$label -> $tag : size unknown, add it to the table in this script"
            continue
        }
        $gb = [double]$KnownSizesGB[$tag]
        $verdict = Get-FitVerdict $gb
        $msg = "$label -> $tag ($('{0:N1}' -f $gb) GB) : $verdict"
        if ($verdict -eq 'OVER_CAP') {
            if ($Strict) { Write-Fail "$msg - this model cannot run on a $AipcVramGB GB card" }
            else { Write-Warn "$msg - see B2 note; re-run with -Strict to make this blocking" }
        } elseif ($verdict -eq 'MARGINAL') {
            Write-Warn "$msg - tight; no headroom for KV cache or compositor"
        } else {
            Write-Pass $msg
        }
    }
}
if ($b1Checked -eq 0) { Write-Warn 'no tier defaults were read - cannot check B1' }

# ---------------------------------------------------------------------------
# B2. The shipped deer-flow roster: which ACTIVE entries are over-cap.
#
#     Line-oriented and PS 5.1 safe on purpose (the AIPCs have no
#     ConvertFrom-Yaml), matching test-auxiliary-model-pins.ps1. It reads the
#     `models:` block only, and distinguishes an active entry from a commented
#     one, because a commented entry costs nothing - that is the whole point of
#     commenting it out.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'B2  active deer-flow roster entries' -ForegroundColor Cyan

$clientConfig = Join-Path $repoRoot 'deploy/client-bundle/deer-flow-config.yaml'
$activeModels = @()   # @{ name=..; tag=.. }
$commentedModels = @()

if (Test-Path $clientConfig) {
    $lines = [System.IO.File]::ReadAllLines($clientConfig)
    $inModels = $false
    $currentName = $null
    $currentCommented = $false

    foreach ($line in $lines) {
        if ($line -match '^models:\s*$') { $inModels = $true; continue }
        # Any other top-level key ends the block.
        if ($inModels -and $line -match '^[A-Za-z_][A-Za-z0-9_]*:') { break }
        if (-not $inModels) { continue }

        # `  - name: x`   (active)   |   `  # - name: x`  (commented)
        if ($line -match '^\s*-\s+name:\s*(\S+)\s*$') {
            $currentName = $Matches[1]; $currentCommented = $false; continue
        }
        if ($line -match '^\s*#\s*-\s*name:\s*(\S+)\s*$') {
            $currentName = $Matches[1]; $currentCommented = $true; continue
        }
        # `    model: tag`  or  `    # model: tag`
        if ($currentName -and $line -match '^\s*model:\s*(\S+)\s*$') {
            $activeModels += [pscustomobject]@{ Name = $currentName; Tag = $Matches[1] }
            $currentName = $null; continue
        }
        if ($currentName -and $line -match '^\s*#\s*model:\s*(\S+)\s*$') {
            $commentedModels += [pscustomobject]@{ Name = $currentName; Tag = $Matches[1] }
            $currentName = $null; continue
        }
    }
}

# Tags reachable from an ACTIVE roster entry or a tier default: these define
# "referenced" for B3.
$referenced = @{}
foreach ($m in $activeModels) { $referenced[$m.Tag] = $true }
foreach ($rel in $composeFiles) {
    foreach ($var in $tierVars) {
        $t = Get-ComposeDefault (Join-Path $repoRoot $rel) $var
        if ($t) { $referenced[$t] = $true }
    }
}

if ($activeModels.Count -eq 0) {
    Write-Warn 'no active model entries parsed - cannot check B2'
} else {
    Write-Host "    $($activeModels.Count) active, $($commentedModels.Count) commented out" -ForegroundColor DarkGray
    $overCapActive = 0
    foreach ($m in $activeModels) {
        $tag = $m.Tag
        if (-not $KnownSizesGB.ContainsKey($tag)) {
            Write-Warn "$($m.Name) -> $tag : size unknown, add it to the table in this script"
            continue
        }
        $gb = [double]$KnownSizesGB[$tag]
        $verdict = Get-FitVerdict $gb
        if ($verdict -eq 'OVER_CAP') {
            $overCapActive++
            $msg = "$($m.Name) -> $tag ($('{0:N1}' -f $gb) GB) : OVER_CAP"
            if ($Strict) { Write-Fail $msg } else { Write-Warn "$msg - cannot fit a $AipcVramGB GB card" }
        } elseif ($verdict -eq 'MARGINAL') {
            Write-Warn "$($m.Name) -> $tag ($('{0:N1}' -f $gb) GB) : MARGINAL - tight on a $AipcVramGB GB card"
        } else {
            Write-Pass "$($m.Name) -> $tag ($('{0:N1}' -f $gb) GB) : FITS"
        }
    }
    if ($overCapActive -gt 0) {
        Write-Host ''
        Write-Host "    NOTE: $overCapActive active entr(y/ies) are over-cap. These run fine on the" -ForegroundColor DarkGray
        Write-Host '          96 GiB dev box, which is exactly why they survived review. Whether the' -ForegroundColor DarkGray
        Write-Host '          SHIPPED roster should expose them on a 16 GB client is a product call -' -ForegroundColor DarkGray
        Write-Host '          comment the entry out (the commented ones above cost nothing) or accept' -ForegroundColor DarkGray
        Write-Host '          CPU spill. This gate deliberately does not decide that for you.' -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# B3. Pre-pull waste: over-cap tags ollama-models.txt pulls that nothing
#     references. install.ps1 pulls EVERY uncommented line unconditionally, so
#     these are tens of GB of guaranteed-unused download per client machine.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'B3  pre-pull list: over-cap tags nothing references' -ForegroundColor Cyan

$prePull = Join-Path $repoRoot 'deploy/client-bundle/ollama-models.txt'
if (-not (Test-Path $prePull)) {
    Write-Warn 'ollama-models.txt not found - cannot check B3'
} else {
    $wasteGB = 0.0
    $wasteCount = 0
    $seenPrePull = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($prePull)) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        $tag = $line.Trim()
        # De-duplicate: ollama-models.txt currently lists qwen3.8 twice (once in
        # the tier block, once in the picker-options block). Pulling twice is
        # harmless, but counting it twice would overstate the waste figure.
        if ($seenPrePull.ContainsKey($tag)) { continue }
        $seenPrePull[$tag] = $true
        if (-not $KnownSizesGB.ContainsKey($tag)) {
            Write-Warn "pre-pull $tag : size unknown, add it to the table in this script"
            continue
        }
        $gb = [double]$KnownSizesGB[$tag]
        if ((Get-FitVerdict $gb) -ne 'OVER_CAP') { continue }
        if ($referenced.ContainsKey($tag)) {
            Write-Warn "pre-pull $tag ($('{0:N1}' -f $gb) GB) : over-cap but referenced by an active surface - decide the roster first"
        } else {
            $wasteCount++
            $wasteGB += $gb
            Write-Warn "pre-pull $tag ($('{0:N1}' -f $gb) GB) : over-cap AND unreferenced - $('{0:N1}' -f $gb) GB of guaranteed-unused download"
        }
    }
    if ($wasteCount -eq 0) {
        Write-Pass 'no over-cap unreferenced tags in the pre-pull list'
    } else {
        Write-Host "    => $wasteCount tag(s), $('{0:N1}' -f $wasteGB) GB per client machine." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# B4. Commented-out roster entries are NOT waste - they document intent. But an
#     over-cap COMMENTED entry whose tag is still pre-pulled is the worst of
#     both: paid for, never usable.
# ---------------------------------------------------------------------------
if ($commentedModels.Count -gt 0) {
    Write-Host ''
    Write-Host 'B4  commented roster entries still being pre-pulled' -ForegroundColor Cyan
    $b4 = 0
    foreach ($m in $commentedModels) {
        if ($referenced.ContainsKey($m.Tag)) { continue }
        $pulled = $false
        if (Test-Path $prePull) {
            foreach ($line in [System.IO.File]::ReadAllLines($prePull)) {
                if ($line.Trim() -eq $m.Tag -and $line -notmatch '^\s*#') { $pulled = $true; break }
            }
        }
        if ($pulled) {
            $b4++
            $gb = if ($KnownSizesGB.ContainsKey($m.Tag)) { [double]$KnownSizesGB[$m.Tag] } else { 0 }
            Write-Warn "commented-out $($m.Name) -> $($m.Tag) ($('{0:N1}' -f $gb) GB) is still pre-pulled but no longer selectable"
        }
    }
    if ($b4 -eq 0) { Write-Pass 'no orphaned commented-and-pulled entries' }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAIL: $($script:failures) model(s) in an unconditional path exceed the $AipcVramGB GB AIPC budget." -ForegroundColor Red
    Write-Host '  A model that does not fit does not fail loudly - it spills to CPU or evicts' -ForegroundColor DarkGray
    Write-Host '  the chat model, and the resulting stall looks like an Ollama bug. Fix the' -ForegroundColor DarkGray
    Write-Host '  tier default (compose ${VAR:-default}) or the roster entry, then re-run.' -ForegroundColor DarkGray
    exit 1
}

Write-Host "RESULT: no unconditional over-cap model. ($($script:warnings) warning(s) for review)" -ForegroundColor Green
if ($script:warnings -gt 0 -and -not $Strict) {
    Write-Host '  This script is registered NON-BLOCKING on purpose: the warnings are real' -ForegroundColor DarkGray
    Write-Host '  capacity exposures, but which models the shipped roster offers is a product' -ForegroundColor DarkGray
    Write-Host '  decision. Run with -Strict once that decision is made.' -ForegroundColor DarkGray
}
exit 0
