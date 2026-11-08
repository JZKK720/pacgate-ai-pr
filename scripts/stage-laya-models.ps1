<#
.SYNOPSIS
    Stage the laya checkpoints on a machine that can reach a model host.

.DESCRIPTION
    WHY THIS EXISTS (2026-11-01).

    laya makes optional clause judgement work on the client machine, but it needs
    checkpoints on disk. The documented way is `huggingface-cli download`, and that
    was measured unusable from this region: huggingface.co resolves to
    199.16.158.12 (an X/Twitter range) and transfers at roughly 10 KB/s with Xet
    enabled. ModelScope, on Alibaba Cloud, serves the same repository at
    0.59 MB/s - about 60x faster - so this script stages from ModelScope by default.

    It writes an HF *cache* layout ("$OutDir/hub/models--convaiinnovations--laya/
    snapshots/<sha>/"), because that is what laya reads. It does NOT write a
    `trees/` revision listing. That detail is load-bearing: with HF_HUB_OFFLINE=1,
    `snapshot_download` cross-checks `trees/<sha>.json` against the Hub's file
    metadata and raises IncompleteSnapshotError when files are missing from it -
    which they are, because we deliberately fetch only the checkpoints. Measured:
    without trees/, the cache resolves and serves; with it, every load fails.
    `blobs/` is NOT needed either (measured), so this does not duplicate ~1.4 GB.

    Run this on a machine with internet access. From 0.2.13 the checkpoints are
    BAKED into ghcr.io/jzkk720/laya-serve, so a client install needs no staging:
    this output is a laya-serve BUILD CONTEXT, used to rebuild the image or to
    override the baked weights on one machine.

.PARAMETER OutDir
    Where to write the cache. For a rebuild, point it at
    deploy/laya-serve/laya-weights (the Dockerfile's COPY source).

.PARAMETER Models
    Checkpoints to stage. Default stages both, which is what an en/zh deployment
    needs: laya routes Latin text to `english` and Han to `multilingual`, and a
    missing checkpoint makes that language fail with HTTP 500.

.PARAMETER Revision
    ModelScope revision. Default master.

.PARAMETER Force
    Re-download even when a file already has the right size.

.EXAMPLE
    pwsh -NoProfile -File scripts/stage-laya-models.ps1 -OutDir ..\laya-hf-cache

.NOTES
    Exit codes: 0 = staged and verified; 1 = a defect; 2 = cannot check (no
    network, or the host does not serve the repo).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [ValidateSet('multilingual', 'english', 'both')]
    [string]$Models = 'both',

    [string]$Revision = 'master',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Repo = 'convaiinnovations/laya'
$FilesApi = "https://modelscope.cn/api/v1/models/${Repo}/repo/files?Revision=${Revision}&Recursive=true"
$FileApi = "https://modelscope.cn/api/v1/models/$Repo/repo"

# A checkpoint is the files laya hands snapshot_download: the config, the weights
# and the tokenizer/encoder subdirectories. multilingual lives in a subfolder;
# english lives at the repo root. Anything else is not a checkpoint.
function Get-CheckpointFiles([string]$Name, $AllPaths) {
    if ($Name -eq 'multilingual') {
        return @($AllPaths | Where-Object { $_ -like 'multilingual/*' })
    }
    return @($AllPaths | Where-Object {
            ($_ -notlike '*/*' -and $_ -in @('config.json', 'rl_agent_config.json', 'model.safetensors')) -or
            $_ -like 'tokenizer/*' -or $_ -like 'encoder/*'
        })
}

Write-Host "laya checkpoint staging" -ForegroundColor Cyan
Write-Host "  repo     : $Repo"
Write-Host "  source   : modelscope.cn"
Write-Host "  out      : $OutDir"
Write-Host "  models   : $Models"
Write-Host ''

# ── 1. resolve the file list and the commit sha ───────────────────────────────
# ModelScope's listing endpoint intermittently truncates the response
# (IncompleteRead after a few KB) rather than failing outright. Measured: one
# attempt in two. Invoke-RestMethod's built-in retry does not cover a short body,
# and neither does a bare try/catch with a single attempt, so retry explicitly
# and treat an unparsable or empty listing as "try again" rather than "empty".
$listing = $null
$lastErr = $null
for ($i = 1; $i -le 6; $i++) {
    try {
        $candidate = Invoke-RestMethod -Uri $FilesApi -TimeoutSec 90
        $n = @($candidate.Data.Files).Count
        if ($n -gt 0) { $listing = $candidate; break }
        $lastErr = "listing returned 0 files (attempt $i)"
    }
    catch {
        $lastErr = "$($_.Exception.Message) (attempt $i)"
    }
    Start-Sleep -Seconds (2 * $i)
}

if (-not $listing) {
    Write-Host "  CANNOT CHECK: model host unreachable or listing truncated - $lastErr" -ForegroundColor Yellow
    Write-Host '  Run this on a machine with internet access, then copy the result.' -ForegroundColor Yellow
    exit 2
}

$paths = @($listing.Data.Files | Where-Object { $_.Type -eq 'blob' -or $_.Type -eq 'file' } | ForEach-Object { $_.Path })
if ($paths.Count -eq 0) {
    Write-Host "  CANNOT CHECK: the listing returned no usable files - the API shape may have changed." -ForegroundColor Yellow
    exit 2
}
Write-Host "  resolved $($paths.Count) file(s) in the repository"

# The commit id the cache must be keyed by. ModelScope exposes it as Revision on
# a resolved listing; fall back to the Hub's sha only if we can reach it, and
# otherwise derive a stable local key so the layout is still self-consistent.
$sha = $null
if ($listing.Data.Revision) { $sha = [string]$listing.Data.Revision }
if (-not $sha -or $sha -notmatch '^[0-9a-f]{40}$') {
    try {
        $hub = Invoke-RestMethod -Uri "https://huggingface.co/api/models/$Repo" -TimeoutSec 30 -MaximumRetryCount 2
        if ($hub.sha -match '^[0-9a-f]{40}$') { $sha = $hub.sha }
    }
    catch { }
}
if (-not $sha) {
    # A local-only key keeps the tree internally consistent; it just will not match
    # an upstream commit, which only matters for provenance, not for loading.
    $sha = ([System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes("laya|$Revision|$($paths.Count)"))) -replace '-', '').ToLower()
}
Write-Host "  cache key: $sha"

# ── 2. work out which files each checkpoint needs ─────────────────────────────
$wanted = [System.Collections.Generic.List[string]]::new()
$sets = if ($Models -eq 'both') { @('multilingual', 'english') } else { @($Models) }
foreach ($m in $sets) {
    foreach ($f in (Get-CheckpointFiles $m $paths)) { if (-not $wanted.Contains($f)) { $wanted.Add($f) } }
}
Write-Host "  files needed: $($wanted.Count)"
Write-Host ''

# ── 3. download into the HF cache layout ──────────────────────────────────────
$repoDir = Join-Path (Join-Path $OutDir 'hub') 'models--convaiinnovations--laya'
$snapDir = Join-Path (Join-Path $repoDir 'snapshots') $sha
New-Item -ItemType Directory -Force -Path $snapDir | Out-Null

# Never leave a trees/ listing behind: see the note at the top.
$treesDir = Join-Path $repoDir 'trees'
if (Test-Path -LiteralPath $treesDir) {
    Remove-Item -LiteralPath $treesDir -Recurse -Force
    Write-Host '  removed a stale trees/ listing (it makes offline load fail)' -ForegroundColor DarkGray
}

$index = @{}
foreach ($p in $listing.Data.Files) { $index[$p.Path] = $p }

$okCount = 0
$failCount = 0
foreach ($rel in $wanted) {
    $meta = $index[$rel]
    $size = if ($meta) { [int64]$meta.Size } else { 0 }
    $dest = Join-Path $snapDir ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null

    if (-not $Force -and (Test-Path -LiteralPath $dest)) {
        $have = (Get-Item -LiteralPath $dest).Length
        if ($size -gt 0 -and $have -eq $size) {
            Write-Host ("  have    {0}  ({1:n1} MB)" -f $rel, ($have / 1MB)) -ForegroundColor DarkGray
            $okCount++
            continue
        }
    }

    # ${FileApi} braces are REQUIRED, not style: PowerShell allows '?' inside a
    # variable name, so "$FileApi?Revision=..." silently expands an undefined
    # $FileApi?Revision to nothing and yields the URL "=master&FilePath=..."
    # ("Invalid URI: The hostname could not be parsed"). Measured 2026-11-01.
    $url = "${FileApi}?Revision=${Revision}&FilePath=$([uri]::EscapeDataString($rel))"
    # Same truncation problem as the listing, and worse for a 600 MB file: a
    # partial body leaves a file that exists but is short. Retry until the size
    # matches, and delete the partial before each attempt so a resumed file
    # cannot masquerade as a complete one.
    $attempt = 0
    $done = $false
    while (-not $done -and $attempt -lt 4) {
        $attempt++
        try {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
            Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 3600
            $got = (Get-Item -LiteralPath $dest).Length
            if ($size -le 0 -or $got -eq $size) { $done = $true; break }
            Write-Host ("  retry   {0} - got {1} of {2} bytes" -f $rel, $got, $size) -ForegroundColor DarkYellow
        }
        catch {
            Write-Host ("  retry   {0} - {1}" -f $rel, $_.Exception.Message) -ForegroundColor DarkYellow
        }
        Start-Sleep -Seconds (3 * $attempt)
    }
    if (-not $done) {
        Write-Host ("  FAIL    {0} after {1} attempt(s)" -f $rel, $attempt) -ForegroundColor Red
        $failCount++
        continue
    }

    $got = (Get-Item -LiteralPath $dest).Length
    if ($size -gt 0 -and $got -ne $size) {
        Write-Host ("  FAIL    {0} - size {1} != expected {2}" -f $rel, $got, $size) -ForegroundColor Red
        $failCount++
        continue
    }
    Write-Host ("  fetched {0}  ({1:n1} MB)" -f $rel, ($got / 1MB)) -ForegroundColor Green
    $okCount++
}

# refs/main tells snapshot_download which snapshot a bare repo id resolves to.
$refsDir = Join-Path $repoDir 'refs'
New-Item -ItemType Directory -Force -Path $refsDir | Out-Null
Set-Content -LiteralPath (Join-Path $refsDir 'main') -Value $sha -NoNewline -Encoding ascii

# ── 4. verify the layout is complete for the requested checkpoints ────────────
Write-Host ''
Write-Host 'verify' -ForegroundColor Cyan
$missing = @()
foreach ($m in $sets) {
    $need = Get-CheckpointFiles $m $paths
    $haveAll = $true
    foreach ($rel in $need) {
        if (-not (Test-Path -LiteralPath (Join-Path $snapDir ($rel -replace '/', '\')))) {
            $missing += $rel
            $haveAll = $false
        }
    }
    if ($haveAll) { Write-Host "  [PASS] $m is complete" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $m is incomplete" -ForegroundColor Red }
}
if (Test-Path -LiteralPath $treesDir) { Write-Host '  [FAIL] a trees/ listing exists - offline load will fail' -ForegroundColor Red }

$totalMb = [math]::Round((Get-ChildItem -LiteralPath $snapDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 0)
Write-Host ''
Write-Host "  staged $okCount file(s), $totalMb MB total at $snapDir"

if ($failCount -gt 0 -or $missing.Count -gt 0) {
    Write-Host "RESULT: staging INCOMPLETE ($failCount download failure(s), $($missing.Count) missing file(s))." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  This output is the laya-serve BUILD CONTEXT for baking, not a runtime mount."
Write-Host "  From 0.2.13 the checkpoints ship inside ghcr.io/jzkk720/laya-serve, so a"
Write-Host '  client install needs no staging at all. This script is for the two cases'
Write-Host '  that baking cannot cover:'
Write-Host "    1. REBUILDING the image. Copy '$OutDir' to deploy/laya-serve/laya-weights"
Write-Host '       and rebuild:  docker build -t laya-serve:local deploy/laya-serve'
Write-Host '    2. PINNING different weights on one machine, by mounting this directory'
Write-Host '       over /home/laya/.cache/huggingface. That REPLACES the baked layer, so'
Write-Host '       it only works with a complete directory - a partial or empty one'
Write-Host '       crash-loops the container.'
Write-Host ''
Write-Host '  To use the shipped image instead, do nothing here:'
Write-Host '       docker compose --profile laya up -d laya'
Write-Host 'RESULT: checkpoints staged and verified.' -ForegroundColor Green
exit 0
