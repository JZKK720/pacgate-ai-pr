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

# KNOWN OVERSIZE, accepted deliberately. An entry here is a decision, not an
# exemption from review: it must name the file, its size, and why it is tracked.
#
# The first entry was found by this gate on 2026-10-23, the day it was written, and
# it invalidates the ceiling comment above: the largest tracked file in this repo is
# NOT under 1 MB. It is a 37.66 MB scanned PDF that `seed.rs` reads as RAG corpus
# (`--assets pacgate-ai/pacgate-ai-assets/...`), so deleting it from the index would
# break the seed path on a fresh clone. It is already in history, so removing it now
# would not shrink any clone - only a history rewrite would, and that is a separate
# decision with its own blast radius.
#
# The gate still fails on any NEW file over the ceiling, which is the property that
# matters: the 42 MB cherry-pick class cannot arrive unnoticed.
#
# Entries match by ASCII-only REGEX, never by a literal path. This script is UTF-8
# without a BOM, and PS 5.1 decodes a BOM-less file as ANSI/GBK on a Chinese-locale
# host - so a CJK literal written here arrives as mojibake and matches nothing.
# Measured: the first version of this list embedded the path and the gate reported
# its own entry as stale. The ASCII tail of the filename is unique and survives any
# encoding.
$KnownOversize = @(
    @{ Match = '20201215_.*_Haiwen_.*\.pdf$'
       MB    = 37.7
       Why   = 'RAG seed corpus read by pacgate-api seed.rs; already in history since 01a4644a' }
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

# -z + core.quotepath=false, NOT plain `git ls-files`.
#
# WHY: git quotes any path containing a non-ASCII byte by default, emitting
# `"docs/\351\241\271..."` with literal backslash escapes. `Test-Path -LiteralPath`
# rejects that as an illegal path, so every such file was silently skipped by the
# `continue` below. Measured on this repo before the fix: 772 of 829 tracked files
# inspected, 57 skipped - and one of the skipped files is a 37.66 MB tracked PDF,
# i.e. the guard reported PASS while the exact class of file it exists to catch was
# invisible to it. A guard that silently skips is the same defect this repo's other
# gates warn about: green about something absent.
#
# -z also makes a path containing a newline or a space unambiguous, which line-based
# parsing cannot do.
$tracked = @((git -c core.quotepath=false ls-files -z 2>$null) -split "`0" | Where-Object { $_ })
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { CannotCheck 'git ls-files returned nothing - not a git checkout?' }

$ceiling = $MaxMB * 1MB
$oversize = @()
$absent = @()
$checked = 0
foreach ($f in $tracked) {
    if (-not (Test-Path -LiteralPath $f)) { $absent += $f; continue }
    $item = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { $absent += $f; continue }
    $checked++
    if ($item.Length -gt $ceiling) {
        $oversize += [pscustomobject]@{ Path = $f; MB = [math]::Round($item.Length / 1MB, 1) }
    }
}

Check 'tracked files were actually inspected' ($checked -gt 0) 'no tracked files resolved on disk - the guard would pass vacuously'
Write-Host ("         inspected {0} of {1} tracked file(s) against a {2} MB ceiling" -f $checked, $tracked.Count, $MaxMB) -ForegroundColor DarkGray

# Coverage assertion. A tracked file that cannot be resolved on disk is either
# deleted in the worktree (legitimate, and git status will show it) or a path this
# script failed to parse (the bug above). Either way the guard did not measure it,
# so the count must be visible rather than swallowed by a bare `continue`.
if ($absent.Count -gt 0) {
    Write-Host ("         {0} tracked file(s) not present on disk (deleted in the worktree, or unparseable):" -f $absent.Count) -ForegroundColor DarkGray
    foreach ($a in ($absent | Select-Object -First 5)) { Write-Host "           $a" -ForegroundColor DarkGray }
    if ($absent.Count -gt 5) { Write-Host ("           ... and {0} more" -f ($absent.Count - 5)) -ForegroundColor DarkGray }
}

# Split the findings into accepted and new. A known file is reported by name so it
# stays visible in every run - an allowlist that prints nothing is how a decision
# turns into an unnoticed exemption.
function Find-KnownEntry([string]$path) {
    foreach ($k in $KnownOversize) { if ($path -match $k.Match) { return $k } }
    return $null
}

$accepted = @($oversize | Where-Object { Find-KnownEntry $_.Path })
$new = @($oversize | Where-Object { -not (Find-KnownEntry $_.Path) })

foreach ($a in $accepted) {
    $why = (Find-KnownEntry $a.Path).Why
    Write-Host ("         accepted oversize: {0} ({1} MB) - {2}" -f $a.Path, $a.MB, $why) -ForegroundColor DarkGray
}

Check "no NEW tracked file exceeds $MaxMB MB" ($new.Count -eq 0) `
    ("oversize: " + (($new | ForEach-Object { "$($_.Path) ($($_.MB) MB)" }) -join '; ') +
     " - a binary this size is permanent in git history; remove it from the index and add a .gitignore rule")

# An allowlist entry that no longer matches anything is stale, and a stale entry is
# how a real violation gets waved through later. Fail so it gets removed.
$staleEntries = @($KnownOversize | Where-Object { $k = $_; -not ($oversize | Where-Object { $_.Path -match $k.Match }) })
Check 'every accepted-oversize entry still matches a real file' ($staleEntries.Count -eq 0) `
    ("stale allowlist entries (file is gone or now under the ceiling): " + (($staleEntries | ForEach-Object { $_.Match }) -join '; ') + " - remove them so the list keeps meaning something")

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
