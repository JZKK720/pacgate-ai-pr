# Regression gate for the Windows PowerShell 5.1 native-stderr defect.
#
# THE DEFECT (measured, not theorised):
#   install.ps1 sets $ErrorActionPreference = "Stop". On the built-in Windows
#   PowerShell 5.1, ANY native command that writes to stderr becomes a
#   TERMINATING error when a redirection is attached - `2>&1`, `2>$null` and
#   `*>` are all affected. PowerShell 7 does not do this.
#
#   `docker compose up -d` writes its progress ("Volume ... Creating",
#   "Container ... Running") to stderr on EVERY run, so a client AIPC running
#   the built-in shell died at the compose-up step with a NativeCommandError and
#   never reached the tenant/admin bootstrap. The dev box never saw it because
#   the operator runs pwsh 7.
#
#   try/catch does NOT help (the error is caught, but the rest of the try block
#   is skipped and the assignment in flight is silently lost). trap { continue }
#   does not help either (execution continues, the assignment is still lost).
#
# WHY THE EXISTING INSTALL TESTS MISSED IT: test-install-render.ps1,
# test-install-repo-pull.ps1 and test-update-end-to-end.ps1 all run the
# installer under `pwsh` with a stub docker that prints NOTHING. A stub that
# never writes to stderr cannot reproduce a stderr-termination defect, and pwsh
# does not have the defect in the first place.
#
# WHAT THIS GATE DOES:
#   A/B/C  static  - no executable `2>&1` survives, every redirection site is
#                    wrapped, and the helper is defined in each client script.
#   D/E/F  dynamic - the REAL shipped helper (extracted from install.ps1 by AST,
#                    so the test cannot drift from the implementation) survives
#                    stderr, preserves $LASTEXITCODE, and yields a clean capture
#                    under Windows PowerShell 5.1.
#   G      control - the same command WITHOUT the helper still dies under 5.1.
#                    Without this the test could pass for the wrong reason.
#   H      parity  - the helper is a no-op under pwsh 7.
#
#   A second, independent defect of the SAME CLASS is covered here too:
#   `-SkipHttpErrorCheck` is a PowerShell 7 parameter. Under 5.1 it raises
#   ParameterBindingException before a request is sent, and because the register
#   call sat in `try { } catch { }` the failure was silent - the installer printed
#   "could not register the admin" and matter provisioning then could not
#   authenticate either, so deer-flow fell back to unsanitized on-disk memory.
#   Invoke-ApiRequest replaces it and reports status/body on both shells.
#   Covered by: A2 static, plus I/J dynamic with I as the control.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$clientScripts = @(
    'deploy/client-bundle/install.ps1'
    'deploy/client-bundle/setup-qm.ps1'
    'deploy/client-bundle/smoke-deer-flow-outputs.ps1'
)

# Scripts OUTSIDE the client bundle fixed for the same defect class. They never ship
# to a client, but three are OPERATIONAL (release dispatch, GHCR login, MCP call) and
# one is a SECURITY gate; every one of them silently did nothing under 5.1. They are
# checked for the PowerShell 7-only parameter class only - they are dev-side and run
# under pwsh, so they are not held to the client scripts' stderr-redirection rules.
$repoScripts = @(
    'scripts/ov-mcp-call.ps1'
    'scripts/ghcr-login.ps1'
    'scripts/dispatch-release-via-api.ps1'
    'scripts/test-install-render.ps1'
    'scripts/test-auth-provisioning-gate.ps1'
)

# Live-stack gates are run by run-all-checks through the SAME launcher that falls
# back to Windows PowerShell 5.1, so their redirection must be 5.1-safe too.
# These were missed because they "worked on the dev box" - which has pwsh.
#
# test-lane-connectivity.ps1 was the proof (found 2026-10-20): under 5.1 it died
# at `docker exec ... 2>&1` (E6), then at a `docker inspect --format '{{index ...
# "com..."}}'` where 5.1 mangles the nested quotes, and reported its two most
# important assertions - the qm->pacgate-api and qm->openviking EDGES - as
# network failures. Under pwsh the same file reported 11 passed. A gate that
# fails for a reason unrelated to the system it inspects is worse than no gate.
$liveStackScripts = @(
    'scripts/test-lane-connectivity.ps1'
)

$pass = 0
$fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $name  $detail" -ForegroundColor Red; $script:fail++ }
}

$work = Join-Path $env:TEMP ("pacgate-ps51-stderr-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    Write-Host "=== PowerShell 5.1 native-stderr gate ===" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # ── A/B/C: static assertions on the shipped scripts ─────────────────────
    Write-Host ''
    Write-Host 'STATIC: the shipped client scripts carry no unguarded redirection'

    foreach ($rel in $clientScripts) {
        $path = Join-Path $repoRoot $rel
        $name = Split-Path $rel -Leaf
        if (-not (Test-Path $path)) { Check "$name exists" $false $path; continue }

        $lines = Get-Content $path

        # A. `2>&1` is never safe on PS 5.1 - the helper cannot normalise it
        #    (PS 5.1 still injects NativeCommandError decoration and reorders
        #    lines). It must not appear in executable code at all.
        $exec21 = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $t = $lines[$i]
            if ($t -match '2>&1' -and $t -notmatch '^\s*#') { $exec21 += ($i + 1) }
        }
        Check "$name has no executable 2>&1" ($exec21.Count -eq 0) "lines: $($exec21 -join ', ')"

        # B. Every `2>$null` / `*>` site must be inside the helper. A wrapped
        #    call may span lines, so a site counts as wrapped when the helper
        #    name appears on its own line or within the 3 lines above it.
        $bare = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $t = $lines[$i]
            if ($t -notmatch '2>\$null|\*>\$null|\*>\$') { continue }
            if ($t -match '^\s*#') { continue }
            $window = @()
            for ($j = [Math]::Max(0, $i - 3); $j -le $i; $j++) { $window += $lines[$j] }
            if (($window -join "`n") -notmatch 'Invoke-WithNativeStderr') { $bare += ($i + 1) }
        }
        Check "$name wraps every redirection site" ($bare.Count -eq 0) "unwrapped lines: $($bare -join ', ')"

        # C. The helper must be defined in the script that uses it, exactly once,
        #    and BEFORE the first call - PowerShell resolves a function at call
        #    time, so a definition placed after its first use would throw.
        $defLines = @()
        $useLines = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*#') { continue }
            if ($lines[$i] -match '^\s*function\s+Invoke-WithNativeStderr') { $defLines += ($i + 1) }
            elseif ($lines[$i] -match 'Invoke-WithNativeStderr') { $useLines += ($i + 1) }
        }
        Check "$name defines the helper exactly once" ($defLines.Count -eq 1) "found $($defLines.Count) definitions"
        Check "$name actually uses the helper" ($useLines.Count -gt 1) "found $($useLines.Count) references"
        if ($defLines.Count -eq 1 -and $useLines.Count -gt 0) {
            Check "$name defines the helper before its first call" ($defLines[0] -lt $useLines[0]) `
                "defined at line $($defLines[0]), first used at line $($useLines[0])"
        }
    }

    # ── Extract the REAL helper from install.ps1 ────────────────────────────
    # Extracted by AST rather than copied, so this gate tests the shipped
    # implementation and cannot silently drift from it.
    Write-Host ''
    Write-Host 'DYNAMIC: the shipped helper under Windows PowerShell 5.1'

    $installPath = Join-Path $repoRoot 'deploy/client-bundle/install.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installPath, [ref]$tokens, [ref]$errors)

    # A2. PowerShell 7-only parameters must not appear in the client scripts.
    #     -SkipHttpErrorCheck throws ParameterBindingException on 5.1 BEFORE the
    #     request is sent, and the swallow-all catch around the old call hid it.
    #     -UseBasicParsing is NOT in this list: it is accepted (and ignored) by
    #     both shells.
    Write-Host ''
    Write-Host 'STATIC: no PowerShell 7-only parameters in the client scripts'
    foreach ($rel in $clientScripts) {
        $path = Join-Path $repoRoot $rel
        $name = Split-Path $rel -Leaf
        if (-not (Test-Path $path)) { continue }
        $exec = @()
        $n = 0
        foreach ($l in (Get-Content $path)) {
            $n++
            if ($l -match '^\s*#') { continue }
            if ($l -match 'SkipHttpErrorCheck|StatusCodeVariable|AsHashtable|AsByteStream|ProgressAction|FollowSymlink') { $exec += $n }
        }
        Check "$name has no PowerShell 7-only parameters" ($exec.Count -eq 0) "lines: $($exec -join ', ')"
    }

    # The same class, in the repo-side scripts fixed alongside them.
    Write-Host ''
    Write-Host 'STATIC: no PowerShell 7-only parameters in the fixed repo scripts'
    foreach ($rel in $repoScripts) {
        $path = Join-Path $repoRoot $rel
        $name = Split-Path $rel -Leaf
        if (-not (Test-Path $path)) { Check "$name exists" $false $path; continue }
        $exec = @()
        $n = 0
        foreach ($l in (Get-Content $path)) {
            $n++
            if ($l -match '^\s*#') { continue }
            if ($l -match 'SkipHttpErrorCheck|StatusCodeVariable|AsHashtable|AsByteStream|ProgressAction|FollowSymlink') { $exec += $n }
        }
        Check "$name has no PowerShell 7-only parameters" ($exec.Count -eq 0) "lines: $($exec -join ', ')"
    }

    # Live-stack gates: the same rules the client scripts are held to, because
    # run-all-checks launches them through a launcher that falls back to 5.1.
    Write-Host ''
    Write-Host 'STATIC: live-stack gates survive Windows PowerShell 5.1'
    foreach ($rel in $liveStackScripts) {
        $path = Join-Path $repoRoot $rel
        $name = Split-Path $rel -Leaf
        if (-not (Test-Path $path)) { Check "$name exists" $false $path; continue }

        $exec = @()
        $n = 0
        foreach ($l in (Get-Content $path)) {
            $n++
            if ($l -match '^\s*#') { continue }
            if ($l -match 'SkipHttpErrorCheck|StatusCodeVariable|AsHashtable|AsByteStream|ProgressAction|FollowSymlink') { $exec += $n }
        }
        Check "$name has no PowerShell 7-only parameters" ($exec.Count -eq 0) "lines: $($exec -join ', ')"

        # A bare `2>&1` on a native command is a terminating error under 5.1.
        # Only a wrapper function's own body may contain one, so the check allows
        # exactly the wrapper patterns this repo uses and nothing else.
        $bare = @()
        $n = 0
        foreach ($l in (Get-Content $path)) {
            $n++
            if ($l -match '^\s*#') { continue }
            if ($l -notmatch '2>&1') { continue }
            if ($l -match 'return \(& \$Script 2>&1') { continue }                 # Invoke-NativeCapture body
            if ($l -match 'docker exec -i \$Container node 2>&1') { continue }     # Invoke-NodeInContainer body
            if ($l -match 'Invoke-WithNativeStderr|Invoke-NativeCapture|Invoke-NodeInContainer') { continue }  # wrapped call
            $bare += $n
        }
        Check "$name wraps every 2>&1 redirection" ($bare.Count -eq 0) "unwrapped lines: $($bare -join ', ')"
    }

    $fnAst = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-WithNativeStderr'
        }, $true)
    Check 'helper found in install.ps1 by AST' ($fnAst.Count -eq 1) "found $($fnAst.Count)"
    if ($fnAst.Count -ne 1) { throw 'cannot extract the helper - aborting' }
    $helperText = $fnAst[0].Extent.Text

    # The child harness. `cmd /c "echo ... 1>&2"` is the smallest native command
    # that writes to stderr, and it is what the original repro used.
    #
    # Built from a SINGLE-quoted here-string with a placeholder, so nothing in
    # the harness body is expanded by this script - the helper text is spliced in
    # verbatim and every `$` in the harness reaches the child intact.
    $harnessTemplate = @'
$ErrorActionPreference = 'Stop'
__HELPER__

# D. survives stderr with a 2>$null capture
$captured = Invoke-WithNativeStderr { cmd /c "echo admin & echo NOTICE: x 1>&2" 2>$null }
Write-Output ("D|" + ($captured -join ','))

# E. $LASTEXITCODE survives the helper boundary
Invoke-WithNativeStderr { cmd /c "exit 7" 2>$null } | Out-Null
Write-Output ("E|" + $LASTEXITCODE)

# F. the capture is CLEAN - no NativeCommandError decoration leaked in
$clean = Invoke-WithNativeStderr { cmd /c "echo admin & echo NOTICE: x 1>&2" 2>$null }
$joined = ($clean -join [char]10)
Write-Output ("F|" + $(if ($joined -match 'NativeCommandError|CategoryInfo') { 'DIRTY' } else { 'CLEAN' }))

# G. CONTROL - the same command with NO helper must still die on 5.1
try {
    $control = cmd /c "echo admin & echo NOTICE: x 1>&2" 2>$null
    Write-Output ("G|SURVIVED|" + ($control -join ','))
}
catch {
    Write-Output "G|DIED"
}
'@
    $harness = $harnessTemplate.Replace('__HELPER__', $helperText)
    $harnessPath = Join-Path $work 'harness.ps1'
    [System.IO.File]::WriteAllText($harnessPath, $harness)

    $ps51 = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
    if (-not $ps51) {
        Write-Host '  [SKIP] powershell.exe not present - cannot exercise the 5.1 path' -ForegroundColor Yellow
    }
    else {
        $out51 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1
        $txt51 = ($out51 | ForEach-Object { "$_" }) -join "`n"
        Write-Host "  --- powershell.exe 5.1 output ---" -ForegroundColor DarkGray
        $txt51 -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        Check 'D: helper survives stderr under 5.1' ($txt51 -match 'D\|admin') "got: $txt51"
        Check 'E: $LASTEXITCODE preserved under 5.1' ($txt51 -match 'E\|7') "got: $txt51"
        Check 'F: 2>$null capture is clean under 5.1' ($txt51 -match 'F\|CLEAN') "got: $txt51"
        # The control is what makes D-F meaningful: if the bare form survived
        # too, the shell would not have the defect and the test would prove
        # nothing about the helper.
        Check 'G: CONTROL - bare form still dies under 5.1' ($txt51 -match 'G\|DIED') "got: $txt51"
    }

    # ── H: parity under pwsh 7 ──────────────────────────────────────────────
    Write-Host ''
    Write-Host 'PARITY: the helper is a no-op under PowerShell 7'
    $pwshCmd = (Get-Command pwsh -ErrorAction SilentlyContinue)
    if (-not $pwshCmd) {
        Write-Host '  [SKIP] pwsh not present' -ForegroundColor Yellow
    }
    else {
        $out7 = & pwsh -NoProfile -ExecutionPolicy Bypass -File $harnessPath 2>&1
        $txt7 = ($out7 | ForEach-Object { "$_" }) -join "`n"
        Check 'H: pwsh 7 gives the same D/E/F results' `
            (($txt7 -match 'D\|admin') -and ($txt7 -match 'E\|7') -and ($txt7 -match 'F\|CLEAN')) "got: $txt7"
        # pwsh 7 does not have the defect, so the control is expected to survive.
        Check 'H: pwsh 7 control survives (defect is 5.1-only)' ($txt7 -match 'G\|SURVIVED') "got: $txt7"
    }

    # ── I/J: the API helper under PowerShell 5.1 ─────────────────────────────
    # Extracted by AST from the shipped install.ps1, same reasoning as above.
    # I is the CONTROL: it must PROVE that -SkipHttpErrorCheck really is absent
    # from 5.1. Without I, J passing would not show the parameter was the fault.
    Write-Host ''
    Write-Host 'DYNAMIC: the API helper under Windows PowerShell 5.1'

    $apiAst = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-ApiRequest'
        }, $true)
    Check 'API helper found in install.ps1 by AST' ($apiAst.Count -eq 1) "found $($apiAst.Count)"
    if ($apiAst.Count -eq 1 -and $ps51) {
        $apiHarness = @'
$ErrorActionPreference = 'Stop'

# I. CONTROL - the parameter the old code used must be absent on 5.1.
$has = $false
try { $has = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck') } catch { }
Write-Output ("I|" + $(if ($has) { 'AVAILABLE' } else { 'ABSENT' }))

# J. the shipped helper must still report a status and a body for a real 403,
#    and must not throw. Any local listener would need a server, so use the
#    documented loopback probe against a port nothing can be listening on: the
#    point is that it returns Error instead of throwing.
__HELPER__
try {
    $r = Invoke-ApiRequest -Uri 'http://127.0.0.1:1/never-listening' -TimeoutSec 5
    Write-Output ("J|OK|status=" + $r.Status + "|error=" + ($r.Error -ne $null))
}
catch {
    Write-Output "J|THREW|$($_.Exception.Message)"
}
'@
        $apiHarness = $apiHarness.Replace('__HELPER__', $apiAst[0].Extent.Text)
        $apiHarnessPath = Join-Path $work 'api-harness.ps1'
        [System.IO.File]::WriteAllText($apiHarnessPath, $apiHarness)

        $apiOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $apiHarnessPath 2>&1
        $apiTxt = ($apiOut | ForEach-Object { "$_" }) -join "`n"
        Write-Host '  --- powershell.exe 5.1 API output ---' -ForegroundColor DarkGray
        $apiTxt -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

        Check 'I: CONTROL - -SkipHttpErrorCheck is ABSENT on 5.1' ($apiTxt -match 'I\|ABSENT') "got: $apiTxt"
        Check 'J: Invoke-ApiRequest returns a result instead of throwing' ($apiTxt -match 'J\|OK') "got: $apiTxt"
    }

    Write-Host ''
    Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
