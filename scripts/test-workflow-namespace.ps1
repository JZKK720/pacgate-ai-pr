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

Assert-True ($raw -match 'GHCR_NAMESPACE:\s*jzkk720') 'workflow declares the pinned GHCR_NAMESPACE constant'
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

# Precedence order in the script must be input > pinned > owner.
$inputIdx = $raw.IndexOf('if [ -n "$INPUT_NS" ]')
$pinIdx = $raw.IndexOf('elif [ -n "$GHCR_NAMESPACE" ]')
$ownerIdx = $raw.IndexOf('ns="$OWNER_NS"')
Assert-True ($inputIdx -gt 0 -and $pinIdx -gt $inputIdx -and $ownerIdx -gt $pinIdx) `
    'precedence is input > pinned > owner (checked by position in the script)'

Write-Output ''

# --- the build job's own credential -----------------------------------------
#
# GITHUB_TOKEN cannot cross namespaces. On the PRIMARY path this is irrelevant:
# the namespace is pinned to jzkk720 and the release runs from JZKK720, so the
# pinned namespace and the token's owner MATCH and the automatic token suffices.
# GHCR_RELEASE_PAT is the escape hatch for a deliberately cross-namespace run.
Write-Output '=== build-job credential ==='
Write-Output ''

Assert-True ($raw -match 'GHCR_RELEASE_PAT') 'the build job can use a PAT for a cross-namespace target'
Assert-True ($raw -match 'secrets\.GHCR_RELEASE_PAT') 'the PAT is read from a repository secret, never a literal'
Assert-True ($raw -match 'secrets\.GHCR_RELEASE_PAT \|\| secrets\.GITHUB_TOKEN') `
    'GHCR_RELEASE_PAT is optional - it falls back to the automatic token'
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
#
# The comparison is on the LOWERCASED variables (ns_lc vs owner_lc), not the raw
# ones: GHCR usernames are case-insensitive while a shell compare is not, and the
# owner keeps its real capitalization (JZKK720 vs ghcr.io/jzkk720). Asserting on
# the raw names would require the workflow to keep a comparison that produces a
# false 403 warning.
$nsBlock = [regex]::Match($raw, 'Resolve image namespace[\s\S]{0,3000}')
Assert-True ($nsBlock.Success -and [regex]::Match($nsBlock.Value, 'ns_lc" != "\$owner_lc').Success) `
    'WARNS when the token owner differs from the pinned namespace'
# Assert the PROPERTY (both sides are lowercased before comparing), not the
# exact `tr` invocation. An earlier version of this check spelled out the tr
# arguments and failed on a correct workflow, because the quoting inside
# `tr '[:upper:]' '[:lower:]'` does not lay out the way it looks when read as a
# pattern - the space between the two quoted sets is not adjacent to what the
# eye expects. Matching the two variable NAMES is unambiguous and survives a
# rewrite of the lowercasing itself.
Assert-True ($nsBlock.Success -and
             [regex]::Match($nsBlock.Value, 'ns_lc=\$\(.*lower').Success -and
             [regex]::Match($nsBlock.Value, 'owner_lc=\$\(.*lower').Success) `
    'the owner/namespace compare is case-insensitive (GHCR usernames are)'
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
ns_lc=`$(printf '%s' "`$ns" | tr '[:upper:]' '[:lower:]')
owner_lc=`$(printf '%s' "`$OWNER_NS" | tr '[:upper:]' '[:lower:]')
warn=no
if [ "`$ns_lc" != 'jzkk720' ]; then warn=yes; fi
cred='GITHUB_TOKEN'
cwarn=no
if [ -n "`$CLIENT_PAT" ]; then
  cred='GHCR_RELEASE_PAT'
elif [ "`$ns_lc" != "`$owner_lc" ]; then
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
    Assert-True ($r.Warn -eq 'yes') 'WARNS for an explicit input off the release authority' "got $($r.Warn)"

    # THE PRIMARY PATH, and the one that must never warn: pinned jzkk720, run
    # from JZKK720, no PAT. The namespace and the token owner agree, so the
    # automatic token suffices. This is what every normal release does.
    $r = Resolve-Ns -InputNs '' -Pinned 'jzkk720' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'jzkk720') 'the pinned release authority is used' "got $($r.Ns)"
    Assert-True ($r.Warn -eq 'no') 'no warning on the primary path' "got $($r.Warn)"
    Assert-True ($r.Cred -eq 'GITHUB_TOKEN') 'the automatic token is sufficient same-owner' "got $($r.Cred)"
    Assert-True ($r.CredWarn -eq 'no') 'no credential warning same-owner' "got $($r.CredWarn)"

    $r = Resolve-Ns -InputNs '' -Pinned 'jzkk720' -Owner 'jzkk720'
    Assert-True ($r.Src -like 'committed*') 'reports the constant as the source' "got $($r.Src)"

    # CASE MATTERS, AND IT BIT US. github.repository_owner preserves the account's
    # real capitalization: this repo's owner is `JZKK720`, while every registry
    # path is lowercase (`ghcr.io/jzkk720`). A raw string compare reported a
    # mismatch that does not exist and warned about a 403 that would not happen -
    # training the reader to ignore the warning that DOES matter. GHCR is
    # case-insensitive, so the compare must be too.
    $r = Resolve-Ns -InputNs '' -Pinned 'jzkk720' -Owner 'JZKK720'
    Assert-True ($r.Ns -eq 'jzkk720') 'the pin still resolves when the owner is capitalized' "got $($r.Ns)"
    Assert-True ($r.Warn -eq 'no') 'no namespace warning for a capitalized same-owner' "got $($r.Warn)"
    Assert-True ($r.CredWarn -eq 'no') 'NO FALSE 403 WARNING when the owner differs only in case' "got $($r.CredWarn)"

    # Pin unset: falls back to the owner. On JZKK720 that still lands correctly,
    # but it is no longer the intended path - the pin is what makes it explicit.
    $r = Resolve-Ns -InputNs '' -Pinned '' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'jzkk720') 'unset pin falls back to the owner' "got $($r.Ns)"
    Assert-True ($r.Warn -eq 'no') 'falling back to jzkk720 does not warn' "got $($r.Warn)"

    # The mirror repo must WARN: it is no longer a publish target.
    $r = Resolve-Ns -InputNs '' -Pinned '' -Owner 'pacgate-ai'
    Assert-True ($r.Warn -eq 'yes') 'WARNS when publishing somewhere clients do not pin' "got $($r.Warn)"

    # THE CROSS-NAMESPACE CASE. If someone overrides the namespace to a different
    # owner, the token belongs to one account and the target is another, so the
    # push cannot work and the step must say so before the 403 arrives.
    $r = Resolve-Ns -InputNs 'pacgate-ai' -Pinned 'jzkk720' -Owner 'jzkk720'
    Assert-True ($r.Ns -eq 'pacgate-ai') 'an explicit override wins over the pin' "got $($r.Ns)"
    Assert-True ($r.CredWarn -eq 'yes') 'WARNS that GITHUB_TOKEN cannot reach the overridden namespace' "got $($r.CredWarn)"

    $r = Resolve-Ns -InputNs 'pacgate-ai' -Pinned 'jzkk720' -Owner 'jzkk720' -Pat 'ghp_example'
    Assert-True ($r.Cred -eq 'GHCR_RELEASE_PAT') 'a supplied PAT is preferred over the automatic token' "got $($r.Cred)"
    Assert-True ($r.CredWarn -eq 'no') 'no credential warning once a PAT is supplied' "got $($r.CredWarn)"

    # A non-jzkk720 namespace with its matching owner: credential is fine, but the
    # namespace warning still fires because clients do not pin it.
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
