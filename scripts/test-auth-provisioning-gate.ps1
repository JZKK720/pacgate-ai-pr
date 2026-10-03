# Gate: pacgate-api's account-provisioning surface must be closed in both
# directions.
#
# WHY THIS EXISTS. Closing `POST /api/auth/register` to first-user-only fixed a
# real exposure, but nothing was committed that proves the routes behave. The
# unit tests in `crates/pacgate-api/src/auth.rs` cover the ROLE DECISION
# (`bootstrap_roles`, `resolve_assignable_role`) and cannot see the router at
# all - so if `/api/auth/users` were ever moved below the auth middleware, or
# `/api/auth/register` lost its gate, every Rust test would still pass.
#
# That is the highest-risk untested area of the change, because the two ways it
# can fail are both silent:
#   * the provisioning route slips onto the PUBLIC router  -> open account
#     creation, the original defect, restored;
#   * the provisioning route is dropped or mis-registered   -> 404 on a fresh
#     install, so the qm bridge account is never created and Runtime 3 is dead.
#
# This asserts the DESIRED behaviour, so it FAILS before 0.1.22 is deployed (the
# route returns 404 on the 0.1.21 image) and PASSES after. That is the point:
# a RED result here is the release gate, not a flaky test.
#
# It also proves the role boundary end to end, which no unit test can: an account
# created through the admin route must NOT come out as a platform admin. That is
# the defect where the installer's "admin" was really an attorney, inverted - a
# created attorney that is secretly an administrator would be worse.
#
# CLEANUP CONTRACT: this script creates a real probe account to test with. It
# deletes that account in a `finally` block and verifies the row is gone. It never
# leaves an account behind, and it never touches a pre-existing account.
#
# Usage:
#   pwsh -File scripts/test-auth-provisioning-gate.ps1
#
# Exit: 0 = both routes behave correctly
#       1 = a gate is missing or broken
#       2 = CANNOT CHECK (stack not running) - not a failure, see $liveStackGates
#           in scripts/run-all-checks.ps1

[CmdletBinding()]
param(
    # nginx ingress port. pacgate-api publishes no host port of its own, so this
    # is the only way in - and it is the path an attacker on the LAN would use.
    [int]$Port = 8089,
    [string]$Prefix = 'pacgate',
    [string]$Container = 'pacgate-db'
)

$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}

$BaseUrl = "http://localhost:$Port/$Prefix"

# A probe identity unique per run, so a leaked row is identifiable in the DB.
$stamp          = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$probeEmail     = "provprobe-$stamp@pacgateprobe.com"
$probePassword  = "ProvProbe-Passw0rd!$stamp"

Write-Host "=== pacgate-api account-provisioning gate ===" -ForegroundColor Cyan
Write-Host "  target: $BaseUrl" -ForegroundColor Gray

# ── Preflight: is the stack even up? ─────────────────────────────────────────
# Exit 2 (CANNOT CHECK) rather than 1. A gate that fails when nothing is running
# trains people to ignore it, and then it cannot warn them when something is.
$preflight = $null
try {
    $preflight = Invoke-WebRequest -Uri "$BaseUrl/health" -TimeoutSec 10 -SkipHttpErrorCheck
} catch { }
if (-not $preflight -or $preflight.StatusCode -ne 200) {
    Write-Host "[SKIP] CANNOT CHECK: $BaseUrl/health is not answering." -ForegroundColor Yellow
    Write-Host "       Start the stack (.\deploy\client-bundle\install.ps1) and re-run." -ForegroundColor Yellow
    exit 2
}
Write-Host "  [OK] stack is up" -ForegroundColor Green

# ── Admin credentials, from the deployment's own .env ───────────────────────
$envPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.env'
if (-not (Test-Path $envPath)) {
    Write-Host "[SKIP] CANNOT CHECK: $envPath not found." -ForegroundColor Yellow
    exit 2
}
$adminEmail = ''; $adminPass = ''
foreach ($line in (Get-Content -LiteralPath $envPath)) {
    if     ($line -match '^\s*PACGATE_API_EMAIL\s*=\s*(.+)$')    { $adminEmail = $Matches[1].Trim() }
    elseif ($line -match '^\s*PACGATE_API_PASSWORD\s*=\s*(.+)$') { $adminPass  = $Matches[1].Trim() }
}
if (-not $adminEmail -or -not $adminPass) {
    Write-Host "[SKIP] CANNOT CHECK: PACGATE_API_EMAIL/PASSWORD missing from .env." -ForegroundColor Yellow
    exit 2
}

# Returns the response object, or $null on a transport failure. Status codes are
# read from the object, never inferred from an exception message.
function Invoke-Probe {
    param([string]$Method, [string]$Uri, $Headers, $Body)
    $p = @{ Uri = $Uri; Method = $Method; SkipHttpErrorCheck = $true; TimeoutSec = 20 }
    if ($Headers) { $p.Headers = $Headers }
    if ($Body)    { $p.Body = $Body; $p.ContentType = 'application/json' }
    try { return Invoke-WebRequest @p } catch { return $null }
}

function Remove-ProbeAccount {
    if (-not $probeEmail) { return }
    $sql = "DELETE FROM users WHERE email = '$probeEmail';"
    $out = docker exec $Container psql -U pacgate -d pacgate -t -c $sql 2>&1
    Write-Host "  cleanup: $($out -join ' ')" -ForegroundColor DarkGray
}

$created = $false
try {
    # ── 1. WHAT THIS SCRIPT CANNOT SEE (stated, so nobody assumes it) ───────
    #
    # An earlier version of this script asserted "POST /api/auth/users without a
    # token returns 401" and PASSED. That pass was worthless. nginx fronts the API
    # and answers 401 for ANY unauthenticated path - a request to a deliberately
    # nonexistent route (/api/definitely-not-a-route-xyz) also returns 401. So that
    # assertion could not distinguish "the route exists and is protected" from "the
    # route does not exist at all", and it would have stayed green if the route were
    # moved to the PUBLIC router, which is the exact failure it claimed to catch.
    #
    # A test that passes for the wrong reason is worse than no test, so that check is
    # REMOVED rather than kept as decoration. The public-router risk is real and is
    # covered elsewhere:
    #   * in the router source - `/api/auth/users` is registered BEFORE the
    #     `.layer(middleware::from_fn_with_state(..., auth_middleware))` call in
    #     pacgate-api/src/lib.rs, so axum applies the middleware to it;
    #   * by reading `auth_middleware`, which skips only /health,
    #     /api/auth/login and /api/auth/register.
    # What would close it from this side is a Rust test that builds the real router
    # and sends an unauthenticated request to it; that needs an AppState, and
    # `pg://connect_lazy` does not make AppState constructible without stubs for
    # the agent loop, LLM router, tool dispatcher and stores. That test does not
    # exist. Recorded as an open gap rather than papered over.

    # ── 1b. What IS discriminating: does the route exist at all? ────────────
    #
    # With a valid token nginx passes the request through, so the status code is the
    # ROUTER's answer: 404 means the running image has no such route, 2xx means it
    # does. This is the release gate - it is red against 0.1.21 and green after 0.1.22.
    $login = Invoke-Probe -Method Post -Uri "$BaseUrl/api/auth/login" `
        -Body (@{ email = $adminEmail; password = $adminPass } | ConvertTo-Json -Compress)
    if ($null -eq $login -or $login.StatusCode -ne 200) {
        Check 'admin can log in' $false "got HTTP $($login.StatusCode)"
        throw 'cannot continue without an admin token'
    }
    $adminTok = ($login.Content | ConvertFrom-Json).token
    Check 'admin can log in' $true

    # ── 2. First-user-only on the public register route ─────────────────────
    #
    # Users certainly exist by now (the admin), so an anonymous self-registration
    # MUST be refused. This is the original defect's gate, and - unlike the removed
    # check above - it IS discriminating: nginx forwards /api/auth/register
    # unauthenticated by design, so the 200-vs-403 decision is the API's.
    $reg = Invoke-Probe -Method Post -Uri "$BaseUrl/api/auth/register" `
        -Body (@{ email = $probeEmail; password = $probePassword } | ConvertTo-Json -Compress)
    if ($null -ne $reg) {
        Check 'POST /api/auth/register is refused once a user exists' ($reg.StatusCode -eq 403) `
            "got HTTP $($reg.StatusCode); expected 403. A 2xx means open registration is BACK and it created a real account."
    }
    else {
        Check 'POST /api/auth/register is refused once a user exists' $false 'transport failure'
    }

    # An administrator is a PLATFORM admin, not merely a tenant admin. This is the
    # assertion that catches a regression to the pre-fix state where the installer
    # created role='attorney', system_role='user' and called it an admin.
    $me = Invoke-Probe -Method Get -Uri "$BaseUrl/api/auth/me" -Headers @{ Authorization = "Bearer $adminTok" }
    $adminSystemRole = if ($me) { ($me.Content | ConvertFrom-Json).system_role } else { '<none>' }
    Check 'the bootstrap admin holds the platform admin role' ($adminSystemRole -eq 'admin') `
        "system_role='$adminSystemRole'; 'user' here means the installer's admin cannot provision anything"

    $create = Invoke-Probe -Method Post -Uri "$BaseUrl/api/auth/users" `
        -Headers @{ Authorization = "Bearer $adminTok" } `
        -Body (@{ email = $probeEmail; password = $probePassword; role = 'attorney' } | ConvertTo-Json -Compress)
    if ($null -ne $create -and $create.StatusCode -ge 200 -and $create.StatusCode -lt 300) {
        $created = $true
        Check 'an administrator can create an account' $true
    }
    else {
        Check 'an administrator can create an account' $false "got HTTP $($create.StatusCode)"
    }

    # ── 4. A created account must NOT be a platform admin ───────────────────
    #
    # The inverse of the original defect, and the reason this is worth testing
    # over HTTP: only an end-to-end path proves what system_role actually landed
    # in the row, which is what every authorization check keys on.
    if ($created) {
        $probeLogin = Invoke-Probe -Method Post -Uri "$BaseUrl/api/auth/login" `
            -Body (@{ email = $probeEmail; password = $probePassword } | ConvertTo-Json -Compress)
        if ($null -ne $probeLogin -and $probeLogin.StatusCode -eq 200) {
            Check 'the created account can log in' $true
            $probeTok = ($probeLogin.Content | ConvertFrom-Json).token

            $probeMe = Invoke-Probe -Method Get -Uri "$BaseUrl/api/auth/me" -Headers @{ Authorization = "Bearer $probeTok" }
            $probeSystemRole = if ($probeMe) { ($probeMe.Content | ConvertFrom-Json).system_role } else { '<none>' }
            Check 'the created account is NOT a platform admin' ($probeSystemRole -ne 'admin') `
                "system_role='$probeSystemRole'; an admin here means the role boundary is inverted - a provisioned attorney that can mint accounts"

            # ── 5. That non-admin must be refused at the provisioning route ──
            $escalate = Invoke-Probe -Method Post -Uri "$BaseUrl/api/auth/users" `
                -Headers @{ Authorization = "Bearer $probeTok" } `
                -Body (@{ email = "escalate-$stamp@pacgateprobe.com"; password = $probePassword } | ConvertTo-Json -Compress)
            Check 'a non-admin cannot create accounts' ($null -ne $escalate -and $escalate.StatusCode -eq 403) `
                "got HTTP $($escalate.StatusCode); anything 2xx is a privilege escalation"
        }
        else {
            Check 'the created account can log in' $false "got HTTP $($probeLogin.StatusCode)"
        }
    }
}
catch {
    Write-Host "  [FAIL] aborted: $($_.Exception.Message)" -ForegroundColor Red
    $script:fail++
}
finally {
    Remove-ProbeAccount
}

# ── Cleanup verification ─────────────────────────────────────────────────────
# Asserted, not assumed: a probe account left behind is a real account with a
# password this script just wrote to the console.
$remaining = (docker exec $Container psql -U pacgate -d pacgate -t -A -c `
    "SELECT count(*) FROM users WHERE email = '$probeEmail';" 2>&1 | Out-String).Trim()
Check 'the probe account was removed' ($remaining -eq '0') "rows remaining: $remaining"

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "RESULT: $($script:pass) passed, 0 failed" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $($script:pass) passed, $($script:fail) FAILED" -ForegroundColor Red
exit 1
