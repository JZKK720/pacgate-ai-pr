# Assert that EVERY running service is the image its compose pin names.
#
# WHY THIS EXISTS (the 2026-10-23 field reports)
#
# Two AIPC machines deployed 0.2.2, both reported "all gates passed", and both
# were running broken stacks. On this box the same state was reproducible: four
# of five services were executing 0.2.1 images created 2026-10-22 08:00 while
# `pacgate-api` had been recreated on 0.2.3 at 2026-10-23 01:32 - and
# `run-all-checks.ps1` reported ALL 47 GATES PASSED.
#
# Nothing was lying. Every existing version gate looks at ONE service:
#
#   test-staleness-probe.ps1            -> pacgate-api container vs compose pin
#   test-version-marker-against-image.ps1 -> pacgate-api /build-info
#   test-release-provenance.ps1         -> registry labels vs the tag
#   test-compose-healthchecks.ps1       -> healthcheck presence, not identity
#
# So a stack can be arbitrarily mixed and every one of them stays green. That is
# the failure mode this gate closes: it compares ALL pinned services at once.
#
# WHY IT MATTERS BEYOND TIDINESS. `docker compose up -d` DOES recreate a container
# when its image TAG changes - proved with a throwaway project: nginx:1.27-alpine
# -> nginx:1.27 produced "Container cohprobe Recreated" and a new image id, while
# the same tag with no pull produced "Running" and the same id. So a full
# `install.ps1 -Update` does move every service.
#
# The gap is the PARTIAL recreate: someone recreates one service to verify a
# release and leaves the rest on the previous one. That is exactly what happened
# here - pacgate-api was recreated 21 minutes after the v0.2.3 tag while the other
# four still carried 0.2.1 images from the previous day. Most services bind-mount
# their code, which hides it - but `ocr-service` has NO bind mounts at all, so it
# really does run the old `app.py`. Verified on this box: the 0.2.1 container still
# carried the unguarded `box, (text, _conf) = line[0], line[1]`, so one malformed
# OCR line marked the whole page incomplete. 0.2.2 skips the bad line and keeps
# the rest.
#
# WHAT IS ASSERTED
#   1. every service pinning a `ghcr.io/jzkk720/*:<semver>` image is RUNNING;
#   2. its running container's `.Config.Image` equals the pin, exactly;
#   3. the pins themselves agree on one version (a mixed PIN is a different bug
#      and would make the per-service comparison meaningless).
#
# Exit 2 means CANNOT CHECK (stack down) and must never be read as a failure of
# the code - the same contract run-all-checks.ps1 already honours.
[CmdletBinding()]
param(
    [string]$ComposeFile = '',
    # Report only; never fail. For a machine mid-upgrade.
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not $ComposeFile) { $ComposeFile = 'deploy/client-bundle/compose.prod.yaml' }

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $passed passed, $failed failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== stack version coherence (every service vs its compose pin) ==='

if (-not (Test-Path $ComposeFile)) { CannotCheck "compose file not found: $ComposeFile" }

# -Encoding UTF8: PS 5.1 on a Chinese-locale host decodes BOM-less files as
# ANSI/GBK, and compose.prod.yaml carries Chinese comments.
$composeTxt = Get-Content $ComposeFile -Raw -Encoding UTF8

# Parse service -> (container_name, image) from the compose text.
#
# Deliberately a text parse rather than `docker compose config`: that command
# needs the .env to render, and a missing variable turns the whole gate into an
# error about the environment instead of an answer about the stack. The shape
# asserted here is the one the file actually uses - a two-space service key, then
# `image:` and `container_name:` at four spaces.
$services = @()
$current = $null
foreach ($line in ($composeTxt -split "`r?`n")) {
    if ($line -match '^  (?<svc>[a-z0-9][a-z0-9\-]*):\s*$') {
        if ($current) { $services += $current }
        $current = [pscustomobject]@{ Service = $Matches['svc']; Image = $null; Container = $null }
        continue
    }
    if (-not $current) { continue }
    if ($line -match '^\s+image:\s*(?<img>\S+)\s*$')         { $current.Image = $Matches['img'] }
    if ($line -match '^\s+container_name:\s*(?<cn>\S+)\s*$') { $current.Container = $Matches['cn'] }
}
if ($current) { $services += $current }

# Only the release images this repo publishes. A third-party pin (postgres,
# nginx, openviking) is not part of the release and must not be dragged into a
# version-coherence assertion - it would fail on every unrelated upstream bump.
$release = @($services | Where-Object { $_.Image -match '^ghcr\.io/jzkk720/[a-z0-9\-]+:(?<v>\d+\.\d+\.\d+)$' })

Check 'compose declares release services to compare' ($release.Count -gt 0) "no ghcr.io/jzkk720/*:<semver> pins found in $ComposeFile"
if ($release.Count -eq 0) { CannotCheck 'no release services parsed from compose' }

Write-Host ("         {0} release service(s): {1}" -f $release.Count, (($release | ForEach-Object { $_.Service }) -join ', ')) -ForegroundColor DarkGray

# 1. The PINS must agree with each other. A mixed pin is a different defect from a
#    mixed stack, and it would make the per-service comparison below meaningless:
#    every service would "match" its own pin while the release is incoherent.
$pinVersions = @($release | ForEach-Object { [regex]::Match($_.Image, ':(?<v>\d+\.\d+\.\d+)$').Groups['v'].Value } | Sort-Object -Unique)
Check 'all release pins name ONE version' ($pinVersions.Count -eq 1) "compose pins disagree: $($pinVersions -join ', ') - a release is one version across every image"
Write-Host ("         pinned version: {0}" -f ($pinVersions -join ', ')) -ForegroundColor DarkGray

# 2. Every release service must be RUNNING. A stopped service has no image to
#    compare, and silently skipping it is how a gate reports green about a
#    container that is not there.
$running = @{}
$psOut = docker ps --format '{{.Names}}' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $psOut) { CannotCheck 'docker is not reachable or no containers are running' }
foreach ($n in @($psOut)) { if ($n) { $running[$n.Trim()] = $true } }

foreach ($svc in $release) {
    $cn = if ($svc.Container) { $svc.Container } else { $svc.Service }
    Check "$($svc.Service) is running" $running.ContainsKey($cn) "container '$cn' is not in 'docker ps' - a stopped service cannot be compared to its pin"
}

# 3. The comparison that this gate exists for: running image == pinned image.
$mismatches = @()
foreach ($svc in $release) {
    $cn = if ($svc.Container) { $svc.Container } else { $svc.Service }
    if (-not $running.ContainsKey($cn)) { continue }

    $actual = (docker inspect $cn --format '{{.Config.Image}}' 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Check "$($svc.Service) image is identifiable" $false "docker inspect returned no image for '$cn'"
        continue
    }

    $ok = ($actual -eq $svc.Image)
    if (-not $ok) { $mismatches += [pscustomobject]@{ Service = $svc.Service; Pinned = $svc.Image; Running = $actual } }
    Check "$($svc.Service) runs its pinned image" $ok "pinned '$($svc.Image)' but running '$actual'"
}

# 4. The gate must DISCRIMINATE. Without this, a comparison that always answers
#    "OK" would pass every assertion above. Exercised synthetically so it cannot
#    expire when the stack moves - the same lesson test-staleness-probe.ps1
#    records about its own fixture-based negative case.
function Test-ImageMatchesPin([string]$pinned, [string]$actual) { return ($pinned -eq $actual) }
Check 'comparison ACCEPTS a matching image' (Test-ImageMatchesPin 'ghcr.io/jzkk720/pacgate-api:0.2.3' 'ghcr.io/jzkk720/pacgate-api:0.2.3') 'a matching pair was rejected'
Check 'comparison REJECTS a stale image (so the gate can fail)' (-not (Test-ImageMatchesPin 'ghcr.io/jzkk720/pacgate-api:0.2.3' 'ghcr.io/jzkk720/pacgate-api:0.2.1')) 'a 0.2.1 container under a 0.2.3 pin would read as coherent'

Write-Host ''
if ($mismatches.Count -gt 0) {
    Write-Host 'MIXED STACK - these services are not the release the pins name:' -ForegroundColor Red
    foreach ($m in $mismatches) {
        Write-Host ("  {0,-20} pinned {1}  running {2}" -f $m.Service, $m.Pinned, $m.Running) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  Recreate them (a changed bind-mounted file does NOT trigger this):' -ForegroundColor Yellow
    Write-Host ("    docker compose -f {0} up -d --force-recreate {1}" -f $ComposeFile, (($mismatches | ForEach-Object { $_.Service }) -join ' ')) -ForegroundColor Gray
    Write-Host ''
}

if ($ReportOnly) {
    Write-Host "RESULT: $passed passed, $failed failed (REPORT ONLY - not failing the run)" -ForegroundColor Yellow
    exit 0
}

if ($failed -gt 0) {
    Write-Host "RESULT: $passed passed, $failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: every running service is the image its compose pin names. ($passed passed)" -ForegroundColor Green
exit 0
