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

# 2026-11-03: the invariant changed shape, so this check changed with it.
#
# Until this date the redactor minted a numeric mask and the mirror excluded it with
# `(?!0{4})`, tied to `MIN_LEADING_ZEROS`. That whole mechanism is gone: it leaked the
# value's length, letter layout and check character, drifted with allocation order, and
# collided two different USCCs onto one placeholder. Every class now renders as an
# opaque `[CODE_TAG]` token, which no raw-value pattern below can match.
#
# So the assertion is not "the guard matches a constant" any more - it is "there is no
# numeric mask left to guard". Asserting the ABSENCE is what stops the mechanism being
# reintroduced without this file being revisited; a positive check on the token format
# would pass even if both mechanisms came back.
Check 'no format-preserving numeric mask remains in the Rust source' `
    (-not ($phSrc -match 'fn format_preserving')) 'format_preserving() is back - the numeric mask was removed as a defect; if it is reintroduced deliberately, this audit must change too'
Check 'tokens are minted as [CODE_TAG]' `
    ($phSrc -match 'fn join_token\(code: &str, tag: &str\) -> String') 'the token join point changed; re-derive the patterns below'
Check 'the guard constant still excludes pre-0.2.17 placeholders' `
    ($patterns['cn_id_card'] -match '^\(\?!0\{4\}\)') 'historical chunk rows may still hold numeric masks; dropping the guard would report them as unfixable leaks'

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
    # Added 2026-11-03. Two of these were measured still plaintext in already-indexed
    # chunks of a live matter, so the audit failing to see them is how the leak stayed
    # in place through a remediation pass.
    'hk_id'          = '香港身份证'
    'sg_nric'        = '新加坡 NRIC'
    'my_id'          = '马来西亚身份证'
    'military_id'    = '军官证'
    'th_tax_id'      = '泰国 TaxID'
    'th_juristic'    = '泰国 Juristic ID'
}
foreach ($key in $mustHavePattern.Keys) {
    Check "a pattern exists for $($mustHavePattern[$key])" ($patterns.Contains($key)) "missing key: $key"
}

# ── 3. The sanitizer's own output must match NOTHING ──────────────────────────
#
# Two generations, deliberately:
#
#   * the CURRENT tokens, `[CODE_<hex>]`. These are what 0.2.17 mints, and the
#     assertion is that no raw-value pattern can match one. It is a weaker check than
#     it looks - a bracketed uppercase token could not match these patterns anyway -
#     and it is here so that a future pattern that loses its anchor is caught.
#   * the LEGACY numeric masks, from 0.2.16 and earlier. These must stay excluded from
#     the audit forever, because chunk rows minted by those versions are still in the
#     database on a live deployment and no remediation can rewrite a value it cannot
#     see. Index values include the ones that broke a width-specific guard: 10, 100,
#     1000.
function ConvertTo-DotNet([string]$p) { $p -replace '\[\[:space:\]\]', '\s' }

function Test-AnyPattern([string]$text) {
    $hits = @()
    foreach ($k in $patterns.Keys) {
        if ($text -match (ConvertTo-DotNet $patterns[$k])) { $hits += $k }
    }
    return $hits
}

$placeholders = @(
    '[CN_ID_2D8BF002A1C4E6F0]',        # current token
    '[USCC_0D0948B887EDD824]',
    '[BANK_CARD_53C82EF1C9807E78]',
    '[TH_JURISTIC_68B7B56AD411AC75]',
    '000000000000000010',             # legacy mask, index 1
    '000000000000000100',             # legacy mask, index 10 - the one that broke
    '000000000000001000',             # legacy mask, index 100
    '000000000000010000',             # legacy mask, index 1000
    '00000000X000000X20'              # legacy USCC-shaped mask
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
    # A country-coded mobile must be found without relying on Luhn, and a longer
    # foreign identifier that merely CONTAINS the digits must not be reported.
    '手机 +8613912345679'      = 'cn_mobile'
    # The overseas set (2026-11-03), including the two values measured still plaintext
    # in already-indexed chunks of a live matter.
    '香港身份证 A123456(7)'    = 'hk_id'
    '新加坡 NRIC S1234567D'    = 'sg_nric'
    '马来西亚身份证 900101-14-5567' = 'my_id'
    '军官证 军字第1234567号'   = 'military_id'
    'TaxID 3101401176368'      = 'th_tax_id'
    'Juristic ID No.0115565002108' = 'th_juristic'
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
    '参见 (2019)最高法民终1234号',
    # `Juristic ID No.0115565002108` USED to be listed here, as the fixture proving the
    # `(^|[^0-9])` mobile guard worked on foreign text. It is no longer ordinary text:
    # that exact value was measured still plaintext in an indexed chunk of a live
    # matter, so the audit must now REPORT it (see `$mustMatch`), not stay silent. The
    # mobile guard is still exercised by the pattern itself.
    #
    # A 12-digit run with a plausible date head must not be read as a 马来西亚身份证 -
    # the run-together form was dropped from both layers for this reason.
    #
    # Only the `020` head is asserted here, not `010`. `编号010123456789` is a 12-digit
    # run whose `010` head IS a real Beijing landline area code, so the landline pattern
    # legitimately matches it. The Rust layer rejects it because the area-code rule stops
    # after 8 subscriber digits and `is_bounded` sees a digit next; a single SQL regex has
    # no second step, which is a known and documented limit of this mirror (see SCOPE in
    # RawPiiPatterns.ps1). Asserting it here would encode a false expectation - the
    # Malaysian-identity-card guard is what `020` proves.
    '编号020123456789'
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

    # The audit must not count a match that sits INSIDE a token it minted.
    #
    # MEASURED 2026-11-03: plain `content ~ '<pattern>'` reported cn_landline 2 and
    # sg_nric 1 on clean documents, because those patterns matched hex payloads
    # inside [CN_ID_BF05012917050DF0] and [CN_MOBILE_C1F3732998EFA823]. Same class
    # as the Rust rescan's P0-2.
    #
    # The remediation reaches this through Get-PacgateRawPiiPredicate, so for THAT
    # script the shared predicate is the requirement. The audit carries the count
    # inline and must keep doing so: it also dot-sources the predicate file (for the
    # patterns), so a check that accepted either one passed even after the inline
    # exclusion was removed - measured, and that is why this branches by script
    # rather than accepting a disjunction.
    $expectation = if ($script -match 'remediate-sanitized') {
        $src -match 'Get-PacgateRawPiiPredicate'
    }
    else {
        $src -match 'strpos\(t\.tok\[1\], m\.tok\[1\]\)'
    }
    Check "$script excludes matches inside a minted token" $expectation `
        'no token exclusion: token payloads would be counted as leaks'
}
Write-Host ''
if ($failures -eq 0) {
    Write-Host "RESULT: the audit mirror agrees with the rule layer. ($($patterns.Count) patterns)" -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $failures drift(s) between the audit mirror and the rule layer." -ForegroundColor Red
exit 1
