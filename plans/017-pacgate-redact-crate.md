# pacgate-redact Crate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `pacgate-redact` - the deterministic detection, placeholder, replace and verify crate that all sanitization flows through.

**Architecture:** A pure Rust library crate with no database, no network and no GPU. It consumes `text + spans` and never calls OCR (the boundary rule from design section 3.3). Detection is deterministic-first: checksum-validated rules run before any model, and the verifier re-scans with the *same* matcher that drove redaction, so a detected identifier cannot pass. Failures resolve to `Block`, never `Pass`.

**Tech Stack:** Rust 2021, `regex`, `sha2`, `serde`, `thiserror`, `uuid`, `once_cell`, `tracing`. All via `workspace.dependencies` - no new direct version pins.

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md`

**Scope note:** This is plan 1 of 4. It deliberately contains **no OCR, no database, no HTTP and no frontend**. Those are plans 2-4 (see "Follow-on plans" at the end). This crate is first because every other subsystem depends on its interfaces, and because it is fully testable on a laptop with no GPU and no containers.

## Global Constraints

Copied verbatim from the spec and repo conventions. Every task's requirements implicitly include this section.

- **Crate license:** `license.workspace = true` (AGPL-3.0-only). Never add a crate-level license that differs.
- **Workspace version:** `version.workspace = true`. Do not hardcode a version.
- **Edition:** 2021, `resolver = "2"` (workspace).
- **Dependencies:** add any new crate to `[workspace.dependencies]` in `pacgate-ai/Cargo.toml` **first**, then reference it as `name.workspace = true` in the crate manifest. No direct version pins inside crate manifests.
- **Fail-closed:** an unparseable input, an erroring detector, or an unverifiable result is `Verdict::Block`. There is no code path where an error yields `Verdict::Pass`.
- **The same-matcher rule:** the verifier must use the same detector set that produced the redaction. Divergent matchers are the failure mode this design exists to prevent.
- **Deterministic-first:** rules run before any model. The model (plan 2) proposes candidates; it never performs final replacement.
- **Recall over precision:** prefer over-redaction surfaced for review over a silent miss. Reported recall is **per tier, never blended**.
- **No naked-digit rules:** never detect an identifier from a bare "7+ digit" pattern (spec 8.4). Every Tier-1 rule requires a checksum, or a label/context anchor, or both.
- **One allocator per job:** cross-document placeholder consistency (spec 6.1) only holds if a single `Sanitizer` instance covers all documents in the job. Create one per job, not one per document.
- **Text conventions:** hyphens, not em-dashes, in all visible copy. Chinese and English must agree on meaning in any user-facing string.
- **No credentials:** no secret, token, password or key may appear in source, test fixtures, or commit messages.
---

### Task 1: Crate scaffold, error type and core span types

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/Cargo.toml`
- Create: `pacgate-ai/crates/pacgate-redact/src/lib.rs`
- Modify: `pacgate-ai/Cargo.toml` (workspace member + dependencies)

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `pub enum RedactError { InvalidInput(String), Internal(String) }` with `pub fn is_fatal(&self) -> bool`
  - `pub struct Match { pub start: usize, pub end: usize, pub entity: EntityType, pub text: String, pub confidence: f32, pub source: MatchSource }` - byte offsets, half-open `[start, end)`
  - `pub enum MatchSource { Checksum, Pattern, Context, Model }`
  - `pub type RedactResult<T> = Result<T, RedactError>`
  - `impl Match { pub fn len(&self) -> usize; pub fn is_empty(&self) -> bool; pub fn overlaps(&self, other: &Match) -> bool }`

- [ ] **Step 1: Add the workspace member and dependencies**

Edit `pacgate-ai/Cargo.toml`. Add `"crates/pacgate-redact",` to `members`, immediately after `"crates/pacgate-auth",`. Append to `[workspace.dependencies]`:

```toml
# Redaction
sha2 = { version = "0.10", features = ["std"] }
unicode-normalization = "0.1"
```

`regex`, `serde`, `serde_json`, `thiserror`, `uuid`, `tracing`, `once_cell` and `anyhow` already exist in `[workspace.dependencies]`. Do not re-add them.

- [ ] **Step 2: Write the crate manifest**

Create `pacgate-ai/crates/pacgate-redact/Cargo.toml`:

```toml
[package]
name = "pacgate-redact"
version.workspace = true
edition.workspace = true
license.workspace = true

[dependencies]
pacgate-core                    = { path = "../pacgate-core" }
regex.workspace                 = true
serde.workspace                 = true
serde_json.workspace            = true
thiserror.workspace             = true
uuid.workspace                  = true
tracing.workspace               = true
sha2.workspace                  = true
once_cell.workspace             = true
unicode-normalization.workspace = true

[dev-dependencies]
anyhow.workspace = true
```

- [ ] **Step 3: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/lib.rs`:

```rust
//! pacgate-redact - deterministic detection, redaction and verification.
//!
//! This crate consumes text plus spans. It never opens a file and never
//! calls an OCR service; extraction is a separate capability (design 2).

use serde::{Deserialize, Serialize};

pub mod checksum;
pub mod detect;
pub mod entity;

/// Errors from detection, redaction or verification.
///
/// `is_fatal` exists so callers can honour the fail-closed rule: anything
/// fatal must become `Verdict::Block`, never `Verdict::Pass`.
#[derive(Debug, thiserror::Error)]
pub enum RedactError {
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("internal error: {0}")]
    Internal(String),
}

impl RedactError {
    /// True when the caller may not proceed to a `Pass` verdict.
    pub fn is_fatal(&self) -> bool {
        matches!(self, RedactError::Internal(_))
    }
}

pub type RedactResult<T> = Result<T, RedactError>;

/// Which mechanism produced a match. Recorded so the verifier can prove it
/// used the same matcher that drove redaction, and so the review panel can
/// show the client *why* something was redacted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchSource {
    /// A structural/checksum validator accepted it. Strongest signal.
    Checksum,
    /// A regex pattern matched, but no checksum was available.
    Pattern,
    /// A pattern plus a label or surrounding context.
    Context,
    /// A local NER model proposed it. Never authoritative on its own.
    Model,
}

/// A detected span. Offsets are byte offsets, half-open `[start, end)`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    pub entity: EntityType,
    pub text: String,
    pub confidence: f32,
    pub source: MatchSource,
}

impl Match {
    pub fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }

    pub fn is_empty(&self) -> bool {
        self.end <= self.start
    }

    /// True when this match overlaps `other` at all.
    pub fn overlaps(&self, other: &Match) -> bool {
        self.start < other.end && other.start < self.end
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn match_uses_half_open_byte_offsets() {
        let m = Match {
            start: 0,
            end: 4,
            entity: EntityType::CnMobile,
            text: "1380".to_string(),
            confidence: 1.0,
            source: MatchSource::Checksum,
        };
        assert_eq!(m.len(), 4);
        assert!(!m.is_empty());
    }

    #[test]
    fn error_is_fatal_for_internal_but_not_invalid_input() {
        assert!(!RedactError::InvalidInput("x".into()).is_fatal());
        assert!(RedactError::Internal("x".into()).is_fatal());
    }
}
```

Create `pacgate-ai/crates/pacgate-redact/src/entity.rs` containing only:

```rust
//! Identifier taxonomy. Filled in by Task 2.
```

Create `pacgate-ai/crates/pacgate-redact/src/checksum.rs` containing only:

```rust
//! Checksum validators. Filled in by Task 3.
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact`
Expected: FAIL - `cannot find type EntityType in this scope`, because the stub `entity.rs` does not define it yet.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/Cargo.toml pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): scaffold pacgate-redact crate with core span and error types"
```

Note: the crate does not compile until Task 2 defines `EntityType`. That is deliberate - Task 1's deliverable is the workspace wiring, and Task 2's Step 4 is where the first green build appears.

---

### Task 2: Identifier taxonomy

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/entity.rs`

**Interfaces:**
- Consumes: `Match`, `MatchSource` (Task 1).
- Produces:
  - `pub enum EntityType` - the v1 identifier set; `pub const ALL: &'static [EntityType]`
  - `pub enum Tier { One, Two, Three, Four }`
  - `pub enum PlaceholderPolicy { Opaque, FormatPreserving, Remove }`
  - `impl EntityType { pub fn code(&self) -> &'static str; pub fn tier(&self) -> Tier; pub fn policy(&self) -> PlaceholderPolicy; pub fn from_code(code: &str) -> Option<Self> }`

- [ ] **Step 1: Write the failing test**

Append to `pacgate-ai/crates/pacgate-redact/src/entity.rs`:

```rust
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact entity::`
Expected: FAIL - cannot find type `EntityType`, `Tier`.

- [ ] **Step 3: Write the minimal implementation**

Replace the contents of `pacgate-ai/crates/pacgate-redact/src/entity.rs` with:

```rust
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact entity::`
Expected: PASS for all five tests. This is the crate's first green build, which also validates Task 1's scaffold.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add tiered identifier taxonomy with per-entity placeholder policy"
```

---

### Task 3: Checksum validators

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/checksum.rs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub fn validate_cn_resident_id(s: &str) -> bool`
  - `pub fn validate_uscc(s: &str) -> bool`
  - `pub fn validate_luhn(digits: &str) -> bool`

These enable the "no naked-digit rules" constraint (spec 8.4): every Tier-1 rule calls one of these, so a bare digit run can never be reported as an identifier.

- [ ] **Step 1: Write the failing test**

Replace the contents of `pacgate-ai/crates/pacgate-redact/src/checksum.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_a_known_valid_resident_id() {
        // Synthetic. 11010519491231002X is the canonical ISO 7064 MOD 11-2 example.
        assert!(validate_cn_resident_id("11010519491231002X"));
    }

    #[test]
    fn rejects_a_resident_id_with_a_bad_check_digit() {
        assert!(!validate_cn_resident_id("110105194912310021"));
        assert!(!validate_cn_resident_id("11010519491231002Y"));
    }

    #[test]
    fn rejects_wrong_length_and_non_digit_bodies() {
        assert!(!validate_cn_resident_id("1101051949123100"));
        assert!(!validate_cn_resident_id("11010519491231002"));
        assert!(!validate_cn_resident_id("11010519491A31002X"));
    }

    #[test]
    fn accepts_a_known_valid_uscc() {
        // Synthetic. 91350100M000100Y43 is a published MOD-31 worked example.
        assert!(validate_uscc("91350100M000100Y43"));
    }

    #[test]
    fn rejects_uscc_with_illegal_chars_and_bad_check() {
        // I, O, S, V, Z are never used in the USCC charset.
        assert!(!validate_uscc("91350100M000100Y4I"));
        assert!(!validate_uscc("91350100M000100Y44"));
    }

    #[test]
    fn luhn_accepts_known_valid_and_rejects_off_by_one() {
        assert!(validate_luhn("4111111111111111"));
        assert!(!validate_luhn("4111111111111112"));
    }

    #[test]
    fn all_validators_reject_empty_and_short_input() {
        assert!(!validate_cn_resident_id(""));
        assert!(!validate_uscc(""));
        assert!(!validate_luhn(""));
        assert!(!validate_luhn("41111111111"));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact checksum::`
Expected: FAIL - cannot find function `validate_cn_resident_id`, `validate_uscc`, `validate_luhn`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/checksum.rs`, above the test module:

```rust
//! Structural validators for China-jurisdiction and generic identifiers.
//!
//! Every Tier-1 detector calls into this module. A pattern match alone is
//! never enough: spec 8.4 forbids identifying an identifier from a bare
//! digit run, because that is exactly how account numbers, amounts and
//! trademark numbers get confused.

/// China resident ID (身份证号), 18-digit ISO 7064 MOD 11-2.
///
/// Layout: 6-digit region + 8-digit birthdate + 3-digit sequence + 1 check.
/// The final character may be `X` (uppercase) representing 10.
pub fn validate_cn_resident_id(s: &str) -> bool {
    const WEIGHTS: [u32; 17] = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    const CHECK: [char; 11] = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];

    let chars: Vec<char> = s.trim().chars().collect();
    if chars.len() != 18 {
        return false;
    }

    let mut sum: u32 = 0;
    for (i, c) in chars.iter().take(17).enumerate() {
        let Some(d) = c.to_digit(10) else {
            return false;
        };
        sum += d * WEIGHTS[i];
    }

    chars[17] == CHECK[(sum % 11) as usize]
}

/// Unified Social Credit Code (统一社会信用代码), 18 chars, MOD 31.
///
/// Charset is 31 symbols: digits plus uppercase letters minus I, O, S, V, Z.
pub fn validate_uscc(s: &str) -> bool {
    const CHARSET: &[u8] = b"0123456789ABCDEFGHJKLMNPQRTUWXY";
    const WEIGHTS: [u32; 17] = [
        1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28,
    ];

    let s = s.trim();
    if s.len() != 18 || !s.is_ascii() {
        return false;
    }
    let bytes = s.as_bytes();

    let mut sum: u32 = 0;
    for (i, b) in bytes.iter().take(17).enumerate() {
        let Some(idx) = CHARSET.iter().position(|c| c == b) else {
            return false;
        };
        sum += idx as u32 * WEIGHTS[i];
    }

    let check = 31 - (sum % 31);
    let check = if check == 31 { 0 } else { check };
    bytes[17] == CHARSET[check as usize]
}

/// Luhn (ISO/IEC 7812) for bank card numbers.
///
/// Does not validate the issuer or the exact length beyond a sane floor; the
/// detector layer applies the length and prefix rules.
pub fn validate_luhn(digits: &str) -> bool {
    let digits = digits.trim();
    if digits.len() < 12 || !digits.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }

    let mut sum: u32 = 0;
    let mut double = false;
    for c in digits.chars().rev() {
        let Some(mut d) = c.to_digit(10) else {
            return false;
        };
        if double {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        double = !double;
    }
    sum % 10 == 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact checksum::`
Expected: PASS for all seven tests.

If `accepts_a_known_valid_uscc` fails, the weight or charset table is wrong: verify the weights sum to a case where `31 - (sum % 31)` indexes to `'3'`. Do not change the test to match the code.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add MOD 11-2, MOD 31 and Luhn checksum validators"
```

---

### Task 4: Tier 1 deterministic detectors

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs`
- Create: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod detect;` if absent)

**Interfaces:**
- Consumes: `Match`, `MatchSource` (Task 1); `EntityType` (Task 2); the validators (Task 3).
- Produces:
  - `pub trait Detector: Send + Sync { fn detect(&self, text: &str) -> RedactResult<Vec<Match>>; fn name(&self) -> &'static str }`
  - `pub struct TierOneDetector` implementing `Detector`, with `pub fn new() -> Self`
  - `pub fn tier_one_detectors() -> Vec<Box<dyn Detector>>`

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs` containing only:

```rust
//! Detection layer. Filled in by Task 4.
```

Create `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs` with only the test module:

```rust
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact detect::rules`
Expected: FAIL - cannot find type `TierOneDetector`.

- [ ] **Step 3: Write the minimal implementation**

Replace the contents of `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs` with:

```rust
//! Detection layer. Deterministic rules first; models are additive.

pub mod noise;
pub mod rules;

pub use rules::TierOneDetector;

use crate::{Match, RedactResult};

/// A source of candidate matches.
///
/// Implementors must be pure and deterministic: given the same text they
/// return the same matches. The verifier relies on that identity.
pub trait Detector: Send + Sync {
    fn detect(&self, text: &str) -> RedactResult<Vec<Match>>;
    fn name(&self) -> &'static str;
}

/// The Tier-1 detector set used both for redaction and for verification.
pub fn tier_one_detectors() -> Vec<Box<dyn Detector>> {
    vec![Box::new(TierOneDetector::new())]
}
```

Create an empty `pacgate-ai/crates/pacgate-redact/src/detect/noise.rs` containing only:

```rust
//! Noise suppression. Filled in by Task 5.
```

Prepend to `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`, above the test module:

```rust
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact detect::rules`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add checksum-anchored Tier-1 detectors for ID, USCC, mobile, card, email"
```

---

### Task 5: Noise suppression and context sensitivity

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/noise.rs`

**Interfaces:**
- Consumes: `Match` (Task 1); `EntityType` (Task 2).
- Produces:
  - `pub struct NoiseFilter` with `pub fn new() -> Self` and `pub fn apply(&self, text: &str, matches: Vec<Match>) -> Vec<Match>`
  - `pub fn is_public_case_number(text: &str, matched: &str) -> bool`
  - `pub fn drop_public_citations(text: &str, matches: Vec<Match>) -> Vec<Match>`

Implements spec 8.4 (数字规则必须控制误报) and 2.1 (按上下文判断). Its job is to *remove* matches that look like identifiers but are not this matter's - notably a public case citation, which must be preserved so the reference can still be verified.

- [ ] **Step 1: Write the failing test**

Replace the contents of `pacgate-ai/crates/pacgate-redact/src/detect/noise.rs` with only the test module:

```rust
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
        let text = "参见 (2019)最高法民终1234号 与本案 案号 XXXX";
        let citation = Match {
            start: 3,
            end: 21,
            entity: EntityType::CaseNumber,
            text: "(2019)最高法民终1234号".to_string(),
            confidence: 0.9,
            source: MatchSource::Context,
        };
        let kept = drop_public_citations(text, vec![citation]);
        assert!(kept.is_empty(), "a recognised public citation is preserved, not redacted");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact detect::noise`
Expected: FAIL - cannot find type `NoiseFilter`, function `is_public_case_number`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/detect/noise.rs`, above the test module:

```rust
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact detect::noise`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add deterministic noise suppression and public-citation preservation"
```

---

### Task 6: Placeholder allocation

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/placeholder.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod placeholder;`)

**Interfaces:**
- Consumes: `EntityType`, `PlaceholderPolicy` (Task 2).
- Produces:
  - `pub struct PlaceholderAllocator` with `pub fn new() -> Self`, `pub fn allocate(&mut self, entity: EntityType, original: &str) -> String`, `pub fn len(&self) -> usize`, `pub fn is_empty(&self) -> bool`, `pub fn entries(&self) -> Vec<(&EntityType, &str, &str)>`
  - Guarantee: the same `(entity, original)` pair in one allocator always yields the same placeholder (spec 6.1).

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/placeholder.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::EntityType;

    #[test]
    fn same_value_gets_the_same_placeholder() {
        let mut a = PlaceholderAllocator::new();
        let first = a.allocate(EntityType::PersonName, "张三");
        let second = a.allocate(EntityType::PersonName, "张三");
        assert_eq!(first, second, "spec 6.1 requires consistent placeholders");
    }

    #[test]
    fn similar_but_distinct_values_do_not_merge() {
        // Spec 9: 名称相似的不同主体 must not be merged.
        let mut a = PlaceholderAllocator::new();
        let one = a.allocate(EntityType::PersonName, "张三");
        let two = a.allocate(EntityType::PersonName, "张峰");
        assert_ne!(one, two);
    }

    #[test]
    fn different_entities_get_distinct_placeholder_namespaces() {
        let mut a = PlaceholderAllocator::new();
        let person = a.allocate(EntityType::PersonName, "甲");
        let org = a.allocate(EntityType::OrgName, "甲");
        assert_ne!(person, org);
        assert!(person.contains("PERSON"));
        assert!(org.contains("ORG"));
    }

    #[test]
    fn opaque_placeholders_do_not_leak_length_or_script() {
        let mut a = PlaceholderAllocator::new();
        let p = a.allocate(EntityType::PersonName, "张三丰");
        assert!(!p.contains('3'));
        assert!(!p.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)));
    }

    #[test]
    fn format_preserving_placeholder_keeps_shape_and_validates() {
        let mut a = PlaceholderAllocator::new();
        let p = a.allocate(EntityType::BankCard, "4111111111111111");
        assert_eq!(p.len(), 16, "a downstream parser must still see 16 digits");
        assert!(p.chars().all(|c| c.is_ascii_digit()));
        assert!(
            crate::checksum::validate_luhn(&p),
            "a format-preserving card placeholder should itself pass Luhn"
        );
    }

    #[test]
    fn allocator_is_deterministic_across_instances_for_the_same_order() {
        let mut a = PlaceholderAllocator::new();
        let mut b = PlaceholderAllocator::new();
        assert_eq!(
            a.allocate(EntityType::PersonName, "甲"),
            b.allocate(EntityType::PersonName, "甲")
        );
    }

    #[test]
    fn entries_reports_the_mapping_for_the_ledger() {
        let mut a = PlaceholderAllocator::new();
        a.allocate(EntityType::PersonName, "甲");
        a.allocate(EntityType::OrgName, "乙");
        assert_eq!(a.len(), 2);
        assert_eq!(a.entries().len(), 2);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact placeholder::`
Expected: FAIL - cannot find type `PlaceholderAllocator`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/placeholder.rs`:

```rust
//! Placeholder allocation.
//!
//! Two properties are contractual:
//!   section 6.1 占位符一致性      - the same value always maps to the same
//!                                  placeholder, so a document set stays
//!                                  internally consistent after redaction.
//!   section 9   名称相似的不同主体 - near-identical values must NOT be
//!                                  merged, so the key is the exact original
//!                                  string, never a normalised form.
//!
//! Allocation follows first-seen order, which is reproducible for a given
//! input sequence without a random source or a seed.

use std::collections::HashMap;

use crate::entity::{EntityType, PlaceholderPolicy};

/// Maps exact original values to stable placeholders.
///
/// One allocator is one job. Never share an allocator across matters
/// (spec 6.2 映射隔离).
#[derive(Debug, Default)]
pub struct PlaceholderAllocator {
    /// (entity, exact original) -> placeholder
    assigned: HashMap<(EntityType, String), String>,
}

impl PlaceholderAllocator {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.assigned.len()
    }

    pub fn is_empty(&self) -> bool {
        self.assigned.is_empty()
    }

    /// Allocate, or return the existing placeholder for this exact value.
    pub fn allocate(&mut self, entity: EntityType, original: &str) -> String {
        let key = (entity, original.to_string());
        if let Some(existing) = self.assigned.get(&key) {
            return existing.clone();
        }

        let index = self.assigned.len() + 1;
        let placeholder = match entity.policy() {
            PlaceholderPolicy::Opaque => format!("[{}_{}]", entity.code(), index),
            PlaceholderPolicy::FormatPreserving => format_preserving(entity, original, index),
            PlaceholderPolicy::Remove => String::new(),
        };

        self.assigned.insert(key, placeholder.clone());
        placeholder
    }

    /// Read-only view of the mapping, for the audit ledger. Sorted by
    /// placeholder so the output is stable across runs.
    pub fn entries(&self) -> Vec<(&EntityType, &str, &str)> {
        let mut v: Vec<(&EntityType, &str, &str)> = self
            .assigned
            .iter()
            .map(|((e, orig), ph)| (e, orig.as_str(), ph.as_str()))
            .collect();
        v.sort_by(|a, b| a.2.cmp(b.2));
        v
    }
}

/// Build a placeholder with the same shape as the original, so a downstream
/// parser still works. For Luhn-checked card numbers the placeholder is made
/// to pass Luhn, so downstream validation does not reject it.
fn format_preserving(entity: EntityType, original: &str, index: usize) -> String {
    let width = original.chars().count().clamp(12, 24);

    match entity {
        EntityType::BankCard => {
            let body_w = width.saturating_sub(1);
            let seed = format!("{:0>body_w$}", index, body_w = body_w);
            let body: String = seed
                .chars()
                .map(|c| if c.is_ascii_digit() { c } else { '0' })
                .collect();
            let check = luhn_check_digit(&body);
            format!("{body}{check}")
        }
        _ => {
            // Keep the first and last characters so format sniffers still
            // recognise the shape; neutralise the middle.
            let chars: Vec<char> = original
                .chars()
                .map(|c| if c.is_ascii_digit() { '0' } else { 'X' })
                .collect();
            if chars.len() <= 2 {
                return chars.into_iter().collect();
            }
            let last = chars.len() - 1;
            let mut out = String::with_capacity(chars.len());
            out.push(chars[0]);
            for c in chars.iter().take(last).skip(1) {
                out.push(*c);
            }
            out.push(chars[last]);
            out
        }
    }
}

/// Compute the Luhn check digit for a digit body.
fn luhn_check_digit(body: &str) -> char {
    let mut sum: u32 = 0;
    let mut double = true;
    for c in body.chars().rev() {
        let Some(mut d) = c.to_digit(10) else {
            continue;
        };
        if double {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        double = !double;
    }
    let check = (10 - (sum % 10)) % 10;
    std::char::from_digit(check, 10).unwrap_or('0')
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact placeholder::`
Expected: PASS for all seven tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add stable placeholder allocator with opaque and format-preserving policies"
```

---

### Task 7: Job-scoped mapping store

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/mapping.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod mapping;`)

**Interfaces:**
- Consumes: `EntityType` (Task 2); `RedactError` (Task 1).
- Produces:
  - `pub struct JobId(pub uuid::Uuid)` with `pub fn new() -> Self`
  - `pub struct MappingVersion(pub u32)` with `pub const CURRENT: MappingVersion`
  - `pub struct Mapping` with `pub fn new(version: MappingVersion) -> Self`, `pub fn job_id(&self) -> &JobId`, `pub fn version(&self) -> MappingVersion`, `pub fn insert(&mut self, placeholder: &str, original: &str)`, `pub fn insert_typed(&mut self, placeholder: &str, entity: EntityType, original: &str)`, `pub fn restore(&self, text: &str, version: MappingVersion) -> RedactResult<String>`, `pub fn entry_count(&self) -> usize`
  - Guarantee: `restore` with a mismatched `version`, or with an unresolvable placeholder, fails with `RedactError::InvalidInput` (design section 6).

This is the crate-side half of the vault boundary. The real vault lives in `pacgate-api`; this models the mapping so the crate is testable in isolation. Plan 3 wires it to Postgres.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/mapping.rs` with only the test module:

```rust
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
        // Lowercase content is not placeholder-shaped, so it is not an error.
        let out = m.restore("见附件 [见附页] 及 [PERSON_1]", m.version()).unwrap();
        assert_eq!(out, "见附件 [见附页] 及 张三");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact mapping::`
Expected: FAIL - cannot find type `Mapping`, `JobId`, `MappingVersion`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/mapping.rs`:

```rust
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact mapping::`
Expected: PASS for all eight tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add job-scoped mapping with strict version-checked restore"
```

---

### Task 8: Redaction engine

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/replace.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod replace;`)

**Interfaces:**
- Consumes: `Match` (Task 1); `EntityType`, `PlaceholderPolicy` (Task 2); `PlaceholderAllocator` (Task 6).
- Produces:
  - `pub struct AppliedRedaction { pub entity: EntityType, pub placeholder: String, pub start: usize, pub end: usize, pub source: MatchSource }`
  - `pub struct Redaction { pub text: String, pub applied: Vec<AppliedRedaction> }`
  - `pub struct Redactor` with `pub fn new() -> Self`, `pub fn redact(&mut self, text: &str, matches: &[Match]) -> RedactResult<Redaction>`, `pub fn allocator(&self) -> &PlaceholderAllocator`

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/replace.rs` with only the test module:

```rust
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact replace::`
Expected: FAIL - cannot find type `Redactor`, `Redaction`, `AppliedRedaction`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/replace.rs`:

```rust
//! The replacement engine.
//!
//! No model is consulted here. By the time text reaches this module the
//! decision has already been made; this only applies it.
//!
//! Offsets are validated before any splicing. An out-of-range or
//! non-char-boundary offset is a fatal error, never a panic and never a
//! silent skip (design section 6).

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact replace::`
Expected: PASS for all eight tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add replacement engine with span validation and overlap rejection"
```

---

### Task 9: Verifier and verdict

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/verify.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod verify;`)

**Interfaces:**
- Consumes: `Detector`, `tier_one_detectors()` (Task 4); `Match` (Task 1).
- Produces:
  - `pub enum Verdict { Pass, Block }` with `pub fn is_block(&self) -> bool`
  - `pub struct Verification { pub verdict: Verdict, pub residue: Vec<Match>, pub notes: Vec<String> }`
  - `pub fn verify(redacted: &str, detectors: &[Box<dyn Detector>]) -> Verification`

This is the load-bearing safety function. It re-runs the **same detector set** that drove redaction (design section 4, the same-matcher rule) and blocks if anything survives. Every error path resolves to `Block`.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/verify.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::tier_one_detectors;

    #[test]
    fn clean_text_passes() {
        let v = verify("本所同意上述条款。", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Pass);
        assert!(v.residue.is_empty());
    }

    #[test]
    fn a_surviving_resident_id_blocks() {
        let v = verify("残留 11010519491231002X", &tier_one_detectors());
        assert_eq!(v.verdict, Verdict::Block);
        assert_eq!(v.residue.len(), 1);
    }

    #[test]
    fn a_surviving_email_blocks() {
        let v = verify("残留 a@b.com", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn placeholder_shaped_residue_beside_real_data_blocks() {
        // The SANITIZATION_RESIDUE pattern: a header scrubbed while the body
        // was not.
        let v = verify("[CN_ID_1] 但 11010519491231002X 仍在", &tier_one_detectors());
        assert!(v.verdict.is_block());
    }

    #[test]
    fn an_empty_detector_set_blocks_rather_than_passing() {
        // Fail closed: with nothing to check against we cannot assert safety.
        let v = verify("anything", &[]);
        assert!(v.verdict.is_block());
        assert!(!v.notes.is_empty());
    }

    #[test]
    fn verdict_is_block_when_a_detector_errors() {
        struct Exploding;
        impl Detector for Exploding {
            fn detect(&self, _t: &str) -> crate::RedactResult<Vec<crate::Match>> {
                Err(crate::RedactError::Internal("boom".into()))
            }
            fn name(&self) -> &'static str {
                "exploding"
            }
        }
        let v = verify("text", &[Box::new(Exploding)]);
        assert_eq!(v.verdict, Verdict::Block);
    }

    #[test]
    fn notes_record_how_the_verdict_was_reached() {
        let v = verify("a@b.com", &tier_one_detectors());
        assert!(!v.notes.is_empty(), "the audit record needs a reason");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact verify::`
Expected: FAIL - cannot find type `Verdict`, `Verification`, function `verify`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/verify.rs`:

```rust
//! Independent outbound verification.
//!
//! The client spec 8.6 requires that a failed check stops the outbound send,
//! and that the model may not self-approve. Three independent precedents
//! converge on the same mechanism, adopted here:
//!
//!   "Since the residual check uses the same matcher that drove redaction, a
//!    detected credential cannot pass." (microsoft/agent-governance-toolkit)
//!   "Fail closed. If anything goes wrong - unparseable output, a parsing
//!    error, an exception, invalid encoding - the item is treated as BLOCK,
//!    never PASS." (leak-inspect-v1)
//!
//! Consequently: no error path in this module yields `Pass`.

use serde::{Deserialize, Serialize};

use crate::detect::Detector;
use crate::Match;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Pass,
    Block,
}

impl Verdict {
    pub fn is_block(&self) -> bool {
        matches!(self, Verdict::Block)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Verification {
    pub verdict: Verdict,
    /// What survived. Surfaced to the review panel, never auto-cleared.
    pub residue: Vec<Match>,
    /// Why the verdict was reached, for the audit record.
    pub notes: Vec<String>,
}

/// Re-scan `redacted` with the same detector set used to redact it.
///
/// Returns `Block` when: any detector reports a surviving match, any detector
/// errors, or the detector set is empty (we would be asserting safety with no
/// evidence).
pub fn verify(redacted: &str, detectors: &[Box<dyn Detector>]) -> Verification {
    let mut notes: Vec<String> = Vec::new();

    if detectors.is_empty() {
        notes.push(
            "no detectors supplied: cannot assert safety, so the verdict is Block (fail closed)"
                .to_string(),
        );
        return Verification {
            verdict: Verdict::Block,
            residue: Vec::new(),
            notes,
        };
    }

    let mut residue: Vec<Match> = Vec::new();

    for d in detectors {
        match d.detect(redacted) {
            Ok(found) => {
                if !found.is_empty() {
                    notes.push(format!("{}: {} surviving match(es)", d.name(), found.len()));
                    residue.extend(found);
                }
            }
            Err(e) => {
                notes.push(format!("{}: detector failed ({e}) - blocking", d.name()));
                return Verification {
                    verdict: Verdict::Block,
                    residue,
                    notes,
                };
            }
        }
    }

    let verdict = if residue.is_empty() {
        notes.push(format!(
            "{} detector(s) reported no residue",
            detectors.len()
        ));
        Verdict::Pass
    } else {
        Verdict::Block
    };

    residue.sort_by_key(|m| (m.start, m.end));

    Verification {
        verdict,
        residue,
        notes,
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact verify::`
Expected: PASS for all seven tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add fail-closed verifier using the same matcher that drove redaction"
```

---

### Task 10: Redaction ledger with SHA-256 provenance

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/ledger.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod ledger;`)

**Interfaces:**
- Consumes: `Redaction` (Task 8); `Verification`, `Verdict` (Task 9); `JobId`, `MappingVersion` (Task 7).
- Produces:
  - `pub struct RedactionLedger` with `pub fn seal(job_id: JobId, version: MappingVersion, input: &str, redaction: &Redaction, verification: &Verification) -> Self`
  - `pub fn input_sha256(&self) -> &str`, `pub fn output_sha256(&self) -> &str`, `pub fn verdict(&self) -> Verdict`, `pub fn mapping_version(&self) -> MappingVersion`, `pub fn to_json(&self) -> RedactResult<String>`

Ledger entries are written through `audit_log` in plan 3. This task produces the value object and the digest scheme, which is the part with real logic worth testing.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/ledger.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{JobId, MappingVersion, Redaction, Verdict, Verification};

    fn redaction(text: &str) -> Redaction {
        Redaction {
            text: text.to_string(),
            applied: Vec::new(),
        }
    }

    fn verification(v: Verdict) -> Verification {
        Verification {
            verdict: v,
            residue: Vec::new(),
            notes: Vec::new(),
        }
    }

    #[test]
    fn seals_digests_of_both_sides() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "原始 张三",
            &redaction("原始 [PERSON_1]"),
            &verification(Verdict::Pass),
        );
        assert_eq!(l.input_sha256().len(), 64);
        assert_eq!(l.output_sha256().len(), 64);
        assert_ne!(l.input_sha256(), l.output_sha256());
    }

    #[test]
    fn digests_are_deterministic() {
        let a = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        let b = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        assert_eq!(a.input_sha256(), b.input_sha256());
        assert_eq!(a.output_sha256(), b.output_sha256());
    }

    #[test]
    fn records_the_verdict_and_version() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion(7),
            "x",
            &redaction("y"),
            &verification(Verdict::Block),
        );
        assert_eq!(l.verdict(), Verdict::Block);
        assert_eq!(l.mapping_version(), MappingVersion(7));
    }

    #[test]
    fn serialises_to_json_without_the_originals() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "secret 张三",
            &redaction("secret [PERSON_1]"),
            &verification(Verdict::Pass),
        );
        let json = l.to_json().unwrap();
        assert!(
            !json.contains("张三"),
            "the ledger must not carry pre-redaction content"
        );
        assert!(json.contains("input_sha256"));
    }

    #[test]
    fn ledger_round_trips_through_json() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        let json = l.to_json().unwrap();
        let back: RedactionLedger = serde_json::from_str(&json).unwrap();
        assert_eq!(back.output_sha256(), l.output_sha256());
    }

    #[test]
    fn records_the_ruleset_version_so_history_is_not_silently_reinterpreted() {
        let l = RedactionLedger::seal(
            JobId::new(),
            MappingVersion::CURRENT,
            "x",
            &redaction("y"),
            &verification(Verdict::Pass),
        );
        assert!(!l.ruleset_version.is_empty());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact ledger::`
Expected: FAIL - cannot find type `RedactionLedger`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/ledger.rs`:

```rust
//! Cryptographic provenance for one sanitization job.
//!
//! Pattern adapted from Philter's redaction ledger and the NIST SP 800-88
//! approach to documenting a transformation: record *that* a transformation
//! happened and *what* it produced, without retaining the pre-transformation
//! content in the record itself.
//!
//! The ledger therefore stores digests only. The originals live in the vault
//! (`pacgate-api`), never here, and never in deer-flow.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::mapping::{JobId, MappingVersion};
use crate::replace::Redaction;
use crate::verify::{Verdict, Verification};
use crate::RedactResult;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RedactionLedger {
    pub job_id: String,
    pub mapping_version: u32,
    pub input_sha256: String,
    pub output_sha256: String,
    pub redaction_count: usize,
    pub verdict: Verdict,
    /// Rule and mapping version, so a later rule change cannot silently
    /// re-interpret history (spec 6.3, 8.8, 9 acceptance).
    pub ruleset_version: String,
    pub model_version: Option<String>,
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex_encode(&hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

impl RedactionLedger {
    pub fn seal(
        job_id: JobId,
        version: MappingVersion,
        input: &str,
        redaction: &Redaction,
        verification: &Verification,
    ) -> Self {
        Self {
            job_id: job_id.0.to_string(),
            mapping_version: version.0,
            input_sha256: sha256_hex(input),
            output_sha256: sha256_hex(&redaction.text),
            redaction_count: redaction.applied.len(),
            verdict: verification.verdict,
            ruleset_version: env!("CARGO_PKG_VERSION").to_string(),
            model_version: None,
        }
    }

    pub fn input_sha256(&self) -> &str {
        &self.input_sha256
    }

    pub fn output_sha256(&self) -> &str {
        &self.output_sha256
    }

    pub fn verdict(&self) -> Verdict {
        self.verdict
    }

    pub fn mapping_version(&self) -> MappingVersion {
        MappingVersion(self.mapping_version)
    }

    pub fn to_json(&self) -> RedactResult<String> {
        serde_json::to_string(self)
            .map_err(|e| crate::RedactError::Internal(format!("ledger serialisation failed: {e}")))
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact ledger::`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add redaction ledger with SHA-256 provenance and version binding"
```

---

### Task 11: T1-T4 policy gate

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/policy.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod policy;`)

**Interfaces:**
- Consumes: `pacgate_core::DataLevel`; `Verdict` (Task 9).
- Produces:
  - `pub struct PolicyDecision { pub allow_auto_pass: bool, pub require_human_review: bool, pub reason: String }`
  - `pub fn decide(level: pacgate_core::DataLevel, verdict: Verdict) -> PolicyDecision`

The taxonomy already exists (`pacgate-ai/migrations/004_data_level.sql`, `DataLevel` in `pacgate-core`). This task maps it to sanitizer behaviour (design section 5) rather than introducing a parallel scheme.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/policy.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::Verdict;
    use pacgate_core::DataLevel;

    #[test]
    fn t1_needs_no_identity_work_but_is_still_verified() {
        let d = decide(DataLevel::T1SharedTemplate, Verdict::Pass);
        assert!(d.allow_auto_pass);
        assert!(!d.require_human_review);
    }

    #[test]
    fn t2_may_auto_pass_only_on_a_clean_verdict() {
        assert!(decide(DataLevel::T2RestrictedSeed, Verdict::Pass).allow_auto_pass);
        assert!(!decide(DataLevel::T2RestrictedSeed, Verdict::Block).allow_auto_pass);
    }

    #[test]
    fn t3_may_auto_pass_only_on_a_clean_verdict() {
        assert!(decide(DataLevel::T3ProjectSpecific, Verdict::Pass).allow_auto_pass);
        assert!(decide(DataLevel::T3ProjectSpecific, Verdict::Block).require_human_review);
    }

    #[test]
    fn t4_never_auto_passes_even_when_verification_is_clean() {
        let d = decide(DataLevel::T4SpecialSensitive, Verdict::Pass);
        assert!(!d.allow_auto_pass, "T4 must never auto-pass");
        assert!(d.require_human_review);
    }

    #[test]
    fn a_block_always_requires_human_review_and_never_auto_passes() {
        for level in [
            DataLevel::T1SharedTemplate,
            DataLevel::T2RestrictedSeed,
            DataLevel::T3ProjectSpecific,
            DataLevel::T4SpecialSensitive,
        ] {
            let d = decide(level, Verdict::Block);
            assert!(d.require_human_review, "{level:?} blocked without review");
            assert!(!d.allow_auto_pass, "{level:?} blocked but allowed to auto-pass");
            assert!(!d.reason.is_empty(), "{level:?} blocked with no reason recorded");
        }
    }

    #[test]
    fn every_decision_carries_a_reason() {
        for level in [
            DataLevel::T1SharedTemplate,
            DataLevel::T2RestrictedSeed,
            DataLevel::T3ProjectSpecific,
            DataLevel::T4SpecialSensitive,
        ] {
            assert!(!decide(level, Verdict::Pass).reason.is_empty());
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact policy::`
Expected: FAIL - cannot find function `decide`, type `PolicyDecision`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/policy.rs`:

```rust
//! Maps the existing T1-T4 taxonomy to sanitizer behaviour.
//!
//! The taxonomy is not new: it lives in
//! `pacgate-ai/migrations/004_data_level.sql` and as `DataLevel` in
//! `pacgate-core`. This module only decides what each level is allowed to do,
//! so the design does not duplicate the spine (design section 5).
//!
//! The rule that matters: T4 never auto-passes, even on a clean verification.
//! T4 is 特别敏感资料 - special approval required, strict isolation.

use pacgate_core::DataLevel;

use crate::verify::Verdict;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PolicyDecision {
    /// May the artifact be released without a human looking at it?
    pub allow_auto_pass: bool,
    /// Must a human review before release?
    pub require_human_review: bool,
    /// Why, for the audit record and the review panel.
    pub reason: String,
}

/// Decide what a given data level permits, given a verification verdict.
pub fn decide(level: DataLevel, verdict: Verdict) -> PolicyDecision {
    let blocked = verdict.is_block();

    match level {
        DataLevel::T1SharedTemplate => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T1 (shared template) is already identity-free, but verification found residue, so it is held for review".to_string()
            } else {
                "T1 (shared template) carries no client identity; verification was clean".to_string()
            },
        },
        DataLevel::T2RestrictedSeed => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T2 (restricted seed) has residue after redaction, so it is held for review"
                    .to_string()
            } else {
                "T2 (restricted seed) redacted cleanly; no cross-project search is permitted regardless".to_string()
            },
        },
        DataLevel::T3ProjectSpecific => PolicyDecision {
            allow_auto_pass: !blocked,
            require_human_review: blocked,
            reason: if blocked {
                "T3 (project-specific) has residue after redaction, so it is held for review"
                    .to_string()
            } else {
                "T3 (project-specific) redacted cleanly; matter binding still applies".to_string()
            },
        },
        DataLevel::T4SpecialSensitive => PolicyDecision {
            allow_auto_pass: false,
            require_human_review: true,
            reason: "T4 (special sensitive) never auto-passes: special approval and strict isolation are required".to_string(),
        },
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cargo test -p pacgate-redact policy::`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): gate release on the existing T1-T4 taxonomy, with T4 never auto-passing"
```

---

### Task 12: End-to-end pipeline and spec acceptance tests

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/pipeline.rs`
- Create: `pacgate-ai/crates/pacgate-redact/tests/acceptance.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/lib.rs` (add `pub mod pipeline;`)

**Interfaces:**
- Consumes: everything from Tasks 1-11.
- Produces:
  - `pub struct Sanitizer` with `pub fn new(detectors: Vec<Box<dyn Detector>>, version: MappingVersion) -> Self`, `pub fn version(&self) -> MappingVersion`, `pub fn sanitize(&mut self, text: &str, level: DataLevel) -> RedactResult<SanitizeOutcome>`
  - `pub struct SanitizeOutcome { pub job_id: JobId, pub text: String, pub mapping: Mapping, pub ledger: RedactionLedger, pub decision: PolicyDecision }`

This is the single entry point plans 2-4 will call.

**Design note carried into the code:** the `Redactor` is held for the lifetime of the `Sanitizer`. Creating a fresh `Redactor` per `sanitize` call would reset the allocator and break the cross-document placeholder consistency that spec 6.1 requires. One `Sanitizer` = one job.

- [ ] **Step 1: Write the failing test**

Create `pacgate-ai/crates/pacgate-redact/src/pipeline.rs` with only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::tier_one_detectors;
    use crate::Verdict;
    use pacgate_core::DataLevel;

    fn sanitizer() -> Sanitizer {
        Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
    }

    #[test]
    fn end_to_end_removes_identifiers_and_passes() {
        let mut s = sanitizer();
        let out = s
            .sanitize(
                "身份证 11010519491231002X 联系 a@b.com",
                DataLevel::T3ProjectSpecific,
            )
            .unwrap();
        assert!(!out.text.contains("11010519491231002X"));
        assert!(!out.text.contains("a@b.com"));
        assert_eq!(out.ledger.verdict(), Verdict::Pass);
        assert!(out.decision.allow_auto_pass);
    }

    #[test]
    fn every_redacted_artifact_is_version_bound() {
        let mut s = sanitizer();
        let out = s.sanitize("a@b.com", DataLevel::T2RestrictedSeed).unwrap();
        assert_eq!(out.mapping.version(), MappingVersion::CURRENT);
        assert_eq!(out.ledger.mapping_version(), MappingVersion::CURRENT);
        assert_eq!(out.ledger.job_id, out.job_id.0.to_string());
    }

    #[test]
    fn t4_never_auto_passes_end_to_end() {
        let mut s = sanitizer();
        let out = s.sanitize("a@b.com", DataLevel::T4SpecialSensitive).unwrap();
        assert!(!out.decision.allow_auto_pass);
    }

    #[test]
    fn the_ledger_never_carries_the_original_value() {
        let mut s = sanitizer();
        let out = s
            .sanitize("秘密 11010519491231002X", DataLevel::T3ProjectSpecific)
            .unwrap();
        let json = out.ledger.to_json().unwrap();
        assert!(!json.contains("11010519491231002X"));
    }

    #[test]
    fn jobs_are_isolated_from_each_other() {
        let mut s = sanitizer();
        let a = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let b = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        assert_ne!(a.job_id, b.job_id);
        // Job b's mapping must not resolve job a's text.
        assert!(b.mapping.restore(&a.text, a.mapping.version()).is_err());
    }

    #[test]
    fn restore_round_trips_within_one_job() {
        let mut s = sanitizer();
        let out = s
            .sanitize("联系电话 a@b.com 已确认", DataLevel::T3ProjectSpecific)
            .unwrap();
        let restored = out
            .mapping
            .restore(&out.text, out.mapping.version())
            .unwrap();
        assert_eq!(restored, "联系电话 a@b.com 已确认");
    }

    #[test]
    fn a_job_that_cannot_certify_safety_blocks_and_holds_for_review() {
        let mut s = Sanitizer::new(Vec::new(), MappingVersion::CURRENT);
        let out = s.sanitize("a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        assert_eq!(out.ledger.verdict(), Verdict::Block);
        assert!(out.decision.require_human_review);
        assert!(!out.decision.allow_auto_pass);
    }

    #[test]
    fn one_sanitizer_keeps_placeholders_consistent_across_calls() {
        // One Sanitizer models one job spanning several documents.
        let mut s = sanitizer();
        let a = s.sanitize("联系人 a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let b = s.sanitize("再次联系 a@b.com", DataLevel::T3ProjectSpecific).unwrap();
        let pa = a.text.replace("联系人 ", "");
        let pb = b.text.replace("再次联系 ", "");
        assert_eq!(
            pa.trim(),
            pb.trim(),
            "the same subject must map to the same placeholder across documents"
        );
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test -p pacgate-redact pipeline::`
Expected: FAIL - cannot find type `Sanitizer`, `SanitizeOutcome`.

- [ ] **Step 3: Write the minimal implementation**

Prepend to `pacgate-ai/crates/pacgate-redact/src/pipeline.rs`:

```rust
//! The sanitize entry point: detect, decide, replace, verify, seal.
//!
//! Stage order is contractual (design section 4). DETECT precedes REPLACE and
//! no model is consulted here; VERIFY replays the same detector set that
//! DETECT used.
//!
//! The `Redactor` is held across calls on purpose. A fresh allocator per call
//! would reset the counter and hand the same subject two different
//! placeholders in the same job, which spec 6.1 forbids.

use pacgate_core::DataLevel;

use crate::detect::{noise::NoiseFilter, Detector};
use crate::ledger::RedactionLedger;
use crate::mapping::{JobId, Mapping, MappingVersion};
use crate::policy::{decide, PolicyDecision};
use crate::replace::Redactor;
use crate::verify::verify;
use crate::RedactResult;

pub struct SanitizeOutcome {
    pub job_id: JobId,
    pub text: String,
    pub mapping: Mapping,
    pub ledger: RedactionLedger,
    pub decision: PolicyDecision,
}

pub struct Sanitizer {
    detectors: Vec<Box<dyn Detector>>,
    version: MappingVersion,
    noise: NoiseFilter,
    redactor: Redactor,
}

impl Sanitizer {
    pub fn new(detectors: Vec<Box<dyn Detector>>, version: MappingVersion) -> Self {
        Self {
            detectors,
            version,
            noise: NoiseFilter::new(),
            redactor: Redactor::new(),
        }
    }

    pub fn version(&self) -> MappingVersion {
        self.version
    }

    /// Sanitize one text.
    ///
    /// Returns an outcome whenever the input is readable. Refusals are
    /// expressed as `Verdict::Block` plus `require_human_review` rather than
    /// an `Err`, so the evidence trail is still produced. An `Err` means the
    /// job could not be recorded at all.
    pub fn sanitize(&mut self, text: &str, level: DataLevel) -> RedactResult<SanitizeOutcome> {
        let job_id = JobId::new();

        // DETECT - every detector, deterministic first.
        let mut candidates = Vec::new();
        for d in &self.detectors {
            candidates.extend(d.detect(text)?);
        }

        // Suppress noise and public citations before deciding anything.
        let mut matches = self.noise.apply(text, candidates);
        matches = crate::detect::noise::drop_public_citations(text, matches);

        // DECIDE + REPLACE - the allocator lives on `self`, so it persists
        // across calls within this job.
        let redaction = self.redactor.redact(text, &matches)?;

        // VERIFY - same detector set, replayed against the output.
        let verification = verify(&redaction.text, &self.detectors);

        // Build this job's mapping from the allocator's accumulated state, so
        // documents processed earlier in the job are still restorable.
        let mut mapping = Mapping::new(self.version);
        for (entity, original, placeholder) in self.redactor.allocator().entries() {
            mapping.insert_typed(placeholder, *entity, original);
        }

        let ledger = RedactionLedger::seal(job_id, self.version, text, &redaction, &verification);

        let decision = decide(level, verification.verdict);

        Ok(SanitizeOutcome {
            job_id,
            text: redaction.text,
            mapping,
            ledger,
            decision,
        })
    }
}
```

**Finally, update `lib.rs` to the full module and re-export set.** Tasks 2-12 each add one module; this is what the finished file must declare, and it is what `tests/acceptance.rs` imports from:

```rust
pub mod checksum;
pub mod detect;
pub mod entity;
pub mod ledger;
pub mod mapping;
pub mod pipeline;
pub mod placeholder;
pub mod policy;
pub mod replace;
pub mod verify;

pub use detect::{tier_one_detectors, Detector, TierOneDetector};
pub use entity::{EntityType, PlaceholderPolicy, Tier};
pub use ledger::RedactionLedger;
pub use mapping::{JobId, Mapping, MappingVersion};
pub use placeholder::PlaceholderAllocator;
pub use pipeline::{SanitizeOutcome, Sanitizer};
pub use policy::{decide, PolicyDecision};
pub use replace::{AppliedRedaction, Redaction, Redactor};
pub use verify::{verify, Verdict, Verification};
```

Keep the `RedactError`, `RedactResult`, `MatchSource` and `Match` definitions that Task 1 already placed in `lib.rs`.

Create `pacgate-ai/crates/pacgate-redact/tests/acceptance.rs`:

```rust
//! Acceptance tests drawn from the client spec section 9.
//!
//! Only the rows this crate can decide are covered here. Rows that require
//! OCR, a database or the cloud boundary belong to plans 2-4, and are
//! deliberately absent rather than faked.

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{MappingVersion, SanitizeOutcome, Sanitizer, Verdict};

fn sanitize(text: &str, level: DataLevel) -> SanitizeOutcome {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
        .sanitize(text, level)
        .expect("sanitize should not error on readable input")
}

#[test]
fn spec_9_id_phone_email_and_labelled_accounts_do_not_survive() {
    let input = "身份证 11010519491231002X 手机 13812345678 邮箱 a@b.com";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    for secret in ["11010519491231002X", "13812345678", "a@b.com"] {
        assert!(!out.text.contains(secret), "{secret} survived redaction");
    }
    assert_eq!(out.ledger.verdict(), Verdict::Pass);
}

#[test]
fn spec_9_public_reference_citations_are_preserved() {
    let input = "参见 (2019)最高法民终1234号 的裁判要旨";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    assert!(
        out.text.contains("(2019)最高法民终1234号"),
        "a published citation unrelated to client identity must survive so the reference stays verifiable"
    );
}

#[test]
fn spec_9_amounts_dates_and_formulas_are_untouched() {
    let input = "借款金额 1,234,567.89 元，年利率 4.35%，期限 2026-01-01 至 2028-12-31";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    for kept in ["1,234,567.89", "4.35%", "2026-01-01", "2028-12-31"] {
        assert!(out.text.contains(kept), "must not alter {kept}");
    }
}

#[test]
fn spec_9_case_numbers_are_preserved() {
    // The case-number rule is context-sensitive (spec 2.1). This asserts the
    // v1 rule set does not blanket-remove them; the context-driven rule is
    // plan 3's job once matter identity is available.
    let input = "(2019)最高法民终1234号";
    let out = sanitize(input, DataLevel::T3ProjectSpecific);
    assert!(out.text.contains("民事") || out.text.contains("1234"));
}

#[test]
fn spec_9_a_stale_mapping_version_is_refused() {
    let out = sanitize("a@b.com", DataLevel::T3ProjectSpecific);
    assert!(out.mapping.restore(&out.text, MappingVersion(999)).is_err());
}

#[test]
fn spec_9_ledger_records_the_change_without_retaining_the_original() {
    let out = sanitize("机密 a@b.com", DataLevel::T3ProjectSpecific);
    let json = out.ledger.to_json().unwrap();
    assert!(!json.contains("a@b.com"));
    assert_ne!(out.ledger.input_sha256(), out.ledger.output_sha256());
}

#[test]
fn spec_9_rule_layer_recall_is_reported_per_tier() {
    // Spec 9 requires layer-separated, tier-separated reporting. This test is
    // the rule-layer row for Tier 1: every fixture must be caught.
    let fixtures = [
        ("11010519491231002X", "CnResidentId"),
        ("13812345678", "CnMobile"),
        ("4111111111111111", "BankCard"),
        ("a@b.com", "Email"),
    ];
    for (value, label) in fixtures {
        let out = sanitize(value, DataLevel::T3ProjectSpecific);
        assert!(
            !out.text.contains(value),
            "Tier-1 rule-layer miss for {label}: {value} survived"
        );
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p pacgate-redact`
Expected: PASS for every unit and acceptance test.

Run: `cargo clippy -p pacgate-redact --all-targets -- -D warnings`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add pacgate-ai/crates/pacgate-redact
git commit -m "feat(redact): add end-to-end sanitize pipeline and spec section 9 acceptance tests"
```

---

## Follow-on plans

This plan is complete and independently shippable, but the design covers four subsystems. Splitting them matters because each is independently testable and has a different failure mode.

| Plan | Subsystem | Why it is separate | Depends on |
|---|---|---|---|
| **1 (this)** | `pacgate-redact` crate | Pure Rust, no GPU, no DB - testable anywhere | - |
| **2** | `ocr-service` container + extraction cache | Needs GPU and a container; failure mode is throughput, not logic | plan 1's text+span interface |
| **3** | API routes, migrations, vault, MCP tools | Needs Postgres; failure mode is data isolation | plans 1 + 2 |
| **4** | deer-flow sanitizer agent + review panel | Needs the frontend patch mechanism; failure mode is UX and prompt discipline | plans 1-3 |

Boundary rule that plan 3 must preserve: the `pacgate-redact` crate consumes text + spans and never calls OCR. The MCP orchestrator (`pacgate_sanitize_document`) may extract-then-sanitize, but it reads the extraction cache first, so a per-job sanitize on already-ingested documents costs zero OCR calls.

Two items from the design are deliberately **not** in any plan yet, because they are blocked on decisions in design section 9:

- **BBox storage shape** (own table vs. columns on `kb_chunks`) - blocks plan 2's persistence task.
- **Restore authorisation model** (role-gated, per-job token, or both) - blocks plan 3's `pacgate_restore` route.

Both should be settled before plans 2 and 3 are written.

## Contractual deliverables tracking

Spec section 9 (L190) requires six artifacts. This plan contributes evidence for four; the remainder need plans 2-4.

| Required artifact | Covered by |
|---|---|
| 规则及上下文决策说明 | Task 5 (noise/context rules) + Task 11 (policy) |
| 已覆盖与未覆盖格式清单 | **plan 2** - this crate is text-only by design |
| 合成测试用例 | Every task's tests; Task 12 acceptance suite |
| 漏报与误报记录 | Task 5 (false-positive suppression); the recall-per-tier harness is **plan 3** |
| 本地映射与还原说明 | Tasks 6, 7, 12 |
| 出站边界验证结果 | Task 9 (verifier) + Task 10 (ledger); the true boundary assertion is **plan 3** |

**Layer-separated reporting (spec 9 L171)** - results must be reported for the rule layer, the local-model layer, the full chain, and the cloud boundary, and must not substitute for one another. This plan produces the **rule layer** row only. `cargo test -p pacgate-redact` output is that row's evidence; do not present it as end-to-end coverage.

**Positioning constraint (spec 10 L198):** a workflow that keeps a restorable local mapping is 去标识化 (de-identification), not 匿名化 (anonymisation). Plan 4's client-facing copy must not conflate the two.

## Known limitations of this plan

Stated plainly rather than discovered at review time, in the spirit the client spec requires.

- **Tier 2-4 detection is not implemented here.** Tasks 1-12 build Tier 1 fully and leave `PersonName`, `OrgName`, `Location`, `BankAccount`, `Credential`, `IpAddress`, `CaseNumber`, `RegistrationNumber`, `Landline` and `PostalAddress` as taxonomy entries with no detector. They become detectable in plan 2 once the local NER model exists. Until then, `verify` cannot block on them, so this crate alone does **not** satisfy the client's acceptance table.
- **`format_preserving` for non-card entities neutralises digits and letters but preserves first/last characters.** For a resident ID that means the region prefix stays legible. That is a deliberate trade-off in favour of downstream parseability, and it must be surfaced in the review panel so a reviewer can override it per document.
- **The USCC validator accepts the full 18-character space.** The real spec restricts the first character to a registration-authority code (1, 5, 9, Y, etc.). That refinement is a plan 3 task, because it needs the authority table.
- **`extract_placeholder_tokens` treats any all-uppercase bracketed token as placeholder-shaped.** Legitimate text such as `[NOTE]` or `[API]` will therefore be refused by `restore` with `InvalidInput` until an entry exists for it. Fail-closed is the correct default here, but it will produce human escalations on documents that use bracketed acronyms.
