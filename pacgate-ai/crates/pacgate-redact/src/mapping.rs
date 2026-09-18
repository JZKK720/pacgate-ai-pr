//! Job-scoped placeholder mapping and the local restore path.
//!
//! Isolation is structural, not conventional: a `Mapping` is created per job
//! and carries its own `JobId`, so two matters cannot share an allocator even
//! by accident (spec 6.2 映射隔离; acceptance: different matters running at the
//! same time must not share identity).
//!
//! Restore is deliberately strict. An unknown or deformed placeholder is an
//! error, never a guess (spec 6.3; acceptance: 云端输出未知或变形占位符 ->
//! 本地拒绝猜测还原，转人工处理).

use std::collections::HashMap;

use uuid::Uuid;

use crate::entity::EntityType;
use crate::{RedactError, RedactResult};

/// Identifies one sanitization job. Bind every artifact to this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct JobId(pub Uuid);

impl JobId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for JobId {
    fn default() -> Self {
        Self::new()
    }
}

/// Version of the mapping format and rule set. Recorded per job so history is
/// never silently re-interpreted (spec 6.3 L136, 8.8, 9 acceptance).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct MappingVersion(pub u32);

impl MappingVersion {
    pub const CURRENT: MappingVersion = MappingVersion(1);
}

/// One job's placeholder mapping.
#[derive(Debug)]
pub struct Mapping {
    job_id: JobId,
    version: MappingVersion,
    /// placeholder -> (entity, original)
    entries: HashMap<String, (EntityType, String)>,
}

impl Mapping {
    pub fn new(version: MappingVersion) -> Self {
        Self {
            job_id: JobId::new(),
            version,
            entries: HashMap::new(),
        }
    }

    pub fn job_id(&self) -> &JobId {
        &self.job_id
    }

    pub fn version(&self) -> MappingVersion {
        self.version
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn insert(&mut self, placeholder: &str, original: &str) {
        self.insert_typed(placeholder, EntityType::PersonName, original);
    }

    pub fn insert_typed(&mut self, placeholder: &str, entity: EntityType, original: &str) {
        self.entries
            .insert(placeholder.to_string(), (entity, original.to_string()));
    }

    /// Replace every known placeholder with its original.
    ///
    /// Fails when `expected` is not this mapping's version, or when the text
    /// contains a placeholder-shaped token the mapping cannot resolve.
    /// Callers must treat any `Err` as "escalate to a human", never as
    /// "send the text anyway".
    pub fn restore(&self, text: &str, expected: MappingVersion) -> RedactResult<String> {
        if expected != self.version {
            return Err(RedactError::InvalidInput(format!(
                "mapping version mismatch: job has v{}, caller expected v{}",
                self.version.0, expected.0
            )));
        }

        // Reject unknown placeholder-shaped tokens before substituting, so a
        // partially-resolvable string never reaches the caller.
        for token in extract_placeholder_tokens(text) {
            if !self.entries.contains_key(&token) {
                return Err(RedactError::InvalidInput(format!(
                    "unknown placeholder {token}: refusing to guess"
                )));
            }
        }

        // Longest-first so [PERSON_10] is not clobbered by [PERSON_1].
        let mut keys: Vec<&String> = self.entries.keys().collect();
        keys.sort_by(|a, b| b.len().cmp(&a.len()));

        let mut out = text.to_string();
        for k in keys {
            if let Some((_, original)) = self.entries.get(k) {
                out = out.replace(k.as_str(), original);
            }
        }
        Ok(out)
    }
}

/// Find `[UPPER_TOKEN]` shapes for unknown-placeholder detection.
///
/// Only uppercase/digit/underscore content counts, so ordinary bracketed
/// Chinese text such as [见附页] is ignored rather than treated as an error.
fn extract_placeholder_tokens(text: &str) -> Vec<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'[' {
            if let Some(rel) = bytes[i + 1..].iter().position(|&b| b == b']') {
                let end = i + 1 + rel;
                let inner = &text[i + 1..end];
                let looks_like_placeholder = !inner.is_empty()
                    && inner.len() <= 64
                    && inner
                        .chars()
                        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_');
                if looks_like_placeholder {
                    out.push(text[i..=end].to_string());
                }
                i = end + 1;
                continue;
            }
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Mapping {
        let mut m = Mapping::new(MappingVersion(1));
        m.insert("[PERSON_1]", "张三");
        m.insert("[ORG_1]", "智方云");
        m
    }

    #[test]
    fn restore_reverses_a_placeholder() {
        let m = sample();
        let out = m.restore("[PERSON_1] 与 [ORG_1] 签约", m.version()).unwrap();
        assert_eq!(out, "张三 与 智方云 签约");
    }

    #[test]
    fn restore_refuses_on_version_mismatch() {
        let m = sample();
        let err = m.restore("[PERSON_1]", MappingVersion(99)).unwrap_err();
        assert!(matches!(err, crate::RedactError::InvalidInput(_)));
    }

    #[test]
    fn restore_refuses_an_unknown_placeholder_rather_than_guessing() {
        let m = sample();
        let err = m.restore("[PERSON_999] 出现", m.version()).unwrap_err();
        assert!(matches!(err, crate::RedactError::InvalidInput(_)));
    }

    #[test]
    fn restore_leaves_text_without_placeholders_untouched() {
        let m = sample();
        assert_eq!(m.restore("无占位符", m.version()).unwrap(), "无占位符");
    }

    #[test]
    fn jobs_do_not_share_placeholders() {
        let a = sample();
        let b = Mapping::new(MappingVersion(1));
        assert_ne!(a.job_id(), b.job_id());
        assert!(b.restore("[PERSON_1]", b.version()).is_err());
    }

    #[test]
    fn entry_count_tracks_inserts() {
        assert_eq!(sample().entry_count(), 2);
    }

    #[test]
    fn nested_placeholder_names_do_not_clobber_each_other() {
        // [PERSON_1] is a prefix of [PERSON_10]; longest-first replacement
        // must not corrupt the longer token.
        let mut m = Mapping::new(MappingVersion(1));
        m.insert("[PERSON_1]", "甲");
        m.insert("[PERSON_10]", "乙");
        assert_eq!(m.restore("[PERSON_10]", m.version()).unwrap(), "乙");
        assert_eq!(m.restore("[PERSON_1]", m.version()).unwrap(), "甲");
    }

    #[test]
    fn bracketed_text_that_is_not_a_placeholder_is_left_alone() {
        let m = sample();
        // Lowercase/CJK content is not placeholder-shaped, so it is not an error.
        let out = m.restore("见附件 [见附页] 及 [PERSON_1]", m.version()).unwrap();
        assert_eq!(out, "见附件 [见附页] 及 张三");
    }
}