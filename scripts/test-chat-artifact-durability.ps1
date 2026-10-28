# Guard: a chat thread's deliverables must survive the run that produced them,
# and stay retrievable after that run has ended - including after a run killed by
# `Recursion limit reached`.
#
# WHY THIS EXISTS (measured 2026-10-28)
#
# Thread 93a11bec was killed twice by "Recursion limit of 1000 reached" (12:47 and
# 02:02, 115-117 LLM calls each). I had claimed such a run "loses its work". That
# claim was wrong, and the way it was wrong is worth pinning:
#
#   - outputs land PER THREAD at
#       /data/deer-flow/users/<user>/threads/<thread>/user-data/outputs
#     which sits on the /data bind mount, so they outlive both the run and the
#     container;
#   - after both kills, GET /api/threads/{id}/outputs still listed the files;
#   - the 1,846,347-byte PDF still downloaded intact from
#       GET /api/threads/{id}/artifacts/mnt/user-data/outputs/<file>
#     with Content-Type application/pdf and a real %PDF header.
#
# So a killed run is RECOVERABLE: the user re-prompts on the same thread and keeps
# the prior work. That property is what makes the recursion ceiling a bounded
# failure instead of a destructive one, and nothing in the suite asserted it.
#
# Related but distinct: test-format-coverage-e2e.ps1 asserts
# /api/documents/<id>/download (the sanitizer egress gate). This gate covers the
# CHAT artifact route, which is a different surface and had zero coverage.
#
# WHAT IS ASSERTED
#   A1 the /data mount is a host bind mount, so thread outputs are not ephemeral
#   A2 outputs live under user-data/outputs on that mount (not container-internal)
#   A3 at least one real artifact exists on disk from a completed run
#   A4 GET /api/threads/{id}/outputs lists artifacts for that thread
#   A5 the listed artifact DOWNLOADS with HTTP 200 and the right byte length
#   A6 the downloaded bytes are the real file (PDF magic, or md text)
#
# Exit codes: 0 = all pass; 1 = a real failure; 2 = cannot check (CANNOT CHECK)
#
# Usage:  pwsh -File scripts/test-chat-artifact-durability.ps1
#         pwsh -File scripts/test-chat-artifact-durability.ps1 -ThreadId <id>

[CmdletBinding()]
param(
    [string]$BaseUrl   = 'http://localhost:8089',
    [string]$EnvFile   = 'deploy/client-bundle/.deer-flow-credentials',
    [string]$ThreadId,
    [string]$DataRoot  = 'deploy/client-bundle/data/deer-flow'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:passed++ }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:failed++ }
function SkipIt($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Die($m, $c = 1) { Write-Host "`nCANNOT CHECK: $m" -ForegroundColor Yellow; exit $c }

# PS 5.1 turns ANY native stderr write into a terminating error once stderr is
# redirected, so docker/curl calls need the stderr preference parked at Continue
# for the duration of the call. This is the SAME body shape test-loop-detection-window.ps1
# uses, because test-ps51-native-stderr.ps1 pins native stderr by AST and allows only
# that exact form: it rejects a bare `2>&1` and does not walk function bodies, so a
# variant here is flagged as an unwrapped redirection. Keep it identical.
function Invoke-NativeCapture {    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

Write-Host '=== chat artifacts must survive the run that made them ===' -ForegroundColor Cyan

# ── A1: /data must be a host bind mount ──────────────────────────────────────
# NOTE the format string contains NO backslash. Windows PowerShell 5.1 re-escapes a
# `\n` inside a single-quoted docker --format argument, producing `{{\n}}`, which the
# Go template engine rejects with `template parsing error: unexpected "\\"`. The
# command then fails, Invoke-NativeCapture returns the error record, and the gate
# reported a false "no /data mount" failure while pwsh 7 passed. Use a `;` separator
# and split on it here instead.
$mounts = Invoke-NativeCapture { docker inspect deer-flow --format '{{range .Mounts}}{{.Type}}|{{.Destination}};{{end}}' }
if (-not $mounts) { Die 'deer-flow container not found - is the stack up?' 2 }
$flat = (@($mounts) -join '')
$dataMount = @($flat -split ';') | Where-Object { $_ -match '\|/data$' }
if (-not $dataMount) { Bad 'no mount at /data on deer-flow - thread outputs would be container-internal and lost on recreation' }
elseif ($dataMount -match '^bind\|') {
    Ok '/data is a host bind mount (thread outputs outlive the container)'
} else {
    Bad "/data is not a bind mount, it is: $dataMount - thread outputs would not survive recreation"
}

# ── A2: outputs live under user-data/outputs on that mount ───────────────────
$found = Invoke-NativeCapture { docker exec deer-flow sh -c 'find /data/deer-flow/users -maxdepth 5 -type d -name outputs 2>/dev/null | head -5' }
if (-not $found) { Bad 'no user-data/outputs directories under /data/deer-flow/users - the per-thread output layout moved; update this gate and the recursion-cap comment' }
else { Ok "per-thread outputs dirs present on the /data mount ($((@($found) | Where-Object { $_ }).Count) sampled)" }

# ── A3: at least one real artifact on disk ───────────────────────────────────
# Match real FILES, not just any path containing the substring. A bare
# `-path "*/user-data/outputs/*"` also matches `.tool-results` bookkeeping
# directories, which made an earlier draft pick a thread with zero artifacts and
# then report two false failures against it.
$diskFiles = Invoke-NativeCapture { docker exec deer-flow sh -c 'find /data/deer-flow/users -type f -path "*/user-data/outputs/*" -not -path "*/.tool-results/*" 2>/dev/null | head -20' }
$diskList  = @($diskFiles -split "`n" | Where-Object { $_ })
if ($diskList.Count -eq 0) { Bad 'no artifact files exist under any user-data/outputs - cannot prove durability on this box' }
else { Ok "real artifact files on disk ($($diskList.Count) sampled)" }


# ── authenticate ─────────────────────────────────────────────────────────────
if (-not (Test-Path $EnvFile)) { Die "credentials file not found: $EnvFile" 2 }
$email = $null; $password = $null
foreach ($line in Get-Content $EnvFile) {
    if ($line -match '^PACGATE_DEERFLOW_EMAIL=(.+)$')    { $email    = $Matches[1].Trim() }
    if ($line -match '^PACGATE_DEERFLOW_PASSWORD=(.+)$') { $password = $Matches[1].Trim() }
}
if (-not $email -or -not $password) { Die 'PACGATE_DEERFLOW_EMAIL / _PASSWORD missing from the credentials file' 2 }

try {
    $login = Invoke-WebRequest -Uri "$BaseUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = $email; password = $password } `
        -SessionVariable sess -UseBasicParsing -TimeoutSec 30
} catch { Die "deer-flow sign-in failed: $($_.Exception.Message) - start the stack, then re-run." 2 }
if ([int]$login.StatusCode -ne 200) { Die "deer-flow sign-in returned HTTP $([int]$login.StatusCode)" 2 }

# POSTs need the CSRF token from the login cookie, echoed as X-CSRF-Token.
# Without it /api/threads/search answers 403, which reads like an auth failure but
# is the CSRF gate - the same trap documented in test-legal-journey step 9.
$csrf = ($sess.Cookies.GetCookies($BaseUrl) | Where-Object { $_.Name -eq 'csrf_token' }).Value
$postHeaders = @{}
if ($csrf) { $postHeaders['X-CSRF-Token'] = $csrf }

# ── pick a thread the API itself reports artifacts for ───────────────────────
#
# Threads are listed with POST /api/threads/search (GET /api/threads is a 405).
# If -ThreadId was not supplied, walk the listed threads and take the first one
# whose outputs endpoint returns a non-empty file list. Guessing from disk was
# wrong: it can select a thread whose artifacts belong to another user, or one
# with no real files at all, and then fail against a correct API.
if (-not $ThreadId) {
    try {
        $search = Invoke-RestMethod -Uri "$BaseUrl/api/threads/search" -Method Post -WebSession $sess `
            -Headers $postHeaders -ContentType 'application/json' -Body '{"limit":50,"offset":0}' -TimeoutSec 30
    } catch { Die "POST /api/threads/search failed: $($_.Exception.Message)" 2 }

    $cands = @($search) 
    if ($cands.Count -eq 1 -and $cands[0].threads) { $cands = @($cands[0].threads) }

    foreach ($c in $cands) {
        $cid = $c.thread_id
        if (-not $cid) { continue }
        try {
            $probe = Invoke-RestMethod -Uri "$BaseUrl/api/threads/$cid/outputs" -WebSession $sess -TimeoutSec 20
            if (@($probe.files | Where-Object { $_ }).Count -gt 0) { $ThreadId = $cid; break }
        } catch { }
    }
    if (-not $ThreadId) {
        SkipIt 'no thread visible to this account currently reports any output file - nothing to assert'
        Write-Host ''
        Write-Host "RESULT: $passed check(s) passed, durability NOT exercised (no artifacts to test)" -ForegroundColor Yellow
        exit 2
    }
}
Write-Host "  thread under test: $ThreadId" -ForegroundColor DarkGray

# ── A4: the thread's outputs are LISTED by the API ───────────────────────────
try {
    $outs = Invoke-RestMethod -Uri "$BaseUrl/api/threads/$ThreadId/outputs" -WebSession $sess -TimeoutSec 30
} catch { Die "GET /api/threads/$ThreadId/outputs failed: $($_.Exception.Message)" 2 }

$files = @($outs.files | Where-Object { $_ })
if ($files.Count -eq 0) {
    Bad "GET /api/threads/$ThreadId/outputs listed nothing. Either the listing endpoint cannot see the per-thread outputs dir, or (if you passed -ThreadId) this thread genuinely produced no artifact."
} else {
    Ok "GET /api/threads/{id}/outputs lists $($files.Count) artifact(s)"
}

# ── A5 + A6: the artifact actually downloads, and is the real file ──────────
$target = $files | Where-Object { $_.artifact_url } | Select-Object -First 1
if (-not $target) {
    Bad 'no artifact carried an artifact_url - the client has no route to fetch it'
} else {
    try {
        $dl = Invoke-WebRequest -Uri "$BaseUrl$($target.artifact_url)" -WebSession $sess -UseBasicParsing -TimeoutSec 60
    } catch { $dl = $null; Bad "artifact download failed: $($_.Exception.Message)" }

    if ($dl) {
        if ([int]$dl.StatusCode -eq 200) { Ok "artifact downloads: HTTP 200 ($($target.filename))" }
        else { Bad "artifact download returned HTTP $([int]$dl.StatusCode)" }

        if ([int]$dl.RawContentLength -eq [int64]$target.size) {
            Ok "downloaded byte count matches the listed size ($($target.size) bytes)"
        } else {
            Bad "download is $($dl.RawContentLength) bytes but the listing says $($target.size) - truncated or stale"
        }

        # Real-file check: the bytes must be the format claimed, not an error page.
        if ($target.extension -eq '.pdf') {
            $isPdf = ($dl.Content.Length -ge 4 -and $dl.Content[0] -eq 0x25 -and $dl.Content[1] -eq 0x50 -and $dl.Content[2] -eq 0x44 -and $dl.Content[3] -eq 0x46)
            if ($isPdf) { Ok 'downloaded bytes are a real PDF (%PDF header)' }
            else { Bad 'download is not a PDF - an error page is being served under a .pdf name' }
        } else {
            $isText = $dl.Content.Length -gt 0
            if ($isText) { Ok "downloaded bytes are non-empty text ($($target.extension))" }
            else { Bad 'download is empty' }
        }
    }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host "RESULT: $passed of $passed checks passed - chat artifacts survive their run and stay retrievable." -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failed of $($passed + $failed) checks FAILED" -ForegroundColor Red
exit 1
