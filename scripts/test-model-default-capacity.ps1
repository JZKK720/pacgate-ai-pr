# Proves the models[0] capacity stop in deploy/client-bundle/install.ps1 works.
#
# WHY THIS IS A GATE AND NOT A HARNESS
#
# The install-time check is the ONLY thing that turns "this host cannot load the
# default model" into a stop. B0 in test-aipc-capacity-fit.ps1 makes it visible,
# but a warning does not stop an install, and a client never reads the suite.
#
# The failure it prevents, measured 2026-10-05 on a 4 GB Radeon 8060S: the shipped
# `models[0]` was nemotron-3.5-bolt:e4b-q8_0 at 9.8 GB. `ollama pull` succeeded,
# `ollama list` showed it, every install step printed [OK], and the stack failed
# three stages later on the first agent run. `ollama ps` was never consulted, and
# the tracked config does not read PACGATE_MODEL_*, so `.env` could not retarget it.
#
# WHAT IS ASSERTED
#   1. a host that FITS proceeds                   (no false alarm on good hardware)
#   2. a host that does NOT fit STOPS with exit 1  (options C, the shipped posture)
#   3. -AllowCloudDefault promotes an ACTIVE :cloud entry and proceeds (options B,
#      explicitly opt-in - a client never starts sending prompts off-machine by
#      default)
#   4. -AllowCloudDefault with no promotable entry FAILS rather than pretending
#
# The functions are LOADED FROM install.ps1, not restated here, so this cannot
# drift from what runs on a client machine.
#
# Exit codes: 0 = all paths behave; 1 = a path is wrong; 2 = cannot check.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$installer = 'deploy/client-bundle/install.ps1'
if (-not (Test-Path $installer)) {
    Write-Host "SKIP: $installer not found" -ForegroundColor Yellow
    exit 2
}

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== models[0] capacity gate (install-time stop) ==='

$src = Get-Content $installer -Raw

# An extracted scriptblock does not inherit install.ps1's $PSScriptRoot (it is an
# automatic variable, empty inside ::Create), so substitute the real path as a
# literal. The shipped path arithmetic is therefore still what gets exercised.
$bundleDir = (Resolve-Path 'deploy/client-bundle').Path.Replace("'", "''")
foreach ($n in @('Get-DiscreteVramGiB', 'Invoke-WithNativeStderr', 'Confirm-ModelCapacityGate')) {
    $m = [regex]::Match($src, "(?ms)^function $n\b.*?^\}")
    if (-not $m.Success) { Check "function $n is present in install.ps1" $false 'cannot load the shipped function'; continue }
    . ([scriptblock]::Create($m.Value.Replace('$PSScriptRoot', "'$bundleDir'")))
}

$QmPowerShell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

# The functions exit the process on failure, so each scenario runs in its own
# child. That is deliberate: the shipped behaviour IS "stop the install", and
# simulating it in-process would test a copy rather than the thing that ships.
$scenarios = @(
    @{ N = 'a host that fits proceeds';                         Vram = 16; Allow = $false; Expect = 0
       Want = 'default model fits' }
    @{ N = 'a host that cannot fit the default model STOPS';    Vram = 4;  Allow = $false; Expect = 1
       Want = 'the shipped default model cannot load on this host' }
    @{ N = '-AllowCloudDefault promotes an active :cloud entry'; Vram = 4; Allow = $true;  Expect = 0
       Want = 'default promoted to' }
)

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("capgate-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
try {
    foreach ($s in $scenarios) {
        $vram = $s.Vram
        $allow = if ($s.Allow) { '$true' } else { '$false' }
        $body = @"
`$ErrorActionPreference = 'Stop'
Set-Location '$((Get-Location).Path.Replace("'", "''"))'
`$src = Get-Content '$($installer.Replace("'", "''"))' -Raw
foreach (`$n in @('Get-DiscreteVramGiB','Invoke-WithNativeStderr','Confirm-ModelCapacityGate')) {
    `$m = [regex]::Match(`$src, "(?ms)^function `$n\b.*?^\}")
    . ([scriptblock]::Create(`$m.Value.Replace('`$PSScriptRoot', "'$bundleDir'")))
}
`$QmPowerShell = '$QmPowerShell'
`$AllowCloudDefault = $allow
function Get-DiscreteVramGiB { return $vram }
Confirm-ModelCapacityGate
exit 0
"@
        Set-Content -LiteralPath $scratch -Value $body -Encoding UTF8
        $out = & $QmPowerShell -NoProfile -ExecutionPolicy Bypass -File $scratch 2>&1 | Out-String
        $exit = $LASTEXITCODE
        Check $s.N ($exit -eq $s.Expect -and $out -match [regex]::Escape($s.Want)) `
            "expected exit $($s.Expect) and '$($s.Want)'; got exit $exit. output: $(($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' | ')"
    }
}
finally {
    if (Test-Path $scratch) { Remove-Item $scratch -Force }
}

# 4. The opt-in must not silently succeed when there is nothing to promote. A
#    generator that answers "not promotable" has to become a STOP, or the install
#    continues with a default that still cannot load - the original defect.
Check '-AllowCloudDefault does not claim success without a promotable entry' `
    ($src -match '\$promoted' -and $src -match 'no active :cloud entry could be promoted') `
    'without this the flag would print [OK] and continue on a host that still cannot load the default'

# The flag must be OPT-IN. If it defaulted on, every small-GPU client would start
# sending prompts to ollama.com without anyone deciding that.
Check '-AllowCloudDefault is opt-in, not the default posture' `
    ($src -match '(?ms)param\(.*?\[switch\]\$AllowCloudDefault') `
    'the switch must be declared in param() and default to false'

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
