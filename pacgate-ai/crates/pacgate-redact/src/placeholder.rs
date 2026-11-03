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
//! Section 9 is about not MERGING two subjects. It is not a licence to keep the
//! original value around: the token is derived from a normalised copy so two
//! spellings of one printed number agree, while the mapping key stays the exact
//! original so two different numbers never collapse.

use std::collections::HashMap;

use crate::entity::{EntityType, PlaceholderPolicy};

/// True when `value` is a token this crate minted.
///
/// One shape now, `[CODE_<hex>]` - see `PlaceholderAllocator`. The predecessor of
/// this function had to recognise a zeroed numeric run as well, because the
/// redactor produced two kinds of output. It does not any more, and that is the
/// point: a consumer (the SQL audit, the rescan in `pacgate-api`) can decide by
/// bracket, not by guessing whether a numeric run is a real value or the
/// redactor's own.
pub fn is_placeholder(value: &str) -> bool {
    let Some(inner) = value.trim().strip_prefix('[').and_then(|s| s.strip_suffix(']'))
    else {
        return false;
    };
    // Prefix match against the known codes, not a split on '_': several codes
    // themselves contain an underscore (`CN_ID`, `BANK_CARD`, `HK_MO_PERMIT`,
    // `CN_MOBILE`, `CASE_NO`, `REG_NO`, `LAWYER_NO`, `LEGACY_ID`, `BANK_ACCOUNT`,
    // `CN_TAX_ID`, `TH_JURISTIC`). Requiring `parts[0]` to be a code rejected
    // `[CN_ID_1]` when that was still a live shape.
    is_code_underscore_rest(inner)
}

/// True when `inner` (no brackets) is `<known code>_<payload>`.
fn is_code_underscore_rest(inner: &str) -> bool {
    crate::entity::EntityType::ALL.iter().any(|e| {
        inner
            .strip_prefix(e.code())
            .is_some_and(|rest| rest.starts_with('_') && rest.len() > 1)
    })
}

/// True when `value` is a BARE token - `<code>_<hex>` with no brackets.
///
/// MEASURED 2026-11-03, and this is the other half of a P0. Only the bracketed
/// form was protected, so a document that had already been tokenised and then
/// lost its brackets (`CN_TAX_ID_ABCDEF0123456789`) was re-hashed as if the hex
/// tail were a live tax number, producing
/// `[CN_TAX_ID_[CN_TAX_ID_B8CB56A6908EE5A5]]`.
///
/// The payload must look like hex to qualify. That is deliberately stricter than
/// "anything after the code": a bare `CN_ID_` prefix with non-hex text is not a
/// token this crate mints, and treating it as one would blind the detector to a
/// real value that merely sat next to a code name.
fn is_bare_token(value: &str) -> bool {
    let value = value.trim();
    crate::entity::EntityType::ALL.iter().any(|e| {
        value.strip_prefix(e.code()).is_some_and(|rest| {
            rest.strip_prefix('_')
                .is_some_and(|hex| hex.len() >= 8 && hex.chars().all(|c| c.is_ascii_hexdigit()))
        })
    })
}

/// True when `[start, end)` of `text` is a minted token, or LIES INSIDE one.
///
/// This is the form the detectors need, because they match SUB-SPANS. The
/// exact-string `is_placeholder` is not enough: on
/// `纳税人识别号 [CN_TAX_ID_A9FA1A090A96E294]` the tax-id rule returns
/// `A9FA1A090A96E294` - the token's own payload - and
/// `is_placeholder("A9FA1A090A96E294")` is false, so the guard let it through.
///
/// That single miss produced BOTH 2026-11-03 P0s:
///   * the rescan reported the token payload as residue (P0-2), and
///   * a second sanitize pass re-hashed it into a nested token (P0-1), because
///     the applied-redaction list that shields tokens during a single run is
///     empty when the input is ALREADY the output.
///
/// Checks four shapes, in order of likelihood:
///   1. the span is exactly a bracketed token,
///   2. the span is a bare token,
///   3. the span sits inside `[...]` that together form a bracketed token,
///   4. the span is the PAYLOAD of a bare token - `<CODE>_` immediately to its
///      left, no brackets.
///
/// Shape 4 was missed on the first attempt and is not hypothetical. The second
/// audit round measured that the trigger is the KEYWORD, not the bracket:
/// `纳税人识别号 [CN_TAX_ID_ABCDEF0123456789]` was already clean, while
/// `纳税人识别号 CN_TAX_ID_ABCDEF0123456789` (no brackets) still produced
/// `纳税人识别号 CN_TAX_ID_[CN_TAX_ID_949F3E55A690184A]`. Shape 3 could not see it
/// because there is no `[` to walk back to, and shape 2 could not either because
/// the span is only the hex tail.
pub fn is_token_span(text: &str, start: usize, end: usize) -> bool {
    if start > end || end > text.len() || !text.is_char_boundary(start) || !text.is_char_boundary(end)
    {
        return false;
    }
    let span = &text[start..end];
    if is_placeholder(span) || is_bare_token(span) {
        return true;
    }

    let before = &text[..start];

    // Shape 4: the span is the payload of an un-bracketed `<CODE>_` token.
    for e in crate::entity::EntityType::ALL {
        let prefix = format!("{}_", e.code());
        if !before.ends_with(&prefix) {
            continue;
        }
        let token_start = start - prefix.len();
        // Only a real token if the payload is hex of a plausible length; otherwise
        // the text merely happens to end with something that looks like a code.
        if span.len() >= 8 && span.chars().all(|c| c.is_ascii_hexdigit()) {
            let full = &text[token_start..end];
            if is_bare_token(full) {
                return true;
            }
        }
    }

    // Shape 3: enclosed by brackets that wrap a token.
    let Some(open) = before.rfind('[') else {
        return false;
    };
    // A `]` between the bracket and the span means the bracket is already closed,
    // so the span is outside any token.
    if before[open + 1..].contains(']') {
        return false;
    }
    let Some(close_off) = text[end..].find(']') else {
        return false;
    };
    // An `[` opening a new token before the closing bracket means the span is not
    // inside the one we found.
    if text[end..end + close_off].contains('[') {
        return false;
    }
    is_placeholder(&text[open..=end + close_off])
}

/// Maps exact original values to stable tokens.
///
/// ## One representation, derived from the value
///
/// Until 2026-11-03 there were two mechanisms in this file, and the split was
/// the defect. Text-shaped classes got an opaque `[CODE_prefix_index]` token;
/// number-shaped classes got `format_preserving`, which zeroed the value's
/// middle and stamped the ALLOCATION INDEX into the remaining digits. The second
/// mechanism failed four ways (all measured on 2026-11-03 against the values the
/// second review listed):
///
/// | failure | measurement |
/// |---|---|
/// | position, not value | the same ID was `...001X` alone and `...0030` after two other identifiers, so two documents in one matter could not be joined |
/// | shape disclosure | `91110105CA01ABCD26` -> `00000000XX00XXXX10`: length, letter positions and check character all survived |
/// | collision | `91350100M000100Y43` and `91110105CA01ABCD26` both -> `00000000X000000X10` |
/// | counter leak | the mask said which ordinal the identifier was in the document |
///
/// The replacement is the token form ONLY, with the tag derived from the value:
///
/// ```text
/// [CN_ID_<16 uppercase hex>]
/// ```
///
/// * Keyed by the value, so position cannot matter and a matter's documents
///   correlate on the same subject. There is no counter left to leak.
/// * Opaque, so no length, letter position or check character survives.
/// * 64 bits from HMAC-SHA256, so a collision needs ~2^32 distinct values of one
///   class inside one matter - not a document set. (`Mapping` also keeps the
///   reverse table, so a collision would be visible rather than silent, but the
///   bar here is that it does not happen.)
/// * Matter-scoped: the key is the matter's, so two matters derive different tags
///   from the same person even if their corpora are later merged.
///
/// Spec 6.1 (same value, same placeholder) and spec 6.2 (mapping isolation) both
/// hold by construction rather than by a counter that has to be kept in order.
#[derive(Debug, Default)]
pub struct PlaceholderAllocator {
    /// Derivation key. Two allocators with different keys never mint the same
    /// tag for the same value (spec 6.2 映射隔离).
    key: TokenKey,
    /// (entity, exact original) -> token
    assigned: HashMap<(EntityType, String), String>,
    /// token -> normalised value, so a collision is detected instead of
    /// silently handing two subjects the same token.
    minted: HashMap<String, String>,
}

/// The key a tag is derived with.
///
/// Deliberately NOT stored in the sanitized text, the ledger or the mapping: only
/// the tags are. Losing the key does not make a mapping unreadable (the mapping
/// holds placeholder -> original in the clear, server-side); it only means new
/// tags for the same value will not match old ones.
#[derive(Clone, PartialEq, Eq)]
pub struct TokenKey(Vec<u8>);

impl std::fmt::Debug for TokenKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the key material into a log line.
        f.write_str("TokenKey(<redacted>)")
    }
}

impl TokenKey {
    pub fn from_secret(secret: &[u8]) -> Self {
        Self(secret.to_vec())
    }

    /// A fresh random key, for a caller that has no matter key to offer.
    pub fn random() -> Self {
        Self(uuid::Uuid::new_v4().as_bytes().to_vec())
    }
}

impl Default for TokenKey {
    fn default() -> Self {
        Self::random()
    }
}

impl PlaceholderAllocator {
    /// `key` makes token names unambiguous per matter: two matters sanitizing
    /// the same value mint different tags, so one matter's mapping can never
    /// silently resolve another matter's text (spec 6.2).
    pub fn new(key: TokenKey) -> Self {
        Self {
            key,
            assigned: HashMap::new(),
            minted: HashMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.assigned.len()
    }

    pub fn is_empty(&self) -> bool {
        self.assigned.is_empty()
    }

    /// Allocate, or return the existing token for this exact value.
    pub fn allocate(&mut self, entity: EntityType, original: &str) -> String {
        let key = (entity, original.to_string());
        if let Some(existing) = self.assigned.get(&key) {
            return existing.clone();
        }

        let placeholder = match entity.policy() {
            PlaceholderPolicy::Remove => String::new(),
            PlaceholderPolicy::Opaque => self.token(entity, original),
        };

        self.assigned.insert(key, placeholder.clone());
        placeholder
    }

    /// `[CODE_<tag>]`, where the tag is HMAC(key, "CODE|normalised value").
    ///
    /// The code is inside the MAC input as well as around it: two classes that
    /// normalise to the same string (a 13-digit Thai tax id and a 13-digit
    /// juristic id are both digits) must not collide on a shared digest domain.
    fn token(&mut self, entity: EntityType, original: &str) -> String {
        let normalized = normalize_for_token(original, entity.folds_case());
        let digest = hmac_sha256(&self.key, entity.hash_family(), &normalized);
        let tag: String = digest[..TOKEN_TAG_BYTES]
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect();

        self.detect_collision(&tag, &normalized);
        format!("[{}]", join_token(entity.code(), &tag))
    }

    /// Refuse to hand two different normalised values one token.
    ///
    /// 64 bits makes this a theoretical path, which is exactly why it is worth
    /// ten lines: the old mechanism hit a REAL collision at two values
    /// (`00000000X000000X10` for two different USCCs), and a silent one corrupts
    /// `Mapping::restore` by resolving one subject to another's number.
    ///
    /// This is a detector, not a repair. Widening the tag would hide the fact
    /// that the derivation is wrong; the assertion fires in tests and the record
    /// makes the collision visible in a debug build. Reaching this path means the
    /// input was not what `normalize_for_token` assumed.
    fn detect_collision(&mut self, tag: &str, normalized: &str) {
        if let Some(previous) = self.minted.get(tag) {
            debug_assert_eq!(
                previous, normalized,
                "token collision at 64 bits: this needs investigating, not widening"
            );
        } else {
            self.minted.insert(tag.to_string(), normalized.to_string());
        }
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

/// Bytes of HMAC output kept as the tag. 8 bytes = 16 uppercase hex chars.
///
/// The review's prototype used 48 bits and measured zero collisions over 100k
/// distinct IDs. 64 bits is the same trade with a wider margin and no extra cost
/// beyond eight characters in the token, and the token is not read by a human.
pub const TOKEN_TAG_BYTES: usize = 8;

/// Hex characters in a tag. Derived, so the two cannot drift.
pub const TOKEN_TAG_HEX: usize = TOKEN_TAG_BYTES * 2;
/// Lowercase `CODE_TAG`, the inner text of the bracketed token.
pub fn join_token(code: &str, tag: &str) -> String {
    format!("{code}_{tag}")
}

/// Canonical form a tag is derived from.
///
/// Two spellings of one printed number must reach one token, or an OCR'd document
/// fragments the same person into one token per spacing. The rules, all measured
/// against the review's variant list (`44030119800101123X`, `...123x`,
/// `440301 1980 0101 123X`, `440301-1980-0101-123X` -> one token):
///
///   * separators that only group digits are dropped (space, tab, hyphen, the
///     dash family, ideographic space, middle dot) - the same closed set the
///     detector's normaliser uses, so the two cannot disagree;
///   * full-width digits and letters are folded to ASCII;
///   * when `fold_case` is set, letters are upper-cased, so a check character `x`
///     is `X`.
///
/// `fold_case` is the ENTITY's call, not a constant, because the two directions
/// have opposite costs. A resident ID's `x` and `X` are one person, so folding is
/// required for correlation. A WeChat handle's `ZhangSan` and `zhangsan` are two
/// accounts, so folding would merge two subjects - the spec-9 failure that
/// `Mapping::restore` cannot undo.
pub fn normalize_for_token(value: &str, fold_case: bool) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.trim().chars() {
        if matches!(
            ch,
            ' ' | '\t' | '-' | '\u{FF0D}' | '\u{2013}' | '\u{2014}' | '\u{3000}' | '\u{00B7}'
        ) {
            continue;
        }
        let folded = match ch {
            '\u{FF10}'..='\u{FF19}' => char::from_u32(ch as u32 - 0xFF10 + '0' as u32).unwrap_or(ch),
            '\u{FF21}'..='\u{FF3A}' => char::from_u32(ch as u32 - 0xFF21 + 'A' as u32).unwrap_or(ch),
            '\u{FF41}'..='\u{FF5A}' => char::from_u32(ch as u32 - 0xFF41 + 'a' as u32).unwrap_or(ch),
            _ => ch,
        };
        if fold_case {
            out.extend(folded.to_uppercase());
        } else {
            out.push(folded);
        }
    }
    out
}

/// HMAC-SHA256 over `code + '\0' + value`.
///
/// A real MAC, not a bare digest: the tag of a 18-digit ID is derivable from the
/// value alone if the key is absent, and an unkeyed digest of a national ID space
/// is a rainbow table away from being reversible. The NUL separator is what stops
/// `("CN_ID", "X9")` and `("CN_", "IDX9")` from sharing an input.
fn hmac_sha256(key: &TokenKey, code: &str, value: &str) -> [u8; 32] {
    use sha2::{Digest, Sha256};

    // RFC 2104 with SHA-256: block size is 64 bytes.
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.0.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(&key.0));
    } else {
        k[..key.0.len()].copy_from_slice(&key.0);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    inner.update(code.as_bytes());
    inner.update([0u8]);
    inner.update(value.as_bytes());
    let inner = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(inner);
    outer.finalize().into()
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::EntityType;

    fn allocator() -> PlaceholderAllocator {
        PlaceholderAllocator::new(TokenKey::from_secret(b"unit-test-matter-key"))
    }

    #[test]
    fn same_value_gets_the_same_token() {
        let mut a = allocator();
        let first = a.allocate(EntityType::PersonName, "张三");
        let second = a.allocate(EntityType::PersonName, "张三");
        assert_eq!(first, second, "spec 6.1 requires consistent placeholders");
    }

    #[test]
    fn similar_but_distinct_values_do_not_merge() {
        // Spec 9: 名称相似的不同主体 must not be merged.
        let mut a = allocator();
        let one = a.allocate(EntityType::PersonName, "张三");
        let two = a.allocate(EntityType::PersonName, "张峰");
        assert_ne!(one, two);
    }

    #[test]
    fn different_entities_get_distinct_placeholder_namespaces() {
        let mut a = allocator();
        let person = a.allocate(EntityType::PersonName, "甲");
        let org = a.allocate(EntityType::OrgName, "甲");
        assert_ne!(person, org);
        assert!(person.contains("PERSON"));
        assert!(org.contains("ORG"));
    }

    /// A token must not leak the value's length or script.
    ///
    /// The predecessor asserted "no `3` in the placeholder", which only made sense
    /// while the mask ended in a decimal counter. The real invariant is that the
    /// token's width is INDEPENDENT of the original's: a 9-character passport and
    /// an 18-character ID must produce tokens of the same size, or the token
    /// discloses how long the value was.
    #[test]
    fn tokens_do_not_leak_length_or_script() {
        let mut a = allocator();
        let short = a.allocate(EntityType::PersonName, "张三丰");
        assert!(!short.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)));

        let mut b = allocator();
        let narrow = b.allocate(EntityType::Uscc, "91350100M000100Y43");
        let mut c = allocator();
        let wide = c.allocate(EntityType::Uscc, "91350100M000100Y43000");
        assert_eq!(
            narrow.len(),
            wide.len(),
            "the token's width must not follow the value's: {narrow} vs {wide}"
        );
    }

    /// The defect the whole rewrite is about: the token is derived from the
    /// VALUE, so allocation order cannot change it.
    ///
    /// MEASURED 2026-11-03, before the fix: the same ID rendered as
    /// `00000000000000001X` alone and `000000000000000030` after two other
    /// identifiers, because the stamp was the allocation index.
    #[test]
    fn a_token_does_not_depend_on_allocation_order() {
        let mut a = allocator();
        let mut b = allocator();
        let alone = b.allocate(EntityType::CnResidentId, "44030119800101123X");

        a.allocate(EntityType::CnMobile, "13812345678");
        a.allocate(EntityType::BankCard, "6222021234567890128");
        let late = a.allocate(EntityType::CnResidentId, "44030119800101123X");

        assert_eq!(alone, late, "position must not reach the token");
    }

    /// No length, letter layout or check character may survive.
    #[test]
    fn a_token_reveals_nothing_about_the_value_shape() {
        let mut a = allocator();
        for (entity, original) in [
            (EntityType::CnResidentId, "44030119800101123X"),
            (EntityType::Uscc, "91110105CA01ABCD26"),
            (EntityType::BankCard, "6222021234567890128"),
            (EntityType::BankAccount, "6222020200112345678"),
        ] {
            let p = a.allocate(entity, original);
            assert!(is_placeholder(&p), "must be recognisable: {p}");
            let inner = p.trim_start_matches('[').trim_end_matches(']');
            assert_eq!(
                inner.len(),
                entity.code().len() + 1 + TOKEN_TAG_HEX,
                "{entity:?}: a token is CODE_TAG and nothing else: {p}"
            );
            assert!(
                !p.contains("XXXX"),
                "{entity:?}: the letter layout must not survive: {p}"
            );
        }
    }

    /// Two different values must never share a token.
    ///
    /// MEASURED 2026-11-03, before the fix: these two USCCs both produced
    /// `00000000X000000X10`.
    #[test]
    fn distinct_values_never_share_a_token() {
        let mut a = allocator();
        let first = a.allocate(EntityType::Uscc, "91350100M000100Y43");
        let second = a.allocate(EntityType::Uscc, "91110105CA01ABCD26");
        assert_ne!(first, second);
    }

    #[test]
    fn uniqueness_holds_across_a_realistic_matter() {
        let mut a = allocator();
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
            assert!(seen.insert(p.clone()), "duplicate token {p} for {id}");
        }
        assert_eq!(seen.len(), ids.len());
    }

    /// The same number printed four ways is one subject, so it must be one token.
    #[test]
    fn printed_variants_of_one_value_share_a_token() {
        let mut a = allocator();
        let variants = [
            "44030119800101123X",
            "44030119800101123x",
            "440301 1980 0101 123X",
            "440301-1980-0101-123X",
        ];
        let mut tokens = Vec::new();
        for v in variants {
            // A fresh allocator per spelling, because the mapping key is the
            // exact original - the token is what has to agree.
            tokens.push(allocator().allocate(EntityType::CnResidentId, v));
        }
        assert!(tokens.windows(2).all(|w| w[0] == w[1]), "{tokens:?}");
        // And the same allocator still answers per spelling without drifting.
        for v in variants {
            assert!(is_placeholder(&a.allocate(EntityType::CnResidentId, v)));
        }
    }

    #[test]
    fn the_tag_is_upper_hex_of_the_documented_width() {
        let mut a = allocator();
        let p = a.allocate(EntityType::CnResidentId, "44030119800101123X");
        let tag = p
            .trim_start_matches('[')
            .trim_end_matches(']')
            .strip_prefix("CN_ID_")
            .expect("the code is the prefix");
        assert_eq!(tag.len(), TOKEN_TAG_HEX);
        assert!(tag.chars().all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c)));
    }

    /// Matter isolation by construction: a different key, a different tag.
    #[test]
    fn a_different_key_mints_a_different_token() {
        let mut a = PlaceholderAllocator::new(TokenKey::from_secret(b"matter-a"));
        let mut b = PlaceholderAllocator::new(TokenKey::from_secret(b"matter-b"));
        assert_ne!(
            a.allocate(EntityType::CnResidentId, "44030119800101123X"),
            b.allocate(EntityType::CnResidentId, "44030119800101123X"),
            "spec 6.2: two matters must not share a tag for the same person"
        );
    }

    /// A consumer with no access to `AppliedRedaction` must be able to tell the
    /// redactor's output from a real identifier.
    ///
    /// This used to have to recognise a zeroed numeric run as well, which is
    /// exactly how the rescan reported clean text as dirty (2 documented
    /// episodes). One shape means one test.
    #[test]
    fn a_token_is_recognisable_without_the_applied_redaction_list() {
        assert!(is_placeholder("[CN_ID_2D8BF002A1C4E6F0]"));
        assert!(is_placeholder("[LAWYER_NO_C723AAD5B19E2F40]"));
        assert!(is_placeholder("[PLATE_ABC123D4E5F60718]"));
        assert!(is_placeholder("[TH_JURISTIC_0A1B2C3D4E5F6071]"));

        // Real values must NOT be excused.
        assert!(!is_placeholder("110105199003074512"));
        assert!(!is_placeholder("6222020200112345678"));
        assert!(!is_placeholder("91350100M000100Y43"));
        assert!(!is_placeholder("000000000000000010"), "no numeric mask is minted any more");
        assert!(!is_placeholder("00000000"));
    }

    /// Normalisation is the reason an OCR'd document does not fragment its own
    /// subject into one token per spacing. It also must not be so eager that it
    /// merges two different numbers.
    #[test]
    fn normalisation_folds_grouping_but_not_digits() {
        assert_eq!(
            normalize_for_token("440301 1980 0101 123X", true),
            "44030119800101123X"
        );
        assert_eq!(
            normalize_for_token("440301-1980-0101-123x", true),
            "44030119800101123X"
        );
        assert_eq!(
            normalize_for_token(" 440301\u{3000}0101 ", true),
            "4403010101"
        );
        assert_ne!(
            normalize_for_token("44030119800101123X", true),
            normalize_for_token("44030119800101124X", true),
            "normalisation must not blur a real difference"
        );
    }

    /// A case-significant handle must keep its case: `ZhangSan` and `zhangsan`
    /// are two different WeChat accounts on the wire.
    #[test]
    fn a_case_significant_handle_keeps_its_identity() {
        assert_ne!(
            normalize_for_token("ZhangSan", false),
            normalize_for_token("zhangsan", false)
        );
        // And the entity decides, so the allocator cannot get it wrong.
        assert!(!EntityType::WeChatId.folds_case());
        assert!(EntityType::CnResidentId.folds_case());
    }

    /// The HMAC must be a real MAC: same key and value agree, different keys do
    /// not, and the entity code participates in the input.
    #[test]
    fn the_mac_is_keyed_and_domain_separated() {
        let k = TokenKey::from_secret(b"k");
        assert_eq!(
            hmac_sha256(&k, "CN_ID", "44030119800101123X"),
            hmac_sha256(&k, "CN_ID", "44030119800101123X")
        );
        assert_ne!(
            hmac_sha256(&k, "CN_ID", "44030119800101123X"),
            hmac_sha256(&TokenKey::from_secret(b"other"), "CN_ID", "44030119800101123X")
        );
        assert_ne!(
            hmac_sha256(&k, "CN_ID", "0115565002108"),
            hmac_sha256(&k, "TH_TAXID", "0115565002108"),
            "the same digits in two classes must not share a digest input"
        );
    }

    #[test]
    fn the_key_never_prints_its_material() {
        let k = TokenKey::from_secret(b"super-secret-matter-key");
        let printed = format!("{k:?}");
        assert!(!printed.contains("super-secret"), "{printed}");
    }

    /// The exact round trip that failed: sanitize an account, then re-detect it.
    #[test]
    fn a_bank_account_token_does_not_survive_as_residue() {
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
    fn entries_reports_the_mapping_for_the_ledger() {
        let mut a = allocator();
        a.allocate(EntityType::PersonName, "甲");
        a.allocate(EntityType::OrgName, "乙");
        assert_eq!(a.len(), 2);
        assert_eq!(a.entries().len(), 2);
    }

    #[test]
    fn a_removed_entity_yields_no_token() {
        let mut a = allocator();
        assert_eq!(a.allocate(EntityType::Credential, "hunter2-secret"), "");
    }
}
