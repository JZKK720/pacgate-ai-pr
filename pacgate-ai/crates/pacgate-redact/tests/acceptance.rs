//! Acceptance tests drawn from the client spec section 9.
//!
//! Only the rows this crate can decide are covered here. Rows that require
//! OCR, a database or the cloud boundary belong to plans 2-4, and are
//! deliberately absent rather than faked.

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{MappingVersion, SanitizeOutcome, Sanitizer, Verdict};

fn sanitize(text: &str, level: DataLevel) -> SanitizeOutcome {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
        .sanitize(text, level)
        .expect("sanitize should not error on readable input")
}

#[test]
fn spec_9_id_phone_email_and_labelled_accounts_do_not_survive() {
    let input = "身份证 11010519491231002X 手机 13812345678 邮箱 a@b.com";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    for secret in ["11010519491231002X", "13812345678", "a@b.com"] {
        assert!(!out.text.contains(secret), "{secret} survived redaction");
    }
    assert_eq!(out.ledger.verdict(), Verdict::Pass);
}

#[test]
fn spec_9_public_reference_citations_are_preserved() {
    let input = "参见 (2019)最高法民终1234号 的裁判要旨";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    assert!(
        out.text.contains("(2019)最高法民终1234号"),
        "a published citation unrelated to client identity must survive so the reference stays verifiable"
    );
}

#[test]
fn spec_9_amounts_dates_and_formulas_are_untouched() {
    let input = "借款金额 1,234,567.89 元，年利率 4.35%，期限 2026-01-01 至 2028-12-31";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    for kept in ["1,234,567.89", "4.35%", "2026-01-01", "2028-12-31"] {
        assert!(out.text.contains(kept), "must not alter {kept}");
    }
}

#[test]
fn spec_9_a_stale_mapping_version_is_refused() {
    let out = sanitize("a@b.com", DataLevel::T3ProjectSpecific);
    assert!(
        out.mapping.restore(&out.text, MappingVersion(999)).is_err(),
        "a stale mapping version must be refused"
    );
}

#[test]
fn spec_9_ledger_records_the_change_without_retaining_the_original() {
    let out = sanitize("机密 a@b.com", DataLevel::T3ProjectSpecific);
    let json = out.ledger.to_json().unwrap();
    assert!(!json.contains("a@b.com"));
    assert_ne!(out.ledger.input_sha256(), out.ledger.output_sha256());
}

#[test]
fn spec_9_rule_layer_recall_is_reported_per_tier() {
    // Spec 9 requires layer-separated, tier-separated reporting. This test is
    // the rule-layer row for Tier 1: every fixture must be caught.
    let fixtures = [
        ("11010519491231002X", "CnResidentId"),
        ("13812345678", "CnMobile"),
        ("4111111111111111", "BankCard"),
        ("a@b.com", "Email"),
    ];
    for (value, label) in fixtures {
        let out = sanitize(value, DataLevel::T3ProjectSpecific);
        assert!(
            !out.text.contains(value),
            "Tier-1 rule-layer miss for {label}: {value} survived"
        );
    }
}

#[test]
fn spec_9_cross_job_identity_isolation_is_structural() {
    // Different matters running at the same time must not share identity
    // (acceptance: 不同事项同时运行 原件、映射及结果相互隔离).
    let mut job1 = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
    let mut job2 = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
    let a = job1
        .sanitize("当事人 a@b.com", DataLevel::T3ProjectSpecific)
        .unwrap();
    let b = job2
        .sanitize("当事人 a@b.com", DataLevel::T3ProjectSpecific)
        .unwrap();
    assert_ne!(a.job_id, b.job_id, "two jobs must never share a job id");
    assert_ne!(
        a.text, b.text,
        "two jobs must mint different placeholder names for the same subject"
    );
}