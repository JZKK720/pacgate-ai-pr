# Guard: credentials SHARED between the Pacgate stack and the QM stack must agree.
#
# WHY THIS EXISTS (found 2026-10-17, v0.1.31).
#
# This deployment has TWO independent .env files, because the two stacks are two
# compose projects rooted at two directories:
#
#   deploy/client-bundle/.env                <- pacgate-api, deer-flow, nginx, db
#   deploy/client-bundle/qm-pacgate/.env     <- qm core/portal/auth/web-ui/admin
#
# `docker inspect` confirms the split:
#   pacgate-api        working_dir = C:\...\deploy\client-bundle
#   qm-pacgate-core    working_dir = C:\...\deploy\client-bundle\qm-pacgate
#
# Four variables appear in BOTH files. They are shared BY VALUE, not by reference:
# nothing in the repo synchronises them, no compose file shares an env_file, and
# the two files are separate blobs on disk.
#
#   OPENVIKING_ROOT_API_KEY
#   OPENVIKING_API_KEY
#   PACGATE_API_EMAIL
#   PACGATE_API_PASSWORD
#
# The last one DIVERGED. Measured on the live stack 2026-10-17:
#
#   client-bundle/.env            PACGATE_API_PASSWORD  16 chars  -> login 200
#   client-bundle/qm-pacgate/.env PACGATE_API_PASSWORD  24 chars  -> login 401
#   => qm-pacgate-core holds the 24-char value (FLY_RESIDENT_ENV_PACGATE_API_PASSWORD)
#
# Proved empirically, not inferred: POSTing each value to
# http://localhost:8089/pacgate/api/auth/login returned
#   the 16-char value -> 200 + a 283-char JWT
#   the 24-char value -> 401
#
# ROOT CAUSE, and why it is a CODE defect rather than a one-off slip:
# `setup-qm.ps1` obtains the bridge password from a parameter or an interactive
# Read-Host (see the `if ($BridgePassword) {...} else { Read-Host ... }` block) and
# then WRITES it into qm's .env. It never reads the credential the pacgate stack is
# already using. So the value is retyped by hand at setup time, and any later change
# on one side strands the other. Re-running setup-qm.ps1 does not heal it either: its
# login probe uses the NEW value, so it fails against the old account and the script
# reports "the first sandbox tool call will 401" as a WARNING while still exiting.
#
# WHY IT HID FOR SO LONG: the other three shared keys agree. qm's OpenViking access
# works, its portal/auth work, every container reports healthy - and `ollama ps`,
# health checks and the 39-gate suite all stay green, because the suite drives
# pacgate-api over HTTP with PACGATE_API_PASSWORD from client-bundle/.env. The suite
# has no test that crosses the stack boundary, so the one broken edge was invisible.
# Only the pacgate tools INSIDE a qm sandbox were affected - and those fail at the
# far end of a chain that begins with an authenticated API call.
#
# WHAT IT CHECKS
#   C1  every key present in BOTH .env files has an identical value   (the defect)
#   C2  each stack's LIVE container agrees with its own .env           (advisory:
#       detects "file fixed but container not recreated")
#
# Values are NEVER printed. Only a truncated SHA-256 and a length, because this
# workspace has already had one incident where env values reached the output
# (deploy/INCIDENT-2026-10-04-qm-sandbox-env-printed.md). A guard for a credential
# bug must not leak the credential while reporting it.
#
# Exit codes: 0 = agree;  1 = a shared key diverged;  2 = cannot check
#
# Usage:  pwsh -File scripts/test-cross-stack-credentials.ps1
#         pwsh -File scripts/test-cross-stack-credentials.ps1 -SkipLive

[CmdletBinding()]
param(
    [string]$PacgateEnv = 'deploy/client-bundle/.env',
    [string]$QmEnv      = 'deploy/client-bundle/qm-pacgate/.env',
    # Skip the live-container half. Useful where docker is unavailable.
    [switch]$SkipLive
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$script:failures = 0
$script:warnings = 0

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [warn] $m" -ForegroundColor Yellow; $script:warnings++ }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }

# A stable, non-reversible tag for a secret: enough to tell "same" from "different",
# useless to anyone reading the output. NEVER return or echo the value itself.
function Get-SecretTag([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '<empty>' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($s)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 12)
    } finally { $sha.Dispose() }
}

function Read-EnvFile([string]$path) {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        # Skip comments and blanks, matching docker compose's own .env parsing
        # closely enough for a comparison: compose ignores `#` lines.
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $map[$Matches[1]] = $Matches[2]
        }
    }
    return $map
}

function Get-LiveEnvMap([string]$container) {
    $m = @{}
    $raw = docker inspect $container --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($l in $raw) {
        if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $m[$Matches[1]] = $Matches[2] }
    }
    return $m
}

Write-Host '=== credentials shared across the Pacgate and QM stacks agree ==='

$pacPath = Join-Path $repoRoot $PacgateEnv
$qmPath  = Join-Path $repoRoot $QmEnv

Write-Host ''
Write-Host '  sources' -ForegroundColor DarkGray
Write-Host "    pacgate : $PacgateEnv" -ForegroundColor DarkGray
Write-Host "    qm      : $QmEnv" -ForegroundColor DarkGray

$pac = Read-EnvFile $pacPath
$qm  = Read-EnvFile $qmPath

if ($null -eq $pac -or $null -eq $qm) {
    $missing = @()
    if ($null -eq $pac) { $missing += $PacgateEnv }
    if ($null -eq $qm)  { $missing += $QmEnv }
    Write-Host ''
    Write-Host "CANNOT CHECK: env file(s) not present: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host '  These are gitignored, per-machine, and created by install.ps1 / setup-qm.ps1.' -ForegroundColor DarkGray
    Write-Host '  A fresh clone legitimately has neither, so this is not a failure.' -ForegroundColor DarkGray
    exit 2
}

# ---------------------------------------------------------------------------
# C1. Shared keys must agree.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'C1  keys present in BOTH files' -ForegroundColor Cyan

$shared = @($pac.Keys | Where-Object { $qm.Contains($_) } | Sort-Object)

if ($shared.Count -eq 0) {
    Write-Fail 'the two files share NO keys - the shared-credential contract has changed, review this guard'
} else {
    Write-Host "    $($shared.Count) shared key(s): $($shared -join ', ')" -ForegroundColor DarkGray
    foreach ($k in $shared) {
        $a = Get-SecretTag $pac[$k]
        $b = Get-SecretTag $qm[$k]
        if ($a -ceq $b) {
            Write-Pass "$k : identical (tag $a, $($pac[$k].Length) chars)"
        } else {
            Write-Fail "$k : DIVERGED - pacgate tag $a ($($pac[$k].Length) chars) vs qm tag $b ($($qm[$k].Length) chars)"
        }
    }
}

# ---------------------------------------------------------------------------
# C2. Live containers vs their own .env.
#
# This is the half that distinguishes "the file is wrong" from "the file is right
# but the container was never recreated". Both produce the same 401, and only this
# check tells them apart - `docker compose restart` re-reads .env, but an
# already-running container keeps the environment it was CREATED with.
#
# Advisory (warning), because a stopped stack is a normal state for a dev box and
# must not redden the suite.
# ---------------------------------------------------------------------------
$liveChecks = @(
    @{ label = 'pacgate-api';        file = 'pacgate'; envKey = 'PACGATE_API_PASSWORD'; liveKey = 'PACGATE_API_PASSWORD' },
    @{ label = 'qm-pacgate-core';    file = 'qm';      envKey = 'PACGATE_API_PASSWORD'; liveKey = 'FLY_RESIDENT_ENV_PACGATE_API_PASSWORD' }
)

if ($SkipLive) {
    Write-Host ''
    Write-Host 'C2  skipped (-SkipLive)' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host 'C2  live containers agree with their own .env' -ForegroundColor Cyan
    $anyLive = $false
    foreach ($c in $liveChecks) {
        $live = Get-LiveEnvMap $c.label
        if ($null -eq $live) {
            Write-Warn "$($c.label) not running - cannot compare (start the stack to check)"
            continue
        }
        $anyLive = $true
        $fileMap = if ($c.file -eq 'pacgate') { $pac } else { $qm }
        $fromFile = $fileMap[$c.envKey]
        $fromLive = $live[$c.liveKey]
        $tf = Get-SecretTag $fromFile
        $tl = Get-SecretTag $fromLive
        if ($tf -ceq $tl) {
            Write-Pass "$($c.label) : live matches $($c.file).env (tag $tl)"
        } else {
            Write-Warn "$($c.label) : live tag $tl != $($c.file).env tag $tf - the container was created before the file changed; recreate it to apply"
        }
    }
    if (-not $anyLive) { Write-Warn 'neither container was running - C2 not evaluated' }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAIL: $($script:failures) credential(s) shared across the two stacks have diverged." -ForegroundColor Red
    Write-Host ''
    Write-Host '  WHICH VALUE IS RIGHT: the one the account was actually created with. Prove it,' -ForegroundColor DarkGray
    Write-Host '  do not guess - a login probe settles it. POST the candidate value to' -ForegroundColor DarkGray
    Write-Host '  <pacgate-api>/api/auth/login as JSON { email, password }.' -ForegroundColor DarkGray
    Write-Host '  200 + a token = that value is the live one. 401 = it is the stale one.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Then set the shared key in BOTH files to the working value, and RECREATE the' -ForegroundColor DarkGray
    Write-Host '  affected container - `restart` alone keeps the old environment.' -ForegroundColor DarkGray
    Write-Host '    cd deploy/client-bundle/qm-pacgate' -ForegroundColor DarkGray
    Write-Host '    docker compose -f compose.qm.yaml up -d --force-recreate core' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Root cause to fix, or this returns: setup-qm.ps1 takes the bridge password' -ForegroundColor DarkGray
    Write-Host "  from a parameter/prompt and writes it to qm's .env WITHOUT reading what the" -ForegroundColor DarkGray
    Write-Host '  pacgate stack already uses. See the note at the top of this script.' -ForegroundColor DarkGray
    exit 1
}

Write-Host "RESULT: every shared credential agrees across both stacks. ($($script:warnings) warning(s))" -ForegroundColor Green
exit 0
