# Mutation test for scripts/test-pdf-freshness.ps1.
#
# A gate that cannot fail is not a gate. This breaks each assertion in turn and
# asserts the gate REJECTS, then restores every file byte-identical.
#
# The mutations are deliberately of two kinds:
#   1. a source edited after its render (the real-world failure)
#   2. a delivery copy regressed from its original (the drift failure)
#
# Exit codes: 0 = every mutation rejected and every file restored,
#             1 = a mutation was ACCEPTED (the gate is blind), or a restore failed.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

$gate = 'scripts/test-pdf-freshness.ps1'
if (-not (Test-Path $gate)) { Write-Host "exit 2 - gate not found at $gate" -ForegroundColor Yellow; exit 2 }

# Absolute paths built once: Resolve-Path cannot be used for a .bak sibling that
# does not exist yet.
$root = (Get-Location).Path
function AbsPath([string]$rel) { Join-Path $root ($rel -replace '/', '\') }

# Pair: a PDF with a tracked .md source, and a delivery copy with an original.
$targets = @(
    'deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf'
    'deploy/client-delivery/docs/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf'
)

$originals = @{}
foreach ($t in $targets) {
    $abs = AbsPath $t
    if (-not (Test-Path $abs)) { Write-Host "exit 2 - missing $t" -ForegroundColor Yellow; exit 2 }
    $originals[$t] = [System.IO.File]::ReadAllBytes($abs)
    [System.IO.File]::WriteAllBytes("$abs.bak", $originals[$t])
}

function Restore-Targets {
    foreach ($t in $targets) {
        [System.IO.File]::WriteAllBytes((AbsPath $t), $originals[$t])
        Remove-Item "$(AbsPath $t).bak" -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '=== pdf-freshness gate: mutation tests ===' -ForegroundColor Cyan

# ── Mutation 1: make a source NEWER than its render. ────────────────────────
# This is the failure that actually happened: the .md was edited weeks after the
# PDF was rendered, and nothing noticed.
$src = 'deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.md'
$pdf = 'deploy/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf'
$srcAbs = AbsPath $src
$srcOriginalTime = (Get-Item $srcAbs).LastWriteTime
(Get-Item $srcAbs).LastWriteTime = (Get-Date).AddMinutes(5)
$out = & pwsh -NoProfile -File $gate 2>&1 | Out-String
$code = $LASTEXITCODE
(Get-Item $srcAbs).LastWriteTime = $srcOriginalTime
if ($code -eq 1) { Pass 'a source newer than its render -> rejected' }
elseif ($code -eq 0) { Fail 'a source newer than its render -> ACCEPTED. The gate cannot detect the exact failure it exists for.'; Write-Host $out }
else { Fail "a source newer than its render -> exit $code (expected 1)" }

# ── Mutation 2: regress the delivery copy so it drifts from its original. ────
# Truncate one byte. The pair is byte-identical at HEAD, so by the gate's own
# HEAD-derived rule this must count as drift.
$copy = AbsPath 'deploy/client-delivery/docs/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf'
$bytes = [System.IO.File]::ReadAllBytes($copy)
[System.IO.File]::WriteAllBytes($copy, $bytes[0..($bytes.Length - 2)])
$out = & pwsh -NoProfile -File $gate 2>&1 | Out-String
$code = $LASTEXITCODE
if ($code -eq 1) { Pass 'a delivery copy drifting from its original -> rejected' }
elseif ($code -eq 0) { Fail 'a delivery copy drifting from its original -> ACCEPTED. A stale document would ship to the client.'; Write-Host $out }
else { Fail "a delivery copy drifting -> exit $code (expected 1)" }

Restore-Targets

Write-Host ''
Write-Host '=== restore verification ===' -ForegroundColor Cyan
$expectedSrcTime = $srcOriginalTime
(Get-Item $srcAbs).LastWriteTime = $expectedSrcTime
foreach ($t in $targets) {
    $now = [System.IO.File]::ReadAllBytes((AbsPath $t))
    if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$originals[$t])) {
        Pass "$t restored byte-identical"
    }
    else { Fail "$t DIFFERS from its original - repair the working tree before committing" }
}

# End state must be a clean pass, proving the restores are real and not just
# "the gate fails on everything".
$final = & pwsh -NoProfile -File $gate 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) { Pass 'gate passes once every mutation is reverted' }
else { Fail 'gate still fails after restore - the tree is not back to its original state'; Write-Host $final }

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) mutation check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: every mutation was rejected and every file restored' -ForegroundColor Green
exit 0
