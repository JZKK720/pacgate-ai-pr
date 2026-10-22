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
    @{ Name = 'sep-cjk-password'; Re = '(\u5BC6\u7801\s*[\uFF1A:]\s*(?:&#xA;)?)([^\s|]+)' }
    @{ Name = 'sep-cjk-login';    Re = '((?:\u7EDF\u4E00)?\u767B\u5F55\u540D\s*[\uFF1A:]\s*(?:&#xA;)?)([^\s|]+)' }
    @{ Name = 'sep-cjk-account';  Re = '(\u8D26\u53F7\s*[\uFF1A:]\s*(?:&#xA;)?)([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+|\d{8,})' }
    @{ Name = 'api-backtick'; Re = '(API\s*:\s*`)([^`]+)(`)' }
    # Bare (non-backticked) API keys. The charset includes backslash because
    # markdown escapes appear inside these values in practice, e.g. vq\_key\_...
    @{ Name = 'api-bare';      Re = '(API\s*:\s*)([A-Za-z0-9_\\\-]{16,})' }
    @{ Name = 'api-longtoken'; Re = '(API\s*:\s*)([A-Za-z0-9_\\\-]{32,})' }
    @{ Name = 'table-Password'; Re = '(\|\s*\*\*Password\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
    @{ Name = 'table-Email';    Re = '(\|\s*\*\*Email\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
    @{ Name = 'table-GitHubID'; Re = '(\|\s*\*\*GitHub ID\*\*\s*\|\s*`)([^`]+)(`\s*\|)' }
    # --- Plain (non-bold) field names, and unlabeled credential columns. ---
    # The three rules above require `**bold**` field names. A credential table that
    # declares its columns in a HEADER row and then lists bare values per row has
    # neither the bold label NOR any label on the value's own line, so all three miss.
    # MEASURED 2026-10-15: deploy/BENCHMARK-REPORT-2026-10-08.md used exactly that
    # layout and carried a LIVE pacgate-api password; none of the bold rules fired.
    @{ Name = 'table-PasswordPlain'; Re = '(\|\s*(?:\*\*)?\s*[Pp]assword\s*(?:\*\*)?\s*\|\s*`)([^`]+)(`\s*\|)' }
    # Emails are NOT redacted here. They are account identifiers, not secrets, and
    # admin@pacgate-law.com is already published across the handover docs and
    # .env.example by design. Redacting it in one report while the handover prints it
    # would just make the report harder to use. The bold table-Email rule above is
    # kept for the assets docs, where the pairing was a pasted credential block.
    # Last resort: a code-spanned token in its own table cell with no label. Runs last
    # so labelled cells keep their more descriptive rule. Scoped by the explicit target
    # list below, since on an arbitrary table this would redact any 24-40 char value.
    @{ Name = 'table-bare-token'; Re = '(\|\s*`)([A-Za-z0-9]{24,40})(`\s*\|)' }
)

$targets = @(
    'deploy/BENCHMARK-REPORT-2026-10-08.md'
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md'
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/\u667A\u5E93\u8D44\u6599\u6536\u96C6/\u667A\u5E93\u8D44\u6599\u6536\u96C6/MCP\u6388\u6743/\u6CD5\u5F8B\u6570\u636E\u5E93MCP.md'
    'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/\u667A\u5E93\u8D44\u6599\u6536\u96C6/\u667A\u5E93\u8D44\u6599\u6536\u96C6/MCP\u6388\u6743/\u5883\u5916\u6CD5\u5F8B\u6570\u636E\u5E93\u548C\u7F51\u7AD9.md'
)
# Path targets above may contain \uXXXX escapes: single-quoted strings do NOT expand
# them, so they are resolved through the regex-free escape expansion below before use.
$targets = $targets | ForEach-Object { [regex]::Unescape($_) }

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
