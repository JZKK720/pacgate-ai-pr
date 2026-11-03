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
//!
//! ## Independence, and the circularity that broke it
//!
//! Until 2026-11-02 this module replayed the redactor's own suppressor over
//! the residue before deciding:
//!
//! ```text
//! "tier1-rules: 1 surviving match(es)"
//! "noise replay: 1 of 1 surviving matches dropped by the same suppressor the redaction used"
//! ```
//!
//! The verdict was `Pass`. That is circular: a suppressor that misses a
//! survivor on the way in necessarily misses the same survivor on the way out,
//! so a `Pass` produced by replaying it proves nothing about the text. Measured
//! consequence on the client scan of 2026-11-02: `verdict: pass`, 13
//! replacements, and eight identifier classes - 身份证号, 统一社会信用代码,
//! 律师执业证号, 银行账号, 港澳通行证, 车牌, 微信号, 纳税人识别号 - left
//! verbatim in text that was then indexed as searchable. A resident ID in the
//! vector store could be used as a lookup key, and the document carried the
//! `sanitized` label, so downstream treated it as clean.
//!
//! The fix is a split by EVIDENCE, not by convenience:
//!
//!   * A rule match (checksum, shape, label) is structural. A suppressor must
//!     never remove one here: if the redactor found it and left it in the
//!     output, that is a leak and only the minted-placeholder exclusion may
//!     explain it. Any other explanation is the redactor excusing itself.
//!   * A model match is a guess. Suppressing a guess on the way out is a
//!     deliberate decision (`noise::MIN_MODEL_CONFIDENCE`, public entities),
//!     and it can only ever fail to block on a name - never on a number.
//!
//! So the circularity is confined to the one class where it cannot hide a
//! structural identifier, and it is recorded in `notes` rather than silently
//! swallowed.

use serde::{Deserialize, Serialize};

use crate::detect::Detector;
use crate::{Match, MatchSource};

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

/// Where the redactor wrote its own placeholders, in OUTPUT coordinates.
///
/// A match entirely inside one of these spans is the redactor's own token
/// re-firing its detector, not a survivor. This is the ONLY exclusion the
/// verifier grants the redactor, and it is mechanical: the span list is a
/// by-product of the splice, not a judgement.
#[derive(Debug, Clone, Copy, Default)]
pub struct VerifyScope<'a> {
    pub placeholders: &'a [(usize, usize)],
}

impl VerifyScope<'_> {
    fn inside_placeholder(&self, m: &Match) -> bool {
        self.placeholders
            .iter()
            .any(|(s, e)| m.start >= *s && m.end <= *e)
    }
}

/// Re-scan `redacted` with the same detector set used to redact it, and block
/// on any structural survivor.
///
/// `suppress_model` is applied ONLY to `MatchSource::Model` spans. Passing the
/// redaction's own suppressor here is safe precisely because it cannot reach a
/// rule match - see the module docs. Passing `|_| false` disables model
/// suppression entirely (strictest).
///
/// Returns `Block` when: any detector reports a surviving structural match, any
/// detector errors, or the detector set is empty (we would be asserting safety
/// with no evidence).
pub fn verify(
    redacted: &str,
    detectors: &[Box<dyn Detector>],
    scope: VerifyScope<'_>,
    suppress_model: impl Fn(&Match) -> bool,
) -> Verification {
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

    let mut structural: Vec<Match> = Vec::new();
    let mut model_kept: Vec<Match> = Vec::new();
    let mut model_dropped = 0usize;

    for d in detectors {
        match d.detect(redacted) {
            Ok(found) => {
                for m in found.into_iter().filter(|m| !scope.inside_placeholder(m)) {
                    match m.source {
                        // Structural evidence: never suppressed here.
                        MatchSource::Checksum
                        | MatchSource::Pattern
                        | MatchSource::Context => structural.push(m),
                        MatchSource::Model => {
                            if suppress_model(&m) {
                                model_dropped += 1;
                            } else {
                                model_kept.push(m);
                            }
                        }
                    }
                }
            }
            Err(e) => {
                notes.push(format!("{}: detector failed ({e}) - blocking", d.name()));
                return Verification {
                    verdict: Verdict::Block,
                    residue: structural,
                    notes,
                };
            }
        }
    }

    if !structural.is_empty() {
        notes.push(format!(
            "{}: {} surviving structural match(es) - a rule the redactor found and left in place",
            detectors
                .iter()
                .map(|d| d.name())
                .collect::<Vec<_>>()
                .join("+"),
            structural.len()
        ));
    }

    if !model_kept.is_empty() {
        notes.push(format!(
            "model layer: {} surviving model match(es)",
            model_kept.len()
        ));
    }
    if model_dropped > 0 {
        // Recorded, not swallowed: an operator reading the ledger must be able
        // to see that the model layer disagreed and the suppressor won.
        notes.push(format!(
            "model gate: {model_dropped} surviving model match(es) dropped by the shared public-entity / confidence suppressor; not evidence of a leak, but also not proof of cleanliness"
        ));
    }

    let mut residue: Vec<Match> = structural;
    residue.extend(model_kept);
    residue.sort_by_key(|m| (m.start, m.end));

    let verdict = if residue.is_empty() {
        if model_dropped == 0 {
            notes.push(format!(
                "{} detector(s) reported no residue",
                detectors.len()
            ));
        }
        Verdict::Pass
    } else {
        Verdict::Block
    };

    Verification {
        verdict,
        residue,
        notes,
    }
}

/// `verify` for a text with no redactor placeholders (a pure audit pass).
///
/// Strictest form: no exclusion, no model suppression.
pub fn verify_raw(redacted: &str, detectors: &[Box<dyn Detector>]) -> Verification {
    verify(redacted, detectors, VerifyScope::default(), |_| false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::tier_one_detectors;
    use crate::{EntityType, MatchSource};

    #[test]
    fn clean_text_passes() {
        let v = verify_raw("本所同意上述条款。", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Pass);
        assert!(v.residue.is_empty());
    }

    #[test]
    fn a_surviving_resident_id_blocks() {
        let v = verify_raw("残留 11010519491231002X", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Block);
        assert_eq!(v.residue.len(), 1);
    }

    #[test]
    fn a_surviving_email_blocks() {
        let v = verify_raw("残留 a@b.com", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn placeholder_shaped_residue_beside_real_data_blocks() {
        // The SANITIZATION_RESIDUE pattern: a header scrubbed while the body
        // was not.
        let v = verify_raw("[CN_ID_1] 但 11010519491231002X 仍在", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn an_empty_detector_set_blocks_rather_than_passing() {
        // Fail closed: with nothing to check against we cannot assert safety.
        let v = verify_raw("anything", &[]);
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
        let v = verify_raw("text", &[Box::new(Exploding)]);
        assert_eq!(v.verdict, Verdict::Block);
    }

    #[test]
    fn notes_record_how_the_verdict_was_reached() {
        let v = verify_raw("a@b.com", &tier_one_detectors());
        assert!(!v.notes.is_empty(), "the audit record needs a reason");
    }

    /// The 2026-11-02 regression, pinned.
    ///
    /// A structural survivor must block even when the caller supplies a
    /// suppressor that would drop every match. Before the split, this same
    /// suppressor ran on the rule layer too, so `pass` was reported with eight
    /// identifier classes still in the text.
    #[test]
    fn a_structural_survivor_blocks_even_when_the_shared_suppressor_drops_everything() {
        let v = verify(
            "委托人：[PERSON_14BF81AB_1]身份证号：110105199003074512",
            &tier_one_detectors(),
            VerifyScope::default(),
            |_| true, // the suppressor the redaction uses, maximally hostile
        );
        assert_eq!(
            v.verdict,
            Verdict::Block,
            "a rule match is never the suppressor's to drop; notes={:?}",
            v.notes
        );
        assert!(v
            .residue
            .iter()
            .any(|m| m.entity == EntityType::CnResidentId));
    }

    #[test]
    fn the_model_gate_is_recorded_rather_than_silently_applied() {
        struct Guessy;
        impl Detector for Guessy {
            fn detect(&self, _t: &str) -> crate::RedactResult<Vec<crate::Match>> {
                Ok(vec![Match {
                    start: 0,
                    end: 9,
                    entity: EntityType::OrgName,
                    text: "国家网信办".to_string(),
                    confidence: 0.9,
                    source: MatchSource::Model,
                }])
            }
            fn name(&self) -> &'static str {
                "guessy"
            }
        }
        let v = verify(
            "国家网信办",
            &[Box::new(Guessy)],
            VerifyScope::default(),
            |_| true,
        );
        assert_eq!(v.verdict, Verdict::Pass);
        assert!(
            v.notes.iter().any(|n| n.contains("model gate")),
            "a suppressed model match must be visible in the audit trail: {:?}",
            v.notes
        );
    }

    /// The suppressor boundary, stated as a property rather than as a call site.
    ///
    /// `is_suppressible_model_match` is the ONLY suppression the verifier still
    /// replays. It must answer `false` for every structural source, or the
    /// verifier becomes circular again the moment someone passes it in.
    #[test]
    fn the_shared_suppressor_never_claims_a_structural_match() {
        use crate::detect::noise::is_suppressible_model_match;

        for source in [
            MatchSource::Checksum,
            MatchSource::Pattern,
            MatchSource::Context,
        ] {
            let m = Match {
                start: 0,
                end: 18,
                entity: EntityType::CnResidentId,
                text: "110105199003074512".to_string(),
                confidence: 1.0,
                source,
            };
            assert!(
                !is_suppressible_model_match(&m),
                "{source:?} must never be suppressible by the model gate"
            );
        }

        // And it must not suppress a model span merely because it is a model
        // span: a confident, non-public, multi-character guess is still residue.
        let confident = Match {
            start: 0,
            end: 9,
            entity: EntityType::PersonName,
            text: "某某公司实控人".to_string(),
            confidence: 0.99,
            source: MatchSource::Model,
        };
        assert!(!is_suppressible_model_match(&confident));
    }

    /// A public body named by the model is suppressed, and that is a deliberate
    /// decision - not the redactor excusing a rule match.
    #[test]
    fn a_model_guess_at_a_regulator_is_not_treated_as_residue() {
        use crate::detect::noise::is_suppressible_model_match;
        let m = Match {
            start: 0,
            end: 9,
            entity: EntityType::OrgName,
            text: "国家网信办".to_string(),
            confidence: 0.99,
            source: MatchSource::Model,
        };
        assert!(is_suppressible_model_match(&m));
    }

    #[test]
    fn a_placeholder_re_firing_its_own_detector_is_not_residue() {
        // A token can re-fire a label-anchored rule: `账号：[BANK_ACCOUNT_...]` still
        // reads as an account to the label regex. The span exclusion is what proves
        // the verifier is looking at its own output, not a survivor.
        let placeholder = "[BANK_ACCOUNT_D40135711C2E6271]";
        let text = format!("账号：{placeholder}");
        let start = text.find(placeholder).expect("placeholder present");
        let v = verify(
            &text,
            &tier_one_detectors(),
            VerifyScope {
                placeholders: &[(start, start + placeholder.len())],
            },
            |_| false,
        );
        assert_eq!(v.verdict, Verdict::Pass, "notes={:?}", v.notes);
    }

    /// The token is opaque, so it cannot re-fire a NUMERIC rule at all - the failure
    /// mode the numeric mask had. A 64-bit hex tag never satisfies Luhn, MOD 31 or a
    /// date check, so a class that used to need the span exclusion no longer does.
    #[test]
    fn a_numeric_token_cannot_re_fire_a_checksum_rule() {
        let mut s = crate::Sanitizer::new(
            tier_one_detectors(),
            crate::mapping::MappingVersion::CURRENT,
        );
        let out = s
            .sanitize(
                "卡号 6222021234567890128 身份证 44030119800101123X",
                pacgate_core::DataLevel::T3ProjectSpecific,
            )
            .unwrap();
        assert_eq!(out.ledger.verdict(), Verdict::Pass, "notes={:?}", out.ledger.verification_notes);
        for d in tier_one_detectors() {
            for m in d.detect(&out.text).unwrap() {
                assert!(crate::is_placeholder(&m.text), "{:?} '{}'", m.entity, m.text);
            }
        }
    }
}
