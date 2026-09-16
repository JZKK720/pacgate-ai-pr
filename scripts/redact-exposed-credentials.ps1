# Redact literal credentials from tracked business/asset markdown files.
#
# WHY: these files are tracked in PUBLIC repos. Redacting the working tree stops
# FURTHER exposure from new clones of HEAD. It does NOT undo the exposure that
# already happened - these values must be ROTATED, and purged from history.
#
# The script never prints a secret value: it reports only file + line + rule.
#
# Structure preserved: markdown table pipes are left intact so the tables still
# render. Use -Preview to report which lines would change without writing.
[CmdletBinding()]
param(
    # Preview only - report the lines that would change without writing.
    [switch]$Preview
)

$Marker = '[REDACTED-ROTATE-AND-SEE-GIT-HISTORY]'

# Rule set. Each rule is applied to a line; the value side of a credential
# separator is replaced, the label is kept.
$rules = @(
    @{ Name = 'sep-密码';   Re = '(密码\s*[：:]\s*(?:&#xA;)?)([^\s|]+)' }
    @{ Name = 'sep-登录名'; Re = '((?:统一)?登录名\s*[：:]\s*(?:&#xA;)?)([^\s|]+)' }
    @{ Name = 'sep-账号';   Re = '(账号\s*[：:]\s*(?:&#xA;)?)([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+|\d{8,})' }
    @{ Name = 'api-backtick'; Re = '(API\s*:\s*`)([^`]+)(`)' }
    # Bare (non-backticked) API keys. The charset includes backslash because
    # markdown escapes appear inside these values in practice, e.g. vq\_key\_...
    @{ Name = 'api-bare';      Re = '(API\s*:\s*)([A-Za-z0-9_\\\-]{16,})' }
    @{ Name = 'api-longtoken'; Re = '(API\s*:\s*)([A-Za-z0-9_\\\-]{32,})' }
    @{ Name = 'table-Password'; Re = '(\|\s*\*\*Password\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
    @{ Name = 'table-Email';    Re = '(\|\s*\*\*Email\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
    @{ Name = 'table-GitHubID'; Re = '(\|\s*\*\*GitHub ID\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
)

$targets = @(
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md'
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/法律数据库MCP.md'
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/境外法律数据库和网站.md'
)

$totalChanges = 0

foreach ($rel in $targets) {
    if (-not (Test-Path -LiteralPath $rel)) {
        Write-Output "SKIP (missing): $rel"
        continue
    }

    $path = (Resolve-Path -LiteralPath $rel).Path
    $original = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $lines = $original -split "`r?`n"
    $changed = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $before = $line

        foreach ($rule in $rules) {
            if ($rule.Name -like 'table-*') {
                # group 1 = prefix, 2 = secret, 3 = suffix
                $line = [regex]::Replace($line, $rule.Re, {
                    param($m)
                    $m.Groups[1].Value + $Marker + $m.Groups[3].Value
                })
            }
            elseif ($rule.Name -like 'api-longtoken' -or $rule.Name -like 'api-bare') {
                # group 1 = API label, 2 = secret; no suffix group
                $line = [regex]::Replace($line, $rule.Re, {
                    param($m)
                    $m.Groups[1].Value + $Marker
                })
            }
            else {
                # group 1 = label separator, 2 = secret
                $line = [regex]::Replace($line, $rule.Re, {
                    param($m)
                    $m.Groups[1].Value + $Marker
                })
            }
        }

        if ($line -ne $before) {
            $lines[$i] = $line
            # Report which rules fired, not the values.
            $fired = ($rules | Where-Object { [regex]::IsMatch($before, $_.Re) } | ForEach-Object { $_.Name }) -join ', '
            $changed += "    line $($i + 1): [$fired]"
            $script:totalChanges++
        }
    }

    Write-Output "FILE: $rel"
    if ($changed.Count -eq 0) {
        Write-Output '    (no credential-shaped values found)'
    }
    else {
        $changed | ForEach-Object { Write-Output $_ }

        if ($Preview) {
            Write-Output '    -- Preview: not written --'
        }
        else {
            $joined = $lines -join "`r`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($path, $joined, $utf8NoBom)
            Write-Output "    WRITTEN ($($changed.Count) line(s) redacted)"
        }
    }
    Write-Output ''
}

Write-Output "Total credential-bearing lines: $totalChanges"
if ($Preview) { Write-Output 'MODE: Preview (nothing written)' }
