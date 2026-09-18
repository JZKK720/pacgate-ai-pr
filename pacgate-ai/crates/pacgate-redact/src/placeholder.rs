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