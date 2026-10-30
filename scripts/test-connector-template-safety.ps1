# Guard: the connector render must PRESERVE servers the template does not carry.
#
# WHY THIS EXISTS (measured 2026-10-30 on a fixture)
#
# install.ps1 rendered `deer-flow-extensions-config.template.json` (3 servers)
# straight over `deer-flow-extensions-config.json`. On a fixture whose on-disk
# config carried 6 servers, `yuandian-law` and `pkulaw-law-search` were silently
# removed. The change report compared against a HARDCODED
# $knownServers = @('openviking','pacgate','firecrawl'), so it named only
# `firecrawl`; the other two vanished with no message at all.
#
# The rendered file is gitignored, so this loss never appears in a diff. On a
# machine carrying the 30-connector legal-database set, one installer run loses 27
# of them and legal search stops working with no error.
#
# WHAT IS ASSERTED
#   C1 the render MERGES: it parses the existing config and builds a merged map
#   C2 the change report is derived from the files, not from a hardcoded list
#   C3 preserved connectors are named in the output
#   C4 an unparseable existing config is left untouched rather than clobbered
#   C5 the merge order is deterministic, so a re-run is a no-op (idempotency)
#   C6 the rendered config stays BOM-free UTF-8 (deer-flow's JSON parser rejects a BOM)
#   C7 behavioural: a 6-server config survives a render driven by a 3-server template
#
# C7 is the one that earns the gate. C1-C6 are static and would all stay green if a
# future edit kept the merge but reordered keys, so the behavioural check exists.
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$installer = 'deploy/client-bundle/install.ps1'
$template  = 'deploy/client-bundle/deer-flow-extensions-config.template.json'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== connector render safety ===' -ForegroundColor Cyan
Check 'the installer exists' (Test-Path $installer) $installer
Check 'the template exists' (Test-Path $template) $template
if (-not (Test-Path $installer) -or -not (Test-Path $template)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $installer -Raw

# ── C1 ───────────────────────────────────────────────────────────────────────
Check 'C1 the render parses the existing config' `
      ($src -match '\$old\s*=\s*\$dfExisting\s*\|\s*ConvertFrom-Json')
Check 'C1 the render builds a merged server map' ($src -match '\$mergedServers')

# ── C2 ───────────────────────────────────────────────────────────────────────
# The hardcoded list is the reason two servers vanished without a message.
Check 'C2 the change report is not driven by a hardcoded server list' `
      ($src -notmatch "\`$knownServers\s*=\s*@\(\s*'openviking'")

# ── C3 ───────────────────────────────────────────────────────────────────────
Check 'C3 preserved connectors are reported' ($src -match 'Preserved\s+\$\(\$kept\.Count\)')

# ── C4 ───────────────────────────────────────────────────────────────────────
Check 'C4 an unparseable existing config is left untouched' `
      ($src -match 'is not valid JSON; leaving it untouched')
Check 'C4 the write is skipped when the merge could not run' `
      ($src -match 'elseif \(-not \$mergeOk\)')

# ── C5 ───────────────────────────────────────────────────────────────────────
# ConvertTo-Json preserves hashtable iteration order, which is not stable across
# processes - unsorted keys made every run rewrite the file and mint a backup.
Check 'C5 the merge key sets are sorted' `
      ($src -match '\$kept\s*=\s*@\([^\r\n]*Sort-Object')
Check 'C5 the gained set is sorted' ($src -match '\$gained\s*=\s*@\([^\r\n]*Sort-Object')

# ── C6 ───────────────────────────────────────────────────────────────────────
Check 'C6 the render still writes BOM-free UTF-8' `
      ($src -match 'UTF8Encoding\]::new\(\$false\)')

# ── C7 behavioural ──────────────────────────────────────────────────────────
# Drive the REAL shipped install.ps1 in a temp dir with a 3-server template and a
# 6-server on-disk config, stubbing docker/ollama so it runs without a daemon.
$work = Join-Path $env:TEMP ("connector-gate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Copy-Item $installer $work
    Copy-Item $template $work
    New-Item -ItemType Directory -Path (Join-Path $work 'openviking') -Force | Out-Null
    Copy-Item 'deploy/client-bundle/openviking/ov.conf.template' (Join-Path $work 'openviking')
    '[]' | Set-Content (Join-Path $work 'ollama-models.txt')
    'services: {}' | Set-Content (Join-Path $work 'compose.prod.yaml')
    'OPENVIKING_ROOT_API_KEY=test-key-000000000000' | Set-Content (Join-Path $work '.env')

    $stubDir = Join-Path $work '_stubs'
    New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
    Set-Content -Path (Join-Path $stubDir 'docker.cmd') -Value "@echo off`r`nexit /b 0" -Encoding ASCII
    Set-Content -Path (Join-Path $stubDir 'ollama.cmd') -Value "@echo off`nexit /b 0" -Encoding ASCII

    $sixServers = '{"mcpServers":{"openviking":{"enabled":true},"pacgate":{"enabled":true},' +
                  '"officecli":{"enabled":true},"firecrawl":{"enabled":true},' +
                  '"yuandian-law":{"enabled":true},"pkulaw-law-search":{"enabled":true}}}'
    $rendered = Join-Path $work 'deer-flow-extensions-config.json'
    $sixServers | Set-Content $rendered

    # The stub dir is passed to the child only. Mutating $env:PATH here would
    # shadow the real docker.exe for the rest of the session - a mistake that has
    # already produced a false pass in this repo.
    #
    # The CWD must be $work: install.ps1 opens ".\.env" and
    # ".\deer-flow-extensions-config.template.json" relatively, so running it from
    # the repo root silently skips the whole render block and every assertion here
    # would pass on an installer that did nothing.
    Push-Location $work
    try {
        $out = & pwsh -NoProfile -Command "`$env:PATH = '$stubDir;' + `$env:PATH; & .\install.ps1" 2>&1
    } finally { Pop-Location }
    $text = ($out | Out-String)

    $servers = @()
    try { $servers = @((Get-Content $rendered -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties.Name) } catch { }

    Check 'C7 a 3-server template does not delete servers from a 6-server config' `
          ($servers.Count -eq 6) `
          "got $($servers.Count) server(s): $($servers -join ', ')"
    Check 'C7 every unknown server survives' `
          (($servers -contains 'yuandian-law') -and ($servers -contains 'pkulaw-law-search') -and ($servers -contains 'firecrawl')) `
          "servers after render: $($servers -join ', ')"
    Check 'C7 the preserved connectors are named in the output' `
          ($text -match 'Preserved\s+\d+\s+connector' -and
           $text -match 'yuandian-law' -and
           $text -match 'pkulaw-law-search') `
          'the operator must be told which connectors were kept'

    # Idempotency: a second run must not rewrite. This is what C5 protects.
    $before = (Get-Content $rendered -Raw)
    Push-Location $work
    try {
        $out2 = & pwsh -NoProfile -Command "`$env:PATH = '$stubDir;' + `$env:PATH; & .\install.ps1" 2>&1
    } finally { Pop-Location }
    $after = (Get-Content $rendered -Raw)
    Check 'C7 a second run is a no-op (idempotent merge)' `
          ($before -eq $after) `
          'key order that varies per process makes every run rewrite and mint a backup'
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
