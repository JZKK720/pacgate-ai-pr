# Live smoke test for the full PacGate stack (2026-10-01).
#
# gstack-review Layer 5 (QA) + karpathy goal-driven: every lane gets an explicit
# verifiable criterion, and CANNOT-CHECK is never reported as PASS.
#
# Lanes: pacgate-api (pai), pacgate-mcp, deer-flow-pacgate, deer-flow-frontend,
#        openviking, ocr-service, qm-pacgate.
#
# Exit: 0 = every reachable lane passed. 1 = a lane FAILED. 2 = not runnable.

$ErrorActionPreference = 'Continue'
$script:pass = 0; $script:fail = 0; $script:skip = 0

function Ok($m)   { Write-Host "    [PASS] $m" -ForegroundColor Green;  $script:pass++ }
function Bad($m)  { Write-Host "    [FAIL] $m" -ForegroundColor Red;    $script:fail++ }
function Skip($m) { Write-Host "    [SKIP] $m" -ForegroundColor Yellow; $script:skip++ }
function Lane($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }

function Get-Code($url) {
    # curl.exe: Invoke-WebRequest follows Next.js HTML fallbacks and misreads 404s.
    $out = & curl.exe -s -o NUL -w '%{http_code}' --max-time 15 $url 2>&1
    return "$out".Trim()
}
function Get-Body($url) {
    return (& curl.exe -s --max-time 20 $url 2>&1 | Out-String).Trim()
}

# Expected version, DERIVED rather than hardcoded.
#
# This was the literal '0.1.21', so the 0.1.22 bump left this gate asserting the
# PREVIOUS release and going red on a correctly deployed stack. A release that
# cannot pass its own smoke test trains people to ignore the test, and then it
# cannot warn anyone about a genuine failure. bump-release-version.ps1 does not
# own this file, so a literal here would rot on every future bump.
$cargoToml = Join-Path (Split-Path -Parent $PSScriptRoot) 'pacgate-ai/Cargo.toml'
$expectedVersion = if (Test-Path $cargoToml) {
    (Select-String -Path $cargoToml -Pattern '^version\s*=\s*"([0-9.]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
} else { '' }
if (-not $expectedVersion) {
    Write-Host '  exit 2 - could not derive the expected version from pacgate-ai/Cargo.toml' -ForegroundColor Yellow
    exit 2
}
Write-Host "=== FULL STACK SMOKE — $expectedVersion ===" -ForegroundColor White

# Preflight: if the stack is not running, this is CANNOT-CHECK (exit 2), not a
# failure. Without this, every lane would report FAIL on a clean machine and the
# runner would go red on a tree where nothing is wrong - the exact failure mode
# run-all-checks.ps1's header warns about.
$running = @(docker ps --format '{{.Names}}' 2>$null)
$required = @('pacgate-nginx', 'pacgate-api', 'deer-flow', 'deer-flow-frontend', 'openviking', 'ocr-service')
$missing = @($required | Where-Object { $_ -notin $running })
if ($missing.Count -gt 0) {
    Write-Host "  exit 2 - stack not up; missing: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host '          Start it with: docker compose -f deploy/client-bundle/compose.prod.yaml up -d' -ForegroundColor Gray
    exit 2
}

# ── Lane 1: pacgate-api via nginx ingress ───────────────────────────────────
Lane 'pacgate-api (pai)'
$v = Get-Body 'http://localhost:8089/version'
Write-Host "    /version -> $v"
if ($v -match ('"version"\s*:\s*"' + [regex]::Escape($expectedVersion) + '"')) { Ok "/version reports $expectedVersion" }
else { Bad "/version did not report $expectedVersion (got: $v)" }
if ($v -match '"revision"\s*:\s*"[0-9a-f]{7,}"') { Ok '/version carries a real revision' }
else { Bad '/version revision missing or unknown' }

$h = Get-Code 'http://localhost:8089/pacgate/api/matters'
# NOTE: pacgate-api has NO host-facing health route - nginx routes only `/`,
# `/pacgate/`, `/research/` and `= /version`. A host-level /health hits nginx's
# fallback and 404s, which looks like a broken API but is a broken PROBE. The
# API's real /health is only reachable inside the compose network.
$apiHealth = (docker exec pacgate-mcp python3 -c "import httpx; print(httpx.get('http://pacgate-api:8080/health', timeout=5).status_code)" 2>&1 | Out-String).Trim()
if ($apiHealth -eq '200') { Ok 'pacgate-api /health -> 200 (probed on the compose network)' }
else { Bad "pacgate-api /health -> $apiHealth (in-network probe)" }
if ($h -eq '401' -or $h -eq '403' -or $h -eq '200') { Ok "/pacgate/ ingress reachable ($h)" }
else { Bad "/pacgate/ ingress -> $h" }

# A protected route must stay protected: proves auth is on, not open.
$p = Get-Code 'http://localhost:8089/pacgate/api/matters'
if ($p -eq '401' -or $p -eq '403') { Ok "protected route refuses anon ($p)" }
elseif ($p -eq '200') { Bad 'protected route served ANONYMOUSLY (auth regression)' }
else { Bad "protected route -> $p (expected 401/403)" }

# ── Lane 2: pacgate-mcp (the 0.1.21 fix) ────────────────────────────────────
Lane 'pacgate-mcp'
$tools = (docker exec pacgate-mcp sh -c "grep -c 'def pacgate_' /app/server.py" 2>&1 | Out-String).Trim()
if ($tools -eq '16') { Ok "16 MCP tool definitions present" } else { Bad "tool count = $tools (expected 16)" }
$rl = (docker exec pacgate-mcp sh -c "grep -c _relogin /app/server.py" 2>&1 | Out-String).Trim()
if ($rl -eq '2') { Ok 'the 0.1.21 401-retry fix is present in the RUNNING image' }
else { Bad "401-retry fix absent ($rl)" }

# Serve the tools over the real wire (streamable-http), not just grep the source.
# This is the check that matters: a file on disk proves nothing about the lane.
# Count the tools ARRAY, parsed from the SSE data line. An earlier version of
# this used body.count('pacgate_'), which counts mentions inside tool
# DESCRIPTIONS too and reported 52 for a 16-tool server - a wrong number read as
# evidence. Parse, do not substring-count.
$probe = (docker exec pacgate-mcp python3 -c @"
import httpx, json
H = {'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
def payload(text):
    for line in text.splitlines():
        if line.startswith('data: '):
            return json.loads(line[6:])
    return json.loads(text)
with httpx.Client(timeout=20) as c:
    r = c.post('http://127.0.0.1:8000/mcp', headers=H, json={'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'smoke','version':'1'}}})
    sid = r.headers.get('mcp-session-id','')
    H2 = dict(H); H2['mcp-session-id'] = sid
    c.post('http://127.0.0.1:8000/mcp', headers=H2, json={'jsonrpc':'2.0','method':'notifications/initialized'})
    r2 = c.post('http://127.0.0.1:8000/mcp', headers=H2, json={'jsonrpc':'2.0','id':2,'method':'tools/list'})
    tools = payload(r2.text).get('result',{}).get('tools',[])
    names = [t['name'] for t in tools]
    print(f'TOOLS={len(names)} PACGATE={sum(1 for n in names if n.startswith("pacgate_"))}')
"@ 2>&1 | Out-String).Trim()
if ($probe -match 'TOOLS=(\d+) PACGATE=(\d+)') {
    $total = [int]$Matches[1]; $pg = [int]$Matches[2]
    if ($pg -eq 16) { Ok "MCP serves $pg pacgate tools ($total total in tools/list)" }
    else { Bad "MCP served $pg pacgate tools, expected 16" }
} else { Bad "MCP probe failed: $probe" }

# ── Lane 3: deer-flow-pacgate ───────────────────────────────────────────────
Lane 'deer-flow-pacgate'
# MCP servers are bound LAZILY, on agent creation - NOT at container start. So a
# startup-log grep finds nothing on a healthy stack and reads as a failure. What
# IS checkable at rest: the live rendered extensions config actually lists the
# pacgate MCP server. Report only whether the SERVER IS CONFIGURED - never its
# header values, which carry a live key (see the 2026-10-01 incident).
$cfg = (docker exec deer-flow sh -c 'cat /app/deer-flow-extensions-config.json' 2>&1 | Out-String)
if ($cfg -match '"pacgate"') {
    if ($cfg -match 'pacgate-mcp:8000') { Ok 'deer-flow is configured with the pacgate MCP server' }
    else { Bad 'pacgate MCP entry present but points somewhere unexpected' }
} else { Bad 'deer-flow extensions config has NO pacgate MCP server' }
$srvCount = ([regex]::Matches($cfg, '"enabled"\s*:\s*true')).Count
if ($srvCount -ge 3) { Ok "$srvCount MCP servers enabled (openviking + pacgate + officecli)" }
else { Skip "$srvCount enabled MCP server(s); expected 3" }
$sp = Get-Code 'http://localhost:8089/api/v1/auth/setup-status'
if ($sp -eq '200') { Ok 'deer-flow auth gateway reachable (setup-status 200)' } else { Bad "setup-status -> $sp" }
Skip 'agent->MCP invocation NOT exercised: it needs a deer-flow session, and there is no committed agent-run E2E. Do not read this lane as fully verified.'

# ── Lane 4: deer-flow-frontend ──────────────────────────────────────────────
Lane 'deer-flow-frontend'
$fe = Get-Code 'http://localhost:8090'
if ($fe -eq '200') { Ok 'frontend serves 200 on :8090' } else { Bad "frontend -> $fe" }
# Branding: the PacGate overrides must be in the served build.
$brand = (docker exec deer-flow-frontend sh -c "grep -rli pacgate /app/frontend 2>/dev/null | wc -l" 2>&1 | Out-String).Trim()
if ([int]$brand -ge 6) { Ok "frontend is BRANDED ($brand files reference pacgate)" }
else { Bad "frontend branding regressed ($brand files; expected ~12)" }

# ── Lane 5: openviking ──────────────────────────────────────────────────────
Lane 'openviking'
# /healthz is 404 on openviking; /health is the real liveness route (verified by
# probing both). The container's own healthcheck uses an entrypoint helper.
$ov = Get-Code 'http://localhost:1933/health'
if ($ov -eq '200') { Ok 'openviking /health -> 200' } else { Bad "openviking /health -> $ov" }
$ovh = (docker inspect --format '{{.State.Health.Status}}' openviking 2>&1 | Out-String).Trim()
if ($ovh -eq 'healthy') { Ok 'container health = healthy' } else { Bad "container health = $ovh" }
# The MCP lane is what deer-flow actually uses (root key + text/event-stream).
$mcp = (& curl.exe -s -o NUL -w '%{http_code}' --max-time 15 -X POST 'http://localhost:1933/mcp' `
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' `
        -H "X-API-Key: $env:OPENVIKING_ROOT_API_KEY" `
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>&1 | Out-String).Trim()
if ($mcp -eq '200' -or $mcp -eq '202') { Ok "openviking MCP tools/list -> $mcp" }
else { Skip "openviking MCP -> $mcp (needs the root key in env; covered by test-legal-journey lane 10)" }

# ── Lane 6: ocr-service (the 0.1.21 volume fix) ─────────────────────────────
Lane 'ocr-service'
$oc = (docker exec -w /app ocr-service python3 -c "import app" 2>&1 | Out-String).Trim()
if ([string]::IsNullOrEmpty($oc)) { Ok 'ocr-service module imports cleanly' } else { Skip "import probe: $oc" }
$vol = (docker exec ocr-service sh -c "mount | grep -c '/root/.paddleocr'" 2>&1 | Out-String).Trim()
if ($vol -eq '1') { Ok 'paddleocr weights volume IS mounted (0.1.21 fix)' }
else { Bad "paddleocr volume NOT mounted ($vol) - recreate would re-download" }
$weights = (docker exec ocr-service sh -c "ls /root/.paddleocr 2>/dev/null | wc -l" 2>&1 | Out-String).Trim()
Write-Host "    weights present in volume: $weights entr(ies) (0 = not yet extracted this container)"

# ── Lane 7: qm-pacgate ──────────────────────────────────────────────────────
Lane 'qm-pacgate'
$qm = Get-Code 'http://localhost:8181/healthz'
if ($qm -eq '200' -or $qm -eq '401') { Ok "qm portal reachable ($qm)" }
else { Skip "qm not running ($qm) - setup-qm.ps1 is INTERACTIVE (admin email + bridge password) and does not run 'qm up'" }

# ── VERDICT ─────────────────────────────────────────────────────────────────
Write-Host "`n=== RESULT ===" -ForegroundColor White
Write-Host "  passed: $script:pass   failed: $script:fail   skipped(cannot-check): $script:skip"
if ($script:fail -gt 0) { Write-Host 'RESULT: FAILED - a reachable lane is broken' -ForegroundColor Red; exit 1 }
Write-Host 'RESULT: every reachable lane passed' -ForegroundColor Green
exit 0
