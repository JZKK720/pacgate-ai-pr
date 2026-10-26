//! Cryptographic provenance for one sanitization job.
//!
//! Pattern adapted from Philter's redaction ledger and the NIST SP 800-88
//! approach to documenting a transformation: record *that* a transformation
//! happened and *what* it produced, without retaining the pre-transformation
//! content in the record itself.
//!
//! The ledger therefore stores digests only. The originals live in the vault
//! (`pacgate-api`), never here, and never in deer-flow.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::mapping::{JobId, MappingVersion};
use crate::replace::Redaction;
use crate::verify::{Verdict, Verification};
use crate::RedactResult;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedactionLedger {
    pub job_id: String,
    pub mapping_version: u32,
    pub input_sha256: String,
    pub output_sha256: String,
    pub redaction_count: usize,
    pub verdict: Verdict,
    /// Rule and mapping version, so a later rule change cannot silently
    /// re-interpret history (spec 6.3, 8.8, 9 acceptance).
    pub ruleset_version: String,
    pub model_version: Option<String>,
    /// What survived redaction, when the verdict is `Block`.
    ///
    /// `Verification::residue` is documented as "Surfaced to the review panel,
    /// never auto-cleared" - but until 2026-10-24 it was surfaced nowhere. The
    /// ledger recorded `verdict: "block"` and dropped the evidence, so a
    /// reviewer saw a refusal with no reason and the only way to clear it was
    /// to reset the row in Postgres by hand.
    ///
    /// Measured on the Firm KB ingest: 5 of 13 documents blocked, 284 chunks
    /// left unsearchable, and nothing in the record said which entity or which
    /// surviving text caused it.
    ///
    /// Empty on a pass, so a clean ledger is byte-identical to before.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub residue: Vec<ResidueEntry>,
    /// The verifier's own explanation of the verdict.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub verification_notes: Vec<String>,
}

/// One surviving match, as recorded in the ledger.
///
/// Deliberately carries the surviving TEXT. The ledger's header says it stores
/// "digests only ... without retaining the pre-transformation content", and that
/// rule exists so the ledger cannot become a second copy of the client data.
/// A residue entry is the opposite case: it is text the redactor FAILED to
/// remove, so it is already present in the output the reviewer is holding. Not
/// recording it protects nothing and makes the block unactionable.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ResidueEntry {
    pub entity: String,
    pub text: String,
    pub start: usize,
    pub end: usize,
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex_encode(&hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

impl RedactionLedger {
    pub fn seal(
        job_id: JobId,
        version: MappingVersion,
        input: &str,
        redaction: &Redaction,
        verification: &Verification,
    ) -> Self {
        Self {
            job_id: job_id.0.to_string(),
            mapping_version: version.0,
            input_sha256: sha256_hex(input),
            output_sha256: sha256_hex(&redaction.text),
            redaction_count: redaction.applied.len(),
            verdict: verification.verdict,
            ruleset_version: env!("CARGO_PKG_VERSION").to_string(),
            model_version: None,
            residue: verification
                .residue
                .iter()
                .map(|m| ResidueEntry {
                    entity: format!("{:?}", m.entity),
                    text: m.text.clone(),
                    start: m.start,
                    end: m.end,
                })
                .collect(),
            verification_notes: verification.notes.clone(),
        }
    }

    pub fn input_sha256(&self) -> &str {
        &self.input_sha256
    }

    pub fn output_sha256(&self) -> &str {
        &self.output_sha256
    }

    pub fn verdict(&self) -> Verdict {
        self.verdict
    }

    pub fn mapping_version(&self) -> MappingVersion {
        MappingVersion(self.mapping_version)
    }

    pub fn to_json(&self) -> RedactResult<String> {
        serde_json::to_string(self)
            .map_err(|e| crate::RedactError::Internal(format!("ledger serialisation failed: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JobId, MappingVersion, Redaction, Verdict, Verification};

    fn redaction(text: &str) -> Redaction {
        Redaction {
            text: text.to_string(),
            applied: Vec::new(),
        }
    }

    fn verification(v: Verdict) -> Verification {
        Verification {
            verdict: v,
            residue: Vec::new(),
            notes: Vec::new(),
        }
    }

    #[test]
    fn seals_digests_of_both_sides() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "原始 张三",
            &redaction("原始 [PERSON_1]"),
            &verification(Verdict::Pass),
        );
        assert_eq!(l.input_sha256().len(), 64);
        assert_eq!(l.output_sha256().len(), 64);
        assert_ne!(l.input_sha256(), l.output_sha256());
    }

    #[test]
    fn digests_are_deterministic() {
        let a = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        let b = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        assert_eq!(a.input_sha256(), b.input_sha256());
        assert_eq!(a.output_sha256(), b.output_sha256());
    }

    #[test]
    fn records_the_verdict_and_version() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion(7),
            "x",
            &redaction("y"),
            &verification(Verdict::Block),
        );
        assert_eq!(l.verdict(), Verdict::Block);
        assert_eq!(l.mapping_version(), MappingVersion(7));
    }

    #[test]
    fn serialises_to_json_without_the_originals() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "secret 张三",
            &redaction("secret [PERSON_1]"),
            &verification(Verdict::Pass),
        );
        let json = l.to_json().unwrap();
        assert!(
            !json.contains("张三"),
            "the ledger must not carry pre-redaction content"
        );
        assert!(json.contains("input_sha256"));
    }

    #[test]
    fn ledger_round_trips_through_json() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        let json = l.to_json().unwrap();
        let back: RedactionLedger = serde_json::from_str(&json).unwrap();
        assert_eq!(back.output_sha256(), l.output_sha256());
    }

    #[test]
    fn records_the_ruleset_version_so_history_is_not_silently_reinterpreted() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        assert!(!l.ruleset_version.is_empty());
    }
}
    #[test]
    fn a_block_ledger_records_why_it_blocked() {
        // Measured 2026-10-24: five of thirteen firm documents came back
        // `verdict: block` and the reviewer had NOTHING to act on. The ledger
        // carried only `verdict: "block"`; the residue that caused it - which
        // entity, which surviving text, at which offset - was computed by
        // `verify_reduced` and then dropped on the floor.
        //
        // `Verification::residue` is documented as "Surfaced to the review
        // panel, never auto-cleared". It was not surfaced anywhere. A block
        // with no reason is indistinguishable from a bug, and the only way to
        // clear it was to reset the row in Postgres by hand.
        let v = Verification {
            verdict: Verdict::Block,
            residue: vec![crate::Match {
                start: 10,
                end: 28,
                entity: crate::EntityType::CnResidentId,
                text: "11010519491231002X".to_string(),
                confidence: 0.99,
                source: crate::MatchSource::Pattern,
            }],
            notes: vec!["tier-one: 1 surviving match(es)".to_string()],
        };
        let r = Redaction {
            text: "残留 11010519491231002X".to_string(),
            applied: Vec::new(),
        };
        let l = RedactionLedger::seal(JobId::new(), MappingVersion(1), "in", &r, &v);

        let json = l.to_json().expect("serialise");
        assert!(
            json.contains("residue"),
            "a block ledger must record the residue that caused it, got: {json}"
        );
        assert!(
            json.contains("CnResidentId"),
            "the residue must name the entity type, got: {json}"
        );
        assert!(
            json.contains("surviving match"),
            "the residue must carry the verifier's notes, got: {json}"
        );
    }
