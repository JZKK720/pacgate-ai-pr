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
#   2. the image the container actually RUNS has the same IDENTITY as the image
#      the pin's tag NOW NAMES - not that the two tag STRINGS read alike;
#   3. the pins themselves agree on one version (a mixed PIN is a different bug
#      and would make the per-service comparison meaningless).
#
# WHY IDENTITY AND NOT THE TAG STRING (fixed 2026-11-23)
#
# This gate used to compare the container's `.Config.Image` - the string the
# container was CREATED WITH - against the compose pin. That comparison is a
# tautology: `.Config.Image` is written at create time and NEVER changes when the
# tag is re-pointed at different bytes, so the assertion could only ever fail if
# someone hand-edited the compose pin. It was green about a property it did not
# test.
#
# That is exactly the 2026-11-22 incident: a local build took the `0.2.37` tag,
# the stack was deployed from it, then a later `docker pull` re-pointed the tag at
# the published image. `ocr-service` kept running the locally-built bytes with no
# tag at all, under a pin that named the published release - and this gate
# reported PASS throughout.
#
# The consequence is not cosmetic. Containers are immutable: re-pointing a tag
# does not restart them, so the stack genuinely keeps executing the old bytes.
# Only an identity comparison can see that.
#
# Proved by mutation (scripts/test-coherence-mutations.ps1), and reproduced
# end-to-end before the fix: with the `pacgate-api:0.2.37` tag re-pointed at
# `alpine:3.20` while the container kept running the real release, this gate
# printed "14 passed ... every running service is the image its compose pin
# names" and exited 0. It now fails that case.
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

# 3. The comparison that this gate exists for: the image the container RUNS has
#    the same identity as the image its pin's tag NOW NAMES.
#
#    Not the tag strings. `.Config.Image` is frozen at create time, so comparing
#    it to the pin asks only "was this container created from this reference" -
#    true even when the tag has since been re-pointed at different bytes. See the
#    header. `.Image` is the digest actually executing; `docker image inspect
#    <tag> .Id` is the digest that tag resolves to right now. Those two are the
#    same question a client asks: "am I running the release, or something else
#    wearing its tag?"
#
#    Resolution failures are CANNOT CHECK, never a silent skip. Without the tag's
#    ID there is nothing to compare, and treating "not resolvable" as "fine" is
#    how the original defect stayed invisible.
$mismatches = @()
foreach ($svc in $release) {
    $cn = if ($svc.Container) { $svc.Container } else { $svc.Service }
    if (-not $running.ContainsKey($cn)) { continue }

    $runningId = (docker inspect $cn --format '{{.Image}}' 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($runningId)) {
        Check "$($svc.Service) image is identifiable" $false "docker inspect returned no .Image for '$cn'"
        continue
    }

    # The tag is read LOCALLY on purpose: the pin is asserted against what this
    # machine would deploy, and a network round to GHCR would turn a local
    # coherence question into an availability question. (test-release-provenance
    # already asserts the published side.)
    $tagId = (docker image inspect $svc.Image --format '{{.Id}}' 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($tagId)) {
        Check "$($svc.Service) pinned tag resolves locally" $false "pin '$($svc.Image)' is not present on this machine - cannot compare identity (run a compose pull first)"
        continue
    }

    $ok = ($runningId -eq $tagId)
    if (-not $ok) {
        $mismatches += [pscustomobject]@{
            Service = $svc.Service; Pinned = $svc.Image
            Running = $runningId; TagNow = $tagId
        }
    }
    Check "$($svc.Service) runs the image its pinned tag names" $ok `
        "pin '$($svc.Image)' now resolves to $tagId but '$cn' is running $runningId - the tag was re-pointed after this container was created (a re-create is required; the container keeps the old bytes)"
}

# 4. The gate must DISCRIMINATE, and it must discriminate the RIGHT thing.
#
#    The previous version of this block compared two different VERSION STRINGS
#    ('...:0.2.3' vs '...:0.2.1'). That was not the field incident and never
#    could be: the pin and the container's `.Config.Image` both come from the
#    same compose file, so a re-pointed tag leaves them byte-identical. The old
#    negative case was green about a comparison the incident had already proved
#    useless - a check that cannot fail, reporting as coverage.
#
#    The pair below is the REAL shape: one tag, two digests. `d9e853e87e55` is
#    `alpine:3.20` and `fba6dd2e7140` is the 0.2.37 `pacgate-api` - the exact
#    substitution used to reproduce the defect end-to-end before this fix.
function Test-ImageIdentityMatch([string]$tagId, [string]$runningId) { return ($tagId -eq $runningId) }

Check 'identity comparison ACCEPTS the image the tag names' `
    (Test-ImageIdentityMatch 'sha256:fba6dd2e7140' 'sha256:fba6dd2e7140') `
    'a container running exactly what its tag names must not be reported as a mismatch'

Check 'identity comparison DETECTS a re-pointed tag (so the gate can fail)' `
    (-not (Test-ImageIdentityMatch 'sha256:d9e853e87e55' 'sha256:fba6dd2e7140')) `
    'the 2026-11-22 re-point (locally-built bytes -> published bytes under one tag) must be visible; without this the gate cannot fail'

# The assertion above only proves the HELPER discriminates. It says nothing about
# whether the gate calls it with two digests - the original defect was a correct
# comparison of the wrong field. So assert the FIELD ITSELF, permanently.
#
# Comment lines are stripped before scanning. Without that, this check matches its
# own explanation (the header quotes `{{.Config.Image}}` to describe the bug) and
# fails on the fix - the same trap the mutation harness records: a "caught" test
# that matches its own [PASS] line's text. Only the executable `docker inspect`
# calls decide the verdict.
$selfTxt = if ($PSCommandPath) { Get-Content $PSCommandPath -Raw } else { '' }
$codeLines = @(($selfTxt -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' })
$containerInspect = @($codeLines | Where-Object { $_ -match 'docker\s+inspect' -and $_ -notmatch 'docker\s+image\s+inspect' -and $_ -match '--format' })
$usesConfigImage = @($containerInspect | Where-Object { $_ -match '\{\{\s*\.Config\.Image\s*\}\}' })
$usesRunningImage = @($containerInspect | Where-Object { $_ -notmatch '\{\{\s*\.Image\s*\}\}' })

Check 'the gate inspects the RUNNING digest, not the create-time tag string' `
    ($containerInspect.Count -gt 0 -and $usesConfigImage.Count -eq 0 -and $usesRunningImage.Count -eq 0) `
    ("found {0} container inspect call(s); {1} use .Config.Image (frozen at create time, reads identically after a re-point - how this gate stayed green through 2026-11-22); {2} do not read .Image" -f `
        $containerInspect.Count, $usesConfigImage.Count, $usesRunningImage.Count)

# The FIELD being right does not make the COMPARISON right: `$ok = $true` reads the
# correct digest and ignores it. That substitution is invisible to every assertion
# above on a coherent stack - the whole reason the original defect survived - so
# assert the comparison actually consumes both operands.
$verdictLine = @($codeLines | Where-Object { $_ -match '^\s*\$ok\s*=' })
$wired = @($verdictLine | Where-Object { $_ -match '\$runningId' -and $_ -match '\$tagId' })

Check 'the verdict compares the running digest against the tag digest' `
    ($verdictLine.Count -eq 1 -and $wired.Count -eq 1) `
    ("expected exactly one `$ok = ... verdict; found {0}, of which {1} reference both `$runningId and `$tagId - a verdict that reads one operand and decides anyway is the defect, not the fix" -f `
        $verdictLine.Count, $wired.Count)

Write-Host ''
if ($mismatches.Count -gt 0) {
    Write-Host 'MIXED STACK - these services are not the release the pins name:' -ForegroundColor Red
    foreach ($m in $mismatches) {
        Write-Host ("  {0,-20} pin {1}" -f $m.Service, $m.Pinned) -ForegroundColor Red
        Write-Host ("  {0,-20}   runs {1}" -f '', $m.Running) -ForegroundColor Red
        Write-Host ("  {0,-20}   tag  {1}" -f '', $m.TagNow) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  A running container keeps the bytes it was created with. Re-pointing a tag' -ForegroundColor Yellow
    Write-Host '  does not restart it, so these services must be RECREATED:' -ForegroundColor Yellow
    Write-Host ("    docker compose -f {0} up -d --force-recreate {1}" -f $ComposeFile, (($mismatches | ForEach-Object { $_.Service }) -join ' ')) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  If the tag itself is wrong (a local build took it), re-pull before recreating:' -ForegroundColor Yellow
    Write-Host ("    docker compose -f {0} pull {1}" -f $ComposeFile, (($mismatches | ForEach-Object { $_.Service }) -join ' ')) -ForegroundColor Gray
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
