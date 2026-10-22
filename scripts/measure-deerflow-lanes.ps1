# Measure WHERE a deer-flow turn spends its time: prompt overhead, prefill,
# decode, model reloads, and host RAM held by llama-server's prompt cache.
#
# WHY THIS EXISTS (measured 2026-10-21 on the HX370 box, Ollama 0.40.6)
#   "deer-flow is slow" was being answered with guesses about VRAM. The
#   measurements showed VRAM was never the constraint: the card held 6.4 GiB
#   free while the host sat at 0.03 MB available memory. Every conclusion below
#   comes from one of four sources and this script reports all four, so the next
#   investigation starts from numbers instead of intuition:
#
#     1. `ollama ps`            - which runner is resident, at which context
#     2. %LOCALAPPDATA%\Ollama\server.log
#                               - llama.cpp's own timing and memory accounting
#                                 (the only place that reports prompt-cache and
#                                 KV split separately from weights)
#     3. deerflow.db            - per-run token totals recorded by deer-flow
#     4. Windows perf counters  - host commit charge vs WSL's VM ceiling
#
# WHAT IT CANNOT DO
#   It does not load models or send prompts. It is a READ-ONLY probe, so it is
#   safe to run against a live stack and cannot itself cause an eviction.
#
# Usage:
#   .\scripts\measure-deerflow-lanes.ps1
#   .\scripts\measure-deerflow-lanes.ps1 -Json

[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Get-LlamaLog { Join-Path $env:LOCALAPPDATA 'Ollama\server.log' }

# ── 1. resident runners ──────────────────────────────────────────────────────
function Get-ResidentRunners {
    $rows = @()
    $out = & ollama ps 2>$null
    if (-not $out) { return $rows }
    foreach ($line in ($out | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        # NAME ID SIZE PROCESSOR CONTEXT RUNNER UNTIL - split on runs of 2+ spaces
        $f = @($line.Trim() -split '\s{2,}')
        if ($f.Count -lt 6) { continue }
        $rows += [pscustomobject]@{
            Name    = $f[0]
            Id      = $f[1]
            Size    = $f[2]
            Gpu     = $f[3]
            Context = $f[4]
        }
    }
    return $rows
}

# ── 2. host memory vs the WSL ceiling ────────────────────────────────────────
# The Windows "50 of 64 GB" reading is COMMIT CHARGE, not working set, and most of
# it is vmmemWSL. This reports both so the two cannot be confused again.
function Get-HostMemory {
    $r = [pscustomobject]@{
        RamGiB          = $null
        CommitUsedGiB   = $null
        CommitLimitGiB  = $null
        AvailableMiB    = $null
        VmmemWSLGiB     = $null
        WslVmCeilingGiB = $null
        ContainerSumGiB = $null
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $r.RamGiB         = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $r.CommitLimitGiB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 2)
        $r.AvailableMiB   = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
    } catch { }
    try {
        $c = Get-Counter '\Memory\Committed Bytes' -ErrorAction Stop
        $r.CommitUsedGiB = [math]::Round($c.CounterSamples[0].CookedValue / 1GB, 2)
    } catch { }
    $v = Get-Process vmmemWSL -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($v) { $r.VmmemWSLGiB = [math]::Round($v.PrivateMemorySize64 / 1GB, 2) }
    try {
        $mem = (docker info --format '{{.MemTotal}}' 2>$null)
        if ($mem -match '^\d+$') { $r.WslVmCeilingGiB = [math]::Round([double]$mem / 1GB, 2) }
    } catch { }
    return $r
}

# ── 3. prompt overhead: what deer-flow actually binds per call ───────────────
# The single largest fixed cost on a 16 GB box is the tool schema surface, which
# is bound into EVERY prompt. Measured live rather than assumed, because it
# changes whenever an MCP server is added or tool_search is toggled.
function Get-ToolSurface {
    $py = @'
from deerflow.tools.tools import get_available_tools
import json
try:
    tools = get_available_tools()
except Exception as e:
    print(json.dumps({"error": str(e)})); raise SystemExit
tot = 0; rows = []
for t in tools:
    s = json.dumps({"name": t.name, "description": t.description,
                    "args": getattr(t, "args", {})})
    tot += len(s); rows.append({"name": t.name, "chars": len(s)})
rows.sort(key=lambda r: -r["chars"])
try:
    from deerflow.config.app_config import get_app_config
    ts = getattr(get_app_config(), "tool_search", None)
    ts_enabled = bool(getattr(ts, "enabled", False)) if ts is not None else False
except Exception:
    ts_enabled = None
print(json.dumps({"count": len(tools), "chars": tot,
                  "approx_tokens": tot // 4, "tool_search_enabled": ts_enabled,
                  "largest": rows[:8]}))
'@
    try {
        $raw = $py | docker exec -i deer-flow /app/backend/.venv/bin/python - 2>$null
        $line = @($raw | Where-Object { $_ -match '^\{' })[-1]
        if (-not $line) { return $null }
        return $line | ConvertFrom-Json
    } catch { return $null }
}

# ── 4. llama.cpp ground truth from server.log ────────────────────────────────
# Everything here is parsed, not inferred. Two traps this parser avoids:
#   * `cached n_tokens = N` is a PROGRESS COUNTER during prefill, not a cache-hit
#     figure. Reuse is (requested - actually_prefilled), computed per task.
#   * the `srv update:` block is the only place the prompt-cache footprint
#     appears, and it is HOST RAM, not VRAM.
function Get-LlamaStats {
    $log = Get-LlamaLog
    if (-not (Test-Path $log)) { return $null }

    $py = @'
import re, os, io, json
p = os.path.join(os.environ["LOCALAPPDATA"], "Ollama", "server.log")
L = io.open(p, encoding="utf-8", errors="replace").read().splitlines()
starts = [i for i, l in enumerate(L) if "starting llama-server" in l]
seg = L[starts[-1]:] if starts else L

# per-task cache reuse
tasks = []; cur = None
for l in seg:
    m = re.search(r"new prompt, n_ctx_slot = (\d+), n_keep = \d+, task\.n_tokens = (\d+)", l)
    if m:
        cur = (int(m.group(1)), int(m.group(2))); continue
    m = re.search(r"prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens", l)
    if m and cur:
        tasks.append({"ctx": cur[0], "requested": cur[1],
                      "prefilled": int(m.group(2)), "ms": float(m.group(1))})
        cur = None

prefill_tok = sum(t["prefilled"] for t in tasks)
prefill_ms  = sum(t["ms"] for t in tasks)
req_tok     = sum(t["requested"] for t in tasks)
zero_reuse  = sum(1 for t in tasks if t["prefilled"] >= t["requested"] - 2)

# decode
gen_tok = 0; gen_ms = 0.0
for l in seg:
    m = re.search(r"^\s*eval time =\s+([\d.]+) ms /\s+(\d+) tokens", l)
    if m:
        gen_ms += float(m.group(1)); gen_tok += int(m.group(2))

# prompt cache footprint (host RAM)
cache_mib = None; cache_limits = None; cache_n = None
for l in seg:
    m = re.search(r"cache state:\s+(\d+) prompts,\s+([\d.]+) MiB \(limits:\s+([\d.]+) MiB", l)
    if m:
        cache_n = int(m.group(1)); cache_mib = float(m.group(2)); cache_limits = float(m.group(3))

# model load / eviction churn - all time, because churn is the symptom
loads = len(starts)
evict = sum(1 for l in L if "predicted to exceed available memory, evicting" in l)
reproc = sum(1 for l in L if "forcing full prompt re-processing due to lack of cache data" in l)
swa = sum(1 for l in L if "KV cache shifting is not supported" in l)

print(json.dumps({
    "tasks": len(tasks),
    "prefill_tokens": prefill_tok,
    "prefill_seconds": round(prefill_ms / 1000, 1),
    "prefill_tok_s": round(prefill_tok / (prefill_ms / 1000), 0) if prefill_ms else None,
    "requested_tokens": req_tok,
    "cache_reuse_pct": round(100.0 * (req_tok - prefill_tok) / req_tok, 1) if req_tok else None,
    "zero_reuse_tasks": zero_reuse,
    "decode_tokens": gen_tok,
    "decode_tok_s": round(gen_tok / (gen_ms / 1000), 1) if gen_ms else None,
    "prompt_cache_prompts": cache_n,
    "prompt_cache_mib": cache_mib,
    "prompt_cache_limit_mib": cache_limits,
    "llama_server_starts": loads,
    "evictions": evict,
    "forced_reprocess": reproc,
    "swa_shift_unsupported": swa,
}))
'@
    try {
        $raw = $py | python - 2>$null
        $line = @($raw | Where-Object { $_ -match '^\{' })[-1]
        if (-not $line) { return $null }
        return $line | ConvertFrom-Json
    } catch { return $null }
}

# ── 5. deer-flow's own per-run accounting ────────────────────────────────────
# The 13,049-input-token floor for a 3-message thread is what makes the point
# that the prompt is dominated by bound surface, not by conversation.
function Get-DeerflowRuns {
    $db = 'deploy/client-bundle/data/deer-flow/data/deerflow.db'
    if (-not (Test-Path $db)) { return $null }
    $py = @'
import sqlite3, json
c = sqlite3.connect("file:deerflow.db?mode=ro", uri=True)
try:
    rows = list(c.execute(
        "select model_name, message_count, total_input_tokens, total_output_tokens,"
        " llm_call_count, created_at from runs order by created_at desc limit 10"))
except Exception as e:
    print(json.dumps({"error": str(e)})); raise SystemExit
print(json.dumps([{"model": r[0], "messages": r[1], "input_tokens": r[2],
                   "output_tokens": r[3], "calls": r[4], "at": r[5]} for r in rows]))
'@
    try {
        Push-Location 'deploy/client-bundle/data/deer-flow/data'
        try {
            $raw = $py | python - 2>$null
        } finally { Pop-Location }
        $line = @($raw | Where-Object { $_ -match '^\[' })[-1]
        if (-not $line) { return $null }
        return $line | ConvertFrom-Json
    } catch { return $null }
}

# ── report ───────────────────────────────────────────────────────────────────
$runners = Get-ResidentRunners
$mem     = Get-HostMemory
$stats   = Get-LlamaStats
$tools   = Get-ToolSurface
$runs    = Get-DeerflowRuns

if ($Json) {
    [pscustomobject]@{
        runners = $runners
        host    = $mem
        llama   = $stats
        tools   = $tools
        runs    = $runs
    } | ConvertTo-Json -Depth 6
    exit 0
}

Write-Host '=== deer-flow lane profile ===' -ForegroundColor Cyan
Write-Host ''

Write-Host 'Resident runners' -ForegroundColor White
if ($runners.Count -eq 0) { Write-Host '  (none - next request pays a full load)' -ForegroundColor DarkGray }
foreach ($r in $runners) {
    Write-Host ("  {0,-24} ctx={1,-7} size={2,-7} {3}" -f $r.Name, $r.Context, $r.Size, $r.Gpu)
}
Write-Host ''

Write-Host 'Host memory (the "50 of 64 GB" reading is commit charge, not working set)' -ForegroundColor White
Write-Host ("  RAM total              {0,8} GiB" -f $mem.RamGiB)
Write-Host ("  Commit used            {0,8} GiB" -f $mem.CommitUsedGiB)
Write-Host ("  Commit limit           {0,8} GiB" -f $mem.CommitLimitGiB)
Write-Host ("  Available              {0,8} MiB" -f $mem.AvailableMiB)
Write-Host ("  vmmemWSL private       {0,8} GiB" -f $mem.VmmemWSLGiB)
Write-Host ("  WSL VM ceiling         {0,8} GiB" -f $mem.WslVmCeilingGiB)
if ($mem.VmmemWSLGiB -and $mem.WslVmCeilingGiB) {
    $gap = [math]::Round($mem.VmmemWSLGiB - 9.5, 1)
    if ($gap -gt 2) {
        Write-Host ("  -> the VM holds ~{0} GiB more than the ~9.5 GiB of containers" -f $gap) -ForegroundColor Yellow
        # Measured 2026-10-21: this is NOT reclaimable guest cache. `drop_caches`
        # inside the guest succeeded and left vmmemWSL unchanged, and the guest
        # reported 8.4 GiB used of 30.9 GiB. It is the VM's allocated footprint,
        # which Windows reclaims under pressure (observed 30.32 -> 20.56 GiB).
        Write-Host '     (VM allocated footprint, not guest cache - Windows reclaims it' -ForegroundColor DarkGray
        Write-Host '      under pressure; observed 30.3 -> 20.6 GiB). Pacgate does not' -ForegroundColor DarkGray
        Write-Host '     write .wslconfig - it is machine-wide and governs every distro.' -ForegroundColor DarkGray
        Write-Host '     To bound it at the next maintenance window:' -ForegroundColor DarkGray
        Write-Host '       [wsl2] / memory=24GB / autoMemoryReclaim=gradual' -ForegroundColor DarkGray
        Write-Host '     then `wsl --shutdown` (stops every container) and restart Docker.' -ForegroundColor DarkGray
    }
}
Write-Host ''

if ($tools) {
    Write-Host 'Prompt surface bound into EVERY call' -ForegroundColor White
    Write-Host ("  tools                 {0,8}" -f $tools.count)
    Write-Host ("  schema size           {0,8} chars (~{1} tokens)" -f $tools.chars, $tools.approx_tokens)
    Write-Host ("  tool_search enabled   {0,8}" -f $tools.tool_search_enabled)
    foreach ($t in $tools.largest) {
        Write-Host ("    {0,7}  {1}" -f $t.chars, $t.name) -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($stats) {
    Write-Host 'llama.cpp ground truth (current runner)' -ForegroundColor White
    Write-Host ("  tasks measured        {0,8}" -f $stats.tasks)
    if ($stats.tasks -ge 3) {
        Write-Host ("  prefill throughput    {0,8} tok/s" -f $stats.prefill_tok_s)
        Write-Host ("  decode throughput     {0,8} tok/s" -f $stats.decode_tok_s)
        Write-Host ("  prefix-cache reuse    {0,7} %" -f $stats.cache_reuse_pct)
        Write-Host ("  tasks with zero reuse {0,8}" -f $stats.zero_reuse_tasks)
    } else {
        # A 1-2 task sample is dominated by model load and a cold prefix. Reporting
        # a throughput figure from it would be the same mistake as planning VRAM
        # from a single `ollama ps` row, so it is withheld rather than printed.
        Write-Host '  (too few tasks in this runner for a throughput figure)' -ForegroundColor DarkGray
        Write-Host '   run a workflow turn, then re-run this script' -ForegroundColor DarkGray
    }
    if ($null -ne $stats.prompt_cache_mib) {
        Write-Host ("  prompt cache (HOST)   {0,8} MiB of {1} MiB limit / {2} prompts" -f `
            $stats.prompt_cache_mib, $stats.prompt_cache_limit_mib, $stats.prompt_cache_prompts)
    }
    Write-Host ''
    Write-Host 'Churn (all time - the reliable slow-workflow signal)' -ForegroundColor White
    Write-Host ("  llama-server starts   {0,8}" -f $stats.llama_server_starts)
    Write-Host ("  evictions             {0,8}" -f $stats.evictions)
    Write-Host ("  forced re-processing  {0,8}" -f $stats.forced_reprocess)
    Write-Host ("  SWA shift unsupported {0,8}" -f $stats.swa_shift_unsupported)
    if ($stats.evictions -gt 5) {
        Write-Host '  -> eviction churn is high: check for one weight set under two tag names' -ForegroundColor Yellow
    }
    if ($stats.forced_reprocess -gt 0) {
        Write-Host '  -> llama.cpp says the prompt cache is being invalidated by SWA checkpoints' -ForegroundColor Yellow
    }
    Write-Host ''
}

if ($runs) {
    Write-Host 'Recent deer-flow runs' -ForegroundColor White
    foreach ($r in $runs) {
        $perCall = if ($r.calls -gt 0) { [math]::Round($r.input_tokens / $r.calls, 0) } else { 0 }
        Write-Host ("  {0,-26} msgs={1,-4} in={2,-9} out={3,-7} calls={4,-3} avg_in={5}" -f `
            $r.model, $r.messages, $r.input_tokens, $r.output_tokens, $r.calls, $perCall)
    }
    $small = $runs | Where-Object { $_.messages -le 3 } | Select-Object -First 1
    if ($small -and $small.input_tokens -gt 5000) {
        Write-Host ("  -> a {0}-message thread used {1} input tokens: the floor is bound surface, not history" -f `
            $small.messages, $small.input_tokens) -ForegroundColor Yellow
    }
    Write-Host ''
}

Write-Host 'Interpretation' -ForegroundColor Cyan
Write-Host '  Slow prefill   -> bound tool surface + prefix-cache invalidation'
Write-Host '  9-16 s pauses  -> a model reload; look for the same weights under two tags'
Write-Host '  High commit    -> WSL guest cache, not the containers'
Write-Host '  Low decode     -> memory bandwidth on the card; not fixable in config'
exit 0
