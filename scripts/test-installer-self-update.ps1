# Test: install.ps1 -Update must run the NEW script, not the pre-refresh body.
#
# WHY THIS EXISTS (found 2026-10-20)
#   PowerShell parses an entire script before executing line 1, so when
#   `install.ps1 -Update` refreshes the repo, the rest of that run continues to
#   execute the OLD body from memory. Every step defined BEFORE the repo refresh
#   therefore could not be fixed by editing the installer - the machine would run
#   the previous version's early steps and only pick the fix up on a SECOND
#   manual run. The Ollama residency step (2b) sits before the refresh, so it
#   would have been skipped on the very update that introduced it.
#
#   install.ps1 now records the hash of the body it is actually running at
#   entry and, after the repo refresh, hands off to the file now on disk when
#   the hash changed. This test proves that behaviour in isolation, with no
#   docker, no ollama and no real repo - it is a pure test of the mechanism.
#
# It runs the same scenario TWICE: once with the handoff (the fix) and once
#   simulating the old behaviour (the control). Without the control, a test that
#   "passes" could simply be measuring a script that always did the right thing.

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-That {
    param([Parameter(Mandatory)] [bool]$Condition, [Parameter(Mandatory)] [string]$Name)
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        $script:Failed++
    }
}

# A miniature stand-in for install.ps1. Two generations exist; gen2 adds the
# "new step" that must actually reach the machine in a single -Update run.
#
#   early  - a step that lives BEFORE the repo refresh (like Ollama residency)
#   swap   - the repo refresh itself, which replaces the file on disk
#   late   - a step that lives AFTER the refresh
function New-SimScript {
    param(
        [Parameter(Mandatory)] [int]$Generation,
        [Parameter(Mandatory)] [bool]$WithHandoff
    )

    # Mirrors install.ps1 exactly: the RUNNING hash is stamped at entry, so by
    # the time the refresh is done, the stamp differs from what is now on disk.
    # The old version of this simulation relied on a hash handed in from outside,
    # which never exists on a first run - that is why the control and the fix
    # behaved identically and the test failed honestly.
    $handoff = if ($WithHandoff) {
        @'
$diskHash = (Get-FileHash -Path $HERE -Algorithm SHA256).Hash
if ($diskHash -ne $env:SIM_RAN_HASH) {
    & $PSCommandPath -Update
    exit $LASTEXITCODE
}
'@
    } else { '' }

    return @"
param([switch]`$Update, [switch]`$SkipRepoPull)

`$HERE = `$PSCommandPath
`$env:SIM_RAN_HASH = (Get-FileHash -Path `$HERE -Algorithm SHA256).Hash
`$root = Split-Path -Parent `$HERE
`$log = Join-Path `$root 'log.txt'

Add-Content -LiteralPath `$log -Value "gen$Generation early"

# the repo refresh: pulls the next generation over this very file
if (`$Update -and `$env:SIM_NEXT -and (Test-Path `$env:SIM_NEXT)) {
    [System.IO.File]::Copy(`$env:SIM_NEXT, `$HERE, `$true)
    `$env:SIM_NEXT = ''
}

$handoff
Add-Content -LiteralPath `$log -Value "gen$Generation late"
"@
}

function Invoke-Scenario {
    param([Parameter(Mandatory)] [bool]$WithHandoff)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('selfupdate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $sim = Join-Path $dir 'sim.ps1'
        $next = Join-Path $dir 'next.ps1'
        $log = Join-Path $dir 'log.txt'

        [System.IO.File]::WriteAllText($sim, (New-SimScript -Generation 1 -WithHandoff $WithHandoff), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($next, (New-SimScript -Generation 2 -WithHandoff $WithHandoff), [System.Text.UTF8Encoding]::new($false))

        $env:SIM_RAN_HASH = ''
        $env:SIM_NEXT = $next
        & pwsh -NoProfile -File $sim -Update 6>&1 2>&1 | Out-Null
        $exit = $LASTEXITCODE
        $env:SIM_NEXT = ''
        $env:SIM_RAN_HASH = ''

        return [pscustomobject]@{
            Exit = $exit
            Lines = @(if (Test-Path $log) { Get-Content -LiteralPath $log } else { @() })
        }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '=== install.ps1 self-update handoff ===' -ForegroundColor Cyan
Write-Output ''

Write-Host 'CASE 1: CONTROL - without the handoff, the pre-refresh body keeps running' -ForegroundColor White
$legacy = Invoke-Scenario -WithHandoff $false
Write-Host ("  log: {0}" -f ($legacy.Lines -join ' | ')) -ForegroundColor DarkGray
Assert-That ($legacy.Exit -eq 0) 'control run exits 0'
Assert-That ($legacy.Lines -contains 'gen1 early') 'control ran the old body before the swap'
Assert-That ($legacy.Lines -contains 'gen1 late') 'CONTROL REPRODUCES THE BUG: the stale body finished its later steps'
Assert-That (-not ($legacy.Lines -contains 'gen2 late')) 'control never reached the new script, so the new step was LOST'
Write-Output ''

Write-Host 'CASE 2: THE FIX - one -Update picks up the new script and runs it' -ForegroundColor White
$fixed = Invoke-Scenario -WithHandoff $true
Write-Host ("  log: {0}" -f ($fixed.Lines -join ' | ')) -ForegroundColor DarkGray
Assert-That ($fixed.Exit -eq 0) 'handoff run exits 0'
Assert-That ($fixed.Lines -contains 'gen1 early') 'the old body still ran its pre-refresh steps (expected, harmless)'
Assert-That (-not ($fixed.Lines -contains 'gen1 late')) 'the STALE body did NOT finish - it handed off instead'
Assert-That ($fixed.Lines -contains 'gen2 early') 'the new script ran'
Assert-That ($fixed.Lines -contains 'gen2 late') 'THE NEW STEP ACTUALLY RAN - this is the defect being fixed'
Write-Output ''

Write-Host 'CASE 3: handoff cannot loop' -ForegroundColor White
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('selfupdate-loop-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
    $sim = Join-Path $dir 'sim.ps1'
    $log = Join-Path $dir 'log.txt'
    [System.IO.File]::WriteAllText($sim, (New-SimScript -Generation 1 -WithHandoff $true), [System.Text.UTF8Encoding]::new($false))
    $env:SIM_RAN_HASH = ''
    $env:SIM_NEXT = ''
    # Nothing to pull: the file never changes, so the hashes always match.
    & pwsh -NoProfile -File $sim -Update 6>&1 2>&1 | Out-Null
    $exit = $LASTEXITCODE
    $lines = @(if (Test-Path $log) { Get-Content -LiteralPath $log } else { @() })
    $env:SIM_RAN_HASH = ''
    Assert-That ($exit -eq 0) 'no-change -Update exits 0'
    Assert-That (@($lines | Where-Object { $_ -eq 'gen1 early' }).Count -eq 1) 'body ran exactly ONCE (no re-exec when the file is unchanged)'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ''

if ($script:Failed -gt 0) {
    Write-Host ("RESULT: {0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    exit 1
}
Write-Host ("RESULT: {0} passed, 0 failed" -f $script:Passed) -ForegroundColor Green
exit 0
