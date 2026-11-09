# Post-deploy audit for an AIPC machine running a Pacgate release.
#
# WHY THIS EXISTS (2026-11-09)
#
# deploy/HANDOFF-SYNC-TO-ORIGIN-MAIN.md tells an operator to run six commands after
# `install.ps1 -Update`, in a stated order, with one of them ("check 2": the fixes
# are LIVE in the container, not merely on disk) singled out as "the one that
# matters". That list is prose. Nothing enforces the order, nothing notices when a
# stage was skipped, and a skipped stage is indistinguishable from a passing one -
# which is the exact failure class this repo keeps rediscovering:
#
#   * the summarization patch was mounted, imported cleanly, and was INERT;
#   * a dead workflows mount sat on deer-flow while every gate reported healthy;
#   * the 2026-10-17 incident left one stack holding a credential the other
#     rejected, invisible to all 39 gates because none crossed the boundary.
#
# So the stages here are ordered by DEPENDENCY, each stage refuses to run until the
# one it depends on has passed, and a stage that cannot be evaluated reports
# CANNOT CHECK - never a pass.
#
# WHAT IT DOES NOT DO
#
# It does not replace `run-all-checks.ps1`. That runner owns the STATIC gates (they
# need no stack). This owns the LIVE stages, in the order a real deployment
# produces them, and it delegates to the repo's existing scripts rather than
# reimplementing them - a second copy of an assertion is a second thing to drift.
#
# Exit codes: 0 = every evaluated stage passed; 1 = a stage FAILED;
#             2 = nothing could be evaluated, or a later stage was blocked.
#
# Usage:
#   pwsh -File scripts/audit-post-deploy.ps1
#   pwsh -File scripts/audit-post-deploy.ps1 -SkipGenerative     # skip the slow model lanes
#   pwsh -File scripts/audit-post-deploy.ps1 -Stage 1,2,3         # run a prefix only

[CmdletBinding()]
param(
    # Base URL the operator's browser uses. Keep the /pacgate prefix.
    [string]$BaseUrl = 'http://localhost:8089/pacgate',

    # Skip the model-driven lanes (workflow execution, agent loop). They cost
    # minutes and depend on a local model being resident, so a first pass on a
    # fresh machine legitimately omits them - but then the report says so.
    [switch]$SkipGenerative,

    # Run only these stage numbers, comma-separated, e.g. -Only 0,1,2.
    # A comma STRING rather than [int[]]: under `pwsh -File`, `-Stage 0,1` binds as
    # the single value 1 (verified), silently dropping every stage but the last.
    [string]$Only = '',

    # Continue past a failed stage instead of stopping. The report still marks the
    # dependants BLOCKED, because a later stage's result is not trustworthy.
    [switch]$KeepGoing
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

$script:results = @()
$script:stopped = $false

# Parse -Only into a set of ints once, so every Should-Run call is a cheap lookup.
$script:onlySet = @()
if ($Only -ne '') {
    $script:onlySet = @($Only -split ',' | ForEach-Object { ($_ -replace '\s','') } |
        Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
}

function Stage-Note([int]$n, [string]$name, [string]$status, [string]$detail) {
    $script:results += [pscustomobject]@{ Stage = $n; Name = $name; Status = $status; Detail = $detail }
    $colour = switch ($status) {
        'PASS'         { 'Green' }
        'FAIL'         { 'Red' }
        'CANNOT CHECK' { 'Yellow' }
        'BLOCKED'      { 'DarkYellow' }
        'SKIP'         { 'DarkGray' }
        default        { 'White' }
    }
    Write-Host ("  [{0,-12}] {1}" -f $status, $name) -ForegroundColor $colour
    if ($detail) { Write-Host "               $detail" -ForegroundColor DarkGray }
}

function Should-Run([int]$n) {
    # Filter FIRST. Applying the -Stage filter only after the FAIL check meant a
    # stage excluded by -Stage still reported as BLOCKED, which reads as a failure
    # in a run that never intended to touch it.
    if ($script:onlySet.Count -gt 0 -and $script:onlySet -notcontains $n) { return $false }
    if ($script:stopped -and -not $KeepGoing) {
        Stage-Note $n $script:currentStageName 'BLOCKED' 'an earlier stage failed; its result would not be trustworthy'
        return $false
    }
    return $true
}

# Runs a repo script and classifies its exit code. Exit 2 is CANNOT CHECK and is
# NEVER folded into PASS - that conflation is what lets an unevaluated check read
# as coverage.
function Invoke-Gate([int]$n, [string]$name, [string]$script, [string[]]$scriptArgs = @()) {
    $script:currentStageName = $name
    if (-not (Should-Run $n)) { return }
    $path = Join-Path $repoRoot $script
    if (-not (Test-Path $path)) {
        Stage-Note $n $name 'CANNOT CHECK' "missing script: $script"
        return
    }
    Write-Host ("`n-- stage {0}: {1}" -f $n, $name) -ForegroundColor Cyan
    $out = & pwsh -NoProfile -File $path @scriptArgs 2>&1
    $code = $LASTEXITCODE
    $tail = ($out | Select-Object -Last 3) -join ' | '
    switch ($code) {
        0 { Stage-Note $n $name 'PASS' $tail }
        1 { Stage-Note $n $name 'FAIL' $tail; if (-not $KeepGoing) { $script:stopped = $true } }
        2 { Stage-Note $n $name 'CANNOT CHECK' $tail }
        default { Stage-Note $n $name 'FAIL' "exit $code : $tail"; if (-not $KeepGoing) { $script:stopped = $true } }
    }
}

Write-Host ('=' * 78)
Write-Host ' POST-DEPLOY AUDIT' -ForegroundColor Cyan
Write-Host " base:  $BaseUrl"
Write-Host " repo:  $repoRoot"
Write-Host ('=' * 78)

# ---------------------------------------------------------------------------
# STAGE 0 - What is actually deployed, and does it match the source tree?
#
# Nothing downstream means anything until the running containers are the images
# the pins name. A "MIXED STACK" (one container never recreated) makes every
# later stage test a blend of old and new code and report on neither.
$script:currentStageName = 'deployed version matches the source tree'
if (Should-Run 0) {
    Write-Host "`n-- stage 0: $($script:currentStageName)" -ForegroundColor Cyan
    $cargo = Join-Path $repoRoot 'pacgate-ai/Cargo.toml'
    $srcVersion = if (Test-Path $cargo) {
        ([regex]::Match((Get-Content $cargo -Raw), '(?m)^\s*version\s*=\s*"([0-9.]+)"')).Groups[1].Value
    } else { '' }
    $running = docker ps --format '{{.Names}}|{{.Image}}' 2>$null
    if (-not $running) {
        Stage-Note 0 $script:currentStageName 'CANNOT CHECK' 'docker is unavailable or no containers are running'
        if (-not $KeepGoing) { $script:stopped = $true }
    } else {
        $stale = @()
        # Only the images THIS release publishes. A `jzkk720/` image outside that
        # set (hermes-agent:latest) tracks the remote independently, so demanding
        # it match the release tag would be a false failure on every machine - the
        # "gate goes red on a healthy machine" defect this repo has shipped before.
        $releaseImages = @('pacgate-api','pacgate-mcp','deer-flow-pacgate',
                           'deer-flow-frontend-pacgate','ocr-service','laya-serve')
        foreach ($line in $running) {
            $parts = $line -split '\|', 2
            if ($parts.Count -lt 2) { continue }
            $name = $parts[0]; $image = $parts[1]
            if ($image -notmatch 'jzkk720/') { continue }
            $repo = ($image -split '/')[-1] -replace ':[^:]+$',''
            if ($releaseImages -notcontains $repo) { continue }
            if ($srcVersion -and $image -notmatch ":$([regex]::Escape($srcVersion))$") {
                $stale += "$name -> $image"
            }
        }
        if (-not $srcVersion) {
            Stage-Note 0 $script:currentStageName 'CANNOT CHECK' 'could not read the source version from pacgate-ai/Cargo.toml'
        } elseif ($stale.Count -eq 0) {
            Stage-Note 0 $script:currentStageName 'PASS' "every running jzkk720 image is tagged $srcVersion"
        } else {
            Stage-Note 0 $script:currentStageName 'FAIL' ("stale image(s): " + ($stale -join '; '))
            if (-not $KeepGoing) { $script:stopped = $true }
        }
    }
}

# ---------------------------------------------------------------------------
# STAGE 1 - The bind-mounted patches are LIVE in the container, not just on disk.
#
# This is the stage the handoff singles out, and it exists because a patch that is
# mounted and imports cleanly looks exactly like a working one from outside. The
# first summarization fix was INERT for exactly this reason: it patched the base
# class while deer-flow dispatched to a subclass that overrode the method.
#
# A `docker restart` is not enough after a patch file changes - the module is read
# at process start. So this asserts the CONTENT the running process loaded.
$script:currentStageName = 'patches are live in the running containers'
if (Should-Run 1) {
    Write-Host "`n-- stage 1: $($script:currentStageName)" -ForegroundColor Cyan
    $probes = @(
        @{ Container = 'deer-flow'; Path = '/app/backend/packages/harness/deerflow/agents/middlewares/summarization_middleware.py'; Needle = 'recoverable handles'; Why = 'summarization recovery index' },
        @{ Container = 'deer-flow'; Path = '/app/adapters/pacgate_deerflow_adapter/client.py'; Needle = 'for attempt in range(2)'; Why = 'bounded 401 re-login' },
        @{ Container = 'deer-flow'; Path = '/app/backend/app/gateway/services.py'; Needle = '_PACGATE_MIN_RECURSION_LIMIT'; Why = 'recursion floor' }
    )
    $live = @(); $dead = @(); $unknown = @()
    foreach ($p in $probes) {
        $n = docker exec $p.Container sh -c "grep -c '$($p.Needle)' '$($p.Path)' 2>/dev/null" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $n) { $unknown += "$($p.Why) (cannot read $($p.Path))"; continue }
        if ([int]$n -ge 1) { $live += $p.Why } else { $dead += "$($p.Why) - file present but marker absent" }
    }
    if ($dead.Count -gt 0) {
        Stage-Note 1 $script:currentStageName 'FAIL' ("not live: " + ($dead -join '; ') + ' -> docker compose ... restart deer-flow')
        if (-not $KeepGoing) { $script:stopped = $true }
    } elseif ($live.Count -gt 0) {
        $det = "live: $($live -join ', ')"
        if ($unknown.Count -gt 0) { $det += " | unverified: $($unknown -join ', ')" }
        Stage-Note 1 $script:currentStageName 'PASS' $det
    } else {
        Stage-Note 1 $script:currentStageName 'CANNOT CHECK' ($unknown -join '; ')
    }
}

# ---------------------------------------------------------------------------
# STAGE 2 - Credentials: present, agreed across both stacks, and LIVE.
#
# The 2026-10-17 incident was one stack holding a credential the other rejected,
# with all 39 gates green because none of them crossed the boundary. C1/C1b/C3 in
# this script cover agreement and live login; C5 (added 2026-11-09) covers a
# compose-required variable being absent entirely, which Compose silently
# substitutes with an empty string while still starting the container.
Invoke-Gate 2 'credentials agree across both stacks and authenticate' 'scripts/test-cross-stack-credentials.ps1'
Invoke-Gate 3 'the credentials the stack USES are valid (not merely present)' 'scripts/audit-e2e-credentials.ps1'

# ---------------------------------------------------------------------------
# STAGE 4 - Every lane connects and every service is the image its pin names.
Invoke-Gate 4 'every cross-component lane connects' 'scripts/test-lane-connectivity.ps1'
Invoke-Gate 5 'every running service is the image its pin names' 'scripts/test-stack-version-coherence.ps1'
Invoke-Gate 6 'the account-provisioning surface is closed' 'scripts/test-auth-provisioning-gate.ps1'

# ---------------------------------------------------------------------------
# STAGE 7 - The MCP surface, from the consumer's side.
#
# Counting tools is not the same as being able to call one: deer-flow qualifies
# MCP names with the server prefix, and a gate that matched bare names could never
# pass on a real run.
Invoke-Gate 7 'the MCP tool surface is intact from the consumer side' 'scripts/test-mcp-tool-surface.ps1'
Invoke-Gate 8 'an agent run actually invokes an MCP tool' 'scripts/test-agent-mcp-e2e.ps1'

# ---------------------------------------------------------------------------
# STAGE 9 - Content: the real library, real documents, real retrieval.
#
# test-workflow-library-served asserts the firm's 222-workflow library is served
# rather than the 10 built-ins. kb-search-empty-signal E6 (added 2026-11-09)
# asserts the API suppresses unrelated neighbours, because before that a nonsense
# query returned chunks scoring higher than 17 of 20 legitimate ones and the
# caller's no_match branch was unreachable dead code.
Invoke-Gate 9  'the firm workflow library is served, not the built-ins' 'scripts/test-workflow-library-served.ps1' @('-BaseUrl', $BaseUrl)
Invoke-Gate 10 'an empty kb_search explains itself and a miss is reported as a miss' 'scripts/test-kb-search-empty-signal.ps1'
Invoke-Gate 11 'sanitizer end to end: upload -> extract -> sanitize -> verify -> restore' 'scripts/test-sanitizer-e2e.ps1'
Invoke-Gate 12 'every document format survives extract + sanitize + convert' 'scripts/test-format-coverage-e2e.ps1'
Invoke-Gate 13 'NER is enabled and its weights are real' 'scripts/test-ner-enabled.ps1'

# ---------------------------------------------------------------------------
# STAGE 14 - Generative loops. These are the lanes that cost minutes and can loop
# forever, so they run last: if an earlier stage is red there is no point burning
# a model's budget on top of a broken stack.
if ($SkipGenerative) {
    Stage-Note 14 'document generation reaches a real file' 'SKIP' '-SkipGenerative was set'
    Stage-Note 15 'the legal journey completes end to end' 'SKIP' '-SkipGenerative was set'
} else {
    Invoke-Gate 14 'a workflow executes and lands a real docx on disk' 'scripts/test-document-generation-e2e.ps1' @('-BaseUrl', $BaseUrl)
    Invoke-Gate 15 'the legal journey completes end to end' 'scripts/test-legal-journey.ps1' @('-BaseUrl', $BaseUrl)
    # The recursion cap needs a run deep enough to reach the wall; on a quiet box
    # this is CANNOT CHECK by design and must not be read as a pass.
    Invoke-Gate 16 'no run died on a caller-supplied recursion budget' 'scripts/audit-recursion-regressions.ps1'
    Invoke-Gate 17 'summarization pressure hint honours the declared window' 'scripts/test-summarization-recovery.ps1'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 78)
$pass   = @($script:results | Where-Object Status -eq 'PASS').Count
$fail   = @($script:results | Where-Object Status -eq 'FAIL').Count
$cannot = @($script:results | Where-Object Status -eq 'CANNOT CHECK').Count
$blocked= @($script:results | Where-Object Status -eq 'BLOCKED').Count
$skipped= @($script:results | Where-Object Status -eq 'SKIP').Count

Write-Host (" RESULT: {0} passed, {1} failed, {2} cannot-check, {3} blocked, {4} skipped" -f $pass,$fail,$cannot,$blocked,$skipped)
if ($cannot -gt 0) {
    Write-Host ' CANNOT CHECK is NOT a pass: those stages were not evaluated.' -ForegroundColor Yellow
}
if ($blocked -gt 0) {
    Write-Host ' BLOCKED stages never ran because a dependency failed; fix the first FAIL.' -ForegroundColor DarkYellow
}
Write-Host ('=' * 78)

Pop-Location
if ($fail -gt 0) { exit 1 }
if ($pass -eq 0) { exit 2 }
if ($cannot -gt 0 -or $blocked -gt 0) { exit 2 }
exit 0
