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
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$clientScripts = @(
    'deploy/client-bundle/install.ps1'
    'deploy/client-bundle/setup-qm.ps1'
    'deploy/client-bundle/smoke-deer-flow-outputs.ps1'
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

    Write-Host ''
    Write-Host "RESULT: $pass passed, $fail failed" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit 1 }
