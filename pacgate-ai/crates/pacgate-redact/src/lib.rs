//! pacgate-redact - deterministic detection, redaction and verification.
//!
//! This crate consumes text plus spans. It never opens a file and never
//! calls an OCR service; extraction is a separate capability (design 2).

use serde::{Deserialize, Serialize};

pub mod checksum;
pub mod detect;
pub mod entity;
pub use entity::{EntityType, PlaceholderPolicy, Tier};

/// Errors from detection, redaction or verification.
///
/// `is_fatal` exists so callers can honour the fail-closed rule: anything
/// fatal must become `Verdict::Block`, never `Verdict::Pass`.
#[derive(Debug, thiserror::Error)]
pub enum RedactError {
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("internal error: {0}")]
    Internal(String),
}

impl RedactError {
    /// True when the caller may not proceed to a `Pass` verdict.
    pub fn is_fatal(&self) -> bool {
        matches!(self, RedactError::Internal(_))
    }
}

pub type RedactResult<T> = Result<T, RedactError>;

/// Which mechanism produced a match. Recorded so the verifier can prove it
/// used the same matcher that drove redaction, and so the review panel can
/// show the client *why* something was redacted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchSource {
    /// A structural/checksum validator accepted it. Strongest signal.
    Checksum,
    /// A regex pattern matched, but no checksum was available.
    Pattern,
    /// A pattern plus a label or surrounding context.
    Context,
    /// A local NER model proposed it. Never authoritative on its own.
    Model,
}

/// A detected span. Offsets are byte offsets, half-open `[start, end)`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    pub entity: EntityType,
    pub text: String,
    pub confidence: f32,
    pub source: MatchSource,
}

impl Match {
    pub fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    pub fn is_empty(&self) -> bool {
        self.end <= self.start
    }

    /// True when this match overlaps `other` at all.
    pub fn overlaps(&self, other: &Match) -> bool {
        self.start < other.end && other.start < self.end
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_uses_half_open_byte_offsets() {
        let m = Match {
            start: 0,
            end: 4,
            entity: EntityType::CnMobile,
            text: "1380".to_string(),
            confidence: 1.0,
            source: MatchSource::Checksum,
        };
        assert_eq!(m.len(), 4);
        assert!(!m.is_empty());
    }

    #[test]
    fn error_is_fatal_for_internal_but_not_invalid_input() {
        assert!(!RedactError::InvalidInput("x".into()).is_fatal());
        assert!(RedactError::Internal("x".into()).is_fatal());
    }
}
