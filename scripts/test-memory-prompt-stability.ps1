# Asserts the memory lane's prompt is PREFIX-STABLE after the deer-flow 2.2.0
# upgrade. See header history in git for the measured prefill numbers.
#
# WHY THIS GATE EXISTS (measured 2026-10-26/27, HX370 box, Ollama 0.40.11,
# gemma4:12b-it-qat)
#
# Upstream v2.2.0 ships memory_update.chat.yaml with the user message ordered:
#     Current Memory State -> <current_memory> -> New Conversation -> <conversation>
# `current_memory` changes on every update, so the prefix changed every update
# and llama.cpp could never reuse the cached prefix. Holding the conversation
# constant, updates measured 77.7s / 68.7s / 68.7s, then 0.5s identical rerun.
# After moving the conversation block first, the same sequence measured
# 68.9s -> 1.3s -> 1.2s.
#
# HOW IT SHIPS IN 2.2.0
# deer-flow 2.2.0 moved the memory prompt into core/prompts/memory_update.chat.yaml
# loaded via load_prompt_messages(..., prompts_dir=...) from memory.backend_config
# .prompts_dir. The fork is a YAML fork under deploy/client-bundle/memory-prompts/,
# not a .py patch. prompts_dir is all-or-nothing: EVERY template resolves from
# it, so the directory also carries verbatim copies of the other three templates.
#
# WHAT THIS GATE ASSERTS
#   1. every template prompts_dir must contain is present and parses
#   2. the forked template's system message is byte-identical to upstream
#      (it carries the cached prefix - it must not drift)
#   3. the user message has <conversation> before <current_memory>
#   4. both compose lanes mount the prompts dir, both configs set
#      backend_config.prompts_dir at it, and the Dockerfile bakes it
#   5. the three non-forked templates match upstream v2.2.0 byte-for-byte
#
# WHAT IT DOES NOT ASSERT (honest gap)
# The 2.0.0-era gate also asserted a hard total cap on the conversation text.
# Upstream 2.2.0 removed that cap; growth is now bounded by the extraction
# watermark (only new turns are fed) plus a per-message 1000-char truncation,
# not by a total. Restoring a total cap means forking prompt.py, which is a
# much heavier maintenance burden. If the memory prompt ever measures big
# again, fork format_conversation_for_update, not this file, and restore a
# cap assertion here.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

Write-Host '=== memory prompt prefix stability (prompts_dir fork) ===' -ForegroundColor Cyan

$bundle = 'deploy/client-bundle'
$promptDir = Join-Path $bundle 'memory-prompts'
$chatYaml = Join-Path $promptDir 'memory_update.chat.yaml'
$otherTemplates = @('staleness_review.yaml', 'consolidation.yaml', 'fact_extraction.yaml')
$srcRoot = 'deploy/deer-flow-src'
$upstreamDir = 'backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/prompts'

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Host '  exit 2 - no python on PATH; cannot parse the templates' -ForegroundColor Yellow
    exit 2
}

if (-not (Test-Path $promptDir)) {
    Write-Host "  exit 2 - $promptDir not found; the prompts_dir fork is missing" -ForegroundColor Yellow
    exit 2
}

# -- 1. every template prompts_dir must provide is present and parses --
foreach ($name in @('memory_update.chat.yaml') + $otherTemplates) {
    $p = Join-Path $promptDir $name
    if (-not (Test-Path $p)) { Fail "$name missing from prompts_dir (prompts_dir is all-or-nothing)"; continue }
    $r = & $py.Source -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1],encoding='utf-8')); print(d.get('format'))" $p 2>&1
    if ($LASTEXITCODE -eq 0) { Pass "$name parses (format=$r)" } else { Fail "$name does not parse: $r" }
}

# -- 2/3. user-block order and system-message identity --------------------
$probe = @'
import sys, yaml
fork = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
msgs = fork["messages"]
user = next(m["content"] for m in msgs if m["role"] == "user")
print("CONV=%d MEM=%d" % (user.find("<conversation>"), user.find("<current_memory>")))
'@
$probePath = Join-Path ([System.IO.Path]::GetTempPath()) 'pacgate-prompt-order.py'
Set-Content -Path $probePath -Value $probe -Encoding UTF8
try {
    $out = & $py.Source $probePath $chatYaml 2>&1
    if ("$out" -match 'CONV=(\d+) MEM=(\d+)') {
        $conv = [int]$Matches[1]; $mem = [int]$Matches[2]
        if ($conv -ge 0 -and $mem -ge 0 -and $conv -lt $mem) {
            Pass 'the user message puts <conversation> before <current_memory> (stable prefix)'
        } else {
            Fail "user block order is wrong (conversation=$conv memory=$mem) - the volatile block is ahead of the stable one and llama.cpp can never reuse the prefix"
        }
    } else {
        Fail "could not parse the user block: $out"
    }
} finally { Remove-Item $probePath -ErrorAction SilentlyContinue }

# Upstream comparison (skipped with a note when the clone is absent)
$upOk = Test-Path $srcRoot
if ($upOk) {
    $upPath = Join-Path ([System.IO.Path]::GetTempPath()) 'pacgate-upstream-memory-update.yaml'
    & git -C $srcRoot show "v2.2.0:$upstreamDir/memory_update.chat.yaml" > $upPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        $sysProbe = @'
import sys, yaml
up = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
fork = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
up_sys = next(m["content"] for m in up["messages"] if m["role"] == "system")
fork_sys = next(m["content"] for m in fork["messages"] if m["role"] == "system")
print("SAME" if up_sys == fork_sys else "DIFF")
'@
        $sp = Join-Path ([System.IO.Path]::GetTempPath()) 'pacgate-sys-compare.py'
        Set-Content -Path $sp -Value $sysProbe -Encoding UTF8
        $sysOut = & $py.Source $sp $upPath $chatYaml 2>&1
        Remove-Item $sp, $upPath -ErrorAction SilentlyContinue
        if ("$sysOut" -match 'SAME') {
            Pass 'the fork keeps upstream system message byte-identical (cached prefix preserved)'
        } else {
            Fail "the fork's system message differs from upstream: $sysOut"
        }
    } else {
        Write-Host '  [ .. ] upstream v2.2.0 not readable; system-message identity not checked' -ForegroundColor DarkGray
        $upOk = $false
    }
}

# -- 4. compose lanes mount it, configs set prompts_dir, image bakes it --
foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $f2 = Join-Path $bundle $lane
    $t = if (Test-Path $f2) { Get-Content $f2 -Raw } else { '' }
    if ($t -match [regex]::Escape('./memory-prompts:/app/prompts/memory')) {
        Pass "$lane mounts memory-prompts at /app/prompts/memory"
    } else {
        Fail "$lane does not mount memory-prompts - the fork would not reach the container"
    }
}
foreach ($cfg in @("$bundle/deer-flow-config.yaml", 'deploy/deer-flow-pacgate/config.yaml')) {
    $t = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { '' }
    if ($t -match '(?m)^\s*prompts_dir:\s*/app/prompts/memory\s*$') {
        Pass "$cfg sets backend_config.prompts_dir"
    } else {
        Fail "$cfg does not set prompts_dir - the fork would be ignored"
    }
}
$df = Get-Content 'deploy/deer-flow-pacgate/Dockerfile' -Raw -ErrorAction SilentlyContinue
if ($df -match 'COPY deploy/client-bundle/memory-prompts /app/prompts/memory') {
    Pass 'the image bakes memory-prompts (standalone runs are covered)'
} else {
    Fail 'the Dockerfile does not bake memory-prompts - a standalone run loses the fork'
}

# -- 5. the three copied templates have not drifted from upstream ----------
if (Test-Path $srcRoot) {
    foreach ($name in $otherTemplates) {
        $gpath = "v2.2.0:$upstreamDir/$name"
        $up = & git -C $srcRoot show $gpath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ .. ] $name - upstream v2.2.0 not readable; drift not checked" -ForegroundColor DarkGray
            continue
        }
        $local = (Get-Content (Join-Path $promptDir $name) -Raw).TrimEnd()
        $remote = (($up -join "`n")).TrimEnd()
        if ($local -eq $remote) {
            Pass "$name matches upstream v2.2.0 verbatim"
        } else {
            Fail "$name has drifted from upstream v2.2.0 - rebase onto the upstream copy, do not hand-edit"
        }
    }
} else {
    Write-Host "  [ .. ] $srcRoot not present; upstream drift not checked" -ForegroundColor DarkGray
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "$($script:failures) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
