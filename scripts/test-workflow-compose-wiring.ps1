# Assert the workflow-library wiring is COMPLETE and CONSISTENT across compose files.
#
# WHY THIS EXISTS
#
# The runtime guard (scripts/test-workflow-library-served.ps1) catches the defect
# on a RUNNING stack. This one catches it BEFORE deployment, and catches a class
# the runtime guard cannot see: a fix applied to one compose file but not another.
#
# That is not hypothetical. The first fix landed only in compose.prod.yaml. When
# compose.bundle.yaml was later inspected it had the mount on the WRONG service
# and no WORKFLOWS_DIR at all - the identical original defect, untouched. A
# second pass then found pacgate-api had no mount in that file either. Two edits
# were needed; the first looked complete and was not.
#
# The runtime guard passed the whole time, because install.ps1 uses
# compose.prod.yaml. A repo-parallel file stayed broken and nothing objected.
#
# WHAT IT ASSERTS
#
#   A1  In any compose file defining pacgate-api, WORKFLOWS_DIR and the
#       ./workflows mount are EITHER both present on pacgate-api or both absent.
#       Half a fix is the failure mode.
#   A2  No OTHER service claims ./workflows:/app/workflows. deer-flow had it and
#       has zero references to /app/workflows - the mount was inert there.
#   A3  File parity: the files that define pacgate-api agree on this wiring, so
#       fixing one and forgetting the other is a test failure, not a surprise.
#   A4  The mount source (./workflows) exists next to the compose file - a mount
#       of a missing directory silently yields an empty mount, which reproduces
#       the original symptom (built-ins only) in a different way.
#   A5  Patch-mount parity: compose.prod.yaml and compose.bundle.yaml bind the
#       SAME set of ./patches/*.py files. This is the same drift class as A3 but
#       for the patch layer, and it had already happened: bundle was missing
#       deer-flow-present-file.py, pacgate-adapter-client.py and
#       deer-flow-deferred-tool-filter.py. A missing patch mount does not error -
#       the container silently runs the unpatched upstream file, so the defect is
#       invisible until a user hits the behaviour the patch was written to fix.
#   A6  Every referenced patch file exists on disk. A bind mount of a missing
#       file makes Docker create a DIRECTORY at that path, which breaks the
#       import in a way that looks nothing like a missing file.
#
# Usage:  pwsh -File scripts/test-workflow-compose-wiring.ps1
# Exit:   0 = wiring complete and consistent, 1 = defect, 2 = could not check.
#
# See deploy/DEFECT-workflow-mount-wrong-service.md.

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Info($m) { Write-Host "         $m" -ForegroundColor DarkGray }

$script:failures = 0

Write-Host '=== workflow-library compose wiring ===' -ForegroundColor Cyan

# Resolve each service's OWN lines so a mount is attributed to the right service.
# String-scanning the whole file would attribute a mount to whichever service was
# inspected, which is exactly the error that created the defect.
function Get-ComposeFileInfo {
    param([string]$Path)

    $lines = Get-Content -LiteralPath $Path -Encoding utf8
    $services = @{}
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^  ([A-Za-z0-9._-]+):\s*$') {
            $current = $Matches[1]
            if (-not $services.ContainsKey($current)) { $services[$current] = @() }
            continue
        }
        if ($null -ne $current) { $services[$current] += $line }
    }

    $info = [pscustomobject]@{ Path = $Path; Services = $services; HasApi = $services.ContainsKey('pacgate-api') }
    return $info
}

# Collect every ./patches/<name>.py bind mount in the file, attributed to the
# service that owns it. Returns objects so A5 can compare sets and A6 can check
# the source file exists.
function Get-PatchMounts {
    param($Info)

    $found = @()
    foreach ($name in $Info.Services.Keys) {
        $body = ($Info.Services[$name] -join "`n")
        foreach ($m in [regex]::Matches($body, '(?m)^\s*-\s*\./patches/([A-Za-z0-9._-]+\.py):(\S+)')) {
            $found += [pscustomobject]@{
                Service = $name
                File    = $m.Groups[1].Value
                Target  = $m.Groups[2].Value
            }
        }
    }
    return $found
}

$candidates = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'compose*.yaml' -or $_.Name -like 'compose*.yml' } |
    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\target\\|\\\.git\\' })

if ($candidates.Count -eq 0) {
    Write-Host 'RESULT: ERROR - no compose files found; check RepoRoot.' -ForegroundColor Red
    exit 2
}

$apiFiles = @()

foreach ($file in $candidates) {
    $rel = $file.FullName.Replace($RepoRoot, '').TrimStart('\')
    $info = Get-ComposeFileInfo -Path $file.FullName
    if (-not $info.HasApi) { continue }

    # Case-SENSITIVE and line-anchored, deliberately.
    #
    # PowerShell -match is case-INSENSITIVE by default. An earlier version tested
    # `-match 'WORKFLOWS_DIR'`, which also matched an explanatory COMMENT that
    # mentions `workflows_dir` in prose. With that bug, deleting the real key left
    # the guard satisfied by the comment and it passed a genuinely broken file -
    # a false negative caught only by fault injection. Require the actual key.
    $apiBody = ($info.Services['pacgate-api'] -join "`n")
    $hasEnv = [bool]($apiBody -cmatch '(?m)^\s+WORKFLOWS_DIR:\s*\S')
    $hasMount = [bool]($apiBody -cmatch '(?m)^\s*-\s*\./workflows:/app/workflows')

    $apiFiles += [pscustomobject]@{
        Rel = $rel; Path = $file.FullName; Dir = $file.DirectoryName
        HasEnv = $hasEnv; HasMount = $hasMount
        Patches = @(Get-PatchMounts -Info $info)
    }

    Write-Host "  $rel"
    Info ("pacgate-api: WORKFLOWS_DIR={0}  mount={1}" -f $hasEnv, $hasMount)

    # A1 - both or neither, on pacgate-api.
    if ($hasEnv -xor $hasMount) {
        Fail "A1 [$rel] half-wired: WORKFLOWS_DIR=$hasEnv but mount=$hasMount."
        Info 'WORKFLOWS_DIR without the mount points at an empty dir;'
        Info 'the mount without WORKFLOWS_DIR is never read (workflows_dir is None).'
        $script:failures++
    } elseif ($hasEnv -and $hasMount) {
        Pass "A1 [$rel] pacgate-api has both the env var and the mount"
    } else {
        Info "A1 [$rel] pacgate-api opts out of the library in this file"
    }

    # A2 - no other service may claim the mount.
    $intruders = @()
    foreach ($name in $info.Services.Keys) {
        if ($name -eq 'pacgate-api') { continue }
        # Anchored + case-sensitive for the same reason as A1: an unanchored
        # case-insensitive match would fire on a comment that merely mentions the
        # path, reporting a non-existent intruder.
        if (($info.Services[$name] -join "`n") -cmatch '(?m)^\s*-\s*\./workflows:/app/workflows') { $intruders += $name }
    }
    if ($intruders.Count -gt 0) {
        Fail "A2 [$rel] workflows mount present on non-owning service(s): $($intruders -join ', ')"
        Info 'Those services do not read /app/workflows (verified in-container).'
        $script:failures++
    } else {
        Pass "A2 [$rel] only pacgate-api claims the workflows mount"
    }

    # A4 - the mount source must exist and be non-empty.
    $src = Join-Path $file.DirectoryName 'workflows'
    if ($hasMount) {
        if (-not (Test-Path $src)) {
            Fail "A4 [$rel] mount source missing: $src (an empty mount reproduces the defect)"
            $script:failures++
        } else {
            $count = @(Get-ChildItem -LiteralPath $src -File -Filter '*.yaml' -ErrorAction SilentlyContinue).Count
            if ($count -eq 0) {
                Fail "A4 [$rel] mount source has no workflow YAMLs: $src"
                $script:failures++
            } else {
                Pass "A4 [$rel] mount source has $count workflow YAML file(s)"
            }
        }
    }
}

if ($apiFiles.Count -eq 0) {
    Write-Host 'RESULT: ERROR - no compose file defines pacgate-api; cannot check.' -ForegroundColor Red
    exit 2
}

# A3 - parity across files that define pacgate-api.
Write-Host ''
Write-Host '  parity across files defining pacgate-api'
$wired = @($apiFiles | Where-Object { $_.HasEnv -and $_.HasMount })
$unwired = @($apiFiles | Where-Object { -not $_.HasEnv -and -not $_.HasMount })
$half = @($apiFiles | Where-Object { $_.HasEnv -xor $_.HasMount })

Info ("wired: {0}   opted-out: {1}   half-wired: {2}" -f $wired.Count, $unwired.Count, $half.Count)

# The tracked, deployable compose files must not silently drift apart. Override
# files legitimately opt out (they inherit base wiring via compose merge).
$baseline = @($apiFiles | Where-Object { $_.Rel -match 'compose\.(prod|bundle)\.yaml$' })
if ($baseline.Count -gt 1) {
    $states = @($baseline | ForEach-Object { "$($_.HasEnv)/$($_.HasMount)" } | Sort-Object -Unique)
    if ($states.Count -eq 1) {
        Pass "A3 prod and bundle agree on the wiring ($($states[0]))"
    } else {
        Fail "A3 prod and bundle disagree: $((($baseline | ForEach-Object { "$($_.Rel)=$($_.HasEnv)/$($_.HasMount)" }) -join ', '))"
        Info 'A fix applied to one compose file and not the other is the exact gap this catches.'
        $script:failures++
    }
}

# A5 - patch-mount parity across the tracked, deployable compose files.
#
# Same drift class as A3, but for the patch layer. A missing patch mount does not
# fail loudly: the container starts and silently runs the unpatched upstream
# file, so the regression only surfaces when a user hits the behaviour the patch
# existed to fix. That is how bundle came to be missing three mounts.
Write-Host ''
Write-Host '  patch-mount parity across files defining pacgate-api'
$patchBaseline = @($apiFiles | Where-Object { $_.Rel -match 'compose\.(prod|bundle)\.yaml$' })
if ($patchBaseline.Count -gt 1) {
    $sets = @{}
    foreach ($f in $patchBaseline) {
        $sets[$f.Rel] = @($f.Patches | ForEach-Object { $_.File } | Sort-Object -Unique)
    }
    $names = @($sets.Keys | Sort-Object)
    $ref = $names[0]
    $drift = $false
    for ($i = 1; $i -lt $names.Count; $i++) {
        $other = $names[$i]
        $onlyRef = @($sets[$ref] | Where-Object { $sets[$other] -notcontains $_ })
        $onlyOther = @($sets[$other] | Where-Object { $sets[$ref] -notcontains $_ })
        if ($onlyRef.Count -gt 0 -or $onlyOther.Count -gt 0) {
            $drift = $true
            Fail "A5 patch mounts differ between $ref and $other"
            if ($onlyRef.Count -gt 0) { Info ("  only in {0}: {1}" -f $ref, ($onlyRef -join ', ')) }
            if ($onlyOther.Count -gt 0) { Info ("  only in {0}: {1}" -f $other, ($onlyOther -join ', ')) }
            Info 'A missing patch mount runs the unpatched upstream file with no error.'
            $script:failures++
        }
    }
    if (-not $drift) {
        Pass ("A5 prod and bundle bind the same {0} patch file(s)" -f $sets[$ref].Count)
    }
}

# A6 - every referenced patch file must exist. Docker creates a DIRECTORY when a
# bind-mount source is missing, which breaks the import in a way that looks
# nothing like a missing file.
Write-Host ''
Write-Host '  patch mount sources exist'
$missing = @()
foreach ($f in $apiFiles) {
    foreach ($p in $f.Patches) {
        $src = Join-Path $f.Dir (Join-Path 'patches' $p.File)
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $missing += "$($f.Rel) -> patches/$($p.File)"
        }
    }
}
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Fail "A6 missing patch source: $m" }
    Info 'Docker creates a directory at the target when the source is absent.'
    $script:failures++
} else {
    $total = @($apiFiles | ForEach-Object { $_.Patches } | ForEach-Object { $_.File } | Sort-Object -Unique).Count
    Pass "A6 all $total referenced patch file(s) exist on disk"
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: FAIL - $($script:failures) wiring problem(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: workflow-library wiring is complete and consistent.' -ForegroundColor Green
exit 0
