//! The 2026-11-03 second-round review, pinned as executable requirements.
//!
//! The review's finding was not "a rule is missing". It was that the redactor
//! runs TWO replacement mechanisms in one pass: bracketed tokens for text-shaped
//! classes, and a zeroed format-preserving mask for number-shaped classes. The
//! mask is the defect, and it fails in four distinct ways:
//!
//!   1. It is keyed by ALLOCATION POSITION, not by value. The same ID gets a
//!      different mask depending on how many other identifiers the job happened
//!      to see first, so two documents in one matter cannot be correlated.
//!   2. It preserves the value's shape - length, letter positions, and the
//!      check character - so `91110105CA01ABCD26` became
//!      `00000000XX00XXXX10`: the search template survives, only the digits go.
//!   3. It collides. Two USCCs in one probe both produced `00000000X000000X10`.
//!   4. It leaks the counter, so the mask itself says "this is the third
//!      identifier in the document".
//!
//! The fix is one mechanism for both: a per-matter HMAC keyed by the NORMALISED
//! value, rendered as an opaque `[TYPE_TAG]` token. Position stops mattering,
//! shape stops leaking, collisions stop, and the counter disappears.
//!
//! These tests are the acceptance bar for that change.

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{EntityType, MappingVersion, Sanitizer};

fn sanitizer() -> Sanitizer {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
}

fn out_of(s: &mut Sanitizer, text: &str) -> String {
    s.sanitize(text, DataLevel::T3ProjectSpecific)
        .expect("sanitize is deterministic on readable text")
        .text
}

/// A fresh matter key per test, so tests cannot couple through shared state.
fn matter(name: &str) -> Sanitizer {
    Sanitizer::with_key(
        tier_one_detectors(),
        MappingVersion::CURRENT,
        pacgate_redact::TokenKey::from_secret(name.as_bytes()),
    )
}

// ---------------------------------------------------------------------------
// 1. The mask must be derived from the VALUE, not from its position.
// ---------------------------------------------------------------------------

/// The review's core measurement: the same resident ID appears as the first and
/// as the third allocated identifier in one matter, and the two documents must
/// still agree on its token.
///
/// Before the fix this produced `...001X` then `...0030`, so the documents could
/// not be joined on the number - the one thing a legal corpus needs to do.
#[test]
fn the_same_value_gets_the_same_token_whatever_its_position() {
    let mut s = matter("matter-position");

    let first = out_of(&mut s, "身份证 44030119800101123X");
    // Two other identifiers allocated before the ID in the next document.
    let later = out_of(
        &mut s,
        "手机 13812345678 卡号 6222021234567890128 身份证 44030119800101123X",
    );

    let token_from = |line: &str| -> String {
        line.split_whitespace()
            .find(|w| w.starts_with("[CN_ID_"))
            .unwrap_or_else(|| panic!("no CN_ID token in {line:?}"))
            .to_string()
    };
    assert_eq!(
        token_from(&first),
        token_from(&later),
        "the same ID must map to one token regardless of allocation order: \
         {first:?} vs {later:?}"
    );
}

/// Cross-matter correlation must NOT happen by default: two matters derive
/// different tags from the same value.
#[test]
fn different_matters_do_not_mint_the_same_token() {
    let mut a = matter("matter-a");
    let mut b = matter("matter-b");
    let ta = out_of(&mut a, "身份证 44030119800101123X");
    let tb = out_of(&mut b, "身份证 44030119800101123X");
    assert_ne!(
        ta, tb,
        "matter-scoped keys must not let two matters join on the same person"
    );
}

/// A default (token-less) sanitizer is the production path for a single job, and
/// it must still be value-keyed rather than position-keyed.
#[test]
fn a_default_sanitizer_is_value_keyed_too() {
    let mut s = sanitizer();
    let first = out_of(&mut s, "身份证 44030119800101123X");
    let later = out_of(&mut s, "手机 13812345678 身份证 44030119800101123X");
    assert!(
        later.contains(first.rsplit(' ').next().unwrap_or("\u{0}")),
        "value-keyed tokens survive a changed allocation order: {first:?} vs {later:?}"
    );
}

// ---------------------------------------------------------------------------
// 2. The token must not preserve the original's shape.
// ---------------------------------------------------------------------------

/// `91110105CA01ABCD26` used to become `00000000XX00XXXX10`, which hands a
/// searcher the encoding template: 18 chars, letters at 9-10 and 13-16.
#[test]
fn a_token_does_not_leak_the_originals_alphabet_layout() {
    let mut s = sanitizer();
    let out = out_of(&mut s, "统一社会信用代码 91110105CA01ABCD26");
    let token = out
        .split_whitespace()
        .find(|w| w.starts_with("[USCC_"))
        .expect("the USCC must be tokenised");
    assert!(
        token[1..token.len() - 1]
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'),
        "a token is [CODE_TAG] and nothing else: {token}"
    );
    assert!(
        !token.contains("XXXX"),
        "the letter layout must not survive into the token: {token}"
    );
}

/// No number-shaped class may still emit a bare zeroed run. This is the check
/// that would have caught the split mechanism on its own.
#[test]
fn no_identifier_class_emits_a_zeroed_numeric_mask() {
    let mut s = sanitizer();
    let out = out_of(
        &mut s,
        "身份证 44030119800101123X 代码 91110105CA01ABCD26 \
         卡号 6222021234567890128 账号 6222020200112345678",
    );
    for word in out.split_whitespace() {
        let zeros = word.chars().take_while(|c| *c == '0').count();
        assert!(
            zeros < 4,
            "a zeroed numeric mask survived the fix: {word:?} in {out:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// 3. Distinct values must never collide.
// ---------------------------------------------------------------------------

/// Two USCCs in one job both rendered as `00000000X000000X10` before the fix,
/// which breaks `Mapping::restore` for whichever one loses.
#[test]
fn distinct_values_never_share_a_token() {
    let mut s = sanitizer();
    let out = out_of(
        &mut s,
        "代码 91350100M000100Y43 另一份代码 91110105CA01ABCD26",
    );
    let tokens: Vec<&str> = out
        .split_whitespace()
        .filter(|w| w.starts_with("[USCC_"))
        .collect();
    assert_eq!(tokens.len(), 2, "both codes must be tokenised: {out:?}");
    assert_ne!(tokens[0], tokens[1], "two companies, two tokens: {out:?}");
}

// ---------------------------------------------------------------------------
// 4. Normalisation: the same printed value must reach the same token.
// ---------------------------------------------------------------------------

/// Grouping is how these numbers are printed. A token derived from the raw bytes
/// would split one person into one token per spacing.
#[test]
fn separator_and_case_variants_share_one_token() {
    let variants = [
        "身份证 44030119800101123X",
        "身份证 44030119800101123x",
        "身份证 440301 1980 0101 123X",
        "身份证 440301-1980-0101-123X",
    ];
    let mut tokens = Vec::new();
    for v in variants {
        let mut s = matter("matter-normalise");
        let out = out_of(&mut s, v);
        tokens.push(
            out.split_whitespace()
                .find(|w| w.starts_with("[CN_ID_"))
                .unwrap_or_else(|| panic!("no token in {out:?}"))
                .to_string(),
        );
    }
    assert!(
        tokens.windows(2).all(|w| w[0] == w[1]),
        "all printed forms of one ID must share a token: {tokens:?}"
    );
}

// ---------------------------------------------------------------------------
// 4b. The same value in the same matter must survive a restart and a re-run.
// ---------------------------------------------------------------------------

/// The operational requirement behind the key: a re-run of one document, or a
/// restart of the process, must mint the SAME tokens, or the mapping already
/// stored in the vault stops lining up with newly sanitized text.
///
/// This is what a per-process random key would break, and it is why
/// `PACGATE_SANITIZER_KEY` exists rather than "just use a UUID".
#[test]
fn the_same_matter_key_reproduces_the_same_tokens() {
    let run = |text: &str| {
        let mut s = matter("stable-matter");
        out_of(&mut s, text)
    };
    let first = run("身份证 44030119800101123X 卡号 6222021234567890128");
    let second = run("身份证 44030119800101123X 卡号 6222021234567890128");
    assert_eq!(
        first, second,
        "a re-run with the same matter key must reproduce the same tokens"
    );
}

// ---------------------------------------------------------------------------
// 5. The check digit must LABEL, not gate.
// ---------------------------------------------------------------------------

/// The review's clearest residual defect: an OCR-misread card is the most
/// important one to redact, and Luhn was deciding whether to look at it.
#[test]
fn a_card_that_fails_luhn_is_still_redacted() {
    let mut s = sanitizer();
    let out = out_of(&mut s, "卡号 6222021234567890129");
    assert!(
        !out.contains("6222021234567890129"),
        "a card one digit off must still be redacted, got {out:?}"
    );
    assert!(
        out.contains("[BANK_CARD_"),
        "and it must be tokenised like any other card: {out:?}"
    );
}

/// A 16-digit non-card (no Luhn) under a card label must not become a card, but
/// must not be silently republished either.
#[test]
fn a_misread_resident_id_is_never_mislabelled_as_a_bank_card() {
    let mut s = sanitizer();
    let out = out_of(&mut s, "身份证 440301198001011234");
    assert!(
        out.contains("[CN_ID_"),
        "the label says 身份证, so the token must say CN_ID: {out:?}"
    );
    assert!(
        !out.contains("[BANK_CARD_"),
        "a resident ID must never be reported as a bank card: {out:?}"
    );
}

// ---------------------------------------------------------------------------
// 6. Classes the review found entirely uncovered.
// ---------------------------------------------------------------------------

#[test]
fn overseas_and_minority_identifier_classes_are_covered() {
    let cases: &[(&str, EntityType)] = &[
        ("香港身份证 A123456(7)", EntityType::HkId),
        ("新加坡 NRIC S1234567D", EntityType::SgNric),
        ("马来西亚身份证 900101-14-5567", EntityType::MyId),
        ("台湾通行证 0123456789", EntityType::TaiwanPermit),
        ("护照 PE1234567", EntityType::Passport),
        ("军官证 军字第1234567号", EntityType::MilitaryId),
        ("TaxID 3101401176368", EntityType::ThTaxId),
        ("Juristic ID No.0115565002108", EntityType::ThJuristicId),
    ];
    for (text, entity) in cases {
        let mut s = sanitizer();
        let out = out_of(&mut s, text);
        let marker = format!("[{}_", entity.code());
        assert!(
            out.contains(&marker),
            "{entity:?} must be tokenised; expected {marker}... in {out:?} (input {text:?})"
        );
    }
}

/// A Thai TaxID must not be reported as a Chinese mobile, and its replacement
/// must be the same class the label names - the review's "structural mismatch".
#[test]
fn a_thai_tax_id_is_labeled_and_replaced_as_itself() {
    let mut s = sanitizer();
    let out = out_of(&mut s, "TaxID 3101401176368");
    assert!(out.contains("[TH_TAXID_"), "expected a TH_TAXID token: {out:?}");
    assert!(
        !out.contains("[CN_MOBILE_"),
        "a Thai tax id is not a Chinese mobile: {out:?}"
    );
}

/// The exact OCR line from the live `invoice-ganjong` chunk, where the value was
/// still plaintext after a `sanitized` label and two remediation passes.
///
/// `Juristic IDNo.0115565002108Tel（02）...` - the trailing `Tel` is the next field
/// starting immediately, which OCR produces constantly. `is_bounded` required a
/// NON-ALPHANUMERIC character after the value, so it rejected the match and the
/// identifier stayed in a searchable chunk. A published fixed-width numeric field
/// cannot be extended by a letter, so `is_digit_bounded` is the correct test here.
#[test]
fn a_thai_id_run_together_with_the_next_field_is_still_redacted() {
    for (text, marker) in [
        (
            "Juristic IDNo.0115565002108Tel（02）0332333Fax.020332391",
            "[TH_JURISTIC_",
        ),
        ("TaxIDNo.3101401176368Tel.02", "[TH_TAXID_"),
        ("Tax ID 3101401176368Fax", "[TH_TAXID_"),
    ] {
        let mut s = sanitizer();
        let out = out_of(&mut s, text);
        assert!(
            out.contains(marker),
            "a fixed-width labelled id followed by the next field must be redacted: \
             {text:?} -> {out:?} (expected {marker})"
        );
    }
}

/// The relaxation above must not become "any 13-digit run": a LONGER digit run
/// still refuses the match, which is the case that matters (an order number whose
/// head matches the same digits).
#[test]
fn a_longer_digit_run_is_not_mistaken_for_a_thai_id() {
    let mut s = sanitizer();
    let text = "Juristic IDNo.011556500210811Tel";
    let out = out_of(&mut s, text);
    assert_eq!(
        out, text,
        "a digit run longer than the published 13 must not match: {out:?}"
    );
}

// ---------------------------------------------------------------------------
// 7. Precision: none of this may touch ordinary contract text.
// ---------------------------------------------------------------------------

/// The review's fourth found defect: `身份证44030119800101123X` with NO space.
///
/// Chinese legal text rarely puts a space before an ID number. The review's
/// prototype leaked this entirely because Python's `\w` includes CJK, so `\b` does
/// not exist between 证 and 4. `pacgate-redact` never used `\b` - `is_bounded`
/// tests for ASCII alphanumerics, which a CJK character is not - so this should
/// already pass; it is pinned here because it is the single form most likely to be
/// reintroduced by a future rule that reaches for `\b`.
#[test]
fn an_identifier_glued_to_chinese_text_is_still_redacted() {
    for (text, marker) in [
        ("身份证44030119800101123X", "[CN_ID_"),
        ("身份证号44030119800101123X", "[CN_ID_"),
        ("代码91110105CA01ABCD26", "[USCC_"),
        ("卡号6222021234567890128", "[BANK_CARD_"),
        ("手机13812345678", "[CN_MOBILE_"),
        ("律师执业证号11101201810123456", "[LAWYER_NO_"),
        ("车牌粤B12345", "[PLATE_"),
    ] {
        let mut s = sanitizer();
        let out = out_of(&mut s, text);
        assert!(
            out.contains(marker),
            "an identifier glued to Chinese text must still be redacted: \
             {text:?} -> {out:?} (expected {marker})"
        );
    }
}

#[test]
fn ordinary_contract_text_is_untouched() {
    let mut s = sanitizer();
    let text = "借款金额 1,250,000.00 元，年利率 4.35%，期限 2026-01-01 至 2028-12-31；\
                合同编号 PG-2026-0042；参见 (2019)最高法民终1234号";
    assert_eq!(
        out_of(&mut s, text),
        text,
        "no token may appear in text that contains no identifier"
    );
}
