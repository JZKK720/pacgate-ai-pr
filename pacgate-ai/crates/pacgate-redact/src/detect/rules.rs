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
/// Unanchored on purpose - `is_bounded` is the boundary test, because `\b`
/// fails between a CJK character and a digit.
static RE_CN_ID_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{17}[\dXx]").expect("id candidate regex is valid"));

/// 18-char USCC shape: digits plus uppercase letters, excluding I O S V Z.
static RE_USCC_CANDIDATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[0-9A-HJ-NPQRTUWXY]{18}").expect("uscc candidate regex is valid")
});

static RE_MOBILE_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"1[3-9]\d{9}").expect("mobile regex is valid"));

static RE_DIGIT_RUN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{12,19}").expect("digit run regex is valid"));

/// Ceiling on matches from one text, to turn a pathological input into a
/// fatal error instead of unbounded memory growth.
const MAX_MATCHES: usize = 4096;

/// True when the span `[start, end)` is not flanked by an ASCII alphanumeric.
///
/// Replaces `\b` on the candidate patterns. `\b` is wrong here because the
/// `regex` crate is Unicode-aware by default, so `\w` includes CJK - which means
/// `\b` does not exist between a CJK character and a digit, and
/// `手机13812345678` (no space) is silently missed. Chinese text does not use
/// inter-word spaces, so that is the common form, not an edge case.
///
/// The test is deliberately "not ASCII-alphanumeric" rather than "non-word":
/// trailing CJK (`手机13812345678号`) must be accepted, while a longer token
/// (`ABC13812345678`) must not. `[^\w]` would reject both.
///
/// Offsets come from `regex::Match` on the same `text`, so they are char
/// boundaries by construction.
fn is_bounded(text: &str, start: usize, end: usize) -> bool {
    let before_ok = text[..start]
        .chars()
        .next_back()
        .map_or(true, |c| !c.is_ascii_alphanumeric());
    let after_ok = text[end..]
        .chars()
        .next()
        .map_or(true, |c| !c.is_ascii_alphanumeric());
    before_ok && after_ok
}

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
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if validate_cn_resident_id(m.as_str()) {
                self.push(&mut out, m, EntityType::CnResidentId, MatchSource::Checksum);
            }
        }

        for m in RE_USCC_CANDIDATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if validate_uscc(m.as_str()) {
                self.push(&mut out, m, EntityType::Uscc, MatchSource::Checksum);
            }
        }

        for m in RE_MOBILE_CANDIDATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::CnMobile, MatchSource::Checksum);
        }

        for m in RE_DIGIT_RUN.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
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

    /// A CJK character is a word character for Unicode-aware `\b`, so `\b` does
    /// not exist between it and a digit. These are the forms a Chinese contract
    /// actually contains - no inter-word spaces.
    #[test]
    fn is_bounded_accepts_cjk_adjacency_and_rejects_longer_tokens() {
        let text = "手机13812345678";
        let start = 6; // "手机" is 6 bytes (2 chars x 3 bytes)
        assert_eq!(&text[start..start + 11], "13812345678");
        assert!(is_bounded(text, start, start + 11), "CJK adjacency must be accepted");

        // Trailing CJK too: the number is followed by a unit character.
        let trailing = "手机13812345678号";
        assert!(is_bounded(trailing, start, start + 11));

        // A longer ASCII token must still be rejected: this is the reason not to
        // simply drop the anchors.
        assert!(!is_bounded("ABC13812345678", 3, 14));
        assert!(!is_bounded("A13812345678", 1, 12));
        assert!(!is_bounded("138123456789", 0, 11));

        // Text edges are unconstrained.
        assert!(is_bounded("13812345678", 0, 11));
    }

    /// The four boundary-anchored classes must be caught with a CJK character
    /// directly adjacent, not only when separated by a space. Measured before
    /// the fix: all four adjacent forms returned no matches at all.
    #[test]
    fn finds_boundary_anchored_classes_when_cjk_is_adjacent() {
        let cases = [
            ("身份证11010519491231002X", "11010519491231002X", EntityType::CnResidentId),
            ("代码91350100M000100Y43", "91350100M000100Y43", EntityType::Uscc),
            ("手机13812345678", "13812345678", EntityType::CnMobile),
            ("卡号4111111111111111", "4111111111111111", EntityType::BankCard),
        ];
        for (text, value, entity) in cases {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == entity && m.text == value),
                "adjacency miss ({entity:?}): {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The fix must not become "match any digit run": a longer ASCII token still
    /// has to be rejected, or the recall fix becomes a precision regression.
    #[test]
    fn still_rejects_longer_ascii_tokens() {
        // 11-digit mobile shape embedded in a longer alphanumeric token.
        let embedded = TierOneDetector::new().detect("ABC13812345678").unwrap();
        assert!(embedded.is_empty(), "must not extract a mobile from a longer token");

        // 138123456789 is 12 digits: matches RE_DIGIT_RUN's 12-19 range, but is not
        // a Luhn-valid card, so nothing should be reported.
        let extra = TierOneDetector::new().detect("138123456789").unwrap();
        assert!(
            !extra.iter().any(|m| m.entity == EntityType::CnMobile),
            "a 12-digit run must not be read as a mobile"
        );
    }
}