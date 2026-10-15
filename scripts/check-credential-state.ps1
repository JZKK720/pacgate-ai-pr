# Authoritative credential-state check across local / fork / origin.
#
# Uses BOTH prose rules (CJK password / login / API) AND markdown-table rules
# (| **Password** | `...` |), because a rule set missing either one produces
# false negatives - which is exactly how this exposure was missed twice.
#
# Reports presence counts only. Never prints a value.
$files = [ordered]@{
    'BENCH-2026-10-08.md'  = 'deploy/BENCHMARK-REPORT-2026-10-08.md'
    'OPERATOR.md'          = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md'
    'legal-DB-MCP.md'      = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/\u667A\u5E93\u8D44\u6599\u6536\u96C6/\u667A\u5E93\u8D44\u6599\u6536\u96C6/MCP\u6388\u6743/\u6CD5\u5F8B\u6570\u636E\u5E93MCP.md'
    'overseas-legal-DBs.md' = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/\u667A\u5E93\u8D44\u6599\u6536\u96C6/\u667A\u5E93\u8D44\u6599\u6536\u96C6/MCP\u6388\u6743/\u5883\u5916\u6CD5\u5F8B\u6570\u636E\u5E93\u548C\u7F51\u7AD9.md'
}

# Paths use \uXXXX escapes because single-quoted strings do not expand them and this
# file must stay ASCII-only for PowerShell 5.1 (see DEFECT-ps51-cjk-literal-parse-failure).
foreach ($k in @($files.Keys)) { $files[$k] = [regex]::Unescape($files[$k]) }

$rules = @(
    '\u5BC6\u7801\s*[\uFF1A:]\s*(?:&#xA;)?(?<v>[^\s|`]+)'
    '(?:\u7EDF\u4E00)?\u767B\u5F55\u540D\s*[\uFF1A:]\s*(?<v>[^\s|`]+)'
    'API\s*:\s*`?(?<v>[A-Za-z0-9_\\\-]{16,})'
    # Field name may or may not be bold. Requiring `**` is the exact blind spot that
    # let a live pacgate-api password sit in a public repo undetected - see the long
    # note in detect-literal-credentials.ps1. Shape-agnostic, deliberately.
    '\|\s*(?:\*\*)?\s*[Pp]assword\s*(?:\*\*)?\s*\|\s*`(?<v>[^`]+)`'
    # md-Email was removed 2026-10-15. A bare address is an identifier, not a secret:
    # admin@pacgate-law.com is published by design in deploy/client-bundle/.env.example.
    # Counting it as "LIVE" made the report read "LIVE x2" on a fully redacted tree,
    # which understates nothing but obscures the one number that matters.
    '\|\s*\*\*GitHub ID\*\*\s*\|\s*`(?<v>[^`]+)`'
    # Unlabeled credential cell (value-only row under a header-declared table).
    '\|\s*`(?<v>[A-Za-z0-9]{24,40})`\s*\|'
)

function Get-LiveCount([string]$text) {
    $live = 0
    foreach ($re in $rules) {
        foreach ($m in [regex]::Matches($text, $re)) {
            $v = $m.Groups['v'].Value.Trim()
            if ($v -match 'REDACTED') { continue }
            if ($v -match '^(\u5F85\u586B\u5199|\u5F85\u8865|xxx|\*+|-+|\u25A1+)$') { continue }
            if ($v.Length -lt 5) { continue }
            $live++
        }
    }
    return $live
}

function Format-Cell([int]$n) {
    if ($n -lt 0) { return 'missing' }
    if ($n -eq 0) { return 'clean' }
    return "LIVE x$n"
}

Write-Output ("{0,-22} {1,-14} {2,-18} {3}" -f 'FILE', 'LOCAL', 'FORK (pacgate-ai)', 'ORIGIN (JZKK720)')
Write-Output ("{0,-22} {1,-14} {2,-18} {3}" -f ('-' * 22), ('-' * 14), ('-' * 18), ('-' * 30))

foreach ($fname in $files.Keys) {
    $rel = $files[$fname]

    $local = if (Test-Path -LiteralPath $rel) { Get-LiveCount (Get-Content -LiteralPath $rel -Raw) } else { -1 }

    $fork = -1
    $origin = -1
    foreach ($pair in @(@('FORK', 'fork/main'), @('ORIGIN', 'origin/main'))) {
        $tmp = Join-Path $env:TEMP '_chk_cred.md'
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        git show "$($pair[1]):$rel" > $tmp 2>$null
        if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
            $n = Get-LiveCount (Get-Content $tmp -Raw)
            if ($pair[0] -eq 'FORK') { $fork = $n } else { $origin = $n }
        }
    }

    Write-Output ("{0,-22} {1,-14} {2,-18} {3}" -f $fname, (Format-Cell $local), (Format-Cell $fork), (Format-Cell $origin))
}

Write-Output ''
Write-Output 'Values are never printed. "LIVE xN" = N real credential strings still present.'
