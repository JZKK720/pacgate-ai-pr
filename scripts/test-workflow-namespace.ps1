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
# appear" is wrong: the explanatory comment legitimately names the deprecated
# namespace to explain why the pin exists, and the first version of this
# assertion flagged that comment. What must not exist is a jzkk720 line that
# reads as a PUSH TARGET. So: every occurrence must be on a line that explicitly
# marks it deprecated or explains the origin-tagging hazard.
$jzLines = @(Get-Content -LiteralPath $wf | Select-String -Pattern 'jzkk720')
$unexplained = @($jzLines | Where-Object { $_.Line -notmatch 'DEPRECATED|ORIGIN|deprecated' })
Assert-True ($unexplained.Count -eq 0) 'every jzkk720 mention is marked deprecated or explains the hazard' `
    ($unexplained | ForEach-Object { "L$($_.LineNumber): $($_.Line.Trim())" } | Select-Object -First 3)

# Precedence order in the script must be input > pinned > owner.
$inputIdx = $raw.IndexOf('if [ -n "$INPUT_NS" ]')
$pinIdx = $raw.IndexOf('elif [ -n "$GHCR_NAMESPACE" ]')
$ownerIdx = $raw.IndexOf('ns="$OWNER_NS"')
Assert-True ($inputIdx -gt 0 -and $pinIdx -gt $inputIdx -and $ownerIdx -gt $pinIdx) `
    'precedence is input > pinned > owner (checked by position in the script)'

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
