//! Separator stripping and full-width folding, with a map back to the original.
//!
//! Both exist for the same reason. `Match` offsets are byte offsets into the
//! ORIGINAL text (`lib.rs:66-72`), and `Redactor` rejects any span that is not
//! on a char boundary. So any transformation that changes byte positions must
//! record how to get back, or redaction corrupts the text.
//!
//! Detecting against a normalised copy and mapping spans back is the only way to
//! match `4111 1111 1111 1111` without either shifting every downstream offset or
//! duplicating every pattern with separator variants. Grouped digits are the
//! canonical printed form of a bank card, a resident ID and a mobile number, so
//! the ungrouped-only behaviour missed the normal case.
//!
//! Spec 10.5 deliberately deferred full-width digit folding for exactly this
//! offset reason. One map serves both, which is why they are one mechanism.

/// Characters removed before matching.
///
/// Deliberately a small closed set of separators that appear *between* digits in
/// printed identifiers. Anything broader (stripping all punctuation) would start
/// deleting content rather than joining digit groups, and would let a match span
/// across a sentence.
///
/// The dash entries are the hyphen-minus, en dash, em dash and full-width
/// hyphen-minus. They are *character literals* here, not prose punctuation, so
/// the repo's copy rule about em-dashes in visible text does not apply.
const SEPARATORS: [char; 8] = [
    ' ',        // ASCII space
    '\t',       // tab, in case a table cell separates digits with one
    '-',        // hyphen-minus
    '\u{FF0D}', // full-width hyphen-minus
    '\u{2013}', // en dash
    '\u{2014}', // em dash
    '\u{3000}', // ideographic space
    '\u{00B7}', // middle dot
];

/// A normalised copy of a text, plus the byte map back into the original.
pub struct NormalizedText {
    /// Separators removed, full-width digits folded to ASCII.
    pub text: String,
    /// For each byte of `text`, the byte offset in the ORIGINAL text of the
    /// character that produced it. Same length as `text`.
    ///
    /// A separator produces no entry (it emits no byte). A 3-byte full-width
    /// digit folded to one ASCII byte contributes three entries, all pointing at
    /// the full-width character's start.
    map: Vec<usize>,
}

impl NormalizedText {
    pub fn build(original: &str) -> Self {
        let mut text = String::with_capacity(original.len());
        let mut map: Vec<usize> = Vec::with_capacity(original.len());

        for (offset, ch) in original.char_indices() {
            if SEPARATORS.contains(&ch) {
                continue;
            }

            // Fold full-width forms to ASCII. Rust's `\d` already matches
            // full-width digits, but the patterns here anchor on literal ASCII
            // characters, so an unfolded full-width value cannot match at all.
            //
            // Letters matter as much as digits: a Chinese resident ID ends in a
            // check character that may be `X`, and a full-width `Ｘ` (U+FF38)
            // left unfolded made the ID miss AND let a spurious mobile match
            // inside its own digits. Measured 2026-09-26.
            let folded = match ch {
                '\u{FF10}'..='\u{FF19}' => {
                    char::from_u32(ch as u32 - 0xFF10 + '0' as u32).unwrap_or(ch)
                }
                '\u{FF21}'..='\u{FF3A}' => {
                    char::from_u32(ch as u32 - 0xFF21 + 'A' as u32).unwrap_or(ch)
                }
                '\u{FF41}'..='\u{FF5A}' => {
                    char::from_u32(ch as u32 - 0xFF41 + 'a' as u32).unwrap_or(ch)
                }
                _ => ch,
            };

            for _ in 0..folded.len_utf8() {
                map.push(offset);
            }
            text.push(folded);
        }

        Self { text, map }
    }

    /// Map a normalised byte range back to an original byte range.
    ///
    /// Returns an **exclusive** end that is on a char boundary in `original`, so
    /// the result can be used directly as a `[start, end)` span for `Redactor`
    /// and as `is_bounded`'s argument pair.
    ///
    /// `original` is passed in rather than stored because the exclusive end must
    /// be found by advancing past the last matched character in the original,
    /// and this type deliberately holds no borrow of it.
    ///
    /// Returns `None` when the range is empty, out of bounds, or an endpoint has
    /// no mapping.
    pub fn original_span(
        &self,
        original: &str,
        start: usize,
        end: usize,
    ) -> Option<(usize, usize)> {
        if start >= end || end > self.map.len() {
            return None;
        }

        let orig_start = *self.map.get(start)?;
        let last_start = *self.map.get(end - 1)?;

        // Exclusive end: the last matched character's start plus that character's
        // width in the ORIGINAL text. Using the normalised width would be wrong
        // for a folded full-width digit (3 bytes -> 1).
        let last_char = original.get(last_start..)?.chars().next()?;
        let orig_end = last_start + last_char.len_utf8();

        if orig_end > original.len() {
            return None;
        }
        Some((orig_start, orig_end))
    }

    /// The normalised slice for a match, for checksum and shape validation.
    pub fn slice(&self, start: usize, end: usize) -> Option<&str> {
        self.text.get(start..end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_text_is_unchanged_and_maps_identically() {
        let n = NormalizedText::build("13812345678");
        assert_eq!(n.text, "13812345678");
        assert_eq!(n.original_span("13812345678", 0, 11), Some((0, 11)));
    }

    #[test]
    fn strips_ascii_separators_and_records_the_mapping() {
        let original = "4111 1111 1111 1111";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "4111111111111111");

        // The whole run maps back to the whole original, separators included.
        // A partial span is what would leave a digit stranded in the clear.
        assert_eq!(n.original_span(original, 0, 16), Some((0, 19)));
    }

    #[test]
    fn strips_hyphens() {
        let original = "4111-1111-1111-1111";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "4111111111111111");
        assert_eq!(n.original_span(original, 0, 16), Some((0, 19)));
    }

    #[test]
    fn folds_full_width_digits() {
        let original = "\u{FF11}\u{FF13}\u{FF18}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}\u{FF18}";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "13812345678");
        // Each full-width digit is 3 bytes in the original and 1 in the
        // normalised text, so the whole run maps to 33 original bytes.
        assert_eq!(n.original_span(original, 0, 11), Some((0, 33)));
    }

    #[test]
    fn folds_full_width_letters_needed_for_the_resident_id_check_char() {
        // U+FF38 FULLWIDTH LATIN CAPITAL LETTER X. Without folding it, the ID
        // missed AND `1[3-9]\d{9}` matched a spurious mobile inside its digits.
        let original = "１１０１０５１９４９１２３１００２Ｘ";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "11010519491231002X");
    }

    #[test]
    fn maps_a_mid_string_span_to_its_own_original_bytes() {
        // The CJK label must not be swallowed: only the number is the span.
        let original = "手机13812345678";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "手机13812345678");
        let (s, e) = n.original_span(original, 6, 17).expect("number is mapped");
        assert_eq!(&original[s..e], "13812345678");
    }

    #[test]
    fn grouped_id_maps_to_the_whole_grouped_original() {
        let original = "110105 19491231 002X";
        let n = NormalizedText::build(original);
        assert_eq!(n.text, "11010519491231002X");
        let (s, e) = n.original_span(original, 0, 18).expect("id is mapped");
        assert_eq!(&original[s..e], original, "the span must cover both separators");
    }

    #[test]
    fn rejects_empty_and_out_of_bounds_ranges() {
        let original = "13812345678";
        let n = NormalizedText::build(original);
        assert_eq!(n.original_span(original, 5, 5), None, "empty range");
        assert_eq!(n.original_span(original, 0, 99), None, "past the end");
        assert_eq!(n.original_span(original, 9, 4), None, "inverted");
    }

    #[test]
    fn slice_exposes_the_normalised_bytes_for_validation() {
        let original = "4111 1111 1111 1111";
        let n = NormalizedText::build(original);
        assert_eq!(n.slice(0, 16), Some("4111111111111111"));
        assert_eq!(n.slice(0, 99), None);
    }

    #[test]
    fn separator_only_text_normalises_to_empty() {
        let original = " - \u{3000}";
        let n = NormalizedText::build(original);
        assert!(n.text.is_empty());
        assert_eq!(n.original_span(original, 0, 1), None);
    }
}
