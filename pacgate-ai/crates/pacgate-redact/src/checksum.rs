//! Structural validators for China-jurisdiction and generic identifiers.
//!
//! Every Tier-1 detector calls into this module. A pattern match alone is
//! never enough: spec 8.4 forbids identifying an identifier from a bare
//! digit run, because that is exactly how account numbers, amounts and
//! trademark numbers get confused.

/// China resident ID (身份证号), 18-digit ISO 7064 MOD 11-2.
///
/// Layout: 6-digit region + 8-digit birthdate + 3-digit sequence + 1 check.
/// The final character may be `X` (uppercase) representing 10.
pub fn validate_cn_resident_id(s: &str) -> bool {
    const WEIGHTS: [u32; 17] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    const CHECK: [char; 11] = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

    let chars: Vec<char> = s.trim().chars().collect();
    if chars.len() != 18 {
        return false;
    }

    let mut sum: u32 = 0;
    for (i, c) in chars.iter().take(17).enumerate() {
        let Some(d) = c.to_digit(10) else {
            return false;
        };
        sum += d * WEIGHTS[i];
    }

    chars[17] == CHECK[(sum % 11) as usize]
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
    sum % 10 == 0
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