//! Regional identifier coverage, from the 0.2.18 audit's per-probe table.
//!
//! Every case here returned **0 redactions and `verdict: pass`** before the fix.
//! That combination is what makes this class of defect dangerous: a `pass` reads
//! as "nothing needed intercepting", not "this class is unsupported", so a
//! coverage gap is indistinguishable from a clean document in every report the
//! operator sees.
//!
//! Two of these were a LIVE LEAK, not a coverage nicety: `probe-0217-regression`
//! carries `香港入境许可 HK1234567；澳门非本地劳工证 M1234567` verbatim, is marked
//! `sanitized`, and is retrievable through kb_search. The 0.2.16 notes listed both
//! classes as supported; the rule required exactly ten digits after the prefix and
//! these have seven.

use pacgate_redact::detect::{Detector, TierOneDetector};
use pacgate_redact::EntityType;

fn detected(text: &str) -> Vec<(EntityType, String)> {
    TierOneDetector::new()
        .detect(text)
        .expect("detection never fails on readable text")
        .into_iter()
        .map(|m| (m.entity, m.text))
        .collect()
}

fn assert_caught(text: &str, value: &str, entity: EntityType) {
    let found = detected(text);
    assert!(
        found
            .iter()
            .any(|(e, t)| *e == entity && t == value),
        "not caught: {text:?} -> {found:?} (expected {entity:?} = {value:?})"
    );
}

/// 香港入境许可: `HK` + 7 digits, after its label.
#[test]
fn hk_entry_permit_is_caught() {
    for text in ["香港入境许可 HK1234567", "香港入境许可证：HK1234567"] {
        assert_caught(text, "HK1234567", EntityType::HkMoPermit);
    }
}

/// 澳门非本地劳工证: `M` + 7 digits, after its label.
#[test]
fn macau_non_resident_worker_permit_is_caught() {
    for text in [
        "澳门非本地劳工证 M1234567",
        "非本地劳工证：M1234567",
        "劳工证 M1234567",
    ] {
        assert_caught(text, "M1234567", EntityType::HkMoPermit);
    }
}

/// 澳门居民身份证: 7 digits + parenthesised check digit.
#[test]
fn macau_id_is_caught() {
    assert_caught("澳门居民身份证 5123456(7)", "5123456(7)", EntityType::HkMoPermit);
}

/// 澳门车牌: 澳 + authority letter + 4 digits.
#[test]
fn macau_plate_is_caught() {
    assert_caught("澳门车牌 澳A1234", "澳A1234", EntityType::VehiclePlate);
}

/// Philippines TIN: `3-3-3-000` printed form.
#[test]
fn philippines_tin_is_caught() {
    for text in [
        "菲律宾 TIN 123-456-789-000",
        "TIN: 123-456-789",
    ] {
        let found = detected(text);
        assert!(
            found.iter().any(|(e, _)| *e == EntityType::CnTaxId),
            "not caught: {text:?} -> {found:?}"
        );
    }
}

/// Vietnam MST must be caught AS A TAX ID, not stolen by the landline rule.
///
/// MEASURED 2026-11-03: `越南 MST 0101243150` produced `[LANDLINE_...]`. The rule
/// did fire - a 10-digit run matched the landline shape first. A label match is
/// `Context`, which outranks `Pattern`, so the labelled claim now wins.
#[test]
fn vietnam_mst_is_caught_as_a_tax_id_not_a_landline() {
    let found = detected("越南 MST 0101243150");
    assert!(
        found
            .iter()
            .any(|(e, t)| *e == EntityType::CnTaxId && t == "0101243150"),
        "MST must be a tax id: {found:?}"
    );
    assert!(
        !found.iter().any(|(e, _)| *e == EntityType::Landline),
        "MST must not also be a landline: {found:?}"
    );
}

/// Indonesia NPWP, dotted form, matched WHOLE.
///
/// MEASURED 2026-11-03: the `NPWP：` prefix was consumed by the LOCATION rule while
/// the number body survived verbatim - the label hidden and the value left, the
/// worst combination.
#[test]
fn indonesia_npwp_is_caught_whole() {
    assert_caught(
        "印尼 NPWP 01.234.567.8-901.000",
        "01.234.567.8-901.000",
        EntityType::CnTaxId,
    );
}

/// An UNLABELLED short prefix must not become a permit.
///
/// `HK1234567` and `M1234567` alone are ordinary order/flight reference shapes.
/// Claiming them bare would reintroduce the false positives this repo has paid for
/// repeatedly, so the label is mandatory and both are asserted here together - the
/// recall fix and its guard belong in one test.
#[test]
fn unlabelled_short_prefixes_are_not_permits() {
    for text in ["HK1234567", "M1234567", "订单号 HK1234567 已发出"] {
        let found = detected(text);
        assert!(
            !found.iter().any(|(e, _)| *e == EntityType::HkMoPermit),
            "an unlabelled short prefix became a permit: {text:?} -> {found:?}"
        );
    }
}

/// A bilingual Thai/Chinese summary prints the label with the English form in
/// parentheses and the value on the NEXT line:
///
/// ```text
/// 法人登记号 (Juristic ID)
/// 0115565002108
/// ```
///
/// MEASURED 2026-11-03 on a live `sanitized` chunk of a real matter: the
/// English-only label pattern did not match this layout, so the SELLER's
/// registration number stayed in plaintext and stayed searchable, while the
/// BUYER's number two fields later was correctly tokenised into
/// `[BANK_CARD_...]`. Half a document redacted is worse than none: the leftover
/// value looks like a deliberate exception rather than a miss.
#[test]
fn a_chinese_labelled_thai_registration_is_caught() {
    // The exact layout from the document, including the newline.
    assert_caught(
        "法人登记号 (Juristic ID)\n0115565002108",
        "0115565002108",
        EntityType::ThJuristicId,
    );
    // The same, with the value on the label line.
    assert_caught(
        "法人登记号 (Juristic ID) 0115565002108",
        "0115565002108",
        EntityType::ThJuristicId,
    );
    // The English-only form must keep working - this is the shape the original
    // rule was written for, and widening must not trade one for the other.
    assert_caught(
        "Juristic ID No.0115565002108",
        "0115565002108",
        EntityType::ThJuristicId,
    );
}

/// The buyer's tax id in the same document is printed with a Chinese label too:
///
/// ```text
/// 纳税人识别号(TaxID)
/// 3101401176368
/// ```
///
/// The label is Chinese, the English form is in parentheses, and the value is on
/// the next line - the same layout as the juristic id and the same reason it was
/// missed.
#[test]
fn a_chinese_labelled_thai_tax_id_is_caught() {
    assert_caught(
        "纳税人识别号(TaxID)\n3101401176368",
        "3101401176368",
        EntityType::ThTaxId,
    );
    // The English-only form must keep working.
    assert_caught("TaxID 3101401176368", "3101401176368", EntityType::ThTaxId);
}

/// The same Thai tax id printed with a CHINESE label and no English form.
///
/// MEASURED 2026-11-03: an audit report about this very leak quoted the number back
/// in a markdown table, `| 泰国企业税号 | 0115565002108 |`. The English pattern needs
/// the English word, so the value survived inside the document that documented its
/// own escape - and the document was labelled `sanitized` and searchable.
#[test]
fn a_chinese_only_thai_tax_label_is_caught() {
    for text in [
        "泰国税号    0115565002108",
        "| 泰国企业税号 | 0115565002108 |",
        "泰国纳税人识别号：0115565002108",
    ] {
        assert_caught(text, "0115565002108", EntityType::ThTaxId);
    }
}

/// The separator is restricted to layout characters, so the rule cannot reach across
/// prose. Without this, "泰国税号" would start claiming the next 13-digit run in any
/// sentence that mentioned it.
#[test]
fn a_chinese_thai_tax_label_does_not_reach_across_prose() {
    let found = detected("泰国税号这一项需要人工核对，金额为1234567890123元");
    assert!(
        !found.iter().any(|(e, _)| *e == EntityType::ThTaxId),
        "the label reached across prose: {found:?}"
    );
}

/// A bilingual summary collapses the label's internal space: `TaxID`, `JuristicID`.
///
/// MEASURED 2026-11-03 in a real `sanitized` chunk:
/// `卖方JuristicID0115565002108与买方TaxID3101401176368`. The pattern required a
/// literal space between the two words, so neither was caught in prose - only in the
/// tabular layout where the words happened to be separated.
#[test]
fn collapsed_thai_labels_are_caught_in_running_text() {
    assert_caught(
        "卖方JuristicID0115565002108与买方TaxID3101401176368",
        "0115565002108",
        EntityType::ThJuristicId,
    );
    assert_caught(
        "卖方JuristicID0115565002108与买方TaxID3101401176368",
        "3101401176368",
        EntityType::ThTaxId,
    );
}

/// Full-width and half-width brackets must both be accepted.
///
/// MEASURED 2026-11-03: one document printed `法人登记号（Juristic ID）` in one chunk
/// and `法人登记号 (Juristic ID)` in another. An explicit bracket list caught the
/// second and missed the first, so one chunk was tokenised and the other was not - in
/// the same document, labelled `sanitized`.
#[test]
fn both_bracket_widths_are_accepted_after_the_label() {
    for text in [
        "法人登记号（Juristic ID）\n0115565002108",
        "法人登记号 (Juristic ID)\n0115565002108",
        "| 法人登记号（Juristic ID） | 0115565002108 |",
    ] {
        assert_caught(text, "0115565002108", EntityType::ThJuristicId);
    }
}
