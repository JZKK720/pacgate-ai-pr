//! Structural validators for China-jurisdiction and generic identifiers.
//!
//! Every Tier-1 detector calls into this module. A pattern match alone is
//! never enough: spec 8.4 forbids identifying an identifier from a bare
//! digit run, because that is exactly how account numbers, amounts and
//! trademark numbers get confused.

/// China resident ID (身份证号), 18-digit ISO 7064 MOD 11-2.
///
/// Layout: 6-digit region + 8-digit birthdate + 3-digit sequence + 1 check.
/// The final character may be `X` representing 10. Both cases are accepted on
/// input: `RE_CN_ID_CANDIDATE` matches `[\dXx]`, and a lowercase `x` is a normal
/// way for a scan or a hand-typed form to render the check character. Measured
/// 2026-11-02: `cn_resident_id_shape_ok` accepted only `'X'` while the pattern
/// accepted both, so `身份证号：11010519900307001x` matched the regex and was
/// then thrown away by the validator - a real identifier left in the text by a
/// detector that had already found it.
pub fn validate_cn_resident_id(s: &str) -> bool {
    if !cn_resident_id_shape_ok(s) {
        return false;
    }
    let chars: Vec<char> = s.trim().chars().collect();
    let check = cn_resident_id_check_char(s);
    chars[17] == check
}

/// Shape-only test: length, digits, region prefix and a real birthdate.
///
/// Deliberately separate from the check digit, because the two answer
/// different questions and only one of them is available in the text:
///
///   * `validate_cn_resident_id` answers "is this a well-formed, issued
///     number" - the strongest evidence when it passes.
///   * `cn_resident_id_shape_ok` answers "is this the right KIND of value to
///     redact" - which is the question a redactor actually has to answer.
///
/// The distinction was missing until 2026-11-02 and it leaked. The OCR sample
/// `110105199003074512` (a 1990-03-07 birth, region 110105) failed the check
/// digit (expected `X`, got `2`) and was therefore left in the text - then
/// indexed as searchable, so it could be looked up by number. A check digit
/// being wrong says the value is not a real issued ID; it does not say the
/// text stops being identifying. A mistyped, OCR-damaged or deliberately
/// altered ID is still personal data, and refusing to touch it protects
/// nobody except the person who typed it wrong.
///
/// The region test is the first character only (1-8): the 6-digit address
/// code space is large and versioned, and a lookup table here would be a
/// second source of truth to drift. The birthdate test is a real calendar
/// check, which is what does the discriminating work - `110105` followed by
/// `19491231` is far too specific to be an order number.
pub fn cn_resident_id_shape_ok(s: &str) -> bool {
    let chars: Vec<char> = s.trim().chars().collect();
    if chars.len() != 18 {
        return false;
    }
    // Region: 6 digits, and the leading digit of a county-level code is 1-8.
    if !matches!(chars[0], '1'..='8') || !chars[..6].iter().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if !chars[6..17].iter().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if !(chars[17].is_ascii_digit() || chars[17] == 'X' || chars[17] == 'x') {
        return false;
    }
    is_real_date(&chars[6..14])
}

/// ISO 7064 MOD 11-2 check character for an 18-digit resident ID.
pub fn cn_resident_id_check_char(s: &str) -> char {
    const WEIGHTS: [u32; 17] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    const CHECK: [char; 11] = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

    let mut sum: u32 = 0;
    for (i, c) in s.trim().chars().take(17).enumerate() {
        let d = c.to_digit(10).unwrap_or(0);
        sum += d * WEIGHTS[i];
    }
    CHECK[(sum % 11) as usize]
}

/// True when `chars` is `YYYYMMDD` naming a real calendar day in 1900..=2099.
///
/// The upper bound is deliberately loose rather than "not in the future": a
/// birthdate is the only field this is used for, and 1900..=2099 accepts every
/// plausible one while still rejecting `00000000`, `19901332` and `19490231`.
pub fn is_real_date(chars: &[char]) -> bool {
    if chars.len() != 8 || !chars.iter().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let digits = |from: usize, to: usize| -> u32 {
        chars[from..to]
            .iter()
            .fold(0u32, |acc, c| acc * 10 + c.to_digit(10).unwrap_or(0))
    };
    let year = digits(0, 4);
    let month = digits(4, 6);
    let day = digits(6, 8);
    if !(1900..=2099).contains(&year) || !(1..=12).contains(&month) {
        return false;
    }
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let last = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if leap => 29,
        _ => 28,
    };
    (1..=last).contains(&day)
}

/// Unified Social Credit Code (统一社会信用代码), 18 chars, MOD 31.
///
/// Charset is 31 symbols: digits plus uppercase letters minus I, O, S, V, Z.
pub fn validate_uscc(s: &str) -> bool {
    const CHARSET: &[u8] = b"0123456789ABCDEFGHJKLMNPQRTUWXY";
    const WEIGHTS: [u32; 17] = [
        1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28,
    ];

    let s = s.trim();
    if s.len() != 18 || !s.is_ascii() {
        return false;
    }
    let bytes = s.as_bytes();

    let mut sum: u32 = 0;
    for (i, b) in bytes.iter().take(17).enumerate() {
        let Some(idx) = CHARSET.iter().position(|c| c == b) else {
            return false;
        };
        sum += idx as u32 * WEIGHTS[i];
    }

    let check = 31 - (sum % 31);
    let check = if check == 31 { 0 } else { check };
    bytes[17] == CHARSET[check as usize]
}

/// Shape-only test for a Unified Social Credit Code, check digit excluded.
///
/// A USCC that fails MOD 31 is still an 18-character registration number in a
/// document about a company, and leaving it in the text because the arithmetic
/// did not land is the same mistake `cn_resident_id_shape_ok` exists to stop.
///
/// The shape is what carries the evidence, not the checksum: registration
/// authority (position 0 in the published set), a 6-digit administrative
/// division at 2..8, and the 18-character restricted alphabet. That
/// combination is not what an order number, a hash or a base64 fragment
/// looks like - the restricted alphabet has no `I O S V Z` and no lowercase,
/// and the 6 digits at a fixed offset rule out an arbitrary token.
pub fn uscc_shape_ok(s: &str) -> bool {
    const CHARSET: &[u8] = b"0123456789ABCDEFGHJKLMNPQRTUWXY";
    /// Published registration-authority codes: 1 机构编制, 5 民政,
    /// 9 工商, Y 其他(含 A 农民专业合作社). A USCC always starts with one.
    const AUTHORITY: [char; 4] = ['1', '5', '9', 'Y'];

    let s = s.trim();
    if s.len() != 18 || !s.is_ascii() {
        return false;
    }
    let bytes = s.as_bytes();
    if !bytes.iter().all(|b| CHARSET.contains(b)) {
        return false;
    }
    if !AUTHORITY.contains(&(bytes[0] as char)) {
        return false;
    }
    // 6-digit administrative division code at 2..8.
    bytes[2..8].iter().all(|b| b.is_ascii_digit())
}

/// Shape test for a bank CARD number, independent of its check digit.
///
/// Added 2026-11-03 with the removal of the Luhn gate. Without a shape test the
/// gate was doing two jobs at once, and only one of them can be dropped: Luhn
/// must not decide whether a value is redacted, but SOMETHING still has to stop
/// `RE_DIGIT_RUN` (12-19 digits) from claiming an order number, an amount written
/// without separators, or a timestamp.
///
/// What separates a card from a long number:
///   * length 13-19, the ISO/IEC 7812 range;
///   * issuer prefix 2-6. Every bank card begins with a major industry identifier
///     in this range (2 mastercard, 3 Amex/JCB, 4 Visa, 5 Mastercard, 6 UnionPay).
///     No amount, date, phone, account-only number or contract number reliably
///     does, and `1` is excluded because a run starting with `1` is what a mobile
///     number and a legacy ID look like.
///
/// MEASURED 2026-11-03: with this test and no Luhn requirement, a misread card
/// (`6222021234567890129`) is claimed while the review's precision controls
/// (`1,250,000.00`, `2026-01-01`, `PG-2026-0042`) stay untouched - the separators
/// break the run before length is even considered.
pub fn card_number_shape_ok(digits: &str) -> bool {
    let t = digits.trim();
    if !(13..=19).contains(&t.len()) || !t.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    matches!(t.as_bytes()[0], b'2'..=b'6')
}

/// Shape test for a bank account number.
///
/// No checksum exists domestically (the Luhn card rule covers cards, not
/// accounts), so the label plus a plausible length is the only evidence
/// available. The length window is the printed range for an account:
/// 8 digits at the short end, 32 at the long end. A 6-digit run is excluded on
/// purpose - it is indistinguishable from a date fragment or an amount.
pub fn bank_account_shape_ok(digits: &str) -> bool {
    let t = digits.trim();
    (8..=32).contains(&t.len()) && t.chars().all(|c| c.is_ascii_digit())
}

/// Shape test for a Malaysian identity card, applied to the pattern's span.
///
/// The layout is `YYMMDD-PB-###G`. The pattern already requires the hyphens; this
/// adds the one check the pattern cannot express without a date engine - that the
/// head is a real calendar day - so `999999-14-5567` is not an identity card.
pub fn malaysian_id_shape_ok(s: &str) -> bool {
    let digits: Vec<char> = s
        .trim()
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect();
    if digits.len() != 12 {
        return false;
    }
    // Two-digit year: try both centuries the printed card can mean.
    is_real_date(&[
        '1', '9', digits[0], digits[1], digits[2], digits[3], digits[4], digits[5],
    ]) || is_real_date(&[
        '2', '0', digits[0], digits[1], digits[2], digits[3], digits[4], digits[5],
    ])
}

/// Shape test for a mainland vehicle registration plate.
///
/// Format: province character + authority letter + 5 characters from the
/// issued set (excluding `I` and `O`), optionally a new-energy 6th character.
/// The province list is fixed and finite, which is why this is a shape test
/// and not a guess - there is no way to build a false positive out of a
/// document sentence, because the leading character must be a province.
pub fn vehicle_plate_shape_ok(s: &str) -> bool {
    const PROVINCES: [char; 31] = [
        '京', '津', '冀', '晋', '蒙', '辽', '吉', '黑', '沪', '苏', '浙', '皖', '闽', '赣', '鲁',
        '豫', '鄂', '湘', '粤', '桂', '琼', '渝', '川', '贵', '云', '藏', '陕', '甘', '青', '宁',
        '新',
    ];
    let chars: Vec<char> = s.trim().chars().collect();
    if !(7..=8).contains(&chars.len()) {
        return false;
    }
    if !PROVINCES.contains(&chars[0]) {
        return false;
    }
    if !chars[1].is_ascii_alphabetic() {
        return false;
    }
    chars[2..].iter().all(|c| {
        c.is_ascii_digit() || (c.is_ascii_alphabetic() && *c != 'I' && *c != 'i' && *c != 'O' && *c != 'o')
    })
}

/// Luhn (ISO/IEC 7812) for bank card numbers.
///
/// Does not validate the issuer or the exact length beyond a sane floor; the
/// detector layer applies the length and prefix rules.
pub fn validate_luhn(digits: &str) -> bool {
    let digits = digits.trim();
    if digits.len() < 12 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }

    let mut sum: u32 = 0;
    let mut double = false;
    for c in digits.chars().rev() {
        let Some(mut d) = c.to_digit(10) else {
            return false;
        };
        if double {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        double = !double;
    }
    sum.is_multiple_of(10)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_a_known_valid_resident_id() {
        // Synthetic. 11010519491231002X is the canonical ISO 7064 MOD 11-2 example.
        assert!(validate_cn_resident_id("11010519491231002X"));
    }

    #[test]
    fn rejects_a_resident_id_with_a_bad_check_digit() {
        assert!(!validate_cn_resident_id("110105194912310021"));
        assert!(!validate_cn_resident_id("11010519491231002Y"));
    }

    #[test]
    fn rejects_wrong_length_and_non_digit_bodies() {
        assert!(!validate_cn_resident_id("1101051949123100"));
        assert!(!validate_cn_resident_id("11010519491231002"));
        assert!(!validate_cn_resident_id("11010519491A31002X"));
    }

    #[test]
    fn accepts_a_known_valid_uscc() {
        // Synthetic. 91350100M000100Y43 is a published MOD-31 worked example.
        assert!(validate_uscc("91350100M000100Y43"));
    }

    #[test]
    fn rejects_uscc_with_illegal_chars_and_bad_check() {
        // I, O, S, V, Z are never used in the USCC charset.
        assert!(!validate_uscc("91350100M000100Y4I"));
        assert!(!validate_uscc("91350100M000100Y44"));
    }

    #[test]
    fn luhn_accepts_known_valid_and_rejects_off_by_one() {
        assert!(validate_luhn("4111111111111111"));
        assert!(!validate_luhn("4111111111111112"));
    }

    #[test]
    fn all_validators_reject_empty_and_short_input() {
        assert!(!validate_cn_resident_id(""));
        assert!(!validate_uscc(""));
        assert!(!validate_luhn(""));
        assert!(!validate_luhn("41111111111"));
    }
}