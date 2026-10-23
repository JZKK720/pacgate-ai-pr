# Assert the pacgate-mcp TOOL SURFACE is intact, from the consumer's side.
#
# WHY THIS EXISTS (the 2026-10-23 AIPC #2 field report)
#
# One machine lost ALL of its MCP tools and the 47-gate suite stayed green. Their
# own words: "Only a live deploy caught this; the 47-gate suite passed while it
# was broken." The specific trigger there was fork-local, but the COVERAGE GAP it
# exposed is real in this repo:
#
#   test-mcp-401-retry.ps1   -> the retry path, with the SDK stubbed. No server.
#   test-officecli-mcp.ps1   -> officecli's stdio surface, not pacgate's.
#   smoke-full-stack.ps1     -> counts "3 MCP servers enabled". Counting a server
#                               is not testing its tools.
#
# Nothing asserted that pacgate-mcp still ADVERTISES its tools. A tool that
# disappears - a decorator lost in a refactor, an import that silently fails, a
# server that starts but registers nothing - is invisible to every gate above and
# presents to a lawyer as "the assistant cannot do that any more".
#
# WHAT IS ASSERTED
#   1. the server completes the MCP handshake (initialize -> session id);
#   2. tools/list returns the EXACT expected set of pacgate_* names - not a count,
#      because a count passes when one tool is swapped for another;
#   3. every advertised tool carries a description and an input schema, so a tool
#      that exists but cannot be called does not pass.
#
# The expected list is DERIVED from deploy/pacgate-mcp/server.py rather than
# hardcoded, so adding a tool does not require editing this gate - but REMOVING
# one still fails, because the file and the running server must agree. That is the
# property worth having: the source of truth and the deployed surface cannot drift.
#
# Exit 2 means CANNOT CHECK (stack down) and must never be read as a failure.
[CmdletBinding()]
param(
    [string]$Container = 'pacgate-mcp',
    [string]$ServerFile = 'deploy/pacgate-mcp/server.py'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $passed passed, $failed failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== pacgate-mcp tool surface ==='

if (-not (Test-Path $ServerFile)) { CannotCheck "server source not found: $ServerFile" }

# The expected surface, derived from the source. `@mcp.tool` decorates each tool
# and the function name immediately below it is the advertised name.
#
# The decorator pattern is anchored to `@mcp.tool(` deliberately. A looser
# `@mcp\.tool[^\r\n]*` also matches a MUTATED decorator such as
# `@mcp.tool_removed()`, so a mutation test that renames the decorator would still
# parse as a declared tool and the gate would stay green - which is exactly what
# happened when this gate was first mutation-tested. The `\(` is what makes the
# assertion able to fail.
$src = Get-Content $ServerFile -Raw -Encoding UTF8
$expected = @([regex]::Matches($src, '(?m)^@mcp\.tool\([^\r\n]*\r?\n(?:@[^\r\n]*\r?\n)*\s*(?:async\s+)?def\s+(?<name>[a-z_][a-z0-9_]*)') |
    ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)

Check 'the server source declares tools' ($expected.Count -gt 0) "no @mcp.tool functions parsed from $ServerFile"
if ($expected.Count -eq 0) { CannotCheck 'could not parse any tools from the server source' }
Write-Host ("         source declares {0} tool(s)" -f $expected.Count) -ForegroundColor DarkGray

# The container must be running. A stopped server has no surface to assert, and
# silently skipping it is how a gate reports green about something absent.
$running = (docker ps --format '{{.Names}}' 2>$null | Out-String)
if ($LASTEXITCODE -ne 0 -or -not $running) { CannotCheck 'docker is not reachable or no containers are running' }
if ($running -notmatch "(?m)^\s*$([regex]::Escape($Container))\s*$") {
    CannotCheck "container '$Container' is not running"
}

# Drive the real MCP streamable-http protocol from inside the network. Run from
# the deer-flow container because it is the actual consumer and already has a
# Python with the MCP client stack - a host-side probe would need the SDK
# installed and would not prove the in-network path.
$probe = @'
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
    """SSE frames split across multiple data: lines; take the last JSON payload."""
    out = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            chunk = line[5:].strip()
            if not chunk:
                continue
            try:
                out = json.loads(chunk)
            except Exception:
                pass
    return out

try:
    r = post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "capabilities": {},
        "clientInfo": {"name": "tool-surface-gate", "version": "1"}}})
    sid = r.headers.get("mcp-session-id")
    if not sid:
        print("ERROR no session id from initialize"); sys.exit(3)
    r.read()

    r2 = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)
    payload = parse(r2.read().decode())
    if not payload or "result" not in payload or "tools" not in payload["result"]:
        print("ERROR tools/list returned no tools array"); sys.exit(3)

    tools = payload["result"]["tools"]
    print("TOOLS " + json.dumps([t.get("name") for t in tools]))
    missing_desc = [t.get("name") for t in tools if not (t.get("description") or "").strip()]
    missing_schema = [t.get("name") for t in tools if not t.get("inputSchema")]
    print("NO_DESC " + json.dumps(missing_desc))
    print("NO_SCHEMA " + json.dumps(missing_schema))
except Exception as e:
    print("ERROR " + str(e)[:200]); sys.exit(3)
'@

$raw = $probe | docker exec -i deer-flow python - 2>&1
$exit = $LASTEXITCODE
if ($exit -ne 0 -or -not ($raw -match 'TOOLS ')) {
    CannotCheck "the MCP handshake did not complete: $(($raw | Out-String).Trim() -replace '\s+', ' ' | ForEach-Object { $_.Substring(0, [Math]::Min(200, $_.Length)) })"
}

$actual = @()
$m = [regex]::Match(($raw | Out-String), 'TOOLS (?<j>\[.*?\])')
if ($m.Success) { $actual = @($m.Groups['j'].Value | ConvertFrom-Json) }

Check 'the server completes the MCP handshake and lists tools' ($actual.Count -gt 0) 'tools/list returned an empty set - the server started but registered nothing'
Write-Host ("         server advertises {0} tool(s)" -f $actual.Count) -ForegroundColor DarkGray

# The decisive assertion: the SET must match, not the count. A count passes when
# one tool is silently swapped for another, which is exactly the failure mode a
# refactor produces.
$missing = @($expected | Where-Object { $actual -notcontains $_ })
$extra = @($actual | Where-Object { $expected -notcontains $_ })
Check 'every tool the source declares is advertised' ($missing.Count -eq 0) "missing from the running server: $($missing -join ', ') - the source and the deployed surface have drifted"
Check 'the server advertises nothing the source does not declare' ($extra.Count -eq 0) "advertised but not in the source: $($extra -join ', ') - the running image is not built from this source"

# A tool that exists but cannot be called is not a working tool.
$noDesc = @()
$dm = [regex]::Match(($raw | Out-String), 'NO_DESC (?<j>\[.*?\])')
if ($dm.Success) { $noDesc = @($dm.Groups['j'].Value | ConvertFrom-Json) }
Check 'every advertised tool carries a description' ($noDesc.Count -eq 0) "no description: $($noDesc -join ', ') - the model cannot choose a tool it cannot understand"

$noSchema = @()
$sm = [regex]::Match(($raw | Out-String), 'NO_SCHEMA (?<j>\[.*?\])')
if ($sm.Success) { $noSchema = @($sm.Groups['j'].Value | ConvertFrom-Json) }
Check 'every advertised tool carries an input schema' ($noSchema.Count -eq 0) "no inputSchema: $($noSchema -join ', ') - a tool with no schema cannot be called"

Write-Host ''
if ($failed -gt 0) {
    Write-Host "RESULT: $passed passed, $failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: the MCP tool surface matches its source. ($passed passed)" -ForegroundColor Green
exit 0
