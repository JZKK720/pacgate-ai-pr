# The single source of truth for "raw PII inside a kb_chunks row".
#
# WHY THIS FILE EXISTS
#
# These patterns were duplicated in `audit-sanitized-chunk-egress.ps1` (which COUNTS
# and NAMES the affected rows) and `remediate-sanitized-chunk-egress.ps1` (which
# repairs them). The remediation script even carried a comment saying the two "must be
# kept in step" - and then they were not.
#
# MEASURED 2026-10-15: the audit was fixed to stop matching the redactor's own
# format-preserving placeholder, and the remediation was not. Re-running the
# remediation on an already-clean machine therefore selected 39 documents and reported
# "raw 0 -> 0, chunks kept=1" for every one - a no-op disguised as work. The closing
# audit then disagreed with it, exactly as it had when the audit itself was wrong.
#
# A comment asking two copies to stay in step is not a mechanism. This is.
#
# WHY THE GUARD IS `(?!0{4})` AND NOT A WIDTH-SPECIFIC COUNT
#
# The redactor renders a format-preserved value by zeroing its middle and stamping
# a per-job index into it, e.g. `000000000000000010`. That value is a legitimate
# member of BOTH character classes below, so without a guard each pattern flags the
# sanitizer's own output as a leak.
#
# MEASURED 2026-10-25: the guard was written `(?!0{17})`, which requires SEVENTEEN
# leading zeros and therefore never matched the placeholder it was meant to exclude.
# `'000000000000000026' ~ '(?!0{17})[0-9]{17}[0-9Xx]'` returned true and the audit
# reported the redactor's own output as a leak - 37 false "leaks" per pattern on a
# machine with zero real ones. It was then fixed to `0{16}`, which was correct for
# the placeholder format of that day and stopped being correct on 2026-11-02.
#
# MEASURED 2026-11-02: stamping a decimal index from the right eats one leading zero
# per digit, so index 10 produced `000000000000000100` - fifteen leading zeros - and a
# `0{16}` guard stopped excluding it. The count was never the right invariant.
#
# The invariant now comes FROM THE RUST CODE: `pacgate_redact::placeholder::
# MIN_LEADING_ZEROS` is the number of zeros every format-preserving placeholder is
# guaranteed to keep, and a Rust test (`every_format_preserving_placeholder_keeps_the
# _audit_guard_satisfiable`) proves it holds at arbitrary index values and at every
# format-preserved width. If you change the placeholder format, change that constant
# and this guard follows - because it is below.
#
# A real Chinese ID card or USCC begins with at most a handful of zeros, never four
# in a row after a province code, so `0{4}` excludes the placeholder and nothing else.
$PacgatePlaceholderZeroGuard = '(?!0{4})'

$PacgateRawPiiPatterns = [ordered]@{
    # An email address. Safe as-is: the redactor's placeholder for one is a bracketed
    # token like [EMAIL_...], which cannot match.
    'email'         = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

    # A PRC resident ID card: 17 digits then a check character.
    #
    # The redactor also emits a placeholder in this class when the value has the ID
    # SHAPE but a bad check digit (a mistyped or OCR-damaged number, which is still
    # personal data - see `cn_resident_id_shape_ok`). Such a value is format-preserved,
    # so the guard above is what keeps it out of this audit.
    'cn_id_card'    = "$PacgatePlaceholderZeroGuard[0-9]{17}[0-9Xx]"

    # A Unified Social Credit Code: 18 characters from a restricted alphabet.
    'uscc'          = "$PacgatePlaceholderZeroGuard[0-9A-HJ-NPQRTUWXY]{18}"

    # A PRC mobile number.
    'cn_mobile'     = '1[3-9][0-9]{9}'

    # A PRC landline with an area code, hyphen optional.
    'cn_landline'   = '0(10|2[1-9]|[3-9][0-9]{2})-?[0-9]{7,8}'

    # ── Added 2026-11-02, mirroring the rule-layer classes that were missing ──
    #
    # These were the classes a client scan found verbatim inside text carrying the
    # `sanitized` label: 律师执业证号, 银行账号, 车牌, 纳税人识别号 (and 港澳通行证,
    # 微信号, which are rendered as opaque `[CODE_...]` placeholders and therefore
    # cannot match a raw-value pattern at all - they need no entry here).

    # 律师执业证号: 17 digits with no checksum, so the RULE needs its label - but this
    # audit is looking for a raw value that escaped, and an escaped licence number has
    # no label next to it any more. A 17-digit run is distinctive enough on its own.
    #
    # `(号码?)?`, not `(?:号码)?`. The latter binds 号 and 码 into one optional unit, so
    # it matches "号码" or nothing - never the far more common "号" alone. Measured
    # 2026-11-02: with `(?:号码)?` this pattern did NOT match `律师执业证号 1110...`,
    # so the audit stayed silent on a real 17-digit licence. The Rust label regex has
    # the same shape but survives it by searching unanchored for the digits after the
    # label; a single SQL regex has no second step to fall back on.
    'lawyer_license' = '律师执业证(号码?)?[:：]?[[:space:]]*[0-9]{17}'

    # 银行账号: a digit run of 8-32 with optional grouping separators. Anchored on the
    # account label, because a bare digit run of that length is an amount or an order
    # number. The separators are spelled out as a character class rather than `\s`,
    # which in Postgres ERE would also match newlines and let a match span two lines.
    #
    # The placeholder guard is repeated HERE, unlike the id/uscc patterns which carry
    # it once at the front, because this pattern is anchored on a LABEL that the
    # placeholder preserves: `账号：0000000000000000050` still reads as an account and
    # its digits match the run. Measured 2026-11-02 - without the guard the rescan
    # reported a clean document as dirty on every run.
    'bank_account'  = "(账号|帐号|账户|帐户)(号码)?[:：]?[[:space:]]*$PacgatePlaceholderZeroGuard[0-9][0-9 -]{6,40}[0-9]"

    # 车牌: province ideograph + authority letter + 5-6 characters. The province set is
    # closed, which is why the audit can look for a bare plate without a label.
    'cn_plate'      = '[京津冀晋蒙辽吉黑沪苏浙皖闽赣鲁豫鄂湘粤桂琼渝川贵云藏陕甘青宁新][A-Z][A-Z0-9]{5,6}'

    # 纳税人识别号: the label plus a 15-20 character code (an old tax code or a USCC).
    'cn_tax_id'     = '纳税人识别号(码)?[:：]?[[:space:]]*[0-9A-Z]{15,20}'
}

# SCOPE, STATED HONESTLY
#
# These are Tier-1 rules expressible in SQL. They are a LOWER BOUND on exposure: the
# NER-tier identifiers the product actually detects (names, addresses, org names) cannot
# be found by a SQL regex, so a clean result here is NOT a proof of no leakage. The
# product's own detector set is the authority; this is a cheap independent check.
#
# The values are SQL regular expressions (POSIX ERE as Postgres implements it), not
# .NET regexes - they are interpolated straight into a `~` operator. Keep the two
# dialects' differences in mind if you edit them: no backreferences, no lookbehind.

# Convenience: a SQL fragment testing `$Column` against every pattern, OR-ed.
# Used by both callers so neither can add a pattern and forget the other.
function Get-PacgateRawPiiPredicate {
    param([string]$Column = 'c.content')

    $parts = @()
    foreach ($name in $PacgateRawPiiPatterns.Keys) {
        $parts += "$Column ~ '$($PacgateRawPiiPatterns[$name])'"
    }
    return ($parts -join ' OR ')
}
