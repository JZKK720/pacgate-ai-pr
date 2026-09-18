//! Independent outbound verification.
//!
//! The client spec 8.6 requires that a failed check stops the outbound send,
//! and that the model may not self-approve. Three independent precedents
//! converge on the same mechanism, adopted here:
//!
//!   "Since the residual check uses the same matcher that drove redaction, a
//!    detected credential cannot pass." (microsoft/agent-governance-toolkit)
//!   "Fail closed. If anything goes wrong - unparseable output, a parsing
//!    error, an exception, invalid encoding - the item is treated as BLOCK,
//!    never PASS." (leak-inspect-v1)
//!
//! Consequently: no error path in this module yields `Pass`.

use serde::{Deserialize, Serialize};

use crate::detect::Detector;
use crate::Match;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Pass,
    Block,
}

impl Verdict {
    pub fn is_block(&self) -> bool {
        matches!(self, Verdict::Block)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Verification {
    pub verdict: Verdict,
    /// What survived. Surfaced to the review panel, never auto-cleared.
    pub residue: Vec<Match>,
    /// Why the verdict was reached, for the audit record.
    pub notes: Vec<String>,
}

/// Re-scan `redacted` with the same detector set used to redact it.
///
/// Returns `Block` when: any detector reports a surviving match, any detector
/// errors, or the detector set is empty (we would be asserting safety with no
/// evidence).
pub fn verify(redacted: &str, detectors: &[Box<dyn Detector>]) -> Verification {
    let mut notes: Vec<String> = Vec::new();

    if detectors.is_empty() {
        notes.push(
            "no detectors supplied: cannot assert safety, so the verdict is Block (fail closed)"
                .to_string(),
        );
        return Verification {
            verdict: Verdict::Block,
            residue: Vec::new(),
            notes,
        };
    }

    let mut residue: Vec<Match> = Vec::new();

    for d in detectors {
        match d.detect(redacted) {
            Ok(found) => {
                if !found.is_empty() {
                    notes.push(format!("{}: {} surviving match(es)", d.name(), found.len()));
                    residue.extend(found);
                }
            }
            Err(e) => {
                notes.push(format!("{}: detector failed ({e}) - blocking", d.name()));
                return Verification {
                    verdict: Verdict::Block,
                    residue,
                    notes,
                };
            }
        }
    }

    let verdict = if residue.is_empty() {
        notes.push(format!(
            "{} detector(s) reported no residue",
            detectors.len()
        ));
        Verdict::Pass
    } else {
        Verdict::Block
    };

    residue.sort_by_key(|m| (m.start, m.end));

    Verification {
        verdict,
        residue,
        notes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::tier_one_detectors;

    #[test]
    fn clean_text_passes() {
        let v = verify("本所同意上述条款。", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Pass);
        assert!(v.residue.is_empty());
    }

    #[test]
    fn a_surviving_resident_id_blocks() {
        let v = verify("残留 11010519491231002X", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Block);
        assert_eq!(v.residue.len(), 1);
    }

    #[test]
    fn a_surviving_email_blocks() {
        let v = verify("残留 a@b.com", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn placeholder_shaped_residue_beside_real_data_blocks() {
        // The SANITIZATION_RESIDUE pattern: a header scrubbed while the body
        // was not.
        let v = verify("[CN_ID_1] 但 11010519491231002X 仍在", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn an_empty_detector_set_blocks_rather_than_passing() {
        // Fail closed: with nothing to check against we cannot assert safety.
        let v = verify("anything", &[]);
        assert!(v.verdict.is_block());
        assert!(!v.notes.is_empty());
    }

    #[test]
    fn verdict_is_block_when_a_detector_errors() {
        struct Exploding;
        impl Detector for Exploding {
            fn detect(&self, _t: &str) -> crate::RedactResult<Vec<crate::Match>> {
                Err(crate::RedactError::Internal("boom".into()))
            }
            fn name(&self) -> &'static str {
                "exploding"
            }
        }
        let v = verify("text", &[Box::new(Exploding)]);
        assert_eq!(v.verdict, Verdict::Block);
    }

    #[test]
    fn notes_record_how_the_verdict_was_reached() {
        let v = verify("a@b.com", &tier_one_detectors());
        assert!(!v.notes.is_empty(), "the audit record needs a reason");
    }
}