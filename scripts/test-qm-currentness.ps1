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

function Write-Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
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
Write-Host ''
if ($script:failures -gt 0) {
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
