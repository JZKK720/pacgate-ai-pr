# Assert client-facing handoff docs do not instruct a DEPLOYABLE-BUT-WRONG action.
#
# WHY THIS EXISTS
#
# Three client-facing docs told the on-site engineer to `git clone` the FORK.
# The AIPC deployment handbook went further and asserted the two repos were
# "identical ... so either clone works". That was true when written (2026-09-22).
# It became FALSE the next day, when 26 commits landed on JZKK720 that the fork
# did not have - including the fix for the workflow-wiring defect. A machine
# deployed from the fork therefore serves 10 built-in workflows instead of the
# firm's 222, and NOTHING reports an error.
#
# The lesson is not "someone made a typo". It is that a doc which asserts two
# things are in sync has baked in an assumption that decays, and it decays
# SILENTLY. So the assertions get a check that can fail.
#
# WHAT IT ASSERTS
#
#   A1  No doc contains a runnable fork-clone command. A doc may DISCUSS the fork
#       (the corrections do), but it must not hand over a copy-pasteable wrong
#       command. Prose describing it is fine; a fenced `git clone ...pacgate-ai/`
#       line is not.
#   A2  A doc claiming the two repos are identical/synced must mark that claim as
#       corrected. An unmarked live "they are identical" is a false instruction.
#   A3  AIPC handoff docs must name JZKK720 as the clone target, so the correct
#       remote is stated wherever deployment is described.
#
# Usage:  pwsh -File scripts/test-handoff-command-safety.ps1
# Exit:   0 = safe, 1 = a doc would deploy the wrong code, 2 = could not check.

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

Write-Host '=== handoff doc command safety ===' -ForegroundColor Cyan

# Vendored and generated trees contain hundreds of unrelated READMEs. Scanning
# them produced 391 "docs" in the first run, which is noise, not coverage.
$docs = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Include '*.md' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\|\\target\\|\\\.git\\|\\\.venv\\|\\site-packages\\|\\dist-info\\' })

if ($docs.Count -eq 0) {
    Write-Host 'RESULT: ERROR - no markdown docs found; check RepoRoot.' -ForegroundColor Red
    exit 2
}

# Only these are CLIENT-FACING deployment instructions. Other docs legitimately
# discuss the fork's history (plans, post-mortems), so scoping matters: a check
# that flags a legitimate historical mention is a check people learn to ignore.
$clientFacing = @($docs | Where-Object {
    $_.Name -match 'AIPC|HANDOFF|DEPLOYMENT-HANDBOOK|client-bundle' -or
    $_.FullName -match '\\client-delivery\\'
})

Info ("scanning {0} doc(s); {1} are client-facing deployment docs" -f $docs.Count, $clientFacing.Count)

# --- A1: no runnable fork-clone command, anywhere ---------------------------
# Deliberately whole-repo: a copy-pasteable wrong command is dangerous even in a
# historical file, because that is exactly where an engineer short on time looks.
$forkClone = @()
foreach ($doc in $docs) {
    $text = [System.IO.File]::ReadAllText($doc.FullName)
    # Match a real command line, not a prose mention or an inline-code note.
    if ($text -cmatch '(?m)^\s*git clone\s+https://github\.com/pacgate-ai/') {
        $forkClone += $doc.FullName.Replace($RepoRoot, '').TrimStart('\')
    }
}
if ($forkClone.Count -gt 0) {
    Fail "A1 $($forkClone.Count) doc(s) contain a runnable fork-clone command:"
    $forkClone | ForEach-Object { Info $_ }
    Info 'A fork clone deploys the workflow-wiring defect silently (10 built-ins, not 222).'
    $script:failures++
} else {
    Pass 'A1 no doc hands over a runnable fork-clone command'
}

# --- A2: stale "the REPOS are identical" claims must be marked corrected -----
# The identity claim decays on its own. Unmarked, it reads as current fact and
# authorizes the wrong clone.
#
# SCOPED NARROWLY, on purpose. The first version matched the bare word
# "identical" anywhere and reported 21 failures - including a vendored .venv
# README and docs saying "identical to AIPC #1", which is a claim about MACHINE
# parity, not repo parity, and is entirely legitimate. A check that reports real
# things as failures is a check people learn to ignore. So this now requires a
# repo/clone context AND an identity word, and only looks at client-facing docs.
$identityPattern = '(repos?\s+(are|now)\s+(identical|the same))|(identical[^\n]{0,40}(repos?|origin/main|fork))|(either clone works)'
$correctionMarker = '(CORRECTED|SUPERSEDED|DO NOT|WRONG|no longer|❌|⛔|🛑)'
$staleIdentity = @()
foreach ($doc in $clientFacing) {
    $text = [System.IO.File]::ReadAllText($doc.FullName)
    if ($text -match $identityPattern) {
        # Count identity claims NOT accompanied by a correction marker in the
        # same line or the few lines above it (where a banner would sit).
        $lines = $text -split "`r?`n"
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $identityPattern) {
                $windowStart = [Math]::Max(0, $i - 12)
                $window = ($lines[$windowStart..$i] -join "`n")
                if ($window -notmatch $correctionMarker) {
                    $staleIdentity += ("{0}:{1}" -f $doc.FullName.Replace($RepoRoot, '').TrimStart('\'), ($i + 1))
                    break
                }
            }
        }
    }
}
if ($staleIdentity.Count -gt 0) {
    Fail "A2 $($staleIdentity.Count) doc(s) assert repo identity WITHOUT a correction marker:"
    $staleIdentity | ForEach-Object { Info $_ }
    Info 'That claim decays silently; it must be marked corrected or removed.'
    $script:failures++
} else {
    Pass 'A2 no unmarked "repos are identical" claim survives'
}

# --- A3: AIPC docs must name the canonical clone target ---------------------
$noCanonical = @()
foreach ($doc in $clientFacing) {
    $text = [System.IO.File]::ReadAllText($doc.FullName)
    $mentionsClone = ($text -match 'git clone')
    $namesCanonical = ($text -match 'JZKK720/pacgate-ai-pr')
    if ($mentionsClone -and -not $namesCanonical) {
        $noCanonical += $doc.FullName.Replace($RepoRoot, '').TrimStart('\')
    }
}
if ($noCanonical.Count -gt 0) {
    Fail "A3 $($noCanonical.Count) client-facing doc(s) mention cloning but never name JZKK720:"
    $noCanonical | ForEach-Object { Info $_ }
    $script:failures++
} else {
    Pass 'A3 every client-facing doc that mentions cloning names JZKK720'
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "RESULT: FAIL - $($script:failures) unsafe handoff issue(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: handoff docs are safe to execute.' -ForegroundColor Green
exit 0
