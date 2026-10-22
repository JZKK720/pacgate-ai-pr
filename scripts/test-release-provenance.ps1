# Asserts that the release TAG identifies the artifacts that were actually
# PUBLISHED - i.e. that the tag is still the recipe for what a client pulls.
#
# WHY THIS EXISTS (the 0.1.28 defect it was written from)
#
# The chain of events had no broken link and no failing check, and still shipped
# a tag that did not identify the release:
#
#   1. `v0.1.28` was tagged at fffec57 and pushed -> build-ghcr.yml fired on the
#      push and published five images, revision fffec57. Correct at the time.
#   2. The OCR weights bake (feat: bake PP-OCRv4 weights) then landed in afe2965,
#      on main, AFTER the tag.
#   3. `workflow_dispatch` was used - correctly, to publish the bake without
#      minting a new version - and build-ghcr.yml was run on main. It OVERWROTE
#      the existing 0.1.28 packages with revision afe2965.
#   4. The tag was never moved. It still pointed at fffec57.
#
# Measured: `git ls-tree -r --name-only 'v0.1.28^{commit}' -- deploy/ocr-service/`
# contains no `warm_up.py`, while every published 0.1.28 image reports
# `org.opencontainers.image.revision = afe29654d05025e2f32eb9bd635be74f292d0df7`.
#
# The published artifacts were correct. The TAG was wrong. That is a real
# release defect: `preflight-release-tag.ps1` refuses to re-tag while the tag and
# the packages exist, so the only way to re-derive 0.1.28 is FROM THE TAG - and a
# rebuild from that tag would have reproduced the BAKE-LESS image. The recipe for
# the release no longer produced the release.
#
# Nothing in this repo could see it. `preflight-release-tag.ps1` only checks
# before a release; `smoke-full-stack.ps1` only asserts that /version carries
# SOME revision, never that it is the tag's. This gate closes that hole from both
# ends: what the registry says the images are (self-contained, works on any
# machine, no local docker), and what the tag would rebuild.
#
# The mechanism that makes it possible, worth stating because it is not obvious:
# `Resolve image tag` in build-ghcr.yml reads `inputs.tag` on a dispatch and
# `github.ref_name` on a push, and `actions/checkout` sets no explicit `ref:`. So
# a dispatch checks out MAIN while still publishing the OLD version number. Any
# dispatch after a tag moves the artifact without moving the tag. This gate is
# the only thing that notices.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check (pre-publication window).

[CmdletBinding()]
param(
    # Version to check. Empty = the workspace version from Cargo.toml, so a bump
    # needs no edit here.
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Info($m) { Write-Host "        $m" -ForegroundColor DarkGray }

. (Join-Path $PSScriptRoot 'lib/Release-ImageState.ps1')

Write-Host '=== release tag vs published artifact provenance ===' -ForegroundColor Cyan

if (-not $Version) { $Version = Get-ReleaseVersion }
if (-not $Version) {
    Fail 'could not read the workspace version from pacgate-ai/Cargo.toml'
    Write-Host ''
    Write-Host 'FAILED: cannot determine which release to check; the gate would pass vacuously' -ForegroundColor Red
    exit 1
}
$tag = "v$Version"
Info "release under test: $Version (tag $tag)"

# ---------------------------------------------------------------------------
# 1. What the registry says the published images are.
# ---------------------------------------------------------------------------

function Get-ImageRevisionLabel {
    <#
    .SYNOPSIS
        Read `org.opencontainers.image.revision` from a published image, straight
        from the registry - no docker, no local pull, no running stack.

    .DESCRIPTION
        Needed because the running container on any given box reports the
        revision it was STARTED from, which may be an older pull (this dev box sat
        on fffec57 while the registry served afe2965). Only the registry is
        authoritative about what a client will pull.

        Registry mechanics that are easy to get wrong and cost real debugging
        time here:
          * Two Accept lists are required, and they are NOT interchangeable. An
            index (multi-arch) manifest is fetched with the index/manifest-list
            types; a CHILD manifest is an OCI *single-image* manifest and 404s if
            you only offer index types.
          * The revision is a LABEL, which lives in the image CONFIG BLOB - so it
            is a third request after the manifest, not a field of it.
          * The second blob GET is authenticated with the SAME token: that token
            already covers its repository. Re-minting is wasted work, and on GHCR
            the blob endpoint is not anonymous.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )
    $repo = "$Namespace/$Repository"
    $idxAccept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
    $manAccept = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
    $host_ = 'https://ghcr.io'
    $tok = (Invoke-RestMethod -Uri "$host_/token?scope=repository:$repo`:pull&service=ghcr.io" -Method Get -TimeoutSec 20).token
    $man = Invoke-RestMethod -Uri "$host_/v2/$repo/manifests/$Tag" -Method Get -TimeoutSec 20 `
        -Headers @{ Authorization = "Bearer $tok"; Accept = $idxAccept }
    if ($man.manifests) {
        # Prefer linux/amd64 - the platform the bundle ships. `unknown/unknown`
        # entries appear in these indexes (attestation/SBOM) and are not images.
        $child = @($man.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' } | Select-Object -First 1)
        if (-not $child) { $child = @($man.manifests | Where-Object { $_.platform.os -eq 'linux' } | Select-Object -First 1) }
        if (-not $child) { throw "no linux child manifest in the index for $repo`:$Tag" }
        $man = Invoke-RestMethod -Uri "$host_/v2/$repo/manifests/$($child[0].digest)" -Method Get -TimeoutSec 20 `
            -Headers @{ Authorization = "Bearer $tok"; Accept = $manAccept }
    }
    if (-not $man.config.digest) { throw "manifest for $repo`:$Tag carries no config digest" }
    $blob = Invoke-RestMethod -Uri "$host_/v2/$repo/blobs/$($man.config.digest)" -Method Get -TimeoutSec 20 `
        -Headers @{ Authorization = "Bearer $tok" }
    return [pscustomobject]@{
        Revision = $blob.config.Labels.'org.opencontainers.image.revision'
        Version  = $blob.config.Labels.'org.opencontainers.image.version'
    }
}

# The image set is DERIVED from the compose pins, not listed here. A hardcoded
# list silently stops covering a new first-party image, which is the one thing a
# completeness check must not do. The semver in the pattern is what excludes the
# digest-pinned third-party image (volcengine/openviking).
$pins = @([regex]::Matches((Get-Content 'deploy/client-bundle/compose.prod.yaml' -Raw),
    'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/(?<repo>[A-Za-z0-9._-]+):(?<tag>\d+\.\d+\.\d+)') |
    ForEach-Object { [pscustomobject]@{ Ns = $_.Groups['ns'].Value; Repo = $_.Groups['repo'].Value; Tag = $_.Groups['tag'].Value } } |
    Sort-Object Ns, Repo -Unique)
if ($pins.Count -eq 0) {
    Fail 'could not derive any first-party image pins from compose.prod.yaml'
    Write-Host ''
    Write-Host 'FAILED: the gate would pass vacuously' -ForegroundColor Red
    exit 1
}
Info "derived $($pins.Count) published image(s) from compose.prod.yaml"

$revisions = @{}
$missing = @()
foreach ($p in $pins) {
    $ref = "$($p.Ns)/$($p.Repo):$($p.Tag)"
    try {
        $lab = Get-ImageRevisionLabel -Namespace $p.Ns -Repository $p.Repo -Tag $p.Tag
    }
    catch {
        $missing += $ref
        Info "registry read failed for $ref : $($_.Exception.Message)"
        continue
    }
    if (-not $lab.Revision) {
        Fail "$ref has no org.opencontainers.image.revision label"
        continue
    }
    $revisions[$ref] = $lab.Revision.Substring(0, [Math]::Min(12, $lab.Revision.Length))
    if ($lab.Version -ne $p.Tag) {
        Fail "$ref carries version label '$($lab.Version)' but is pinned as '$($p.Tag)'"
    }
}

# A release window legitimately has unpublished images. Decline to answer rather
# than manufacturing a red - the same contract lib/Release-ImageState.ps1 sets.
if ($missing.Count -gt 0) {
    $reason = if ($revisions.Count -eq 0) {
        "no $Version image is published yet ($($missing -join ', ')) - the release tag has not finished building. Publish the tag, wait for build-ghcr.yml, then re-run."
    } else {
        "only part of $Version is published; missing: $($missing -join ', '). A partially-published release cannot be compared to its tag."
    }
    Exit-NotYetAssertable $reason
}

# ---------------------------------------------------------------------------
# 2. The images must all come from ONE build.
# ---------------------------------------------------------------------------

# @(...) is load-bearing: a one-element pipeline yields a bare STRING, and
# `$string[0]` is its first character, not the element. That silently turned
# "afe29654d05" into "a" while still reporting Count = 1.
$distinct = @($revisions.Values | Sort-Object -Unique)
if ($distinct.Count -eq 1) {
    Pass "all $($revisions.Count) published images share one revision ($($distinct[0]))"
} else {
    # Deliberately FAIL, not "cannot check". The artifacts exist and disagree,
    # which is a stronger signal than the release window (where they do not exist
    # yet): a client pulling RIGHT NOW gets a mixed bundle. The message names both
    # readings so a human mid-build is not misled - an active tag build overwrites
    # the packages one at a time and converges, and a set that stays split is a
    # real divergence.
    Fail "published images came from $($distinct.Count) DIFFERENT builds: $(( $revisions.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    Info 'if a tag build is running, the packages are being overwritten one at a time and this converges when it finishes - re-run then'
    Info 'if no build is running, this is a real divergence: a dispatch overwrote some images and not others'
}

# ORDERING IS LOAD-BEARING. A hard FAIL must never be followed by a
# "cannot check" exit, because run-all-checks.ps1 reads exit 2 as SKIP and the
# real defect would disappear from the report - a gate silently downgrading its
# own failure, which is the exact class of bug this whole file is about. So the
# registry verdict is settled first and terminally.
if ($script:failures -gt 0) {
    Write-Host ''
    Write-Host "FAILED: $($script:failures) provenance defect(s) in the published artifacts" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 3. The tag must exist and be annotated.
# ---------------------------------------------------------------------------

$tagType = (& git cat-file -t $tag 2>$null)
if ($tagType -ne 'tag') {
    Fail "tag $tag is missing or is not annotated (git cat-file -t -> '$tagType')"
    Write-Host ''
    Write-Host "FAILED: cannot compare the tag to the published artifacts" -ForegroundColor Red
    exit 1
}
Pass "tag $tag exists and is annotated"

$tagCommit = (& git rev-parse "$tag^{commit}" 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $tagCommit) {
    Fail "could not resolve $tag to a commit"
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Everything changed since the built revision must be unable to reach an image.
# ---------------------------------------------------------------------------

$builtRev = $null
if ($distinct.Count -eq 1) { $builtRev = $distinct[0] }
$resolved = $null
if ($builtRev) { $resolved = (& git rev-parse --verify --quiet "$builtRev^{commit}" 2>$null) }

if (-not $resolved) {
    # The revision label is a 40-char SHA in production, but the local-dev
    # fallback is a short/absent one. Not being able to diff is NOT a failed
    # release; say what could not be checked instead of guessing.
    Exit-NotYetAssertable "published revision label '$builtRev' does not resolve to a commit in this clone (label present but truncated/unknown), so the tag-to-artifact file diff cannot be computed."
}

# Per-image build inputs, derived from each Dockerfile's `file:` + `context:` in
# build-ghcr.yml. Only paths INSIDE a build context can reach an image.
#
# Read as: a changed file matching one of these is image-affecting.
$contextPrefixes = @(
    'pacgate-ai/',                     # context: pacgate-ai
    'deploy/pacgate-mcp/',             # context: deploy/pacgate-mcp
    'deploy/ocr-service/',             # context: deploy/ocr-service
    # context: '.' for the two deer-flow images - only their COPY sources reach
    # a layer, so a repo-root context does NOT make every file an input.
    'pacgate-adapters/python/pacgate_deerflow_adapter/',
    'deploy/deer-flow-pacgate/config.yaml',
    'deploy/deer-flow-src/frontend/',
    'deploy/frontend-patches/files/'   # CI copies these INTO the frontend context
)

# A Dockerfile is itself a build input even though it is not a COPY source.
$dockerfiles = @(
    'pacgate-ai/Dockerfile',
    'deploy/pacgate-mcp/Dockerfile',
    'deploy/ocr-service/Dockerfile',
    'deploy/deer-flow-pacgate/Dockerfile',
    'deploy/deer-flow-frontend-pacgate/Dockerfile'
)

# .dockerignore genuinely narrows the pacgate-ai context (this is what excluded
# the changed pacgate-ai-assets/render.py from the image). Honouring its
# directory prefixes here keeps the gate's report actionable instead of listing
# files that provably cannot be in the context. Only directory-prefix lines are
# handled; a glob it does not understand stays in the report, which is the
# conservative direction - an over-report asks a human to look, an under-report
# hides a break.
$ignoredPrefixes = @()
if (Test-Path 'pacgate-ai/.dockerignore') {
    $ignoredPrefixes = @(Get-Content 'pacgate-ai/.dockerignore' |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim().TrimStart('/') } |
        Where-Object { $_ -match '/$' } |
        ForEach-Object { "pacgate-ai/$_" })
}

# Files that a compose file bind-mounts OVER the image copy. A change to one of
# these does NOT make the tag a wrong recipe for the published artifact: the
# artifact is still exactly what the tag builds, and the running container reads
# the host file instead. It is a different (and legitimate) deployment shape -
# the repo's own patch pipeline - so it must be reported, not failed.
#
# This distinction matters because the two failure modes look identical in a
# plain file diff. A change that reaches a layer means "a rebuild from the tag
# would differ from what clients pull" (the 0.1.28 defect). A change that is
# bind-mounted means "clients pull the tag's image and then override one file",
# which is what deploy/client-bundle/compose.prod.yaml does for 20 patches plus
# deploy/pacgate-mcp/server.py. Failing the second would make the gate
# permanently red on any machine that carries a local patch, which is how a gate
# stops being read.
$bindMounted = @()
foreach ($composeFile in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    if (-not (Test-Path $composeFile)) { continue }
    foreach ($line in (Get-Content $composeFile)) {
        # Shape: `- ./patches/x.py:/app/...:ro` or `- ../pacgate-mcp/server.py:/app/server.py:ro`
        if ($line -match '^\s*-\s*(\.\.?/[^:]+):[^:]+') {
            $src = $Matches[1].Trim()
            $full = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $composeFile) $src))
            $rel = [System.IO.Path]::GetRelativePath((Get-Location).Path, $full) -replace '\\', '/'
            if ($rel -and -not $rel.StartsWith('..')) { $bindMounted += $rel }
        }
    }
}
$bindMounted = @($bindMounted | Sort-Object -Unique)

$changed = @(& git diff --name-only "$resolved..HEAD" 2>$null | Where-Object { $_ })
$affecting = @()
$overridden = @()
$benign = @()
foreach ($f in $changed) {
    $isInput = $false
    foreach ($p in $contextPrefixes) { if ($f.StartsWith($p)) { $isInput = $true; break } }
    if ($dockerfiles -contains $f) { $isInput = $true }
    if ($isInput) {
        foreach ($ip in $ignoredPrefixes) { if ($f.StartsWith($ip)) { $isInput = $false; break } }
    }
    if ($isInput -and ($bindMounted -contains $f)) { $overridden += $f }
    elseif ($isInput) { $affecting += $f }
    else { $benign += $f }
}

Info "checked $($changed.Count) file(s) changed between $($builtRev) and HEAD"

if ($affecting.Count -gt 0) {
    Fail "$($affecting.Count) file(s) that CAN reach a built image changed after the published revision was built:"
    $affecting | ForEach-Object { Info "  $_" }
    Info 'the tag does not identify the published artifacts: a rebuild from the tag would differ from what clients pull'
    Info "fix: re-point $tag at the commit the images were built from, or rebuild so they match the tag"
} else {
    Pass "no image-affecting file changed between $($builtRev) and HEAD, so the tag still describes the published artifacts"
    # Reported, not hidden: this is the evidence that the diff was read, and it
    # is what lets a reviewer see the judgement rather than trust a count.
    if ($overridden.Count -gt 0) {
        Info "$($overridden.Count) file(s) changed but are BIND-MOUNTED over the image by compose, so the published artifact is unchanged:"
        $overridden | ForEach-Object { Info "  $_" }
        Info 'the running container reads the host copy, so this is a patch-pipeline change, not a tag/artifact mismatch'
    }
    if ($benign.Count -gt 0) {
        Info "$($benign.Count) file(s) changed but cannot reach an image (docs, gates, CI, ignored context):"
        $benign | ForEach-Object { Info "  $_" }
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) provenance defect(s)" -ForegroundColor Red
    exit 1
}
Write-Host "PASSED: $tag identifies the $($distinct[0]) artifacts clients will pull" -ForegroundColor Green
exit 0
