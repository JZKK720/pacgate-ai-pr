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
        keys.sort_by_key(|k| std::cmp::Reverse(k.len()));

        let mut out = text.to_string();
        for k in keys {
            if let Some((_, original)) = self.entries.get(k) {
                out = out.replace(k.as_str(), original);
            }
        }
        Ok(out)
    }

    /// JSON for the vault row (`sanitizer_jobs.mapping` JSONB). Shape:
    /// `{"entries": [{"placeholder", "entity", "original"}], "job_id", "version"}`.
    /// The original values NEVER leave pacgate-api; this is storage, not egress.
    pub fn serialize(&self) -> serde_json::Value {
        let entries: Vec<serde_json::Value> = self
            .entries
            .iter()
            .map(|(ph, (entity, original))| {
                serde_json::json!({
                    "placeholder": ph,
                    "entity": entity.code(),
                    "original": original,
                })
            })
            .collect();
        serde_json::json!({
            "job_id": self.job_id.0.to_string(),
            "version": self.version.0,
            "entries": entries,
        })
    }

    /// Rebuild a mapping from its serialized form. Unknown entity codes are
    /// refused (never guessed), so a partial vault is visible rather than
    /// silently mis-restoring.
    pub fn deserialize(
        value: &serde_json::Value,
        expected_version: MappingVersion,
    ) -> RedactResult<Self> {
        let version = value
            .get("version")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| {
                RedactError::InvalidInput("mapping json lacks version".to_string())
            })?;
        if version != expected_version.0 as u64 {
            return Err(RedactError::InvalidInput(format!(
                "mapping version mismatch: stored v{version}, expected v{}",
                expected_version.0
            )));
        }
        let job_id_str = value
            .get("job_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                RedactError::InvalidInput("mapping json lacks job_id".to_string())
            })?;
        let job_id = JobId(job_id_str.parse().map_err(|e| {
            RedactError::InvalidInput(format!("mapping json job_id invalid: {e}"))
        })?);
        let mut entries = HashMap::new();
        for e in value
            .get("entries")
            .and_then(|v| v.as_array())
            .ok_or_else(|| {
                RedactError::InvalidInput("mapping json lacks entries".to_string())
            })?
        {
            let placeholder = e
                .get("placeholder")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    RedactError::InvalidInput("entry lacks placeholder".to_string())
                })?
                .to_string();
            let entity_code = e
                .get("entity")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    RedactError::InvalidInput("entry lacks entity".to_string())
                })?;
            let entity = EntityType::from_code(entity_code).ok_or_else(|| {
                RedactError::InvalidInput(format!(
                    "unknown entity code {entity_code}: refusing to guess"
                ))
            })?;
            let original = e
                .get("original")
                .and_then(|v| v.as_str())
                .ok_or_else(|| {
                    RedactError::InvalidInput("entry lacks original".to_string())
                })?
                .to_string();
            entries.insert(placeholder, (entity, original.to_string()));
        }
        Ok(Self {
            job_id,
            version: expected_version,
            entries,
        })
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
    fn a_mapping_survives_a_json_round_trip() {
        let mut m = Mapping::new(MappingVersion(1));
        m.insert_typed("[PERSON_ABC123_1]", EntityType::PersonName, "张三");
        m.insert_typed("[ORG_ABC123_2]", EntityType::OrgName, "智方云");
        let json = m.serialize();
        let back = Mapping::deserialize(&json, MappingVersion(1)).expect("round trip");
        assert_eq!(back.entry_count(), 2);
        let restored = back
            .restore("[PERSON_ABC123_1] 与 [ORG_ABC123_2] 签约", MappingVersion(1))
            .unwrap();
        assert_eq!(restored, "张三 与 智方云 签约");
    }

    #[test]
    fn deserialize_refuses_an_unknown_entity_code_rather_than_guessing() {
        let mut m = Mapping::new(MappingVersion(1));
        m.insert_typed("[PERSON_X_1]", EntityType::PersonName, "张三");
        let mut json = m.serialize();
        json["entries"][0]["entity"] = serde_json::json!("NOT_A_REAL_CODE");
        let err = Mapping::deserialize(&json, MappingVersion(1)).unwrap_err();
        assert!(err.to_string().contains("unknown entity code"));
    }

    #[test]
    fn deserialize_refuses_a_version_mismatch() {
        let m = sample();
        let json = m.serialize();
        let err = Mapping::deserialize(&json, MappingVersion(99)).unwrap_err();
        assert!(err.to_string().contains("version mismatch"));
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