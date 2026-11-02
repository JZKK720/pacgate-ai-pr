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

/// A format-preserving placeholder always begins with this many zeros.
///
/// The SQL audit in `scripts/lib/RawPiiPatterns.ps1` excludes the redactor's own
/// output with `(?!0{K})`, and this constant is the `K` it must use. Keeping the
/// number here - next to the code that mints the value - is what stops the two
/// from drifting; the alternative is a magic number in a second language that
/// silently stops matching when this file changes.
///
/// Widths differ per entity (a 15-character legacy ID has 13 interior digits, an
/// 18-character ID has 16), so the guard has to be the SAME expression applied to
/// every length: "at least this many leading zeros". 4 is chosen because it is
/// satisfied by every format-preserved width the crate produces (see the
/// `MIN_LEADING_ZEROS` test) while still being four zeros a real identifier never
/// starts with in practice.
pub const MIN_LEADING_ZEROS: usize = 4;

/// The largest index that can be stamped without eating into `MIN_LEADING_ZEROS`
/// for the NARROWEST format-preserved width.
///
/// A stamped index consumes one leading zero per decimal digit. The narrowest
/// format-preserved original is 12 characters (`width` is clamped to 12), giving
/// `12 - 2 - MIN_LEADING_ZEROS = 6` usable interior positions - so up to six
/// digits, i.e. 999,999 values. Past that the entity falls back to the opaque
/// `[CODE_index]` form: uniqueness and privacy survive, shape preservation does
/// not. A single job holding a million distinct values of ONE identifier type is
/// not a law-firm document set.
pub const MAX_STAMPED_INDEX: usize = 999_999;

/// True when `value` is a format-preserving placeholder this crate minted.
///
/// The test is the invariant, not a guess: every format-preserved placeholder
/// begins with at least `MIN_LEADING_ZEROS` zeros (see `MIN_LEADING_ZEROS`), and a
/// real identifier does not. It is what lets a consumer that never saw the
/// `AppliedRedaction` list - the SQL audit, and the rescan in `pacgate-api` - tell
/// the redactor's own output from a leak.
///
/// MEASURED 2026-11-02: without this, the rescan reported
/// `BANK_ACCOUNT '0000000000000000010'` as residue on an otherwise clean document,
/// because the account rule is label-anchored and its placeholder keeps the label
/// shape. A rescan that always says "dirty" is worse than no rescan.
///
/// Deliberately conservative on length (12..=24, the clamped widths) so a short
/// numeric run that happens to start with zeros - an amount, a date fragment - is
/// not excused.
pub fn is_format_preserving_placeholder(value: &str) -> bool {
    let zeros = value.chars().take_while(|c| *c == '0').count();
    if zeros < MIN_LEADING_ZEROS {
        return false;
    }
    (12..=24).contains(&value.chars().count())
        && value
            .chars()
            .all(|c| c.is_ascii_digit() || c == 'X')
}

/// True when `value` is any placeholder this crate mints: the opaque
/// `[CODE_prefix_index]` form, or a format-preserved one.
pub fn is_placeholder(value: &str) -> bool {
    let t = value.trim();
    if is_format_preserving_placeholder(t) {
        return true;
    }
    let Some(inner) = t.strip_prefix('[').and_then(|s| s.strip_suffix(']')) else {
        return false;
    };
    // Two minted shapes:
    //   [CODE_prefix_index]  - `PlaceholderAllocator::allocate`
    //   [CODE_index]         - the opaque fallback past MAX_STAMPED_INDEX
    //
    // Prefix match against the known codes, not a split on '_': several codes
    // themselves contain an underscore (`CN_ID`, `BANK_CARD`, `HK_MO_PERMIT`,
    // `CN_MOBILE`, `CASE_NO`, `REG_NO`, `LAWYER_NO`, `LEGACY_ID`, `BANK_ACCOUNT`,
    // `CN_TAX_ID`). Requiring `parts[0]` to be a code rejected `[CN_ID_1]` - caught
    // by the test below on the first run.
    crate::entity::EntityType::ALL.iter().any(|e| {
        inner
            .strip_prefix(e.code())
            .is_some_and(|rest| rest.starts_with('_') && rest.len() > 1)
    })
}

/// Maps exact original values to stable placeholders.
///
/// One allocator is one job. Never share an allocator across matters
/// (spec 6.2 映射隔离).
#[derive(Debug, Default)]
pub struct PlaceholderAllocator {
    /// Job-scoped prefix, so two jobs never mint the same placeholder name.
    prefix: String,
    /// (entity, exact original) -> placeholder
    assigned: HashMap<(EntityType, String), String>,
}

impl PlaceholderAllocator {
    /// `prefix` makes placeholder names globally unambiguous: two jobs
    /// sanitizing the same value mint different tokens, so one job's mapping
    /// can never silently resolve another job's text (spec 6.2).
    pub fn new(prefix: &str) -> Self {
        Self {
            prefix: prefix.to_string(),
            assigned: HashMap::new(),
        }
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
            PlaceholderPolicy::Opaque => {
                format!("[{}_{}_{}]", entity.code(), self.prefix, index)
            }
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
            // recognise the shape; neutralise the middle - then stamp `index`
            // into the digits so two different values never collide.
            //
            // The collision was real and measured 2026-11-02: neutralising the
            // middle alone mapped BOTH `110105199003074512` and
            // `310104198507121234` to `000000000000000000`. One placeholder for
            // two people is a spec 9 violation (名称相似的不同主体 must not be
            // merged) and it corrupts `Mapping::restore`, which can only return
            // one of the two originals.
            //
            // ## The invariant the audit depends on
            //
            // A format-preserving placeholder must ALWAYS start with at least
            // `MIN_LEADING_ZEROS` zeros, because the SQL audit
            // (`scripts/lib/RawPiiPatterns.ps1`) excludes the redactor's own
            // output with `(?!0{K})`. That guard is the only thing stopping the
            // audit from reporting a clean machine's placeholders as raw PII
            // leaks - measured 2026-10-25 as 37 false "leaks" per pattern.
            //
            // Stamping a decimal index from the right eats one leading zero per
            // digit, so index 10 broke a `0{16}` guard and index 1000 would break
            // `0{14}`. Rather than let the guard drift with the counter, the
            // index is capped: past `MAX_STAMPED_INDEX` the entity falls back to
            // the opaque `[CODE_index]` form, which no SQL pattern can mistake
            // for an identifier. A job with more than this many distinct values
            // of one type loses shape preservation, not uniqueness or privacy.
            let chars: Vec<char> = original
                .chars()
                .map(|c| if c.is_ascii_digit() { '0' } else { 'X' })
                .collect();
            if chars.len() <= 2 {
                return chars.into_iter().collect();
            }
            if index > MAX_STAMPED_INDEX {
                return format!("[{}_{}]", entity.code(), index);
            }

            let stamp: Vec<char> = index.to_string().chars().collect();
            // Digit positions strictly before the retained final character,
            // rightmost first. A non-digit position is the `X` left by a letter
            // and is skipped, not overwritten: turning an `X` into a digit would
            // change the value's character class and could make the placeholder
            // look like a different kind of identifier.
            let mut digit_positions: Vec<usize> = (1..chars.len() - 1)
                .rev()
                .filter(|i| chars[*i].is_ascii_digit())
                .collect();

            if stamp.len() > digit_positions.len() {
                // Not enough digit positions to carry the index. Opaque rather
                // than a duplicate placeholder.
                return format!("[{}_{}]", entity.code(), index);
            }
            // Right-align: write the most significant index digit furthest left.
            digit_positions.truncate(stamp.len());
            let start = *digit_positions.last().unwrap_or(&0);
            // The invariant: never consume into the zero region the audit guard
            // relies on.
            if start < MIN_LEADING_ZEROS {
                return format!("[{}_{}]", entity.code(), index);
            }

            let mut out = chars;
            for (offset, pos) in digit_positions.iter().enumerate() {
                out[*pos] = stamp[offset];
            }
            out.into_iter().collect()
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
    let check = if sum.is_multiple_of(10) { 0 } else { 10 - (sum % 10) };
    std::char::from_digit(check, 10).unwrap_or('0')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EntityType;

    #[test]
    fn same_value_gets_the_same_placeholder() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let first = a.allocate(EntityType::PersonName, "张三");
        let second = a.allocate(EntityType::PersonName, "张三");
        assert_eq!(first, second, "spec 6.1 requires consistent placeholders");
    }

    #[test]
    fn similar_but_distinct_values_do_not_merge() {
        // Spec 9: 名称相似的不同主体 must not be merged.
        let mut a = PlaceholderAllocator::new("JOB1");
        let one = a.allocate(EntityType::PersonName, "张三");
        let two = a.allocate(EntityType::PersonName, "张峰");
        assert_ne!(one, two);
    }

    #[test]
    fn different_entities_get_distinct_placeholder_namespaces() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let person = a.allocate(EntityType::PersonName, "甲");
        let org = a.allocate(EntityType::OrgName, "甲");
        assert_ne!(person, org);
        assert!(person.contains("PERSON"));
        assert!(org.contains("ORG"));
    }

    #[test]
    fn opaque_placeholders_do_not_leak_length_or_script() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let p = a.allocate(EntityType::PersonName, "张三丰");
        assert!(!p.contains('3'));
        assert!(!p.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)));
    }

    #[test]
    fn format_preserving_placeholder_keeps_shape_and_validates() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let p = a.allocate(EntityType::BankCard, "4111111111111111");
        assert_eq!(p.len(), 16, "a downstream parser must still see 16 digits");
        assert!(p.chars().all(|c| c.is_ascii_digit()));
        assert!(
            crate::checksum::validate_luhn(&p),
            "a format-preserving card placeholder should itself pass Luhn"
        );
    }

    /// Two different format-preserved values must never share a placeholder.
    ///
    /// Measured 2026-11-02: neutralising the middle collapsed BOTH
    /// `110105199003074512` and `310104198507121234` to
    /// `000000000000000000`. Spec 9 forbids merging similar-but-distinct
    /// subjects, and `Mapping::restore` can only return one original for a
    /// shared placeholder - so the other subject silently resolves to the wrong
    /// person's number.
    #[test]
    fn two_different_ids_never_share_a_placeholder() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let first = a.allocate(EntityType::CnResidentId, "110105199003074512");
        let second = a.allocate(EntityType::CnResidentId, "310104198507121234");
        assert_ne!(
            first, second,
            "two people must never collapse onto one placeholder"
        );
        assert_eq!(first.len(), 18, "the ID shape must survive: {first}");
        assert_eq!(second.len(), 18, "the ID shape must survive: {second}");
        assert!(
            first.chars().all(|c| c.is_ascii_digit())
                && second.chars().all(|c| c.is_ascii_digit()),
            "a digit-shaped value must keep a digit-shaped placeholder"
        );
    }

    /// The same collision, for an entity whose value contains letters.
    #[test]
    fn two_different_credit_codes_never_share_a_placeholder() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let first = a.allocate(EntityType::Uscc, "91350100M000100Y43");
        let second = a.allocate(EntityType::Uscc, "91110000100000000X");
        assert_ne!(first, second);
        assert_eq!(first.len(), 18);
        assert_eq!(second.len(), 18);
    }

    /// Placeholder uniqueness across a realistic job, not just two values.
    #[test]
    fn every_allocated_placeholder_in_a_job_is_distinct() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let ids = [
            "110105199003074512",
            "110105199003074513",
            "310104198507121234",
            "440305199912310021",
            "110101200001010011",
        ];
        let mut seen = std::collections::HashSet::new();
        for id in ids {
            let p = a.allocate(EntityType::CnResidentId, id);
            assert!(seen.insert(p.clone()), "duplicate placeholder {p} for {id}");
        }
        assert_eq!(seen.len(), ids.len());
    }

    /// The invariant the SQL audit depends on: every format-preserving
    /// placeholder starts with at least `MIN_LEADING_ZEROS` zeros.
    ///
    /// This is not decoration. `scripts/lib/RawPiiPatterns.ps1` excludes the
    /// redactor's own output from the "raw PII still in a sanitized chunk" audit
    /// using `(?!0{K})`. Measured 2026-11-02: a decimal index stamped from the
    /// right ate one leading zero per digit, so from index 10 onward the
    /// placeholder no longer satisfied a `0{16}` guard and the audit would have
    /// reported the sanitizer's own clean output as leaks. The guard has to hold
    /// for ARBITRARY index values, not just the small ones a test happens to try.
    #[test]
    fn every_format_preserving_placeholder_keeps_the_audit_guard_satisfiable() {
        for entity in [
            EntityType::CnResidentId,
            EntityType::Uscc,
            EntityType::BankCard,
            EntityType::BankAccount,
        ] {
            for index in [1usize, 9, 10, 99, 100, 1000, MAX_STAMPED_INDEX] {
                let original = match entity {
                    EntityType::CnResidentId => "110105199003074512".to_string(),
                    EntityType::Uscc => "91350100M000100Y43".to_string(),
                    EntityType::BankCard => "4111111111111111".to_string(),
                    // A 12-character account: the narrowest format-preserved width.
                    _ => "020000123456".to_string(),
                };
                let p = format_preserving(entity, &original, index);
                if p.starts_with('[') {
                    // The opaque fallback no SQL pattern can mistake for a value.
                    continue;
                }
                let lead = p.chars().take_while(|c| *c == '0').count();
                assert!(
                    lead >= MIN_LEADING_ZEROS,
                    "{entity:?} index {index} produced {p} with only {lead} leading \
                     zero(s); the audit guard `(?!0{{{MIN_LEADING_ZEROS}}})` would stop \
                     excluding the redactor's own output"
                );
                assert_eq!(p.len(), original.len(), "shape lost for {entity:?}: {p}");
            }
        }
    }

    /// Past the stamping ceiling the placeholder degrades to opaque, and it must
    /// still be unique - the ceiling exists to protect the guard, not to allow a
    /// collision.
    #[test]
    fn past_the_stamp_ceiling_placeholders_stay_unique_and_opaque() {
        // Allocate enough to cross the ceiling would need a million entries, so
        // assert on the function directly at the boundary.
        let just_under = format_preserving(EntityType::CnResidentId, "110105199003074512", MAX_STAMPED_INDEX);
        let just_over =
            format_preserving(EntityType::CnResidentId, "110105199003074512", MAX_STAMPED_INDEX + 1);
        assert_ne!(just_under, just_over);
        assert!(
            just_over.starts_with('['),
            "past the ceiling the form must be opaque, got {just_over}"
        );
    }

    /// A consumer with no access to `AppliedRedaction` must still be able to tell
    /// the redactor's output from a real identifier.
    ///
    /// MEASURED 2026-11-02: the rescan reported `BANK_ACCOUNT
    /// '0000000000000000010'` as residue on an otherwise clean document, because
    /// the account rule is label-anchored and its placeholder keeps the label
    /// shape. The sanitize job excludes minted spans by offset; a standalone rescan
    /// has no such list, so it needs this predicate.
    #[test]
    fn a_placeholder_is_recognisable_without_the_applied_redaction_list() {
        assert!(is_format_preserving_placeholder("0000000000000000010"));
        assert!(is_format_preserving_placeholder("00000000X000000X30"));
        assert!(is_format_preserving_placeholder("00000000000000002X"));

        // Every opaque form this crate mints.
        assert!(is_placeholder("[CN_ID_1]"));
        assert!(is_placeholder("[LAWYER_NO_C723AAD5_4]"));
        assert!(is_placeholder("[PLATE_ABC123_7]"));

        // Real values must NOT be excused.
        assert!(!is_placeholder("110105199003074512"));
        assert!(!is_placeholder("6222020200112345678"));
        assert!(!is_placeholder("91350100M000100Y43"));
        assert!(!is_placeholder("1,250,000.00"));
        // A short zero-padded number is not a placeholder: excusing it would hide
        // a real leak whose value happens to start with zeros.
        assert!(!is_placeholder("00000000"));
        assert!(!is_format_preserving_placeholder("00001234"));
    }

    /// The exact round trip that failed: sanitize an account, then re-detect it.
    #[test]
    fn a_bank_account_placeholder_does_not_survive_as_residue() {
        use crate::detect::tier_one_detectors;
        let mut s = crate::Sanitizer::new(
            tier_one_detectors(),
            crate::mapping::MappingVersion::CURRENT,
        );
        let out = s
            .sanitize(
                "开户行：中国工商银行北京分行 账号：6222020200112345678",
                pacgate_core::DataLevel::T3ProjectSpecific,
            )
            .unwrap();
        assert_eq!(out.ledger.verdict(), crate::Verdict::Pass);
        assert!(
            !out.text.contains("6222020200112345678"),
            "the account must be redacted: {:?}",
            out.text
        );

        // What a standalone rescan would see, and what it must ignore.
        for d in tier_one_detectors() {
            for m in d.detect(&out.text).unwrap() {
                assert!(
                    is_placeholder(&m.text),
                    "the rescan must be able to recognise {:?} '{}' as the redactor's own output",
                    m.entity,
                    m.text
                );
            }
        }
    }

    #[test]
    fn allocator_is_deterministic_across_instances_for_the_same_order() {
        let mut a = PlaceholderAllocator::new("JOB1");
        let mut b = PlaceholderAllocator::new("JOB1");
        assert_eq!(
            a.allocate(EntityType::PersonName, "甲"),
            b.allocate(EntityType::PersonName, "甲")
        );
    }

    #[test]
    fn entries_reports_the_mapping_for_the_ledger() {
        let mut a = PlaceholderAllocator::new("JOB1");
        a.allocate(EntityType::PersonName, "甲");
        a.allocate(EntityType::OrgName, "乙");
        assert_eq!(a.len(), 2);
        assert_eq!(a.entries().len(), 2);
    }
}