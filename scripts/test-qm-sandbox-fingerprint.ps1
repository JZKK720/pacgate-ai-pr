<#
    Tests for qm-sandbox-fingerprint.ps1.

    Builds a throwaway git repo with a sandbox/ tree and a qm.config.jsonc, then
    runs the REAL script against it. A mocked git would not catch the two things
    most likely to break: path handling through git, and line-ending
    normalisation.

    The case that matters most is CASE 4. A drift detector that always says
    'drift' is as useless as one that always says 'current' - it just fails
    loudly instead of silently. CASE 4 proves it reports CURRENT when the source
    genuinely has not changed, so the DRIFT verdict in CASE 5 carries meaning.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repoRoot 'scripts/qm-sandbox-fingerprint.ps1'

if (-not (Test-Path -LiteralPath $target)) {
    throw "Cannot test: script not found at $target"
}

$passed = 0
$failed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ($Expected -eq $Actual) {
        Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host ("  [FAIL] {0}" -f $Label) -ForegroundColor Red
        Write-Host ("         expected: {0}" -f $Expected) -ForegroundColor Gray
        Write-Host ("         actual  : {0}" -f $Actual) -ForegroundColor Gray
        $script:failed++
    }
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Label)
    if ($Haystack -like "*$Needle*") {
        Write-Host ("  [PASS] {0}" -f $Label) -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host ("  [FAIL] {0}" -f $Label) -ForegroundColor Red
        Write-Host ("         output did not contain: {0}" -f $Needle) -ForegroundColor Gray
        $script:failed++
    }
}

# Run a command without touching the caller's location or $LASTEXITCODE.
function Invoke-Captured {
    param([string]$Exe, [string[]]$ArgList, [string]$WorkingDirectory, [string]$Stdin)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }

    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Stdin) { $p.StandardInput.Write($Stdin) }
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Output = ($out + $err); ExitCode = $p.ExitCode }
}

function New-Fixture {
    param([string]$Root)

    $qm = Join-Path $Root 'deploy/qm-pacgate'
    $sb = Join-Path $qm 'sandbox'
    New-Item -ItemType Directory -Force -Path (Join-Path $sb 'skills/demo') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sb 'tools/pacgate-qm') | Out-Null
    Set-Content -LiteralPath (Join-Path $sb 'Dockerfile') -Value "FROM scratch`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $sb 'skills/demo/SKILL.md') -Value "# demo`nskill body`n" -NoNewline
    Set-Content -LiteralPath (Join-Path $sb 'tools/pacgate-qm/tool.json') -Value "{ `"name`": `"pacgate-qm`" }`n" -NoNewline

    $cfg = @'
{
  "contract": 1,
  "orgId": "pacgate",
  "basePort": 8180,
  "sandbox": { "image": "localhost:5000/pacgate-sandboxes@sha256:207a779d0d40ba0bc46c18a4139b936a5ce00dd825f0d8f389e547d1a9991ffc",
    "app": "pacgate-sandboxes"
  }
}
'@
    Set-Content -LiteralPath (Join-Path $qm 'qm.config.jsonc') -Value $cfg -NoNewline

    $gitDir = Join-Path $qm '.git'
    & git init -q --initial-branch=main $qm 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed in $qm" }
    & git -C $qm add -A 2>&1 | Out-Null
    & git -C $qm -c user.email=t@t -c user.name=t commit -q -m init 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $qm" }

    return [pscustomobject]@{ Qm = $qm; Config = (Join-Path $qm 'qm.config.jsonc') }
}

$pwsh = (Get-Command pwsh).Source

# Use the real temp dir, not the 8.3 short form: ProcessStartInfo rejects a
# short-name WorkingDirectory.
$base = Join-Path ([System.IO.Path]::GetTempPath()) ("qmfingerprint-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $base | Out-Null

Write-Host '=== qm-sandbox-fingerprint tests ===' -ForegroundColor Cyan
Write-Host ''

try {
    $fx = New-Fixture -Root $base

    # ---- CASE 1: nothing recorded yet -> NOT_RECORDED, exit 1 --------------
    Write-Host 'CASE 1: no fingerprint recorded' -ForegroundColor White
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 1 $r.ExitCode 'exits non-zero when not recorded'
    Assert-Contains $r.Output 'No fingerprint recorded' 'reports NOT_RECORDED'
    Assert-Contains $r.Output 'cannot be checked against its' 'explains the image cannot be verified'
    Assert-Contains $r.Output 'with no error' 'explains why it matters'
    Write-Output ''

    # ---- CASE 2: -Json is machine readable ---------------------------------
    Write-Host 'CASE 2: -Json output' -ForegroundColor White
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base, '-Json') -WorkingDirectory $base
    Assert-Equal 1 $r.ExitCode 'exits 1 in JSON mode when not recorded'
    $obj = $null
    try { $obj = $r.Output.Trim() | ConvertFrom-Json } catch { }
    if ($obj) {
        Assert-Equal 'NOT_RECORDED' $obj.state 'JSON state is NOT_RECORDED'
        Assert-Equal 3 $obj.fileCount 'JSON counts the 3 tracked sandbox files'
        Assert-Equal 'sha256:207a779d0d40ba0bc46c18a4139b936a5ce00dd825f0d8f389e547d1a9991ffc' $obj.pinnedDigest 'JSON reports the pinned digest'
    }
    else {
        Write-Host '  [FAIL] JSON output did not parse' -ForegroundColor Red
        Write-Host ("         raw: {0}" -f $r.Output) -ForegroundColor Gray
        $script:failed++
    }
    Write-Output ''

    # ---- CASE 3: -Write records it ----------------------------------------
    Write-Host 'CASE 3: -Write records the fingerprint' -ForegroundColor White
    $before = [System.IO.File]::ReadAllText($fx.Config)
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base, '-Write') -WorkingDirectory $base
    Assert-Equal 0 $r.ExitCode '-Write succeeds'
    $after = [System.IO.File]::ReadAllText($fx.Config)
    if ($after -match '"sourceFingerprint"\s*:\s*"([0-9a-f]{64})"') {
        Write-Host '  [PASS] sourceFingerprint written as 64 hex chars' -ForegroundColor Green
        $script:passed++
        $recorded = $Matches[1]
    }
    else {
        Write-Host '  [FAIL] sourceFingerprint not written correctly' -ForegroundColor Red
        $script:failed++
        $recorded = $null
    }
    if ($after -match '"image"\s*:\s*"localhost:5000/pacgate-sandboxes@sha256:207a779d') {
        Write-Host '  [PASS] existing image pin preserved (not clobbered)' -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host '  [FAIL] -Write clobbered the image pin' -ForegroundColor Red
        $script:failed++
    }
    if ($after -match '"orgId"\s*:\s*"pacgate"') {
        Write-Host '  [PASS] config content preserved' -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host '  [FAIL] -Write damaged unrelated config' -ForegroundColor Red
        $script:failed++
    }
    Assert-Equal 1 @(Get-ChildItem -Path $fx.Qm -Filter 'qm.config.jsonc.bak.*').Count 'a backup was made'
    Write-Output ''

    # ---- CASE 4: unchanged source -> CURRENT (the anti-false-positive case) -
    Write-Host 'CASE 4: source unchanged after recording' -ForegroundColor White
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 0 $r.ExitCode 'exits 0 when source matches'
    Assert-Contains $r.Output 'matches the recorded fingerprint' 'reports CURRENT'
    Write-Output ''

    # ---- CASE 4b: a rebuild-in-place must NOT look like drift --------------
    #
    # If sandbox/ is rewritten with identical content but different line
    # endings, the image content is the same and the fingerprint must not move.
    # Otherwise every Windows checkout would report drift against every Linux
    # build, and the check would be ignored - which is how real drift gets
    # missed.
    Write-Host 'CASE 4b: CRLF rewrite of identical content = still CURRENT' -ForegroundColor White
    $skill = Join-Path $fx.Qm 'sandbox/skills/demo/SKILL.md'
    $lf = [System.IO.File]::ReadAllText($skill)
    [System.IO.File]::WriteAllText($skill, $lf.Replace("`n", "`r`n"))
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 0 $r.ExitCode 'line-ending change alone is not drift'
    Write-Output ''

    # ---- CASE 5: real source change -> DRIFT ------------------------------
    Write-Host 'CASE 5: sandbox source actually changed' -ForegroundColor White
    Set-Content -LiteralPath (Join-Path $fx.Qm 'sandbox/skills/demo/SKILL.md') -Value "# demo`nCHANGED BODY`n" -NoNewline
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 1 $r.ExitCode 'exits 1 on drift'
    Assert-Contains $r.Output 'has CHANGED since the image was pinned' 'reports DRIFT'
    Write-Output ''

    # ---- CASE 6: a NEW file is drift too ----------------------------------
    Write-Host 'CASE 6: new sandbox file' -ForegroundColor White
    & git -C $fx.Qm checkout -q -- . 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $fx.Qm 'sandbox/tools/pacgate-qm/new_tool.py') -Value "print(1)`n" -NoNewline
    & git -C $fx.Qm add -A 2>&1 | Out-Null
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 1 $r.ExitCode 'a newly added tracked file is drift'
    Write-Output ''

    # ---- CASE 7: untracked scaffolding is NOT drift -----------------------
    #
    # A scratch file in sandbox/ is not part of what the image was built from.
    # Counting it would make the check fire on work-in-progress and teach the
    # reader to ignore it.
    Write-Host 'CASE 7: untracked file in sandbox/ is not drift' -ForegroundColor White
    & git -C $fx.Qm reset -q 2>&1 | Out-Null
    Remove-Item -LiteralPath (Join-Path $fx.Qm 'sandbox/tools/pacgate-qm/new_tool.py') -Force
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base, '-Write') -WorkingDirectory $base
    Set-Content -LiteralPath (Join-Path $fx.Qm 'sandbox/scratch.tmp') -Value "junk`n" -NoNewline
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base) -WorkingDirectory $base
    Assert-Equal 0 $r.ExitCode 'untracked file does not report drift'
    Write-Output ''

    # ---- CASE 8: -Write is idempotent -------------------------------------
    Write-Host 'CASE 8: -Write when already current' -ForegroundColor White
    Remove-Item -LiteralPath (Join-Path $fx.Qm 'sandbox/scratch.tmp') -Force
    $baksBefore = @(Get-ChildItem -Path $fx.Qm -Filter 'qm.config.jsonc.bak.*').Count
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $base, '-Write') -WorkingDirectory $base
    Assert-Equal 0 $r.ExitCode '-Write succeeds when already current'
    Assert-Contains $r.Output 'already current' 'says it wrote nothing'
    Assert-Equal $baksBefore @(Get-ChildItem -Path $fx.Qm -Filter 'qm.config.jsonc.bak.*').Count 'no redundant backup'
    Write-Output ''

    # ---- CASE 9: missing config fails loudly ------------------------------
    Write-Host 'CASE 9: missing qm.config.jsonc' -ForegroundColor White
    $empty = Join-Path $base 'empty'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $r = Invoke-Captured -Exe $pwsh -ArgList @('-NoProfile', '-File', $target, '-RepoRoot', $empty) -WorkingDirectory $empty
    Assert-Equal 1 $r.ExitCode 'exits 1 when config is missing'
    Assert-Contains $r.Output 'qm.config.jsonc not found' 'names the missing file'
    Write-Output ''
}
finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '=== Results ===' -ForegroundColor Cyan
if ($failed -eq 0) {
    Write-Host ("  {0} passed, 0 failed" -f $passed) -ForegroundColor Green
    exit 0
}
Write-Host ("  {0} passed, {1} FAILED" -f $passed, $failed) -ForegroundColor Red
exit 1
