# Model picker + generation delivery gate.
#
# WHY THIS EXISTS. The 2026-10-13 defect shipped in every 0.1.27 deployment and
# nothing in this repo could have caught it: the picker and the generation path
# had NO test. What was broken was not the model - it was the DELIVERY of the
# result. Next.js `experimental.proxyTimeout` defaults to 30000 ms, so every
# gateway call the frontend proxied had its socket torn down mid-flight while the
# run kept executing server-side. It read as "the model cannot generate".
# See deploy/DEFECT-frontend-proxy-timeout.md.
#
# So this gate asserts BOTH halves:
#   STATIC - the long-run timeout chain is actually configured, and the picker
#            roster cannot drift from the models install.ps1 is told to pull.
#            The defect WAS a missing config value, so this is the part that
#            regresses silently if someone drops it.
#   LIVE   - the picker answers, and a real generation through NGINX (the path a
#            client actually uses) returns an actual reply rather than an error.
#
# Exit 2 means CANNOT CHECK (stack down / no credentials) and must never be read
# as a failure of the code.
[CmdletBinding()]
param(
    [string]$NginxUrl = 'http://localhost:8089',
    [string]$Email = 'admin@pacgate-law.com',
    # NOT hardcoded. A live deer-flow password sat here until 2026-10-15 in a PUBLIC
    # repo. Resolved per machine from -Password, then PACGATE_DEERFLOW_PASSWORD, then
    # the gitignored deploy/client-bundle/.deer-flow-credentials. With none of those
    # the gate reports CANNOT CHECK (exit 2) instead of failing - see below.
    [string]$Password = '',
    [string]$Model = 'gemma4-12b-local',
    [int]$TimeoutSec = 420
)

# deer-flow has a SEPARATE identity store from pacgate-api, so .env's
# PACGATE_API_PASSWORD is the API principal and returns 401 here. The deer-flow admin
# is created by deer-flow's own /initialize, so the credential must be supplied.
function Resolve-DeerFlowPassword {
    if ($Password) { return $Password }
    if ($env:PACGATE_DEERFLOW_PASSWORD) { return $env:PACGATE_DEERFLOW_PASSWORD }
    $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.deer-flow-credentials'
    if (Test-Path -LiteralPath $f) {
        $m = Select-String -LiteralPath $f -Pattern '^\s*PACGATE_DEERFLOW_PASSWORD\s*=\s*(.+?)\s*$' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value.Trim() }
    }
    return $null
}

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
$pass = 0
$fail = 0

# Resolve once, up front. CANNOT CHECK is reported before any assertion runs, so a
# machine with no deer-flow credential does not produce a misleading red or a
# misleading green.
$Password = Resolve-DeerFlowPassword
if (-not $Password) {
    Write-Host '[SKIP] CANNOT CHECK: no deer-flow credential available.' -ForegroundColor Yellow
    Write-Host '       Pass -Password, set PACGATE_DEERFLOW_PASSWORD, or write' -ForegroundColor Yellow
    Write-Host '       deploy/client-bundle/.deer-flow-credentials (gitignored).' -ForegroundColor Yellow
    Write-Host 'RESULT: 0 passed, 0 failed (CANNOT CHECK - no credential)' -ForegroundColor Yellow
    exit 2
}

function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
        $script:fail++
    }
}

Write-Host '=== model picker + generation delivery gate ===' -ForegroundColor Cyan

# ── STATIC: the timeout chain ────────────────────────────────────────────────
# The frontend is the INNER proxy: browser -> nginx -> Next.js -> gateway. Each
# hop caps the request independently and the first one to give up wins, so both
# must be configured, and the measured worst case is a real run at 2495 s.
Write-Host ''
Write-Host 'STATIC: the long-run timeout chain is configured'

$nextCfg = Join-Path $repoRoot 'deploy/frontend-patches/files/next.config.js'
Check 'frontend next.config.js is tracked in the patch pipeline' (Test-Path $nextCfg) $nextCfg
if (Test-Path $nextCfg) {
    $txt = Get-Content $nextCfg -Raw
    $m = [regex]::Match($txt, 'proxyTimeout:\s*(\d+)')
    Check 'frontend sets experimental.proxyTimeout' $m.Success 'no proxyTimeout found - Next.js will default to 30s and kill long runs'
    if ($m.Success) {
        $ms = [int]$m.Groups[1].Value
        # Anything in the same class as the 30 s default (or the 300 s that failed
        # next) cannot carry a real agent run.
        Check 'proxyTimeout is above any observed run' ($ms -ge 900000) "proxyTimeout=$ms ms; a real run measured 2495 s"
    }
}

$compose = Join-Path $repoRoot 'deploy/client-bundle/compose.prod.yaml'
$cTxt = Get-Content $compose -Raw
Check 'compose bind-mounts the patched config over the image copy' `
    ($cTxt -match 'frontend-patches/files/next\.config\.js:/app/frontend/next\.config\.js') `
    'without the bind mount a client needs an image rebuild to get the fix'

$nginx = Join-Path $repoRoot 'deploy/client-bundle/nginx/default.conf'
$nTxt = Get-Content $nginx -Raw
# `location /` and `location /research/` front the same upstream and the same
# long-running traffic, so they must not drift apart.
$rootTimeouts = [regex]::Matches($nTxt, 'proxy_read_timeout\s+(\d+)s') | ForEach-Object { [int]$_.Groups[1].Value }
Check 'nginx has a long-run read timeout on the UI/API locations' `
    (($rootTimeouts | Where-Object { $_ -ge 900 }).Count -ge 2) `
    "read timeouts found: $($rootTimeouts -join ', ') s (need >= 900 on both / and /research/)"

# The UPDATE path must actually apply the bind mount. A changed bind-mounted FILE
# does not alter compose config, so `up -d` never recreates the container and
# `next start` reads next.config.js only at boot. install.ps1's "-Update" restart
# list therefore has to name deer-flow-frontend, or an updated machine silently
# keeps the old config and stays broken - the exact gap this assertion exists for.
$installPs1 = Join-Path $repoRoot 'deploy/client-bundle/install.ps1'
$iTxt = Get-Content $installPs1 -Raw
$restartBlock = [regex]::Match($iTxt, "(?s)Restarting services with bind-mounted code.{0,1500}")
Check 'install.ps1 -Update restarts deer-flow-frontend (applies the bind mount)' `
    ($restartBlock.Success -and $restartBlock.Value -match 'deer-flow-frontend') `
    'the update restart list must include deer-flow-frontend, or a repo update leaves the old proxyTimeout in force'

# ── STATIC: picker roster vs what install.ps1 pulls ──────────────────────────
Write-Host ''
Write-Host 'STATIC: the picker roster cannot drift from the pulled models'

$cfg = Join-Path $repoRoot 'deploy/client-bundle/deer-flow-config.yaml'
$list = Join-Path $repoRoot 'deploy/client-bundle/ollama-models.txt'
if ((Test-Path $cfg) -and (Test-Path $list)) {
    # Active picker entries only: a commented-out model is not offered, and a
    # bare string must not be mistaken for a model tag.
    $picker = @()
    foreach ($line in (Get-Content $cfg)) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*-?\s*model:\s*(\S+)') { continue }
        $picker += $matches[1]
    }
    $picker = @($picker | Sort-Object -Unique)
    Check 'the picker offers at least one model' ($picker.Count -gt 0) 'no active model: entries parsed'

    $required = @(Get-Content $list | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
    $missing = @($picker | Where-Object { $required -notcontains $_ })
    Check 'every picker model is in ollama-models.txt' ($missing.Count -eq 0) `
        "not listed for install: $($missing -join ', ')"
    Write-Host "         picker: $($picker -join ', ')" -ForegroundColor DarkGray
}
else { Check 'picker config + model list exist' $false "$cfg / $list" }

# ── LIVE: the picker answers ─────────────────────────────────────────────────
Write-Host ''
Write-Host 'LIVE: the picker is served and a generation is delivered'

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$loginOk = $false
try {
    $null = Invoke-WebRequest -Uri "$NginxUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = $Email; password = $Password } `
        -WebSession $session -UseBasicParsing -TimeoutSec 25
    $loginOk = $true
}
catch {
    Write-Host "[SKIP] CANNOT CHECK: deer-flow login failed at $NginxUrl ($($_.Exception.Response.StatusCode.value__))." -ForegroundColor Yellow
    Write-Host '       Start the stack and set -Email/-Password to a real deer-flow account.' -ForegroundColor Yellow
    Write-Host "RESULT: $pass passed, $fail failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

if ($loginOk) {
    $roster = $null
    try { $roster = (Invoke-WebRequest -Uri "$NginxUrl/api/models" -WebSession $session -UseBasicParsing -TimeoutSec 25).Content | ConvertFrom-Json }
    catch { }
    Check 'GET /api/models answers through nginx' ($null -ne $roster) 'the picker endpoint did not respond'
    if ($roster) {
        Check 'the picker returns a roster' ($roster.models.Count -gt 0) 'roster empty'
        $names = ($roster.models | ForEach-Object { $_.name }) -join ', '
        Write-Host "         roster: $names" -ForegroundColor DarkGray
        # The first entry IS the default (the frontend takes models[0]).
        Check 'every roster entry carries a concrete model tag' `
            (@($roster.models | Where-Object { -not $_.model }).Count -eq 0) 'an entry had no model tag'
        $target = if ($Model -and ($roster.models.name -contains $Model)) { $Model } else { $roster.models[0].name }
        Write-Host "         generating with: $target" -ForegroundColor DarkGray

        # The whole point: a real generation must be DELIVERED back through nginx.
        try {
            $t = (Invoke-WebRequest -Uri "$NginxUrl/api/threads" -Method Post -Body '{}' -ContentType 'application/json' `
                    -Headers @{ 'X-CSRF-Token' = ($session.Cookies.GetCookies($NginxUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value } `
                    -WebSession $session -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
            $body = @{
                input   = @{ messages = @(@{ role = 'user'; content = 'Reply with exactly this word and nothing else: PONG' }) }
                context = @{ model_name = $target }
            } | ConvertTo-Json -Depth 12 -Compress
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-WebRequest -Uri "$NginxUrl/api/threads/$($t.thread_id)/runs/wait" -Method Post -Body $body `
                -ContentType 'application/json' `
                -Headers @{ 'X-CSRF-Token' = ($session.Cookies.GetCookies($NginxUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value } `
                -WebSession $session -UseBasicParsing -TimeoutSec $TimeoutSec
            $sw.Stop()
            $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            Check 'a generation is DELIVERED through nginx (HTTP 200)' ($r.StatusCode -eq 200) "got HTTP $($r.StatusCode)"
            # A 200 with no assistant text is the other half of the original
            # defect. The runs/wait payload puts messages at the TOP level
            # ({messages, thread_data, title}); the thread /state endpoint nests
            # them under .values. Accept either rather than assuming one shape -
            # assuming the wrong one is how this gate first reported a false FAIL.
            $json = $null
            try { $json = $r.Content | ConvertFrom-Json } catch { }
            $msgs = @()
            if ($json) {
                if ($json.messages) { $msgs = @($json.messages) }
                elseif ($json.values -and $json.values.messages) { $msgs = @($json.values.messages) }
            }
            $ai = $msgs | Where-Object { $_.type -eq 'ai' } | Select-Object -Last 1
            $text = if ($ai) { [string]$ai.content } else { '' }
            Check 'the delivered run carries an assistant reply' ($text.Trim().Length -gt 0) `
                "HTTP 200 but no assistant message in the payload (parsed $(@($msgs).Count) message(s))"
            Write-Host ("         delivered in {0}s  reply='{1}'" -f $secs, $text.Trim().Substring(0, [Math]::Min(60, $text.Trim().Length))) -ForegroundColor DarkGray
        }
        catch {
            $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'no-response' }
            Check 'a generation is DELIVERED through nginx (HTTP 200)' $false "HTTP $code - if this is 500/504 the proxy timeout chain regressed (see deploy/DEFECT-frontend-proxy-timeout.md)"
            Check 'the delivered run carries an assistant reply' $false 'no reply could be read'
        }
    }
}

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
exit 0
