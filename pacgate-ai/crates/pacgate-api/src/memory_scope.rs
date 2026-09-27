//! What the persistent-memory lanes may hold.
//!
//! The rule, in one line: **memory holds process, not matter facts.**
//!
//! Memory is conversational context - what was done, what is in flight, how the
//! user prefers to be interacted with. Matter facts (party names, identifiers,
//! account numbers) belong in the RAG lane, where `kb_chunks.sanitization_state`
//! already gates retrieval. A memory store that accepts matter facts becomes a
//! second, ungated copy of client data that a later chat turn can retrieve and
//! feed back into an LLM - a sanitization bypass in the sanitizer's own memory.
//!
//! ## The deliberate asymmetry
//!
//! Identifiers are refused; prose is not. Only classes with a checksum or an
//! unambiguous shape gate this lane - the Tier-1 set `tier_one_detectors()`
//! produces: `CnResidentId`, `Uscc`, `CnMobile`, `BankCard`, `Email`.
//!
//! **`PersonName`, `OrgName` and `Location` are NOT checked**, even though the NER
//! model can find them. A process summary legitimately contains "the firm", "the
//! user", "the client". Gating on names would refuse valid summaries, and a gate
//! that fires on legitimate traffic gets disabled - which is exactly how the
//! `If-Match` guard in `matters.rs` came to be dead at three layers while every
//! unit test passed.
//!
//! Names in memory are therefore a real, documented residual risk. They are
//! accepted because the alternative is a gate nobody keeps.
//!
//! ## Why size is also checked
//!
//! Matter facts look like *content*; process summaries do not. A memory document
//! holding a contract dump is out of scope even when no single value matches a
//! pattern, and size is the only check that sees that.

use pacgate_redact::detect::{tier_one_detectors, Detector};

/// Ceiling on a memory payload.
///
/// Roughly 30x the largest memory file observed on the dev box (2.5 KB), so this
/// is a boundary against a category error rather than a working constraint.
pub const MEMORY_MAX_BYTES: usize = 64 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum MemoryScopeViolation {
    /// A checksum- or shape-validated identifier was found. Hard refusal.
    Identifier { entity: String, count: usize },
    /// The payload is too large to plausibly be a process summary.
    TooLarge { bytes: usize, limit: usize },
}

/// Decide whether `memory` may be stored in a persistent-memory lane.
///
/// `Ok(())` means in scope. Any `Err` is a refusal, not a warning.
pub fn check_memory_scope(memory: &serde_json::Value) -> Result<(), MemoryScopeViolation> {
    let bytes = serde_json::to_vec(memory).map(|v| v.len()).unwrap_or(usize::MAX);
    if bytes > MEMORY_MAX_BYTES {
        return Err(MemoryScopeViolation::TooLarge {
            bytes,
            limit: MEMORY_MAX_BYTES,
        });
    }

    // Scan the SERIALISED text rather than walking the tree, so a value nested in
    // `user.topOfMind.summary` counts exactly the same as one in `facts[]`. A
    // hand-written walk would silently miss any branch added later.
    let text = serde_json::to_string(memory).unwrap_or_default();

    let detectors = tier_one_detectors();
    let mut count = 0usize;
    let mut first: Option<String> = None;

    for d in &detectors {
        // A detector error is a REFUSAL, never a pass: scope cannot be asserted
        // with no evidence. The Tier-1 detectors are deterministic and infallible,
        // so this arm is defensive rather than reachable.
        let found = d.detect(&text).map_err(|_| MemoryScopeViolation::Identifier {
            entity: "detector-error".to_string(),
            count: 0,
        })?;
        for m in found {
            count += 1;
            if first.is_none() {
                first = Some(m.entity.code().to_string());
            }
        }
    }

    if count > 0 {
        return Err(MemoryScopeViolation::Identifier {
            entity: first.unwrap_or_else(|| "unknown".to_string()),
            count,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obj(json: &str) -> serde_json::Value {
        serde_json::from_str(json).expect("test fixture is valid JSON")
    }

    /// The rule this step exists to make mechanical: memory holds PROCESS.
    #[test]
    fn a_process_summary_is_allowed() {
        let m = obj(
            r#"{
            "version": "2.0",
            "facts": [
                {"category": "context", "content": "The user is sanitizing a document at level T3."}
            ],
            "user": {"topOfMind": {"summary": "Working through redaction for one matter."}}
        }"#,
        );
        assert_eq!(
            check_memory_scope(&m),
            Ok(()),
            "narrated process must be allowed"
        );
    }

    /// A resident ID passes a checksum, so this refusal is unambiguous rather
    /// than a judgement call.
    #[test]
    fn a_checksum_valid_resident_id_is_refused() {
        let m = obj(r#"{"facts":[{"content":"Client ID 11010519491231002X on file"}]}"#);
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::Identifier { entity, count }) => {
                assert_eq!(entity, "CN_ID");
                assert_eq!(count, 1);
            }
            other => panic!("a resident ID must be refused, got {other:?}"),
        }
    }

    #[test]
    fn a_mobile_and_an_email_are_refused() {
        for (json, expect) in [
            (r#"{"facts":[{"content":"call 13812345678"}]}"#, "CN_MOBILE"),
            (r#"{"facts":[{"content":"mail a@b.com"}]}"#, "EMAIL"),
        ] {
            match check_memory_scope(&obj(json)) {
                Err(MemoryScopeViolation::Identifier { entity, .. }) => {
                    assert_eq!(entity, expect, "wrong entity for {json}")
                }
                other => panic!("expected a refusal for {json}, got {other:?}"),
            }
        }
    }

    /// The deliberate ASYMMETRY. A process summary says "the firm". If this ever
    /// starts refusing names, the gate will reject legitimate traffic and be
    /// disabled - the failure mode already observed once in this subsystem.
    #[test]
    fn a_person_or_org_name_is_allowed_because_prose_needs_it() {
        let m = obj(r#"{"facts":[{"content":"The firm reviewed the matter with the user."}]}"#);
        assert_eq!(
            check_memory_scope(&m),
            Ok(()),
            "names are Tier-2 and must not gate this lane"
        );
    }

    /// Matter facts look like content. A lane holding a contract dump is out of
    /// scope regardless of whether any single value matches a pattern.
    #[test]
    fn an_oversized_payload_is_refused() {
        let big = "x".repeat(MEMORY_MAX_BYTES + 1);
        let m = obj(&format!(r#"{{"facts":[{{"content":"{big}"}}]}}"#));
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::TooLarge { bytes, limit }) => {
                assert!(bytes > limit, "{bytes} should exceed {limit}");
            }
            other => panic!("an oversized payload must be refused, got {other:?}"),
        }
    }

    /// A payload comfortably under the limit is in scope - the size check must not
    /// fire on ordinary summaries.
    #[test]
    fn a_large_but_plausible_summary_is_allowed() {
        let body = "The user is working through a redaction task. ".repeat(200); // ~9 KB
        let m = obj(&format!(r#"{{"facts":[{{"content":"{body}"}}]}}"#));
        assert!(
            serde_json::to_vec(&m).unwrap().len() < MEMORY_MAX_BYTES,
            "fixture should be under the limit"
        );
        assert_eq!(check_memory_scope(&m), Ok(()));
    }

    /// A UUID is an internal reference, not an identifier. The detectors decide,
    /// not a shape heuristic: a shape scan produced 1062 UUID matches in one
    /// ungated store, so shape counting is not evidence of PII.
    #[test]
    fn a_uuid_is_not_an_identifier() {
        let m = obj(r#"{"facts":[{"content":"document 1b3c2e48-22e1-4fcc-849a-8477d7196b19"}]}"#);
        assert_eq!(
            check_memory_scope(&m),
            Ok(()),
            "a UUID is an internal reference, not PII"
        );
    }

    /// Counts are reported so a refusal is diagnosable rather than a bare no.
    #[test]
    fn multiple_identifiers_are_counted() {
        let m = obj(r#"{"facts":[{"content":"13812345678 and a@b.com"}]}"#);
        match check_memory_scope(&m) {
            Err(MemoryScopeViolation::Identifier { count, .. }) => {
                assert_eq!(count, 2, "both identifiers must be counted")
            }
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    /// A nested field must be seen, not only a top-level one. Scanning the
    /// serialised text rather than walking the tree is what guarantees this.
    #[test]
    fn an_identifier_nested_deeply_is_still_found() {
        let m = obj(
            r#"{"user":{"topOfMind":{"summary":"follow up, reachable on 13812345678"}},
                "facts":[]}"#,
        );
        assert!(
            matches!(
                check_memory_scope(&m),
                Err(MemoryScopeViolation::Identifier { .. })
            ),
            "a nested identifier must be found"
        );
    }
}
