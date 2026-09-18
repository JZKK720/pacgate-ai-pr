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