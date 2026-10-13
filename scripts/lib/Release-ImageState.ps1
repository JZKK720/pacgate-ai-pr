# Shared release-image state probe.
#
# WHY THIS EXISTS
#
# A version-pinned gate has three states, not two, and the third one is invisible
# to an exit code:
#
#   1. the image exists and the gate PASSED      -> green, real assurance
#   2. the image exists and the gate FAILED      -> red, real defect
#   3. the image DOES NOT EXIST YET              -> NOT YET ASSERTABLE
#
# State 3 is the release window: `bump-release-version.ps1` rewrites Cargo.toml
# and the compose pins, but no image at the new version is published until the
# tag push finishes building. Every version-pinned gate then derives the NEW
# version, finds no image, and fails. On 0.1.28 that produced FIVE red gates in
# one `run-all-checks.ps1` run - and every one of their messages read like a
# product fault: "running image is stale", "docker run failed", "SOME CHECKS
# FAILED", "a reachable lane is broken", and eleven cascading sanitizer FAILs.
#
# It was none of those. Measured, not assumed: test-sanitizer-e2e.ps1 against the
# published `pacgate-api:0.1.27` image is 16/16 PASS. The only thing wrong was
# that the suite was asked a question about an artefact that did not exist yet,
# and it answered "broken" instead of "nothing to test".
#
# That is worse than a cosmetic problem. It is the same failure mode the headers
# of run-all-checks.ps1, test-version-marker-against-image.ps1 and
# test-sanitizer-e2e.ps1 each warn about in turn: a red suite that is mostly
# noise teaches people to ignore the suite, and a genuine 0.1.28-only defect
# would arrive inside a red wall nobody reads. This repo has already lost three
# assertions that way.
#
# So the rule enforced here: an ABSENT artefact is reported as NOT YET ASSERTABLE
# (exit 2, i.e. "cannot check"), which run-all-checks.ps1 already treats as SKIP
# rather than FAILURE. A PRESENT artefact that misbehaves still fails normally.
# The gate can never go green on a real defect - it can only decline to answer
# about something that is not there.
#
# The probe deliberately distinguishes three registry answers, because treating
# them alike is a documented trap (see scripts/check-ghcr-anon.py):
#   200 -> published, pullable, assertable
#   404 -> tag absent, or a private package's missing tag: NOT YET ASSERTABLE
#   other/transport error -> UNKNOWN; never silently read as "absent"

function Test-GhcrManifestPresent {
    <#
    .SYNOPSIS
        Does <repo>:<tag> exist on GHCR, answerable without credentials?
    .OUTPUTS
        'present' | 'absent' | 'unknown'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag
    )
    $repo = "$Namespace/$Repository"
    $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
    try {
        $tok = Invoke-RestMethod -Uri "https://ghcr.io/token?scope=repository:$repo`:pull&service=ghcr.io" -Method Get -TimeoutSec 20
        # -UseBasicParsing is REQUIRED: without it Windows PowerShell 5.1
        # dispatches to the IE-based parser, which throws NullReferenceException
        # on a manifest HEAD response.
        $r = Invoke-WebRequest -Uri "https://ghcr.io/v2/$repo/manifests/$Tag" -Method Head -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $($tok.token)"; Accept = $accept } -TimeoutSec 20
        if ($r.StatusCode -eq 200) { return 'present' }
        return 'unknown'
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) { return 'absent' }
        return 'unknown'
    }
}

function Test-ImageTagLocally {
    <#
    .SYNOPSIS
        Is a local docker image tag present? Used so a locally-built image (e.g.
        the clean-clone proof builds pacgate-api:local) is still assertable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference)
    $have = @(docker images --format '{{.Repository}}:{{.Tag}}' 2>$null) -contains $Reference
    if ($have) { return 'present' }
    return 'absent'
}

function Get-ReleaseVersion {
    <#
    .SYNOPSIS
        The workspace version, from the crate manifest - the same source of truth
        `preflight-release-tag.ps1` and `/build-info` (via CARGO_PKG_VERSION) use.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $toml = Join-Path $RepoRoot 'pacgate-ai/Cargo.toml'
    if (-not (Test-Path $toml)) { return '' }
    return ([regex]::Match((Get-Content $toml -Raw), '(?m)^version\s*=\s*"(?<v>\d+\.\d+\.\d+)"')).Groups['v'].Value
}

function Get-ReleaseOcrImage {
    <#
    .SYNOPSIS
        The ocr-service image reference for the release under test, e.g.
        ghcr.io/jzkk720/ocr-service:0.1.28. Derived, never hardcoded.

    .DESCRIPTION
        Gates used to reference an invented `ocr-service:local` tag instead. That
        tag was a hand-made leftover (see run-all-checks.ps1's own note: "Nothing
        ever built that tag"), and it served three unrelated needs at once:

          - fixture building, which only ever needed `python3` + PIL and does not
            need OCR at all;
          - the OCR service under test, which must be the RELEASE image;
          - fixture/release equivalence, which needs exactness.

        An unversioned tag satisfies none of them properly. In particular it hides
        the property that matters most for the weights bake: ocr-service must
        extract with NO NETWORK. A stale `:local` cannot assert that; the real
        reference can, and is what a client actually runs.

        Callers that need the image PRESENT can use Test-ReleaseOcrImagePresent
        first, which distinguishes "absent (release window)" from "wrong".
    #>
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $ver = Get-ReleaseVersion -RepoRoot $RepoRoot
    if (-not $ver) { return '' }
    $compose = Join-Path $RepoRoot 'deploy/client-bundle/compose.prod.yaml'
    if (-not (Test-Path $compose)) { return '' }
    $ns = [regex]::Match((Get-Content $compose -Raw),
          'ghcr\.io/(?<ns>[A-Za-z0-9._-]+)/ocr-service:\d+\.\d+\.\d+').Groups['ns'].Value
    if (-not $ns) { return '' }
    return "ghcr.io/$ns/ocr-service:$ver"
}

function Test-ReleaseOcrImagePresent {
    <#
    .SYNOPSIS
        Is the release ocr-service image usable right now - locally first (cheap),
        otherwise anonymously on GHCR?
    .OUTPUTS
        'present' | 'absent' | 'unknown'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reference)
    if ((Test-ImageTagLocally -Reference $Reference) -eq 'present') { return 'present' }
    $ref = $Reference -replace '^ghcr\.io/', ''
    $repo = $ref.Substring(0, $ref.LastIndexOf(':'))
    $tag = $ref.Substring($ref.LastIndexOf(':') + 1)
    return Test-GhcrManifestPresent -Namespace ($repo -split '/')[0] -Repository ($repo -split '/')[1] -Tag $tag
}

function Exit-NotYetAssertable {
    <#
    .SYNOPSIS
        Stop with the "cannot check" exit code (2), which run-all-checks.ps1
        reports as SKIP CANNOT CHECK and does NOT count as a failure.

        Always prints the reason: a silent skip is how coverage disappears
        without anyone noticing, which is the failure mode this file exists to
        prevent.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason)
    Write-Host ("SKIP: NOT YET ASSERTABLE - {0}" -f $Reason) -ForegroundColor Yellow
    exit 2
}
