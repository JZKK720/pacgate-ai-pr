//! Identifier recall and precision for the Tier-1 rule layer.
//!
//! Two claims are pinned here, and they are the two that the 2026-11-02 client
//! scan showed were NOT being met:
//!
//!   1. A value with the full shape of a Chinese resident ID is redacted even
//!      when its check digit is wrong. A wrong check digit means "not an
//!      issued number"; it does not mean "no longer personal data".
//!   2. Precision survives: the shapes are still bounded, so an order number,
//!      an amount or an unrelated 18-digit run is not swept up.

use pacgate_redact::checksum::{cn_resident_id_shape_ok, validate_cn_resident_id};
use pacgate_redact::detect::Detector;
use pacgate_redact::{EntityType, MatchSource};

fn find(text: &str) -> Vec<(EntityType, String)> {
    pacgate_redact::detect::TierOneDetector::new()
        .detect(text)
        .expect("detection is deterministic and never fails on readable text")
        .into_iter()
        .map(|m| (m.entity, m.text))
        .collect()
}

/// The number the client scan found verbatim in a `sanitized`, searchable
/// document.
///
/// Its check digit is wrong (expected `X`, given `2`), which is exactly why the
/// pre-2026-11-02 rule layer skipped it: the rule required
/// `validate_cn_resident_id`, so a mistyped or OCR-damaged ID was treated as
/// "not an ID" and left in place. Region `110105` and birth `1990-03-07` are
/// both well-formed, so the SHAPE is unambiguous - it is a mis-keyed ID, and a
/// mis-keyed ID is still an identifier.
#[test]
fn a_resident_id_with_a_bad_check_digit_is_still_redacted() {
    assert!(
        !validate_cn_resident_id("110105199003074512"),
        "precondition: this fixture's check digit really is wrong"
    );
    assert!(
        cn_resident_id_shape_ok("110105199003074512"),
        "precondition: the shape (region + real birthdate) is well-formed"
    );

    let found = find("身份证号：110105199003074512");
    assert!(
        found
            .iter()
            .any(|(e, t)| *e == EntityType::CnResidentId && t == "110105199003074512"),
        "a shape-valid resident ID must be redacted even with a bad check digit; got {found:?}"
    );
}

/// The checksum-valid form keeps its stronger evidence label, so the ledger can
/// distinguish "this is certainly an ID" from "this has the shape of one".
#[test]
fn a_checksum_valid_id_is_claimed_at_checksum_strength() {
    let matches = pacgate_redact::detect::TierOneDetector::new()
        .detect("身份证 11010519491231002X")
        .unwrap();
    let id = matches
        .iter()
        .find(|m| m.entity == EntityType::CnResidentId)
        .expect("the canonical valid ID must be found");
    assert_eq!(id.source, MatchSource::Checksum);
    assert_eq!(id.text, "11010519491231002X");
}

/// A shape-valid but checksum-invalid ID is claimed at pattern strength: still
/// redacted, but recorded as weaker evidence.
#[test]
fn a_shape_only_id_is_claimed_at_pattern_strength() {
    let matches = pacgate_redact::detect::TierOneDetector::new()
        .detect("身份证号：110105199003074512")
        .unwrap();
    let id = matches
        .iter()
        .find(|m| m.entity == EntityType::CnResidentId)
        .expect("the shape-valid ID must be found");
    assert_eq!(id.source, MatchSource::Pattern);
}

/// Precision guard. Widening the ID rule must not turn it into "any 18-digit
/// run": the birthdate has to be a real calendar day and the region prefix has
/// to be a plausible county code.
#[test]
fn eighteen_digit_runs_that_are_not_ids_stay_untouched() {
    let not_ids = [
        // Month 13.
        "编号 110105199013074512",
        // 31 February.
        "编号 110105199002314512",
        // Year 1899 - before any resident ID was issued.
        "编号 110105189912314512",
        // Leading region digit 9 is not a county-level code.
        "编号 960105199003074512",
        // An order number that carries no date at all.
        "订单号 202603070012345678",
    ];
    for text in not_ids {
        let found = find(text);
        assert!(
            !found.iter().any(|(e, _)| *e == EntityType::CnResidentId),
            "false positive: {text} was claimed as a resident ID: {found:?}"
        );
    }
}

/// The USCC alphabet is a superset of the resident-ID alphabet, so a bare
/// 18-digit ID is also a USCC *candidate*. It must be reported once, as an ID.
#[test]
fn a_resident_id_is_not_also_reported_as_a_credit_code() {
    let found = find("身份证 11010519491231002X");
    let codes: Vec<EntityType> = found.iter().map(|(e, _)| *e).collect();
    assert!(
        !codes.contains(&EntityType::Uscc),
        "one value must not be reported as two entity types: {found:?}"
    );
}

/// A USCC that fails MOD 31 is still a company registration number.
#[test]
fn a_uscc_with_a_bad_check_digit_is_still_redacted() {
    // Published valid example, last character altered.
    let found = find("统一社会信用代码 91350100M000100Y44");
    assert!(
        found
            .iter()
            .any(|(e, t)| *e == EntityType::Uscc && t == "91350100M000100Y44"),
        "a shape-valid credit code must be redacted even with a bad check digit; got {found:?}"
    );
}
