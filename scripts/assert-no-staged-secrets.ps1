# Pre-commit guard: confirm the STAGED diff contains no live credentials.
# Scans `git diff --cached` for credential-shaped values. Exits 1 if any found,
# so it can be wired into a pre-commit hook.
# Reports rule names and file names only - never values.
#
# ENCODING: PowerShell on a CJK Windows locale decodes native-command output
# using the console codepage (GBK), which mangles UTF-8 that git emits. Without
# the two lines below, CJK credentials (密码：...) arrive as mojibake and this
# guard silently misses exactly the case it was written for. Verified by test.
$prevConsole = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$prevOut = $OutputEncoding
$OutputEncoding = [System.Text.Encoding]::UTF8

try {
    $diff = git -c core.quotepath=false diff --cached -U0
}
finally {
    [Console]::OutputEncoding = $prevConsole
    $OutputEncoding = $prevOut
}

$rules = [ordered]@{
    'cjk-密码'    = '密码\s*[：:]\s*(?:&#xA;)?(?<v>[^\s|`]+)'
    'cjk-登录名'  = '(?:统一)?登录名\s*[：:]\s*(?<v>[^\s|`]+)'
    'api-token'   = 'API\s*:\s*`?(?<v>[A-Za-z0-9_\\\-]{16,})'
    'md-Password' = '\|\s*\*\*Password\*\*\s*\|\s*`(?<v>[^`]+)`'
    'md-Email'    = '\|\s*\*\*Email\*\*\s*\|\s*`(?<v>[^`]+)`'
    'known-keys'  = '(?<v>vq_key_[A-Za-z0-9_\\\-]{10,}|sk-[A-Za-z0-9_\-]{16,}|gh[pous]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35})'
}

$currentFile = '(unknown)'
$hits = @()

# The credential scanners themselves contain credential-shaped regex literals.
# Matching those would make this guard fail on its own source, training people
# to bypass it - so skip the scanner scripts by name.
$scannerFiles = @(
    'detect-literal-credentials.ps1'
    'redact-exposed-credentials.ps1'
    'assert-no-staged-secrets.ps1'
    'check-credential-state.ps1'
)

foreach ($line in ($diff -split "`r?`n")) {
    if ($line -match '^\+\+\+ b/(.+)$') { $currentFile = $Matches[1]; continue }
    if (-not $line.StartsWith('+')) { continue }   # only added lines
    if ($line.StartsWith('+++')) { continue }
    if ($scannerFiles -contains (Split-Path $currentFile -Leaf)) { continue }

    foreach ($name in $rules.Keys) {
        foreach ($m in [regex]::Matches($line, $rules[$name])) {
            $v = $m.Groups['v'].Value.Trim()
            if ($v -match 'REDACTED') { continue }
            # Skip placeholders and documentation stand-ins. The angle-bracket
            # case matters because docs describing the format (e.g.
            # "密码：<value>") would otherwise trip this guard.
            if ($v -match '^(待填写|待补|xxx|\*+|-+|□+)$') { continue }
            if ($v -match '^<.*>$') { continue }
            if ($v -match '^\$\{|^\{\{') { continue }
            if ($v.Length -lt 5) { continue }
            $hits += [pscustomobject]@{ File = $currentFile; Rule = $name }
        }
    }
}

if (-not $hits) {
    Write-Output 'PASS: staged diff contains no live credentials.'
    exit 0
}

Write-Output "FAIL: staged diff contains credential-shaped values."
$hits | Group-Object File | ForEach-Object {
    Write-Output ("  {0}" -f $_.Name)
    $_.Group | Select-Object -ExpandProperty Rule -Unique | ForEach-Object { Write-Output "      rule: $_" }
}
exit 1
