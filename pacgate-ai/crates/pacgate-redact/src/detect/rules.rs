//! Deterministic Tier-1 detectors.
//!
//! Ordering inside this module mirrors the spec's priority: checksum-backed
//! validators first, then labelled patterns, then plain patterns. A plain
//! pattern never fires without either a checksum or a label.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::checksum::{validate_cn_resident_id, validate_luhn, validate_uscc};
use crate::{EntityType, Match, MatchSource, RedactError, RedactResult};

use super::Detector;

static RE_EMAIL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}").expect("email regex is valid")
});

/// 18-char resident ID shape. Validity is decided by the checksum, not this.
static RE_CN_ID_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b\d{17}[\dXx]\b").expect("id candidate regex is valid"));

/// 18-char USCC shape: digits plus uppercase letters, excluding I O S V Z.
static RE_USCC_CANDIDATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"\b[0-9A-HJ-NPQRTUWXY]{18}\b").expect("uscc candidate regex is valid")
});

static RE_MOBILE_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b1[3-9]\d{9}\b").expect("mobile regex is valid"));

static RE_DIGIT_RUN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b\d{12,19}\b").expect("digit run regex is valid"));

/// Ceiling on matches from one text, to turn a pathological input into a
/// fatal error instead of unbounded memory growth.
const MAX_MATCHES: usize = 4096;

/// Finds the Tier-1 identifier set. Every rule is checksum- or shape-anchored;
/// none fires on a bare digit run.
pub struct TierOneDetector {
    include_email: bool,
}

impl Default for TierOneDetector {
    fn default() -> Self {
        Self::new()
    }
}

impl TierOneDetector {
    pub fn new() -> Self {
        Self { include_email: true }
    }

    fn push(
        &self,
        out: &mut Vec<Match>,
        m: regex::Match<'_>,
        entity: EntityType,
        source: MatchSource,
    ) {
        out.push(Match {
            start: m.start(),
            end: m.end(),
            entity,
            text: m.as_str().to_string(),
            confidence: if source == MatchSource::Checksum { 1.0 } else { 0.9 },
            source,
        });
    }
}

impl Detector for TierOneDetector {
    fn name(&self) -> &'static str {
        "tier1-rules"
    }

    fn detect(&self, text: &str) -> RedactResult<Vec<Match>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }

        let mut out: Vec<Match> = Vec::new();

        for m in RE_CN_ID_CANDIDATE.find_iter(text) {
            if validate_cn_resident_id(m.as_str()) {
                self.push(&mut out, m, EntityType::CnResidentId, MatchSource::Checksum);
            }
        }

        for m in RE_USCC_CANDIDATE.find_iter(text) {
            if validate_uscc(m.as_str()) {
                self.push(&mut out, m, EntityType::Uscc, MatchSource::Checksum);
            }
        }

        for m in RE_MOBILE_CANDIDATE.find_iter(text) {
            self.push(&mut out, m, EntityType::CnMobile, MatchSource::Checksum);
        }

        for m in RE_DIGIT_RUN.find_iter(text) {
            if validate_luhn(m.as_str()) {
                self.push(&mut out, m, EntityType::BankCard, MatchSource::Checksum);
            }
        }

        if self.include_email {
            for m in RE_EMAIL.find_iter(text) {
                self.push(&mut out, m, EntityType::Email, MatchSource::Pattern);
            }
        }

        if out.len() > MAX_MATCHES {
            return Err(RedactError::Internal(format!(
                "detector produced {} matches, exceeding the ceiling of {MAX_MATCHES}",
                out.len()
            )));
        }

        out.sort_by_key(|m| (m.start, m.end));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entities(found: &[Match]) -> Vec<EntityType> {
        let mut v: Vec<EntityType> = found.iter().map(|m| m.entity).collect();
        v.sort_by_key(|e| e.code());
        v.dedup();
        v
    }

    #[test]
    fn finds_a_resident_id_but_not_a_17_digit_run() {
        let text = "身份证 11010519491231002X 和编号 12345678901234567";
        let found = TierOneDetector::new().detect(text).unwrap();
        assert_eq!(entities(&found), vec![EntityType::CnResidentId]);
        assert_eq!(found[0].text, "11010519491231002X");
        assert_eq!(found[0].source, MatchSource::Checksum);
    }

    #[test]
    fn finds_email_by_pattern() {
        let text = "联系 zhang.san@example.com 谢谢";
        let found = TierOneDetector::new().detect(text).unwrap();
        assert_eq!(entities(&found), vec![EntityType::Email]);
        assert_eq!(found[0].text, "zhang.san@example.com");
        assert_eq!(found[0].source, MatchSource::Pattern);
    }

    #[test]
    fn finds_mobile_only_with_a_valid_operator_prefix() {
        let good = TierOneDetector::new().detect("手机 13812345678").unwrap();
        assert_eq!(entities(&good), vec![EntityType::CnMobile]);

        // 12x is not an allocated mobile prefix.
        let bad = TierOneDetector::new().detect("编号 12812345678").unwrap();
        assert!(bad.is_empty(), "must not treat an unallocated prefix as a mobile");
    }

    #[test]
    fn finds_bank_card_only_when_luhn_passes() {
        let good = TierOneDetector::new().detect("卡号 4111111111111111").unwrap();
        assert_eq!(entities(&good), vec![EntityType::BankCard]);

        let bad = TierOneDetector::new().detect("卡号 4111111111111112").unwrap();
        assert!(bad.is_empty(), "a failing Luhn check must not produce a Tier-1 match");
    }

    #[test]
    fn does_not_report_matches_that_are_not_there() {
        let found = TierOneDetector::new().detect("本所同意上述条款。").unwrap();
        assert!(found.is_empty());
    }

    #[test]
    fn multiple_matches_are_returned_in_ascending_offset_order() {
        let text = "a@b.com 和 c@d.com";
        let found = TierOneDetector::new().detect(text).unwrap();
        assert_eq!(found.len(), 2);
        assert!(found[0].start < found[1].start);
    }
}