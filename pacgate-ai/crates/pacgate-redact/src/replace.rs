//! The replacement engine.
//!
//! No model is consulted here. By the time text reaches this module the
//! decision has already been made; this only applies it.
//!
//! Offsets are validated before any splicing. An out-of-range or
//! non-char-boundary offset is a fatal error, never a panic and never a
//! silent skip (design section 6). Chinese text is 3 bytes per character, so
//! a naive byte splice corrupts it; char-boundary validation is what prevents
//! that.

use serde::{Deserialize, Serialize};

use crate::entity::{EntityType, PlaceholderPolicy};
use crate::placeholder::PlaceholderAllocator;
use crate::{Match, MatchSource, RedactError, RedactResult};

/// One redaction as applied, for the audit ledger and the review panel.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppliedRedaction {
    pub entity: EntityType,
    pub placeholder: String,
    pub start: usize,
    pub end: usize,
    pub source: MatchSource,
}

/// The outcome of applying a match set to one text.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Redaction {
    pub text: String,
    pub applied: Vec<AppliedRedaction>,
}

/// Applies matches to text using a stable placeholder allocator.
#[derive(Debug, Default)]
pub struct Redactor {
    allocator: PlaceholderAllocator,
}

impl Redactor {
    pub fn new() -> Self {
        Self::default()
    }

    /// Access the allocator, so the caller can persist the mapping.
    pub fn allocator(&self) -> &PlaceholderAllocator {
        &self.allocator
    }

    /// Apply every match. Matches must not overlap; the noise filter
    /// (Task 5) runs before this so that invariant holds.
    pub fn redact(&mut self, text: &str, matches: &[Match]) -> RedactResult<Redaction> {
        let len = text.len();

        for m in matches {
            if m.end > len || m.start > m.end {
                return Err(RedactError::Internal(format!(
                    "span [{}, {}) is out of range for a {} byte text",
                    m.start, m.end, len
                )));
            }
            if !text.is_char_boundary(m.start) || !text.is_char_boundary(m.end) {
                return Err(RedactError::Internal(format!(
                    "span [{}, {}) is not on a char boundary",
                    m.start, m.end
                )));
            }
        }

        let mut ordered: Vec<&Match> = matches.iter().collect();
        ordered.sort_by_key(|m| m.start);

        for pair in ordered.windows(2) {
            if pair[0].overlaps(pair[1]) {
                return Err(RedactError::Internal(format!(
                    "overlapping matches at [{}, {}) and [{}, {}) - run NoiseFilter first",
                    pair[0].start, pair[0].end, pair[1].start, pair[1].end
                )));
            }
        }

        let mut out = String::with_capacity(len);
        let mut applied: Vec<AppliedRedaction> = Vec::new();
        let mut cursor = 0usize;

        for m in ordered {
            let placeholder = self.allocator.allocate(m.entity, &m.text);

            out.push_str(&text[cursor..m.start]);

            if m.entity.policy() != PlaceholderPolicy::Remove {
                out.push_str(&placeholder);
            }

            applied.push(AppliedRedaction {
                entity: m.entity,
                placeholder,
                start: m.start,
                end: m.end,
                source: m.source,
            });

            cursor = m.end;
        }

        out.push_str(&text[cursor..]);

        Ok(Redaction { text: out, applied })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EntityType, Match, MatchSource};

    fn m(start: usize, end: usize, entity: EntityType, text: &str) -> Match {
        Match {
            start,
            end,
            entity,
            text: text.to_string(),
            confidence: 1.0,
            source: MatchSource::Checksum,
        }
    }

    #[test]
    fn replaces_a_single_span_and_keeps_surrounding_text() {
        let text = "身份证 11010519491231002X 已核对";
        let matches = vec![m(10, 28, EntityType::CnResidentId, "11010519491231002X")];
        let out = Redactor::new().redact(text, &matches).unwrap();
        assert!(!out.text.contains("11010519491231002X"));
        assert!(out.text.starts_with("身份证 "));
        assert!(out.text.ends_with(" 已核对"));
        assert_eq!(out.applied.len(), 1);
    }

    #[test]
    fn a_removed_entity_leaves_no_placeholder_behind() {
        let text = "token=abcdef123456";
        let matches = vec![m(6, 18, EntityType::Credential, "abcdef123456")];
        let out = Redactor::new().redact(text, &matches).unwrap();
        assert!(!out.text.contains("abcdef123456"));
        assert!(!out.text.contains('['), "credentials are removed, not placeholdered");
    }

    #[test]
    fn repeated_values_reuse_one_placeholder() {
        let text = "张三...张三";
        let matches = vec![
            m(0, 6, EntityType::PersonName, "张三"),
            m(9, 15, EntityType::PersonName, "张三"),
        ];
        let out = Redactor::new().redact(text, &matches).unwrap();
        assert_eq!(out.applied[0].placeholder, out.applied[1].placeholder);
    }

    #[test]
    fn multibyte_text_offsets_are_respected() {
        // Chinese text is 3 bytes per character; a naive byte splice corrupts it.
        let text = "姓名张三，电话13812345678。";
        let start = text.find('张').unwrap();
        let end = start + "张三".len();
        let matches = vec![m(start, end, EntityType::PersonName, "张三")];
        let out = Redactor::new().redact(text, &matches).unwrap();
        assert!(out.text.starts_with("姓名"));
        assert!(out.text.ends_with("，电话13812345678。"));
    }

    #[test]
    fn out_of_range_offsets_error_rather_than_panic() {
        let text = "短";
        let matches = vec![m(0, 999, EntityType::PersonName, "x")];
        let err = Redactor::new().redact(text, &matches).unwrap_err();
        assert!(err.is_fatal());
    }

    #[test]
    fn non_char_boundary_offsets_error_rather_than_panic() {
        let text = "张三";
        // Offset 1 is inside the first character's UTF-8 sequence.
        let matches = vec![m(0, 1, EntityType::PersonName, "x")];
        assert!(Redactor::new().redact(text, &matches).is_err());
    }

    #[test]
    fn overlapping_matches_error_instead_of_silently_dropping_one() {
        let text = "aaaaaaaaaaaaaaaaaaaa";
        let matches = vec![
            m(0, 10, EntityType::PersonName, "aaaaaaaaaa"),
            m(5, 15, EntityType::OrgName, "aaaaaaaaaa"),
        ];
        let err = Redactor::new().redact(text, &matches).unwrap_err();
        assert!(err.is_fatal(), "an overlapping set must not be applied silently");
    }

    #[test]
    fn no_matches_returns_the_original_text() {
        let out = Redactor::new().redact("没有敏感信息", &[]).unwrap();
        assert_eq!(out.text, "没有敏感信息");
        assert!(out.applied.is_empty());
    }
}