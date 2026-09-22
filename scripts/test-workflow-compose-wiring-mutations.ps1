# Prove test-workflow-compose-wiring.ps1 actually FIRES, by injecting each fault
# class into a THROWAWAY COPY of the compose files. The repo is never mutated.
#
# WHY THIS IS A TRACKED FILE AND NOT A ONE-OFF
#
# A guard only ever seen green is not yet a guard. This harness was written as a
# throwaway and immediately found TWO things a human review would not have:
#
#   1. A FALSE NEGATIVE. The guard tested `-match 'WORKFLOWS_DIR'`, but PowerShell
#      -match is case-INSENSITIVE, so an explanatory comment containing the prose
#      word `workflows_dir` satisfied the check. Deleting the real env key left the
#      guard satisfied by a comment - it passed a genuinely broken file. Fixed by
#      requiring a case-sensitive, line-anchored `^\s+WORKFLOWS_DIR:\s*\S`.
#
#   2. A DEAD MOUNT still sitting on deer-flow in compose.prod.yaml, left behind
#      as "harmless" during the original fix. A2 now catches it.
#
# That is the entire argument for keeping it: the guard's value depends on its
# ability to fail, and only injection can establish that.
#
# INJECTION IS VERIFIED. Each case confirms the fault actually landed before
# judging the guard, and reports INJECT-FAILED separately from GUARD-MISSED. An
# earlier version conflated the two: it reported a fault as "not proven" when the
# anchor had simply failed to match (8-space indent assumed, file used 6), which
# would have hidden a real guard weakness behind a harness bug.
#
# Usage:  pwsh -File scripts/test-workflow-compose-wiring-mutations.ps1
# Exit:   0 = every fault class proven caught, 1 = a fault went undetected.
#
# See deploy/DEFECT-workflow-mount-wrong-service.md.

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

$guard = Join-Path $RepoRoot 'scripts\test-workflow-compose-wiring.ps1'
$src = Join-Path $RepoRoot 'deploy\client-bundle'

if (-not (Test-Path $guard)) { Write-Host "guard not found: $guard" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $src)) { Write-Host "compose dir not found: $src" -ForegroundColor Red; exit 1 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wfwiring_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp 'workflows') -Force | Out-Null
Copy-Item (Join-Path $src 'compose.prod.yaml') $tmp
Copy-Item (Join-Path $src 'compose.bundle.yaml') $tmp
$wfSrc = Join-Path $src 'workflows'
if (Test-Path $wfSrc) {
    Get-ChildItem $wfSrc -File -Filter '*.yaml' | Select-Object -First 5 |
        Copy-Item -Destination (Join-Path $tmp 'workflows')
}

$prod = Join-Path $tmp 'compose.prod.yaml'
$bundle = Join-Path $tmp 'compose.bundle.yaml'
$prod0 = [System.IO.File]::ReadAllText($prod)
$bundle0 = [System.IO.File]::ReadAllText($bundle)

function Write-Lines([string]$Path, $Lines) {
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Restore-Baseline {
    [System.IO.File]::WriteAllText($prod, $prod0, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($bundle, $bundle0, (New-Object System.Text.UTF8Encoding($false)))
    $wf = Join-Path $tmp 'workflows'
    if (-not (Test-Path $wf)) {
        $renamed = Join-Path $tmp 'workflows_renamed'
        if (Test-Path $renamed) { Rename-Item $renamed 'workflows' }
    }
}

# Locate a service block by position so indentation is irrelevant.
function Get-BlockRange {
    param([string]$Path, [string]$Service)
    $l = [System.IO.File]::ReadAllLines($Path)
    $start = -1
    for ($i = 0; $i -lt $l.Count; $i++) {
        if ($l[$i] -match "^  $([regex]::Escape($Service)):\s*$") { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = $l.Count - 1
    for ($i = $start + 1; $i -lt $l.Count; $i++) {
        if ($l[$i] -match '^  [A-Za-z0-9._-]+:\s*$') { $end = $i - 1; break }
    }
    return @{ Start = $start; End = $end }
}

function Remove-InBlock {
    param([string]$Path, [string]$Service, [string]$Pattern)
    $range = Get-BlockRange -Path $Path -Service $Service
    if (-not $range) { return $false }
    $l = [System.Collections.Generic.List[string]]::new()
    $l.AddRange([System.IO.File]::ReadAllLines($Path))
    $hits = @()
    for ($i = $range.End; $i -ge $range.Start; $i--) {
        if ($l[$i] -match $Pattern) { $hits += $i }
    }
    if ($hits.Count -eq 0) { return $false }
    foreach ($i in ($hits | Sort-Object -Descending)) { $l.RemoveAt($i) }
    Write-Lines $Path $l
    return $true
}

function Insert-InBlock {
    param([string]$Path, [string]$Service, [string]$AfterPattern, [string]$NewLine)
    $range = Get-BlockRange -Path $Path -Service $Service
    if (-not $range) { return $false }
    $l = [System.Collections.Generic.List[string]]::new()
    $l.AddRange([System.IO.File]::ReadAllLines($Path))
    $at = -1
    for ($i = $range.Start; $i -le $range.End; $i++) {
        if ($l[$i] -match $AfterPattern) { $at = $i; break }
    }
    if ($at -lt 0) { return $false }
    $l.Insert($at + 1, $NewLine)
    Write-Lines $Path $l
    return $true
}

function Invoke-Guard {
    $out = & pwsh -NoProfile -File $guard -RepoRoot $tmp 2>&1
    return @{ Exit = $LASTEXITCODE; Text = ($out -join "`n") }
}

$script:proven = 0
$script:total = 0

function Assert-Case {
    param([string]$Name, [int]$WantExit, [bool]$Injected, [hashtable]$Result, [string]$WantPattern)

    $script:total++
    if (-not $Injected) {
        Write-Host ("  [INJECT-FAILED] {0} - the fault never landed, so this case proves nothing" -f $Name) -ForegroundColor Yellow
        return
    }
    $ok = ($Result.Exit -eq $WantExit)
    if ($ok -and $WantPattern) { $ok = ($Result.Text -match $WantPattern) }
    if (-not $ok) {
        Write-Host ("  [GUARD-MISSED] {0} (exit {1}, wanted {2})" -f $Name, $Result.Exit, $WantExit) -ForegroundColor Red
        return
    }
    $script:proven++
    Write-Host ("  [PROVEN] {0} (exit {1})" -f $Name, $Result.Exit) -ForegroundColor Green
    $hit = ($Result.Text -split "`n") | Where-Object { $_ -match '\[FAIL\]' } | Select-Object -First 1
    if ($hit) { Write-Host "           $($hit.Trim())" -ForegroundColor DarkGray }
}

Write-Host '=== baseline: a clean copy must PASS the guard ===' -ForegroundColor Cyan
Restore-Baseline
Assert-Case 'baseline passes' 0 $true (Invoke-Guard) 'RESULT: workflow-library wiring is complete'

Write-Host ''
Write-Host '=== fault 1: half-wired - drop WORKFLOWS_DIR from pacgate-api ===' -ForegroundColor Cyan
Restore-Baseline
$inj = Remove-InBlock -Path $prod -Service 'pacgate-api' -Pattern '^\s*WORKFLOWS_DIR:'
Assert-Case 'half-wired detected (A1)' 1 ($inj -and ([System.IO.File]::ReadAllText($prod) -ne $prod0)) (Invoke-Guard) 'A1'

Write-Host ''
Write-Host '=== fault 2: wrong-service mount - put it back on deer-flow ===' -ForegroundColor Cyan
Restore-Baseline
$inj = Insert-InBlock -Path $prod -Service 'deer-flow' -AfterPattern 'deer-flow-config\.yaml:/app/backend/config\.yaml:ro' -NewLine '      - ./workflows:/app/workflows:ro'
Assert-Case 'wrong-service mount detected (A2)' 1 $inj (Invoke-Guard) 'A2'

Write-Host ''
Write-Host '=== fault 3: parity drift - the bundle loses its mount ===' -ForegroundColor Cyan
Restore-Baseline
$inj = Remove-InBlock -Path $bundle -Service 'pacgate-api' -Pattern '\./workflows:/app/workflows'
Assert-Case 'parity drift detected (A1)' 1 $inj (Invoke-Guard) $null

Write-Host ''
Write-Host '=== fault 4: mount source missing - the silent symptom ===' -ForegroundColor Cyan
Restore-Baseline
$wf = Join-Path $tmp 'workflows'
if (Test-Path $wf) { Rename-Item $wf 'workflows_renamed' }
Assert-Case 'missing mount source detected (A4)' 1 $true (Invoke-Guard) 'A4'

Restore-Baseline
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
$colour = if ($script:proven -eq $script:total) { 'Green' } else { 'Red' }
Write-Host ("=== {0} of {1} fault classes proven caught ===" -f $script:proven, $script:total) -ForegroundColor $colour
if ($script:proven -ne $script:total) { exit 1 }
exit 0
