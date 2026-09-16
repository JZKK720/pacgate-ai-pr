# Verify the namespace-resolution logic in build-ghcr.yml.
#
# The logic is embedded in a YAML `run:` block, so it cannot be unit-tested
# directly. This extracts the same SH logic and exercises it against the three
# precedence cases plus the wrong-namespace warning, because getting this wrong
# publishes a release to a namespace no client pulls from - successfully, and
# therefore silently.
[CmdletBinding()]
param(
    # Skip the docker-based behavioural section and run only the static
    # assertions. The mutation harness needs this: it invokes this suite ~10
    # times in a loop, and each docker run pays container startup, so the nested
    # total blows past the caller's time budget and the run is reported as a
    # timeout rather than as a result. The static layer is what the mutations
    # target, and the behavioural layer still runs in the full gate suite.
    [switch]$StaticOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$wf = Join-Path $repoRoot '.github/workflows/build-ghcr.yml'

if (-not (Test-Path -LiteralPath $wf)) { throw "workflow not found: $wf" }

$passed = 0
$failed = 0
function Assert-True {
    param([bool]$Cond, [string]$Label, [string]$Detail = '')
    if ($Cond) { Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green; $script:passed++ }
    else {
        Write-Host ("  [FAIL] {0}" -f $Label) -ForegroundColor Red
        if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor Gray }
        $script:failed++
    }
}

Write-Host '=== build-ghcr namespace resolution ===' -ForegroundColor Cyan
Write-Output ''

# --- structural checks: the workflow must actually reference the pin ---------
$raw = Get-Content -LiteralPath $wf -Raw

Assert-True ($raw -match 'GHCR_NAMESPACE:\s*pacgate-ai') 'workflow declares the pinned GHCR_NAMESPACE constant'
Assert-True ($raw -match '\$GHCR_NAMESPACE') 'the step reads the committed constant'
Assert-True ($raw -match '::warning::Publishing to ghcr\.io') 'warns when resolving to a non-pinned namespace'

# The pin must agree with what the client compose files actually pull. This is
# the invariant the whole file exists to protect: if the workflow publishes to
# one namespace and compose pins another, the client install pulls nothing and
# no error is raised anywhere.
#
# Scoped to the FOUR images the workflow builds - not every ghcr.io reference.
# The first version compared all namespaces and flagged 'volcengine', which is
# OpenViking: an UPSTREAM image pinned by digest, not something this workflow
# publishes. A check that reports a real thing as a failure is a check people
# learn to ignore, so the scope is now explicit.
$builtImages = @('pacgate-api', 'pacgate-mcp', 'deer-flow-pacgate', 'deer-flow-frontend-pacgate')
$pins = @()
foreach ($f in @('deploy/client-bundle/compose.prod.yaml', 'deploy/client-bundle/compose.bundle.yaml')) {
    $p = Join-Path $repoRoot $f
    if (Test-Path -LiteralPath $p) {
        foreach ($img in $builtImages) {
            $m = [regex]::Match((Get-Content $p -Raw), "ghcr\.io/([a-z0-9\-]+)/$img")
            if ($m.Success) { $pins += [pscustomobject]@{ File = (Split-Path $f -Leaf); Image = $img; Ns = $m.Groups[1].Value } }
        }
    }
}
$pinned = ([regex]::Match($raw, 'GHCR_NAMESPACE:\s*([a-z0-9\-]+)')).Groups[1].Value
$wrong = @($pins | Where-Object { $_.Ns -ne $pinned })
Assert-True ($pins.Count -eq 8 -and $wrong.Count -eq 0) `
    'all 8 pins (4 images x 2 compose files) use the workflow namespace' `
    ("pinned='$pinned'; found $($pins.Count) pins; mismatches: " + (($wrong | ForEach-Object { "$($_.Image)@$($_.Ns)" }) -join ', '))

# Stale-namespace check, made PRECISE. A blanket "the string jzkk720 must not
# appear" is wrong: the file legitimately names the upstream namespace to explain
# the mirror and to record the tagging hazard, and the first version of this
# assertion flagged those comments.
#
# The rule is about INTENT: every mention must be either (a) declared as the
# mirror namespace, or (b) prose that marks it upstream/mirror/deprecated. A
# mention reading as a CLIENT publish target is the thing that must not exist.
#
# CONTEXT IS A WINDOW, not a single line. My third attempt at this check looked
# only at the matching line and failed on "A release therefore populates BOTH.
# pacgate-ai is authoritative; jzkk720 gets a" + "MIRROR of the same tags" -
# the keyword was on the WRAPPED next line. Prose wraps; the check has to read a
# window. (Third correction to this one assertion. Each was a false positive, and
# a checker whose false-positive rate is high is one people learn to skip.)
$fileLines = @(Get-Content -LiteralPath $wf)
$unexplained = @()
for ($i = 0; $i -lt $fileLines.Count; $i++) {
    if ($fileLines[$i] -notmatch 'jzkk720') { continue }
    $lo = [Math]::Max(0, $i - 1)
    $hi = [Math]::Min($fileLines.Count - 1, $i + 2)
    $window = ($fileLines[$lo..$hi] -join ' ')
    if ($window -notmatch 'DEPRECATED|deprecated|MIRROR|mirror|upstream|developer|ORIGIN') {
        $unexplained += ("L{0}: {1}" -f ($i + 1), $fileLines[$i].Trim())
    }
}
Assert-True ($unexplained.Count -eq 0) 'every jzkk720 mention is marked mirror/upstream/deprecated' `
    (($unexplained | Select-Object -First 3) -join "`n         ")

# Precedence order in the script must be input > pinned > owner.
$inputIdx = $raw.IndexOf('if [ -n "$INPUT_NS" ]')
$pinIdx = $raw.IndexOf('elif [ -n "$GHCR_NAMESPACE" ]')
$ownerIdx = $raw.IndexOf('ns="$OWNER_NS"')
Assert-True ($inputIdx -gt 0 -and $pinIdx -gt $inputIdx -and $ownerIdx -gt $pinIdx) `
    'precedence is input > pinned > owner (checked by position in the script)'

Write-Output ''

# --- mirror job: the upstream namespace -------------------------------------
#
# The mirror is NON-BLOCKING by design: pacgate-ai is the source of truth and a
# mirror failure must never fail a client release. These assertions encode that,
# because the property is easy to lose in a later edit and impossible to notice
# from a green run.
Write-Host '=== mirror-upstream job ===' -ForegroundColor Cyan
Write-Output ''
Assert-True ($raw -match 'GHCR_MIRROR_NAMESPACE:\s*jzkk720') 'declares the upstream mirror namespace'
Assert-True ($raw -match 'mirror-upstream:') 'has a mirror-upstream job'
Assert-True ($raw -match 'needs:\s*build-and-push') 'mirror runs AFTER the client build'
Assert-True ($raw -match 'if:\s*\$\{\{\s*env\.GHCR_MIRROR_NAMESPACE != ''''\s*\}\}') 'mirror job is skipped when no mirror namespace is set'
Assert-True ($raw -match 'GHCR_MIRROR_PAT') 'mirror authenticates with its own PAT (GITHUB_TOKEN cannot cross namespaces)'

# Retag, not rebuild. A rebuild would double CI time AND produce different
# digests for identical source, making the two namespaces impossible to compare.
Assert-True ($raw -match 'imagetools create') 'mirror RETAGS rather than rebuilding'
Assert-True ($raw -notmatch 'mirror-upstream:[\s\S]{0,4000}build-push-action') 'mirror does not invoke a build action'

# The dangling-output trap: build-and-push declares no outputs, so referencing
# needs.build-and-push.outputs.<x> resolves to an empty string silently.
#
# COMMENT LINES ARE EXCLUDED. The first version of this assertion flagged the
# comment that explains the trap - the same class of false positive as the 'VAR'
# one in audit-qm-bootstrap.ps1. A checker that reports its own documentation as a
# defect teaches people to ignore it.
$codeLines = @(Get-Content -LiteralPath $wf | Where-Object { $_.TrimStart() -notmatch '^#' })
$dangling = @($codeLines | Where-Object { $_ -match 'needs\.build-and-push\.outputs\.' })
Assert-True ($dangling.Count -eq 0) 'no reference to outputs that build-and-push does not declare' `
    ($dangling | ForEach-Object { $_.Trim() } | Select-Object -First 2)

# A mirror failure must not be able to fail the run.
Assert-True ($raw -match 'have=0') 'mirror degrades to a warning when the PAT is absent'
Assert-True ($raw -match '::warning::\$GHCR_MIRROR_NAMESPACE') 'a non-pullable mirror WARNs rather than erroring'
Assert-True ($raw -notmatch 'mirror-upstream:[\s\S]{0,6000}::error::') 'the mirror job never emits a hard ::error::'
Write-Output ''

# --- the build job's own credential -----------------------------------------
#
# The mirror got a PAT because GITHUB_TOKEN cannot cross namespaces. The BUILD
# job has the same constraint and did not: its login used (github.actor,
# secrets.GITHUB_TOKEN) while the namespace was pinned to pacgate-ai, so a run
# from the upstream repo would have pushed into a namespace its token does not
# own and died on a bare 403.
Write-Output '=== build-job credential ==='
Write-Output ''

Assert-True ($raw -match 'GHCR_CLIENT_PAT') 'the build job can use a PAT for the pinned namespace'
Assert-True ($raw -match 'secrets\.GHCR_CLIENT_PAT') 'the PAT is read from a repository secret, never a literal'
Assert-True ($raw -match 'secrets\.GHCR_CLIENT_PAT \|\| secrets\.GITHUB_TOKEN') `
    'GHCR_CLIENT_PAT is optional - it falls back to the automatic token'
Assert-True ($raw -match 'steps\.ns\.outputs\.actor \|\| github\.actor') 'the login account follows the resolved namespace'

# The PAT must not be routed through a step output. It works, but it copies the
# secret into $GITHUB_OUTPUT, which is both unnecessary (login-action can select
# it inline) and a wider surface than the alternative.
Assert-True ($raw -notmatch 'PAC_TOKEN_EOF') 'the PAT is not copied into $GITHUB_OUTPUT'

# The empty-release trap. A build job that cannot log in must NOT continue:
# skipping the pushes would leave every downstream signal (run badge, step
# summary, "CI passed") asserting that a release shipped when nothing was
# published. Same failure class as the "0 edits, exit 0" no-op.
Assert-True ($raw -match "if:\s*steps\.login\.outcome != 'success'") 'a failed GHCR login stops the build job'
$confirmBlock = [regex]::Match($raw, "Confirm GHCR login[\s\S]{0,900}")
Assert-True ($confirmBlock.Success -and $confirmBlock.Value -match '::error::') 'a failed login is a hard ::error::, not a warning'
Assert-True ($confirmBlock.Success -and $confirmBlock.Value -match 'exit 1') 'a failed login exits non-zero'

# WARN in advance when the token provably cannot reach the target. This is the
# only signal before the push 403s.
#
# Match the CONDITION, not a keyword. The first version of this assertion looked
# for `elif.*OWNER_NS`, which happened to match only because the warning was
# written as an `elif` at the time. Rewriting it as an `if` with a compound
# condition - a no-op refactor - turned the assertion red against a workflow that
# behaved identically. An assertion coupled to incidental syntax is not testing
# the property it names, and this is the second time in this file that a check
# failed against correct output.
#
# The pattern avoids backslashes on purpose: in a PowerShell SINGLE-quoted string
# `\` is not an escape, so a pattern ending in `\$` closes the string on the
# backslash boundary and the regex engine receives an illegal trailing `\`. Same
# family as the `$var:` scope-qualifier trap - quoting rules differ between the
# two layers and the failure surfaces in the wrong one.
$nsBlock = [regex]::Match($raw, 'Resolve image namespace[\s\S]{0,3000}')
Assert-True ($nsBlock.Success -and [regex]::Match($nsBlock.Value, 'ns" != "\$OWNER_NS').Success) `
    'WARNS when the token owner differs from the pinned namespace'
Write-Output ''

if ($StaticOnly) {
    Write-Output ''
    Write-Host '=== Results ===' -ForegroundColor Cyan
    Write-Host ("  {0} passed, {1} failed (behavioural section skipped: -StaticOnly)" -f $passed, $failed)
    if ($failed -gt 0) { exit 1 }
    exit 0
}

# --- behavioural checks: run the same logic as SH ---------------------------
#
# The script is written to a FILE and mounted, not passed through `sh -c`.
# Passing it inline failed with 'syntax error: unexpected "elif"' because the
# here-string is built in PowerShell and then re-parsed by Docker's CLI layer, and
# the escaping did not survive. A temp file has no quoting surface at all - the
# same lesson as the earlier readiness probe that died on quoting.
function Resolve-Ns {
    param([string]$InputNs, [string]$Pinned, [string]$Owner, [string]$Pat = '')

    # Mirrors the workflow's `Resolve image namespace` step, including the
    # credential branch. It is duplicated here on purpose: the point is to run
    # the DECISION and observe it. A regex over the YAML would pass even if the
    # branches were ordered wrong.
    $sh = @"
INPUT_NS='$InputNs'
GHCR_NAMESPACE='$Pinned'
OWNER_NS='$Owner'
CLIENT_PAT='$Pat'
if [ -n "`$INPUT_NS" ]; then
  ns="`$INPUT_NS"; src='namespace dispatch input'
elif [ -n "`$GHCR_NAMESPACE" ]; then
  ns="`$GHCR_NAMESPACE"; src='committed GHCR_NAMESPACE'
else
  ns="`$OWNER_NS"; src='repo owner (GHCR_NAMESPACE is empty)'
fi
warn=no
if [ "`$ns" != 'pacgate-ai' ]; then warn=yes; fi
cred='GITHUB_TOKEN'
cwarn=no
if [ -n "`$CLIENT_PAT" ]; then
  cred='GHCR_CLIENT_PAT'
elif [ "`$ns" != "`$OWNER_NS" ]; then
  cwarn=yes
fi
echo "`$ns|`$src|`$warn|`$cred|`$cwarn"
"@
    $tmp = Join-Path $script:base "ns-$([guid]::NewGuid().ToString('N').Substring(0,6)).sh"
    # LF endings: CRLF in a mounted .sh gives 'not found' / syntax errors in sh.
    [System.IO.File]::WriteAllText($tmp, ($sh -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $out = & docker run --rm --mount "type=bind,source=$tmp,target=/t.sh,readonly" alpine:3.20 sh /t.sh 2>&1
    $line = ($out | Out-String).Trim()
    $parts = $line -split '\|'
    return [pscustomobject]@{ Ns = $parts[0]; Src = $parts[1]; Warn = $parts[2]; Cred = $parts[3]; CredWarn = $parts[4]; Raw = $line }
}

$script:base = Join-Path ([System.IO.Path]::GetTempPath() -replace 'CUBECL~1', 'cubecloud-io') ('ns-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $script:base | Out-Null

try {
    $r = Resolve-Ns -InputNs 'pacgate-ai' -Pinned 'something-else' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'pacgate-ai') 'explicit input wins' "got $($r.Ns)"
    Assert-True ($r.Warn -eq 'no') 'no warning for an explicit input' "got $($r.Warn)"

    $r = Resolve-Ns -InputNs '' -Pinned 'pacgate-ai' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'pacgate-ai') 'committed constant wins over the owner' "got $($r.Ns)"
    Assert-True ($r.Src -like 'committed*') 'reports the constant as the source' "got $($r.Src)"

    # THE CASE THAT MATTERS: pin unset, workflow running on origin. Previously
    # this silently published to the deprecated namespace.
    $r = Resolve-Ns -InputNs '' -Pinned '' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'jzkk720') 'unset pin falls back to the owner' "got $($r.Ns)"
    Assert-True ($r.Warn -eq 'yes') 'WARNS when publishing to a namespace clients do not pin' "got $($r.Warn)"

    $r = Resolve-Ns -InputNs '' -Pinned '' -Owner 'pacgate-ai'
    Assert-True ($r.Warn -eq 'no') 'no warning when the owner IS the pinned namespace' "got $($r.Warn)"

    # THE CROSS-NAMESPACE CASE. Running on origin with the pin active: the token
    # belongs to jzkk720, the target is pacgate-ai, so the push cannot work and
    # the step must say so before the 403 arrives.
    $r = Resolve-Ns -InputNs '' -Pinned 'pacgate-ai' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'pacgate-ai') 'pinned namespace wins on the upstream repo' "got $($r.Ns)"
    Assert-True ($r.CredWarn -eq 'yes') 'WARNS that GITHUB_TOKEN cannot reach the pinned namespace' "got $($r.CredWarn)"

    $r = Resolve-Ns -InputNs '' -Pinned 'pacgate-ai' -Owner 'jzkk720' -Pat 'ghp_example'
    Assert-True ($r.Cred -eq 'GHCR_CLIENT_PAT') 'a supplied PAT is preferred over the automatic token' "got $($r.Cred)"
    Assert-True ($r.CredWarn -eq 'no') 'no credential warning once a PAT is supplied' "got $($r.CredWarn)"

    # The normal client-delivery path: owner and pin agree, no PAT anywhere.
    $r = Resolve-Ns -InputNs '' -Pinned 'pacgate-ai' -Owner 'pacgate-ai'
    Assert-True ($r.Cred -eq 'GITHUB_TOKEN') 'the automatic token is the default credential' "got $($r.Cred)"
    Assert-True ($r.CredWarn -eq 'no') 'no credential warning when owner and pin agree' "got $($r.CredWarn)"

    # A PAT must not be used when it was never set - an empty secret must not
    # silently become the credential (it would 401 rather than fall back).
    $r = Resolve-Ns -InputNs '' -Pinned 'pacgate-ai' -Owner 'pacgate-ai' -Pat ''
    Assert-True ($r.Cred -eq 'GITHUB_TOKEN') 'an unset secret falls back rather than selecting an empty PAT' "got $($r.Cred)"
}
catch {
    Write-Host ("  [FAIL] harness error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failed++
}
finally {
    Remove-Item -LiteralPath $script:base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($failed -eq 0) {
    Write-Host ("{0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
