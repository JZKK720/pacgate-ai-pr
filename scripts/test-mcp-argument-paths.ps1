# Guard: MCP tool ARGUMENTS must be path-translated, and the rewrite must have
# the thread context it needs to do that.
#
# WHY THIS EXISTS (measured 2026-10-30 on 0.2.7)
#
#   officecli_officecli({"command":"create /mnt/user-data/outputs/x.docx"})
#     -> ToolException: Could not find a part of the path
#
# /mnt/user-data is a VIRTUAL path. Inside the container the real directory is
# {data}/deer-flow/users/<user>/threads/<thread>/user-data/outputs. bash commands
# were rewritten by replace_virtual_paths_in_command and read_file's path by
# replace_virtual_path; MCP ARGUMENTS were passed verbatim.
#
# 2026-11-24: the fix moved off a whole-file fork of deerflow/mcp/tools.py onto
# deer-flow's supported mcpInterceptors extension point, implemented by
# pacgate_deerflow_adapter.virtual_path_interceptor. The fork was a v2.0.0
# snapshot; 2.2.0 added ServerDiscoveryResult and ~600 lines of discovery and
# binding machinery, so the mount made the gateway unimportable.
#
# HOW THE INTERCEPTOR GETS THREAD CONTEXT
# deer-flow injects the ToolRuntime by PARAMETER NAME ("runtime"), not by
# annotation, so an unannotated `runtime: Runtime | None = None` in the tool
# closure is enough - upstream 2.2.0 does exactly that. The interceptor reads
# request.runtime, which deer-flow fills from the same injection path.
#
# WHAT IS ASSERTED
#   A1  the adapter module and its bind-mount copy exist and are byte-identical
#   A2  it implements the MCPToolCallRequest interceptor contract
#   A3  the rewrite is applied to request.args before the handler runs
#   A4  the rewriter is bounded, ignores non-matching values, and never throws
#   A5  both compose lanes mount the adapter file, and the extensions config
#       registers it under mcpInterceptors
#   A6  live: the deployed module imports inside deer-flow
#
# Exit 2 means CANNOT CHECK and must never be read as a failure.
[CmdletBinding()]
param(
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$pkg     = 'pacgate-adapters/python/pacgate_deerflow_adapter/virtual_path_interceptor.py'
$mounted = 'deploy/client-bundle/patches/pacgate-adapter-virtual-path-interceptor.py'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$extensionsConfigs = @('deploy/client-bundle/deer-flow-extensions-config.template.json',
                       'deploy/client-bundle/deer-flow-extensions-config.json')
$mountTarget = '/app/adapters/pacgate_deerflow_adapter/virtual_path_interceptor.py'
$interceptorSpec = 'pacgate_deerflow_adapter.virtual_path_interceptor:build_virtual_path_interceptor'

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== MCP argument path translation ===' -ForegroundColor Cyan

# -- A1 ------------------------------------------------------------------
Check 'A1 the adapter module exists' (Test-Path $pkg) $pkg
Check 'A1 the bind-mounted copy exists' (Test-Path $mounted) $mounted
if (-not (Test-Path $pkg) -or -not (Test-Path $mounted)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $pkg -Raw
Check 'A1 the two copies are byte-identical' `
      ((Get-FileHash $pkg -Algorithm SHA256).Hash -eq (Get-FileHash $mounted -Algorithm SHA256).Hash)

# -- A2 ------------------------------------------------------------------
Check 'A2 exposes a zero-argument builder for mcpInterceptors' `
      ($src -match '(?m)^def build_virtual_path_interceptor\(\s*\)')
Check 'A2 returns an async intercept(request, handler) coroutine' `
      ($src -match '(?m)^\s+async def intercept\(\s*request\s*:\s*MCPToolCallRequest\s*,\s*handler\s*\)')
Check 'A2 reads the runtime off the request (never a module global)' `
      ($src -match 'request\.runtime')
Check 'A2 forwards to the wrapped handler' `
      ($src -match 'return await handler\(')

# -- A3 ------------------------------------------------------------------
$overrideAt = $src.IndexOf('request.override(args=')
$handlerAt  = $src.IndexOf('return await handler(')
Check 'A3 the rewritten args are put on the request before the handler runs' `
      ($overrideAt -ge 0 -and $handlerAt -gt $overrideAt) `
      "overrideAt=$overrideAt handlerAt=$handlerAt"
Check 'A3 a path-free value is returned untouched' `
      ($src -match 'if VIRTUAL_PATH_PREFIX not in value')
Check 'A3 no thread context means no rewrite (no-op, not a crash)' `
      ($src -match 'if not thread_data or not isinstance\(args, dict\)')

# -- A4 ------------------------------------------------------------------
Check 'A4 containers are walked to a bounded depth' ($src -match '_ARG_PATH_MAX_DEPTH')
Check 'A4 an unchanged structure is returned by identity' `
      ($src -match 'return rewritten if changed else args')
Check 'A4 the pure-path case is tried before the embedded-command case' `
      ($src.IndexOf('replace_virtual_path(value, thread_data)') -lt $src.IndexOf('replace_virtual_paths_in_command(value, thread_data)'))

# -- A5 ------------------------------------------------------------------
foreach ($c in $composes) {
    $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
    Check "A5 $c mounts the interceptor at $mountTarget" `
          ($body -match [regex]::Escape("./patches/pacgate-adapter-virtual-path-interceptor.py:$mountTarget"))
    Check "A5 $c no longer mounts the retired whole-file tools.py fork" `
          ($body -notmatch 'deer-flow-mcp-args\.py:/app/backend/packages/harness/deerflow/mcp/tools\.py')
}
foreach ($c in $extensionsConfigs) {
    $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
    Check "A5 $c registers the interceptor" `
          ($body -match [regex]::Escape($interceptorSpec))
}

# -- A6 (live) -----------------------------------------------------------
$running = $false
try {
    $state = docker inspect -f '{{.State.Health.Status}}' $Container 2>$null
    $running = ($state -eq 'healthy')
} catch { $running = $false }

if (-not $running) {
    Write-Host ''
    Write-Host '  [skip] CANNOT CHECK: deer-flow is not running healthy.' -ForegroundColor Yellow
    $colour = if ($script:failed -gt 0) { 'Red' } else { 'Yellow' }
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed (live checks skipped)" -ForegroundColor $colour
    if ($script:failed -gt 0) { exit 1 } else { exit 2 }
}

$mountJson = (docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}|{{.RW}};{{end}}' $Container 2>$null)
$mountRow = @(($mountJson -split ';') | Where-Object { $_ -match [regex]::Escape($mountTarget) }) | Select-Object -First 1
Check 'A6 the mount source is the tracked patch' `
      ($mountRow -and $mountRow -match 'pacgate-adapter-virtual-path-interceptor\.py') `
      "mount row: $mountRow"
Check 'A6 the mount is read-only' `
      ($mountRow -and $mountRow -match '\|False$') `
      ".RW must be False for a :ro mount; got: $mountRow"

$probeDir = Join-Path $env:TEMP ("mcp-argpath-gate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
$probeFile = Join-Path $probeDir 'probe.py'
@'
import asyncio
import json
from langchain_mcp_adapters.interceptors import MCPToolCallRequest

from pacgate_deerflow_adapter.virtual_path_interceptor import build_virtual_path_interceptor

intercept = build_virtual_path_interceptor()
captured = {}

async def handler(req):
    captured['args'] = req.args
    return 'ok'

async def main():
    await intercept(
        MCPToolCallRequest(
            name="t",
            args={"command": "create /mnt/user-data/outputs/x.docx"},
            server_name="s",
            runtime=None,
        ),
        handler,
    )
    print("REWRITE", json.dumps(captured['args'], sort_keys=True))

asyncio.run(main())
'@ | Out-File -FilePath $probeFile -Encoding utf8
docker cp $probeFile "${Container}:/tmp/mcp_argpath_gate_probe.py" 2>$null | Out-Null
$probe = docker exec $Container sh -c "cd /app/backend && PYTHONPATH=/app/adapters .venv/bin/python /tmp/mcp_argpath_gate_probe.py" 2>&1
Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
Check 'A6 the interceptor imports and runs inside deer-flow' `
      ($probe -match 'REWRITE') `
      (($probe | Out-String).Trim() -replace '\s+', ' ')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
