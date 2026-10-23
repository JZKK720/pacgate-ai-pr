# Refuse a tracked file above a size ceiling.
#
# WHY THIS EXISTS (the 2026-10-23 AIPC #2 field report)
#
# A cherry-pick on that machine staged a 42 MB docker CLI binary. It was caught by
# a human noticing the diff, not by anything in this repo. A binary that size in
# git history is PERMANENT: a later commit cannot remove it, only a history
# rewrite can, and by then every clone carries it.
#
# `.gitignore` cannot express this rule - it matches names and patterns, not
# sizes - so the check has to be a script. The .gitignore additions made alongside
# this file cover the specific shapes that incident produced; this covers the
# general case.
#
# WHAT IS ASSERTED
#   1. no TRACKED file exceeds the ceiling;
#   2. the ceiling is low enough to be meaningful (a guard set to 1 GB would pass
#      the 42 MB binary that motivated it);
#   3. the check can FAIL - exercised synthetically, so it cannot expire.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check.
[CmdletBinding()]
param(
    # 10 MB. The largest legitimate tracked file in this repo is well under 1 MB
    # (the workflow YAML library and the docs HTML), so 10 MB leaves an order of
    # magnitude of headroom while still catching the 42 MB class.
    [int]$MaxMB = 10
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$passed = 0; $failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $passed passed, $failed failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== tracked file size guard ==='

$tracked = git ls-files 2>$null
if ($LASTEXITCODE -ne 0 -or -not $tracked) { CannotCheck 'git ls-files returned nothing - not a git checkout?' }

$ceiling = $MaxMB * 1MB
$oversize = @()
$checked = 0
foreach ($f in @($tracked)) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $item = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { continue }
    $checked++
    if ($item.Length -gt $ceiling) {
        $oversize += [pscustomobject]@{ Path = $f; MB = [math]::Round($item.Length / 1MB, 1) }
    }
}

Check 'tracked files were actually inspected' ($checked -gt 0) 'no tracked files resolved on disk - the guard would pass vacuously'
Write-Host ("         inspected {0} tracked file(s) against a {1} MB ceiling" -f $checked, $MaxMB) -ForegroundColor DarkGray

Check "no tracked file exceeds $MaxMB MB" ($oversize.Count -eq 0) `
    ("oversize: " + (($oversize | ForEach-Object { "$($_.Path) ($($_.MB) MB)" }) -join '; ') +
     " - a binary this size is permanent in git history; remove it from the index and add a .gitignore rule")

# The guard must DISCRIMINATE. A ceiling set so high that nothing can trip it is
# not a guard, and this is the specific mistake that would have let the 42 MB
# binary through: a 1 GB ceiling passes it silently.
function Test-WithinCeiling([long]$bytes, [int]$maxMB) { return ($bytes -le ($maxMB * 1MB)) }
Check 'the ceiling REJECTS the 42 MB binary that motivated this guard' (-not (Test-WithinCeiling (42MB) $MaxMB)) "a $MaxMB MB ceiling would accept a 42 MB binary"
Check 'the ceiling ACCEPTS a normal source file' (Test-WithinCeiling (200KB) $MaxMB) 'a 200 KB source file was rejected'

Write-Host ''
if ($failed -gt 0) {
    Write-Host "RESULT: $passed passed, $failed failed" -ForegroundColor Red
    exit 1
}
Write-Host "RESULT: no tracked file exceeds $MaxMB MB. ($passed passed)" -ForegroundColor Green
exit 0
