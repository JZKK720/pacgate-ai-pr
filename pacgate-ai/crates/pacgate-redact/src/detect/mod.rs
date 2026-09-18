//! Detection layer. Deterministic rules first; models are additive.

pub mod ner;
pub mod noise;
pub mod rules;

pub use rules::TierOneDetector;

use crate::{Match, RedactResult};

/// A source of candidate matches.
///
/// Implementors must be pure and deterministic: given the same text they
/// return the same matches. The verifier relies on that identity.
pub trait Detector: Send + Sync {
    fn detect(&self, text: &str) -> RedactResult<Vec<Match>>;
    fn name(&self) -> &'static str;
}

/// The Tier-1 detector set used both for redaction and for verification.
pub fn tier_one_detectors() -> Vec<Box<dyn Detector>> {
    vec![Box::new(TierOneDetector::new())]
}

/// Rules + local NER model. Tier-1-only stays available for tests without
/// the model weights; this set is what production redaction runs.
///
/// Fails closed: a missing or incomplete model directory is an error, so a
/// deployment either has the full set or refuses to start redaction.
pub fn full_detectors(model_dir: &str) -> RedactResult<Vec<Box<dyn Detector>>> {
    Ok(vec![
        Box::new(TierOneDetector::new()),
        Box::new(crate::detect::ner::NerDetector::load(model_dir)?),
    ])
}
