# Guard: MCP tool ARGUMENTS must be path-translated, and the rewrite must have
# the thread context it needs to do that.
#
# WHY THIS EXISTS (measured 2026-10-30 on 0.2.7)
#
#   officecli_officecli({"command":"create /mnt/user-data/outputs/x.docx"})
#     -> ToolException: Could not find a part of the path
#
# `/mnt/user-data` is a VIRTUAL path. Inside the container the real directory is
# `{data}/deer-flow/users/<user>/threads/<thread>/user-data/outputs`. bash
# commands were rewritten by `replace_virtual_paths_in_command` and read_file's
# `path` by `replace_virtual_path`; MCP ARGUMENTS were passed verbatim.
#
# The same patch also restores `runtime` injection. Without InjectedToolArg the
# injected ToolRuntime never reaches the closure, so the rewrite would silently
# no-op - measured both ways against a real ToolNode with an MCP-shaped schema:
#     plain  `runtime: Runtime | None = None`       -> runtime NONE
#     `Annotated[Runtime | None, InjectedToolArg()]` -> runtime YES
#
# WHAT IS ASSERTED
#   A1  the patch exists and is a whole module, not a diff
#   A2  the closure marks `runtime` with InjectedToolArg, and imports it
#   A3  the argument rewrite is wired ONCE, before the interceptor branch, so no
#       call path can skip it
#   A4  the rewriter is a no-op without thread data, on a path-free value, and is
#       depth-bounded
#   A5  both compose files mount the patch (A5 parity - install.ps1 uses the bundle)
#   A6  live: the deployed file is the patch, and the module actually loads the
#       MCP tool surface through it
#
# Exit 2 means CANNOT CHECK and must never be read as a failure.
[CmdletBinding()]
param(
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$patch = 'deploy/client-bundle/patches/deer-flow-mcp-args.py'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$mountTarget = '/app/backend/packages/harness/deerflow/mcp/tools.py'

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== MCP argument path translation ===' -ForegroundColor Cyan

# ── A1 ───────────────────────────────────────────────────────────────────────
Check 'A1 the patch exists' (Test-Path $patch) $patch
if (-not (Test-Path $patch)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $patch -Raw

Check 'A1 the patch is a whole module (defines _make_session_pool_tool)' `
      ($src -match '(?m)^def _make_session_pool_tool\(')

# ── A2 ───────────────────────────────────────────────────────────────────────
# The exact shape that made a first patch attempt silently no-op.
Check 'A2 runtime is annotated InjectedToolArg' `
      ($src -match 'runtime:\s*Annotated\[\s*Runtime\s*\|\s*None\s*,\s*InjectedToolArg\(\)\s*\]') `
      'without InjectedToolArg the injected ToolRuntime is dropped by _parse_input'
Check 'A2 InjectedToolArg is imported' `
      ($src -match 'from langchain_core\.tools\.base import InjectedToolArg')

# ── A3 ───────────────────────────────────────────────────────────────────────
$rewriteAt = $src.IndexOf('_rewrite_virtual_paths_in_args(arguments')
$branchAt  = $src.IndexOf('if tool_interceptors:')
Check 'A3 the argument rewrite is wired at the call site' ($rewriteAt -ge 0)
Check 'A3 the rewrite precedes the interceptor branch' `
      ($rewriteAt -ge 0 -and $branchAt -ge 0 -and $rewriteAt -lt $branchAt) `
      "rewriteAt=$rewriteAt branchAt=$branchAt"

# Both helpers are needed: the prefix rewriter is space-safe but only handles a
# value that STARTS with a virtual root; the command rewriter handles an embedded
# path but tokenizes on whitespace, so a path with spaces must not reach it first.
Check 'A3 a pure path is rewritten with the exact helper' `
      ($src -match 'new_value = replace_virtual_path\(value, thread_data\)')
Check 'A3 an embedded path falls back to the command helper' `
      ($src -match 'new_value = replace_virtual_paths_in_command\(value, thread_data\)')
Check 'A3 the exact helper is tried before the command helper' `
      ($src.IndexOf('replace_virtual_path(value, thread_data)') -lt $src.IndexOf('replace_virtual_paths_in_command(value, thread_data)'))

# ── A4 ───────────────────────────────────────────────────────────────────────
Check 'A4 the rewriter short-circuits without thread data' `
      ($src -match 'if not thread_data or not isinstance\(args, dict\):\s*\r?\n\s*return args')
Check 'A4 the rewriter is depth-bounded' ($src -match '_ARG_PATH_MAX_DEPTH')
Check 'A4 a path-free string is returned unchanged' `
      ($src -match 'if VIRTUAL_PATH_PREFIX not in value:\s*\r?\n\s*return value')
Check 'A4 an unchanged argument object is returned as-is' `
      ($src -match 'return rewritten if changed else args')
Check 'A4 thread data falls back to a derivation when the graph did not inject it' `
      ($src -match 'def _thread_data_for_mcp\(')

# ── A5 ───────────────────────────────────────────────────────────────────────
foreach ($c in $composes) {
    $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
    Check "A5 $c mounts the patch over $mountTarget" `
          ($body -match [regex]::Escape("./patches/deer-flow-mcp-args.py:$mountTarget"))
}

# ── A6 (live) ────────────────────────────────────────────────────────────────
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

$liveCount = (docker exec $Container sh -c "grep -c '_rewrite_virtual_paths_in_args' $mountTarget" 2>$null)
Check 'A6 the running container executes the patch' `
      ($liveCount -and [int]$liveCount -ge 2) `
      "grep count in container: $liveCount"

# A docker cp copy would not appear in the mount table; only a real bind mount
# will. `mount` does not report the SOURCE on this Windows/9p host, so the
# authoritative source of truth is docker's own mount list, which is also
# platform-independent.
$mnt = (docker exec $Container sh -c "mount | grep '$mountTarget'" 2>$null)
Check 'A6 the patch is a live bind mount' `
      ($mnt) `
      'a docker cp copy would not appear here; only a real mount will'

$mountJson = (docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}|{{.RW}};{{end}}' $Container 2>$null)
$mountRow = @(($mountJson -split ';') | Where-Object { $_ -match [regex]::Escape($mountTarget) }) | Select-Object -First 1
Check 'A6 the mount source is the tracked patch' `
      ($mountRow -and $mountRow -match 'deer-flow-mcp-args\.py') `
      "mount row: $mountRow"
Check 'A6 the mount is read-only' `
      ($mountRow -and $mountRow -match '\|False$') `
      ".RW must be False for a :ro mount; got: $mountRow"

# The module must still import and load the surface. A syntax error or a broken
# import here would take every MCP tool with it - the exact blast radius that
# makes this patch worth gating rather than eyeballing.
#
# The probe is written to a file rather than passed with -c: nesting Python
# quotes inside `sh -c` inside PowerShell is where a gate starts failing on a
# healthy stack, which is how a runner earns being ignored.
$probeDir = Join-Path $env:TEMP ("mcp-args-gate-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
$probeFile = Join-Path $probeDir 'probe.py'
@'
import asyncio
from deerflow.mcp.tools import get_mcp_tools

print("COUNT", len(asyncio.run(get_mcp_tools())))
'@ | Out-File -FilePath $probeFile -Encoding utf8
docker cp $probeFile "${Container}:/tmp/mcp_args_gate_probe.py" 2>$null | Out-Null
$probe = docker exec $Container sh -c "cd /app/backend && .venv/bin/python /tmp/mcp_args_gate_probe.py" 2>$null
Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
Check 'A6 the patched module loads the MCP tool surface' `
      ($probe -and $probe -match 'COUNT ([1-9][0-9]*)') `
      (($probe | Out-String).Trim() -replace '\s+', ' ')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
