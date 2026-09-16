# Verify the namespace-resolution logic in build-ghcr.yml.
#
# The logic is embedded in a YAML `run:` block, so it cannot be unit-tested
# directly. This extracts the same SH logic and exercises it against the three
# precedence cases plus the wrong-namespace warning, because getting this wrong
# publishes a release to a namespace no client pulls from - successfully, and
# therefore silently.
[CmdletBinding()]
param()

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

# --- behavioural checks: run the same logic as SH ---------------------------
#
# The script is written to a FILE and mounted, not passed through `sh -c`.
# Passing it inline failed with 'syntax error: unexpected "elif"' because the
# here-string is built in PowerShell and then re-parsed by Docker's CLI layer, and
# the escaping did not survive. A temp file has no quoting surface at all - the
# same lesson as the earlier readiness probe that died on quoting.
function Resolve-Ns {
    param([string]$InputNs, [string]$Pinned, [string]$Owner)

    $sh = @"
INPUT_NS='$InputNs'
GHCR_NAMESPACE='$Pinned'
OWNER_NS='$Owner'
if [ -n "`$INPUT_NS" ]; then
  ns="`$INPUT_NS"; src='namespace dispatch input'
elif [ -n "`$GHCR_NAMESPACE" ]; then
  ns="`$GHCR_NAMESPACE"; src='committed GHCR_NAMESPACE'
else
  ns="`$OWNER_NS"; src='repo owner (GHCR_NAMESPACE is empty)'
fi
warn=no
if [ "`$src" != 'namespace dispatch input' ] && [ "`$ns" != 'pacgate-ai' ]; then warn=yes; fi
echo "`$ns|`$src|`$warn"
"@
    $tmp = Join-Path $script:base "ns-$([guid]::NewGuid().ToString('N').Substring(0,6)).sh"
    # LF endings: CRLF in a mounted .sh gives 'not found' / syntax errors in sh.
    [System.IO.File]::WriteAllText($tmp, ($sh -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    $out = & docker run --rm --mount "type=bind,source=$tmp,target=/t.sh,readonly" alpine:3.20 sh /t.sh 2>&1
    $line = ($out | Out-String).Trim()
    $parts = $line -split '\|'
    return [pscustomobject]@{ Ns = $parts[0]; Src = $parts[1]; Warn = $parts[2]; Raw = $line }
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
