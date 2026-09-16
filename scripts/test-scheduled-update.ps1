<#
    Tests for scheduled-update.ps1's CLASSIFIER and window logic.

    The classifier is the whole point of the wrapper: install.ps1 exits 0 whether
    or not the repo half of the update landed, so the exit code cannot be trusted
    to mean "everything worked". If the classifier is wrong the scheduled task
    reports SUCCESS on a machine that is silently drifting - which is worse than
    no wrapper at all, because it adds confidence without evidence.

    So this does not test it by reading the source. It builds fixtures, runs the
    REAL wrapper, and reads the status file it writes.

    A note on method: the wrapper invokes `install.ps1 -Update`, which needs
    docker and ollama. A stub `docker.cmd` cannot emit the warnings the classifier
    looks for, so instead of stubbing those tools we point the wrapper at a FAKE
    install.ps1 whose output we control exactly. That keeps the test focused on
    the classifier, which is the part that can be wrong in a way nothing else
    would catch.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $repoRoot 'scripts/scheduled-update.ps1'
if (-not (Test-Path -LiteralPath $wrapper)) { throw "wrapper not found: $wrapper" }

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

$base = Join-Path ([System.IO.Path]::GetTempPath() -replace 'CUBECL~1', 'cubecloud-io') ('sched-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $base | Out-Null

# Build a fake bundle whose install.ps1 emits a chosen message and exits 0.
function New-FakeBundle {
    param([string]$Name, [string]$Emit, [int]$ExitCode = 0)
    $bundle = Join-Path $base $Name
    New-Item -ItemType Directory -Force -Path $bundle | Out-Null
    # Write-Host deliberately: install.ps1 uses Write-Host, and the wrapper must
    # capture the Information stream (6>&1). If it captured only 2>&1 the
    # classifier would see nothing and report SUCCESS every time - so emitting via
    # Write-Host is what makes this test detect that specific bug.
    $body = @"
Write-Host '=== Pacgate-ai Installer ==='
Write-Host "$Emit"
exit $ExitCode
"@
    [System.IO.File]::WriteAllText((Join-Path $bundle 'install.ps1'), $body, [System.Text.UTF8Encoding]::new($false))
    return $bundle
}

function Invoke-Wrapper {
    param([string]$Bundle, [string[]]$Extra = @())
    $logDir = Join-Path $Bundle 'logs'
    $out = & pwsh -NoProfile -File $wrapper -BundleDir $Bundle -LogDir $logDir @Extra 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sf = Join-Path $logDir 'last-update-status.json'
    $status = if (Test-Path $sf) { Get-Content $sf -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Output = $out; Exit = $code; Status = $status; LogDir = $logDir }
}

Write-Host '=== scheduled-update classifier tests ===' -ForegroundColor Cyan
Write-Output ''

try {
    # ---- 1. clean run -> SUCCESS -----------------------------------------
    Write-Host 'CASE 1: a fully successful update' -ForegroundColor White
    $b = New-FakeBundle -Name 'ok' -Emit '[OK] Repo updated abc1234 -> def5678 (2 commit(s))'
    $r = Invoke-Wrapper -Bundle $b
    Assert-True ($r.Exit -eq 0) 'exit 0 for SUCCESS' "got $($r.Exit)"
    Assert-True ($r.Status.outcome -eq 'SUCCESS') 'classified SUCCESS' "got $($r.Status.outcome)"
    Assert-True (@($r.Status.degradedReasons).Count -eq 0) 'no degraded reasons'
    Assert-True ($r.Output -match 'OUTCOME: SUCCESS') 'says so on the console'
    Write-Output ''

    # ---- 2. each degraded condition -> DEGRADED --------------------------
    Write-Host 'CASE 2: each condition install.ps1 treats as a mere warning' -ForegroundColor White
    $cases = @(
        @{ N = 'dirty';   M = '[WARN] Repo has local changes - skipping the repo update.';       K = 'dirty' }
        @{ N = 'diverge'; M = '[WARN] Repo has diverged from origin/main - not fast-forwardable.'; K = 'diverged' }
        @{ N = 'nogit';   M = '[WARN] git not found - cannot refresh the repo.';                  K = 'git is missing' }
        @{ N = 'nocheck'; M = '[WARN] C:\x is not a git checkout - cannot refresh.';               K = 'not a git checkout' }
        @{ N = 'offline'; M = '[WARN] git fetch failed (offline?) - continuing with the current checkout.'; K = 'offline' }
        @{ N = 'qmsand';  M = '[WARN] qm sandbox source has CHANGED since the image was pinned.';  K = 'qm sandbox is stale' }
    )
    foreach ($c in $cases) {
        $b = New-FakeBundle -Name $c.N -Emit $c.M
        $r = Invoke-Wrapper -Bundle $b
        Assert-True ($r.Status.outcome -eq 'DEGRADED') ("'{0}' -> DEGRADED" -f $c.K) "got $($r.Status.outcome)"
        # 2, not 1: the task scheduler's "last result" must distinguish degraded
        # (needs a human, machine still working) from failed (broken).
        Assert-True ($r.Exit -eq 2) ("'{0}' exits 2 (distinct from FAILED=1)" -f $c.K) "got $($r.Exit)"
        Assert-True ($r.Status.degradedReasons.Count -ge 1) ("'{0}' records a reason" -f $c.K)
    }
    Write-Output ''

    # ---- 3. multiple reasons are all recorded ----------------------------
    Write-Host 'CASE 3: several degradations at once' -ForegroundColor White
    $b = New-FakeBundle -Name 'multi' -Emit '[WARN] Repo has local changes - skipping the repo update.`n[WARN] qm sandbox source has CHANGED since the image was pinned.'
    $r = Invoke-Wrapper -Bundle $b
    Assert-True ($r.Status.outcome -eq 'DEGRADED') 'still DEGRADED'
    Assert-True ($r.Status.degradedReasons.Count -eq 2) 'both reasons recorded' "got $($r.Status.degradedReasons.Count)"
    Write-Output ''

    # ---- 4. non-zero exit from install.ps1 -> FAILED ---------------------
    Write-Host 'CASE 4: the installer itself fails' -ForegroundColor White
    $b = New-FakeBundle -Name 'fail' -Emit 'ERROR: Docker daemon not running.' -ExitCode 1
    $r = Invoke-Wrapper -Bundle $b
    Assert-True ($r.Status.outcome -eq 'FAILED') 'classified FAILED' "got $($r.Status.outcome)"
    Assert-True ($r.Exit -eq 1) 'exit 1 for FAILED' "got $($r.Exit)"
    Write-Output ''

    # ---- 5. FAILED outranks DEGRADED -------------------------------------
    Write-Host 'CASE 5: failed AND degraded -> FAILED wins' -ForegroundColor White
    $b = New-FakeBundle -Name 'both' -Emit '[WARN] Repo has local changes - skipping the repo update.' -ExitCode 1
    $r = Invoke-Wrapper -Bundle $b
    Assert-True ($r.Status.outcome -eq 'FAILED') 'FAILED takes precedence' "got $($r.Status.outcome)"
    Write-Output ''

    # ---- 6. maintenance window -------------------------------------------
    #
    # The window arithmetic must handle a range that wraps midnight (22 -> 6),
    # because that is the realistic operator setting: quiet hours are overnight.
    #
    # Getting this right in the TEST took a correction. The first version used
    # start = now+1, end = now and asserted it would RUN - but that window
    # excludes now by construction (it is the complement), so the failure was my
    # arithmetic, not the wrapper's logic. Both branches are now driven explicitly.
    Write-Host 'CASE 6: maintenance window' -ForegroundColor White
    $b = New-FakeBundle -Name 'window' -Emit '[OK] Repo updated a -> b'
    $now = (Get-Date).Hour

    # (a) A window that CONTAINS now, wrapping midnight whenever now != 0.
    #     start = now, end = now-1 (mod 24) => start > end => wrap branch; the
    #     `hour >= start` arm matches. When now == 0 it does not wrap and the
    #     window is 0..22, which still contains 0.
    $cStart = $now
    $cEnd = ($now + 23) % 24
    $r = Invoke-Wrapper -Bundle $b -Extra @('-MaintenanceWindowStart', "$cStart", '-MaintenanceWindowEnd', "$cEnd")
    Assert-True ($r.Status.outcome -eq 'SUCCESS') 'a window containing now runs' "window $cStart-$cEnd, now $now, got $($r.Status.outcome)"

    # (b) A window that EXCLUDES now, wrapping wherever possible.
    #     start = now+1, end = now-1 (mod 24).
    $xStart = ($now + 1) % 24
    $xEnd = ($now + 23) % 24
    $r = Invoke-Wrapper -Bundle $b -Extra @('-MaintenanceWindowStart', "$xStart", '-MaintenanceWindowEnd', "$xEnd")
    Assert-True ($r.Status.outcome -eq 'SKIPPED') 'a window excluding now is SKIPPED' "window $xStart-$xEnd, now $now, got $($r.Status.outcome)"
    Assert-True ($r.Exit -eq 0) 'SKIPPED is not a failure' "got $($r.Exit)"
    Assert-True ($r.Output -match 'outside the maintenance window') 'explains why'

    # (c) -Force overrides an excluding window.
    $r = Invoke-Wrapper -Bundle $b -Extra @('-MaintenanceWindowStart', "$xStart", '-MaintenanceWindowEnd', "$xEnd", '-Force')
    Assert-True ($r.Status.outcome -eq 'SUCCESS') '-Force overrides the window' "got $($r.Status.outcome)"

    # (d) A full-day window is never skipped.
    $r = Invoke-Wrapper -Bundle $b -Extra @('-MaintenanceWindowStart', '0', '-MaintenanceWindowEnd', '23')
    Assert-True ($r.Status.outcome -eq 'SUCCESS') 'a full-day window runs at any hour' "got $($r.Status.outcome)"
    Write-Output ''

    # ---- 7. log rotation --------------------------------------------------
    Write-Host 'CASE 7: log rotation keeps the newest N' -ForegroundColor White
    $b = New-FakeBundle -Name 'rot' -Emit '[OK] Repo updated a -> b'
    $ld = Join-Path $b 'logs'
    New-Item -ItemType Directory -Force -Path $ld | Out-Null
    # Pre-seed old logs with distinct timestamps so ordering is deterministic.
    foreach ($i in 1..5) {
        $f = Join-Path $ld ("update-2020010{0}-000000.log" -f $i)
        Set-Content -LiteralPath $f -Value 'old'
        (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$i)
    }
    # KeepRuns is not exposed as a wrapper param in the call above; run directly.
    & pwsh -NoProfile -File $wrapper -BundleDir $b -LogDir $ld -KeepRuns 2 2>&1 | Out-Null
    $remaining = @(Get-ChildItem -LiteralPath $ld -Filter 'update-*.log' -File).Count
    Assert-True ($remaining -le 3) 'old logs pruned to about KeepRuns' "found $remaining"

    # ---- 8. status file is machine-readable and complete -----------------
    Write-Host 'CASE 8: status file shape' -ForegroundColor White
    Assert-True ($null -ne $r.Status.timestamp) 'has a timestamp'
    Assert-True ($null -ne $r.Status.exitCode -or $r.Status.outcome -eq 'SKIPPED') 'records the installer exit code'
    Assert-True ($null -ne $r.Status.logFile) 'points at its log file'
}
catch {
    Write-Host ("  [FAIL] harness error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failed++
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($failed -eq 0) {
    Write-Host ("{0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("{0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
