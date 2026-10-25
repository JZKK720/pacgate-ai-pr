use pacgate_redact::detect::Detector;

#[test]
fn a_checksum_valid_id_is_redacted_and_an_invalid_one_is_not() {
    // Measured 2026-10-25: the OCR sample's `110105199003074512` survived
    // sanitization. That is NOT a regression from the confidence gate - the
    // rule layer requires a valid checksum (`validate_cn_resident_id`) and this
    // number's check digit is wrong (expected 6, got 2). The fixture is
    // synthetic and was never a real ID.
    //
    // This test pins the behaviour so the distinction stays visible: a valid
    // checksum is redacted, an invalid one is left alone by the RULE layer.
    let d = pacgate_redact::detect::TierOneDetector::new();
    let valid = d.detect("身份证 11010519491231002X").unwrap();
    assert!(
        valid.iter().any(|m| m.entity == pacgate_redact::EntityType::CnResidentId),
        "a checksum-valid ID must be redacted"
    );
    let invalid = d.detect("身份证 110105199003074512").unwrap();
    assert!(
        !invalid.iter().any(|m| m.entity == pacgate_redact::EntityType::CnResidentId),
        "an ID with a bad check digit is not a valid ID; the rule layer rejects it"
    );
}
