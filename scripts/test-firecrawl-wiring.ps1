# Guard: every Firecrawl surface parses the response it actually receives, and
# the key reaches all three of them from one place.
#
# WHY THIS EXISTS (measured 2026-11-05)
#
# Three clients speak to api.firecrawl.dev from this repo:
#     1. `pacgate-search` (Rust)          -> /api/search, the legal connector
#     2. `pacgate-mcp`  (Python)          -> pacgate_web_search / pacgate_web_scrape
#     3. `firecrawl_qm.py` (sandbox tool) -> the QM agent's firecrawl-qm CLI
#
# The QM tool had been reading the scrape body from the WRONG depth:
#
#     md = result.get("markdown", "")     # top level
#
# The API answers `{"success": true, "data": {"markdown": ..., "metadata": ...}}`,
# so that expression is ALWAYS empty. The tool then printed nothing and exited 0.
# Measured on the shipped image before the fix:
#
#     $ firecrawl-qm scrape https://example.com   ->  (no output)   exit 0
#
# There is no error, no non-zero exit, and no log line. The agent reads the empty
# string as "this page has no content" and reports that to the client. A wrong
# answer that looks like a real one is the worst failure shape this repo has, so
# it gets a gate rather than a note.
#
# The same command had a second defect of the same family: `crawl` printed the
# job-creation ACK (`{"success":true,"id":...}`) and exited. A crawl is
# asynchronous; the id has to be polled. The agent was handed a job ticket where
# it expected a site.
#
# WHAT IS ASSERTED
#   F1 the three clients agree on the API version
#   F2 the QM scrape path reads data.markdown, and an empty body is an error
#   F3 the QM crawl path polls to completion before printing
#   F4 no Firecrawl MCP server is added to the deer-flow extension template
#   F5 FIRECRAWL_API_KEY reaches pacgate-mcp and pacgate-api from .env
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$qmTool = 'deploy/qm-pacgate/sandbox/tools/firecrawl-qm/firecrawl_qm.py'
$mcp    = 'deploy/pacgate-mcp/server.py'
$rust   = 'pacgate-ai/crates/pacgate-search/src/lib.rs'
$tpl    = 'deploy/client-bundle/deer-flow-extensions-config.template.json'
$bundle = 'deploy/client-bundle/compose.bundle.yaml'
$prod   = 'deploy/client-bundle/compose.prod.yaml'

$script:passed = 0
$script:failed = 0
$script:cannot = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function Cannot($n, $why) {
    $script:cannot++; Write-Host "  [CANNOT CHECK] $n - $why" -ForegroundColor Yellow
}

Write-Host '=== firecrawl wiring ===' -ForegroundColor Cyan

foreach ($f in @($qmTool, $mcp, $rust, $tpl, $bundle, $prod)) {
    if (-not (Test-Path $f)) { Cannot 'input files' "$f is missing"; Write-Host 'RESULT: cannot continue' -ForegroundColor Yellow; exit 2 }
}
$qmSrc   = Get-Content $qmTool -Raw
$mcpSrc  = Get-Content $mcp    -Raw
$rustSrc = Get-Content $rust   -Raw
$tplSrc  = Get-Content $tpl    -Raw

# -- F1: one API version across all three clients -----------------------------
# Mixing v1 and v2 is not a style problem. v2 /search answers
# `{"data": {"web": [...]}}` while v1 answers `{"data": [...]}`; a client built
# for one silently parses zero results from the other.
$qmVersion   = @([regex]::Matches($qmSrc,   '/v(\d)/') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$mcpVersion  = @([regex]::Matches($mcpSrc,  'firecrawl\.dev/v(\d)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$rustVersion = @([regex]::Matches($rustSrc, 'firecrawl\.dev/v(\d)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Write-Host ("         versions: qm={0} mcp={1} rust={2}" -f ($qmVersion -join ','), ($mcpVersion -join ','), ($rustVersion -join ',')) -ForegroundColor DarkGray

Check 'F1 the QM tool targets exactly one API version' ($qmVersion.Count -eq 1) `
      ("references more than one version: {0}" -f ($qmVersion -join ', '))
Check 'F1 pacgate-mcp targets exactly one API version' ($mcpVersion.Count -eq 1)
Check 'F1 pacgate-search targets exactly one API version' ($rustVersion.Count -eq 1)
if ($qmVersion.Count -eq 1 -and $mcpVersion.Count -eq 1 -and $rustVersion.Count -eq 1) {
    Check 'F1 all three clients agree on the API version' `
          ($qmVersion[0] -eq $mcpVersion[0] -and $mcpVersion[0] -eq $rustVersion[0]) `
          ("qm=v{0}, mcp=v{1}, rust=v{2} - one client will parse the other's response shape as empty" -f $qmVersion[0], $mcpVersion[0], $rustVersion[0])
}

# -- F2: the scrape body is read from data.markdown ---------------------------
Check 'F2 the QM tool unwraps the data envelope' `
      ($qmSrc -match 'def _payload_data') `
      'scrape must read data.markdown; the top level carries no markdown key'
Check 'F2 the QM scrape path reads data.markdown' `
      ($qmSrc -match 'data\.get\("markdown"\)') `
      'result.get("markdown") is always empty - it printed nothing and exited 0'

# A scrape that yields no markdown must be an ERROR, not a silent empty print:
# an empty body has to reach the caller as a failure.
Check 'F2 an empty scrape body is reported as an error' `
      ($qmSrc -match 'Firecrawl returned no markdown') `
      'printing an empty string with exit 0 is indistinguishable from a real empty page'

# -- F3: crawl polls instead of printing the job ticket ----------------------
Check 'F3 the QM crawl path polls for completion' `
      ($qmSrc -match 'crawl/\{job_id\}') `
      'the crawl start response carries no page content; the id has to be polled'
Check 'F3 the QM crawl path prints page content' `
      ($qmSrc -match 'page\.get\("markdown"\)') `
      'crawl must emit the pages it fetched, not the start acknowledgement'
Check 'F3 the QM crawl path bounds its wait' `
      ($qmSrc -match 'args\.timeout' -and $qmSrc -match 'time\.sleep') `
      'an unbounded poll can hang a sandbox turn forever'

# -- F4: Firecrawl is NOT an MCP server in deer-flow --------------------------
# Measured 2026-11-05: `deerflow/mcp/tools.py:get_mcp_tools()` awaits
# `MultiServerMCPClient.get_tools()`, which asyncio.gathers one load task per
# server WITHOUT return_exceptions, and the whole call is wrapped in
# `except Exception: return []`. One unreachable server therefore removes EVERY
# MCP tool - pacgate, openviking and officecli included - and the run continues
# with no error the user can see. A remote HTTP dependency must not sit on that
# list.
$tplServers = @()
foreach ($m in [regex]::Matches($tplSrc, '"([a-zA-Z0-9_\-]+)"\s*:\s*\{\s*"enabled"')) {
    $tplServers += $m.Groups[1].Value
}
Write-Host ("         template MCP servers: {0}" -f ($tplServers -join ', ')) -ForegroundColor DarkGray
Check 'F4 the extension template was parseable' ($tplServers.Count -ge 2) `
      "found $($tplServers.Count) server(s); the template shape may have changed"
Check 'F4 firecrawl is not a deer-flow MCP server' `
      ($tplServers -notcontains 'firecrawl') `
      'an unreachable firecrawl entry would delete every other MCP tool (asyncio.gather with no return_exceptions)'

# The tools must instead live on pacgate-mcp, which is already a required
# service and therefore cannot be down without the agent being visibly broken.
Check 'F4 pacgate-mcp exposes the web search tool' ($mcpSrc -match 'def pacgate_web_search\(')
Check 'F4 pacgate-mcp exposes the web scrape tool' ($mcpSrc -match 'def pacgate_web_scrape\(')
Check 'F4 both tools are registered on the MCP server' `
      (([regex]::Matches($mcpSrc, '(?m)^@mcp\.tool\(\)\s*\r?\ndef pacgate_web_(search|scrape)\(')).Count -eq 2) `
      'a def without @mcp.tool() is invisible to the agent'

# -- F5: the key reaches every surface that reads it -------------------------
foreach ($f in @($bundle, $prod)) {
    if (-not (Test-Path $f)) { continue }
    $src = Get-Content $f -Raw
    $start = $src.IndexOf('  pacgate-mcp:')
    if ($start -lt 0) { Cannot "F5 pacgate-mcp block in $f" 'service not found'; continue }
    $rest = $src.Substring($start + 14)
    $end = [regex]::Match($rest, '(?m)^  [a-z0-9\-]+:\s*$')
    $block = if ($end.Success) { $rest.Substring(0, $end.Index) } else { $rest }
    Check "F5 pacgate-mcp receives FIRECRAWL_API_KEY in $(Split-Path $f -Leaf)" `
          ($block -match 'FIRECRAWL_API_KEY') `
          'the tools read the var but compose never passes it, so they always report available=false'

    Check "F5 FIRECRAWL_API_KEY is documented in $(Split-Path $f -Leaf)" `
          ($src -match 'FIRECRAWL_API_KEY') `
          'the connector key list is what an operator follows'
}

Write-Host ''
if ($script:cannot -gt 0 -and $script:failed -eq 0) {
    Write-Host "RESULT: $($script:passed) passed, 0 failed, $($script:cannot) cannot check" -ForegroundColor Yellow
    exit 2
}
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
