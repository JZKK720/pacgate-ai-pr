# Authoritative credential-state check across local / fork / origin.
#
# Uses BOTH prose rules (密码 / 登录名 / API) AND markdown-table rules
# (| **Password** | `...` |), because a rule set missing either one produces
# false negatives - which is exactly how this exposure was missed twice.
#
# Reports presence counts only. Never prints a value.
$files = [ordered]@{
    'OPERATOR.md'          = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md'
    'legal-DB-MCP.md'      = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/法律数据库MCP.md'
    'overseas-legal-DBs.md' = 'pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/境外法律数据库和网站.md'
}

$rules = @(
    '密码\s*[：:]\s*(?:&#xA;)?(?<v>[^\s|`]+)'
    '(?:统一)?登录名\s*[：:]\s*(?<v>[^\s|`]+)'
    'API\s*:\s*`?(?<v>[A-Za-z0-9_\\\-]{16,})'
    '\|\s*\*\*Password\*\*\s*\|\s*`(?<v>[^`]+)`'
    '\|\s*\*\*Email\*\*\s*\|\s*`(?<v>[^`]+)`'
    '\|\s*\*\*GitHub ID\*\*\s*\|\s*`(?<v>[^`]+)`'
)

function Get-LiveCount([string]$text) {
    $live = 0
    foreach ($re in $rules) {
        foreach ($m in [regex]::Matches($text, $re)) {
            $v = $m.Groups['v'].Value.Trim()
            if ($v -match 'REDACTED') { continue }
            if ($v -match '^(待填写|待补|xxx|\*+|-+|□+)$') { continue }
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
    foreach ($pair in @(@('FORK', 'forkheads/main'), @('ORIGIN', 'origin/main'))) {
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
