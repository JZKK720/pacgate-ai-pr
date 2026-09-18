//! Suppresses matches that are structurally identifiable but are not this
//! matter's identifiers.
//!
//! Two responsibilities, both required by the client spec:
//!   section 8.4 数字规则必须控制误报 - never let a bare digit rule stand
//!   section 2.1 按上下文判断        - the same number class is handled
//!                                     differently depending on whether it
//!                                     ties to client identity
//!
//! Ordering must be deterministic. Sorting by (longest, earliest, entity code)
//! makes the outcome independent of detector execution order, which matters
//! because the verifier replays this same reduction.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::{EntityType, Match};

/// A published-citation shape: (YEAR)court-typeNUMBER号.
static RE_CITATION: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[(（]\d{4}[)）][^\s]{1,12}?号").expect("citation regex is valid")
});

/// True when `matched` appears inside a published-citation shape in `text`.
///
/// Used to *preserve* public-reference case numbers: spec 2.1 requires that a
/// citation unrelated to client identity survives, so the reference can still
/// be verified.
pub fn is_public_case_number(text: &str, matched: &str) -> bool {
    RE_CITATION
        .find_iter(text)
        .any(|c| c.as_str().contains(matched))
}

/// Drops overlapping and nested matches. Longest span wins; ties go to the
/// earlier start, then to the earlier entity code, so the result is total.
pub struct NoiseFilter;

impl Default for NoiseFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl NoiseFilter {
    pub fn new() -> Self {
        Self
    }

    pub fn apply(&self, _text: &str, mut matches: Vec<Match>) -> Vec<Match> {
        matches.sort_by(|a, b| {
            b.len()
                .cmp(&a.len())
                .then(a.start.cmp(&b.start))
                .then(a.entity.code().cmp(b.entity.code()))
        });

        let mut kept: Vec<Match> = Vec::with_capacity(matches.len());
        for candidate in matches {
            if kept.iter().any(|k| k.overlaps(&candidate)) {
                continue;
            }
            kept.push(candidate);
        }

        kept.sort_by_key(|m| (m.start, m.end));
        kept
    }
}

/// Drop any match whose entity is `CaseNumber` and which the context marks as
/// a public citation.
pub fn drop_public_citations(text: &str, matches: Vec<Match>) -> Vec<Match> {
    matches
        .into_iter()
        .filter(|m| m.entity != EntityType::CaseNumber || !is_public_case_number(text, &m.text))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EntityType, MatchSource};

    fn m(start: usize, end: usize, entity: EntityType) -> Match {
        Match {
            start,
            end,
            entity,
            text: String::new(),
            confidence: 0.9,
            source: MatchSource::Pattern,
        }
    }

    #[test]
    fn drops_a_match_that_is_inside_a_larger_match() {
        let text = "0123456789012345678";
        let outer = m(0, 19, EntityType::BankAccount);
        let inner = m(1, 15, EntityType::BankCard);
        let kept = NoiseFilter::new().apply(text, vec![outer, inner]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].entity, EntityType::BankAccount);
    }

    #[test]
    fn public_case_citations_are_recognised_so_they_can_be_preserved() {
        assert!(is_public_case_number(
            "参见 (2019)最高法民终1234号 判决",
            "(2019)最高法民终1234号"
        ));
        assert!(!is_public_case_number("案号 1234", "1234"));
    }

    #[test]
    fn keeps_matches_that_do_not_overlap() {
        let text = "aaaaaaaaaaaaaaaaaaaa";
        let kept = NoiseFilter::new().apply(
            text,
            vec![m(0, 3, EntityType::Email), m(5, 8, EntityType::Email)],
        );
        assert_eq!(kept.len(), 2);
    }

    #[test]
    fn overlapping_equals_longest_wins_deterministically() {
        let text = "aaaaaaaaaaaaaaaaaaaa";
        let a = m(0, 10, EntityType::PersonName);
        let b = m(2, 12, EntityType::OrgName);
        // Same length: the earlier start wins, and the result is order-independent.
        let first = NoiseFilter::new().apply(text, vec![a.clone(), b.clone()]);
        let second = NoiseFilter::new().apply(text, vec![b, a]);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].entity, second[0].entity);
    }

    #[test]
    fn empty_input_yields_empty_output() {
        assert!(NoiseFilter::new().apply("", vec![]).is_empty());
    }

    #[test]
    fn drop_public_citations_removes_only_flagged_case_numbers() {
        let text = "参见 (2019)最高法民终1234号 与本案其他案号";
        let citation = Match {
            start: 3,
            end: 20,
            entity: EntityType::CaseNumber,
            text: "(2019)最高法民终1234号".to_string(),
            confidence: 0.9,
            source: MatchSource::Context,
        };
        let kept = drop_public_citations(text, vec![citation]);
        assert!(
            kept.is_empty(),
            "a recognised public citation is preserved, not redacted"
        );
    }
}