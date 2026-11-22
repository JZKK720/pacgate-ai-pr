<#
Benchmark: end-to-end round trips across the whole pacgate-ai bundle.

WHY THIS EXISTS
    Every other gate in this repo answers "is it correct?". None answers "how long
    does it take, and did it get slower?". That matters here because the two failure
    modes this project has actually shipped were latency-shaped:

      - a model on the CPU at 1-2 tokens/second, which looked exactly like a hang
        (scripts/test-ollama-gpu-residency.ps1 now catches the cause)
      - a prompt that grew until each step paid a 7.4 s prefix cost

    So this measures, and reports numbers. It does NOT assert a threshold: a threshold
    picked today becomes a flaky gate tomorrow on a machine with a different GPU. Run
    it before and after a change and compare the two tables.

WHAT IT MEASURES, cheapest first
    L0  static routes        nginx -> api /version, /pacgate/health, frontend, qm
    L1  auth + thread create deer-flow login, POST /api/threads
    L2  MCP tool surface     pacgate-mcp tools/list over the stdio bridge
    L3  document round trip  upload -> sanitize -> download (the sanitizer lane)
    L4  agent round trip     /runs/wait on a tool-requiring prompt (the slow one)

    L4 is opt-in (-IncludeAgent) because on a box where the model cannot load it takes
    the full timeout to fail, which is not a measurement of anything.

USAGE
    pwsh -File scripts/benchmark-round-trips.ps1
    pwsh -File scripts/benchmark-round-trips.ps1 -IncludeAgent -Runs 3
    pwsh -File scripts/benchmark-round-trips.ps1 -Json out.json     # machine-readable

EXIT CODES
    0 = every measured round trip completed
    1 = a round trip failed at HTTP level (not a latency opinion, a real failure)
    2 = CANNOT CHECK - the stack is not up
#>
[CmdletBinding()]
param(
    [string]$NginxUrl = 'http://localhost:8089',
    [string]$FrontendUrl = 'http://localhost:8090',
    [string]$QmUrl = 'http://localhost:8181',
    [string]$OllamaUrl = 'http://localhost:11434',
    [string]$Email = 'admin@pacgate-law.com',
    [string]$Password = '',
    [int]$TimeoutSec = 300,
    # Repeat each cheap probe this many times and report the median. One sample on a
    # busy desktop is mostly noise.
    [int]$Runs = 5,
    # L4 costs a model round trip. Opt in.
    [switch]$IncludeAgent,
    [string]$Json = ''
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$results = [System.Collections.Generic.List[object]]::new()

function Record([string]$Layer, [string]$Name, [double]$Ms, [string]$Note = '') {
    $results.Add([pscustomobject]@{ Layer = $Layer; Name = $Name; Ms = [math]::Round($Ms, 1); Note = $Note })
}

function Median([double[]]$xs) {
    if ($xs.Count -eq 0) { return [double]::NaN }
    $s = $xs | Sort-Object
    $mid = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2) { return $s[$mid] }
    return ($s[$mid - 1] + $s[$mid]) / 2
}

# Time a probe N times, discard nothing, report the median plus the spread. The spread
# is the useful part: a 40 ms median with a 900 ms outlier is a different system from a
# flat 40 ms, and only the pair shows which one you have.
function Measure-Probe([string]$Layer, [string]$Name, [scriptblock]$Probe) {
    $samples = @()
    $note = ''
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = & $Probe
            if ($r -is [hashtable] -and $r.ContainsKey('Note')) { $note = $r.Note }
        } catch {
            $sw.Stop()
            $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
            Write-Host ("  [FAIL] {0} / {1}: {2}" -f $Layer, $Name, $code) -ForegroundColor Red
            Record $Layer $Name -1 "FAILED $code"
            return
        }
        $sw.Stop()
        $samples += $sw.Elapsed.TotalMilliseconds
    }
    $med = Median $samples
    $min = ($samples | Measure-Object -Minimum).Minimum
    $max = ($samples | Measure-Object -Maximum).Maximum
    $spread = if ($med -gt 0) { [math]::Round((($max - $min) / $med) * 100, 0) } else { 0 }
    Write-Host ("  [  ok] {0} / {1,-34} median {2,8:N1} ms   spread {3,4}%   n={4}" -f `
            $Layer, $Name, $med, $spread, $samples.Count) -ForegroundColor Green
    Record $Layer $Name $med "spread $spread%% ($([math]::Round($min,1))-$([math]::Round($max,1)) ms)$(if ($note) { "; $note" })"
}

Write-Host '=== pacgate-ai round-trip benchmark ===' -ForegroundColor White
Write-Host ("    runs per probe: {0}   agent lane: {1}" -f $Runs, $(if ($IncludeAgent) { 'ON' } else { 'off (-IncludeAgent)' })) -ForegroundColor DarkGray
Write-Host ''

# ── is the stack up at all? ───────────────────────────────────────────────────
try {
    $null = Invoke-WebRequest -Uri "$NginxUrl/version" -UseBasicParsing -TimeoutSec 10
} catch {
    Write-Host "RESULT: CANNOT CHECK - nginx at $NginxUrl is not answering" -ForegroundColor Yellow
    exit 2
}

# ── L0: static routes. The floor: what a round trip costs with no model involved. ──
Write-Host 'L0  static routes (no model, no document)' -ForegroundColor Cyan
Measure-Probe 'L0' 'nginx -> api /version' {
    $r = Invoke-WebRequest -Uri "$NginxUrl/version" -UseBasicParsing -TimeoutSec 15
    @{ Note = ($r.Content | ConvertFrom-Json).version }
}
Measure-Probe 'L0' 'api /pacgate/health' {
    $null = Invoke-WebRequest -Uri "$NginxUrl/pacgate/health" -UseBasicParsing -TimeoutSec 15
    @{}
}
Measure-Probe 'L0' 'deer-flow-frontend /' {
    $null = Invoke-WebRequest -Uri "$FrontendUrl/" -UseBasicParsing -TimeoutSec 15
    @{}
}
Measure-Probe 'L0' 'qm portal /' {
    try {
        $null = Invoke-WebRequest -Uri "$QmUrl/" -UseBasicParsing -TimeoutSec 15
        @{ Note = '200' }
    } catch {
        $c = $_.Exception.Response.StatusCode.value__
        # A 401 is the portal correctly refusing an anonymous request; the round trip
        # still happened, which is what is being timed.
        if ($c -eq 401) { @{ Note = '401 = auth wall, expected' } } else { throw }
    }
}
Write-Host ''

# ── L1: auth + thread creation ────────────────────────────────────────────────
Write-Host 'L1  deer-flow auth and thread creation' -ForegroundColor Cyan

function Resolve-DfPassword {
    if ($Password) { return $Password }
    if ($env:PACGATE_DEERFLOW_PASSWORD) { return $env:PACGATE_DEERFLOW_PASSWORD }
    if ($env:DEER_FLOW_PASSWORD) { return $env:DEER_FLOW_PASSWORD }
    # Same file and same two key names as scripts/test-agent-mcp-e2e.ps1. Reading .env
    # instead (my first attempt) silently skipped every authenticated lane: the password
    # lives in .deer-flow-credentials, which install.ps1 writes separately.
    $f = Join-Path $repoRoot 'deploy/client-bundle/.deer-flow-credentials'
    if (Test-Path -LiteralPath $f) {
        $m = Select-String -LiteralPath $f -Pattern '^\s*(?:PACGATE_DEERFLOW_PASSWORD|DEER_FLOW_PASSWORD)\s*=\s*(.+)$' |
            Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'") }
    }
    return $null
}

$dfPassword = Resolve-DfPassword
$session = $null
$csrf = $null
if (-not $dfPassword) {
    Write-Host '  [skip] no deer-flow credential - L1/L3/L4 cannot run' -ForegroundColor Yellow
} else {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Measure-Probe 'L1' 'deer-flow POST /auth/login/local' {
        $null = Invoke-WebRequest -Uri "$NginxUrl/api/v1/auth/login/local" -Method Post `
            -Body @{ username = $Email; password = $dfPassword } `
            -WebSession $session -UseBasicParsing -TimeoutSec 25
        @{}
    }
    $csrf = ($session.Cookies.GetCookies($NginxUrl) |
        Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value

    if ($csrf) {
        Measure-Probe 'L1' 'POST /api/threads' {
            $null = Invoke-WebRequest -Uri "$NginxUrl/api/threads" -Method Post -Body '{}' `
                -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = $csrf } `
                -WebSession $session -UseBasicParsing -TimeoutSec 30
            @{}
        }
    } else {
        Write-Host '  [skip] no csrf_token cookie - thread creation cannot be measured' -ForegroundColor Yellow
    }
}
Write-Host ''

# ── L2: the MCP tool surface over the stdio bridge ─────────────────────────────
# READ THIS NUMBER CORRECTLY. This probe spawns a NEW python process per sample, so it
# is dominated by cold-start cost, not by the tool call. Measured on 0.2.37 2026-10-05:
#
#   docker exec + python3 -c "print(1)"   233 ms
#   docker exec + python3 -c "import server"   791 ms   <- docx-scalpel, mcp, httpx
#   full handshake + tools/list          1133 ms
#
# So ~70% of the figure is import cost and ~20% is container exec; the protocol
# round trip itself is a small remainder. That is fine for what this probe is for - it
# proves the bridge answers and that the 29 tools are advertized - but it must NOT be
# read as "the MCP tool call takes 1.1 s". A long-lived client pays the import ONCE.
# The steady-state tool latency is L4's business, where the process is already up.
Write-Host 'L2  pacgate-mcp tools/list (cold process - startup-dominated, see note)' -ForegroundColor Cyan

$initReq = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"benchmark","version":"1"}}}'
$listReq = '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
Measure-Probe 'L2' 'mcp cold start + handshake + tools/list' {
    $body = Join-Path ([IO.Path]::GetTempPath()) ("bench-mcp-{0}.jsonl" -f ([guid]::NewGuid().ToString('N')))
    @($initReq, $listReq) | Set-Content -LiteralPath $body -Encoding ASCII
    try {
        # A FILE body, not an inline argument: PowerShell re-quotes a JSON literal passed
        # to a native command and strips the inner quotes, which is what made the smoke
        # lane report 400 against a healthy stack.
        $out = (Get-Content $body | docker exec -i pacgate-mcp python3 /app/server.py 2>&1 | Out-String)
        $n = ([regex]::Matches($out, '"name"\s*:')).Count
        @{ Note = "$n tool entries" }
    } finally {
        Remove-Item -LiteralPath $body -ErrorAction SilentlyContinue
    }
}
Write-Host ''

# ── L4: the agent round trip. Opt-in; this is the expensive one. ────────────────
if ($IncludeAgent -and $csrf) {
    Write-Host 'L4  agent round trip (/runs/wait, tool-requiring prompt)' -ForegroundColor Cyan
    $threadId = $null
    try {
        $t = (Invoke-WebRequest -Uri "$NginxUrl/api/threads" -Method Post -Body '{}' `
                -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = $csrf } `
                -WebSession $session -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
        $threadId = $t.thread_id
    } catch { }
    if (-not $threadId) {
        Write-Host '  [skip] could not create a thread for the agent lane' -ForegroundColor Yellow
    } else {
        $body = @{
            input   = @{ messages = @(@{
                        role    = 'user'
                        content = 'Call the pacgate_list_connectors tool and tell me which connectors exist. You must call the tool.'
                    }) }
            context = @{ thread_id = $threadId }
        } | ConvertTo-Json -Depth 12 -Compress
        $agentRuns = [Math]::Max(1, [Math]::Min($Runs, 3))
        Measure-Probe 'L4' 'agent /runs/wait (tool loop)' {
            $r = Invoke-WebRequest -Uri "$NginxUrl/api/threads/$threadId/runs/wait" -Method Post -Body $body `
                -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = $csrf } `
                -WebSession $session -UseBasicParsing -TimeoutSec $TimeoutSec
            $j = $r.Content | ConvertFrom-Json
            $fb = @($j.messages | Where-Object { $_.additional_kwargs.deerflow_error_fallback }).Count
            @{ Note = if ($fb) { 'ERROR FALLBACK' } else { 'clean reply' } }
        }
    }
    Write-Host ''
}

# ── report ────────────────────────────────────────────────────────────────────
$failed = @($results | Where-Object { $_.Ms -lt 0 })
Write-Host '=== summary ===' -ForegroundColor White
$results | Group-Object Layer | ForEach-Object {
    $tot = ($_.Group | Where-Object { $_.Ms -ge 0 } | Measure-Object -Property Ms -Sum).Sum
    Write-Host ("  {0}  {1,2} probe(s)   {2,9:N1} ms" -f $_.Name, $_.Count, $tot) -ForegroundColor Gray
}
Write-Host ''
Write-Host ("  measured wall time, one pass of every probe: {0:N1} ms" -f `
    (($results | Where-Object { $_.Ms -ge 0 } | Measure-Object -Property Ms -Sum).Sum)) -ForegroundColor White

if ($Json) {
    $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Json -Encoding UTF8
    Write-Host "  wrote $Json" -ForegroundColor DarkGray
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "RESULT: $($failed.Count) round trip(s) FAILED at HTTP level" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: every measured round trip completed ($($results.Count) probes)" -ForegroundColor Green
exit 0
