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
