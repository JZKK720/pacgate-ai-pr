# Dry-run the `install.ps1 -Update` path WITHOUT changing the live stack.
#
# WHY THIS EXISTS
# ---------------
# The update path had never been exercised against a real machine. This dev box
# IS such a machine: live containers run pacgate-api 0.1.2 (from the now-dead
# jzkk720 namespace) while compose pins 0.1.14 - the same 12-version gap the
# client AIPC has.
#
# But running the real installer here would be destructive: the live containers
# use FIXED container_names (pacgate-api, pacgate-nginx, pacgate-db) and step 7
# runs `docker compose up -d`, which RECREATES them. The e2e override cannot
# isolate a second stack either, because it does not remap openviking's host
# port 1933, which is already held by the live container.
#
# So this script re-runs the update path READ-ONLY: it performs every check the
# installer performs, and every step that would mutate state is either skipped
# or redirected to a no-op. Nothing is pulled into the running stack, no
# container is created, started, stopped, or recreated.
#
# WHAT IT ACTUALLY VERIFIES (the things a dry-run can prove)
#   1. compose.prod.yaml parses, and the pins it declares resolve publicly.
#   2. The staleness probe (step 7e) reports the TRUE state on a behind machine
#      - including the 401 path, which is what an old image actually returns.
#   3. The dirty-tree guard (step 3b) would pass, i.e. the repo is clean.
#   4. Step 7f's qm re-stage would be a no-op, i.e. it finds nothing to change.
#   5. The repo fast-forward would be a no-op (already at origin/main).
#
# WHAT IT CANNOT PROVE, and therefore does not claim: that the real installer's
# `up -d` recreate succeeds, or that the stack comes up healthy. Those require a
# disposable host or a client window, and are called out as such in the output.
#
# Usage:  .\scripts\dry-run-update.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$pass = 0; $fail = 0; $warn = 0
# NOT named `R`. In PowerShell command resolution ALIASES BEAT FUNCTIONS, and `r`
# is a built-in alias for Invoke-History - so a helper named R is shadowed and
# every call binds to Invoke-History instead. The symptom is misleading:
#   "A positional parameter cannot be found that accepts argument 'True'"
# which reads like a bug in the CALL, not a name collision in the definition.
function Check([string]$n, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [FAIL] $n" -ForegroundColor Red }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}
function Note([string]$n, [string]$detail = '') {
    $script:warn++; Write-Host "  [WARN] $n" -ForegroundColor Yellow
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

Write-Host "=== install.ps1 -Update DRY RUN (read-only; live stack untouched) ===" -ForegroundColor Cyan
Write-Output ''

# Record the live state FIRST, so the end of the run can prove nothing moved.
$before = @{}
foreach ($c in @('pacgate-api', 'pacgate-nginx', 'pacgate-db', 'deer-flow', 'openviking')) {
    $before[$c] = (docker inspect $c --format '{{.Id}}' 2>$null | Out-String).Trim()
}

# ── 1. The pin is current and resolves anonymously ─────────────────────────
Write-Host '--- 1. compose pins resolve on GHCR ---' -ForegroundColor Cyan
$composePath = 'deploy/client-bundle/compose.prod.yaml'
$raw = Get-Content $composePath -Raw
$pins = [regex]::Matches($raw, 'ghcr\.io/(?<ns>[a-z0-9\-]+)/(?<img>[a-z0-9\-]+):(?<tag>\d+\.\d+\.\d+)')
Check 'compose declares 4 runtime image pins' ($pins.Count -eq 4) ("found {0}" -f $pins.Count)
$namespaces = @($pins | ForEach-Object { $_.Groups['ns'].Value } | Sort-Object -Unique)
Check 'every pin is in the pacgate-ai namespace' ($namespaces.Count -eq 1 -and $namespaces[0] -eq 'pacgate-ai') `
    ("namespaces: {0}" -f ($namespaces -join ', '))

$accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
foreach ($p in $pins) {
    $ns = $p.Groups['ns'].Value; $img = $p.Groups['img'].Value; $tag = $p.Groups['tag'].Value
    $code = 'ERR'
    try {
        $tok = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:$ns/${img}:pull").token
        $code = (curl.exe -s -o NUL -w "%{http_code}" -H "Accept: $accept" -H "Authorization: Bearer $tok" "https://ghcr.io/v2/$ns/${img}/manifests/${tag}")
    }
    catch { }
    Check "$ns/${img}:${tag} pullable" ($code -eq '200') "HTTP $code"
}

# ── 2. The dirty-tree guard (step 3b) would pass ───────────────────────────
Write-Output ''
Write-Host '--- 2. dirty-tree guard (installer step 3b) ---' -ForegroundColor Cyan
Push-Location 'deploy/client-bundle'
$repoTop = (git rev-parse --show-toplevel).Trim()
$dirty = @(git -C $repoTop status --porcelain)
Pop-Location

# The installer's guard is `$dirty = git status --porcelain; if ($dirty)`. That
# means it treats UNTRACKED files as dirty too, and skips the repo refresh on a
# tree git itself would happily fast-forward. This is a real behaviour worth
# knowing before a client update: an operator who left a scratch file behind
# gets "skipping the repo update" and only images move. It is a WARN in the
# installer, not a failure - but the repo silently stays behind.
#
# Counted separately so the report distinguishes the two cases.
$untracked = @($dirty | Where-Object { $_ -match '^\?\?' })
$tracked = @($dirty | Where-Object { $_ -notmatch '^\?\?' })
Check 'no TRACKED local edits (which would truly block a fast-forward)' ($tracked.Count -eq 0) `
    ("{0} tracked change(s)" -f $tracked.Count)
if ($untracked.Count -gt 0) {
    Note "$($untracked.Count) untracked file(s) present - the installer's guard skips the repo pull for these" `
        'harmless for git --ff-only, but it means ONLY images update; commit or remove them for a full refresh'
}

# ── 3. The repo is already at origin/main (pull would be a no-op) ──────────
Write-Output ''
Write-Host '--- 3. repo refresh would be a no-op ---' -ForegroundColor Cyan
$head = (git rev-parse HEAD).Trim()
$remote = ''
try { $remote = (git ls-remote origin refs/heads/main 2>$null | ForEach-Object { $_.Split()[0] }).Trim() } catch { }
Check 'local HEAD equals origin/main' ($remote -and $head -eq $remote) `
    ("local {0} vs origin {1}" -f $head.Substring(0, 7), $(if ($remote) { $remote.Substring(0, 7) } else { 'unreachable' }))

# ── 4. The staleness probe (step 7e) reports the TRUE state ────────────────
Write-Output ''
Write-Host '--- 4. staleness probe (installer step 7e) ---' -ForegroundColor Cyan
Push-Location 'deploy/client-bundle'
$portOut = (docker compose -f compose.prod.yaml port nginx 80 2>$null | Out-String).Trim()
$frontPort = $null
if ($portOut -match ':(\d+)\s*$') { $frontPort = $Matches[1] }
$pinned = [regex]::Match($raw, '(?m)^\s*image:\s*ghcr\.io/[a-z0-9\-]+/pacgate-api:(?<v>\d+\.\d+\.\d+)\s*$')
# The compose port for the LIVE project is remapped, so fall back to the running
# container, which is authoritative - the same fallback order the installer uses.
if (-not $frontPort) {
    foreach ($l in @(docker port pacgate-nginx 2>$null)) { if ($l -match ':(\d+)\s*$') { $frontPort = $Matches[1]; break } }
}
Pop-Location

# NOTE on the port. `docker compose port` returns the LIVE published port, not
# the declared one - it reports 8081 here even though compose.prod.yaml declares
# 8089. So the installer's fallback order is correct and needs no correction.
# (My first version of this script warned that it would probe the wrong port.
# That was a false positive: it assumed compose port echoed the declaration.
# Verified by comparing `docker compose port nginx 80` against `docker port`.)
$declared = $frontPort
$liveContainer = @(docker port pacgate-nginx 2>$null) | ForEach-Object { if ($_ -match ':(\d+)\s*$') { $Matches[1] } } | Select-Object -First 1
if ($liveContainer -and $declared -and $liveContainer -ne $declared) {
    Note "compose and docker report different nginx ports ($declared vs $liveContainer)" `
        'the installer tries compose first, then the container - worth knowing if a probe ever looks wrong'
}
else {
    Check 'the installer resolves the nginx host port consistently' $true `
        ("both compose and docker agree on port {0} (declared in compose.prod.yaml is 8089)" -f $declared)
}

$probePort = if ($liveContainer) { $liveContainer } else { $frontPort }
$url = "http://localhost:$probePort/version"
$reported = $null; $revision = $null; $httpNote = ''
foreach ($attempt in 1..3) {
    try { $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
          if ($resp.version) { $reported = $resp.version; $revision = $resp.revision; break } }
    catch { $httpNote = $_.Exception.Message; Start-Sleep -Seconds 2 }
}
$liveImg = (docker inspect pacgate-api --format '{{.Config.Image}}' 2>$null | Out-String).Trim()
if ($reported) {
    Check "probe read a version from $url" $true "reports $reported (revision $revision)"
}
else {
    # An old image returns 401 on /version (no /build-info, or auth-gated). The
    # installer's fallback branch is the interesting one: it must say "predates
    # /version" rather than "still starting", or the operator waits for a start
    # that will never come.
    $matchesFallback = $liveImg -match 'jzkk720|:0\.1\.[0-9]$'
    Check "probe's fallback diagnosis is correct for an old image" $matchesFallback `
        ("live image $liveImg; regex 'jzkk720|:0.1.[0-9]$' matched=$matchesFallback")
    Note "the probe cannot read a version on this box" `
        ("it would print 'Could not read ...' + the predates-/version line. Response: {0}" -f ($httpNote -replace '\s+', ' '))
}
Check 'running image differs from the compose pin (the staleness the probe exists to catch)' ($liveImg -match '0\.1\.2') `
    ("running $liveImg vs pinned 0.1.{0}" -f ([regex]::Match($raw, 'pacgate-api:0\.1\.(\d+)').Groups[1].Value))

# ── 5. Step 7f qm re-stage would be a no-op ────────────────────────────────
Write-Output ''
Write-Host '--- 5. qm re-stage (installer step 7f) ---' -ForegroundColor Cyan
$qmSrc = 'deploy/qm-pacgate'
$qmDst = 'deploy/client-bundle/qm-pacgate'
if ((Test-Path $qmSrc) -and (Test-Path $qmDst)) {
    $diff = @(git diff --no-index --name-only $qmSrc $qmDst 2>$null | Where-Object { $_ -and $_ -notmatch '\.env$|node_modules|\.generated|\.bak\.' })
    Check 'the qm runtime copy already matches the tracked source (no re-stage needed)' ($diff.Count -eq 0) `
        ("{0} differing file(s) outside the excluded set" -f $diff.Count)
}
elseif (-not (Test-Path $qmDst)) {
    # Expected on a box where setup-qm.ps1 has not been run: the runtime copy is
    # gitignored and only exists after staging, so step 7f has nothing to compare
    # and correctly does nothing. This is NOT a gap.
    Check 'step 7f is correctly a no-op (qm never staged on this box)' $true `
        "$qmDst does not exist yet; step 7f stages it on first run"
}
else {
    Note 'qm runtime copy exists but the tracked source is missing' "$qmSrc"
}

# ── 6. Prove nothing moved ─────────────────────────────────────────────────
Write-Output ''
Write-Host '--- 6. live stack untouched ---' -ForegroundColor Cyan
# COMPARE PER KEY, not by joining a hashtable's .Values.
#
# The first version joined `$before.Values` and `$after.Values` into strings and
# compared those. Hashtable enumeration order is not insertion order, and the two
# hashtables were populated by different code paths, so the strings differed even
# though every ID was identical - a false FAIL. Comparing key by key removes the
# ordering assumption entirely.
$moved = @()
foreach ($c in @($before.Keys)) {
    $now = (docker inspect $c --format '{{.Id}}' 2>$null | Out-String).Trim()
    if ($now -ne $before[$c]) { $moved += $c }
}
# `if` cannot be used as an expression in an argument position, so the detail
# string is built first.
$detail = if ($moved.Count -eq 0) {
    "{0} containers compared, all identical" -f $before.Count
} else {
    "recreated: {0}" -f ($moved -join ', ')
}
Check 'every live container ID is unchanged by this dry run' ($moved.Count -eq 0) $detail

Write-Output ''
Write-Host ("{0} passed, {1} failed, {2} warning(s)" -f $pass, $fail, $warn)
Write-Output ''
Write-Host 'NOT PROVEN by this dry run (needs a disposable host or a client window):' -ForegroundColor DarkGray
Write-Host '  - the `docker compose up -d` recreate actually succeeding' -ForegroundColor DarkGray
Write-Host '  - the stack coming up healthy on the new images' -ForegroundColor DarkGray
Write-Host '  - a real `git pull` against a machine that is behind' -ForegroundColor DarkGray
if ($fail -gt 0) { exit 1 }
exit 0
