# Prune old GHCR image versions, keeping the newest N releases.
#
# WHY THIS IS A SCRIPT AND NOT A ONE-OFF COMMAND
# ----------------------------------------------
# There are ~210 tags across six packages. Deleting a GHCR version is IRREVERSIBLE
# and destroys EVERY tag pointing at that digest at once, so a loop typed by hand
# is the wrong instrument: one wrong index and a shipped release is gone.
#
# HOW DELETION ACTUALLY WORKS (measured 2026-11-03):
#   * The registry API does NOT delete GHCR manifests. `DELETE /v2/<repo>/manifests/
#     <digest>` answers 405 for every credential, so a docker/registry-based script
#     cannot work here no matter what it is given.
#   * Deletion goes through the GitHub Packages REST API and needs a token with
#     BOTH read:packages and delete:packages. A classic PAT carrying only
#     `gist, repo, workflow` gets 403 "You need at least read:packages scope".
#     The registry token endpoint still returns 200 for a `delete` scope it will not
#     honour, so a 200 there is NOT evidence of permission.
#   * `latest` and a release tag can share ONE digest. Deleting the version behind
#     an old tag would then also delete `latest`. The plan resolves digests from the
#     listing and refuses any version that a kept tag or `latest` also points at.
#
# SAFETY MODEL
#   Default is a dry run: print the full plan and change nothing. Deletion needs an
#   explicit -Execute plus a typed confirmation, unless -Force is given.
#
# Usage:
#   .\scripts\prune-ghcr-versions.ps1                      # show the plan
#   $env:GHCR_PRUNE_TOKEN = '<read:packages + delete:packages>'
#   .\scripts\prune-ghcr-versions.ps1 -Execute             # delete it
#
# Offline testing: -FixturePath reads <package>.json files shaped like the API
# response instead of calling GitHub, so the keep/drop maths is verifiable without
# a credential. See scripts/test-prune-ghcr-versions.ps1.
#
# Exit codes: 0 = ok/no work, 1 = refused or a delete failed, 2 = cannot check.

[CmdletBinding()]
param(
    # How many of the newest semver releases to keep. "The two versions before the
    # latest" is 3 releases total: the newest plus the two previous.
    [int]$KeepReleases = 3,

    # Package names under the namespace. Explicit on purpose: a typo must not prune
    # an unrelated package, and a new package is added deliberately.
    [string[]]$Packages = @(
        'pacgate-api'
        'pacgate-mcp'
        'ocr-service'
        'deer-flow-pacgate'
        'deer-flow-frontend-pacgate'
        'laya-serve'
    ),

    [string]$Namespace = 'jzkk720',

    # Non-semver tags that are known litter. Never part of a release, so they are
    # pruned regardless of -KeepReleases.
    [string[]]$JunkTags = @('tmp-del', 'connectivity-test', 'connectivity-test-delete'),

    # Offline mode: directory of <package>.json version listings.
    [string]$FixturePath = '',

    # Packages API base. Overridable so this can run inside GitHub Actions, where
    # GITHUB_TOKEN may only reach the /repos/{owner}/{repo} form and cannot use the
    # /user form that a personal token uses.
    [string]$ApiBase = 'https://api.github.com/user/packages/container',

    [switch]$Execute,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Explicitly NOT read from the environment proxy: a stale HTTP_PROXY aimed at a dead
# local port makes every request fail as "network", which reads like an outage.
$env:HTTP_PROXY = ''
$env:HTTPS_PROXY = ''
$env:http_proxy = ''
$env:https_proxy = ''

function Exit-CannotCheck([string]$why) {
    Write-Host ''
    Write-Host "CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host '              Nothing was deleted.' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

$token = $env:GHCR_PRUNE_TOKEN
$useFixtures = -not [string]::IsNullOrWhiteSpace($FixturePath)

if (-not $useFixtures -and [string]::IsNullOrWhiteSpace($token)) {
    Exit-CannotCheck @"
No token. Set GHCR_PRUNE_TOKEN to a token with read:packages + delete:packages.
  Measured 2026-11-03: this machine's git credential carries scopes
  'gist, repo, workflow' only, so the packages API answers HTTP 403. A 200 from
  https://ghcr.io/token?...:delete proves nothing - it is returned regardless.
  Create one at https://github.com/settings/tokens (classic) with read:packages
  and delete:packages ticked.
"@
}

$apiBase = $ApiBase.TrimEnd('/')

function Invoke-GitHub([string]$uri, [string]$method = 'GET') {
    # Invoke-WebRequest, NOT curl.exe.
    #
    # MEASURED 2026-11-03 on the first Actions run: this was written against
    # `curl.exe`, which exists on Windows but has no equivalent executable on the
    # ubuntu-latest runner, so the pruner died with "The term 'curl.exe' is not
    # recognized" before it listed a single version. .NET is the only HTTP client
    # guaranteed on both, and -SkipHttpErrorCheck returns the status code for 4xx/5xx
    # instead of throwing, which is what the curl -w "%{http_code}" form existed for.
    $headers = @{
        Authorization          = "Bearer $token"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method $method -Headers $headers `
            -UseBasicParsing -TimeoutSec 60 -SkipHttpErrorCheck
        return [pscustomobject]@{ Code = [int]$resp.StatusCode; Body = [string]$resp.Content }
    }
    catch {
        # Transport failure, not an HTTP answer. Code 0 so the caller reads it as
        # "cannot check" rather than as a permissions problem.
        return [pscustomobject]@{ Code = 0; Body = $_.Exception.Message }
    }
}

function Get-SortKey([string]$tag) {
    # Junk and alias tags are not versions. Sorting them with a [version] cast throws
    # "Version string portion was too short or too long", which killed the dry run
    # after it had already computed the plan. Non-semver tags sort last.
    $v = $null
    if ([version]::TryParse($tag, [ref]$v)) { return @(0, $v) }
    return @(1, [version]'0.0.0')
}

function Get-VersionListing([string]$pkg) {
    if ($useFixtures) {
        $f = Join-Path $FixturePath "$pkg.json"
        if (-not (Test-Path $f)) { Exit-CannotCheck "fixture missing: $f" }
        return (Get-Content $f -Raw | ConvertFrom-Json)
    }
    $resp = Invoke-GitHub "$apiBase/$pkg/versions?per_page=100"
    if ($resp.Code -ne 200) {
        $why = if ($resp.Code -eq 403) { 'token lacks read:packages' } else { "HTTP $($resp.Code)" }
        Exit-CannotCheck "cannot list versions for $pkg ($why). Body: $($resp.Body)"
    }
    return ($resp.Body | ConvertFrom-Json)
}

# ── Build the plan ───────────────────────────────────────────────────────────
Write-Host ''
Write-Host "=== GHCR prune plan: keep the newest $KeepReleases release(s) ===" -ForegroundColor Cyan
Write-Host "    namespace: $Namespace"
Write-Host "    mode: $(if ($useFixtures) { 'offline fixture' } elseif ($Execute) { 'EXECUTE' } else { 'dry run' })"
Write-Host ''

$plan = @()
$guards = @()

foreach ($pkg in $Packages) {
    $versions = @(Get-VersionListing $pkg)
    if ($versions.Count -eq 0) {
        Write-Host "  $pkg - no versions returned" -ForegroundColor Yellow
        continue
    }

    # tag -> digest, and digest -> version id. `name` IS the manifest digest.
    $tagToDigest = @{}
    $digestToId = @{}
    foreach ($v in $versions) {
        if ($v.name) { $digestToId[$v.name] = $v.id }
        foreach ($t in @($v.metadata.container.tags)) {
            if ($t) { $tagToDigest[$t] = $v.name }
        }
    }

    # Semantic versions only. `latest` is excluded: it is an alias governed by the
    # publish workflow, not a release this script gets to schedule.
    $semver = @($tagToDigest.Keys |
        Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_ } -Descending)
    $keep = @($semver | Select-Object -First $KeepReleases)
    $drop = @($semver | Select-Object -Skip $KeepReleases)
    $junk = @($tagToDigest.Keys | Where-Object { $JunkTags -contains $_ })
    $other = @($tagToDigest.Keys | Where-Object {
            $_ -ne 'latest' -and $_ -notmatch '^\d+\.\d+\.\d+$' -and $JunkTags -notcontains $_
        })

    # Protected digests: everything a kept tag or `latest` resolves to.
    $protected = @{}
    foreach ($t in $keep) { if ($tagToDigest[$t]) { $protected[$tagToDigest[$t]] = $t } }
    $latestDigest = $tagToDigest['latest']
    if ($latestDigest) { $protected[$latestDigest] = 'latest' }

    $latestAlias = if ($latestDigest) {
        $hits = @($tagToDigest.Keys | Where-Object { $tagToDigest[$_] -eq $latestDigest -and $_ -ne 'latest' })
        if ($hits.Count -gt 0) { $hits[0] } else { 'no release tag' }
    }
    else { 'none' }
    Write-Host ("  {0,-30} keep {1,-18} latest -> {2}" -f $pkg, ($keep -join ', '), $latestAlias)

    foreach ($t in $drop) {
        $d = $tagToDigest[$t]
        if ($protected.ContainsKey($d)) {
            $guards += "$pkg`:$t shares a digest with $($protected[$d]); skipped"
            continue
        }
        $co = @($tagToDigest.Keys | Where-Object { $tagToDigest[$_] -eq $d -and $_ -ne $t })
        $plan += [pscustomobject]@{
            Package  = $pkg
            Tag      = $t
            Digest   = $d
            AlsoTags = ($co -join ',')
            Reason   = 'older release'
        }
    }

    foreach ($t in $junk) {
        $d = $tagToDigest[$t]
        if ($protected.ContainsKey($d)) {
            $guards += "$pkg`:$t shares a digest with $($protected[$d]); skipped"
            continue
        }
        $co = @($tagToDigest.Keys | Where-Object { $tagToDigest[$_] -eq $d -and $_ -ne $t })
        $plan += [pscustomobject]@{
            Package  = $pkg
            Tag      = $t
            Digest   = $d
            AlsoTags = ($co -join ',')
            Reason   = 'junk tag'
        }
    }

    if ($other.Count -gt 0) {
        $guards += "$pkg has non-release tags not in -JunkTags, left alone: $($other -join ', ')"
    }
}

# Collapse to ONE row per (package, digest).
#
# A digest can carry several tags: measured on the real registry, `0.2.13` and the
# leftover `tmp-del` point at the SAME manifest. Listing them separately overstates
# the work and, worse, the second DELETE answers 404 because the first already
# removed the manifest - turning a fully successful run into a reported failure.
$merged = [ordered]@{}
foreach ($p in $plan) {
    $key = "$($p.Package)|$($p.Digest)"
    if ($merged.Contains($key)) {
        $ex = $merged[$key]
        if ($ex.Tags -notcontains $p.Tag) { $ex.Tags = @($ex.Tags) + $p.Tag }
        if ($ex.Reasons -notcontains $p.Reason) { $ex.Reasons = @($ex.Reasons) + $p.Reason }
    }
    else {
        $merged[$key] = [pscustomobject]@{
            Package = $p.Package
            Digest  = $p.Digest
            Tags    = @($p.Tag)
            Reasons = @($p.Reason)
        }
    }
}
$plan = @($merged.Values)

Write-Host ''
Write-Host "=== Versions to delete ($($plan.Count)) ===" -ForegroundColor Cyan
if ($plan.Count -eq 0) {
    Write-Host '  none'
}
else {
    $plan |
        Sort-Object Package, { Get-SortKey ($_.Tags | Select-Object -First 1) } |
        Select-Object Package, @{ n = 'Tags'; e = { $_.Tags -join ', ' } },
        @{ n = 'Reason'; e = { $_.Reasons -join '+' } } |
        Format-Table -AutoSize |
        Out-String -Width 200 |
        Write-Host
}

if ($guards.Count -gt 0) {
    Write-Host '=== Deliberately NOT deleting (guard) ===' -ForegroundColor Yellow
    $guards | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ''
}

if (-not $Execute) {
    Write-Host 'DRY RUN - nothing was deleted.' -ForegroundColor Green
    Write-Host 'Re-run with -Execute after reviewing the list above.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

if ($useFixtures) {
    Write-Host 'REFUSED: -Execute cannot be combined with -FixturePath.' -ForegroundColor Red
    exit 1
}
if ($plan.Count -eq 0) { exit 0 }

if (-not $Force) {
    $ans = Read-Host "Type DELETE to remove $($plan.Count) version(s) permanently"
    if ($ans -ne 'DELETE') {
        Write-Host 'REFUSED: confirmation not given. Nothing was deleted.' -ForegroundColor Red
        exit 1
    }
}

# Re-list to collect version ids at delete time, so an id is never inferred.
$idByKey = @{}
foreach ($pkg in $Packages) {
    $versions = @(Get-VersionListing $pkg)
    foreach ($v in $versions) { if ($v.name) { $idByKey["$pkg|$($v.name)"] = $v.id } }
}

$deleted = 0
$failed = 0
foreach ($p in $plan) {
    $label = ($p.Tags -join ',')
    $vid = $idByKey["$($p.Package)|$($p.Digest)"]
    if (-not $vid) {
        Write-Host "  SKIP   $($p.Package):$label - no version id for $($p.Digest)" -ForegroundColor Yellow
        $failed++
        continue
    }
    $r = Invoke-GitHub "$apiBase/$($p.Package)/versions/$vid" 'DELETE'
    if ($r.Code -eq 204) {
        Write-Host "  deleted $($p.Package):$label" -ForegroundColor Green
        $deleted++
    }
    else {
        Write-Host "  FAILED  $($p.Package):$label - HTTP $($r.Code) $($r.Body)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
Write-Host "deleted $deleted, failed $failed" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }
exit 0
