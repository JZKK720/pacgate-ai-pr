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
# WHY `(?!0{17})` IS PRESENT ON BOTH 18-CHARACTER PATTERNS
#
# The redactor renders a Chinese ID card as `00000000000000000X` - 17 zeros and an X.
# That value is a legitimate member of BOTH character classes below, so without the
# guard each pattern flags the sanitizer's own output as a leak. On a machine with zero
# real leaks that produced 37 false "leaks" against each pattern in turn, and the first
# fix attempt only covered one of the two, so the count simply moved to the other.
#
# Real Chinese ID cards and USCCs do not begin with 17 zeros, so the guard excludes
# exactly the placeholder and nothing else.
#
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

$PacgateRawPiiPatterns = [ordered]@{
    # An email address. Safe as-is: the redactor's placeholder for one is a bracketed
    # token like [EMAIL_...], which cannot match.
    'email'         = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

    # A PRC resident ID card: 17 digits then a check character.
    #
    # The guard excludes the redactor's own format-preserving placeholder, which
    # is 16 zeros, an index, and a Luhn check digit - e.g. 000000000000000026.
    # It was written as `(?!0{17})`, which requires SEVENTEEN leading zeros and so
    # never matched the placeholder it was meant to exclude: measured 2026-10-25,
    # `'000000000000000026' ~ '(?!0{17})[0-9]{17}[0-9Xx]'` returned true and the
    # audit reported the redactor's own output as a leak. `0{16}` is the correct
    # width - a real ID never starts with 16 zeros.
    'cn_id_card'    = '(?!0{16})[0-9]{17}[0-9Xx]'

    # A Unified Social Credit Code: 18 characters from a restricted alphabet.
    # Same placeholder guard, same off-by-one - this is the one that was missed on
    # the remediation side.
    'uscc'          = '(?!0{16})[0-9A-HJ-NPQRTUWXY]{18}'

    # A PRC mobile number.
    'cn_mobile'     = '1[3-9][0-9]{9}'

    # A PRC landline with an area code, hyphen optional.
    'cn_landline'   = '0(10|2[1-9]|[3-9][0-9]{2})-?[0-9]{7,8}'
}

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
