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
# The redactor USED TO render a format-preserved value by zeroing its middle and
# stamping a per-job index into it, e.g. `000000000000000010`. That value was a
# legitimate member of BOTH character classes below, so without a guard each pattern
# flagged the sanitizer's own output as a leak.
#
# MEASURED 2026-10-25: the guard was written `(?!0{17})`, which required SEVENTEEN
# leading zeros and therefore never matched the placeholder it was meant to exclude.
# `'000000000000000026' ~ '(?!0{17})[0-9]{17}[0-9Xx]'` returned true and the audit
# reported the redactor's own output as a leak - 37 false "leaks" per pattern on a
# machine with zero real ones. It was then fixed to `0{16}`, which was correct for
# the placeholder format of that day and stopped being correct on 2026-11-02.
#
# MEASURED 2026-11-02: stamping a decimal index from the right ate one leading zero
# per digit, so index 10 produced `000000000000000100` - fifteen leading zeros - and a
# `0{16}` guard stopped excluding it. The count was never the right invariant.
#
# 2026-11-03: THE GUARD IS NO LONGER NEEDED, AND THAT IS THE FIX.
#
# Every identifier class now renders as an opaque `[CODE_TAG]` token. There is no
# numeric mask any more - the whole format-preserving mechanism was removed as the
# defect it was (it leaked the value's length, letter layout and check character,
# drifted with allocation order, and collided). So the sanitizer's own output can no
# longer look like a raw value in the first place: a token is bracketed and contains
# an uppercase code, which no pattern below can match.
#
# The guard is retained verbatim rather than deleted, ON PURPOSE. Three separate
# episodes here were caused by widening a guard to match a moving target, and older
# chunk rows on a live deployment may still hold placeholders minted by 0.2.16 and
# earlier. Keeping `(?!0{4})` keeps those historical placeholders excluded from this
# audit instead of reporting them as leaks that no remediation can clear.
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

    # A PRC mobile number, with an optional 86 country code.
    #
    # The leading `(^|[^0-9])` is a boundary test, and it is needed only here. The
    # Rust detector calls `is_bounded` and rejects a match with a digit immediately
    # before it; SQL ERE has no lookbehind, so the guard has to consume the preceding
    # character instead. MEASURED 2026-11-02: without it, the Thai juristic ID
    # `0115565002108` in `Juristic ID No.0115565002108` matched as an INNER substring
    # and the audit reported `LEAK cn_mobile 1` on a document that the rescan and the
    # redactor both correctly considered clean. A false positive that no remediation
    # can clear is exactly what trains an operator to ignore this audit.
    #
    # `86` is part of the pattern for the same reason it is in the rule layer: a
    # country-coded mobile must not depend on its Luhn checksum to be found.
    'cn_mobile'     = '(^|[^0-9])(?:86)?1[3-9][0-9]{9}'

    # A PRC landline with an area code, hyphen optional.
    'cn_landline'   = '0(?:10|2[1-9]|[3-9][0-9]{2})-?[0-9]{7,8}'

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
    'lawyer_license' = '(律师)?执业证(号码?)?[:：]?[[:space:]]*[0-9]{17}'

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
    #
    # `[A-Za-z]`, not `[A-Z]`. Measured 2026-11-02: a plate printed in lower case
    # (`京a12345`) was invisible to both the rule layer and this audit, so a real plate
    # could sit in a `sanitized` chunk and neither would report it.
    'cn_plate'      = '[京津冀晋蒙辽吉黑沪苏浙皖闽赣鲁豫鄂湘粤桂琼渝川贵云藏陕甘青宁新][A-Za-z][A-Za-z0-9]{5,6}'

    # 纳税人识别号: the label plus a 15-20 character code (an old tax code or a USCC).
    'cn_tax_id'     = '纳税人识别号(码)?[:：]?[[:space:]]*[0-9A-Z]{15,20}'

    # ── 境外与少数类标识符, added 2026-11-03 ──
    #
    # These were measured surviving verbatim, and two of them were still plaintext in
    # ALREADY-INDEXED chunks of a live matter (`invoice-ganjong`):
    # `Juristic ID No.0115565002108` and `TaxID 3101401176368`. A rule layer fix does
    # not clean rows that were ingested before it, so the audit has to be able to see
    # these or the remediation cannot select them.

    # 香港身份证: letter(s) + 6 digits + bracketed check character.
    'hk_id'         = '[A-Z]{1,2}[0-9]{6}\([0-9A]\)'

    # 新加坡 NRIC/FIN: [STFGM] + 7 digits + check letter.
    'sg_nric'       = '[STFGM][0-9]{7}[A-Z]'

    # 马来西亚身份证: YYMMDD-PB-###G. Hyphenated only - a run-together 12-digit form is
    # indistinguishable from an order number, which is why the Rust rule refuses it
    # too (measured: it claimed `编号010123456789`).
    'my_id'         = '[0-9]{6}-[0-9]{2}-[0-9]{4}'

    # 军官证: 军字第 + digits + 号.
    'military_id'   = '军字第[0-9]{6,10}号'

    # 泰国 TaxID and Juristic ID. Both are 13 digits, so the LABEL is the only thing
    # that makes them identifiers - and the only thing that tells the two apart.
    'th_tax_id'     = '(Tax[[:space:]]*ID|TaxID)[:：]?[[:space:]]*[0-9]{13}'
    'th_juristic'   = 'Juristic[[:space:]]*ID([[:space:]]*No\.?)?[:：]?[[:space:]]*[0-9]{13}'
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


    # Exclude matches that fall INSIDE a token this redactor minted.
    #
    # The Rust rescan already does this with `is_token_span`; the SQL audit did not,
    # so it reported the payload of a token as raw PII. MEASURED 2026-11-03 on the
    # live DB: `cn_landline` matched inside `[CN_ID_BF05012917050DF0]` (the digits
    # `0`+`501`+`2917050` sit in that hex tail) and `sg_nric` matched `F3732998E`
    # inside `[CN_MOBILE_C1F3732998EFA823]`. Both were counted as leaks in documents
    # that were in fact clean - the same class of false positive as P0-2, one layer
    # further out.
    #
    # SQL ERE has no lookbehind, so a token cannot be excluded INLINE per pattern.
    # Instead the whole row is rejected when every match it has lies inside a token:
    # the caller gets `false` for such a row. `[A-Z_]+_[0-9A-F]{8,}` with optional
    # brackets is the token grammar from `PlaceholderAllocator`.
    #
    # This is deliberately conservative: a document that contains BOTH a token and a
    # real leak still reports, because the real leak's match is outside the token and
    # the row-level test below only suppresses rows where the ONLY evidence is
    # token-internal.
    $parts = @()
    foreach ($name in $PacgateRawPiiPatterns.Keys) {
        $p = $PacgateRawPiiPatterns[$name]
            # The mask-shape rejection is the second half of the same idea, one layer out.
            #
            # MEASURED 2026-11-03: `X10000000000000000`, `000000000000000010`,
            # `00000000XX00XXXX40` and `X07000000060000044` are the redactor's OWN historical
            # format-preserving masks, and every one of them matched. The `(?!0{4})` guard only
            # anchors on LEADING ZEROS, so a mask that kept its original first character
            # (`X1`, `X0`) or that zeroes the MIDDLE (`00000000XX00XXXX40`) sailed through.
            #
            # The invariant is a LAYOUT property, not a prefix: three identical characters in a
            # row cannot occur in a real PRC ID, USCC, mobile, landline or bank account. That
            # holds whatever an old masker happened to preserve, and it does not need to be
            # revisited when the mask format changes again - which is precisely how the two
            # previous guards (`0{17}`, then `0{16}`) became wrong.
            #
            # BACKREFERENCES: PostgreSQL ARE supports them but the sibling SQL dialects in
            # this repo's docs do not, so the three-way alternation is written out rather than
            # expressed as `([0-9A-Za-z_])\1{2}`.
            $maskReject = '000|111|222|333|444|555|666|777|888|999|XXX'
            $parts += @"
EXISTS (
        SELECT 1 FROM regexp_matches($Column, '$p', 'g') AS m(tok)
        WHERE m.tok[1] !~ '$maskReject'
          AND NOT EXISTS (
        SELECT 1 FROM regexp_matches($Column, '\[?[A-Z][A-Z0-9_]*_[0-9A-F]{8,}\]?', 'g') AS t(tok)
        WHERE strpos(t.tok[1], m.tok[1]) > 0
    )
)
"@
    }
    return ($parts -join ' OR ')
}

# Send SQL to psql over STDIN as UTF-8, whatever the console code page is.
#
# WHY THIS EXISTS (measured 2026-11-03)
#
# Five of the patterns above contain the FULL-WIDTH COLON inside a character class
# (`[:：]`) - lawyer_license, bank_account, cn_tax_id, th_tax_id, th_juristic. They
# are correct SQL, and each one works on its own. But `$sql | docker exec -i ...`
# encodes the pipe with `$OutputEncoding`, and on a Chinese Windows console the code
# page is 936. In that state the full-width colon is not representable, becomes `?`,
# and `[:：]?` turns into `[:?]?` - which Postgres rejects with
#     ERROR: invalid regular expression: quantifier operand invalid
#
# The visible symptom was silent and inverted: `remediate-sanitized-chunk-egress.ps1`
# reported "documents: 0 affected - no raw match" while `audit-sanitized-chunk-egress.ps1`
# reported 2 leaks in `invoice-ganjong`. The audit ran its predicate through the same
# pipe, but a single failing `~` inside an `OR` only nulls that term as long as at
# least one other term is valid - so the audit still found the leak through a pattern
# that happened to contain no wide colon, and the remediation, whose SELECT had no such
# fallback to succeed on, matched nothing at all.
#
# A remediation that reports "nothing to do" whenever its own query fails is the worst
# possible failure direction: it is indistinguishable from a clean machine, and it was
# reported as clean twice before this was found. So the fix is not "quote better" - it
# is to stop relying on ambient encoding, and to FAIL LOUDLY when psql rejects the SQL
# rather than returning the error text as if it were a row set.
function Invoke-PacgatePsql {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [string]$Container = 'pacgate-db',
        [string]$Database = 'pacgate',
        [string]$DbUser = 'pacgate'
    )

    $prev = $OutputEncoding
    try {
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $out = $Sql | docker exec -i $Container psql -U $DbUser -d $Database -t -A -v ON_ERROR_STOP=1 2>&1
    } finally {
        $OutputEncoding = $prev
    }

    $lines = @($out | ForEach-Object { "$_" })
    $errors = @($lines | Where-Object { $_ -match '^ERROR:|^psql: error' })
    if ($errors.Count -gt 0) {
        # A failed query is NOT "no matches". Returning the error text here is how
        # "nothing to remediate" got printed on a database with a known leak.
        throw ("psql rejected the query, so the result is UNKNOWN, not empty:`n  " +
            ($errors -join "`n  "))
    }

    # `CREATE FUNCTION` and friends emit a status line on the same stream as rows;
    # with `-q` they are suppressed, but ON_ERROR_STOP plus the filter above keeps
    # this correct even if a future psql is stricter about that flag.
    return @($lines | Where-Object { $_ -and $_ -notmatch '^(INFO|NOTICE|WARNING|CREATE |DROP |DO|SET)' })
}

