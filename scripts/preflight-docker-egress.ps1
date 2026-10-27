# Pre-flight: can the Docker daemon actually reach the registries and package
# indexes a build needs? Run this BEFORE `docker build`, `docker compose pull`,
# or a release build. Aborts with a named cause instead of a silent SSL EOF.
#
# WHY THIS EXISTS (measured 2026-10-27, this dev box):
#
#   docker build -f deploy/deer-flow-pacgate/Dockerfile .
#     -> RUN pip install ... /app/adapters/pacgate_deerflow_adapter
#     -> SSLError(SSLEOFError(8, '[SSL: UNEXPECTED_EOF_WHILE_READING]')) against pypi.org
#
# The instinct is "pypi is down" or "the corporate network blocks pypi". It was
# neither. WinINET had ProxyEnable=1 pointing at 127.0.0.1:7892 (CycloneLite),
# Docker Desktop relays through that system proxy, and the ProxyOverride bypass
# list did not include ghcr.io / pypi.org / files.pythonhosted.org. From the HOST
# the same request worked, because PowerShell and curl honour a different path
# than the daemon. So the failure looked transient and container-specific, and it
# cost a full rebuild attempt to surface.
#
# The same proxy, when its upstream is dead, accepts the TCP connection and the
# CONNECT verb and then drops every tunnel - so every registry fails identically
# and it reads like a GHCR visibility problem. It is not.
#
# This script separates those cases so the next person spends seconds, not
# rebuild attempts:
#
#   HOST  reachable, DOCKER unreachable  -> proxy/daemon egress problem
#   HOST  unreachable, DOCKER unreachable -> genuine network outage
#   both reachable                       -> safe to build
#
# Usage:
#   pwsh -File scripts/preflight-docker-egress.ps1
#   pwsh -File scripts/preflight-docker-egress.ps1 -Targets 'pypi.org','ghcr.io'
#
# Exit codes: 0 = every target reachable from Docker, 2 = CANNOT CHECK (daemon not
# running), 1 = a real egress failure with the cause named.

[CmdletBinding()]
param(
    # Hosts the build needs. pypi + files.pythonhosted for pip, ghcr for our own
    # images and the pinned bytedance base, registry-1.docker.io for base images
    # pulled by name, deb.debian.org for the apt-get layer in the wrapper image.
    [string[]]$Targets = @('pypi.org', 'files.pythonhosted.org', 'ghcr.io', 'registry-1.docker.io', 'deb.debian.org'),

    # Skip the in-container probe and only report host reachability.
    [switch]$HostOnly
)

$ErrorActionPreference = 'Continue'

# Accept a comma-separated list as ONE argument as well as an array. `pwsh -File
# script.ps1 -Targets 'a','b'` arrives as the single string "a,b" (the -File
# binder does not split on commas the way a direct cmdlet call does), which would
# otherwise probe a host literally named "'a','b'" and report a bogus failure.
$Targets = @($Targets | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim("'", '"') } | Where-Object { $_ })
if ($Targets.Count -eq 0) {
    Write-Host '[SKIP] CANNOT CHECK: no targets given.' -ForegroundColor Yellow
    exit 2
}

# Never let a native command's stderr terminate the run: on PowerShell 7 a native
# process writing to stderr raises under 'Stop'. Same trap already guarded in
# scripts/assert-no-staged-secrets.ps1.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$fail = 0
function Ok($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host '=== PRE-FLIGHT: docker build egress ===' -ForegroundColor Cyan

# ── 1. Is the daemon up? ─────────────────────────────────────────────────────
# Without this every probe below fails for the same uninformative reason.
docker info --format '{{.ServerVersion}}' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [SKIP] CANNOT CHECK: the Docker daemon is not reachable.' -ForegroundColor Yellow
    Note 'Start Docker Desktop, then re-run this preflight.'
    Write-Host 'RESULT: 0 passed, 0 failed (CANNOT CHECK - no daemon)' -ForegroundColor Yellow
    exit 2
}
Ok 'docker daemon is reachable'

# ── 2. Host-level reachability ───────────────────────────────────────────────
# This is the CONTROL. Its only job is to tell a proxy/daemon problem apart from
# a real outage; a failure here is not by itself a build blocker on a box whose
# host shell uses a different egress path than the daemon.
$hostDown = @()
foreach ($t in $Targets) {
    try {
        $r = Invoke-WebRequest -Uri "https://$t/" -Method Head -TimeoutSec 12 -UseBasicParsing -ErrorAction Stop
        # Any HTTP status proves DNS + TLS + a response; 403/405 is common for HEAD.
        Ok "host can reach $t (HTTP $($r.StatusCode))"
    }
    catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code -gt 0) {
            Ok "host can reach $t (HTTP $code)"
        }
        else {
            $hostDown += $t
            Write-Host "  [warn] host cannot reach $t" -ForegroundColor Yellow
        }
    }
}

if ($HostOnly) {
    Write-Host ''
    if ($hostDown.Count -gt 0) {
        Write-Host "RESULT: $($hostDown.Count) target(s) unreachable from the host: $($hostDown -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    Write-Host 'RESULT: every target reachable from the host.' -ForegroundColor Green
    exit 0
}

# ── 3. Container-level reachability: the one that actually matters ───────────
# A build runs INSIDE the daemon's network namespace and egress, which is not the
# same path as the host shell. Probing from a container is the only honest test.
#
# python3 is used because it is guaranteed present in every image this repo
# builds on; curl is deliberately NOT assumed - the deer-flow base image has no
# curl, which is exactly the kind of assumption that produced the earlier
# misleading hand-test.
$probe = @'
import socket, ssl, sys
targets = sys.argv[1:]
bad = []
for t in targets:
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((t, 443), timeout=12) as s:
            with ctx.wrap_socket(s, server_hostname=t) as ss:
                ss.getpeercert()
        print("OK    " + t)
    except Exception as e:
        print("FAIL  " + t + "  " + type(e).__name__ + ": " + str(e))
        bad.append(t)
sys.exit(1 if bad else 0)
'@

$img = 'python:3.12-slim'
# Prefer an image already on this machine so the preflight never needs the very
# network it is testing. Fall back to the python image only if none is present.
foreach ($cand in @('ghcr.io/jzkk720/deer-flow-pacgate:0.2.6', $img)) {
    docker image inspect $cand 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $img = $cand; break }
}

$out = $probe | docker run --rm -i --entrypoint python3 $img - $Targets 2>&1
$dockerFailed = @()
foreach ($line in @($out)) {
    $l = "$line".Trim()
    if ($l -match '^OK\s+(\S+)') { Ok "container can reach $($Matches[1])" }
    elseif ($l -match '^FAIL\s+(\S+)') { $dockerFailed += $Matches[1] }
}

if ($out -match 'Unable to find image|pull access denied|manifest unknown') {
    Write-Host '  [SKIP] CANNOT CHECK: no usable probe image could be run.' -ForegroundColor Yellow
    Note 'The daemon cannot pull a probe image either - that IS the egress problem.'
    Note "Tried: $img"
    Write-Host 'RESULT: 0 passed, 0 failed (CANNOT CHECK - no probe image)' -ForegroundColor Yellow
    exit 2
}

if ($dockerFailed.Count -gt 0) {
    foreach ($t in $dockerFailed) { Bad "container cannot reach $t" }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'RESULT: Docker egress is healthy for every build target.' -ForegroundColor Green
    $ErrorActionPreference = $prevEap
    exit 0
}

# ── 4. Name the cause, not just the symptom ────────────────────────────────
Write-Host 'DOCKER EGRESS IS BROKEN - a build would fail with an SSL/connection error.' -ForegroundColor Red
Write-Host ''
if ($hostDown.Count -eq 0) {
    Write-Host 'DIAGNOSIS: the host reaches every target but Docker does not.' -ForegroundColor Yellow
    Write-Host '  That is a proxy or daemon-network problem, NOT an upstream outage and' -ForegroundColor Yellow
    Write-Host '  NOT a registry-visibility problem. Docker Desktop relays through the' -ForegroundColor Yellow
    Write-Host '  WinINET system proxy; if that proxy is set but its upstream is dead, or' -ForegroundColor Yellow
    Write-Host '  the targets are missing from ProxyOverride, every registry fails the' -ForegroundColor Yellow
    Write-Host '  same way and it reads like GHCR is blocking you.' -ForegroundColor Yellow
    Write-Host ''
    $ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty $ie -ErrorAction SilentlyContinue
    if ($p) {
        Write-Host ("  ProxyEnable   : {0}" -f $p.ProxyEnable) -ForegroundColor Gray
        Write-Host ("  ProxyServer   : {0}" -f $p.ProxyServer) -ForegroundColor Gray
        $ov = "$($p.ProxyOverride)"
        $missing = @($Targets | Where-Object { $ov -notmatch [regex]::Escape($_) })
        if ($missing.Count -gt 0) {
            Write-Host ("  NOT bypassed  : {0}" -f ($missing -join ', ')) -ForegroundColor Yellow
            Note 'Docker matches ProxyOverride by EXACT hostname. A wildcard like'
            Note '*.ghcr.io does nothing; add the bare hostname.'
        }
        else {
            Write-Host '  ProxyOverride : every build target is already bypassed' -ForegroundColor Gray
            Note 'The bypass list looks right, so suspect a dead proxy upstream:'
            Note 'the listener accepts CONNECT and then drops the tunnel.'
        }
    }
    Write-Host ''
    Write-Host '  Fastest check: disable the system proxy for the build window,' -ForegroundColor Yellow
    Write-Host '  or add the missing hostnames to ProxyOverride, then re-run this.' -ForegroundColor Yellow
}
else {
    Write-Host "DIAGNOSIS: neither the host nor Docker can reach: $($hostDown -join ', ')" -ForegroundColor Yellow
    Write-Host '  This is a genuine network outage (or DNS failure), not a proxy or' -ForegroundColor Yellow
    Write-Host '  registry-policy issue. Fix connectivity and retry.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host ("RESULT: {0} of {1} build target(s) unreachable from Docker." -f $fail, $Targets.Count) -ForegroundColor Red
$ErrorActionPreference = $prevEap
exit 1
