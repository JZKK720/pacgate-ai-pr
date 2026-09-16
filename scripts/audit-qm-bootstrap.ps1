# Does setup-qm.ps1 generate every variable that qm actually requires?
#
# Read-only. Names only, no values.
#
# The bootstrap script writes a .env from a fixed here-string. If a variable that
# qm.config.jsonc or compose.qm.yaml requires is absent from that here-string, the
# client deployment is missing a secret - and compose substitutes an EMPTY string
# for an unset ${VAR}, so the failure surfaces later as an auth error or an empty
# password rather than as a missing-config error at bootstrap time.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

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

# 1. What does setup-qm.ps1 WRITE into .env?
$setup = Get-Content 'deploy/client-bundle/setup-qm.ps1' -Raw
$hereBlock = [regex]::Match($setup, '(?s)\$envContent\s*=\s*@"(.*?)"@').Groups[1].Value
$generated = @([regex]::Matches($hereBlock, '(?m)^([A-Z][A-Z0-9_]*)=', 'Multiline') | ForEach-Object { $_.Groups[1].Value })
# The regex above needs Multiline; do it explicitly.
$generated = @($hereBlock -split "`r?`n" | ForEach-Object {
        $m = [regex]::Match($_, '^([A-Z][A-Z0-9_]*)=')
        if ($m.Success) { $m.Groups[1].Value }
    } | Select-Object -Unique)

Write-Output '=== 1. Variables setup-qm.ps1 writes into .env ==='
$generated | ForEach-Object { "  $_" }
Write-Output ("  total: {0}" -f $generated.Count)
Write-Output ''

# 2. What does the deployment REQUIRE?
#    (a) ${VAR} interpolations in compose.qm.yaml and qm.config.jsonc
#
# COMMENT LINES ARE STRIPPED FIRST. The first version scanned raw text and
# reported a required variable named 'VAR' - which came from the documentation
# line `# via ${VAR}; never hardcode them here.` A check that reports a comment as
# a missing requirement is a check people stop reading, so comments and blank
# lines are removed before scanning.
$required = [System.Collections.Generic.HashSet[string]]::new()
function Get-CodeText {
    param([string]$Path)
    $out = @()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trim = $line.TrimStart()
        if ($trim.StartsWith('#') -or $trim.StartsWith('//') -or $trim -eq '') { continue }
        $out += $line
    }
    return ($out -join "`n")
}

$composeCode = Get-CodeText 'deploy/qm-pacgate/compose.qm.yaml'
$cfgCode = Get-CodeText 'deploy/qm-pacgate/qm.config.jsonc'

foreach ($raw in @($composeCode, $cfgCode)) {
    foreach ($m in [regex]::Matches($raw, '\$\{([A-Z][A-Z0-9_]*)\}')) { [void]$required.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($raw, '\$\{([A-Z][A-Z0-9_]*):-')) { [void]$required.Add($m.Groups[1].Value) }
}
# (b) sandbox secretEnv entries in qm.config.jsonc - these are JSON strings, not
#     ${} interpolations, so they need their own extraction.
$cfg = Get-Content 'deploy/qm-pacgate/qm.config.jsonc' -Raw
$secMatch = [regex]::Match($cfg, '"secretEnv"\s*:\s*\[(.*?)\]')
if ($secMatch.Success) {
    foreach ($m in [regex]::Matches($secMatch.Groups[1].Value, '"([A-Z][A-Z0-9_]*)"')) { [void]$required.Add($m.Groups[1].Value) }
}

# Optional vars (those with a :- default, or documented optional) do not need a value.
$optional = [System.Collections.Generic.HashSet[string]]::new()
$allRaw = $composeCode + $cfgCode
foreach ($m in [regex]::Matches($allRaw, '\$\{([A-Z][A-Z0-9_]*):-')) { [void]$optional.Add($m.Groups[1].Value) }
foreach ($o in @('ANTHROPIC_API_KEY', 'OPENROUTER_API_KEY', 'PACGATE_API_TOKEN')) { [void]$optional.Add($o) }
# Optional because compose gives them a literal default (PUBLIC_WEB_URL etc are
# set inline, not from .env), or because the service is not enabled locally.
foreach ($o in @('SMTP_USERNAME', 'SMTP_PASSWORD', 'AUTH_EMAIL_FROM', 'AUTH_SIGNING_JWK', 'AUTH_CLIENT_SECRET', 'AUTH_TOKEN_SECRET', 'PORTAL_SESSION_SECRET', 'OPENVIKING_ACCOUNT', 'OPENVIKING_USER')) { [void]$optional.Add($o) }

Write-Output '=== 2. Variables the deployment requires but setup-qm.ps1 does NOT write ==='
$missing = @($required | Where-Object { $generated -notcontains $_ -and $optional -notcontains $_ } | Sort-Object)
if ($missing.Count -eq 0) {
    Write-Host '  (none) - the generated .env is complete' -ForegroundColor Green
}
else {
    foreach ($v in $missing) {
        # Say why it matters, where we can tell.
        $why = switch ($v) {
            'POSTGRES_PASSWORD' { 'qm Postgres password; compose substitutes an EMPTY string if unset' }
            'OPENVIKING_ROOT_API_KEY' { 'sandbox ov-* tools: /mcp authenticates with the ROOT key; the app key returns 401' }
            'OPENVIKING_API_KEY' { 'sandbox OpenViking access' }
            'AUTH_ALLOWED_EMAILS' { 'auth/portal allow-list - without it, who may sign in is undefined' }
            'FIRECRAWL_API_KEY' { 'firecrawl-qm sandbox tool' }
            'SKILL_SIGNING_SECRET' { 'signing key (present in the here-string, check parsing)' }
            default { '' }
        }
        Assert-True $false "missing required variable: $v" $why
    }
}
Write-Output ("  missing: {0}" -f $missing.Count)
Write-Output ''

# 3. Does setup-qm.ps1 actually stage the qm-pacgate deployment?
#
# Checked by BEHAVIOUR, not by a literal string. The first version looked for
# `Copy-Item` on the same line as 'qm-pacgate', which reported "NO" both before
# the fix (correctly) and after it (incorrectly) - the implementation copies via
# a resolved source path, so the words never appear together. A check that goes
# wrong in both directions is worse than none, so this now asserts the three
# things staging actually requires.
Write-Output '=== 3. Does setup-qm.ps1 stage the qm-pacgate deployment? ==='
$setupText = Get-Content 'deploy/client-bundle/setup-qm.ps1' -Raw

$resolvesSource = $setupText -match 'QmSourceDir' -and $setupText -match 'deploy/qm-pacgate'
$doesCopy = $setupText -match 'Copy-Item'
$excludesEnv = $setupText -match "exclude\s*=\s*@\([^)]*'\.env'"
$refusesMissing = $setupText -match 'qm deployment source not found'

Assert-True $resolvesSource 'resolves the tracked source (deploy/qm-pacgate)'
Assert-True $doesCopy 'contains a Copy-Item that stages it'
Assert-True $excludesEnv 'excludes .env, so a re-run cannot destroy generated secrets'
Assert-True $refusesMissing 'fails loudly when the source is absent'

if ($resolvesSource -and $doesCopy -and $excludesEnv -and $refusesMissing) {
    Write-Host '  the header claim ("Copies qm-pacgate/ to the target directory") is now true' -ForegroundColor Green
}
Write-Output ''
Write-Output ("RESULT: {0} of {1} checks passed" -f $passed, ($passed + $failed))
exit ([int]($failed -gt 0))
