//! Maps the existing T1-T4 taxonomy to sanitizer behaviour.
//!
//! The taxonomy is not new: it lives in
//! `pacgate-ai/migrations/004_data_level.sql` and as `DataLevel` in
//! `pacgate-core`. This module only decides what each level is allowed to do,
//! so the design does not duplicate the spine (design section 5).
//!
//! The rule that matters: T4 never auto-passes, even on a clean verification.
//! T4 is 特别敏感资料 - special approval required, strict isolation.

use pacgate_core::DataLevel;

use crate::verify::Verdict;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyDecision {
    /// May the artifact be released without a human looking at it?
    pub allow_auto_pass: bool,
    /// Must a human review before release?
    pub require_human_review: bool,
    /// Why, for the audit record and the review panel.
    pub reason: String,
}

/// Decide what a given data level permits, given a verification verdict.
pub fn decide(level: DataLevel, verdict: Verdict) -> PolicyDecision {
    let blocked = verdict.is_block();

    match level {
        DataLevel::T1SharedTemplate => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T1 (shared template) is already identity-free, but verification found residue, so it is held for review".to_string()
            } else {
                "T1 (shared template) carries no client identity; verification was clean".to_string()
            },
        },
        DataLevel::T2RestrictedSeed => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T2 (restricted seed) has residue after redaction, so it is held for review"
                    .to_string()
            } else {
                "T2 (restricted seed) redacted cleanly; no cross-project search is permitted regardless".to_string()
            },
        },
        DataLevel::T3ProjectSpecific => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T3 (project-specific) has residue after redaction, so it is held for review"
                    .to_string()
            } else {
                "T3 (project-specific) redacted cleanly; matter binding still applies".to_string()
            },
        },
        DataLevel::T4SpecialSensitive => PolicyDecision {
            allow_auto_pass: false,
            require_human_review: true,
            reason: "T4 (special sensitive) never auto-passes: special approval and strict isolation are required".to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Verdict;
    use pacgate_core::DataLevel;

    #[test]
    fn t1_needs_no_identity_work_but_is_still_verified() {
        let d = decide(DataLevel::T1SharedTemplate, Verdict::Pass);
        assert!(d.allow_auto_pass);
        assert!(!d.require_human_review);
    }

    #[test]
    fn t2_may_auto_pass_only_on_a_clean_verdict() {
        assert!(decide(DataLevel::T2RestrictedSeed, Verdict::Pass).allow_auto_pass);
        assert!(!decide(DataLevel::T2RestrictedSeed, Verdict::Block).allow_auto_pass);
    }

    #[test]
    fn t3_may_auto_pass_only_on_a_clean_verdict() {
        assert!(decide(DataLevel::T3ProjectSpecific, Verdict::Pass).allow_auto_pass);
        assert!(decide(DataLevel::T3ProjectSpecific, Verdict::Block).require_human_review);
    }

    #[test]
    fn t4_never_auto_passes_even_when_verification_is_clean() {
        let d = decide(DataLevel::T4SpecialSensitive, Verdict::Pass);
        assert!(!d.allow_auto_pass, "T4 must never auto-pass");
        assert!(d.require_human_review);
    }

    #[test]
    fn a_block_always_requires_human_review_and_never_auto_passes() {
        for level in [
            DataLevel::T1SharedTemplate,
            DataLevel::T2RestrictedSeed,
            DataLevel::T3ProjectSpecific,
            DataLevel::T4SpecialSensitive,
        ] {
            let d = decide(level, Verdict::Block);
            assert!(d.require_human_review, "{level:?} blocked without review");
            assert!(!d.allow_auto_pass, "{level:?} blocked but allowed to auto-pass");
            assert!(!d.reason.is_empty(), "{level:?} blocked with no reason recorded");
        }
    }

    #[test]
    fn every_decision_carries_a_reason() {
        for level in [
            DataLevel::T1SharedTemplate,
            DataLevel::T2RestrictedSeed,
            DataLevel::T3ProjectSpecific,
            DataLevel::T4SpecialSensitive,
        ] {
            assert!(!decide(level, Verdict::Pass).reason.is_empty());
        }
    }
}