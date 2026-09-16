# Precise detector for LITERAL credential values in tracked docs/code.
#
# Tuned to the two failure modes this repo actually has:
#   (a) CJK prose:   密码：<literal>        (full-width or half-width colon)
#   (b) markdown row: | **Password** | `<literal>` |
# plus known key formats (vq_key_, sk-, ghp_, github_pat_, AKIA, AIza, xox).
#
# Reports FILE + LINE + RULE only. Never prints the value.
# Ignores obvious non-secrets: type annotations, env refs, placeholders.
param(
    [string[]]$Paths
)

if (-not $Paths) { $Paths = git ls-files }

$textExt = @('.md', '.txt', '.json', '.jsonc', '.yaml', '.yml', '.ps1', '.sh', '.py', '.rs', '.ts', '.js', '.sql', '.conf', '.ini', '.cfg', '.toml', '.example')

# Values that are clearly NOT secrets - if the whole value matches, skip.
$placeholderRe = '(?i)^(待填写|待补|xxx+|\*+|□+|todo|tbd|n/?a|none|null|-+|your[-_]?\w*|\{\{.*\}\}|\$\{.*\}|<.*>|redacted|placeholder|example|dummy|sample|changeme|change-me|change_me|value_here|replace[-_]?locally|ollama|ollama-local|\[REDACTED[^\]]*\])$'

# Known real-secret formats - always flag, wherever they appear.
$formatRules = @(
    @{ Name = 'vq_key';      Re = 'vq_key_[A-Za-z0-9_\\\-]{10,}' }
    @{ Name = 'sk-key';      Re = 'sk-[A-Za-z0-9_\-]{16,}' }
    @{ Name = 'gh-pat';      Re = 'gh[pous]_[A-Za-z0-9]{30,}' }
    @{ Name = 'gh-finegrained'; Re = 'github_pat_[A-Za-z0-9_]{40,}' }
    @{ Name = 'aws-akia';    Re = 'AKIA[0-9A-Z]{16}' }
    @{ Name = 'google-aiza'; Re = 'AIza[0-9A-Za-z_\-]{35}' }
    @{ Name = 'slack-xox';   Re = 'xox[baprs]-[A-Za-z0-9\-]{10,}' }
    @{ Name = 'pem-block';   Re = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
)

# Label-driven rules: capture the value after a credential label, then decide.
$labelRules = @(
    @{ Name = 'cjk-密码';    Re = '密码\s*[：:]\s*(?:&#xA;)?\s*(?<v>[^\s|`]+)' }
    @{ Name = 'cjk-登录名';  Re = '(?:统一)?登录名\s*[：:]\s*(?<v>[^\s|`]+)' }
    @{ Name = 'cjk-密钥';    Re = '密钥\s*[：:]\s*(?<v>[^\s|`]+)' }
    @{ Name = 'md-Password'; Re = '\|\s*\*\*Password\*\*\s*\|\s*`?(?<v>[^`|\s]+)`?\s*\|' }
    @{ Name = 'md-Email';    Re = '\|\s*\*\*Email\*\*\s*\|\s*`?(?<v>[^`|\s]+)`?\s*\|' }
)

# Scanners contain credential-shaped regex literals by design. Excluded so the
# scan does not report a permanent false positive on itself.
$scannerFiles = @(
    'detect-literal-credentials.ps1'
    'redact-exposed-credentials.ps1'
    'assert-no-staged-secrets.ps1'
    'assert-range-no-new-secrets.ps1'
    'check-credential-state.ps1'
)

$hits = @()

foreach ($rel in $Paths) {
    $ext = [System.IO.Path]::GetExtension($rel).ToLower()
    if ($textExt -notcontains $ext) { continue }
    if (-not (Test-Path -LiteralPath $rel)) { continue }
    if ((Get-Item -LiteralPath $rel).PSIsContainer) { continue }

    # Self-exclusion. The credential scanners contain credential-shaped regex
    # literals by design; matching them would report a permanent false positive
    # and train people to ignore this scan entirely.
    if ($scannerFiles -contains (Split-Path $rel -Leaf)) { continue }

    $lines = $null
    # Wrap in @() to FORCE an array. Get-Content returns a bare [string] for a
    # single-line file, and indexing that yields the first CHARACTER, not the
    # line - which made this scan silently miss any one-line file (verified:
    # a planted "密码：<secret>" in a 1-line file was read as just "密").
    try { $lines = @(Get-Content -LiteralPath $rel -ErrorAction Stop) } catch { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineno = $i + 1
        $fired = @()

        foreach ($r in $formatRules) {
            if ([regex]::IsMatch($line, $r.Re)) { $fired += $r.Name }
        }

        foreach ($r in $labelRules) {
            $m = [regex]::Match($line, $r.Re)
            if ($m.Success) {
                $v = $m.Groups['v'].Value.Trim()
                if ($v.Length -ge 6 -and -not [regex]::IsMatch($v, $placeholderRe)) {
                    $fired += $r.Name
                }
            }
        }

        if ($fired.Count -gt 0) {
            $hits += [pscustomobject]@{
                File   = $rel
                Line   = $lineno
                Rules  = (($fired | Select-Object -Unique) -join ', ')
            }
        }
    }
}

if (-not $hits) {
    Write-Output 'CLEAN: no literal credential values detected in tracked text files.'
}
else {
    Write-Output ("FINDINGS: {0} line(s) across {1} file(s)" -f $hits.Count, ($hits | Group-Object File).Count)
    Write-Output ''
    $hits | Group-Object File | Sort-Object Name | ForEach-Object {
        Write-Output ("FILE: {0}" -f $_.Name)
        $_.Group | ForEach-Object { Write-Output ("    line {0,-5} [{1}]" -f $_.Line, $_.Rules) }
        Write-Output ''
    }
}
