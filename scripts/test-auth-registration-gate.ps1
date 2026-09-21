# Test: the deer-flow frontend must NOT allow open self-registration.
#
# THE DEFECT (verified 2026-09-21): v2.0.0's `/api/v1/auth/register` has no gate.
# It creates a `user` account for anyone who reaches the URL and sets the session
# cookie, auto-logging them in. `auth/config.py` at v2.0.0 models only jwt_secret,
# token_expiry_days and GitHub OAuth - there is no registration field to set.
# Upstream added `auth.local.allow_registration` in 2.1.0 (#4311).
#
# This test asserts the DESIRED behaviour, so it FAILS before the gate exists
# (RED) and PASSES after (GREEN).
#
# CLEANUP CONTRACT: the RED phase must create a real account to prove the endpoint
# is open. This test therefore deletes any probe user it creates, and verifies the
# row is gone. It never leaves an account behind.
#
# Usage:
#   pwsh -File scripts/test-auth-registration-gate.ps1
#   pwsh -File scripts/test-auth-registration-gate.ps1 -Port 8089
#
# Exit: 0 = gate works (registration refused, nothing created)
#       1 = gate missing or broken

[CmdletBinding()]
param(
    # nginx ingress port. The frontend also publishes 8090:3000 directly, which
    # BYPASSES nginx - both are tested so the bypass cannot hide behind the gate.
    [int[]]$Ports = @(8089, 8090),
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }; $script:fail++ }
}

# Unique probe identity per run, so a leaked row is identifiable.
$stamp   = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$probeEmail = "gate-probe-$stamp@pacgateprobe.com"
# Meets v2.0.0 policy: >=8 chars, not in the common-password blocklist.
$probePassword = 'GateProbe-Passw0rd!' + $stamp.Substring(8)

Write-Host '=== auth registration gate ===' -ForegroundColor White
Write-Host "  probe email : $probeEmail"
Write-Host "  ports       : $($Ports -join ', ')"
Write-Host ''

# ── helper: inspect the deer-flow user store ─────────────────────────────────
# The SQL is kept in a PYTHON FILE copied into the container rather than inline.
# Inline `docker exec python -c "...sql..."` needs nested PS/Python/SQL quoting and
# produced a parser error on the first attempt - the same class of failure already
# recorded for `node -e` / `sh -c`. A file has no quoting layer.
$pySource = @'
import sqlite3, sys
DB = "/app/backend/.deer-flow/data/deerflow.db"
cmd = sys.argv[1] if len(sys.argv) > 1 else "count"
con = sqlite3.connect(DB)
try:
    if cmd == "count":
        print(con.execute("select count(*) from users").fetchone()[0])
    elif cmd == "delete":
        cur = con.execute("delete from users where email = ?", (sys.argv[2],))
        con.commit()
        print(cur.rowcount)
    else:
        print("unknown command", file=sys.stderr); sys.exit(2)
finally:
    con.close()
'@

$pyLocal = Join-Path $env:TEMP "gate_probe_$stamp.py"
[System.IO.File]::WriteAllText($pyLocal, $pySource, (New-Object System.Text.UTF8Encoding($false)))

$script:pyReady = $false
function Initialize-ProbeHelper {
    if ($script:pyReady) { return $true }
    & docker cp $pyLocal "${Container}:/tmp/gate_probe.py" > $null 2>&1
    $script:pyReady = $true
    return $true
}

function Get-UserCount {
    [void](Initialize-ProbeHelper)
    $out = & docker exec $Container python /tmp/gate_probe.py count 2>&1
    $n = ($out | Select-Object -First 1).ToString().Trim()
    if ($n -match '^\d+$') { return [int]$n }
    return -1
}

function Remove-ProbeUser($email) {
    [void](Initialize-ProbeHelper)
    $out = & docker exec $Container python /tmp/gate_probe.py delete $email 2>&1
    return ($out | Select-Object -First 1).ToString().Trim()
}

# ── 1. Preconditions ────────────────────────────────────────────────────────
Write-Host '=== 1. preconditions ===' -ForegroundColor Cyan
$running = (& docker ps --format '{{.Names}}' 2>&1) -contains $Container
Check "container '$Container' is running" $running "start the stack before running this test"
if (-not $running) { Write-Host ''; Write-Host "RESULT: cannot run without the stack." -ForegroundColor Red; exit 1 }

$usersBefore = Get-UserCount
Check 'user count readable from deerflow.db' ($usersBefore -ge 0) "got '$usersBefore'"
Write-Host "  users before: $usersBefore"

# ── 2. /setup-status still reachable (regression guard) ─────────────────────
Write-Host ''
Write-Host '=== 2. unauthenticated public endpoints still work ===' -ForegroundColor Cyan
foreach ($port in $Ports) {
    $code = (& curl.exe -s -o NUL -w '%{http_code}' "http://localhost:$port/api/v1/auth/setup-status" 2>&1 | Out-String).Trim()
    Check ":$port /setup-status == 200" ($code -eq '200') "got $code"
}

# ── 3. THE ASSERTION: valid registration must be REFUSED ────────────────────
Write-Host ''
Write-Host '=== 3. self-registration must be refused (the gate) ===' -ForegroundColor Cyan

$body = @{ email = $probeEmail; password = $probePassword } | ConvertTo-Json -Compress
$tmp  = Join-Path $env:TEMP "gate-probe-$stamp.json"
[System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))

foreach ($port in $Ports) {
    $base = "http://localhost:$port"
    $out = & curl.exe -s -o - -w "`nHTTP_STATUS:%{http_code}" `
        -X POST "$base/api/v1/auth/register" `
        -H 'Content-Type: application/json' `
        -H "Origin: $base" `
        -H "Referer: $base/login" `
        --data "@$tmp" 2>&1
    $text = ($out | Out-String).Trim()
    $code = if ($text -match 'HTTP_STATUS:(\d+)') { $Matches[1] } else { 'none' }
    $detail = ($text -split "`n" | Select-Object -First 1)

    Check ":$port POST /register (valid payload) == 403" ($code -eq '403') "got $code :: $detail"
}

# ── 4. No side effect: nothing was created ──────────────────────────────────
Write-Host ''
Write-Host '=== 4. no account was created ===' -ForegroundColor Cyan
$usersAfter = Get-UserCount
Check "user count unchanged ($usersBefore -> $usersAfter)" ($usersAfter -eq $usersBefore) `
      'registration created an account despite the expected refusal'

# Defensive cleanup: if the pre-gate behaviour created a row, remove it.
if ($usersAfter -gt $usersBefore) {
    Write-Host '  (cleaning up a probe account created during RED phase)' -ForegroundColor Yellow
    [void](Remove-ProbeUser $probeEmail)
    $fixed = Get-UserCount
    Check "probe account removed ($usersAfter -> $fixed)" ($fixed -eq $usersBefore) "cleanup failed - check for $probeEmail"
}

Remove-Item $tmp -Force -ErrorAction SilentlyContinue

# ── 5. Login still works (the gate must not break sign-in) ──────────────────
Write-Host ''
Write-Host '=== 5. sign-in is unaffected ===' -ForegroundColor Cyan
$port0 = $Ports[0]
$base0 = "http://localhost:$port0"
# /login/local uses OAuth2PasswordRequestForm - FORM data, not JSON. Sending JSON
# yields 422 (validation), not 401, which is a misleading assertion for a gate
# test: 422 proves nothing about whether the gate leaked into login.
$out2 = & curl.exe -s -o - -w "`nHTTP_STATUS:%{http_code}" `
    -X POST "$base0/api/v1/auth/login/local" `
    -H 'Content-Type: application/x-www-form-urlencoded' `
    -H "Origin: $base0" `
    --data 'username=nobody@pacgateprobe.com&password=definitely-wrong-password' 2>&1
$t2 = ($out2 | Out-String)
$code2 = if ($t2 -match 'HTTP_STATUS:(\d+)') { $Matches[1] } else { 'none' }

# WHAT THIS ASSERTS, and what it must NOT assert.
#
# The point is only that the registration gate did not LEAK into the sign-in
# path. That is proven by the request reaching the credential check at all.
#
#   401 = credential check reached, rejected the bad password   -> PASS
#   429 = _check_rate_limit() engaged (see deer-flow-auth.py
#         _MAX_LOGIN_ATTEMPTS / _LOCKOUT_SECONDS). The login handler runs
#         _check_rate_limit() BEFORE verifying credentials, so a 429 also
#         proves the sign-in path was reached and not blocked by the gate.
#         It is a SUCCESS for this assertion, not a failure.
#   403 = the gate leaked into login                              -> FAIL
#   422 = wrong body shape (JSON instead of form)                 -> test defect
#
# A prior version asserted `-eq '401'` exactly. That false-failed whenever the
# limiter was engaged - including when a real user mistypes their password
# twice (the limit is reached after 5 failures, 5-minute lockout, per-IP).
# Observed 2026-09-22: repeated bad-credential probes pushed the probe IP to
# 429 and the suite reported "GATE MISSING OR BROKEN" on a healthy gate.
# A test that reads green-but-flaky as a security failure trains people to
# ignore it, so 429 is accepted here explicitly.
$okLogin = ($code2 -eq '401') -or ($code2 -eq '429')
Check ":$port0 POST /login/local (bad creds, form) == 401 or 429, NOT 403" $okLogin `
      "got $code2 - 403 means the gate leaked into login; 422 means wrong body shape; 429 means the login rate limiter engaged (still proves the path was reached)"
if ($code2 -eq '429') {
    # NOTE: do not try to interpolate the Python constants here. The patch's
    # names happen to look like PowerShell variables, but "$_MAX_LOGIN_ATTEMPTS"
    # resolves to the automatic variable $_ plus literal text, so it renders
    # empty. Reference them as plain text.
    Write-Host "  note: this probe IP is currently rate-limited (deer-flow-auth.py:" -ForegroundColor DarkGray
    Write-Host "        _MAX_LOGIN_ATTEMPTS / _LOCKOUT_SECONDS = 300). Not a failure." -ForegroundColor DarkGray
}

# ── Result ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host "  passed: $script:pass   failed: $script:fail"
if ($script:fail -gt 0) {
    Write-Host 'RESULT: GATE MISSING OR BROKEN - self-registration is reachable.' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: registration is refused on every tested port, nothing created, login intact.' -ForegroundColor Green
exit 0
