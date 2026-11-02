//! The eight identifier classes that survived a `pass` verdict on 2026-11-02.
//!
//! The client ran a real scanned contract through the pipeline and got:
//!
//! ```text
//! verdict: pass
//! redaction_count: 13
//! verification_notes:
//!   "tier1-rules: 1 surviving match(es)"
//!   "noise replay: 1 of 1 surviving matches dropped by the same suppressor
//!    the redaction used"
//! ```
//!
//! while these stayed verbatim in the text, which was then indexed as
//! searchable and labelled `sanitized`:
//!
//!   中国居民身份证号, 统一社会信用代码, 律师执业证号, 银行账号,
//!   港澳通行证, 车牌, 微信号, 纳税人识别号
//!
//! Two root causes are exercised here, and the tests are split along them:
//!
//!   * `rule_layer_covers_*` - the identifier had no rule, or the rule required
//!     a checksum that a mistyped/OCR-damaged value cannot have.
//!   * `verifier_*` - the rule DID fire, and the verifier then dropped the
//!     survivor with the redactor's own suppressor and reported `pass`.
//!
//! Every fixture is synthetic.

use pacgate_core::DataLevel;
use pacgate_redact::detect::{tier_one_detectors, Detector};
use pacgate_redact::{EntityType, MappingVersion, Sanitizer, Verdict};

fn sanitize(text: &str) -> pacgate_redact::SanitizeOutcome {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
        .sanitize(text, DataLevel::T3ProjectSpecific)
        .expect("sanitize must not error on readable input")
}

fn detected_entities(text: &str) -> Vec<EntityType> {
    pacgate_redact::detect::TierOneDetector::new()
        .detect(text)
        .expect("detection never fails on readable text")
        .into_iter()
        .map(|m| m.entity)
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Rule-layer coverage: one test per class the client scan found surviving.
// ─────────────────────────────────────────────────────────────────────────────

/// 身份证号. The exact value from the client scan, which has a BAD check digit
/// and was therefore skipped by the old "checksum or nothing" rule.
#[test]
fn rule_layer_covers_a_mistyped_resident_id() {
    let text = "委托人：[PERSON_14BF81AB_1]身份证号：110105199003074512";
    let out = sanitize(text);
    assert!(
        !out.text.contains("110105199003074512"),
        "resident ID survived: {:?}",
        out.text
    );
    assert_eq!(
        out.ledger.verdict(),
        Verdict::Pass,
        "a clean redaction must not block; notes={:?}",
        out.ledger.verification_notes
    );
}

/// 统一社会信用代码.
#[test]
fn rule_layer_covers_a_credit_code() {
    let text = "甲方：某某科技有限公司（统一社会信用代码：91350100M000100Y43）";
    let out = sanitize(text);
    assert!(
        !out.text.contains("91350100M000100Y43"),
        "credit code survived: {:?}",
        out.text
    );
}

/// 律师执业证号. Was reported as `RegistrationNumber`, which conflated a
/// natural person's licence with a company registration.
#[test]
fn rule_layer_covers_a_lawyer_license() {
    let text = "代理律师：李某，律师执业证号 11101201810123456";
    let out = sanitize(text);
    assert!(
        !out.text.contains("11101201810123456"),
        "lawyer licence survived: {:?}",
        out.text
    );
    assert!(
        detected_entities(text).contains(&EntityType::LawyerLicense),
        "the licence must be reported under its own entity type, not RegistrationNumber"
    );
}

/// 银行账号. No checksum exists, so the label is the anchor.
#[test]
fn rule_layer_covers_a_bank_account() {
    for text in [
        "开户行：中国工商银行北京分行 账号：6222020200112345678",
        "收款账户 6222 0202 0011 2345 678",
        "银行帐号：02000012345678901",
    ] {
        let out = sanitize(text);
        assert!(
            !out.text.contains("6222020200112345678")
                && !out.text.contains("6222 0202 0011 2345 678")
                && !out.text.contains("02000012345678901"),
            "bank account survived in {text:?}: {:?}",
            out.text
        );
    }
}

/// 港澳通行证. The `C` + 8-digit card form and the labelled older form.
#[test]
fn rule_layer_covers_a_hk_mo_travel_permit() {
    for (text, value) in [
        ("证件号码 C12345678", "C12345678"),
        ("港澳通行证号码 C1234567", "C1234567"),
        ("回乡证 H1234567812", "H1234567812"),
    ] {
        let out = sanitize(text);
        assert!(
            !out.text.contains(value),
            "travel permit {value} survived in {text:?}: {:?}",
            out.text
        );
    }
}

/// 车牌. Shape-only: the province character closes the pattern.
#[test]
fn rule_layer_covers_a_vehicle_plate() {
    for (text, value) in [
        ("车辆：京A12345", "京A12345"),
        ("抵押车辆 粤B12345", "粤B12345"),
        // New-energy 6-character suffix.
        ("车牌号 沪AD12345", "沪AD12345"),
    ] {
        let out = sanitize(text);
        assert!(
            !out.text.contains(value),
            "plate {value} survived in {text:?}: {:?}",
            out.text
        );
    }
}

/// 微信号. Label anchored; the handle charset is fixed by the platform.
#[test]
fn rule_layer_covers_a_wechat_id() {
    for (text, value) in [
        ("微信号：zhang_san_88", "zhang_san_88"),
        ("微信 wang-lawyer01", "wang-lawyer01"),
    ] {
        let out = sanitize(text);
        assert!(
            !out.text.contains(value),
            "wechat id {value} survived in {text:?}: {:?}",
            out.text
        );
    }
}

/// 纳税人识别号. May be a USCC or one of the older 15/17/18/20-digit tax codes.
#[test]
fn rule_layer_covers_a_taxpayer_id() {
    for (text, value) in [
        ("纳税人识别号：91350100M000100Y43", "91350100M000100Y43"),
        ("纳税人识别号码 110105123456789", "110105123456789"),
    ] {
        let out = sanitize(text);
        assert!(
            !out.text.contains(value),
            "taxpayer id {value} survived in {text:?}: {:?}",
            out.text
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verifier independence: the circularity that turned all of the above into
// `pass`.
// ─────────────────────────────────────────────────────────────────────────────

/// The pre-fix notes, reproduced verbatim as the failure this test forbids.
///
/// With the old verifier, the suppressor the redaction used also ran over the
/// residue, so a survivor the suppressor missed on the way in was missed on the
/// way out and the verdict said `pass`. The assertion here is on the SHAPE of
/// the audit trail: a structural survivor must reach the ledger as residue, and
/// the note must not claim a replay dropped it.
#[test]
fn verifier_never_reports_pass_while_a_rule_match_survives() {
    // A text where the redactor leaves an ID behind on purpose is hard to build
    // through the public pipeline, so the verifier is called the way the
    // pipeline calls it: on already-redacted text that still holds a rule match.
    let detectors = tier_one_detectors();
    let redacted = "委托人：[PERSON_14BF81AB_1]身份证号：110105199003074512";
    let v = pacgate_redact::verify(
        redacted,
        &detectors,
        pacgate_redact::VerifyScope::default(),
        // The maximally hostile suppressor: the exact one that produced the
        // "noise replay ... dropped" note in the client's ledger.
        |_| true,
    );
    assert!(
        v.verdict.is_block(),
        "a surviving structural identifier must block; notes={:?}",
        v.notes
    );
    assert!(
        v.residue
            .iter()
            .any(|m| m.entity == EntityType::CnResidentId),
        "the survivor must be recorded, not suppressed; residue={:?}",
        v.residue
    );
    assert!(
        !v.notes.iter().any(|n| n.contains("by the same suppressor")),
        "the verifier must no longer excuse itself with the redactor's suppressor: {:?}",
        v.notes
    );
}

/// The ledger must carry the surviving value so a reviewer can act on it.
///
/// `ResidueEntry.text` is deliberate (ledger.rs): the residue is text the
/// redactor failed to remove, so it is already in the output the reviewer holds.
#[test]
fn a_blocked_document_records_which_identifier_survived() {
    let detectors = tier_one_detectors();
    let v = pacgate_redact::verify_raw("残留 110105199003074512", &detectors);
    assert!(v.verdict.is_block());
    assert!(
        v.residue.iter().any(|m| m.text == "110105199003074512"),
        "the residue must name the surviving value; got {:?}",
        v.residue
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Precision: the new rules must not sweep up ordinary contract text.
// ─────────────────────────────────────────────────────────────────────────────

/// Amounts, dates, percentages, contract numbers and case citations must all
/// survive. This is the spec 9 row, re-asserted because five new shape patterns
/// were added.
#[test]
fn the_new_shapes_do_not_touch_ordinary_contract_text() {
    let keep = [
        "借款金额 1,250,000.00 元",
        "年利率 4.35%",
        "期限 2026-01-01 至 2028-12-31",
        "Contract No.PG-2026-0042",
        "Invoice Total USD 18,400.00",
        "参见 (2019)最高法民终1234号",
        "统一社会信用代码是必填项",
    ];
    for text in keep {
        let out = sanitize(text);
        assert_eq!(
            out.text, text,
            "ordinary contract text was altered: {text:?} -> {:?}",
            out.text
        );
        assert!(
            out.ledger.residue.is_empty(),
            "nothing in {text:?} is an identifier, so nothing may survive as residue: {:?}",
            out.ledger.residue
        );
    }
}

/// A six-character province-plus-letters token is not a plate.
#[test]
fn short_latin_tokens_are_not_plates() {
    for text in ["条款 ABC123 适用", "编号 京A12", "版本 v1.2.3"] {
        let found = detected_entities(text);
        assert!(
            !found.contains(&EntityType::VehiclePlate),
            "false positive on {text:?}: {found:?}"
        );
    }
}

/// A 微信号 label followed by ordinary prose is not a handle.
#[test]
fn a_wechat_label_before_prose_is_not_a_handle() {
    let found = detected_entities("微信号是主要联系方式");
    assert!(
        !found.contains(&EntityType::WeChatId),
        "a label followed by prose must not become a handle: {found:?}"
    );
}

/// The redactor's own opaque placeholder must never be re-read as a handle.
///
/// MEASURED 2026-11-02: `[WECHAT_8CA97849_8]` contains the literal text `WECHAT`,
/// so a WeChat rule with a separate label regex matched its own output and the
/// rescan reported an otherwise clean document as leaking a handle. Caught only
/// because the e2e ran the rescan against real stored text.
#[test]
fn a_wechat_placeholder_is_not_re_detected_as_a_handle() {
    for text in [
        "微信：[WECHAT_8CA97849_8]",
        "微信号：[WECHAT_ABC123_1]",
    ] {
        let found = detected_entities(text);
        assert!(
            !found.contains(&EntityType::WeChatId),
            "the redactor's own placeholder must not match its own rule in {text:?}: {found:?}"
        );
    }
}

/// A bank-account label followed by a 6-digit number is not an account: the
/// length window starts at 8 precisely so a date or amount fragment cannot
/// satisfy it.
#[test]
fn a_bank_account_label_before_a_short_number_is_not_an_account() {
    let found = detected_entities("账号 123456");
    assert!(
        !found.contains(&EntityType::BankAccount),
        "a 6-digit run is too short to be an account: {found:?}"
    );
}
