<#
.SYNOPSIS
    Bound the growth of per-thread agent workspaces on a Pacgate AIPC.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-30).

    `deploy/client-bundle/data/` is bind-mounted into deer-flow (`./data:/data`)
    and is gitignored, so nothing in the repo watches it and no gate fails when it
    grows. Measured on the dev box: 2.4 GB, of which a single agent thread held
    517 MB - a `.venv` the agent created for itself on 2026-10-21 and never used
    again. The checkpoint DB beside it was 1.8 GB with a further 470 MB of
    uncheckpointed WAL. None of that is a cache. It is durable run history.

    So this tool is deliberately NOT a purge. It removes whole THREADS by an
    explicit age rule, and it does so through the API rather than by deleting
    directories.

    WHY THE API AND NOT `rm -rf` (the measured reason).

    A thread is three things that must stay in agreement:
        1. its directory  - data/deer-flow/users/<user>/threads/<id>/
        2. its checkpoints - rows in checkpoints.db (thread_id) + writes
        3. its metadata   - the `store` table, which backs /threads/search
    Measured on this box: the DB held 16 thread_ids and the disk held 9
    directories, with ZERO directories missing a DB row. Dropping a directory
    alone would therefore leave a thread that still appears in the UI, still
    lists in /threads/search, and returns 404 for every artifact. That is worse
    than the disk usage it frees.

    `DELETE /api/threads/{id}` (deer-flow `threads.py`) removes all three:
    the directory via `path_manager.delete_thread_dir`, the checkpoints via
    `checkpointer.adelete_thread`, and the metadata via `thread_store.delete`.
    That is the only safe removal path, and it is what this tool uses.

    WHAT IT WILL NOT DO
    - It never touches matters, documents, kb_chunks or anything in Postgres.
      Those are client matter data and are owned by the matter API.
    - It never deletes a thread newer than -OlderThanDays, however large.
    - It never deletes any of the -KeepLast most recently active threads, even if
      they are older than the age rule. A floor beats an age threshold for
      "someone is clearly still working in here".
    - It refuses to run without -Delete unless -WhatIf is used, so a bare
      invocation only reports.
    - It never removes a directory directly, so it cannot orphan a DB row.

    THE WAL IS SEPARATE. `-CheckpointWal` runs
    `PRAGMA wal_checkpoint(TRUNCATE)` against checkpoints.db. A 470 MB `-wal` is
    un-checkpointed pages, not garbage: deleting the file corrupts nothing but
    loses the pages, and deleting it while the DB is open is unsafe. The pragma is
    the supported way to fold it back and reclaim the space. It needs a quiet
    window - a concurrent write blocks the truncate.

.PARAMETER BaseUrl
    deer-flow root through nginx. Default http://localhost:8089

.PARAMETER CredFile
    File holding PACGATE_DEERFLOW_PASSWORD. Default is the gitignored
    deploy/client-bundle/.deer-flow-credentials - the same file
    run-benchmark.ps1 reads. The password is required because deleting a thread
    is an authenticated write.

.PARAMETER OlderThanDays
    Only threads whose last activity (updated_at) is at least this many days old
    are candidates. Default 30.

.PARAMETER KeepLast
    Always protect this many of the most recently active threads. Default 5.

.PARAMETER Delete
    Actually delete the candidates. Without it the script only reports.

.PARAMETER CheckpointWal
    Run the WAL truncate as well. Independent of -Delete; it only changes the WAL.

.EXAMPLE
    # Report only - the default.
    .\scripts\clean-thread-workspaces.ps1

.EXAMPLE
    # The measured dev-box situation: 9-day-old threads, keep the newest 5.
    .\scripts\clean-thread-workspaces.ps1 -OlderThanDays 5 -WhatIf

.EXAMPLE
    # Reclaim the WAL without deleting any thread.
    .\scripts\clean-thread-workspaces.ps1 -CheckpointWal

.NOTES
    Exit codes: 0 = ok (or nothing to do); 1 = something failed; 2 = cannot run.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BaseUrl = 'http://localhost:8089',
    [string]$CredFile = '',
    [int]$OlderThanDays = 30,
    [int]$KeepLast = 5,
    [switch]$Delete,
    [switch]$CheckpointWal,
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$BaseUrl = $BaseUrl.TrimEnd('/')

function Write-Ok([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Bad([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Warn2([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Note([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }

# A native command's stderr becomes a terminating error on Windows PowerShell 5.1
# once redirected, and the client AIPC may only have 5.1. Wrap every native call.
function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script 2>&1) } finally { $ErrorActionPreference = $prev }
}

if (-not $CredFile) {
    $CredFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.deer-flow-credentials'
}

Write-Host '=== thread-workspace retention ==='

# ── Preflight: the stack must be up. Without it this is CANNOT CHECK (exit 2),
# ── never a silent pass.
$running = Invoke-NativeCapture { docker ps --format '{{.Names}}' }
if ($LASTEXITCODE -ne 0 -or -not $running) {
    Write-Host '  exit 2 - docker is not reachable; cannot inspect the stack.' -ForegroundColor Yellow
    exit 2
}
if (@($running) -notcontains $Container) {
    Write-Host "  exit 2 - container '$Container' is not running." -ForegroundColor Yellow
    exit 2
}

# ── Credential. deer-flow keeps its own identity store, so this cannot be derived
# ── from PACGATE_API_PASSWORD. Same resolution contract as run-benchmark.ps1.
$dfPassword = $env:PACGATE_DEERFLOW_PASSWORD
if (-not $dfPassword -and (Test-Path -LiteralPath $CredFile)) {
    $m = Select-String -LiteralPath $CredFile -Pattern '^\s*PACGATE_DEERFLOW_PASSWORD\s*=\s*(.+?)\s*$' | Select-Object -First 1
    if ($m) { $dfPassword = $m.Matches[0].Groups[1].Value.Trim() }
}
if (-not $dfPassword) {
    Write-Host "  exit 2 - no deer-flow password (set PACGATE_DEERFLOW_PASSWORD or create $CredFile)." -ForegroundColor Yellow
    exit 2
}

$Email = 'admin@pacgate-law.com'
Write-Note "authenticating as $Email"

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
try {
    $null = Invoke-WebRequest -Uri "$BaseUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = $Email; password = $dfPassword } `
        -WebSession $session -UseBasicParsing -TimeoutSec 25
}
catch {
    $code = try { [int]$_.Exception.Response.StatusCode.value__ } catch { 0 }
    Write-Bad "deer-flow login failed (HTTP $code) at $BaseUrl"
    exit 2
}
$csrf = ($session.Cookies.GetCookies($BaseUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value
if (-not $csrf) { Write-Bad 'login succeeded but no csrf_token cookie - cannot issue authenticated writes'; exit 2 }
$H = @{ 'X-CSRF-Token' = $csrf }

# ── Enumerate threads from the API, not the filesystem. The API is the source of
# ── truth for what the user can SEE, and a thread that is invisible but holds
# ── 500 MB on disk is exactly what this tool is for.
try {
    $threads = (Invoke-WebRequest -Uri "$BaseUrl/api/threads/search" -Method Post `
            -Headers $H -Body '{}' -ContentType 'application/json' `
            -WebSession $session -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json
}
catch {
    Write-Bad "cannot list threads ($($_.Exception.Message))"
    exit 2
}
if ($null -eq $threads) { $threads = @() }
$threads = @($threads | Where-Object { $_ })
if ($threads.Count -eq 0) { Write-Ok 'no threads on this box'; exit 0 }

Write-Note "$($threads.Count) thread(s) known to the API"

# ── Select candidates: age first, then the recency floor.
$now = Get-Date
$cutoff = $now.AddDays(-$OlderThanDays)
$ordered = @($threads | Sort-Object { [datetime]$_.updated_at } -Descending)

$protectedNewest = @($ordered | Select-Object -First $KeepLast)
$protectedIds = @($protectedNewest | ForEach-Object { $_.thread_id })

$candidates = @()
$tooNew = 0
$protectedByFloor = 0
foreach ($t in $threads) {
    $updated = [datetime]$t.updated_at
    if ($updated -gt $cutoff) { $tooNew++; continue }
    if ($protectedIds -contains $t.thread_id) { $protectedByFloor++; continue }
    $candidates += $t
}

Write-Host ''
Write-Host ("  rule: updated_at older than {0} day(s) (before {1:yyyy-MM-dd HH:mm}), keeping the newest {2}" -f $OlderThanDays, $cutoff, $KeepLast) -ForegroundColor DarkGray
Write-Note "$tooNew thread(s) younger than the age rule - kept"
Write-Note "$protectedByFloor thread(s) older than the rule but inside the -KeepLast $KeepLast floor - kept"

if ($candidates.Count -eq 0) {
    Write-Ok "nothing to remove under this rule"
}
else {
    Write-Host ''
    Write-Host '  candidates:' -ForegroundColor Yellow
    foreach ($c in $candidates) {
        # Size on disk, read from inside the container so the path is the one the
        # service actually uses (the host path is a bind mount of the same tree).
        $size = 'unknown'
        $du = Invoke-NativeCapture {
            docker exec $Container sh -c "du -sm '/data/deer-flow/users'/*/threads/$($c.thread_id) 2>/dev/null | head -1"
        }
        if ($du -and ("$du" -match '^\s*(\d+)')) { $size = "$($Matches[1]) MB" }
        Write-Host ("    {0}  status={1}  last={2:yyyy-MM-dd}  {3,9}" -f `
            $c.thread_id.Substring(0, 8), $c.status, ([datetime]$c.updated_at), $size) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Ok "$($candidates.Count) candidate(s)"

    if (-not $Delete) {
        Write-Host '  report only - re-run with -Delete to remove them.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ''
        $deleted = 0
        foreach ($c in $candidates) {
            if (-not $PSCmdlet.ShouldProcess($c.thread_id, 'delete thread (dir + checkpoints + metadata)')) { continue }
            try {
                $null = Invoke-WebRequest -Uri "$BaseUrl/api/threads/$($c.thread_id)" -Method Delete `
                    -Headers $H -WebSession $session -UseBasicParsing -TimeoutSec 120
                Write-Ok "deleted $($c.thread_id.Substring(0, 8))"
                $deleted++
            }
            catch {
                $code = try { [int]$_.Exception.Response.StatusCode.value__ } catch { 0 }
                Write-Bad "delete of $($c.thread_id.Substring(0, 8)) failed (HTTP $code)"
            }
        }
        Write-Note "deleted $deleted of $($candidates.Count)"
    }
}

# ── WAL. Independent of thread deletion: this changes only checkpoints.db.
if ($CheckpointWal) {
    Write-Host ''
    Write-Host 'WAL checkpoint' -ForegroundColor Cyan
    # sqlite3 CLI is NOT in the image (checked); the Python stdlib driver is, so
    # use it. TRUNCATE folds the WAL back into the main DB and shrinks the -wal.
    # A concurrent writer blocks it, which is why this reports the result rather
    # than assuming success.
    $db = '/app/backend/.deer-flow/checkpoints.db'
    $probe = @'
import sqlite3, os, sys
db = sys.argv[1]
for suffix in ('', '-wal'):
    p = db + suffix
    if os.path.exists(p):
        print("SIZE %s %d" % (suffix or 'db', os.path.getsize(p)))
try:
    c = sqlite3.connect(db)
    busy, log, checkpointed = c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    c.close()
    print("RESULT busy=%s wal_pages=%s checkpointed=%s" % (busy, log, checkpointed))
    if busy:
        print("NOTE a concurrent writer blocked the truncate; retry during a quiet window")
except Exception as e:
    print("ERROR %s" % str(e)[:200])
    raise SystemExit(1)
for suffix in ('', '-wal'):
    p = db + suffix
    if os.path.exists(p):
        print("AFTER %s %d" % (suffix or 'db', os.path.getsize(p)))
'@
    $out = Invoke-NativeCapture { $probe | docker exec -i $Container python - $db }
    foreach ($line in @($out)) {
        if ("$line" -match '^SIZE (\S+) (\d+)$') {
            Write-Note ("before: {0} = {1:N1} MB" -f $Matches[1], ([double]$Matches[2] / 1MB))
        }
        elseif ("$line" -match '^AFTER (\S+) (\d+)$') {
            Write-Ok ("after:  {0} = {1:N1} MB" -f $Matches[1], ([double]$Matches[2] / 1MB))
        }
        elseif ("$line" -match '^RESULT (.+)$') { Write-Note $Matches[1] }
        elseif ("$line" -match '^NOTE (.+)$') { Write-Warn2 $Matches[1] }
        elseif ("$line" -match '^ERROR (.+)$') { Write-Bad $Matches[1] }
    }
}
else {
    Write-Host ''
    Write-Note 'WAL not checked - pass -CheckpointWal to fold checkpoints.db-wal back into the DB'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: $($script:failures) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: ok' -ForegroundColor Green
exit 0
