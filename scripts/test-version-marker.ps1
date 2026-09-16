# Verify the /version staleness marker end-to-end against real containers.
#
# Why this exists: the marker is the one artifact whose whole job is to be
# reachable when something else is wrong. "nginx -t passes" does not prove that
# GET /version returns the api's version - it proves the file parses. The
# failure modes worth catching here are all wiring:
#
#   - the location never matches and falls through to the frontend
#   - proxy_pass sends the wrong path (/build-info vs /build-info/)
#   - the upstream name does not resolve on the compose network
#   - the response is cached when it must not be
#
# So this stands up a real network, a stub upstream aliased exactly as
# `pacgate-api`, and the real nginx with the real default.conf, then curls it.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$nginxDir = Join-Path $repoRoot 'deploy/client-bundle/nginx'

$net = 'pacgate-version-test'
$upstreamCtr = 'pacgate-vertest-api'
$nginxCtr = 'pacgate-vertest-nginx'
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Cond, [string]$Label, [string]$Detail = '')
    if ($Cond) {
        Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host ("  [FAIL] {0}" -f $Label) -ForegroundColor Red
        if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor Gray }
        $script:failed++
    }
}

function Cleanup {
    foreach ($c in @($nginxCtr, $upstreamCtr)) {
        & docker rm -f $c 2>&1 | Out-Null
    }
    & docker network rm $net 2>&1 | Out-Null
}

Write-Host '=== /version route verification ===' -ForegroundColor Cyan
Write-Host ''

Cleanup  # in case a previous run died

try {
    # A stub upstream that answers /build-info exactly as pacgate-api does.
    & docker network create $net 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker network create failed" }

    # The stub reports a distinctive revision so we can prove the value came
    # THROUGH nginx rather than being invented by a default or a cached copy.
    $py = @'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/build-info":
            body = json.dumps({"version": "0.1.12", "revision": "TESTREV123"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = ("wrong path: " + self.path).encode()
            self.send_response(404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("0.0.0.0", 8080), H).serve_forever()
'@
    $tmp = Join-Path $env:TEMP 'vertest-stub.py'
    [System.IO.File]::WriteAllText($tmp, $py)

    & docker run -d --name $upstreamCtr --network $net --network-alias pacgate-api `
        -v "${tmp}:/stub.py:ro" python:3.12-alpine python /stub.py 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "failed to start stub upstream" }

    # Wait for the stub to accept connections.
    $ready = $false
    foreach ($i in 1..20) {
        & docker exec $upstreamCtr python -c "import socket;socket.create_connection(('127.0.0.1',8080),1)" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "stub upstream never became ready" }

    # The REAL nginx config, mounted exactly as compose mounts it.
    & docker run -d --name $nginxCtr --network $net -p 18089:80 `
        -v "${nginxDir}:/etc/nginx/conf.d:ro" nginx:1.27-alpine 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "failed to start nginx" }

    $nginxUp = $false
    foreach ($i in 1..20) {
        & docker exec $nginxCtr nginx -t 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $nginxUp = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $nginxUp) { throw "nginx config did not pass inside the container" }

    # Give nginx a moment to bind.
    Start-Sleep -Seconds 2

    # --- the actual assertions -------------------------------------------
    $resp = & docker exec $nginxCtr wget -q -O - http://127.0.0.1/version 2>&1
    $code = $LASTEXITCODE
    $text = ($resp | Out-String).Trim()

    Write-Host ("  raw response: {0}" -f $text) -ForegroundColor Gray
    Write-Host ''

    Assert-True ($code -eq 0) 'GET /version returns 200' "wget exit $code"
    Assert-True ($text -match '"version"\s*:\s*"0\.1\.12"') 'response carries the api version'
    Assert-True ($text -match '"revision"\s*:\s*"TESTREV123"') 'response carries the api revision (proves it came through nginx)'
    Assert-True ($text -notmatch 'wrong path') 'proxy_pass sent the correct path (/build-info, not /build-info/)'

    # Cache header: a staleness check answered from cache is worthless.
    $headers = & docker exec $nginxCtr wget -q -S -O /dev/null http://127.0.0.1/version 2>&1
    $hdr = ($headers | Out-String)
    Assert-True ($hdr -match 'Cache-Control:\s*no-store') 'Cache-Control: no-store is present (add_header always works)'

    # The marker must not shadow the real UI.
    $root = & docker exec $nginxCtr wget -q -S -O /dev/null http://127.0.0.1/ 2>&1
    Assert-True (($root | Out-String) -notmatch '404') '/ is unaffected by the new location'
}
catch {
    Write-Host ("  [FAIL] harness error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failed++
}
finally {
    Cleanup
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'vertest-stub.py') -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== Results ===' -ForegroundColor Cyan
if ($failed -eq 0) {
    Write-Host ("  {0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("  {0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
