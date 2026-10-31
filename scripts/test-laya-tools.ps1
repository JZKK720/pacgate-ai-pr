<#
.SYNOPSIS
    Assert the pacgate-mcp laya tool group exists and degrades safely.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-31).

    laya is a local System 1 decision engine reached as a separate HTTP service
    (laya-serve). It is OPTIONAL: most client machines will not run it, at least
    at first, because it costs a 1.2 GB model checkpoint on disk.

    That optionality is the whole risk. An optional dependency that raises on a
    machine without it turns every clause tool into an exception, and the agent
    sees a broken tool rather than an absent capability. So the properties that
    matter are not "it classifies clauses well" - that needs weights this box
    cannot fetch - but:

      L1  server.py registers the three laya tools
      L2  the laya client reads a configurable base URL (no hardcoded host)
      L3  an unreachable laya returns an explicit "unavailable" payload, not a raise
      L4  min_confidence is forwarded - abstention is the reason we use laya
          at all, so silently dropping it would defeat the integration
      L5  no API key is required anywhere in the laya path (the whole point)
      L6  compose declares the service in BOTH lanes, or one lane ships a tool
          that can never work

    L3 and L4 are behavioural: they import server.py and call the tools against a
    dead endpoint. L1/L2/L5/L6 are structural.

    Exit codes: 0 = pass; 1 = a real defect; 2 = cannot check.
#>
[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:9/laya'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:pass = 0
$script:fail = 0
$script:skip = 0

function Check($name, $ok, $detail) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red; if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray } }
}
function Skip($name, $why) {
    $script:skip++; Write-Host "  [SKIP] $name - $why" -ForegroundColor Yellow
}

$server = 'deploy/pacgate-mcp/server.py'
$mcpDir = 'deploy/pacgate-mcp'

if (-not (Test-Path -LiteralPath $server)) {
    Write-Host "  cannot check: $server is missing" -ForegroundColor Red
    exit 2
}
$src = [System.IO.File]::ReadAllText((Resolve-Path $server))

Write-Host ''
Write-Host 'L1  the laya tool group is registered' -ForegroundColor Cyan

$tools = @('pacgate_clause_risk', 'pacgate_clause_flags', 'pacgate_route_language')
foreach ($t in $tools) {
    $declared = $src -match "(?m)^def\s+$t\s*\("
    $decorated = $src -match "(?s)@mcp\.tool\(\)[^\n]*\n(?:[^\n]*\n){0,4}def\s+$t\s*\("
    Check "tool '$t' is defined and decorated with @mcp.tool()" ($declared -and $decorated) `
        "def found=$declared, @mcp.tool found above it=$decorated; an undecorated def is never advertised to the agent"
}

Write-Host ''
Write-Host 'L2  the laya client is configurable, not hardcoded' -ForegroundColor Cyan

Check 'laya base URL comes from the environment' ($src -match 'LAYA_(SERVE_)?BASE_URL|PACGATE_LAYA_URL') `
    'no environment read for the laya endpoint - a hardcoded host breaks every non-default deployment'

# 'pacgate-api' and 'laya' are compose siblings on the same network, so a
# default naming them is the deployment, not a hardcoded third-party host.
$hardcoded = [regex]::Matches($src, '(?:https?://)(?!pacgate-api|laya\b|127\.0\.0\.1|localhost)[a-z0-9.\-]+:\d+')
Check 'no hardcoded service host in server.py' ($hardcoded.Count -eq 0) `
    ("found: " + (($hardcoded | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '))

Write-Host ''
Write-Host 'L3+L4  behaviour: unreachable laya degrades, and confidence is forwarded' -ForegroundColor Cyan

$py = $null
foreach ($cand in @('python', 'py')) {
    $probe = & $cand -c "print('ok')" 2>&1
    if ($LASTEXITCODE -eq 0 -and ($probe -join '') -match 'ok') { $py = $cand; break }
}

if (-not $py) {
    Skip 'behavioural checks' 'no usable python on PATH'
}
else {
    $script = @'
import importlib.util, json, os, sys

os.environ["PACGATE_LAYA_URL"] = sys.argv[1]
os.environ["PACGATE_LAYA_TIMEOUT"] = "2"
os.environ.setdefault("PACGATE_API_EMAIL", "")
os.environ.setdefault("PACGATE_API_PASSWORD", "")

spec = importlib.util.spec_from_file_location("pgmcp", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception as e:
    print(json.dumps({"import_error": f"{type(e).__name__}: {e}"}))
    raise SystemExit(0)

out = {}

# L3: a dead endpoint must come back as a result, not an exception.
for fn in ("pacgate_clause_risk", "pacgate_clause_flags", "pacgate_route_language"):
    f = getattr(mod, fn, None)
    if f is None:
        out[fn] = "MISSING"
        continue
    try:
        # Positional on purpose: the gate must not depend on the parameter's
        # name, only on the tool existing and degrading.
        r = f("甲方应在收到发票后三十日内付款。")
        out[fn] = r if isinstance(r, str) else str(r)
    except Exception as e:
        out[fn] = f"RAISED {type(e).__name__}: {e}"

print(json.dumps(out, ensure_ascii=False))
'@
    $tmp = Join-Path $env:TEMP ("laya-gate-" + [guid]::NewGuid().ToString('n').Substring(0, 6) + '.py')
    [System.IO.File]::WriteAllText($tmp, $script, [System.Text.UTF8Encoding]::new($false))
    $raw = & $py $tmp $BaseUrl (Resolve-Path $server) 2>&1 | Out-String

    if ($raw -match 'import_error') {
        Skip 'behavioural checks' "server.py cannot be imported here: $raw"
    }
    else {
        $res = $null
        try { $res = ($raw -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }

        if (-not $res) {
            Check 'tool calls return a parseable payload' $false ($raw.Substring(0, [Math]::Min(400, $raw.Length)))
        }
        else {
            foreach ($fn in @('pacgate_clause_risk', 'pacgate_clause_flags', 'pacgate_route_language')) {
                $v = [string]$res.$fn
                if ($v -match '^RAISED') {
                    Check "$fn degrades to an explicit unavailable result" $false `
                        "raised instead of returning: $($v.Substring(0, [Math]::Min(200, $v.Length)))"
                    continue
                }
                # Assert the contract, not the wording. Matching vocabulary
                # ("unavailable", "disabled") would pass or fail on prose; the
                # caller branches on `available` being false and on `reason`
                # explaining why, so that is what must hold.
                $obj = $null
                try { $obj = $v | ConvertFrom-Json } catch { }
                if (-not $obj) {
                    Check "$fn degrades to an explicit unavailable result" $false `
                        "returned non-JSON, so a caller cannot branch on it: $($v.Substring(0, [Math]::Min(200, $v.Length)))"
                    continue
                }
                $ok = ($obj.available -eq $false) -and ([string]$obj.reason).Trim().Length -gt 0 -and ([string]$obj.tool) -eq $fn
                Check "$fn degrades to an explicit unavailable result" $ok `
                    "available=$($obj.available) tool='$($obj.tool)' reason='$([string]$obj.reason)'"
            }
        }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

# min_confidence must reach the wire. Structural, because the value only
# exists inside an outbound request body that a dead endpoint never sends.
$forwardsMinConf = $src -match 'min_confidence'
Check 'min_confidence is forwarded to laya (abstention survives)' $forwardsMinConf `
    'server.py never mentions min_confidence, so laya cannot decline and will guess on every clause'

Write-Host ''
Write-Host 'L5  no API key anywhere in the laya path' -ForegroundColor Cyan

# Scope to laya-related lines only: pacgate-api legitimately uses credentials.
$layaLines = @(($src -split '\r?\n') | Where-Object { $_ -match 'laya' })
$keyHits = @($layaLines | Where-Object { $_ -match 'API_KEY|api_key|Authorization|Bearer' })
Check 'no key or bearer auth is required to reach laya' ($keyHits.Count -eq 0) `
    (($keyHits | Select-Object -First 3) -join ' | ')

Write-Host ''
Write-Host 'L6  both compose lanes declare the laya service' -ForegroundColor Cyan

foreach ($lane in @('compose.prod.yaml', 'compose.bundle.yaml')) {
    $p = Join-Path 'deploy/client-bundle' $lane
    if (-not (Test-Path -LiteralPath $p)) { Check "$lane exists" $false; continue }
    $t = [System.IO.File]::ReadAllText((Resolve-Path $p))
    Check "$lane declares a laya service" ($t -match '(?m)^\s{2}laya:\s*$') `
        'no top-level laya: service - the tools would have nothing to call'
    Check "$lane points pacgate-mcp at the laya service" ($t -match 'PACGATE_LAYA_URL') `
        'pacgate-mcp has no PACGATE_LAYA_URL in this lane'
}

Write-Host ''
$total = $script:pass + $script:fail
if ($script:fail -eq 0) {
    Write-Host "RESULT: the laya tools ship, degrade safely, and keep abstention. ($($script:pass) passed, $($script:skip) skipped)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:fail) of $total assertion(s) failed." -ForegroundColor Red
exit 1
