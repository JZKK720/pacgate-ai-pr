//! The sanitize entry point: detect, decide, replace, verify, seal.
//!
//! Stage order is contractual (design section 4). DETECT precedes REPLACE and
//! no model is consulted here; VERIFY replays the same detector set that
//! DETECT used.
//!
//! The `Redactor` is held across calls on purpose. A fresh allocator per call
//! would reset the counter and hand the same subject two different
//! placeholders in the same job, which spec 6.1 forbids.

use pacgate_core::DataLevel;

use crate::detect::{noise::NoiseFilter, Detector};
use crate::ledger::RedactionLedger;
use crate::mapping::{JobId, Mapping, MappingVersion};
use crate::policy::{decide, PolicyDecision};
use crate::replace::Redactor;
use crate::verify::verify;
use crate::RedactResult;

pub struct SanitizeOutcome {
    pub job_id: JobId,
    pub text: String,
    pub mapping: Mapping,
    pub ledger: RedactionLedger,
    pub decision: PolicyDecision,
}

pub struct Sanitizer {
    detectors: Vec<Box<dyn Detector>>,
    version: MappingVersion,
    noise: NoiseFilter,
    redactor: Redactor,
}

impl Sanitizer {
    pub fn new(detectors: Vec<Box<dyn Detector>>, version: MappingVersion) -> Self {
        // One Sanitizer = one job (design 3.1 note). The token is random and
        // minted once, so no two Sanitizer instances can ever mint the same
        // placeholder name.
        let job_token = uuid::Uuid::new_v4().simple().to_string()[..8].to_uppercase();
        Self {
            detectors,
            version,
            noise: NoiseFilter::new(),
            // The token is embedded in every placeholder this job mints, so
            // two jobs can never mint the same name (spec 6.2).
            redactor: Redactor::new(&job_token),
        }
    }

    pub fn version(&self) -> MappingVersion {
        self.version
    }

    /// Sanitize one text.
    ///
    /// Returns an outcome whenever the input is readable. Refusals are
    /// expressed as `Verdict::Block` plus `require_human_review` rather than
    /// an `Err`, so the evidence trail is still produced. An `Err` means the
    /// job could not be recorded at all.
    pub fn sanitize(&mut self, text: &str, level: DataLevel) -> RedactResult<SanitizeOutcome> {
        let job_id = JobId::new();

        // DETECT - every detector, deterministic first.
        let mut candidates = Vec::new();
        for d in &self.detectors {
            candidates.extend(d.detect(text)?);
        }

        // Suppress noise and public citations before deciding anything.
        let mut matches = self.noise.apply(text, candidates);
        matches = crate::detect::noise::drop_public_citations(text, matches);

        // DECIDE + REPLACE - the allocator lives on `self`, so it persists
        // across calls within this job.
        let redaction = self.redactor.redact(text, &matches)?;

        // VERIFY - same detector set, replayed against the output.
        let verification = verify(&redaction.text, &self.detectors);

        // Build this job's mapping from the allocator's accumulated state, so
        // documents processed earlier in the job are still restorable.
        let mut mapping = Mapping::new(self.version);
        for (entity, original, placeholder) in self.redactor.allocator().entries() {
            mapping.insert_typed(placeholder, *entity, original);
        }

        let ledger = RedactionLedger::seal(job_id, self.version, text, &redaction, &verification);

        let decision = decide(level, verification.verdict);

        Ok(SanitizeOutcome {
            job_id,
            text: redaction.text,
            mapping,
            ledger,
            decision,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::tier_one_detectors;
    use crate::Verdict;
    use pacgate_core::DataLevel;

    fn sanitizer() -> Sanitizer {
        Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
    }

    #[test]
    fn end_to_end_removes_identifiers_and_passes() {
        let mut s = sanitizer();
        let out = s
            .sanitize(
                "身份证 11010519491231002X 联系 a@b.com",
                DataLevel::T3ProjectSpecific,
            )
            .unwrap();
        assert!(!out.text.contains("11010519491231002X"));
        assert!(!out.text.contains("a@b.com"));
        assert_eq!(out.ledger.verdict(), Verdict::Pass);
        assert!(out.decision.allow_auto_pass);
    }

    #[test]
    fn every_redacted_artifact_is_version_bound() {
        let mut s = sanitizer();
        let out = s.sanitize("a@b.com", DataLevel::T2RestrictedSeed).unwrap();
        assert_eq!(out.mapping.version(), MappingVersion::CURRENT);
        assert_eq!(out.ledger.mapping_version(), MappingVersion::CURRENT);
        assert_eq!(out.ledger.job_id, out.job_id.0.to_string());
    }

    #[test]
    fn t4_never_auto_passes_end_to_end() {
        let mut s = sanitizer();
        let out = s.sanitize("a@b.com", DataLevel::T4SpecialSensitive).unwrap();
        assert!(!out.decision.allow_auto_pass);
    }

    #[test]
    fn the_ledger_never_carries_the_original_value() {
        let mut s = sanitizer();
        let out = s
            .sanitize("秘密 11010519491231002X", DataLevel::T3ProjectSpecific)
            .unwrap();
        let json = out.ledger.to_json().unwrap();
        assert!(!json.contains("11010519491231002X"));
    }

    #[test]
    fn jobs_are_isolated_from_each_other() {
        // Two separate Sanitizer instances model two jobs on two matters.
        // The job token embedded in each placeholder makes cross-resolution
        // structurally impossible, not just discouraged (spec 6.2).
        let mut job1 = sanitizer();
        let mut job2 = sanitizer();
        let a = job1.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let b = job2.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        assert_ne!(a.job_id, b.job_id);
        let err = b
            .mapping
            .restore(&a.text, a.mapping.version())
            .expect_err("job b must not resolve job a's text");
        assert!(
            err.to_string().contains("unknown placeholder"),
            "cross-job resolution must be refused: {err}"
        );
    }

    #[test]
    fn one_job_spans_documents_and_stays_consistent() {
        // WITHIN one job, the same value must cross-resolve - that is 6.1
        // consistency. This is the complement of the isolation test above.
        let mut s = sanitizer();
        let a = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let b = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        assert_ne!(a.job_id, b.job_id);
        let restored = b
            .mapping
            .restore(&a.text, a.mapping.version())
            .expect("within one job, the mapping must cross-resolve");
        assert_eq!(restored, "a@b.com");
    }

    #[test]
    fn restore_round_trips_within_one_job() {
        let mut s = sanitizer();
        let out = s
            .sanitize("联系电话 a@b.com 已确认", DataLevel::T3ProjectSpecific)
            .unwrap();
        let restored = out
            .mapping
            .restore(&out.text, out.mapping.version())
            .unwrap();
        assert_eq!(restored, "联系电话 a@b.com 已确认");
    }

    #[test]
    fn a_job_that_cannot_certify_safety_blocks_and_holds_for_review() {
        let mut s = Sanitizer::new(Vec::new(), MappingVersion::CURRENT);
        let out = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        assert_eq!(out.ledger.verdict(), Verdict::Block);
        assert!(out.decision.require_human_review);
        assert!(!out.decision.allow_auto_pass);
    }

    #[test]
    fn one_sanitizer_keeps_placeholders_consistent_across_calls() {
        // One Sanitizer models one job spanning several documents.
        let mut s = sanitizer();
        let a = s.sanitize("联系人 a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let b = s.sanitize("再次联系 a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let pa = a.text.replace("联系人 ", "");
        let pb = b.text.replace("再次联系 ", "");
        assert_eq!(
            pa.trim(),
            pb.trim(),
            "the same subject must map to the same placeholder across documents"
        );
    }
}