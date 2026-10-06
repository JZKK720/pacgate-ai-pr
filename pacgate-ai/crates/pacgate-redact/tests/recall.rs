//! Per-tier recall reporting (spec section 9: 不能相互替代).
//!
//! Rule-layer row  : Tier-1 fixtures caught by rules only.
//! Model-layer row : Tier-2 fixtures (person/org names) caught by NER.
//! These are separate assertions on purpose - one does not substitute the
//! other. The model row skips loudly when the weights are absent so CI
//! without the 400MB bundle stays green (plan 019 T7 contract).

use pacgate_redact::detect::{full_detectors, tier_one_detectors};
use pacgate_redact::{EntityType, MappingVersion, Sanitizer};

fn run(detectors: Vec<Box<dyn pacgate_redact::detect::Detector>>, text: &str) -> String {
    Sanitizer::new(detectors, MappingVersion::CURRENT)
        .sanitize(text, pacgate_core::DataLevel::T3ProjectSpecific)
        .expect("sanitize must not fail on synthetic fixtures")
        .text
}

/// Tier-1 fixtures caught by the rules alone. No model required - these
/// patterns carry their own checksum/context validation (plan 017).
#[test]
fn rule_layer_tier_one_recall() {
    let fixtures = [
        ("11010519491231002X", EntityType::CnResidentId),
        ("13812345678", EntityType::CnMobile),
        ("4111111111111111", EntityType::BankCard),
        ("a@b.com", EntityType::Email),
    ];
    for (value, entity) in fixtures {
        let out = run(tier_one_detectors(), value);
        assert!(
            !out.contains(value),
            "Tier-1 miss ({entity:?}): {value} survives sanitization"
        );
    }
}

/// The forms Chinese contracts actually contain: a label immediately followed by
/// the identifier, with no separating space. This row would have failed before
/// the boundary fix - all four adjacent forms returned zero matches.
///
/// Kept as its own row rather than folded into `rule_layer_tier_one_recall`
/// because it is a different claim: that row proves the checksums work, this one
/// proves the boundaries do.
#[test]
fn rule_layer_cjk_adjacency() {
    let fixtures = [
        ("身份证11010519491231002X", "11010519491231002X"),
        ("代码91350100M000100Y43", "91350100M000100Y43"),
        ("手机13812345678", "13812345678"),
        ("卡号4111111111111111", "4111111111111111"),
        // Trailing CJK, which `[^\w]` would have rejected.
        ("手机13812345678号", "13812345678"),
    ];
    for (text, value) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(value),
            "adjacency miss: {value} survives sanitization in {text}"
        );
    }
}

/// Grouped and full-width identifiers. Grouping is how these numbers are
/// actually printed on cards and in contracts, so an ungrouped-only detector
/// missed the normal case in the same four classes the adjacency row targets.
///
/// The assertion is on the DIGITS being absent, not on the exact original
/// string: a format-preserving placeholder deliberately keeps a same-shaped
/// value, so the grouped original may legitimately not appear verbatim. What
/// must never survive is the identifier's actual digits.
#[test]
fn rule_layer_grouped_and_full_width_forms() {
    // (input, the digits that must not survive)
    let fixtures = [
        ("卡号4111 1111 1111 1111", "4111 1111"),
        ("卡号4111-1111-1111-1111", "4111-1111"),
        ("身份证110105 19491231 002X", "19491231"),
        ("手机138 1234 5678", "138 1234"),
        ("卡号４１１１１１１１１１１１１１１１", "４１１１"),
        ("身份证１１０１０５１９４９１２３１００２Ｘ", "１９４９１２３１"),
    ];
    for (text, marker) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(marker),
            "grouped/full-width miss: '{marker}' survives sanitization in {text}: {out}"
        );
    }
}

/// Guard against the two false positives the normalised path introduced and that
/// were caught by probing, not by review. Both are 12-digit runs whose leading
/// digits do not form a real area code.
#[test]
fn rule_layer_landline_false_positives_stay_rejected() {
    for text in ["编号020123456789", "编号010123456789"] {
        let out = run(tier_one_detectors(), text);
        assert!(
            out.contains(text),
            "false positive: {text} was altered by sanitization: {out}"
        );
    }
}

/// The two classes added in step 1, sanitized end-to-end rather than only
/// detected. This is the row that reports step 1 as delivered.
#[test]
fn rule_layer_step_one_classes() {
    let fixtures = [
        ("座机010-12345678", "010-12345678", EntityType::Landline),
        ("座机01012345678", "01012345678", EntityType::Landline),
        ("服务器192.168.1.1", "192.168.1.1", EntityType::IpAddress),
    ];
    for (text, value, entity) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(value),
            "step-1 miss ({entity:?}): {value} survives sanitization in {text}"
        );
    }
}

/// The R1 extension set (2026-10-06): passport, HK/MO permit, labelled
/// Taiwan permit and labelled legacy 15-digit ID, sanitized end-to-end. The
/// claim this row reports is the same as `rule_layer_step_one_classes`' -
/// that the full pipeline (detect -> redact -> verify) removes these too,
/// not just that the unit detector saw them.
#[test]
fn rule_layer_r1_cross_jurisdiction_ids() {
    let fixtures = [
        ("护照EA1234567 已核验", "EA1234567"),
        ("护照E12345678 (旧版)", "E12345678"),
        ("回乡证H1234567800", "H1234567800"),
        ("台胞证12345678", "12345678"),
        ("旧身份证130503670401001", "130503670401001"),
        ("律师执业证号11101201810123456", "11101201810123456"),
    ];
    for (text, value) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(value),
            "R1 miss: '{value}' survives sanitization in '{text}': {out}"
        );
    }
}

/// R1 precision guard: the shapes these new rules anchor on must not fire on
/// unrelated token-adjacent runs, or the extension becomes a precision
/// regression. `E级12345` is the trap found while developing the rule -
/// `E` + a 6-digit run does NOT reach the 7/8-digit passport minimum.
#[test]
fn rule_layer_r1_false_positives_stay_rejected() {
    let keep = [
        "E级12345 甲",           // not a passport shape
        "护照EI1234567",         // I excluded from the second letter
        "护照EO1234567",         // O excluded from the second letter
        "AH1234567800",          // permit inside a longer token
        "编号130503670401001",    // legacy shape without a label
        "合同12345678 中",        // permit shape without a label
    ];
    for text in keep {
        let out = run(tier_one_detectors(), text);
        assert!(
            out.contains(text),
            "false positive: '{text}' was altered by sanitization: {out}"
        );
    }
}

/// A document longer than one BERT window must sanitize, with a name that sits
/// PAST the first window redacted.
///
/// Before windowed inference this call returned an error, and `pipeline.rs:68`
/// propagates detector errors - so the ENTIRE job failed and the document could
/// not be sanitized at all. Not a degraded result: no result.
#[test]
fn model_layer_long_document() {
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!("SKIP model_layer_long_document: PACGATE_NER_MODEL_DIR not set or missing");
        return;
    }

    // Filler pushes the interesting name well past the first window.
    let filler = "本所同意上述条款并遵照执行。".repeat(120);
    let text = format!("{filler}张伟是本案的委托代理人。");
    let detectors = full_detectors(&model_dir).expect("model dir present; load must succeed");
    let out = run(detectors, &text);
    assert!(
        out.len() > 1000,
        "the document must survive sanitization intact in length; got {} bytes",
        out.len()
    );
    assert!(
        !out.contains("张伟"),
        "a name past the first window survived sanitization (windowed inference broken)"
    );
}

/// A name straddling a window boundary must come out as ONE span, not two
/// fragments. Spec 7 lists this as an explicit test.
#[test]
fn model_layer_boundary_straddling_name() {
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!(
            "SKIP model_layer_boundary_straddling_name: PACGATE_NER_MODEL_DIR not set or missing"
        );
        return;
    }

    // Place a name so it likely sits across a planned boundary, then assert the
    // name is gone entirely - a partially-redacted name is the failure this row
    // exists to catch.
    let filler = "本所同意上述条款并遵照执行。".repeat(60);
    let text = format!("{filler}华信律师事务所位于北京市朝阳区。{filler}");
    let detectors = full_detectors(&model_dir).expect("model dir present; load must succeed");
    let out = run(detectors, &text);
    assert!(
        !out.contains("华信律师事务所"),
        "a boundary-straddling org name survived sanitization"
    );
}

/// Tier-2 candidates: person/org/location names that only the model layer
/// can see. Skips when PACGATE_NER_MODEL_DIR is unset or the directory is
/// missing - the skip prints loudly so the coverage gap is visible, and the
/// assertion only runs when the weights are actually present.
#[test]
fn model_layer_tier_two_recall() {
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!(
            "SKIP model_layer_tier_two_recall: PACGATE_NER_MODEL_DIR not set or missing"
        );
        return;
    }

    // With the model: the full detector set must catch a person name and an
    // organization name in a synthetic sentence.
    let fixtures = [
        ("张伟是本案的委托代理人。", "张伟"),
        ("华信律师事务所位于北京市朝阳区。", "华信律师事务所"),
    ];
    for (sentence, name) in fixtures {
        let out = run(full_detectors(&model_dir).expect("model dir present; load must succeed"), sentence);
        assert!(
            !out.contains(name),
            "Tier-2 miss: person/org name '{name}' survives sanitization in {sentence}"
        );
    }
}