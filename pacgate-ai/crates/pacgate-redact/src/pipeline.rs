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
use crate::placeholder::TokenKey;
use crate::policy::{decide, PolicyDecision};
use crate::replace::Redactor;
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
        // A fresh random key. The token is minted once per sanitizer, so no two
        // Sanitizer instances can mint the same tag for the same value - which is
        // the isolation spec 6.2 asks for.
        //
        // This constructor is the one-shot path: one document, one process, no
        // correlation wanted or possible. A caller that needs a matter's documents
        // to agree on a subject's token must use `with_key` and pass the same key
        // for every document in the matter - a per-job random key reproduces the
        // 2026-11-03 defect (same person, token per document, corpus unjoinable).
        Self::with_key(detectors, version, TokenKey::random())
    }

    /// Build a sanitizer whose tokens are derived from `key`.
    ///
    /// The key is the MATTER's. Every document in a matter must be sanitized with
    /// the same key, or two documents holding the same person will not agree on a
    /// token and the corpus cannot be joined on the identifier.
    ///
    /// Two matters must use different keys: that is what stops their corpora
    /// being joined on a person if the data is ever merged.
    pub fn with_key(
        detectors: Vec<Box<dyn Detector>>,
        version: MappingVersion,
        key: TokenKey,
    ) -> Self {
        Self {
            detectors,
            version,
            noise: NoiseFilter::new(),
            redactor: Redactor::new(key),
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

        // Suppress noise, public citations, and public entities before deciding
        // anything. `drop_public_entities` must run HERE as well as in the
        // verifier: if the redactor removes a regulator's name but the verifier
        // still counts it as residue, the document blocks on a span the
        // redactor was right to leave alone. Both sides must agree on what is
        // deliberate, which is the same rule `drop_public_citations` follows.
        let mut matches = self.noise.apply(text, candidates);
        matches = crate::detect::noise::drop_public_citations(text, matches);
        matches = crate::detect::noise::drop_public_entities(text, matches);

        // DECIDE + REPLACE - the allocator lives on `self`, so it persists
        // across calls within this job.
        let redaction = self.redactor.redact(text, &matches)?;

        // VERIFY - same detector set, replayed against the output.
        //
        // The verifier is given exactly two things, and neither of them lets
        // the redactor excuse itself:
        //
        //   1. The spans the redactor itself just wrote. A format-preserving
        //      placeholder re-fires its own detector (a card
        //      4111111111111111 -> 0000000000000018 is Luhn-VALID by
        //      construction, see placeholder.rs), so those spans are excluded
        //      mechanically. Measured 2026-10-08: the compliance prompts guide
        //      held for review with 191 clean replacements for this shape.
        //   2. The MODEL-ONLY suppressor. A model span is a guess, and dropping
        //      a guess on the way out is a deliberate decision, recorded in the
        //      notes. `is_suppressible_model_match` returns false for every
        //      non-model source, so it cannot reach a rule match.
        //
        // What the verifier is NO LONGER given is `drop_public_entities` over
        // the RULE layer. Until 2026-11-02 the whole residue was re-suppressed
        // with the same function the redaction used, which meant a suppressor
        // that missed a survivor on the way in necessarily missed it on the way
        // out - so `pass` was reported while eight identifier classes remained
        // verbatim in text that was then indexed as searchable (measured on the
        // client scan: 13 replacements, `verdict: pass`, resident ID still
        // present and usable as a lookup key).
        //
        // COORDINATES: `AppliedRedaction.start/end` are offsets in the INPUT
        // text, but the replay searches the OUTPUT text. Using them directly
        // only works when no earlier redaction changed the length - with one
        // replacement the offsets coincide, which is why the original
        // single-card test passed. So the spans are rebuilt in OUTPUT
        // coordinates by walking the same splice `redact` performed.
        let placeholder_spans: Vec<(usize, usize)> = {
            let mut spans = Vec::new();
            let mut cursor_in = 0usize;
            let mut cursor_out = 0usize;
            for a in &redaction.applied {
                // Text copied verbatim between the previous span and this one.
                cursor_out += a.start.saturating_sub(cursor_in);
                cursor_in = a.end;
                if a.entity.policy() == crate::entity::PlaceholderPolicy::Remove {
                    // Nothing is written, so the output does not advance.
                    continue;
                }
                let len = a.placeholder.len();
                spans.push((cursor_out, cursor_out + len));
                cursor_out += len;
            }
            spans
        };
        let verification = crate::verify::verify(
            &redaction.text,
            &self.detectors,
            crate::verify::VerifyScope {
                placeholders: &placeholder_spans,
            },
            crate::detect::noise::is_suppressible_model_match,
        );

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

    /// Regression for the 2026-10-08 phantom-block, both measured sources:
    ///   1. A format-preserving placeholder re-fires its own detector: card
    ///      4111111111111111 redacts to 0000000000000018, which is Luhn-VALID
    ///      by construction, so the raw replay found a "surviving card" and
    ///      blocked a single-card sentence (`verdict=block, redactions=1`,
    ///      measured on the live API). The compliance prompts guide held for
    ///      review with 191 clean replacements on every run for this shape.
    ///   2. Candidates the NoiseFilter dropped (inner overlap, public
    ///      citation) stay in the text on purpose; the raw replay re-found
    ///      them as residue.
    ///
    /// The verify replay must therefore ignore spans the redactor itself
    /// minted, and apply the same noise reduction, while still blocking on a
    /// REAL survivor.
    #[test]
    fn a_clean_redaction_is_not_blocked_by_its_own_placeholders() {
        // Single Luhn-valid card: the placeholder is guaranteed valid-Luhn,
        // so the raw replay would re-detect it and the pre-fix pipeline
        // returned Block. Post-fix, the minted span is excluded and this is
        // a clean pass.
        let text = "卡号 4111111111111111 已核";
        let mut s = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
        let out = s.sanitize(text, DataLevel::T3ProjectSpecific).unwrap();

        assert!(
            !out.text.contains("4111111111111111"),
            "the card must be redacted; got {:?}",
            out.text
        );
        assert_eq!(out.ledger.verdict(), Verdict::Pass, "placeholder self-must not block");
        assert!(out.decision.allow_auto_pass);
        assert!(!out.decision.require_human_review);
    }

    /// The placeholder-span exclusion must survive a redaction that CHANGES
    /// LENGTH before the placeholder.
    ///
    /// `AppliedRedaction.start/end` are offsets in the ORIGINAL text, but the
    /// verify replay searches the OUTPUT text. When an earlier redaction
    /// shortens or lengthens the text, every later placeholder's original
    /// offset no longer points at it, the exclusion misses, and the
    /// format-preserving placeholder re-fires its own detector as residue.
    ///
    /// Measured on the live stack 2026-10-25: `e2e_audit` held for review with
    /// `residue=[BankCard "000000000000000026"]` - the redactor's own
    /// placeholder for `110101199003072316`, shifted by the CN_MOBILE
    /// placeholder written before it. The single-redaction test above passes
    /// because with one replacement the offsets coincide.
    #[test]
    fn a_placeholder_is_not_residue_when_an_earlier_redaction_shifts_it() {
        // Phone first (its placeholder is longer than the original), then a
        // Luhn-valid card. The card's placeholder lands at a different offset
        // in the output than the card did in the input.
        let text = "联系电话 13800138000 卡号 4111111111111111 已核";
        let mut s = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
        let out = s.sanitize(text, DataLevel::T3ProjectSpecific).unwrap();

        assert!(
            !out.text.contains("4111111111111111"),
            "the card must be redacted; got {:?}",
            out.text
        );
        assert!(
            !out.text.contains("13800138000"),
            "the phone must be redacted; got {:?}",
            out.text
        );
        assert!(
            out.ledger.residue.is_empty(),
            "a shifted placeholder is not residue; got {:?}",
            out.ledger.residue
        );
        assert_eq!(
            out.ledger.verdict(),
            Verdict::Pass,
            "a shifted placeholder must not block; residue={:?}",
            out.ledger.residue
        );
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