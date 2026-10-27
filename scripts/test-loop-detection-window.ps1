# Test: the per-tool loop guard must be WINDOWED, not monotonic, and sized with
# real headroom.
#
# BACKGROUND (measured 2026-10-27 on the AIPC box, deer-flow 0.2.6 / upstream v2.0.0)
#
#   A document-assembly turn was force-stopped mid-work with:
#
#     [FORCED STOP] Tool bash called 50 times - exceeded the per-tool safety
#     limit. Producing final answer with results collected so far.
#
#   The work was not a loop: thread 6cc8dfae made 92 tool calls in ONE run, 71 of
#   them bash and 55 of them DISTINCT commands (pandoc, weasyprint, docx XML
#   inspection, PDF probes). The guard cannot tell that from a loop because at
#   v2.0.0 it counted NAMES, monotonically:
#
#     self._tool_freq: dict[str, dict[str, int]]        # never decays
#     freq[name] += 1                                   # cleared only by reset()
#
#   and nothing in the gateway/worker path calls reset(), so every bash call for
#   a thread's whole life summed against one ceiling of 50.
#
#   Upstream fixed exactly this in e492bb1c (#4072, windowed deque + Counter) and
#   then 4746a257 (#4295, drop the Counter on evict/reset). Our pinned base image
#   is the v2.0.0 digest and predates both, so the fix is bind-mounted as
#   patches/deer-flow-loop-detection.py.
#
#   WINDOWING ALONE IS NOT ENOUGH. The middleware auto-sizes its window to
#   max(window_size, hard_limit, overrides), so at the shipped ceiling of 50 the
#   window is also 50. Measured across the 33 recorded runs on this box, the
#   worst single run already reaches 48 bash calls inside a 50-call window
#   (run 56b857ac: 61 bash of 68 calls). Two calls of headroom would keep
#   false-tripping, so deer-flow-config.yaml raises the pair to warn 90 / hard
#   150 (worst observed bash-in-150-window = 95, 37% headroom).
#
#   Layer 1 (identical tool-call hash, warn 3 / hard-stop 5) is untouched and is
#   what actually catches repeat loops. This gate locks in all three parts:
#   windowed L2, a ceiling with headroom, and L1 still armed.

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

# Capture a native command's stdout while tolerating stderr under 5.1.
#
# WHY THIS EXISTS (found 2026-10-27). This file sets
# $ErrorActionPreference = 'Stop', and on Windows PowerShell 5.1 a native
# command that writes to stderr raises NativeCommandError as a TERMINATING
# error the moment stderr is redirected. `2>$null` does not help - it is the
# redirection itself that triggers the conversion.
#
# Measured: `powershell -File scripts/test-loop-detection-window.ps1` died at
# the live-container step on LangChain's PendingDeprecationWarning, exited 1,
# and never evaluated the five live assertions - the whole reason this gate
# exists. Under pwsh 7 the same file reported 33 passed. `run-all-checks.ps1`
# prefers pwsh but falls back to powershell.exe, which is the normal case on a
# client machine, so this would have been a false failure there.
function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

$config  = 'deploy/client-bundle/deer-flow-config.yaml'
$patch   = 'deploy/client-bundle/patches/deer-flow-loop-detection.py'
$compose = 'deploy/client-bundle/compose.prod.yaml'
$bundle  = 'deploy/client-bundle/compose.bundle.yaml'
$audit   = 'scripts/audit-deer-flow-patches.ps1'

Write-Host '=== loop detection: windowed per-tool frequency guard ===' -ForegroundColor Cyan
Write-Output ''

# ── 1. the patch is present, mounts, and is the WINDOWED implementation ──────
Write-Host '1. the windowed-frequency patch is present and mounted' -ForegroundColor White
Assert-That (Test-Path $patch) "patch present at $patch"
$src = if (Test-Path $patch) { Get-Content -LiteralPath $patch -Raw } else { '' }

# The defect signature must be GONE. A monotonic dict keyed by thread with a
# nested per-name int is exactly what caused the false stop.
Assert-That ($src -notmatch 'self\._tool_freq:\s*dict\[str,\s*dict\[str,\s*int\]\]') `
    'the monotonic _tool_freq dict is gone'
Assert-That ($src -notmatch 'freq\[name\]\s*\+=\s*1') `
    'the monotonic freq[name] += 1 counter is gone'

# The fix must be PRESENT, both halves of it.
Assert-That ($src -match '_tool_name_history:\s*defaultdict\[str,\s*deque\[str\]\]') `
    'the windowed deque of recent tool names exists'
Assert-That ($src -match '_tool_name_counter:\s*defaultdict\[str,\s*Counter\[str\]\]') `
    'the mirror Counter exists (O(1) counts, no window scan)'
Assert-That ($src -match 'while\s+len\(tool_name_history\)\s*>\s*self\._tool_freq_window') `
    'the window is actually trimmed on every call (counts decay)'
Assert-That ($src -match '_tool_freq_window\s*=\s*max\(') `
    'the window is sized to the largest hard limit, not to window_size'
Assert-That ($src -match 'self\._tool_freq_warned\[thread_id\]\.discard\(name\)') `
    'a decayed count can warn again (warned-set pruning mirrors Layer 1)'

# #4295 cleanup: the Counter must be dropped wherever the deque is.
Assert-That ($src -match '(?s)self\._tool_name_history\.pop\(evicted_id.*?self\._tool_name_counter\.pop\(evicted_id') `
    'LRU eviction drops the Counter alongside the deque'
Assert-That ($src -match '(?s)self\._tool_name_history\.pop\(thread_id.*?self\._tool_name_counter\.pop\(thread_id') `
    'per-thread reset drops the Counter alongside the deque'
Assert-That ($src -match 'self\._tool_name_counter\.clear\(\)') `
    'full reset clears the Counter'

# Layer 1 must be untouched - it is what catches real loops.
Assert-That ($src -match 'count\s*>=\s*self\.hard_limit') `
    'Layer 1 (identical-call hash) still hard-stops'
Assert-That ($src -match '_DEFAULT_HARD_LIMIT\s*=\s*5') `
    'Layer 1 hard limit is still 5 consecutive identical call sets'

$csrc = if (Test-Path $compose) { Get-Content -LiteralPath $compose -Raw } else { '' }
$bsrc = if (Test-Path $bundle) { Get-Content -LiteralPath $bundle -Raw } else { '' }
$mountRe = 'deer-flow-loop-detection\.py:/app/backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware\.py'
Assert-That ($csrc -match $mountRe) 'compose.prod.yaml mounts the patch over the middleware'
Assert-That ($bsrc -match $mountRe) 'compose.bundle.yaml mounts the patch (lanes must not drift)'

# The image must ALSO carry it: the mount covers the client lanes, but a bare run
# of the published image (no client compose) would otherwise keep the defect.
# The v2.0.0 base must have NO dependency on helpers introduced later. The
# windowed fix was cherry-picked onto the v2.0.0 file precisely so it does not
# need ``_bounded_dict`` (added upstream with the loop_capped stop_reason work,
# #3875 Phase 2, which is NOT part of this backport). If someone later re-syncs
# this file against a newer upstream snapshot instead, that import arrives with
# it and the container dies at import time - loud, but only after a rebuild.
Assert-That ($src -notmatch 'from deerflow\.agents\.middlewares\._bounded_dict import') `
    'the patch does not import _bounded_dict (absent from the pinned v2.0.0 image)'

$df = 'deploy/deer-flow-pacgate/Dockerfile'
$dsrc = if (Test-Path $df) { Get-Content -LiteralPath $df -Raw } else { '' }
Assert-That ($dsrc -match 'COPY deploy/client-bundle/patches/deer-flow-loop-detection\.py /app/backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware\.py') `
    'the published image bakes the patched middleware (standalone runs are covered too)'
Write-Output ''

# ── 2. the ceiling has real headroom, not a theoretical one ─────────────────
# A window equal to the hard limit means the guard fires on a run that merely
# has a bash-heavy stretch - which is every document-assembly run on this box.
Write-Host '2. the configured ceiling leaves headroom' -ForegroundColor White
Assert-That (Test-Path $config) "config present at $config"
$cfg = Get-Content -LiteralPath $config -Raw
function Get-TopLevelBlock {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Key)
    # Line-accurate on purpose: dotall (an 's' flag) makes '.*' span newlines, so a
    # block extractor written that way silently swallows the REST of the file and
    # makes every "blocks agree" comparison fail for the wrong reason.
    $lines = $Text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $in = $false
    foreach ($line in $lines) {
        if (-not $in) {
            if ($line -match "^$Key\s*:\s*$") { $in = $true }
            continue
        }
        if ($line -notmatch '^\s' -and $line.Trim() -ne '') { break }
        $out.Add($line)
    }
    return ($out -join "`n").Trim()
}

$ldBlock = Get-TopLevelBlock -Text $cfg -Key 'loop_detection'
Assert-That ($ldBlock -ne '') 'loop_detection section exists in deer-flow-config.yaml'

$warn = if ($ldBlock -match '(?m)^\s*tool_freq_warn:\s*(\d+)') { [int]$Matches[1] } else { 30 }
$hard = if ($ldBlock -match '(?m)^\s*tool_freq_hard_limit:\s*(\d+)') { [int]$Matches[1] } else { 50 }

# The baked (standalone) config must agree, or a bare image run keeps the tripwire.
$baked = 'deploy/deer-flow-pacgate/config.yaml'
$bakedTxt = if (Test-Path $baked) { Get-Content -LiteralPath $baked -Raw } else { '' }
$bakedBlock = Get-TopLevelBlock -Text $bakedTxt -Key 'loop_detection'
Assert-That ($bakedBlock -ne '') 'the image-baked config also sets loop_detection (standalone runs must not regress)'
Assert-That ($bakedBlock -eq $ldBlock) 'the two configs agree on the loop guard (drift here re-arms the trap in one lane)'
# Per-tool override for bash. The middleware auto-sizes its window to the LARGEST
# hard limit in play, so this value also sets the window length.
$bashHard = if ($ldBlock -match '(?s)bash:\s*\n((?:[ \t]+.*\n?)+)') { if ($Matches[1] -match '(?m)^\s*hard_limit:\s*(\d+)') { [int]$Matches[1] } else { 0 } } else { 0 }
$bashWarn = if ($ldBlock -match '(?s)bash:\s*\n((?:[ \t]+.*\n?)+)') { if ($Matches[1] -match '(?m)^\s*warn:\s*(\d+)') { [int]$Matches[1] } else { 0 } } else { 0 }

# Measured worst same-tool density inside a 150-call window across the 33 runs on
# this box: bash 74, write_file 22, read_file 10.
Assert-That ($bashHard -ge 100) "bash override hard_limit ($bashHard) has real headroom over the measured peak of 74"
Assert-That ($bashWarn -ge 50 -and $bashWarn -lt $bashHard) "bash override warn ($bashWarn) fires between 50 and its hard limit ($bashHard)"

# The GLOBAL ceiling must stay tight. Raised globally it would also raise the
# window, and it would weaken the read_file/write_file protection that catches a
# runaway across many files - real peaks there are 10 and 22.
Assert-That ($hard -le 100) "global hard_limit ($hard) stays tight (bash is raised by override, not by loosening everyone)"
Assert-That ($warn -lt $hard) "global tool_freq_warn ($warn) fires before the global hard stop ($hard)"
Assert-That ($warn -ge 30) "global tool_freq_warn ($warn) is not below the old default (a warning that fires too early is noise)"
Write-Output ''

# ── 3. the patch stack audit knows about the new file ───────────────────────
# A bind-mount onto a path upstream moved or renamed lands on nothing and the
# container starts with our fix silently absent. The audit is the loud failure
# for that, and it can only check paths it was told about.
Write-Host '3. the rebase audit tracks the new patch' -ForegroundColor White
$asrc = if (Test-Path $audit) { Get-Content -LiteralPath $audit -Raw } else { '' }
Assert-That ($asrc -match "'deer-flow-loop-detection\.py'\s*=") `
    'audit-deer-flow-patches.ps1 maps the new patch to its upstream path'
Assert-That ($asrc -match 'middlewares/loop_detection_middleware\.py') `
    'the mapped path is the middleware the mount targets'
Write-Output ''

# ── 4. live behaviour, when the container is up ─────────────────────────────
# Static checks cannot prove the counter decays. Replay a real bash-heavy run
# shape through the MOUNTED module: it must not stop, while a tight burst and an
# identical repeat loop must still stop.
Write-Host '4. live behaviour in the running container' -ForegroundColor White
$running = $false
try {
    $health = & docker inspect deer-flow --format '{{.State.Health.Status}}' 2>$null
    $running = (($health | Out-String).Trim() -eq 'healthy')
} catch { $running = $false }

if (-not $running) {
    Write-Host '  [SKIP] deer-flow is not healthy on this machine - static checks only' -ForegroundColor Yellow
} else {
    $py = @'
import sys
sys.path.insert(0, "/app/backend/packages/harness")
from deerflow.config.app_config import AppConfig
from deerflow.agents.middlewares.loop_detection_middleware import LoopDetectionMiddleware
from langchain_core.messages import AIMessage
from types import SimpleNamespace

ld = AppConfig.from_file("/app/backend/config.yaml").loop_detection
win = LoopDetectionMiddleware.from_config(ld)._tool_freq_window
print("WINDOW=%d HARD=%d" % (win, ld.tool_freq_hard_limit))

def play(seq):
    mw = LoopDetectionMiddleware.from_config(ld)
    msgs, out = [], []
    rt = SimpleNamespace(context={"thread_id": "t", "run_id": "r"})
    for i, (name, args) in enumerate(seq):
        msgs.append(AIMessage(content="", tool_calls=[{"name": name, "args": args, "id": "c%d" % i}]))
        warn, stop = mw._track_and_check({"messages": msgs}, rt)
        out.append((warn, stop))
        if stop:
            return i + 1
    return None

# bash-heavy but productive: 92 calls with bash interleaved with reads/writes,
# matching the measured shape of the run that was force-stopped.
heavy = []
for i in range(92):
    if i % 4 == 3:
        heavy.append(("read_file", {"path": "f%d.md" % i}))
    elif i % 9 == 8:
        heavy.append(("write_file", {"path": "o%d.md" % i, "content": "x"}))
    else:
        heavy.append(("bash", {"command": "python3 step_%d.py" % i}))
print("PRODUCTIVE_TRIP=%s" % play(heavy))

tight = [("bash", {"command": "echo %d" % i}) for i in range(400)]
print("TIGHT_TRIP=%s" % play(tight))

same = [("bash", {"command": "python3 build.py"}) for _ in range(8)]
print("REPEAT_TRIP=%s" % play(same))
'@
    # Invoke-NativeCapture, not a bare redirect: this file sets
    # $ErrorActionPreference = 'Stop', and 5.1 turns any native stderr write into
    # a terminating NativeCommandError once stderr is redirected. See the helper.
    $out = Invoke-NativeCapture { $py | & docker exec -i deer-flow /app/backend/.venv/bin/python }
    $text = ($out | Out-String)
    $window = if ($text -match 'WINDOW=(\d+)') { [int]$Matches[1] } else { 0 }
    $liveHard = if ($text -match 'HARD=(\d+)') { [int]$Matches[1] } else { 0 }
    Assert-That ($window -ge $bashHard) "mounted middleware window ($window) covers the bash override ceiling ($bashHard)"
    Assert-That ($liveHard -eq $hard) "mounted global hard limit ($liveHard) matches the config file ($hard)"
    Assert-That ($text -match 'PRODUCTIVE_TRIP=None') `
        'the measured 92-call productive shape no longer force-stops'
    Assert-That ($text -match 'TIGHT_TRIP=\d+') `
        'a genuine tight burst still force-stops (the guard is not disabled)'
    Assert-That ($text -match 'REPEAT_TRIP=5') `
        'an identical repeat loop still stops at Layer 1 (5)'
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    Write-Host '  Either the windowed backport regressed to the monotonic counter, the ceiling' -ForegroundColor Red
    Write-Host '  was lowered back to a tripwire, or the patch stopped being mounted.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
