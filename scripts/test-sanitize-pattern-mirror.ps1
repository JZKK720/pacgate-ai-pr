# Proves the SQL audit's detection patterns still agree with the Rust rule layer.
#
# WHY THIS EXISTS
#
# `scripts/lib/RawPiiPatterns.ps1` is a HAND-WRITTEN mirror of
# `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`. It exists because the audit
# that finds raw identifiers in `sanitized` chunks runs as SQL, where the Rust rule
# layer cannot reach. A mirror is a second source of truth, and this repo has now paid
# for that three times:
#
#   2026-10-15  the audit learned to exclude the redactor's placeholder and the
#               remediation did not, so the remediation "fixed" 39 clean documents.
#   2026-10-25  the exclusion was written `(?!0{17})`, which never matched the
#               placeholder it was meant to exclude - 37 false leaks per pattern.
#   2026-11-02  the placeholder format changed and the now-correct `(?!0{16})` guard
#               stopped excluding it again from index 10 onward.
#
# Each time, the audit was wrong in the dangerous direction (reporting clean machines
# as dirty) or the useless direction (reporting dirty machines as clean). A comment
# asking two copies to stay in step is not a mechanism. This is.
#
# WHAT IT ASSERTS (no database, no docker - runs anywhere)
#
#   1. Every entity class the rule layer calls Tier-1-or-below has an audit pattern,
#      except the ones that are rendered opaque and provably cannot appear raw.
#   2. The placeholder guard is the SAME expression the Rust constant promises.
#   3. The sanitizer's own output matches NO pattern - at index values past the ones a
#      small test would happen to reach, which is where it broke last time.
#   4. Real identifiers still match, and ordinary contract text does not.
#
# Regex dialect note: these are Postgres POSIX ERE, which .NET does NOT implement
# identically. `(?!...)` is in both; `[[:space:]]` is POSIX-only, so it is translated
# for the local check below. A pattern using a POSIX class the translation misses would
# fail case 4 and be caught here rather than in production.
#
# Exit 0 = consistent, 1 = drift found.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$failures = 0
function Check($label, [bool]$ok, $detail) {
    if ($ok) {
        Write-Host "  PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $label" -ForegroundColor Red
        if ($detail) { Write-Host "        $detail" }
        $script:failures++
    }
}

Write-Host '=== audit pattern mirror: drift proof ===' -ForegroundColor Cyan

. (Join-Path $PSScriptRoot 'lib/RawPiiPatterns.ps1')
$patterns = $PacgateRawPiiPatterns

# ── 1. The Rust-side constants this mirror depends on ────────────────────────
$rulesPath = 'pacgate-ai/crates/pacgate-redact/src/detect/rules.rs'
$phPath = 'pacgate-ai/crates/pacgate-redact/src/placeholder.rs'
Check 'the rule-layer source exists' (Test-Path $rulesPath) $rulesPath
Check 'the placeholder source exists' (Test-Path $phPath) $phPath

$phSrc = Get-Content $phPath -Raw
# MIN_LEADING_ZEROS must be the number the SQL guard encodes.
$m = [regex]::Match($phSrc, 'pub const MIN_LEADING_ZEROS: usize = (\d+);')
Check 'MIN_LEADING_ZEROS is declared in the Rust source' $m.Success 'the constant was renamed or removed'
$minZeros = if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }

$guardExpr = [regex]::Match($patterns['cn_id_card'], '^\(\?!0\{(\d+)\}\)')
Check 'the id-card pattern starts with a placeholder guard' $guardExpr.Success `
    "cn_id_card = $($patterns['cn_id_card'])"
if ($guardExpr.Success -and $minZeros -gt 0) {
    $sqlZeros = [int]$guardExpr.Groups[1].Value
    Check 'the SQL guard is at least as strict as the Rust invariant' ($sqlZeros -le $minZeros) `
        "SQL excludes {0} leading zeros, Rust guarantees {1}" -f $sqlZeros, $minZeros
}

# ── 2. Every rule class with a nameable raw shape has a pattern ───────────────
#
# The eight classes a client scan found verbatim on 2026-11-02, minus the ones the
# redactor renders as an opaque `[CODE_index]` token: an opaque placeholder is
# bracketed and cannot match a raw-value pattern, so a pattern for those would be
# dead code that looks like coverage.
$mustHavePattern = [ordered]@{
    'cn_id_card'     = '身份证号'
    'uscc'           = '统一社会信用代码'
    'lawyer_license' = '律师执业证号'
    'bank_account'   = '银行账号'
    'cn_plate'       = '车牌'
    'cn_tax_id'      = '纳税人识别号'
}
foreach ($key in $mustHavePattern.Keys) {
    Check "a pattern exists for $($mustHavePattern[$key])" ($patterns.Contains($key)) "missing key: $key"
}

# ── 3. The sanitizer's own output must match NOTHING ──────────────────────────
#
# Index values chosen to include the ones that broke a width-specific guard:
# 10, 100, 1000. A `0{16}` guard passes 1..9 and fails at 10, which is exactly how
# the 2026-11-02 drift got past every hand test.
function ConvertTo-DotNet([string]$p) { $p -replace '\[\[:space:\]\]', '\s' }

function Test-AnyPattern([string]$text) {
    $hits = @()
    foreach ($k in $patterns.Keys) {
        if ($text -match (ConvertTo-DotNet $patterns[$k])) { $hits += $k }
    }
    return $hits
}

$placeholders = @(
    '000000000000000010',   # index 1, 16 leading zeros
    '000000000000000100',   # index 10, 15 leading zeros - the one that broke
    '000000000000001000',   # index 100
    '000000000000010000',   # index 1000
    '00000000X000000X20'    # a USCC shape with letters
)
foreach ($ph in $placeholders) {
    $hits = Test-AnyPattern $ph
    Check "the redactor's own output '$ph' is not reported as a leak" ($hits.Count -eq 0) `
        ("matched: " + ($hits -join ', '))
}

# ── 4. Real identifiers still match; ordinary contract text does not ──────────
$mustMatch = [ordered]@{
    '110105199003074512'      = 'cn_id_card'      # the client case: bad check digit
    '11010519491231002X'      = 'cn_id_card'      # checksum-valid
    '91350100M000100Y43'      = 'uscc'
    '律师执业证号 11101201810123456' = 'lawyer_license'
    '账号：6222020200112345678'      = 'bank_account'
    '抵押车辆 粤B12345'        = 'cn_plate'
    # A lower-case plate is the same plate. Both the rule layer and this audit
    # missed it until 2026-11-02, when an adversarial probe compared the two.
    '抵押车辆 京a12345'        = 'cn_plate'
}
foreach ($value in $mustMatch.Keys) {
    $hits = Test-AnyPattern $value
    Check "'$value' is still detected" ($hits -contains $mustMatch[$value]) `
        ("expected {0}, matched: {1}" -f $mustMatch[$value], ($hits -join ','))
}

$mustNotMatch = @(
    '借款金额 1,250,000.00 元',
    '年利率 4.35%',
    '期限 2026-01-01 至 2028-12-31',
    'Contract No.PG-2026-0042',
    'Invoice Total USD 18,400.00',
    '参见 (2019)最高法民终1234号'
)
foreach ($text in $mustNotMatch) {
    $hits = Test-AnyPattern $text
    Check "ordinary contract text '$text' is not a match" ($hits.Count -eq 0) `
        ("matched: " + ($hits -join ', '))
}

# ── 5. Both consumers read the shared file, not a local copy ──────────────────
foreach ($script in @('scripts/audit-sanitized-chunk-egress.ps1',
                      'scripts/remediate-sanitized-chunk-egress.ps1')) {
    $src = Get-Content $script -Raw
    Check "$script dot-sources the shared pattern file" `
        ($src -match 'lib[/\\]RawPiiPatterns\.ps1') 'a local copy can drift'

    # A literal guard in EXECUTABLE code means the value was duplicated again.
    # Comment lines are stripped first: these files record the history of this very
    # bug (`(?!0{17})`, `(?!0{16})`) and a check that cannot tell prose from code
    # would forbid documenting the defect it exists to prevent.
    $code = ($src -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Check "$script carries no inline placeholder guard in code" `
        (-not ($code -match '\(\?!0\{\d+\}\)')) 'inline `(?!0{N})` found in code - use the shared pattern'
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host "RESULT: the audit mirror agrees with the rule layer. ($($patterns.Count) patterns)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failures drift(s) between the audit mirror and the rule layer." -ForegroundColor Red
exit 1
