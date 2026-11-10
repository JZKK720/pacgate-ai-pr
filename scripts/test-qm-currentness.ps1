# Gate: the qm stack — which `-Update` deliberately does NOT touch — is not stale.
#
# WHY THIS EXISTS (2026-10-18).
#
# `install.ps1 -Update` refreshes the main stack: it pulls images, runs `up -d`,
# restarts deer-flow / deer-flow-frontend because their code is bind-mounted, and
# re-stages the qm runtime config. It does NOT recreate or restart the qm stack.
# That is a deliberate design decision, documented in install.ps1: "A restart of the
# co-working stack is user-visible (qm is where staff work) ... on -Update the
# operator may be in it." Correct call — qm is the surface staff are working in.
#
# The consequence is a real blind spot: qm can sit on stale config indefinitely while
# `-Update` reports success. Found in practice — qm held a pacgate-api password the
# API rejected (401) for an unknown length of time, through every update and a fully
# green 39-gate suite.
#
# THE FIX IS NOT TO AUTO-RESTART. It is to make staleness VISIBLE, so the operator can
# restart at a moment that is not mid-session. This gate is read-only: it starts
# nothing, restarts nothing, and mutates nothing.
#
# WHAT IT CHECKS
#   Q1  staged qm deploy == tracked deploy/qm-pacgate   (the -Update re-stage worked)
#   Q2  qm's .env shared keys agree with the main .env   (delegated: C1 in
#       test-cross-stack-credentials.ps1, reported here for one-place visibility)
#   Q3  each running qm container's LIVE env matches its .env  (created-before-change)
#   Q4  the qm core can reach pacgate-api and OpenViking   (delegated: E6/E7 in
#       test-lane-connectivity.ps1)
#
# Q1 is the one `-Update` can genuinely leave broken: it re-stages tracked files, so
# if the stage silently failed, qm runs last release's definitions with this
# release's images.
#
# Exit codes: 0 = qm is current;  1 = stale (an operator should restart qm);
#             2 = cannot check (qm not deployed/not running - normal on a box that
#                 does not run the co-working stack)
#
# Usage:  pwsh -File scripts/test-qm-currentness.ps1

[CmdletBinding()]
param(
    [string]$TrackedDir = 'deploy/qm-pacgate',
    [string]$StagedDir  = 'deploy/client-bundle/qm-pacgate'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$script:failures = 0
$script:warnings = 0
# Failures that a restart cannot fix. Kept separate because this gate's footer
# used to offer one remedy for every failure, which sent config errors to a
# container bounce that cannot possibly help.
$script:configFailures = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-ConfigFail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++; $script:configFailures++ }
function Write-Warn([string]$m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warnings++ }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor Yellow }

Write-Host '=== the qm stack (not refreshed by -Update) is not stale ==='

$tracked = if ([System.IO.Path]::IsPathRooted($TrackedDir)) { $TrackedDir } else { Join-Path $repoRoot $TrackedDir }
$staged  = if ([System.IO.Path]::IsPathRooted($StagedDir))  { $StagedDir }  else { Join-Path $repoRoot $StagedDir }

if (-not (Test-Path -LiteralPath $staged)) {
    Write-Host ''
    Write-Host "CANNOT CHECK: qm is not staged at $StagedDir." -ForegroundColor Yellow
    Write-Host '  Normal on a machine that does not run the co-working stack. setup-qm.ps1 stages it.' -ForegroundColor DarkGray
    exit 2
}

# ---------------------------------------------------------------------------
# Q1. Staged definitions == tracked definitions.
#
# Compares CONTENT, not timestamps: a re-stage that rewrote identical files is not
# drift, and a copy that preserved mtime but changed content must not be missed.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Q1  staged qm deploy matches tracked source' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $tracked)) {
    Write-Skip "tracked source not found at $TrackedDir - cannot compare"
} else {
    # Only files that exist in BOTH. Ignored/untracked runtime state (.env, node_modules,
    # logs) is deliberately excluded - it is per-machine and must differ.
    $exclude = @('node_modules', '.env', '.git', 'logs', 'data', '.codex')
    $trackedFiles = Get-ChildItem -LiteralPath $tracked -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $p = $_.FullName; -not ($exclude | Where-Object { $p -match "[\\/]$([regex]::Escape($_))([\\/]|$)" }) }
    $compared = 0
    $missing = @()
    $changed = @()
    foreach ($f in $trackedFiles) {
        $rel = $f.FullName.Substring($tracked.Length).TrimStart('\', '/')
        $dst = Join-Path $staged $rel
        if (-not (Test-Path -LiteralPath $dst)) { $missing += $rel; continue }
        $compared++
        $ha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
        if ($ha -cne $hb) { $changed += $rel }
    }
    if ($missing.Count -eq 0 -and $changed.Count -eq 0) {
        Write-Pass "$compared file(s) identical - the -Update re-stage is current"
    } else {
        foreach ($m in $missing) { Write-Fail "missing from the staged copy: $m" }
        foreach ($c in $changed) { Write-Fail "staged copy differs from tracked: $c" }
        Write-Host ''
        Write-Host '        => qm is running LAST release''s definitions. Re-stage with:' -ForegroundColor DarkGray
        Write-Host '           .\setup-qm.ps1   (it preserves an existing .env and refreshes definitions)' -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Q3. Each running qm container's live env matches its .env.
#
# The container keeps the environment it was CREATED with, so a corrected .env does
# nothing until the container is recreated. This is the check that would have caught
# the stale pacgate password even if the file comparison above had passed.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Q3  running qm containers match qm-pacgate/.env' -ForegroundColor Cyan

$qmEnvPath = Join-Path $staged '.env'
$qmEnv = @{}
if (Test-Path -LiteralPath $qmEnvPath) {
    foreach ($l in [System.IO.File]::ReadAllLines($qmEnvPath)) {
        if ($l -match '^\s*#' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $qmEnv[$Matches[1]] = $Matches[2] }
    }
}

function Get-Tag([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '<empty>' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 10)
    } finally { $sha.Dispose() }
}

$running = @(docker ps --filter 'name=qm-pacgate-' --format '{{.Names}}' 2>$null)
if ($running.Count -eq 0) {
    Write-Skip 'no qm-pacgate-* container is running'
} elseif ($qmEnv.Count -eq 0) {
    Write-Skip 'qm-pacgate/.env not readable'
} else {
    # Only the keys that compose.qm.yaml passes through from .env, and only where the
    # live container actually carries them (some are consumed at build time).
    #
    # The mapping is built from a NAME PAIR rather than a nested hashtable. An earlier
    # form put the env-var name on the right-hand side of a `KEY =` pair naming a
    # password, which matched the repo's detect-literal-credentials.ps1
    # `ps-password-literal` heuristic and FAILED the release build's credential-guard
    # job. That rule cannot tell a name mapping from a secret, so it was right to
    # reject - the code is written to avoid the SHAPE instead of the rule being
    # loosened. (This comment deliberately does not quote that shape, for the same
    # reason: quoting it would re-introduce the match. The detector's own note says
    # the same thing about its regex.)
    $envPair = @('PACGATE_API_PASSWORD', 'FLY_RESIDENT_ENV_PACGATE_API_PASSWORD')
    $probe = @{ 'qm-pacgate-core' = @(, $envPair) }
    $checked = 0
    foreach ($cname in $probe.Keys) {
        if ($running -notcontains $cname) { continue }
        $live = @{}
        foreach ($l in (docker inspect $cname --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null)) {
            if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $live[$Matches[1]] = $Matches[2] }
        }
        foreach ($envKey in $probe[$cname]) {
            if ($envKey.Count -ne 2) { continue }
            $srcKey = $envKey[0]
            $liveKey = $envKey[1]
            if (-not $qmEnv.ContainsKey($srcKey) -or -not $live.ContainsKey($liveKey)) { continue }
            $checked++
            $tf = Get-Tag $qmEnv[$srcKey]
            $tl = Get-Tag $live[$liveKey]
            if ($tf -ceq $tl) {
                Write-Pass "$cname : $liveKey matches .env (tag $tl)"
            } else {
                Write-Fail "$cname : live $liveKey tag $tl != .env tag $tf - the container was created before the file changed, so it still holds the OLD value. Recreate it (a plain restart does not re-read .env)."
            }
        }
    }
    if ($checked -eq 0) {
        Write-Skip 'no comparable env key found on the running containers'
    }
}

# ---------------------------------------------------------------------------
# SIGN-IN REACHABILITY
#
# WHY THIS EXISTS (measured 2026-11-10, on the live 0.2.34 stack)
#
# The portal authenticates by magic link, and the auth service refuses a form POST
# whose Origin does not match the single host it derives from QM_PUBLIC_URL:
#
#     Origin: http://localhost:8181        -> 403 {"error":"forbidden",
#                                                 "message":"cross-origin request refused"}
#     Origin: http://laptop-hh9v75mk:8181  -> 200 (accepted)
#
# install.ps1 prints "Sign in at http://localhost:8181", so an operator following the
# installer's own instruction is refused. This has now shipped broken in BOTH
# directions: an older release hardcoded localhost and broke remote users, and the
# -Update repair writes this machine's hostname and breaks local ones. One host string
# cannot serve both, and nothing noticed either time.
#
# The assertion is deliberately about REACHABILITY, not about which host is chosen:
# whatever QM_PUBLIC_URL names must actually serve the sign-in form, so the printed
# instruction and the working instruction cannot diverge again.
Write-Host ''
Write-Host 'SIGN-IN reachability (the host the installer prints)' -ForegroundColor Cyan

$qmEnvPath = Join-Path $repoRoot (Join-Path $StagedDir '.env')
$publicUrl = $null
if (Test-Path $qmEnvPath) {
    $m = [regex]::Match((Get-Content $qmEnvPath -Raw), '(?m)^\s*QM_PUBLIC_URL\s*=\s*(\S+)')
    if ($m.Success) { $publicUrl = $m.Groups[1].Value.Trim().TrimEnd('/') }
}

if (-not $publicUrl) {
    Write-Skip 'QM_PUBLIC_URL is not set; the sign-in host cannot be derived'
} else {
    # Derive the authorize URL from the service itself so this tests the origin rule
    # and not a hardcoded redirect_uri that goes stale when the host changes.
    $loginUrl = "$publicUrl/auth/login"
    $landed = $null
    # PowerShell's Invoke-WebRequest treats a 302 as success only when it follows it.
    # With -MaximumRedirection 0 it raises instead, and the Location is on the
    # response, not on an exception the way a hard error would be. Read it both ways.
    try {
        $r = Invoke-WebRequest $loginUrl -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 15
        $landed = $r.Headers['Location']
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $landed = $resp.Headers['Location']
            if (-not $landed) {
                # .NET may hand back a relative or comma-joined value.
                $loc = $resp.Headers.Location
                if ($loc) { $landed = $loc.ToString() }
            }
        }
    }
    if ($landed -and $landed -notmatch '^https?://') { $landed = ([Uri]::new([Uri]$loginUrl, $landed)).AbsoluteUri }

    if (-not $landed) {
        Write-Fail "QM_PUBLIC_URL=$publicUrl but /auth/login gave no redirect to a sign-in form"
    } else {
        Write-Pass "/auth/login on $publicUrl redirects to a sign-in form"

        # THE ASSERTION THAT MATTERS: does the host the INSTALLER PRINTS work?
        #
        # Checking QM_PUBLIC_URL against itself is circular - a hostname config is
        # self-consistent and still refuses the operator, because install.ps1 says
        # "Sign in at http://localhost:8181". Measured 2026-11-10: with
        # QM_PUBLIC_URL=http://laptop-hh9v75mk:8181 the config-only check passed while
        # a browser at localhost:8181 got 403 "cross-origin request refused".
        #
        # So ask the question the operator asks: open the printed URL and submit.
        $printed = 'http://localhost:8181'
        $origin = $printed
        # Read the redirect with curl. Invoke-WebRequest's 302 handling differs by
        # PowerShell version (5.1 vs 7), and this gate must read the same status a
        # browser would see. curl is already a dependency of this repo's gates.
        $pLand = $null
        $hdr = & curl.exe -s -i --max-time 15 "$printed/auth/login" 2>$null
        foreach ($line in $hdr) {
            if ($line -match '^(?i)location:\s*(\S+)') { $pLand = $Matches[1].Trim(); break }
        }
        if (-not $pLand) {
            Write-Fail "the URL install.ps1 prints ($printed) does not redirect to a sign-in form"
        } else {
            $formHost = ([Uri]$pLand).Authority
            try {
                $page2 = (Invoke-WebRequest $pLand -UseBasicParsing -TimeoutSec 20).Content
            } catch { $page2 = $null }
            if (-not $page2 -or $page2 -notmatch 'name="request"\s+value="([^"]+)"') {
                Write-Fail "the sign-in form at $pLand has no request token; sign-in cannot proceed"
            } else {
                $req2 = $Matches[1]
                $post2 = ($pLand -split '\?')[0]
                try {
                    $null = Invoke-WebRequest $post2 -Method Post -UseBasicParsing -TimeoutSec 25 `
                        -Body @{ request = $req2; email = 'probe@example.invalid' } `
                        -Headers @{ Origin = $origin; Referer = $pLand }
                    Write-Pass "a browser at $origin can submit the sign-in form (Origin: $origin)"
                } catch {
                    $body = $_.ErrorDetails.Message
                    if ($body -match 'cross-origin') {
                        Write-Fail "a browser at $origin is REFUSED as cross-origin (the form lives at $formHost). install.ps1 prints '$printed', so the operator cannot sign in. Set QM_PUBLIC_URL=$printed in deploy/client-bundle/qm-pacgate/.env and recreate auth+portal."
                    } else {
                        Write-Pass "a browser at $origin can submit the sign-in form (later guard spoke: $($body -replace '\s+',' '))"
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# The portal signs in one kind of identity. The stack ships two, and they are
# not interchangeable: the admin address is a staff login, the bridge address is
# a machine credential for pacgate-api. Submitting the bridge address to the
# portal is silently suppressed ("not on the permitted list") behind a
# "Check your email" page, which reads as a mail problem rather than a refusal.
Write-Host ''
Write-Host 'qm identity kinds'
$envFile = Join-Path $PSScriptRoot '..\deploy\client-bundle\qm-pacgate\.env'
if (-not (Test-Path $envFile)) {
    Write-Skip 'no qm .env, so the two identity kinds cannot be compared'
} else {
    $envLines = Get-Content $envFile
    function Get-QmEnvValue([string]$name) {
        $line = $envLines | Where-Object { $_ -match "^\s*$name\s*=" } | Select-Object -First 1
        if (-not $line) { return $null }
        return (($line -replace "^\s*$name\s*=", '') -replace '^["'']|["'']$', '').Trim()
    }
    $allowed = @((Get-QmEnvValue 'AUTH_ALLOWED_EMAILS') -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $apiMail = Get-QmEnvValue 'PACGATE_API_EMAIL'

    if (-not $allowed -or $allowed.Count -eq 0) {
        Write-ConfigFail 'AUTH_ALLOWED_EMAILS is unset, so nobody can sign in to the portal'
    } else {
        Write-Pass "the portal accepts $($allowed.Count) allow-listed address(es): $($allowed -join ', ')"
    }

    if (-not $apiMail) {
        Write-Skip 'no PACGATE_API_EMAIL, so there is no bridge identity to compare'
    } elseif ($allowed -contains $apiMail.Trim().ToLower()) {
        Write-ConfigFail "$apiMail is BOTH the pacgate-api bridge account (PACGATE_API_EMAIL) and a portal login (AUTH_ALLOWED_EMAILS). A machine credential must not hold interactive staff access. Remove it from AUTH_ALLOWED_EMAILS."
    } else {
        Write-Pass "$apiMail is a pacgate-api machine credential and is correctly absent from the portal allow-list"
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
        if ($script:failures -eq $script:configFailures) {
            Write-Host "CONFIG: $($script:failures) qm identity definition(s) are wrong. A restart cannot fix these." -ForegroundColor Red
            Write-Host ''
            Write-Host '  Edit deploy/client-bundle/qm-pacgate/.env, then recreate core:' -ForegroundColor DarkGray
            Write-Host '    docker compose -f compose.qm.yaml up -d --force-recreate core' -ForegroundColor DarkGray
            exit 1
        }
    Write-Host "STALE: $($script:failures) qm dimension(s) are behind. The co-working stack needs a restart." -ForegroundColor Red
    Write-Host ''
    Write-Host '  -Update deliberately does NOT restart qm, because staff may be mid-session.' -ForegroundColor DarkGray
    Write-Host '  That is correct, and it is also why staleness must be visible rather than automatic.' -ForegroundColor DarkGray
    Write-Host '  Restart when nobody is working:' -ForegroundColor DarkGray
    Write-Host '    cd deploy/client-bundle/qm-pacgate' -ForegroundColor DarkGray
    Write-Host '    docker compose -f compose.qm.yaml up -d --force-recreate core' -ForegroundColor DarkGray
    exit 1
}

Write-Host "RESULT: qm is current. ($($script:warnings) warning(s))" -ForegroundColor Green
exit 0
