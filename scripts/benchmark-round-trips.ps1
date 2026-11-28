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

    L3 was LISTED in this header from the first version and never implemented, so
    every report showed L0/L1/L2 and read as if the sanitizer lane had been measured.
    Implemented 2026-11-28; it authenticates to pacgate-api with its own bearer token
    (the L1 session is a deer-flow cookie jar and does not authorise the pacgate API).
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
    # Empty = derive from config. The literal that used to live here was the retired
# portal port, so the L0 qm probe measured a deleted service and reported the
# healthy stack as "[FAIL] no-response". See scripts/lib/QmEndpoint.ps1.
[string]$QmUrl = '',
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
. (Join-Path $PSScriptRoot 'lib/QmEndpoint.ps1')
# L3 builds its PDF fixture inside the release ocr-service image (it is the container
# with PIL), so it needs the same release-image helper the fixture-building gates use.
. (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')
$QmUrl = Get-QmEndpoint -RepoRoot $repoRoot -QmUrl $QmUrl

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
    # No '%%' here: Write-Host's -f operator is .NET string formatting, not printf, so
    # '%%' printed literally in the JSON report while the console showed a bare '%'.
    Record $Layer $Name $med ("spread {0}% ({1}-{2} ms){3}" -f $spread, [math]::Round($min, 1), [math]::Round($max, 1), $(if ($note) { "; $note" } else { '' }))
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
Measure-Probe 'L0' 'qm core /readyz' {
    $base = $QmUrl.TrimEnd('/')
    $probe = $null
    foreach ($p in @('/readyz', '/healthz')) {
        try {
            $r = Invoke-WebRequest -Uri "$base$p" -UseBasicParsing -TimeoutSec 15
            $probe = "$p -> $($r.StatusCode)"
            break
        } catch {
            $c = $_.Exception.Response.StatusCode.value__
            # A 401/403 is the service correctly refusing an anonymous request; the
            # round trip still happened, which is what is being timed.
            if ($c -eq 401 -or $c -eq 403) { $probe = "$p -> $c (auth wall, expected)"; break }
        }
    }
    if (-not $probe) { throw "qm core did not answer /readyz or /healthz at $base" }
    @{ Note = $probe }
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

# ── L2: the MCP tool surface, in-network, over streamable HTTP ─────────────────
# READ THIS NUMBER CAREFULLY. Two things it is NOT:
#
#   1. It is NOT a stdio handshake. My first version piped JSON-RPC at
#      `python3 /app/server.py` and counted `"name"` occurrences in the output. That
#      measured nothing: server.py BOOTS AN HTTP SERVER ("Starting pacgate MCP server
#      on :8000"), it does not speak stdio, so the probe counted 0 tools while
#      reporting [ok]. A probe that cannot fail is not a probe.
#   2. It is NOT the tool-call latency. The process is cold each sample, so this is
#      dominated by start-up. Measured decomposition on 0.2.37: docker exec +
#      python3 -c pass = 233 ms, + `import server` = 791 ms, full handshake = ~860 ms.
#      ~70% is import cost (docx-scalpel, mcp, httpx), ~20% is container exec. A
#      long-lived client pays it once.
#
# The handshake below is copied from scripts/test-mcp-tool-surface.ps1, which is the
# gate that actually proves the 29-tool surface: initialize -> mcp-session-id ->
# tools/list, run from INSIDE the network (deer-flow has the client stack) so the
# path under test is the real one.
Write-Host 'L2  pacgate-mcp handshake + tools/list (in-network, cold process)' -ForegroundColor Cyan

$mcpProbe = @'
import json, sys, urllib.request

URL = "http://pacgate-mcp:8000/mcp"
H = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}

def post(body, sid=None):
    h = dict(H)
    if sid:
        h["mcp-session-id"] = sid
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers=h)
    return urllib.request.urlopen(req, timeout=30)

def parse(raw):
    text = raw.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        pass
    out = None
    for line in text.splitlines():
        if line.startswith("data:"):
            chunk = line[5:].strip()
            if chunk:
                try:
                    out = json.loads(chunk)
                except Exception:
                    pass
    return out

try:
    r = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "round-trip-benchmark", "version": "1"}}})
    sid = r.headers.get("mcp-session-id")
    if not sid:
        print("ERROR no session id"); sys.exit(3)
    r.read()
    r2 = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)
    payload = parse(r2.read().decode())
    if not payload or "result" not in payload or "tools" not in payload["result"]:
        print("ERROR no tools array"); sys.exit(3)
    print("TOOLS " + str(len(payload["result"]["tools"])))
except Exception as e:
    print("ERROR " + str(e)[:160]); sys.exit(3)
'@

Measure-Probe 'L2' 'mcp handshake + tools/list (cold)' {
    $raw = ($mcpProbe | docker exec -i deer-flow python - 2>&1 | Out-String)
    $m = [regex]::Match($raw, 'TOOLS\s+(\d+)')
    if (-not $m.Success) {
        throw ("mcp handshake did not complete: " + (($raw -replace '\s+', ' ').Trim()))
    }
    @{ Note = "$($m.Groups[1].Value) tools" }
}
Write-Host ''

# ── L3: the document round trip. The lane this script ADVERTISED but never had. ──
#
# The header listed L3 ("upload -> sanitize -> download") from the first version and no
# probe was ever written, so the report showed L0/L1/L2 and any reader would assume the
# sanitizer lane had been measured. It had not. This measures the real path.
#
# pacgate-api needs its OWN bearer token here: the L1 session is a deer-flow cookie jar
# and does not authorise the pacgate API. Same two sources test-legal-journey.ps1 uses -
# PACGATE_API_EMAIL / PACGATE_API_PASSWORD from the bundle .env.
$l3Token = $null
$envFile = Join-Path $repoRoot 'deploy/client-bundle/.env'
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^PACGATE_API_EMAIL=(.+)$')    { $script:apiEmail = $Matches[1].Trim() }
        if ($line -match '^PACGATE_API_PASSWORD=(.+)$') { $script:apiPassword = $Matches[1].Trim() }
    }
}
if ($script:apiEmail -and $script:apiPassword) {
    $loginBody = @{ email = $script:apiEmail; password = $script:apiPassword } | ConvertTo-Json
    foreach ($lp in @("$NginxUrl/pacgate/api/auth/login", "$NginxUrl/pacgate/auth/login")) {
        try {
            $lr = Invoke-RestMethod -Uri $lp -Method Post -ContentType 'application/json' -Body $loginBody -TimeoutSec 30
            if ($lr.token) { $l3Token = $lr.token; break }
        } catch { }
    }
}

if (-not $l3Token) {
    Write-Host 'L3  document round trip - SKIPPED (no pacgate-api credential in .env)' -ForegroundColor Yellow
} else {
    Write-Host 'L3  document round trip (upload -> sanitize -> download)' -ForegroundColor Cyan
    $l3H = @{ Authorization = "Bearer $l3Token" }
    $l3Matter = $null
    $l3Doc = $null
    try {
        $mkBody = @{ name = "bench-l3-$([guid]::NewGuid().ToString('N').Substring(0,8))" } | ConvertTo-Json
        $mk = Invoke-RestMethod -Uri "$NginxUrl/pacgate/api/matters" -Method Post -Headers $l3H -ContentType 'application/json' -Body $mkBody -TimeoutSec 60
        $l3Matter = $mk.id
    } catch {
        Write-Host '  [skip] could not create a matter for the document lane' -ForegroundColor Yellow
    }

    if ($l3Matter) {
        $script:OcrImage = Get-ReleaseOcrImage
        if (-not $script:OcrImage) {
            Write-Host '  [skip] cannot derive the release ocr-service image for the PDF fixture' -ForegroundColor Yellow
        } else {
            Measure-Probe 'L3' 'document upload -> sanitize -> download' {
                # A born-digital PDF (a .txt would route to OCR instead), built in the OCR
                # image because that is the container with PIL. The generator is written to
                # a FILE and mounted rather than passed as -c: nested quoting of a python
                # one-liner inside a PowerShell here-string is what made the first attempt
                # at this lane unparseable.
                $fxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bench-l3-" + [guid]::NewGuid().ToString('N').Substring(0,8))
                New-Item -ItemType Directory -Path $fxDir -Force | Out-Null
                $gen = Join-Path $fxDir 'gen.py'
                $pdf = Join-Path $fxDir 'bench.pdf'
                $py = 'from PIL import Image, ImageDraw, ImageFont' + "`n" +
                      'img = Image.new("RGB", (900, 300), "white")' + "`n" +
                      'd = ImageDraw.Draw(img)' + "`n" +
                      'f = ImageFont.load_default()' + "`n" +
                      'd.text((16, 100), "11010519491231002X", fill="black", font=f)' + "`n" +
                      'd.text((16, 150), "13812345678", fill="black", font=f)' + "`n" +
                      'img.save("/fix/bench.pdf", "PDF", resolution=100)' + "`n"
                [System.IO.File]::WriteAllText($gen, $py, (New-Object System.Text.UTF8Encoding($false)))

                docker run --rm -v "${fxDir}:/fix" --entrypoint python3 $script:OcrImage /fix/gen.py 2>&1 | Out-Null
                if (-not (Test-Path $pdf)) { throw 'could not build the PDF fixture in the OCR image' }

                $bytes = [System.IO.File]::ReadAllBytes($pdf)
                $bnd = '----bench' + [guid]::NewGuid().ToString('N').Substring(0,10)
                $ms = New-Object System.IO.MemoryStream
                $bw = New-Object System.IO.BinaryWriter($ms)
                $head = '--' + $bnd + "`r`n" + 'Content-Disposition: form-data; name="matter_id"' + "`r`n`r`n" + $l3Matter + "`r`n" +
                        '--' + $bnd + "`r`n" + 'Content-Disposition: form-data; name="file"; filename="bench.pdf"' + "`r`n" +
                        'Content-Type: application/pdf' + "`r`n`r`n"
                $bw.Write([System.Text.Encoding]::ASCII.GetBytes($head))
                $bw.Write($bytes)
                $bw.Write([System.Text.Encoding]::ASCII.GetBytes("`r`n--$bnd--`r`n"))
                $bw.Flush()
                try {
                    $up = Invoke-RestMethod -Uri "$NginxUrl/pacgate/api/documents" -Method Post -Headers $l3H -ContentType "multipart/form-data; boundary=$bnd" -Body $ms.ToArray() -TimeoutSec 120
                    $l3Doc = $up.id
                } finally { Remove-Item $fxDir -Recurse -Force -ErrorAction SilentlyContinue }
                if (-not $l3Doc) { throw 'upload returned no document id' }

                # Sanitize is where the redactor runs; the verdict is the contract.
                $sxUrl = "$NginxUrl/pacgate/api/documents/$l3Doc/sanitize"
                $job = Invoke-RestMethod -Uri $sxUrl -Method Post -Headers $l3H -ContentType 'application/json' -Body '{"data_level":"T3"}' -TimeoutSec 300
                if ($job.verdict -ne 'pass') { throw "sanitize verdict was '$($job.verdict)'" }

                # The download is the egress gate: it must open only after sanitize.
                $dlUrl = "$NginxUrl/pacgate/api/documents/$l3Doc/download"
                $dl = Invoke-WebRequest -Uri $dlUrl -Headers $l3H -UseBasicParsing -TimeoutSec 120
                if ($dl.StatusCode -ne 200) { throw "download returned $($dl.StatusCode)" }
                @{ Note = "redactions=$($job.redaction_count) bytes=$($dl.RawContentLength)" }
            }

            # Clean up, so a benchmark does not accumulate matters on the stack it measures.
            try { Invoke-RestMethod -Uri "$NginxUrl/pacgate/api/documents/$l3Doc" -Method Delete -Headers $l3H -TimeoutSec 60 | Out-Null } catch { }
            try { Invoke-RestMethod -Uri "$NginxUrl/pacgate/api/matters/$l3Matter" -Method Delete -Headers $l3H -TimeoutSec 60 | Out-Null } catch { }
        }
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
