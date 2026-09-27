# Mutation test for scripts/test-memory-lane.ps1.
#
# A gate that cannot fail is not a gate. This breaks each assertion in turn and
# asserts the gate REJECTS, then restores every file byte-identical. Modelled on
# test-memory-guard.ps1's companion mutation harness.
#
# Exit codes: 0 = every mutation was rejected and every file restored,
#             1 = a mutation was ACCEPTED (the gate is blind), or a restore failed.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$script:failures = 0
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }

$gate = 'scripts/test-memory-lane.ps1'
if (-not (Test-Path $gate)) { Write-Host "exit 2 - gate not found at $gate" -ForegroundColor Yellow; exit 2 }

$targets = @(
    'deploy/client-bundle/.env.example'
    'deploy/client-bundle/deer-flow-config.yaml'
    'deploy/client-bundle/compose.bundle.yaml'
)

# Absolute paths, built once. Resolve-Path cannot be used for the .bak sibling
# because it does not exist yet - resolving it is what the first run crashed on.
$root = (Get-Location).Path
function AbsPath([string]$rel) { Join-Path $root ($rel -replace '/', '\') }

# Snapshot originals in memory AND on disk so a mid-run crash cannot leave the
# tree mutated. Restoring from memory alone would lose everything on a crash.
$originals = @{}
foreach ($t in $targets) {
    $abs = AbsPath $t
    if (-not (Test-Path $abs)) { Write-Host "exit 2 - missing $t" -ForegroundColor Yellow; exit 2 }
    $originals[$t] = [System.IO.File]::ReadAllText($abs)
    [System.IO.File]::WriteAllText("$abs.bak", $originals[$t])
}

function Test-MutationRejected {
    param([string]$Name, [string]$File, [string]$Find, [string]$ReplaceWith)

    $abs = AbsPath $File
    $orig = $originals[$File]
    if (-not $orig.Contains($Find)) {
        Fail "$Name - mutation pattern not found in $File, so the mutation did not run and the gate was never tested"
        return
    }
    $mut = $orig.Replace($Find, $ReplaceWith)
    [System.IO.File]::WriteAllText($abs, $mut)

    $output = & pwsh -NoProfile -File $gate 2>&1 | Out-String
    $code = $LASTEXITCODE
    [System.IO.File]::WriteAllText($abs, $orig)

    if ($code -eq 1) {
        Pass "$Name -> rejected"
    }
    elseif ($code -eq 0) {
        Fail "$Name -> ACCEPTED. The gate passed on a broken tree, so it cannot protect this property."
        Write-Host $output
    }
    else {
        Fail "$Name -> exit $code (expected 1). An exit 2 means the gate could not check, which is not a rejection."
    }
}

Write-Host '=== memory-lane gate: mutation tests ===' -ForegroundColor Cyan

# The real incident. This is the exact value .env.example shipped.
Test-MutationRejected -Name '.env.example PACGATE_MATTER_ID blanked' `
    -File 'deploy/client-bundle/.env.example' `
    -Find 'PACGATE_MATTER_ID=00000000-0000-4000-8000-000000000000' `
    -ReplaceWith 'PACGATE_MATTER_ID='

Test-MutationRejected -Name 'storage_class reverted to FileMemoryStorage' `
    -File 'deploy/client-bundle/deer-flow-config.yaml' `
    -Find 'pacgate_deerflow_adapter.storage.PacgateMemoryStorage' `
    -ReplaceWith 'deerflow.agents.memory.storage.FileMemoryStorage'

Test-MutationRejected -Name 'PACGATE_MATTER_ID dropped from compose' `
    -File 'deploy/client-bundle/compose.bundle.yaml' `
    -Find 'PACGATE_MATTER_ID: ${PACGATE_MATTER_ID}' `
    -ReplaceWith 'PACGATE_MATTER_ID_UNUSED: ${PACGATE_MATTER_ID}'

Write-Host ''
Write-Host '=== restore verification ===' -ForegroundColor Cyan
foreach ($t in $targets) {
    $now = [System.IO.File]::ReadAllText((Resolve-Path $t))
    if ($now -ceq $originals[$t]) { Pass "$t restored byte-identical" }
    else { Fail "$t DIFFERS from its original - repair the working tree before committing" }
    Remove-Item "$t.bak" -Force -ErrorAction SilentlyContinue
}

# End state must be a clean pass, proving the restores are real and not just
# "the gate fails on everything".
$final = & pwsh -NoProfile -File $gate 2>&1 | Out-String
if ($LASTEXITCODE -eq 0) { Pass 'gate passes once every mutation is reverted' }
else { Fail "gate still fails after restore - the tree is not back to its original state"; Write-Host $final }

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host "FAILED: $($script:failures) mutation check(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED: every mutation was rejected and every file restored' -ForegroundColor Green
exit 0
