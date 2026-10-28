# Report which egress routes this machine can actually use for git and GitHub.
#
# WHY THIS EXISTS (measured on this box, 2026-10-28)
#
# A whole session's worth of pushes failed with three DIFFERENT messages that all
# looked like "GitHub is down", and each had a different cause:
#
#   1. `schannel: failed to receive handshake, SSL/TLS connection failed`
#      The WinINET system proxy was enabled and pointed at 127.0.0.1:7892
#      (CycloneLite). Its upstream had died and returned 502, so it accepted the
#      TCP connection and then failed the TLS handshake. Nothing was wrong with
#      GitHub; it never saw the request.
#
#   2. `CRYPT_E_REVOCATION_OFFLINE`
#      Windows could not reach the certificate-revocation server, so schannel
#      refused the chain. git has a knob for this (http.schannelCheckRevoke) but it
#      does not help because the handshake fails a layer earlier.
#
#   3. `Failed to connect to github.com:443 over proxy`
#      Even after WinINET ProxyEnable was set to 0, git STILL used the proxy: the
#      address lives in `git config --global http.proxy`, which is independent of
#      winhttp/wininet settings. Clearing winhttp is not enough.
#
# The useful fact discovered while untangling this: on this network `github.com:443`
# is unreachable directly while `github.com:22` (SSH) is open and
# `api.github.com:443` works. So the git remote belongs on SSH and the GitHub REST
# scripts (which all use api.github.com) keep working over HTTPS.
#
# Read-only. Prints a route report and a recommendation; never changes a config.
# Exit 0 always, because this is a diagnosis, not a gate.

$ErrorActionPreference = 'Continue'

function Invoke-NativeCapture {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Script 2>&1 | Out-String).Trim() }
    finally { $ErrorActionPreference = $previous }
}

Write-Host '=== GitHub egress diagnostics ===' -ForegroundColor Cyan

# ── 1. what proxy configuration is in play ──────────────────────────────────
Write-Host ''
Write-Host '1. proxy configuration' -ForegroundColor White
$p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$wininet = if ($p) { "ProxyEnable=$($p.ProxyEnable)  ProxyServer=$($p.ProxyServer)" } else { 'unreadable' }
Write-Host "  WinINET     : $wininet"

$gitProxy = Invoke-NativeCapture { git config --global --get http.proxy }
Write-Host "  git global  : http.proxy=[$(if ($gitProxy) { $gitProxy } else { 'unset' })]"
Write-Host '                (independent of WinINET - clearing Windows settings does NOT affect git)'

foreach ($v in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
    $val = [Environment]::GetEnvironmentVariable($v)
    if ($val) { Write-Host "  env $v = $val" -ForegroundColor Yellow }
}

# ── 2. reachability per route ──────────────────────────────────────────────
Write-Host ''
Write-Host '2. route reachability (TCP, no proxy)' -ForegroundColor White
$routes = @(
    @{ Name = 'github.com:22   (SSH)';       Host = 'github.com';     Port = 22 },
    @{ Name = 'github.com:443  (HTTPS)';     Host = 'github.com';     Port = 443 },
    @{ Name = 'api.github.com:443 (REST)';   Host = 'api.github.com'; Port = 443 },
    @{ Name = 'ghcr.io:443     (registry)';  Host = 'ghcr.io';        Port = 443 }
)
$open = @{}
foreach ($r in $routes) {
    $ok = $false
    try { $ok = Test-NetConnection -ComputerName $r.Host -Port $r.Port -InformationLevel Quiet -WarningAction SilentlyContinue } catch { $ok = $false }
    $open[$r.Name] = $ok
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-32} {1}" -f $r.Name, $(if ($ok) { 'open' } else { 'BLOCKED' })) -ForegroundColor $colour
}

# ── 3. the remote the repo actually uses ───────────────────────────────────
Write-Host ''
Write-Host '3. git remote' -ForegroundColor White
$repoRoot = Split-Path -Parent $PSScriptRoot
if (Test-Path (Join-Path $repoRoot '.git')) {
    $url = Invoke-NativeCapture { git -C $repoRoot remote get-url origin }
    Write-Host "  origin      : $url"
    $isSsh = $url -match '^(git@|ssh://)'
    $sshOk = $open['github.com:22   (SSH)']
    $httpsOk = $open['github.com:443  (HTTPS)']
    if ($isSsh -and -not $sshOk) {
        Write-Host '  PROBLEM: the remote is SSH but github.com:22 is blocked.' -ForegroundColor Red
        Write-Host '           Try: git remote set-url origin https://github.com/<owner>/<repo>.git' -ForegroundColor Yellow
    } elseif (-not $isSsh -and -not $httpsOk) {
        Write-Host '  PROBLEM: the remote is HTTPS but github.com:443 is blocked.' -ForegroundColor Red
        Write-Host '           Try: git remote set-url origin git@github.com:<owner>/<repo>.git' -ForegroundColor Yellow
    } else {
        Write-Host '  OK: the remote protocol matches an open route.' -ForegroundColor Green
    }
} else {
    Write-Host "  not a git checkout: $repoRoot" -ForegroundColor DarkGray
}

# ── 4. verdict ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '4. verdict' -ForegroundColor White
$anyGit = $open['github.com:22   (SSH)'] -or $open['github.com:443  (HTTPS)']
if ($anyGit) {
    Write-Host '  At least one git route is open, so pushes can work.' -ForegroundColor Green
} else {
    Write-Host '  NO git route is open. This is a network-level block, not a repo' -ForegroundColor Red
    Write-Host '  problem. Wait for the network, or use another connection.' -ForegroundColor Yellow
}
if (-not $open['api.github.com:443 (REST)']) {
    Write-Host '  api.github.com is also blocked, so the release/release-dispatch' -ForegroundColor Yellow
    Write-Host '  scripts (ghcr-login, dispatch-release-via-api, watch-release-build)' -ForegroundColor Yellow
    Write-Host '  cannot run either.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'If a push fails with "failed to receive handshake", check the git global' -ForegroundColor DarkGray
Write-Host 'proxy FIRST - it is the most common cause here and it is invisible to' -ForegroundColor DarkGray
Write-Host 'Windows proxy settings.' -ForegroundColor DarkGray
exit 0
