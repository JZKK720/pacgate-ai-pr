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

$pacPath = if ([System.IO.Path]::IsPathRooted($PacgateEnv)) { $PacgateEnv } else { Join-Path $repoRoot $PacgateEnv }
$qmPath  = if ([System.IO.Path]::IsPathRooted($QmEnv)) { $QmEnv } else { Join-Path $repoRoot $QmEnv }

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

# PACGATE_API_EMAIL / PACGATE_API_PASSWORD are an IDENTITY, not a shared secret,
# and the two files are SUPPOSED to differ.
#
# `setup-qm.ps1` says it explicitly (line ~162): "THE BRIDGE IS A SEPARATE,
# LEAST-PRIVILEGE SERVICE ACCOUNT ... because the sandbox runs model-directed tool
# calls, so it gets its own attorney-scoped credential". So client-bundle/.env
# holds the DEPLOYMENT ADMIN and qm-pacgate/.env holds the BRIDGE. Requiring them
# to be byte-identical demanded that the bridge be an admin.
#
# Found 2026-10-19 on a clean install: this check failed with
#   PACGATE_API_EMAIL    DIVERGED - pacgate 21 chars vs qm 22 chars
#   PACGATE_API_PASSWORD DIVERGED - pacgate 32 chars vs qm 21 chars
# while BOTH identities authenticated (admin 200, bridge 200). The check was
# wrong, not the deployment - it would only pass if the bridge were the admin,
# which is the over-privileged state the design avoids.
#
# What actually matters is that each file's identity AUTHENTICATES, so those two
# are verified against pacgate-api under C4b below. Everything else here is a
# genuinely shared value (OpenViking keys) and must still match exactly.
$identityKeys = @('PACGATE_API_EMAIL', 'PACGATE_API_PASSWORD')

$shared = @($pac.Keys | Where-Object { $qm.Contains($_) } | Sort-Object)

if ($shared.Count -eq 0) {
    Write-Fail 'the two files share NO keys - the shared-credential contract has changed, review this guard'
} else {
    Write-Host "    $($shared.Count) shared key(s): $($shared -join ', ')" -ForegroundColor DarkGray
    foreach ($k in $shared) {
        if ($identityKeys -contains $k) {
            # Report the shape so a reader can see it is intentional, never the value.
            Write-Host ("    [ .. ] {0} differs by design: pacgate={1} chars, qm={2} chars (admin vs bridge account)" -f `
                $k, $pac[$k].Length, $qm[$k].Length) -ForegroundColor DarkGray
            continue
        }
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
# C1b. Every identity the two files declare must actually authenticate.
#
# This replaces "the values are identical" with the property that matters. A
# bridge password that differs from the admin is fine; a bridge password that no
# longer logs in is the 2026-10-17 defect and must fail.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'C1b each stack identity authenticates to pacgate-api' -ForegroundColor Cyan

function Test-Login([string]$baseUrl, [string]$email, [string]$password) {
    if (-not $email -or -not $password) { return -1 }
    $probe = Join-Path $env:TEMP ("xs-probe-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, (@{ email = $email; password = $password } | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
        Invoke-RestMethod -Uri "$baseUrl/api/auth/login" -Method Post -ContentType 'application/json' -InFile $probe -TimeoutSec 15 | Out-Null
        return 200
    }
    catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return -1
    }
    finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
}

$apiBase = 'http://localhost:8089/pacgate'
if ($SkipLive) {
    Write-Host '    skipped (-SkipLive)' -ForegroundColor DarkGray
}
else {
    foreach ($pair in @(
        @{ label = 'pacgate (deployment admin)'; email = $pac['PACGATE_API_EMAIL']; pass = $pac['PACGATE_API_PASSWORD'] },
        @{ label = 'qm      (bridge account)';   email = $qm['PACGATE_API_EMAIL'];  pass = $qm['PACGATE_API_PASSWORD'] }
    )) {
        $status = Test-Login $apiBase $pair.email $pair.pass
        if ($status -eq 200) {
            Write-Pass "$($pair.label) : login 200"
        }
        elseif ($status -eq -1) {
            Write-Warn "$($pair.label) : pacgate-api unreachable - cannot verify"
        }
        else {
            Write-Fail "$($pair.label) : login $status - this identity does not work against pacgate-api"
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
# C3. The OpenViking client key must EQUAL the root key.
#
# This is a different failure from C1, and it is the one that stays invisible the
# longest: both .env files can agree with each other perfectly and still hold a key
# that authenticates with nothing.
#
# Found 2026-10-18 on the live stack. ov.conf.template declares only `root_api_key`
# - no per-client key is ever registered in the service. So a separately generated
# OPENVIKING_API_KEY is a key that does not exist:
#
#   POST /mcp, X-API-Key = a distinct OPENVIKING_API_KEY  -> 401 Invalid API Key
#   POST /mcp, X-API-Key = the ROOT key                   -> 200 + the tool list
#
# .env.example already documents the correct value - "API key clients use to call
# OpenViking (can equal root key in pilot)" - so equality is the contract, not a
# workaround. install.ps1 documents the same defect for the deer-flow template
# (~line 504: "NOT ${OPENVIKING_API_KEY} ... makes openviking return 401 and rolls
# back the entire MCP tool load"). deer-flow was fixed there; the qm path was not.
#
# Why nobody noticed: OpenViking's /health needs no key, so a connectivity check
# passes. Every qm ov-* sandbox tool fails at call time instead.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'C3  OpenViking client key equals the root key' -ForegroundColor Cyan

$ovChecked = 0
foreach ($pair in @(@{ label = 'pacgate'; map = $pac }, @{ label = 'qm     '; map = $qm })) {
    $m = $pair.map
    if (-not $m.Contains('OPENVIKING_ROOT_API_KEY') -or -not $m.Contains('OPENVIKING_API_KEY')) {
        Write-Warn "$($pair.label) : one or both OPENVIKING_*_API_KEY keys absent - cannot compare"
        continue
    }
    $ovChecked++
    $rootTag = Get-SecretTag $m['OPENVIKING_ROOT_API_KEY']
    $apiTag  = Get-SecretTag $m['OPENVIKING_API_KEY']
    if ($rootTag -ceq $apiTag) {
        Write-Pass "$($pair.label) : OPENVIKING_API_KEY == OPENVIKING_ROOT_API_KEY (tag $apiTag)"
    } else {
        Write-Fail "$($pair.label) : OPENVIKING_API_KEY (tag $apiTag) != OPENVIKING_ROOT_API_KEY (tag $rootTag) - no per-client key is registered in OpenViking, so the client key cannot authenticate; set it equal to the root key"
    }
}

# ---------------------------------------------------------------------------
# C4. Live proof: the client key actually authenticates to /mcp.
#
# C3 is a static contract check; this is the behavioural one. Advisory, because a
# stopped OpenViking is normal on a dev box and must not redden the suite.
#
# /health is deliberately NOT used here: it needs no key, so it passes even when
# every tool call 401s. That property is precisely what hid this defect.
# ---------------------------------------------------------------------------
if ($SkipLive) {
    Write-Host ''
    Write-Host 'C4  skipped (-SkipLive)' -ForegroundColor DarkGray
} else {
    Write-Host ''
    Write-Host 'C4  the client key authenticates to OpenViking /mcp' -ForegroundColor Cyan
    $ovUrl = 'http://localhost:1933/mcp'
    $mcpBody = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    $probed = 0
    foreach ($pair in @(@{ label = 'pacgate'; key = $(if ($pac.Contains('OPENVIKING_API_KEY')) { $pac['OPENVIKING_API_KEY'] } else { $null }) },
                        @{ label = 'qm     '; key = $(if ($qm.Contains('OPENVIKING_API_KEY')) { $qm['OPENVIKING_API_KEY'] } else { $null }) })) {
        if (-not $pair.key) { continue }
        try {
            $resp = Invoke-WebRequest -Uri $ovUrl -Method Post -Body $mcpBody -ContentType 'application/json' `
                -Headers @{ 'Accept' = 'application/json, text/event-stream'; 'X-API-Key' = $pair.key } `
                -TimeoutSec 12 -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                Write-Pass "$($pair.label) : /mcp accepted OPENVIKING_API_KEY (HTTP 200)"
            } else {
                Write-Warn "$($pair.label) : /mcp returned HTTP $($resp.StatusCode)"
            }
            $probed++
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = $_.Exception.Response.StatusCode.value__ }
            if ($code -eq 401) {
                Write-Fail "$($pair.label) : /mcp REJECTED OPENVIKING_API_KEY with 401 Invalid API Key"
                $probed++
            } else {
                Write-Warn "$($pair.label) : OpenViking not reachable at $ovUrl (HTTP $code) - start it to check"
            }
        }
    }
    if ($probed -eq 0) { Write-Warn 'OpenViking was not reachable - C4 not evaluated' }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAIL: $($script:failures) credential problem(s) across the two stacks." -ForegroundColor Red
    Write-Host ''
    Write-Host '  WHICH VALUE IS RIGHT: the one the account was actually created with. Prove it,' -ForegroundColor DarkGray
    Write-Host '  do not guess - a login probe settles it. POST the candidate value to' -ForegroundColor DarkGray
    Write-Host '  <pacgate-api>/api/auth/login as JSON { email, password }.' -ForegroundColor DarkGray
    Write-Host '  200 + a token = that value is the live one. 401 = it is the stale one.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  For C3: set OPENVIKING_API_KEY equal to OPENVIKING_ROOT_API_KEY in BOTH files' -ForegroundColor DarkGray
    Write-Host '  (the documented pilot contract - no per-client key exists in the service).' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Then RECREATE the affected containers - `restart` keeps the old environment.' -ForegroundColor DarkGray
    Write-Host '    cd deploy/client-bundle/qm-pacgate' -ForegroundColor DarkGray
    Write-Host '    docker compose -f compose.qm.yaml up -d --force-recreate --no-deps core' -ForegroundColor DarkGray
    Write-Host '    cd ..' -ForegroundColor DarkGray
    Write-Host '    docker compose -f compose.bundle.yaml up -d --force-recreate --no-deps pacgate-api openviking' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Root cause to fix, or this returns: setup-qm.ps1 takes the bridge password' -ForegroundColor DarkGray
    Write-Host "  from a parameter/prompt and writes it to qm's .env WITHOUT reading what the" -ForegroundColor DarkGray
    Write-Host '  pacgate stack already uses. See the note at the top of this script.' -ForegroundColor DarkGray
    exit 1
}

Write-Host "RESULT: every shared credential agrees across both stacks. ($($script:warnings) warning(s))" -ForegroundColor Green
exit 0
