# Gate: every cross-component LANE actually connects, end to end.
#
# WHY THIS EXISTS (2026-10-18).
#
# This deployment is not one stack. It is at least five, each with its own
# lifecycle, its own .env, and its own health endpoint:
#
#   pacgate-api      metadata + workflows      (compose)
#   pacgate-mcp      MCP tool server           (compose)
#   deer-flow        research agent + memory   (compose)
#   openviking       vector memory + MCP       (compose)
#   qm-pacgate-*     co-working workspace      (separate `qm` lifecycle)
#
# Every component can report `healthy` while the EDGES between them are broken.
# That is not hypothetical - it is how three separate defects survived a 39-gate
# suite:
#
#   1. qm held a pacgate-api password the API rejected (401). qm healthy, api
#      healthy, edge dead.
#   2. qm's OPENVIKING_API_KEY authenticated with nothing (401 on /mcp), because
#      no per-client key is registered in the service. OpenViking /health needs no
#      key, so the obvious health check passed while every ov-* tool failed.
#   3. The qm bridge ran as the deployment admin rather than a least-privilege
#      service account - invisible to any connectivity probe.
#
# The existing suite tests components and public endpoints. Nothing tested the
# EDGES, and the edges are where the product lives: a workflow that cannot reach
# mcp, or a sandbox that cannot reach the API, is a broken product with a green
# dashboard.
#
# WHAT IT CHECKS - one assertion per edge, each independent
#   E1  pacgate-api      reachable + a token can be issued
#   E2  pacgate-mcp      reachable + MCP responds
#   E3  openviking       reachable + /mcp accepts the CLIENT key (not just /health)
#   E4  deer-flow        reachable
#   E5  qm core          reachable
#   E6  qm -> pacgate-api  authenticate FROM INSIDE the qm container
#   E7  qm -> openviking   MCP tools/list FROM INSIDE the qm container
#   E8  workflow library  templates are listed through pacgate-api
#   E9  data plane        pacgate-db answers + the tenant row exists
#   E10 container provenance  which compose file each container came from
#
# E6 and E7 are the important ones and the ones nobody had: they test the edge
# from the CALLER's side, inside its own network namespace, with its own resident
# credentials. A host-side probe cannot prove them, because host and container do
# not share an environment.
#
# E10 is reporting only. This box turned out to run a MIX - pacgate-api and
# openviking from compose.bundle.yaml, everything else from compose.prod.yaml -
# and both files declare the SAME project name, so whichever file runs `up -d`
# silently reconfigures the shared services. Not a failure by itself (the shared
# services are defined identically), but an operator must be able to SEE it.
#
# Exit codes: 0 = every reachable lane connects;  1 = a lane is broken;
#             2 = nothing reachable (stack down - cannot check, not a failure)
#
# Usage:  pwsh -File scripts/test-lane-connectivity.ps1
#         pwsh -File scripts/test-lane-connectivity.ps1 -Verbose-Edges

[CmdletBinding()]
param(
    [string]$PacgateApi = 'http://localhost:8089/pacgate',
    [string]$OpenViking = 'http://localhost:1933',
    [string]$DeerFlow   = 'http://localhost:3000',
    [string]$QmCore     = 'http://localhost:8180',
    [switch]$VerboseEdges
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$script:failures = 0
$script:passed   = 0
$script:unreachable = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Info([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor Yellow; $script:unreachable++ }

# Run a native command and return its combined stdout+stderr as a string.
#
# WHY THIS EXISTS (found 2026-10-20). A bare `docker exec ... 2>&1` is NOT safe
# under Windows PowerShell 5.1: the native stderr write becomes a
# NativeCommandError terminating error, so the assignment throws instead of
# capturing. `run-all-checks.ps1` deliberately falls back to `powershell` (5.1)
# when `pwsh` is absent - which is the normal case on a client machine - so this
# gate passed on the dev box and FAILED on a machine without PowerShell 7.
#
# Measured: `powershell -File scripts/test-lane-connectivity.ps1` died at E6 with
# `docker : [eval]:1 ... NativeCommandError`, exit 1, while the same script under
# pwsh reported 11 passed. The E6/E7 assertions - the whole reason this gate
# exists - therefore never ran on a 5.1 host.
function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script 2>&1 | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

# Run a Node snippet INSIDE a container by piping the SCRIPT BODY on stdin.
#
# WHY NOT `docker exec ... sh -c "<script>"` (found 2026-10-20)
#   That form depends on the host shell handing the quoting through untouched.
#   Windows PowerShell 5.1 mangles the nested quotes, so `sh` received broken
#   syntax and printed `sh: syntax error`, which the gate then classified as
#   "the container could not reach pacgate-api (network/DNS)" - a FALSE failure
#   pointing at the network when the real problem was the host shell.
#   Measured: under `powershell` (5.1) E6 and E7 both reported network failures,
#   while under `pwsh` the same script reported 11 passed. Since run-all-checks
#   deliberately falls back to 5.1 on machines without PowerShell 7, the two
#   most important assertions in this gate were unusable there.
#
# Piping to `docker exec -i <c> node` removes shell quoting from the path
# entirely: node reads the program from stdin. Verified 200 under 5.1 with the
# real 542-character E6 body.
function Invoke-NodeInContainer {
    param(
        [Parameter(Mandatory = $true)][string]$Container,
        [Parameter(Mandatory = $true)][string]$Command
    )
    # The caller passes `node -e "<body>"`; strip the wrapper and feed the body.
    $body = $Command
    if ($body -match '^node\s+-e\s+"(.*)"\s*$') { $body = $Matches[1] }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return ($body | & docker exec -i $Container node 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-Http([string]$url, [hashtable]$headers = @{}, [int]$timeout = 12) {
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec $timeout -UseBasicParsing
        return @{ Ok = $true; Status = $r.StatusCode; Body = $r.Content }
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return @{ Ok = $false; Status = $code; Body = $_.Exception.Message }
    }
}

function Read-EnvFile([string]$path) {
    $m = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $m }
    foreach ($l in [System.IO.File]::ReadAllLines($path)) {
        if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $m[$Matches[1]] = $Matches[2] }
    }
    return $m
}

Write-Host '=== every cross-component lane connects end to end ==='

$pacEnv = Read-EnvFile (Join-Path $repoRoot 'deploy/client-bundle/.env')
$qmEnv  = Read-EnvFile (Join-Path $repoRoot 'deploy/client-bundle/qm-pacgate/.env')
$email  = if ($pacEnv.ContainsKey('PACGATE_API_EMAIL')) { $pacEnv['PACGATE_API_EMAIL'] } else { '' }
$apiPw  = if ($pacEnv.ContainsKey('PACGATE_API_PASSWORD')) { $pacEnv['PACGATE_API_PASSWORD'] } else { '' }
$ovKey  = if ($pacEnv.ContainsKey('OPENVIKING_API_KEY')) { $pacEnv['OPENVIKING_API_KEY'] } else { '' }

# ---------------------------------------------------------------------------
# E1. pacgate-api - reachable and can issue a token.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E1  pacgate-api' -ForegroundColor Cyan
$apiUp = $false
foreach ($p in @("$PacgateApi/healthz", "$PacgateApi/health", "$PacgateApi/")) {
    $r = Get-Http $p
    if ($r.Ok) { $apiUp = $true; break }
}
if (-not $apiUp) {
    Write-Skip "not reachable at $PacgateApi - start the stack to check"
} else {
    Write-Pass "reachable ($PacgateApi)"
    if ($email -and $apiPw) {
        $body = @{ email = $email; password = $apiPw } | ConvertTo-Json -Compress
        try {
            $login = Invoke-RestMethod -Uri "$PacgateApi/api/auth/login" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20
            if ($login.token) { Write-Pass "issued a token for $email (the .env credential is live)" }
            else { Write-Fail "login returned no token" }
            $script:apiToken = $login.token
        } catch {
            Write-Fail "login FAILED for $email ($($_.Exception.Response.StatusCode.value__)) - .env credential is not accepted"
        }
    } else {
        Write-Skip 'PACGATE_API_EMAIL/PASSWORD not in .env - cannot test auth'
    }
}

# ---------------------------------------------------------------------------
# E2. pacgate-mcp.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E2  pacgate-mcp' -ForegroundColor Cyan
$mcpUp = $false
foreach ($port in @(8090, 8091, 8088)) {
    foreach ($path in @('/', '/health')) {
        $r = Get-Http ("http://localhost:$port$path")
        if ($r.Ok) { Write-Pass "reachable on port $port$path (HTTP $($r.Status))"; $mcpUp = $true; break }
    }
    if ($mcpUp) { break }
}
if (-not $mcpUp) { Write-Skip 'no pacgate-mcp port answered (/health not published, or not running)' }

# ---------------------------------------------------------------------------
# E3. openviking - the CLIENT key must work on /mcp, not just /health.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E3  openviking (client key on /mcp, not /health)' -ForegroundColor Cyan
$ovUp = $false
$r = Get-Http "$OpenViking/health"
if ($r.Ok) { $ovUp = $true; Write-Pass "reachable ($OpenViking/health)" }
if (-not $ovUp) {
    Write-Skip "not reachable at $OpenViking"
} elseif (-not $ovKey) {
    Write-Skip 'OPENVIKING_API_KEY not set in .env - cannot test /mcp'
} else {
    $mcpBody = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    try {
        $resp = Invoke-WebRequest -Uri "$OpenViking/mcp" -Method Post -Body $mcpBody -ContentType 'application/json' `
            -Headers @{ 'Accept' = 'application/json, text/event-stream'; 'X-API-Key' = $ovKey } -TimeoutSec 15 -UseBasicParsing
        Write-Pass "/mcp accepted the client key (HTTP $($resp.StatusCode))"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Fail "/mcp REJECTED the client key (HTTP $code) - every ov-* consumer will fail at call time"
    }
}

# ---------------------------------------------------------------------------
# E4 / E5. deer-flow and qm core - reachable.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E4  deer-flow' -ForegroundColor Cyan
$dfUp = $false
foreach ($p in @("$DeerFlow/healthz", "$DeerFlow/", 'http://localhost:8088/healthz', 'http://localhost:8088/')) {
    $r = Get-Http $p
    if ($r.Ok) { Write-Pass "reachable ($p)"; $dfUp = $true; break }
}
if (-not $dfUp) { Write-Skip "not reachable at $DeerFlow" }

Write-Host ''
Write-Host 'E5  qm core' -ForegroundColor Cyan
$qmUp = $false
foreach ($p in @("$QmCore/healthz", "$QmCore/health")) {
    $r = Get-Http $p
    if ($r.Ok) { Write-Pass "reachable ($p)"; $qmUp = $true; break }
}
if (-not $qmUp) { Write-Skip "not reachable at $QmCore" }

# ---------------------------------------------------------------------------
# E6. qm -> pacgate-api, from INSIDE the qm container, with its own credentials.
#
# This is the edge that was dead. A host-side login proves the host's .env; it
# proves nothing about what qm's container actually holds.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E6  qm -> pacgate-api (from inside qm-pacgate-core)' -ForegroundColor Cyan
$running = @(docker ps --filter 'name=qm-pacgate-core' --format '{{.Names}}' 2>$null)
if ($running.Count -eq 0) {
    Write-Skip 'qm-pacgate-core is not running'
} else {
    $js = 'node -e "const h=require(''http'');const b=JSON.stringify({email:process.env.FLY_RESIDENT_ENV_PACGATE_API_EMAIL,password:process.env.FLY_RESIDENT_ENV_PACGATE_API_PASSWORD});const u=new URL(process.env.FLY_RESIDENT_ENV_PACGATE_API_URL+''/api/auth/login'');const q=h.request({hostname:u.hostname,port:u.port,path:u.pathname,method:''POST'',headers:{''Content-Type'':''application/json'',''Content-Length'':Buffer.byteLength(b)}},r=>{let d='''';r.on(''data'',c=>d+=c);r.on(''end'',()=>{console.log(r.statusCode)});});q.on(''error'',e=>console.log(''ERR''));q.write(b);q.end();"'
    $out = Invoke-NodeInContainer -Container 'qm-pacgate-core' -Command $js
    if ($out -match '^200') { Write-Pass 'authenticated from inside the container (HTTP 200)' }
    elseif ($out -match '^401') { Write-Fail 'the container''s resident credential was REJECTED (401) - every pacgate tool call from a sandbox fails' }
    elseif ($out -match 'ERR') { Write-Fail 'the container could not reach pacgate-api (network/DNS)' }
    else { Write-Skip "inconclusive: $out" }
}

# ---------------------------------------------------------------------------
# E7. qm -> openviking /mcp, from inside the qm container.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E7  qm -> openviking /mcp (from inside qm-pacgate-core)' -ForegroundColor Cyan
if ($running.Count -eq 0) {
    Write-Skip 'qm-pacgate-core is not running'
} else {
    # Status code only - deliberately no SSE/body parsing. An earlier version tried
    # to extract the tool count and the quote nesting silently produced invalid JS,
    # which the gate then reported as "could not reach" - a FALSE failure. Proving
    # the EDGE (does the credential authenticate) needs only the status code; the
    # tool inventory is covered by E3 from the host.
    $js2 = 'node -e "const h=require(''http'');const b=JSON.stringify({jsonrpc:''2.0'',id:1,method:''tools/list'',params:{}});const u=new URL(process.env.FLY_RESIDENT_ENV_OPENVIKING_URL+''/mcp'');const q=h.request({hostname:u.hostname,port:u.port,path:u.pathname,method:''POST'',headers:{''Content-Type'':''application/json'',''Accept'':''application/json, text/event-stream'',''Content-Length'':Buffer.byteLength(b),''X-API-Key'':process.env.FLY_RESIDENT_ENV_OPENVIKING_API_KEY}},r=>{r.resume();r.on(''end'',()=>{console.log(r.statusCode);});});q.on(''error'',e=>console.log(''ERR''));q.write(b);q.end();"'
    $out2 = Invoke-NodeInContainer -Container 'qm-pacgate-core' -Command $js2
    if ($out2 -match '^200') { Write-Pass 'OpenViking /mcp accepted the container''s client key (HTTP 200)' }
    elseif ($out2 -match '^401') { Write-Fail 'OpenViking /mcp REJECTED the container''s client key (401) - every ov-* sandbox tool fails' }
    elseif ($out2 -match '^403') { Write-Fail 'OpenViking /mcp rejected the account scope (403)' }
    elseif ($out2 -match 'ERR') { Write-Fail 'the container could not reach OpenViking (network/DNS)' }
    else { Write-Skip "inconclusive: $(($out2 -split "`n")[0])" }
}

# ---------------------------------------------------------------------------
# E8. workflow library - templates are actually served.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E8  workflow library (through pacgate-api)' -ForegroundColor Cyan
if (-not $apiUp) {
    Write-Skip 'pacgate-api not reachable'
} elseif (-not $script:apiToken) {
    Write-Skip 'no token - cannot enumerate workflows'
} else {
    $hdr = @{ Authorization = "Bearer $($script:apiToken)" }
    $got = $false
    foreach ($p in @("$PacgateApi/api/workflows", "$PacgateApi/api/workflows/templates")) {
        try {
            $wf = Invoke-RestMethod -Uri $p -Headers $hdr -TimeoutSec 20
            $list = if ($wf -is [array]) { $wf } elseif ($wf.items) { $wf.items } else { @($wf) }
            if ($list.Count -gt 0) { Write-Pass "$p listed $($list.Count) workflow(s)"; $got = $true; break }
        } catch { }
    }
    if (-not $got) { Write-Fail 'no workflow templates were listed - the workflow lane is empty or erroring' }
}

# ---------------------------------------------------------------------------
# E9. data plane.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E9  data plane (pacgate-db)' -ForegroundColor Cyan
$dbOut = Invoke-NativeCapture { docker exec pacgate-db psql -U pacgate -d pacgate -tAc "select count(*) from tenants" }
if ($dbOut -match '^\d+$') {
    if ([int]$dbOut -gt 0) { Write-Pass "pacgate-db answers; $dbOut tenant row(s)" }
    else { Write-Fail 'pacgate-db answers but has ZERO tenants - seeding never ran' }
} else {
    Write-Fail "pacgate-db did not answer: $(($dbOut -split "`n")[0])"
}

# ---------------------------------------------------------------------------
# E10. Container provenance - which compose file each container came from.
# Reporting only; a mix is not a failure, but it must be visible.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'E10 container provenance (report only)' -ForegroundColor Cyan
$mix = @{}
$provenanceUnavailable = 0
foreach ($c in @('pacgate-api', 'openviking', 'deer-flow', 'deer-flow-frontend', 'pacgate-mcp', 'pacgate-db', 'pacgate-nginx')) {
    # Read the label with `docker inspect` and pick the field in PowerShell,
    # rather than passing a Go template that contains nested double quotes.
    #
    # WHY (found 2026-10-21): `--format '{{index .Config.Labels "com...."}}'`
    # works under pwsh and SILENTLY FAILS under Windows PowerShell 5.1, which
    # strips the inner quotes so docker receives `com.docker...` unquoted and
    # fails with `function "com" not defined`.
    #
    # The first fix only suppressed that message, which turned a loud failure into
    # a quiet one: E10 printed nothing at all under 5.1 while printing the
    # provenance line under pwsh. Because E10 is report-only, no assertion could
    # catch the loss - the operator simply never saw which compose files were in
    # play, which is the entire reason this section exists (a mix of
    # compose.bundle.yaml and compose.prod.yaml sharing one project name means
    # whichever runs `up -d` reconfigures the shared services).
    #
    # Getting the value is better than tolerating its absence: this form has no
    # quoting for a shell to mangle, and it reports honestly when unreadable.
    $cfg = ''
    $raw = Invoke-NativeCapture { docker inspect $c }
    if ($raw -and $raw -notmatch 'Error:|NativeCommandError') {
        try {
            $obj = $raw | ConvertFrom-Json
            $labels = $obj[0].Config.Labels
            if ($labels) {
                $cfg = [string]$labels.'com.docker.compose.project.config_files'
            }
        } catch { }
    }
    if (-not $cfg) { $provenanceUnavailable++; continue }
    # config_files can be a comma-separated list when several -f were used.
    $leaf = (($cfg -split ',')[0].Trim() | Split-Path -Leaf)
    if (-not $mix.ContainsKey($leaf)) { $mix[$leaf] = @() }
    $mix[$leaf] += $c
}
foreach ($k in ($mix.Keys | Sort-Object)) {
    Write-Info "$k : $($mix[$k] -join ', ')"
}
if ($provenanceUnavailable -gt 0) {
    # Report the gap instead of printing nothing. Silence here previously made a
    # 5.1 run indistinguishable from "provenance is fine".
    Write-Info "$provenanceUnavailable container(s): provenance label unreadable (not a failure)"
}
if ($mix.Keys.Count -gt 1) {
    Write-Host '        NOTE: more than one compose file is in play. Both compose.bundle.yaml and' -ForegroundColor DarkGray
    Write-Host '        compose.prod.yaml declare `name: pacgate-ai-bundle`, i.e. the SAME project,' -ForegroundColor DarkGray
    Write-Host '        so whichever file runs `up -d` reconfigures the shared services. Compare' -ForegroundColor DarkGray
    Write-Host '        them before trusting a recreate.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAIL: $($script:failures) lane(s) broken. $($script:passed) passed, $($script:unreachable) could not be checked." -ForegroundColor Red
    Write-Host '  A broken EDGE is invisible to per-component health checks - that is how these' -ForegroundColor DarkGray
    Write-Host '  defects survive a green dashboard. Fix the caller''s resident credential, then' -ForegroundColor DarkGray
    Write-Host '  RECREATE (not restart) the container so it picks the change up.' -ForegroundColor DarkGray
    exit 1
}
if ($script:passed -eq 0) {
    Write-Host "CANNOT CHECK: no lane was reachable ($($script:unreachable) skipped)." -ForegroundColor Yellow
    exit 2
}
Write-Host "RESULT: every reachable lane connects. ($($script:passed) passed, $($script:unreachable) not reachable)" -ForegroundColor Green
exit 0
