//! Cross-store identity consistency.
//!
//! `tenant_id` and `matter_id` appear in four different representations of the
//! same fact:
//!
//!   1. the filesystem path, built by `pacgate_tenant::matter_dir` as a string join
//!   2. `kb_chunks.tenant_id` / `.matter_id` UUID columns
//!   3. `documents.tenant_id` / `.matter_id` UUID columns
//!   4. the OpenViking `X-OpenViking-Account` header and `peer` value
//!
//! Nothing enforces that these agree, and a disagreement between 1 and 2 is
//! invisible to any single-store check: the file is where the path says, and
//! the row is where the columns say, so both look correct in isolation. The
//! observable symptom would be one matter reading another's memory.
//!
//! This module exists to make that specific mismatch detectable. It is not a
//! substitute for per-store validation; it covers the seam those validations
//! cannot see.

use pacgate_core::{MatterId, TenantId};

use crate::RagError;

/// The two identifiers that must agree everywhere.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScopeIds {
    pub tenant_id: TenantId,
    pub matter_id: MatterId,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ScopeMismatch {
    #[error("tenant mismatch: expected {expected}, found {actual}")]
    Tenant { expected: String, actual: String },
    #[error("matter mismatch within tenant {tenant}: expected {expected}, found {actual}")]
    Matter {
        tenant: String,
        expected: String,
        actual: String,
    },
}

/// Compare two views of the same scope.
///
/// Tenant is checked first: it is the outer boundary, so when both differ the
/// tenant is both the more serious failure and the more useful one to report.
pub fn same_scope(expected: &ScopeIds, actual: &ScopeIds) -> Result<(), ScopeMismatch> {
    if expected.tenant_id != actual.tenant_id {
        return Err(ScopeMismatch::Tenant {
            expected: expected.tenant_id.as_str(),
            actual: actual.tenant_id.as_str(),
        });
    }
    if expected.matter_id != actual.matter_id {
        return Err(ScopeMismatch::Matter {
            tenant: expected.tenant_id.as_str(),
            expected: expected.matter_id.as_str(),
            actual: actual.matter_id.as_str(),
        });
    }
    Ok(())
}

/// `same_scope`, mapped into `RagError` for use inside the retrieval path.
pub fn assert_document_scope(expected: &ScopeIds, actual: &ScopeIds) -> Result<(), RagError> {
    same_scope(expected, actual).map_err(|e| RagError::Scope(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use pacgate_core::{MatterId, TenantId};
    use uuid::Uuid;

    fn ids(t: u128, m: u128) -> ScopeIds {
        ScopeIds {
            tenant_id: TenantId(Uuid::from_u128(t)),
            matter_id: MatterId(Uuid::from_u128(m)),
        }
    }

    #[test]
    fn identical_scope_passes() {
        assert!(same_scope(&ids(1, 2), &ids(1, 2)).is_ok());
    }

    #[test]
    fn a_tenant_mismatch_is_caught() {
        let err = same_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Tenant { .. }));
    }

    #[test]
    fn a_matter_mismatch_is_caught() {
        let err = same_scope(&ids(1, 2), &ids(1, 9)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Matter { .. }));
    }

    #[test]
    fn a_tenant_mismatch_is_reported_before_a_matter_mismatch() {
        // If both differ, the tenant is the outer boundary and the more
        // serious failure, so it must be the one reported.
        let err = same_scope(&ids(1, 2), &ids(9, 9)).unwrap_err();
        assert!(matches!(err, ScopeMismatch::Tenant { .. }));
    }

    #[test]
    fn the_error_message_names_both_values() {
        let err = same_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("tenant"), "{msg}");
        // IDs are identifiers, not content, so naming them aids diagnosis.
        assert!(msg.contains(&Uuid::from_u128(1).to_string()), "{msg}");
    }

    #[test]
    fn assert_document_scope_maps_a_mismatch_to_a_rag_error() {
        let err = assert_document_scope(&ids(1, 2), &ids(9, 2)).unwrap_err();
        assert!(matches!(err, super::super::RagError::Scope(_)));
    }
}