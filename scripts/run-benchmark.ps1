# Produce the Pacgate full-stack benchmark, as markdown, from the LIVE stack.
#
# WHY THIS EXISTS. Three benchmark reports were written by hand
# (BENCHMARK-REPORT-2026-09-29 / -10-08 / -10-09-v0.1.25) and each one records
# measurements with no way to reproduce them. The consequence was visible: when
# 0.1.27 shipped there was NO current report, and a benchmark that cannot be
# re-run is a number nobody can trust or refresh. This makes the measurement a
# script, so the report is produced rather than asserted.
#
# SCOPE, stated plainly because a benchmark that overstates itself is worse than
# none:
#   - It measures THIS box (a dev machine, WSL2 Docker, one Ollama runner slot).
#     The absolute numbers are not a client-AIPC specification; the SHAPE and the
#     regressions against a previous run are what they are useful for.
#   - LLM lanes use ONE runner slot, so a concurrent chat starves embeddings.
#     That is why the lanes are measured sequentially, not in parallel.
#   - Anything unmeasurable is reported as SKIP with the reason, never as a pass.
#
# Usage:
#   pwsh -File scripts/run-benchmark.ps1
#   pwsh -File scripts/run-benchmark.ps1 -Markdown > deploy/BENCHMARK-REPORT-<date>-<ver>.md
[CmdletBinding()]
param(
    [string]$NginxUrl = 'http://localhost:8089',
    [string]$OllamaUrl = 'http://localhost:11434',
    # deer-flow admin. The documented dev credential; override per machine.
    [string]$DfEmail = 'admin@pacgate-law.com',
    [string]$DfPassword = '9delujmycbrktj9u5mo9js8t',
    [string]$DfModel = 'gemma4-12b-local',
    # Emit pure markdown (for > file). Without it, prints a human summary too.
    [switch]$Markdown
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Now-Ms { [Diagnostics.Stopwatch]::StartNew() }

function Measure-Get {
    param([string]$Label, [string]$Url, [int]$Samples = 3, [string]$Session = '')
    $times = @()
    $status = 'ERR'
    for ($i = 0; $i -lt $Samples; $i++) {
        $sw = Now-Ms
        try {
            $p = @{ Uri = $Url; TimeoutSec = 60; UseBasicParsing = $true }
            if ($Session) { $p.WebSession = $Session }
            $r = Invoke-WebRequest @p
            $status = [int]$r.StatusCode
        }
        catch {
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode.value__ } else { $status = 'ERR' }
        }
        $sw.Stop()
        $times += [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    }
    [pscustomobject]@{
        Label = $Label; Status = $status
        Min = ($times | Measure-Object -Minimum).Minimum
        Max = ($times | Measure-Object -Maximum).Maximum
        All = ($times -join ' / ')
    }
}

$rows = @()
$notes = @()

# ── 1. HTTP latency through nginx (the client-facing edge) ───────────────────
$rows += Measure-Get 'GET /version (nginx root, staleness probe)' "$NginxUrl/version"
$rows += Measure-Get 'GET /setup (browser first-admin surface)' "$NginxUrl/setup"
$rows += Measure-Get 'GET /pacgate/health (public API health)' "$NginxUrl/pacgate/health"
$rows += Measure-Get 'GET / (deer-flow frontend via nginx)' "$NginxUrl/" -Samples 3

# ── 2. Authenticated pacgate-api ─────────────────────────────────────────────
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$apiEmail = ''; $apiPass = ''
$envPath = Join-Path $repoRoot 'deploy/client-bundle/.env'
if (Test-Path $envPath) {
    foreach ($line in (Get-Content $envPath -ErrorAction SilentlyContinue)) {
        if     ($line -match '^\s*PACGATE_API_EMAIL\s*=\s*(.+)$')    { $apiEmail = $Matches[1].Trim() }
        elseif ($line -match '^\s*PACGATE_API_PASSWORD\s*=\s*(.+)$') { $apiPass  = $Matches[1].Trim() }
    }
}
$loginMs = 'SKIP'
if ($apiEmail -and $apiPass) {
    $sw = Now-Ms
    try {
        $null = Invoke-WebRequest -Uri "$NginxUrl/pacgate/api/auth/login" -Method Post `
            -Body (@{ email = $apiEmail; password = $apiPass } | ConvertTo-Json -Compress) `
            -ContentType 'application/json' -WebSession $session -UseBasicParsing -TimeoutSec 30
        $sw.Stop(); $loginMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    }
    catch { $sw.Stop(); $loginMs = "ERR $([int]$_.Exception.Response.StatusCode.value__)" }
    $rows += [pscustomobject]@{ Label = 'POST /pacgate/api/auth/login'; Status = 'auth'; Min = $loginMs; Max = $loginMs; All = "$loginMs" }
    $tok = ($session.Cookies.GetCookies($NginxUrl) | Where-Object { $_.Name -match 'token' } | Select-Object -First 1).Value
    if ($tok) {
        $rows += Measure-Get 'GET /pacgate/api/auth/me (authed)' "$NginxUrl/pacgate/api/auth/me" -Samples 3 -Session $session
    }
}
else { $notes += 'pacgate-api credentials missing from deploy/client-bundle/.env - authed API lane SKIPPED.' }

# ── 3. LLM / RAG lanes (Ollama, one runner slot => sequential) ───────────────
$llm = @()
$sw = Now-Ms
try {
    $null = Invoke-WebRequest -Uri "$OllamaUrl/api/embeddings" -Method Post -TimeoutSec 300 `
        -Body (@{ model = 'nomic-embed-text:latest'; prompt = 'settlement authority clause' } | ConvertTo-Json -Compress) `
        -ContentType 'application/json' -UseBasicParsing
    $sw.Stop(); $llm += [pscustomobject]@{ Lane = 'nomic-embed-text embedding (first call, cold)'; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0) }
}
catch { $sw.Stop(); $llm += [pscustomobject]@{ Lane = 'nomic-embed-text embedding'; Ms = "ERR" } }

$sw = Now-Ms
try {
    $null = Invoke-WebRequest -Uri "$OllamaUrl/v1/chat/completions" -Method Post -TimeoutSec 600 `
        -Body (@{ model = 'gemma4:12b-it-qat'; messages = @(@{ role = 'user'; content = 'Reply with exactly: PONG' }); max_tokens = 8 } | ConvertTo-Json -Depth 6 -Compress) `
        -ContentType 'application/json' -UseBasicParsing
    $sw.Stop(); $llm += [pscustomobject]@{ Lane = 'gemma4:12b local chat (short, warm)'; Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0) }
}
catch { $sw.Stop(); $llm += [pscustomobject]@{ Lane = 'gemma4:12b local chat'; Ms = "ERR" } }

# deer-flow end-to-end generation, delivered through nginx. This is the lane the
# 2026-10-13 proxyTimeout defect broke, so it is the one worth timing.
$df = 'SKIP'
$dfs = New-Object Microsoft.PowerShell.Commands.WebRequestSession
try {
    $null = Invoke-WebRequest -Uri "$NginxUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = $DfEmail; password = $DfPassword } -WebSession $dfs -UseBasicParsing -TimeoutSec 25
    $csrf = ($dfs.Cookies.GetCookies($NginxUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value
    $H = @{ 'X-CSRF-Token' = $csrf }
    $t = (Invoke-WebRequest -Uri "$NginxUrl/api/threads" -Method Post -Body '{}' -ContentType 'application/json' `
            -Headers $H -WebSession $dfs -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
    $body = @{
        input   = @{ messages = @(@{ role = 'user'; content = 'Reply with exactly this word and nothing else: PONG' }) }
        context = @{ model_name = $DfModel }
    } | ConvertTo-Json -Depth 12 -Compress
    $sw = Now-Ms
    $r = Invoke-WebRequest -Uri "$NginxUrl/api/threads/$($t.thread_id)/runs/wait" -Method Post -Body $body `
        -ContentType 'application/json' -Headers $H -WebSession $dfs -UseBasicParsing -TimeoutSec 900
    $sw.Stop()
    $df = "$([math]::Round($sw.Elapsed.TotalSeconds,1)) s (HTTP $($r.StatusCode))"
}
catch { $df = "ERR $([int]$_.Exception.Response.StatusCode.value__)" }

# ── 4. Container footprint ───────────────────────────────────────────────────
$stats = @(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>$null |
    Where-Object { $_ -match '^(deer-flow|deer-flow-frontend|ocr-service|openviking|pacgate-api|pacgate-db|pacgate-mcp|pacgate-nginx)\|' })

# ── 5. Data-plane counts ─────────────────────────────────────────────────────
$counts = 'SKIP'
try {
    $counts = (docker exec pacgate-db psql -U pacgate -d pacgate -t -A -c `
        "SELECT 'tenants='||(SELECT count(*) FROM tenants)||' users='||(SELECT count(*) FROM users)||' matters='||(SELECT count(*) FROM matters)||' documents='||(SELECT count(*) FROM documents);" 2>$null)
}
catch { }

# ── Output ───────────────────────────────────────────────────────────────────
$ver = 'unknown'
$toml = Join-Path $repoRoot 'pacgate-ai/Cargo.toml'
if (Test-Path $toml) { $ver = (Select-String -Path $toml -Pattern '^version\s*=\s*"([0-9.]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value }
$rev = (git -C $repoRoot rev-parse --short HEAD 2>$null)
$when = (Get-Date -Format 'yyyy-MM-dd HH:mm')
$host_ = "$env:COMPUTERNAME"

Write-Output "# Pacgate full-stack benchmark - v$ver ($when)"
Write-Output ''
Write-Output "Measured by ``scripts/run-benchmark.ps1`` on **$host_**, revision ``$rev``."
Write-Output ''
Write-Output '> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The'
Write-Output '> absolute numbers are not a client-AIPC specification; use the shape and any'
Write-Output '> regression against a previous run. LLM lanes run sequentially because a'
Write-Output '> concurrent chat starves embeddings on a single runner slot.'
Write-Output ''
Write-Output '## 1. HTTP latency through nginx (the client-facing edge)'
Write-Output ''
Write-Output '| Endpoint | Status | Min ms | Max ms | Samples |'
Write-Output '| --- | --- | --- | --- | --- |'
foreach ($r in $rows) { Write-Output "| $($r.Label) | $($r.Status) | $($r.Min) | $($r.Max) | $($r.All) |" }
Write-Output ''
Write-Output '## 2. LLM / RAG lanes (one runner slot, sequential)'
Write-Output ''
Write-Output '| Lane | ms |'
Write-Output '| --- | --- |'
foreach ($l in $llm) { Write-Output "| $($l.Lane) | $($l.Ms) |" }
Write-Output "| deer-flow generation delivered through nginx ($DfModel) | $df |"
Write-Output ''
Write-Output '## 3. Container footprint (idle, snapshot)'
Write-Output ''
if ($stats.Count -gt 0) {
    Write-Output '| Container | CPU % | Mem usage |'
    Write-Output '| --- | --- | --- |'
    foreach ($s in $stats) { $p = $s -split '\|'; Write-Output "| $($p[0]) | $($p[1]) | $($p[2]) |" }
} else { Write-Output '_docker stats returned nothing - stack not running._' }
Write-Output ''
Write-Output '## 4. Data plane'
Write-Output ''
Write-Output "    $counts"
Write-Output ''
if ($notes.Count -gt 0) {
    Write-Output '## Notes / skips'
    Write-Output ''
    foreach ($n in $notes) { Write-Output "- $n" }
    Write-Output ''
}
Write-Output '## Verdict'
Write-Output ''
$bad = @($rows | Where-Object { $_.Status -eq 'ERR' })
if ($bad.Count -eq 0) { Write-Output 'All measured lanes responded. No lane errored.' }
else { Write-Output "$($bad.Count) lane(s) errored: $(($bad | ForEach-Object { $_.Label }) -join ', ')" }
