//! Detection layer. Deterministic rules first; models are additive.

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