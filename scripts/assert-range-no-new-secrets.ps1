# Scan a commit RANGE for credential shapes, separating ADDED from REMOVED.
#
# ADDED   (+) = a secret is entering history -> BLOCK
# REMOVED (-) = a secret is leaving history -> expected during redaction, OK
#
# Pins console/output encoding to UTF-8: PowerShell on a CJK Windows locale
# otherwise decodes git's UTF-8 as GBK, turning 密码 into mojibake and silently
# missing every CJK credential.
param(
    [Parameter(Mandatory = $true)][string]$Range
)

$prevConsole = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$prevOut = $OutputEncoding
$OutputEncoding = [System.Text.Encoding]::UTF8
try {
    $diff = git -c core.quotepath=false diff $Range -U0
}
finally {
    [Console]::OutputEncoding = $prevConsole
    $OutputEncoding = $prevOut
}

# Rules that indicate a REAL secret value follows.
$rules = [ordered]@{
    'cjk-密码'    = '密码\s*[：:]\s*(?:&#xA;)?(?<v>[^\s|`]+)'
    'cjk-登录名'  = '(?:统一)?登录名\s*[：:]\s*(?<v>[^\s|`]+)'
    'md-Password' = '\|\s*\*\*Password\*\*\s*\|\s*`(?<v>[^`]+)`'
    'md-Email'    = '\|\s*\*\*Email\*\*\s*\|\s*`(?<v>[^`]+)`'
    'known-keys'  = '(?<v>vq_key_[A-Za-z0-9_\\\-]{10,}|sk-[A-Za-z0-9_\-]{16,}|AKIA[0-9A-Z]{16})'
}

function Test-Line([string]$line) {
    foreach ($name in $rules.Keys) {
        foreach ($m in [regex]::Matches($line, $rules[$name])) {
            $v = $m.Groups['v'].Value.Trim()
            if ($v -match 'REDACTED') { continue }
            if ($v -match '^(待填写|待补|xxx|\*+|-+|□+)$') { continue }
            if ($v -match '^<.*>$') { continue }
            if ($v.Length -lt 5) { continue }
            return $name
        }
    }
    return $null
}

$currentFile = '(unknown)'
$added = @()
$removed = @()
$removedSuppressed = 0   # scanner regex definitions being added (benign)

$scannerFiles = @('detect-literal-credentials.ps1', 'redact-exposed-credentials.ps1',
                  'assert-no-staged-secrets.ps1', 'check-credential-state.ps1')

foreach ($line in ($diff -split "`r?`n")) {
    if ($line -match '^\+\+\+ b/(.+)$') { $currentFile = $Matches[1]; continue }
    if ($line -match '^--- a/(.+)$') { continue }

    if ($line.StartsWith('+')) {
        if ($scannerFiles -contains (Split-Path $currentFile -Leaf)) { continue }
        $r = Test-Line $line
        if ($r) { $added += [pscustomobject]@{ File = $currentFile; Rule = $r } }
    }
    elseif ($line.StartsWith('-')) {
        $r = Test-Line $line
        if ($r) { $removed += [pscustomobject]@{ File = $currentFile; Rule = $r } }
    }
}

Write-Output ("Range: {0}" -f $Range)
Write-Output ''
Write-Output ("ADDED credential values   : {0}" -f $added.Count)
Write-Output ("REMOVED credential values : {0}" -f $removed.Count)
Write-Output ''

if ($added.Count -gt 0) {
    Write-Output 'BLOCKING - these would ENTER history:'
    $added | Group-Object File | ForEach-Object {
        Write-Output ("  {0}" -f $_.Name)
        $_.Group | Select-Object -ExpandProperty Rule -Unique | ForEach-Object { Write-Output "      $_" }
    }
    exit 1
}

if ($removed.Count -gt 0) {
    Write-Output 'OK - credential values are being REMOVED (redaction):'
    $removed | Group-Object File | ForEach-Object {
        Write-Output ("  {0}  ({1} value(s))" -f $_.Name, $_.Count)
    }
}

Write-Output ''
Write-Output 'PASS: nothing credential-shaped is being added.'
exit 0
