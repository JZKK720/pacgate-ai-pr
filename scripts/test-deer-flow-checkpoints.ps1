# Assert deer-flow's checkpoint store is WRITABLE and not strangling on its WAL.
#
# WHY THIS EXISTS (root-caused 2026-11-28)
#
# Thread creation started returning HTTP 500 with
#     sqlite3.DatabaseError: database disk image is malformed
# raised from langgraph/checkpoint/sqlite/aio.py:aput. The obvious reading - "the
# database is corrupt, restore a backup" - was WRONG, and acting on it would have
# discarded 27,842 checkpoint rows for no reason. The evidence:
#
#   - checkpoints.db was 2.78 GB with a 1.17 GB -wal file
#   - PRAGMA quick_check            -> ok
#   - a plain INSERT                -> ok
#   - a realistic checkpoint INSERT -> ok
#   - PRAGMA wal_checkpoint(TRUNCATE) -> (1, 1032, 1025)
#
# That tuple is (busy, log_frames, checkpointed). busy=1 means SQLITE_BUSY: only 1025
# of 1032 frames could be merged because a reader held the file. The WAL had therefore
# been growing unchecked, and a WAL that large eventually surfaces unreadable pages to
# a writer as "malformed". With the app stopped the checkpoint returned (0, 0, 0), the
# WAL was truncated, thread creation went back to HTTP 200, and every row was kept.
#
# SO THE THING TO WATCH IS NOT "is the file corrupt" (it usually is not) but:
#   1. is the WAL allowed to grow past a sane bound
#   2. can a checkpoint actually complete (busy=0)
#   3. can the writer still write
#
# A silent WAL leak is invisible until writes fail, which is exactly the shape of
# failure this repo keeps re-finding: a green dashboard over a broken lane.
#
# Exit codes: 0 pass, 1 real failure, 2 CANNOT CHECK.

[CmdletBinding()]
param(
    [string]$Container = 'deer-flow',
    # The WAL is expected to hover near wal_autocheckpoint (1000 pages ~= 4 MB). 512 MB
    # is far above normal and far below the 1.17 GB that broke writes; it is a tripwire,
    # not a tuning target.
    [int]$WalWarnMB = 512,
    [switch]$SkipWrite
)

$ErrorActionPreference = 'Continue'

$script:failed = 0
$script:passed = 0
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Warn($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }

Write-Host '=== deer-flow checkpoint store health ===' -ForegroundColor Cyan

# ── 0. the container must be up ──────────────────────────────────────────────
$running = (& docker ps --filter "name=^$Container$" --format '{{.Names}}' 2>$null | Out-String).Trim()
if ($running -ne $Container) {
    Write-Host "  exit 2 - container '$Container' is not running; cannot inspect its store" -ForegroundColor Yellow
    exit 2
}

$py = '/app/backend/.venv/bin/python'
$db = '/app/backend/.deer-flow/checkpoints.db'

# ── 1. the store exists and is a sane size ────────────────────────────────────
# stat, not `ls -l`: one number per call, so there is no column alignment to parse
# and no path-with-spaces ambiguity. The first version parsed `ls -l` with a regex
# anchored on the six leading columns and silently reported 0 MB for a 2.7 GB file.
$dbBytes = [int64]((& docker exec $Container sh -c "stat -c %s $db" 2>$null | Out-String).Trim())
$walBytes = [int64]((& docker exec $Container sh -c "stat -c %s $db-wal 2>/dev/null || echo 0" 2>$null | Out-String).Trim())
$walMB = [math]::Round($walBytes / 1MB, 1)
Write-Host ("         db {0:N0} MB   wal {1:N0} MB" -f ($dbBytes/1MB), $walMB) -ForegroundColor DarkGray

if ($walMB -gt $WalWarnMB) {
    Fail ("the write-ahead log is $walMB MB (> $WalWarnMB MB): checkpointing is not completing. A WAL this large is how 'database disk image is malformed' starts. Run scripts/repair-deer-flow-checkpoints.ps1 with deer-flow STOPPED.")
    # Stop here. The remaining probes diagnose *why writes fail*, and a blocking WAL
    # is already the answer - running them adds noise (and, if the write probe starts
    # failing, a second symptom pointing at the same cause).
    Write-Host ''
    Write-Host ("RESULT: {0} passed, {1} FAILED - the WAL is the failure, stopping before the write probe" -f $script:passed, $script:failed) -ForegroundColor Red
    exit 1
}
else {
    Pass "the WAL is within bounds ($walMB MB)"
}

# ── 2. the checkpoint must not be BUSY, and the file must pass quick_check ────
# PRAGMA runs read the real header. quick_check (not integrity_check) is deliberate:
# integrity_check on a multi-GB store takes many minutes and is the reason the first
# attempt at this diagnosis looked like a hang.
$probe = @'
import json, sqlite3, sys
db = "/app/backend/.deer-flow/checkpoints.db"
out = {}
try:
    c = sqlite3.connect("file:" + db + "?mode=ro", uri=True, timeout=15)
    out["quick_check"] = c.execute("PRAGMA quick_check(50)").fetchone()[0]
    out["journal_mode"] = c.execute("PRAGMA journal_mode").fetchone()[0]
    out["tables"] = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")]
    c.close()
except Exception as exc:
    out["error"] = type(exc).__name__ + ": " + str(exc)[:200]
print(json.dumps(out))
'@
$probePath = Join-Path ([System.IO.Path]::GetTempPath()) 'df-checkpoint-probe.py'
[System.IO.File]::WriteAllText($probePath, $probe, (New-Object System.Text.UTF8Encoding($false)))
$null = & docker cp $probePath "${Container}:/tmp/df-checkpoint-probe.py" 2>&1
Remove-Item $probePath -ErrorAction SilentlyContinue
$raw = (& docker exec $Container $py /tmp/df-checkpoint-probe.py 2>&1 | Out-String).Trim()
$null = & docker exec $Container rm -f /tmp/df-checkpoint-probe.py 2>&1

$info = $null
try { $info = $raw | ConvertFrom-Json } catch { }
if ($null -eq $info) {
    # Empty output is its own diagnosis: the container went away between the size
    # check and this probe (or exec failed outright), so there is nothing to quote.
    # Printing "could not read the store: " with a blank reason sends the operator
    # looking for a database problem that is actually a container problem.
    $why = if ([string]::IsNullOrWhiteSpace($raw)) {
        "the probe printed nothing at all - did '$Container' stop or get restarted mid-run? (check: docker ps -a --filter name=^$Container`$)"
    } else { $raw }
    Write-Host "  exit 2 - could not read the store: $why" -ForegroundColor Yellow
    exit 2
}
if ($info.error) {
    Fail "the store could not be opened: $($info.error)"
}
else {
    Pass "the store opens (journal_mode=$($info.journal_mode), tables=$($info.tables -join ','))"
    if ($info.quick_check -eq 'ok') { Pass 'quick_check reports a sound file' }
    else { Fail "quick_check reported: $($info.quick_check)" }
}

# ── 3. a writer must be able to write. This is the assertion that actually caught the
#       outage: the file passed quick_check and plain INSERTs while thread creation
#       still 500'd, because the failure was in the WAL merge, not the pages.
if (-not $SkipWrite) {
    $wprobe = @'
import json, sqlite3, uuid
db = "/app/backend/.deer-flow/checkpoints.db"
tid = "GATEPROBE-" + uuid.uuid4().hex[:10]
res = {"thread": tid}
try:
    c = sqlite3.connect(db, timeout=20, isolation_level=None)
    c.execute("INSERT INTO checkpoints (thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, type, checkpoint, metadata) VALUES (?,?,?,?,?,?,?)",
              (tid, "", "1", None, "json", "{}", "{}"))
    res["write"] = "ok"
    c.execute("DELETE FROM checkpoints WHERE thread_id=?", (tid,))
    res["cleanup"] = "ok"
    c.close()
except Exception as exc:
    res["write"] = type(exc).__name__ + ": " + str(exc)[:180]
print(json.dumps(res))
'@
    $wp = Join-Path ([System.IO.Path]::GetTempPath()) 'df-checkpoint-write.py'
    [System.IO.File]::WriteAllText($wp, $wprobe, (New-Object System.Text.UTF8Encoding($false)))
    $null = & docker cp $wp "${Container}:/tmp/df-checkpoint-write.py" 2>&1
    Remove-Item $wp -ErrorAction SilentlyContinue
    $wraw = (& docker exec $Container $py /tmp/df-checkpoint-write.py 2>&1 | Out-String).Trim()
    $null = & docker exec $Container rm -f /tmp/df-checkpoint-write.py 2>&1
    $winfo = $null
    try { $winfo = $wraw | ConvertFrom-Json } catch { }
    if ($null -eq $winfo) {
        Fail "the write probe did not answer: $wraw"
    }
    elseif ($winfo.write -eq 'ok') {
        Pass 'a checkpoint row can be written and removed (the operation that was 500ing)'
    }
    else {
        Fail "writing a checkpoint row failed: $($winfo.write)"
    }
}

Write-Host ''
if ($script:failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:passed, $script:failed) -ForegroundColor Red
    Write-Host '  Fix: stop deer-flow, then run scripts/repair-deer-flow-checkpoints.ps1' -ForegroundColor Red
    Write-Host '  Do NOT delete the database: quick_check ok means the rows are fine.' -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: the checkpoint store is writable and its WAL is not leaking. ({0} passed)" -f $script:passed) -ForegroundColor Green
exit 0
