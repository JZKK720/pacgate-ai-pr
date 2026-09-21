# Audit the deer-flow patch stack against upstream.
#
# The pacgate deer-flow wrapper bind-mounts eight whole-file Python patches over
# upstream modules. That keeps the integration non-invasive, but it means an
# upstream bump is a rebase, not a version edit. This script makes the rebase
# measurable:
#
#   1. our INTENDED delta per patch (patch vs its upstream base revision)
#   2. whether the patched upstream path still EXISTS at the target revision
#   3. upstream churn in that file between base and target
#
# (2) is the rebase-break signal: if upstream moved or renamed the file, the
# bind-mount lands on nothing and the container starts with our code silently
# absent. That must fail loudly here rather than at runtime.
#
# Usage:
#   pwsh -File scripts/audit-deer-flow-patches.ps1
#   pwsh -File scripts/audit-deer-flow-patches.ps1 -BaseRef v2.0.0 -TargetRef v2.1.0-rc0
#
# Exit codes: 0 = inventory clean, 1 = a patched path is missing at target.
#
# NOTE ON RELIABILITY (learned the hard way, 2026-09-21): the first version of
# this script wrapped git in a PowerShell function and read $LASTEXITCODE. That
# path returned 129 (git usage error) for EVERY call, so all seven patched paths
# were reported missing at the target and the script exited 1 claiming the
# upgrade would break. All seven exist. Native calls are therefore made directly
# here, path existence is decided by whether `rev-parse --verify` printed an
# object id rather than by an exit code, and both refs are resolved up front so a
# bad ref cannot masquerade as "everything missing".

[CmdletBinding()]
param(
    [string]$BaseRef = 'v2.0.0',
    [string]$TargetRef = 'v2.1.0-rc0',
    [string]$ClonePath
)

$ErrorActionPreference = 'Stop'

# Pin UTF-8 BEFORE any native git call. PowerShell decodes a native command's
# stdout using the console codepage (GBK on some dev boxes), which mangles
# non-ASCII bytes. The upstream files here contain em-dashes, so without this the
# `git show` base copy is corrupted on the way in and every delta is inflated
# with false changes. Same trap already guarded in
# scripts/assert-no-staged-secrets.ps1.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = Split-Path -Parent $PSScriptRoot
$patchesDir = Join-Path $repoRoot 'deploy/client-bundle/patches'
if (-not $ClonePath) { $ClonePath = Join-Path $repoRoot 'deploy/deer-flow-src' }

if (-not (Test-Path $patchesDir)) { throw "patches dir not found: $patchesDir" }
if (-not (Test-Path (Join-Path $ClonePath '.git'))) {
    throw "deer-flow clone not found at $ClonePath (expected a git checkout)"
}

# Resolve <ref>:<path> to an object id, or $null. Content-based, not exit-code
# based, so it cannot silently invert.
function Resolve-GitPath {
    param([string]$Ref, [string]$Path)
    $sha = & git -C $ClonePath rev-parse --verify --quiet "${Ref}:${Path}" 2>$null
    $s = ($sha | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    return $s
}

# ── patch -> upstream path map (from the bind-mount targets in compose.prod.yaml)
$patchMap = [ordered]@{
    'deer-flow-agent.py'       = 'backend/packages/harness/deerflow/agents/lead_agent/agent.py'
    'deer-flow-artifacts.py'   = 'backend/app/gateway/routers/artifacts.py'
    'deer-flow-prompt.py'      = 'backend/packages/harness/deerflow/agents/lead_agent/prompt.py'
    'deer-flow-sync.py'        = 'backend/packages/harness/deerflow/tools/sync.py'
    'deer-flow-thread-runs.py' = 'backend/app/gateway/routers/thread_runs.py'
    'deer-flow-uploads.py'     = 'backend/app/gateway/routers/uploads.py'
    'deer-flow-worker.py'      = 'backend/packages/harness/deerflow/runtime/runs/worker.py'
}

# langchain-mcp-tools.py overrides a VENDORED package inside the image venv, not
# upstream source, so it has no path in this repo and cannot be rebased here.
$vendoredPatch = 'langchain-mcp-tools.py'

Write-Host '=== deer-flow patch stack audit ===' -ForegroundColor White
Write-Host "  clone      : $ClonePath"
Write-Host "  base ref   : $BaseRef"
Write-Host "  target ref : $TargetRef"
Write-Host ''

# Precondition: prove the refs resolve BEFORE trusting any per-path result.
foreach ($r in @($BaseRef, $TargetRef)) {
    $tip = & git -C $ClonePath rev-parse --verify --quiet "${r}^{commit}" 2>$null
    if ([string]::IsNullOrWhiteSpace((($tip | Out-String).Trim()))) {
        throw "ref '$r' does not resolve in $ClonePath -- fetch tags first; per-path results would be meaningless"
    }
}
Write-Host '  (both refs resolve)' -ForegroundColor DarkGray
Write-Host ''

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dfpatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

$rows = @()
$missing = @()

foreach ($patchName in $patchMap.Keys) {
    $upstreamPath = $patchMap[$patchName]
    $patchPath = Join-Path $patchesDir $patchName
    if (-not (Test-Path $patchPath)) { throw "patch missing on disk: $patchPath" }

    $existsAtTarget = $null -ne (Resolve-GitPath -Ref $TargetRef -Path $upstreamPath)
    $existsAtBase   = $null -ne (Resolve-GitPath -Ref $BaseRef   -Path $upstreamPath)

    if (-not $existsAtTarget) {
        $missing += [pscustomobject]@{ Patch = $patchName; Path = $upstreamPath }
    }

    # our intended delta: patch file vs the BASE revision it was built from.
    # The base copy is read as a BLOB to BYTES and written to disk, then diffed
    # by PATH against the patch file. Both sides are then real files on disk and
    # git compares bytes directly -- no PowerShell string round-trip, so the
    # UTF-8 base content cannot be transcoded or re-encoded on the way.
    $add = -1; $del = -1
    if ($existsAtBase) {
        $baseFile = Join-Path $tmpRoot "base-$patchName"
        git -C $ClonePath cat-file blob "${BaseRef}:${upstreamPath}" > $baseFile
        $ns = & git diff --no-index --numstat --ignore-cr-at-eol $baseFile $patchPath 2>$null
        if ($ns) { $p = (($ns | Out-String) -split '\s+'); $add = [int]$p[0]; $del = [int]$p[1] }
        else { $add = 0; $del = 0 }   # byte-identical to upstream at base
    }

    # upstream churn in this file between base and target
    $churn = 0
    if ($existsAtTarget -and $existsAtBase) {
        $cs = & git -C $ClonePath diff --numstat $BaseRef $TargetRef -- $upstreamPath 2>$null
        if ($cs) { $p = (($cs | Out-String) -split '\s+'); $churn = [int]$p[0] + [int]$p[1] }
    }

    $rows += [pscustomobject]@{
        Patch         = $patchName
        OurAdd        = $add
        OurDel        = $del
        OurDelta      = if ($add -ge 0) { $add + $del } else { -1 }
        UpstreamChurn = $churn
        AtTarget      = $existsAtTarget
    }
}

Write-Host '=== our intended delta vs the base revision ===' -ForegroundColor Cyan
$rows | Sort-Object OurDelta -Descending |
    Format-Table Patch, OurAdd, OurDel, OurDelta, UpstreamChurn, AtTarget -AutoSize |
    Out-String | Write-Host

$totalOur = ($rows | Measure-Object OurDelta -Sum).Sum
$totalUp = ($rows | Measure-Object UpstreamChurn -Sum).Sum
Write-Host ("  OUR total intended delta : {0} lines across {1} patches" -f $totalOur, $rows.Count)
Write-Host ("  UPSTREAM churn in those files ({0}..{1}) : {2} lines" -f $BaseRef, $TargetRef, $totalUp)
Write-Host ''

Write-Host '=== vendored patch (cannot be rebased in this repo) ===' -ForegroundColor Cyan
$vendedPath = Join-Path $patchesDir $vendoredPatch
if (Test-Path $vendedPath) {
    $vLines = (Get-Content $vendedPath).Count
    Write-Host ("  {0}: {1} lines; rebase against langchain_mcp_adapters INSIDE the target image" -f $vendoredPatch, $vLines)
} else {
    Write-Host ("  {0}: NOT FOUND" -f $vendoredPatch) -ForegroundColor Red
}
Write-Host ''

Write-Host '=== encoding check (a mis-decode would inflate every delta) ===' -ForegroundColor Cyan
foreach ($patchName in $patchMap.Keys) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $patchesDir $patchName))
    try {
        [void][System.Text.Encoding]::GetEncoding('utf-8', [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback).GetString($bytes)
        $utf8 = 'utf-8 OK'
    } catch { $utf8 = 'NOT VALID UTF-8' }
    Write-Host ("  {0,-26} {1}" -f $patchName, $utf8)
}
Write-Host ''

if ($missing.Count -gt 0) {
    Write-Host '=== FAIL: patched upstream paths missing at target ===' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ("  {0} -> {1}" -f $m.Patch, $m.Path) -ForegroundColor Red }
    Write-Host '  A bind-mount onto a missing path means our code is silently absent at runtime.'
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
    exit 1
}

Write-Host '=== OK: every patched upstream path still exists at the target ===' -ForegroundColor Green
Write-Host '  Next: classify each patch (still-needed vs upstream-fixed), then 3-way rebase.'
Write-Host '  See plans/023-deer-flow-2.1-upgrade.md.'

Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
exit 0
