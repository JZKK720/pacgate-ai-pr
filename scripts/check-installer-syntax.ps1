# Syntax check for the installer scripts. Read-only, no side effects.
#
# Uses the PowerShell PARSER and nothing else.
#
# There is deliberately no brace-counting check here, and the reason is worth
# recording because I wrote one and had to delete it.
#
# The first version also counted '{' and '}' with a regex. That produced a false
# "BRACES UNBALANCED" on qm-sandbox-fingerprint.ps1, because '{0}' inside a
# format string looks like a brace to a regex. I then switched to counting
# parser tokens - which reported 0 braces in EVERY file and passed everything.
# $ast.Tokens is empty for ParseFile results; the AST retains structure, not the
# token stream. So the "fix" turned a noisy check into a check that could not
# fail, which is worse: it looks like verification and verifies nothing.
#
# Before re-adding any balance check, note that the parser ALREADY catches every
# case it would cover. Verified by probe: a file missing a closing brace gives
# "missing closing brace" at line 1; a file with an extra opening brace gives
# the same error at the point the block opens. A truncated file cannot silently
# pass. So the honest answer is one check, not two.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

$targets = @(
    'deploy/client-bundle/install.ps1'
    'deploy/client-bundle/setup-qm.ps1'
    'scripts/qm-sandbox-fingerprint.ps1'
    'scripts/test-qm-sandbox-fingerprint.ps1'
    'scripts/check-installer-syntax.ps1'
    'scripts/audit-aipc-update-coverage.ps1'
    'scripts/test-install-render.ps1'
    'scripts/test-install-repo-pull.ps1'
)

$bad = 0
foreach ($t in $targets) {
    $p = Join-Path $repoRoot $t
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Output ("SKIP {0}  (not present)" -f $t)
        continue
    }

    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs) | Out-Null

    if ($errs -and $errs.Count -gt 0) {
        Write-Output ("FAIL {0}" -f $t)
        $errs | ForEach-Object {
            Write-Output ("       line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
        }
        $bad++
    }
    else {
        Write-Output ("OK   {0}" -f $t)
    }
}

Write-Output ''
if ($bad -eq 0) {
    Write-Output 'All checked scripts parse cleanly.'
    exit 0
}
Write-Output ("{0} file(s) failed to parse." -f $bad)
exit 1
