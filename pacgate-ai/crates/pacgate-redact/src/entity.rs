//! Identifier taxonomy.
//!
//! Four tiers, reported separately (spec section 7: recall is never blended).
//! Tier 1 is the checksum-backed set - structurally verifiable, so a miss
//! there is a defect, not a tuning choice.

use serde::{Deserialize, Serialize};

/// Recall-reporting tier. Tier 1 misses are defects; Tier 4 misses are risk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    /// Checksum-backed structured identifiers.
    One,
    /// Natural-person and organisation names, contact details.
    Two,
    /// Locations, dates, free-text quasi-identifiers.
    Three,
    /// Accounts, credentials, and other high-blast-radius values.
    Four,
}

/// How a matched identifier is represented in the outbound text.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaceholderPolicy {
    /// Replaced by an opaque token. Default for anything no machine parses.
    Opaque,
    /// Replaced by a structurally valid value of the same shape, so that a
    /// downstream parser (spreadsheet formula, template) still works.
    FormatPreserving,
    /// Deleted outright. Only for secrets, where even a shape is a leak.
    Remove,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityType {
    // Tier 1 - checksum-backed, Chinese jurisdiction
    CnResidentId,
    Uscc,
    CnMobile,
    BankCard,
    // Tier 1 - generic structured
    Email,
    // Tier 2 - names and contact
    PersonName,
    OrgName,
    Landline,
    PostalAddress,
    // Tier 3 - quasi-identifiers
    CaseNumber,
    RegistrationNumber,
    Location,
    // Tier 4 - accounts and secrets
    BankAccount,
    Credential,
    IpAddress,
}

impl EntityType {
    /// Every variant, for exhaustive iteration in tests and checklists.
    pub const ALL: &'static [EntityType] = &[
        EntityType::CnResidentId,
        EntityType::Uscc,
        EntityType::CnMobile,
        EntityType::BankCard,
        EntityType::Email,
        EntityType::PersonName,
        EntityType::OrgName,
        EntityType::Landline,
        EntityType::PostalAddress,
        EntityType::CaseNumber,
        EntityType::RegistrationNumber,
        EntityType::Location,
        EntityType::BankAccount,
        EntityType::Credential,
        EntityType::IpAddress,
    ];

    /// Stable string code used in the placeholder, the audit log and the ledger.
    pub fn code(&self) -> &'static str {
        match self {
            EntityType::CnResidentId => "CN_ID",
            EntityType::Uscc => "USCC",
            EntityType::CnMobile => "CN_MOBILE",
            EntityType::BankCard => "BANK_CARD",
            EntityType::Email => "EMAIL",
            EntityType::PersonName => "PERSON",
            EntityType::OrgName => "ORG",
            EntityType::Landline => "LANDLINE",
            EntityType::PostalAddress => "ADDRESS",
            EntityType::CaseNumber => "CASE_NO",
            EntityType::RegistrationNumber => "REG_NO",
            EntityType::Location => "LOCATION",
            EntityType::BankAccount => "BANK_ACCOUNT",
            EntityType::Credential => "CREDENTIAL",
            EntityType::IpAddress => "IP",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|e| e.code() == code)
    }

    pub fn tier(&self) -> Tier {
        match self {
            EntityType::CnResidentId
            | EntityType::Uscc
            | EntityType::CnMobile
            | EntityType::BankCard
            | EntityType::Email => Tier::One,
            EntityType::PersonName
            | EntityType::OrgName
            | EntityType::Landline
            | EntityType::PostalAddress => Tier::Two,
            EntityType::CaseNumber | EntityType::RegistrationNumber | EntityType::Location => {
                Tier::Three
            }
            EntityType::BankAccount | EntityType::Credential | EntityType::IpAddress => Tier::Four,
        }
    }

    /// Per-identifier representation policy (design gap 6).
    pub fn policy(&self) -> PlaceholderPolicy {
        match self {
            // A credential's shape is itself information. Remove it.
            EntityType::Credential => PlaceholderPolicy::Remove,
            // Downstream spreadsheets and templates parse these, so keep the shape.
            EntityType::BankAccount
            | EntityType::BankCard
            | EntityType::Uscc
            | EntityType::CnResidentId => PlaceholderPolicy::FormatPreserving,
            // Nothing machine-parses a name, org, address or case number.
            _ => PlaceholderPolicy::Opaque,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tier_one_is_the_checksum_backed_set() {
        // These must never be missed: they are structurally verifiable.
        assert_eq!(EntityType::CnResidentId.tier(), Tier::One);
        assert_eq!(EntityType::Uscc.tier(), Tier::One);
        assert_eq!(EntityType::BankCard.tier(), Tier::One);
        assert_eq!(EntityType::CnMobile.tier(), Tier::One);
    }

    #[test]
    fn credentials_are_removed_never_placeholdered() {
        assert_eq!(EntityType::Credential.policy(), PlaceholderPolicy::Remove);
    }

    #[test]
    fn account_numbers_keep_format_because_downstream_parses_them() {
        assert_eq!(
            EntityType::BankAccount.policy(),
            PlaceholderPolicy::FormatPreserving
        );
    }

    #[test]
    fn names_are_opaque_because_nothing_parses_them() {
        assert_eq!(EntityType::PersonName.policy(), PlaceholderPolicy::Opaque);
    }

    #[test]
    fn code_round_trips_and_codes_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for e in EntityType::ALL {
            assert_eq!(EntityType::from_code(e.code()), Some(*e));
            assert!(seen.insert(e.code()), "duplicate code: {}", e.code());
        }
        assert_eq!(EntityType::from_code("nope"), None);
    }
}