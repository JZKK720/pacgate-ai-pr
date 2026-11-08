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
///
/// There were three variants until 2026-11-03, and the middle one was a defect
/// rather than a policy. `FormatPreserving` rendered a number-shaped value as a
/// zeroed run of the same width with the allocation counter stamped into it, so
/// `91110105CA01ABCD26` left as `00000000XX00XXXX10`:
///
///   * the length, the letter positions and the check character survived, which
///     is the search template, so the mask did not actually remove information;
///   * the stamp was the ALLOCATION POSITION, so the same person got a different
///     mask in every document and two documents could not be joined;
///   * two distinct values could reach the same mask, which makes `restore`
///     resolve one subject to the other's number;
///   * the counter itself leaked - a mask said "third identifier in this file".
///
/// Meanwhile the same pipeline rendered plates, WeChat handles and permits as
/// opaque `[CODE_...]` tokens. Two mechanisms in one pass is why one of them
/// could rot unnoticed. As of 2026-11-03 there is ONE mechanism: an opaque token
/// derived from the value, and this enum records intent rather than shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlaceholderPolicy {
    /// Replaced by a token whose tag is derived from the value. The only
    /// representation any detected identifier uses.
    Opaque,
    /// Deleted outright. Only for secrets, where even a token is a signal that
    /// something was there, and the surrounding text is usually a secret line.
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
    CnTaxId,
    // Tier 1 - generic structured
    Email,
    // Tier 1 - pattern-anchored cross-jurisdiction IDs (no checksum exists;
    // the shape plus the mandatory letter prefix carries the structure).
    Passport,
    HkMoPermit,
    TaiwanPermit,
    // Tier 1 - overseas and minority identifiers (added 2026-11-03).
    //
    // The second review measured seven classes surviving verbatim, and two of
    // them (`TaxID`, `Juristic ID`) were confirmed still in plaintext inside
    // already-indexed chunks of a live matter. For a cross-border practice these
    // are not edge cases. Each is anchored on a published structural shape or on
    // its own printed label, never on "a long digit run".
    HkId,
    SgNric,
    MyId,
    MilitaryId,
    ThTaxId,
    ThJuristicId,
    // Tier 2 - names and contact
    PersonName,
    OrgName,
    Landline,
    PostalAddress,
    // Tier 3 - quasi-identifiers
    CaseNumber,
    RegistrationNumber,
    Location,
    /// 律师执业证号 - 17 digits with a fixed field layout, but no check digit.
    ///
    /// Was previously reported as `RegistrationNumber`, which conflated a
    /// natural person's licence with a company registration. Same detection
    /// mechanism (label plus bounded digit run), distinct reporting row.
    LawyerLicense,
    /// 车牌号 - province character plus authority letter plus 5-6 characters.
    ///
    /// A vehicle plate identifies its registered owner, and a plate in a
    /// contract is nearly always next to the owner's name.
    VehiclePlate,
    // Tier 3 - context-anchored: a bare 15-digit run is ambiguous, so the
    // 身份证/证件 label is the only thing that makes it an identifier.
    LegacyIdNumber,
    // Tier 4 - accounts and secrets
    BankAccount,
    /// 微信号 - an account handle, and for a Chinese client nearly always a
    /// live contact channel. Tier 4 for the same reason a bank account is.
    WeChatId,
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
        EntityType::CnTaxId,
        EntityType::Email,
        EntityType::Passport,
        EntityType::HkMoPermit,
        EntityType::TaiwanPermit,
        EntityType::HkId,
        EntityType::SgNric,
        EntityType::MyId,
        EntityType::MilitaryId,
        EntityType::ThTaxId,
        EntityType::ThJuristicId,
        EntityType::PersonName,
        EntityType::OrgName,
        EntityType::Landline,
        EntityType::PostalAddress,
        EntityType::CaseNumber,
        EntityType::RegistrationNumber,
        EntityType::Location,
        EntityType::LawyerLicense,
        EntityType::VehiclePlate,
        EntityType::LegacyIdNumber,
        EntityType::BankAccount,
        EntityType::WeChatId,
        EntityType::Credential,
        EntityType::IpAddress,
    ];

    /// The HMAC domain for this type: which types are DIFFERENT LABELS FOR THE SAME
    /// THING, and must therefore share one token.
    ///
    /// The code is a display label and an audit field; it must not decide identity.
    /// MEASURED 2026-11-03: `91440300MA5FL8XY3K` under 统一社会信用代码 became
    /// `[USCC_...]` while the SAME string under 纳税人识别号 became `[CN_TAX_ID_...]`.
    /// Since the three-in-one registration reform a USCC *is* the tax id, so one
    /// legal entity received two tokens and cross-document correlation - the whole
    /// point of value-derived tokens - failed in exactly the case it was built for.
    ///
    /// Same for BANK_CARD / BANK_ACCOUNT: `6217900123456789010` is one account
    /// whether or not the document happens to print 账号 in front of it.
    ///
    /// Everything else keeps its own domain, deliberately. A 13-digit Thai TaxID and
    /// a 13-digit juristic id are both digits; collapsing them would merge two
    /// unrelated registries into one tag space. The rule is "same real-world
    /// identifier", not "same shape".
    pub fn hash_family(&self) -> &'static str {
        match self {
            EntityType::Uscc => "ORG_REG",
            EntityType::CnTaxId => "ORG_REG",
            EntityType::BankCard => "BANK_ACCOUNT",
            EntityType::BankAccount => "BANK_ACCOUNT",
            other => other.code(),
        }
    }

    /// Stable string code used in the placeholder, the audit log and the ledger.
    pub fn code(&self) -> &'static str {
        match self {
            EntityType::CnResidentId => "CN_ID",
            EntityType::Uscc => "USCC",
            EntityType::CnMobile => "CN_MOBILE",
            EntityType::BankCard => "BANK_CARD",
            EntityType::CnTaxId => "CN_TAX_ID",
            EntityType::Email => "EMAIL",
            EntityType::Passport => "PASSPORT",
            EntityType::HkMoPermit => "HK_MO_PERMIT",
            EntityType::TaiwanPermit => "TW_PERMIT",
            EntityType::HkId => "HK_ID",
            EntityType::SgNric => "SG_NRIC",
            EntityType::MyId => "MY_ID",
            EntityType::MilitaryId => "MILITARY_ID",
            EntityType::ThTaxId => "TH_TAXID",
            EntityType::ThJuristicId => "TH_JURISTIC",
            EntityType::PersonName => "PERSON",
            EntityType::OrgName => "ORG",
            EntityType::Landline => "LANDLINE",
            EntityType::PostalAddress => "ADDRESS",
            EntityType::CaseNumber => "CASE_NO",
            EntityType::RegistrationNumber => "REG_NO",
            EntityType::Location => "LOCATION",
            EntityType::LawyerLicense => "LAWYER_NO",
            EntityType::VehiclePlate => "PLATE",
            EntityType::LegacyIdNumber => "LEGACY_ID",
            EntityType::BankAccount => "BANK_ACCOUNT",
            EntityType::WeChatId => "WECHAT",
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
            | EntityType::CnTaxId
            | EntityType::Email
            | EntityType::Passport
            | EntityType::HkMoPermit
            | EntityType::TaiwanPermit
            | EntityType::HkId
            | EntityType::SgNric
            | EntityType::MyId
            | EntityType::MilitaryId
            | EntityType::ThTaxId
            | EntityType::ThJuristicId => Tier::One,
            EntityType::PersonName
            | EntityType::OrgName
            | EntityType::Landline
            | EntityType::PostalAddress => Tier::Two,
            EntityType::CaseNumber
            | EntityType::RegistrationNumber
            | EntityType::Location
            | EntityType::LawyerLicense
            | EntityType::VehiclePlate
            | EntityType::LegacyIdNumber => Tier::Three,
            EntityType::BankAccount
            | EntityType::WeChatId
            | EntityType::Credential
            | EntityType::IpAddress => Tier::Four,
        }
    }

    /// Whether two spellings that differ only in letter case are the same value.
    ///
    /// True for every identifier whose alphabet is a published one and whose
    /// case is a printing artefact: an ID's check character `x`, a USCC's letters,
    /// a plate's authority letter. False for handles and addresses, where case is
    /// part of the value the platform will resolve - `ZhangSan` and `zhangsan` are
    /// two WeChat accounts, and merging them would attribute one person's messages
    /// to another.
    pub fn folds_case(&self) -> bool {
        !matches!(
            self,
            EntityType::WeChatId | EntityType::Email | EntityType::Credential
        )
    }

    /// Per-identifier representation policy (design gap 6).
    ///
    /// There is exactly ONE representation for an identifier: an opaque token
    /// whose tag is derived from the value. The old `FormatPreserving` policy is
    /// gone (see `PlaceholderPolicy`) because it was the defect, not a policy.
    ///
    /// What replaced its justification: shape preservation existed so a
    /// downstream spreadsheet or template would still parse the cell. That is a
    /// real requirement, but it was being met at an unacceptable price - the mask
    /// kept the value's length, its letter positions and its check character, so
    /// it disclosed the search template while claiming to remove information.
    /// The requirement is better met at the restore boundary, where the real
    /// value is put back from the server-side mapping; nothing downstream needs
    /// the sanitized text to be parseable AS a number.
    pub fn policy(&self) -> PlaceholderPolicy {
        match self {
            // A credential is the one thing that must leave no trace at all: a
            // token in its place would still mark the line as "a secret was
            // here", and the surrounding text is usually a config line where
            // that is itself a hint.
            EntityType::Credential => PlaceholderPolicy::Remove,
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

    /// The Tier-1 extension set (2026-10-06): cross-jurisdiction permit and
    /// passport numbers. No checksum exists for these anywhere, so the letter
    /// prefix IS the anchor: a bare digit run never qualifies.
    #[test]
    fn tier_one_extension_is_pattern_anchored() {
        assert_eq!(EntityType::Passport.tier(), Tier::One);
        assert_eq!(EntityType::HkMoPermit.tier(), Tier::One);
        assert_eq!(EntityType::TaiwanPermit.tier(), Tier::One);
    }

    /// The 2026-11-03 overseas/minority set. Two of these (Thai TaxID and
    /// Juristic ID) were found in plaintext inside already-indexed chunks, so
    /// they are Tier 1: a miss is a defect, not a tuning choice.
    #[test]
    fn the_overseas_set_is_tier_one_with_unique_codes() {
        for (entity, code) in [
            (EntityType::HkId, "HK_ID"),
            (EntityType::SgNric, "SG_NRIC"),
            (EntityType::MyId, "MY_ID"),
            (EntityType::MilitaryId, "MILITARY_ID"),
            (EntityType::ThTaxId, "TH_TAXID"),
            (EntityType::ThJuristicId, "TH_JURISTIC"),
        ] {
            assert_eq!(entity.tier(), Tier::One, "{entity:?} must be Tier 1");
            assert_eq!(entity.code(), code);
            assert_eq!(EntityType::from_code(code), Some(entity));
        }
    }

    /// A 15-digit legacy ID run has no checksum and an ambiguous shape, so it
    /// is deliberately Tier 3 and only fires with a document-label context.
    #[test]
    fn legacy_15_digit_id_is_context_anchored_tier_three() {
        assert_eq!(EntityType::LegacyIdNumber.tier(), Tier::Three);
        assert_eq!(EntityType::LegacyIdNumber.code(), "LEGACY_ID");
    }

    #[test]
    fn extension_codes_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for c in [
            "PASSPORT",
            "HK_MO_PERMIT",
            "TW_PERMIT",
            "LEGACY_ID",
            "CN_ID",
            "USCC",
        ] {
            assert!(seen.insert(c), "duplicate code: {c}");
            assert!(EntityType::from_code(c).is_some(), "code not mapped: {c}");
        }
    }

    #[test]
    fn credentials_are_removed_never_placeholdered() {
        assert_eq!(EntityType::Credential.policy(), PlaceholderPolicy::Remove);
    }

    /// Shape preservation is gone. It rendered a number-shaped value as a zeroed
    /// run carrying the allocation counter, which kept the value's length, letter
    /// layout and check character, drifted with position, and collided.
    ///
    /// MEASURED 2026-11-03: `91350100M000100Y43` and `91110105CA01ABCD26` both
    /// produced `00000000X000000X10` in one job - two companies, one placeholder.
    #[test]
    fn every_identifier_class_uses_one_representation() {
        for e in EntityType::ALL {
            let expected = match e {
                // A credential leaves no trace at all.
                EntityType::Credential => PlaceholderPolicy::Remove,
                _ => PlaceholderPolicy::Opaque,
            };
            assert_eq!(e.policy(), expected, "{e:?}");
        }
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