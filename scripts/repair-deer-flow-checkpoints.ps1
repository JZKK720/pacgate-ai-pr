# Repair deer-flow's checkpoint store when thread creation fails with
# "database disk image is malformed".
#
# ROOT CAUSE THIS ADDRESSES (measured 2026-11-28)
#
#   POST /api/threads -> 500, from langgraph/checkpoint/sqlite/aio.py:aput:
#       sqlite3.DatabaseError: database disk image is malformed
#
# The tempting response - restore a backup, or delete the DB and let it recreate -
# throws away real checkpoint history for no reason. The evidence said the rows were
# fine:
#
#   checkpoints.db 2.78 GB, checkpoints.db-wal 1.17 GB
#   PRAGMA quick_check               -> ok
#   plain INSERT                     -> ok
#   realistic checkpoint INSERT      -> ok
#   PRAGMA wal_checkpoint(TRUNCATE)  -> (1, 1032, 1025)      <- busy=1, 7 frames stuck
#
# (busy, log_frames, checkpointed). busy=1 is SQLITE_BUSY: a reader held the file, so
# frames could not be merged and the WAL grew without bound. Once it is that large,
# a writer eventually sees unreadable pages and SQLite reports "malformed". The file
# was never corrupt - the WAL merge was blocked.
#
# With deer-flow stopped the same call returned (0, 0, 0), the WAL was truncated to
# nothing, thread creation went back to HTTP 200, and all rows were kept.
#
# WHAT THIS SCRIPT DOES
#   1. refuses to run while deer-flow is up (a live reader is what causes the busy)
#   2. backs up the db + wal to a timestamped directory, and verifies the copy
#   3. runs wal_checkpoint(TRUNCATE); a non-zero busy flag is reported loudly
#   4. runs quick_check and reports the result
#   5. leaves the database INTACT. It never deletes or rewrites rows.
#
# USAGE
#   pwsh -File scripts/repair-deer-flow-checkpoints.ps1
#   pwsh -File scripts/repair-deer-flow-checkpoints.ps1 -BackupDir D:\backups
#
# Exit codes: 0 repaired/healthy, 1 failed, 2 cannot check.

[CmdletBinding()]
param(
    [string]$Container = 'deer-flow',
    [string]$Image = 'ghcr.io/jzkk720/deer-flow-pacgate:0.3.0',
    [string]$BackupDir = (Join-Path $env:USERPROFILE ("pacgate-backup\deerflow-checkpoints-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    # Skip the container stop/start. Only correct if you know the app is already down.
    [switch]$AlreadyStopped
)

$ErrorActionPreference = 'Continue'

function Step($m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

$py  = '/app/backend/.venv/bin/python'
$db  = '/app/backend/.deer-flow/checkpoints.db'

# ── 1. refuse to run against a live database ────────────────────────────────
Step '1. Preconditions'
$wasRunning = $false
$state = (& docker inspect $Container --format '{{.State.Running}}' 2>$null | Out-String).Trim()
if ($state -eq 'true') {
    if ($AlreadyStopped) {
        Die "-AlreadyStopped was passed but $Container is running. A live reader is exactly what makes the checkpoint BUSY; stop it or drop the flag."
    }
    Write-Host "  stopping $Container (a live reader is what blocks the checkpoint)" -ForegroundColor DarkGray
    $null = & docker stop $Container 2>&1
    $wasRunning = $true
    Start-Sleep -Seconds 5
}
$state = (& docker inspect $Container --format '{{.State.Running}}' 2>$null | Out-String).Trim()
if ($state -eq 'true') { Die "$Container is still running - cannot checkpoint safely." }
Ok "$Container is stopped"

$exists = (& docker run --rm --volumes-from $Container --entrypoint sh $Image -c "test -f $db && echo yes" 2>$null | Out-String).Trim()
if ($exists -ne 'yes') { Write-Host "  exit 2 - $db not found" -ForegroundColor Yellow; exit 2 }
Ok "found $db"

# ── 2. back up before touching anything ─────────────────────────────────────
# The backup is the rollback. It is written BEFORE the checkpoint so a failed repair
# can always be undone, and it is verified so a truncated copy is not mistaken for one.
#
# Every measurement here runs in a THROWAWAY container over `--volumes-from`. It cannot
# use `docker exec`: step 1 guarantees the app is stopped, and `docker exec` against a
# stopped container fails, returns nothing, and the empty string then casts to 0. The
# first version of this script did exactly that and reported "backup size 2777534464
# != source 0"; the copy was complete and the source measurement was the lie.
Step '2. Backup db + wal, and verify it'
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
function OnVolume([string]$shellCommand) {
    ((& docker run --rm --volumes-from $Container --entrypoint sh $Image -c $shellCommand 2>$null | Out-String).Trim())
}

$walExists = (OnVolume "test -f $db-wal && echo yes")
if ($walExists -ne 'yes') {
    # Not fatal: a store that was checkpointed cleanly has no WAL at all. But say so,
    # because a missing WAL and an unreadable WAL look identical if this is silent.
    Write-Host '  no -wal file on the volume (already checkpointed, or cleanly shut down)' -ForegroundColor DarkGray
    $walExists = $null
}

$null = & docker cp "${Container}:$db" (Join-Path $BackupDir 'checkpoints.db') 2>&1
$srcBytes = 0
$srcRaw = OnVolume "stat -c %s $db 2>/dev/null || echo ''"
if (-not [int64]::TryParse($srcRaw, [ref]$srcBytes)) {
    Die "could not measure $db on the volume (got '$srcRaw'). The app is stopped, so every probe must go through --volumes-from, not docker exec."
}
if ($walExists) { $null = & docker cp "${Container}:$db-wal" (Join-Path $BackupDir 'checkpoints.db-wal') 2>&1 }

$bakFile = Join-Path $BackupDir 'checkpoints.db'
if (-not (Test-Path $bakFile)) { Die "the backup file was not written to $BackupDir" }
$bakBytes = (Get-Item $bakFile).Length
if ($bakBytes -ne $srcBytes) { Die "backup size $bakBytes != source $srcBytes - the copy is incomplete, not repairing" }
Ok ("backup verified: {0:N0} MB at {1}" -f ($bakBytes/1MB), $BackupDir)
if ($walExists) {
    $walBak = Join-Path $BackupDir 'checkpoints.db-wal'
    if (Test-Path $walBak) { Ok ("wal backed up too: {0:N0} MB (a checkpoint on a backed-up db can still be rolled back)" -f ((Get-Item $walBak).Length/1MB)) }
}

# ── 3. checkpoint the WAL. This is the actual repair. ────────────────────────
Step '3. wal_checkpoint(TRUNCATE)'
$probe = @'
import json, os, sqlite3, time
db = "/app/backend/.deer-flow/checkpoints.db"
res = {}
t = time.time()
try:
    c = sqlite3.connect(db, timeout=120, isolation_level=None)
    res["checkpoint"] = list(c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone())
    res["quick_check"] = c.execute("PRAGMA quick_check(50)").fetchone()[0]
    c.close()
except Exception as exc:
    res["error"] = type(exc).__name__ + ": " + str(exc)[:250]
res["elapsed_s"] = round(time.time() - t, 1)
# Key by SUFFIX, not basename: os.path.basename("/x/checkpoints.db") is "checkpoints.db",
# so a basename-keyed dict has no "db" member and "$r.db" silently renders as 0 MB for a
# 2.7 GB file. Reported "after: db 0 MB" on a store that had just passed quick_check.
for suffix in ("", "-wal", "-shm"):
    p = db + suffix
    res["db" + suffix] = os.path.getsize(p) if os.path.exists(p) else None
print(json.dumps(res))
'@
$pp = Join-Path ([System.IO.Path]::GetTempPath()) 'df-repair.py'
[System.IO.File]::WriteAllText($pp, $probe, (New-Object System.Text.UTF8Encoding($false)))

# A stopped container's entrypoint still works through `docker run --volumes-from`, and
# the script is mounted separately because --volumes-from only carries the data volume.
$hostTemp = $env:TEMP -replace '\\', '/'
$raw = (& docker run --rm --volumes-from $Container -v "${hostTemp}/df-repair.py:/tmp/df-repair.py:ro" --entrypoint $py $Image /tmp/df-repair.py 2>&1 | Out-String).Trim()
Remove-Item $pp -ErrorAction SilentlyContinue

$r = $null
try { $r = $raw | ConvertFrom-Json } catch { }
if ($null -eq $r) { Die "the repair probe did not return JSON: $raw" }
if ($r.error) { Die "checkpoint failed: $($r.error)" }

$busy = $r.checkpoint[0]
$frames = $r.checkpoint[1]
$done = $r.checkpoint[2]
if ($busy -ne 0) {
    Warn "wal_checkpoint returned busy=$busy ($done of $frames frames merged)."
    Warn 'Something still holds a reader. Re-run with the container confirmed down.'
}
else {
    Ok "wal_checkpoint(TRUNCATE) -> busy=0, $done of $frames frames merged, took $($r.elapsed_s)s"
}
if ($r.quick_check -eq 'ok') { Ok 'quick_check reports a sound file' }
else { Die "quick_check reported: $($r.quick_check). The rows are NOT fine - restore the backup at $BackupDir." }
Ok ("after: db {0:N0} MB, wal {1}" -f ($r.db/1MB), $(if ($null -eq $r.'db-wal') { 'absent' } else { "{0:N0} MB" -f ($r.'db-wal'/1MB) }))

# ── 4. bring the stack back the way it was found ─────────────────────────────
Step '4. Restore the previous running state'
if ($wasRunning) {
    $null = & docker start $Container 2>&1
    Start-Sleep -Seconds 30
    $health = (& docker inspect $Container --format '{{.State.Health.Status}}' 2>$null | Out-String).Trim()
    Ok "$Container restarted (health: $health)"
}
else { Ok "$Container was already stopped; left stopped" }

Write-Host ''
Write-Host 'Repaired. Verify with:  pwsh -File scripts/test-deer-flow-checkpoints.ps1' -ForegroundColor Green
Write-Host "Backup kept at: $BackupDir" -ForegroundColor DarkGray
exit 0
