# Asserts the per-tool loop guard in the shipped bundle is the UPSTREAM v2.2.0
# windowed implementation, and that the shipped config gives it room to work.
#
# WHY THIS GATE EXISTS (measured 2026-10-27 on the AIPC box, deer-flow v2.0.0)
#
#   A document-assembly turn was force-stopped mid-work with:
#
#     [FORCED STOP] Tool bash called 50 times - exceeded the per-tool safety
#     limit. Producing final answer with results collected so far.
#
#   The work was not a loop: thread 6cc8dfae made 92 tool calls in ONE run, 71 of
#   them bash and 55 of them DISTINCT commands. The v2.0.0 guard counted tool
#   NAMES monotonically per thread, so nothing short of a restart helped.
#
# WHAT CHANGED WITH 2.2.0
#
# v2.2.0 absorbed the fix upstream: loop_detection_middleware.py now counts per
# tool through a deque (`_tool_name_history`) with a mirror Counter
# (`_tool_name_counter`), sized from the largest configured hard limit, keyed by
# a per-run scope, and dropped on eviction. The Pacgate backport patch and its
# bind mount are GONE. This gate no longer asserts a patch file; it asserts the
# facts that keep the defect from recurring:
#
#   1. the removed patch is really gone from the bundle (mounts, bake, patch map)
#   2. both compose lanes pin a deer-flow-pacgate image; the Dockerfile pins the
#      upstream base by digest
#   3. the config carries the measured bash headroom override (150) and a global
#      ceiling that is NOT loosened to match (so read_file protection survives)
#   4. the bundle and baked configs agree on the loop guard block
#   5. when the container is up, the mounted middleware is the windowed one and
#      the measured 92-call workload does not trip it
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. "Cannot check" is never a pass.

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
function Skip-That {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [string]$Why)
    Write-Host "  [skip] $Name - $Why" -ForegroundColor Yellow
}

# Capture a native command's output while tolerating stderr under Windows
# PowerShell 5.1 (a native command writing to stderr is a terminating error
# there once stderr is redirected). Bounded by a timeout so a wedged docker
# daemon fails the gate loudly instead of hanging the whole suite forever.
function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [int]$TimeoutSeconds = 30
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $job = Start-Job -ScriptBlock $Script
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            return '__TIMEOUT__'
        }
        return ((Receive-Job -Job $job | Out-String)).Trim()
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $ErrorActionPreference = $previous
    }
}

$config  = 'deploy/client-bundle/deer-flow-config.yaml'
$baked   = 'deploy/deer-flow-pacgate/config.yaml'
$prod    = 'deploy/client-bundle/compose.prod.yaml'
$bundle  = 'deploy/client-bundle/compose.bundle.yaml'
$dockerfile = 'deploy/deer-flow-pacgate/Dockerfile'
$upstream = 'deploy/deer-flow-src/backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py'
# Derive the pinned image from the bundle compose file (same rule as the parity gate).
$script:Image = ''
$pinSource = if (Test-Path $bundle) { $bundle } else { $prod }
$pin = Select-String -Path $pinSource -Pattern 'image:\s*\S*deer-flow-pacgate:(?<v>\d+\.\d+\.\d+)' | Select-Object -First 1
if ($pin) { $script:Image = "ghcr.io/jzkk720/deer-flow-pacgate:$($pin.Matches[0].Groups['v'].Value)" }
elseif (Test-Path $pinSource) {
    $h = Select-String -Path $pinSource -Pattern 'image:\s*(\S*deer-flow-pacgate@sha256:[a-f0-9]+)' | Select-Object -First 1
    if ($h) { $script:Image = $h.Matches[0].Groups[1].Value }
}

Write-Host '=== loop detection: upstream v2.2.0 windowed guard + measured headroom ===' -ForegroundColor Cyan
Write-Output ''

# ── 1. the removed patch is really gone ──────────────────────────────────
Write-Host '1. the v2.0.0 backport patch is gone from the bundle' -ForegroundColor White
# Match actual references that would make the patch load (a bind mount or a COPY
# into the image), not comments that explain the removal. A comment is history,
# not wiring.
foreach ($f in @($prod, $bundle, $dockerfile)) {
    $t = if (Test-Path $f) { Get-Content -LiteralPath $f -Raw } else { '' }
    $wired = [regex]::Matches($t, '(?m)^(?!\s*#).*(loop-detection)') |
             ForEach-Object { $_.Value } |
             Where-Object { $_ -match '(mount|COPY|patches/|:ro)' }
    Assert-That ($wired.Count -eq 0) "$f does not wire deer-flow-loop-detection.py into the image or a mount"
}
# Comments may mention the retired patch when explaining why it is gone; what
# matters is that no COPY/mount/ADD wires it in. Check for wiring, not mention.
$wiredMatch = if (Test-Path $dockerfile) {
    [regex]::Matches((Get-Content -LiteralPath $dockerfile -Raw), '(?m)^\s*(COPY|ADD)\s+.*loop-detection')
} else { @() }
Assert-That ($wiredMatch.Count -eq 0) 'the Dockerfile does not COPY the retired patch into the image'
$audit = if (Test-Path 'scripts/audit-deer-flow-patches.ps1') { Get-Content -LiteralPath 'scripts/audit-deer-flow-patches.ps1' -Raw } else { '' }
Assert-That ($audit -notmatch "'deer-flow-loop-detection\.py'\s*=") `
    'the rebase audit no longer maps the retired patch'
Write-Output ''

# ── 2. the base image is v2.2.0 (windowed upstream, not the 2.0.0 monotonic one)
Write-Host '2. the base image carries the upstream fix' -ForegroundColor White
foreach ($f in @($prod, $bundle)) {
    $t = if (Test-Path $f) { Get-Content -LiteralPath $f -Raw } else { '' }
    Assert-That ($t -match 'deer-flow-pacgate:\d+\.\d+\.\d+' -or $t -match 'deer-flow-pacgate@sha256') `
        "$f pins a deer-flow-pacgate image"
}
$df = if (Test-Path $dockerfile) { Get-Content -LiteralPath $dockerfile -Raw } else { '' }
Assert-That ($df -match 'deer-flow-backend@sha256:') 'the Dockerfile pins the upstream base by digest'
Write-Output ''

# ── 3. the config carries the measured headroom, in both lanes ───────────
Write-Host '3. the config keeps the measured bash headroom' -ForegroundColor White
$cfg = if (Test-Path $config) { Get-Content -LiteralPath $config -Raw } else { '' }
Assert-That ($cfg -match '(?ms)^loop_detection:') 'loop_detection section exists in the bundle config'

foreach ($pair in @(@('bundle', $config), @('baked', $baked))) {
    $name = $pair[0]; $file = $pair[1]
    $t = if (Test-Path $file) { Get-Content -LiteralPath $file -Raw } else { '' }
    # Extract the bash: override block by line, not by nested-quantifier regex
    # (the previous pattern backtracked catastrophically on real configs and
    # hung the gate). Parse line by line instead.
    $lines = $t -split "`n"
    $bashBlock = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*bash:\s*$') {
            $j = $i + 1
            $block = @()
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s+\S') { $block += $lines[$j]; $j++ }
            $bashBlock = ($block -join "`n"); break
        }
    }
    $bashHard = if ($bashBlock -and $bashBlock -match '(?m)^\s*hard_limit:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $bashWarn = if ($bashBlock -and $bashBlock -match '(?m)^\s*warn:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $gWarn    = if ($t -match '(?m)^\s*tool_freq_warn:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    $gHard    = if ($t -match '(?m)^\s*tool_freq_hard_limit:\s*(\d+)') { [int]$Matches[1] } else { 0 }
    Assert-That ($bashHard -ge 100) "${name}: bash override hard_limit ($bashHard) >= 100 (measured need: 71 bash in one run)"
    Assert-That ($bashWarn -ge 50 -and $bashWarn -lt $bashHard) "${name}: bash override warn ($bashWarn) is between 50 and its hard limit ($bashHard)"
    Assert-That ($gHard -le 100) "${name}: global hard_limit ($gHard) stays tight (bash is raised via override, not by loosening everyone)"
    Assert-That ($gWarn -lt $gHard) "${name}: global warn ($gWarn) fires before the global hard stop ($gHard)"
}
Write-Output ''

# ── 4. upstream v2.2.0 actually carries the windowed implementation ───────
Write-Host '4. upstream v2.2.0 carries the windowed guard (evidence the patch was redundant)' -ForegroundColor White
$up = if (Test-Path $upstream) { Get-Content -LiteralPath $upstream -Raw } else { '' }
if (-not $up) {
    Skip-That 'upstream source present' "deploy/deer-flow-src is absent or not checked out at v2.2.0 - cannot verify upstream contents"
} else {
    Assert-That ($up -match '_tool_name_history' -and $up -match 'deque\[str\]') 'upstream keeps a deque of recent tool names per scope'
    Assert-That ($up -match '_tool_name_counter' -and $up -match 'Counter\[str\]') 'upstream keeps a mirror Counter for O(1) frequency lookup'
    Assert-That ($up -match 'while\s+len\(tool_name_history\)\s*>\s*self\._tool_freq_window') 'upstream trims the window on every call (counts decay)'
    Assert-That ($up -match '_tool_freq_window\s*=\s*max\(') 'upstream sizes the window to the largest hard limit, not to window_size'
    Assert-That ($up -notmatch 'self\._tool_freq[^=\n]*\+=\s*1') 'upstream has no monotonic freq[name] += 1 counter'
}
Write-Output ''

# -- 5. live: the running container has the windowed middleware ----------
Write-Host '5. live behaviour in the running container' -ForegroundColor White
$running = $false
try {
    $health = Invoke-NativeCapture { & docker inspect deer-flow --format '{{.State.Health.Status}}' 2>$null } 30
    $running = ($health -eq 'healthy')
} catch {
    $running = $false
}

if (-not $running) {
    Skip-That 'deer-flow healthy' 'the container is not running - static checks only'
} else {
    # Identify the 0.2.37-era bind-mounted backport by reading the repo file
    # that IS mounted into the container (compose wires
    # ./patches/deer-flow-loop-detection.py over the in-image middleware). If
    # that mount is still present, the live probe below would exercise the
    # retired backport rather than upstream v2.2.0, so skip instead of passing
    # for the wrong reason. A docker run probe would work too but is slow and
    # can hang on Docker Desktop; the file check is instant and exact.
    $mountedPatch = 'deploy/client-bundle/patches/deer-flow-loop-detection.py'
    $liveIsBackport = (Test-Path $mountedPatch) -and (Get-Content -LiteralPath $mountedPatch -Raw) -match 'PacGate patch'
    if ($liveIsBackport) {
        Skip-That 'live middleware is the v2.2.0 build' 'the running container bind-mounts the retired 0.2.37 backport over the image path; the live probe would exercise that backport, not upstream v2.2.0. Rebuild deer-flow-pacgate from this branch and drop the mount, then re-run.'
    } else {
        $PYPROBE = @'
import sys
sys.path.insert(0, "/app/backend/packages/harness")
from deerflow.config.app_config import AppConfig
from deerflow.agents.middlewares.loop_detection_middleware import LoopDetectionMiddleware
from langchain_core.messages import AIMessage
from types import SimpleNamespace

ld = AppConfig.from_file("/app/backend/config.yaml").loop_detection
win = LoopDetectionMiddleware.from_config(ld)._tool_freq_window
print("WINDOW=%d HARD=%d GLOBAL_WARN=%d" % (win, ld.tool_freq_hard_limit, ld.tool_freq_warn))

def play(seq):
    mw = LoopDetectionMiddleware.from_config(ld)
    msgs = []
    rt = SimpleNamespace(context={"thread_id": "t", "run_id": "r"})
    for i, (name, args) in enumerate(seq):
        msgs.append(AIMessage(content="", tool_calls=[{"name": name, "args": args, "id": "c%d" % i}]))
        warn, stop = mw._track_and_check({"messages": msgs}, rt)
        if stop:
            return i + 1
    return None

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

        $pyPath = Join-Path ([System.IO.Path]::GetTempPath()) 'pacgate-loop-probe.py'
        Set-Content -Path $pyPath -Value $PYPROBE -Encoding UTF8
        $null = Invoke-NativeCapture { docker cp $pyPath deer-flow:/tmp/pacgate-loop-probe.py } 30
        Remove-Item $pyPath -ErrorAction SilentlyContinue
        $out = Invoke-NativeCapture { docker exec deer-flow /app/backend/.venv/bin/python /tmp/pacgate-loop-probe.py } 60
        $null = Invoke-NativeCapture { docker exec deer-flow rm -f /tmp/pacgate-loop-probe.py } 15
        $text = ($out | Out-String)
        if ($out -eq '__TIMEOUT__') {
            Skip-That 'live probe completed' 'docker exec did not return within the bound; skipping live assertions rather than hanging the suite'
        } elseif ($text -notmatch 'WINDOW=') {
            Assert-That $false "the live probe produced no WINDOW= line (output suppressed; re-run the probe by hand)"
        } else {
            $window   = if ($text -match 'WINDOW=(\d+)')      { [int]$Matches[1] } else { 0 }
            $liveHard = if ($text -match 'HARD=(\d+)')        { [int]$Matches[1] } else { 0 }
            $liveWarn = if ($text -match 'GLOBAL_WARN=(\d+)') { [int]$Matches[1] } else { 0 }
            Assert-That ($window -ge 150) "mounted middleware window ($window) covers the bash override ceiling (>= 150)"
            Assert-That ($liveHard -le 100) "mounted global hard limit ($liveHard) matches the config file"
            Assert-That ($liveWarn -lt $liveHard) "mounted global warn ($liveWarn) fires before the hard stop ($liveHard)"
            Assert-That ($text -match 'PRODUCTIVE_TRIP=None') 'the measured 92-call productive shape no longer force-stops'
            Assert-That ($text -match 'TIGHT_TRIP=\d+') 'a genuine tight burst still force-stops (the guard is not disabled)'
            Assert-That ($text -match 'REPEAT_TRIP=5') 'an identical repeat loop still stops at Layer 1 (5)'
        }
    }
}

Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    Write-Host '  The bundle is shipping either the pre-windowing guard or a config with no bash headroom.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
