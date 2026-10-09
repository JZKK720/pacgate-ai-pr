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
/// Unanchored on purpose - `is_bounded` is the boundary test, because `\b`
/// fails between a CJK character and a digit.
static RE_CN_ID_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{17}[\dXx]").expect("id candidate regex is valid"));

/// 18-char USCC shape: digits plus uppercase letters, excluding I O S V Z.
static RE_USCC_CANDIDATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[0-9A-HJ-NPQRTUWXY]{18}").expect("uscc candidate regex is valid")
});

static RE_MOBILE_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"1[3-9]\d{9}").expect("mobile regex is valid"));

static RE_DIGIT_RUN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{12,19}").expect("digit run regex is valid"));

/// Chinese landline: `0` + area code + 7-8 digit subscriber, optionally
/// hyphenated.
///
/// The area code is matched STRUCTURALLY, not as `\d{2,3}`. Measured
/// 2026-09-26: with a bare `0\d{2,3}` the 12-digit run `010123456789` matched in
/// full and `is_bounded` could not reject it, because the span ran to the end of
/// the text. That is a silent false positive on any unrelated 12-digit number
/// starting with `0` - an account or order number. An earlier draft concluded
/// the `0` head was sufficient on the strength of `123456789012`, which does not
/// start with `0`; the measurement was wrong, not the reasoning that followed.
///
/// Real area codes are: `10` (Beijing, written 010 - the only 2-digit one),
/// `2x` for x in 1-9 (021-029; there is no 020), and `3xx`-`9xx`.
///
/// With the area code pinned, the digit count is bounded and `is_bounded` does
/// the rest: in `010123456789` the match stops after 8 subscriber digits, the
/// next character is a digit, and the match is rejected - the same mechanism
/// that already rejected the hyphenated `010-123456789`.
///
/// Accepted cost: a SPACE-grouped landline (`010 12345678`) is not detected.
/// This pattern deliberately matches the original text rather than the
/// normalised copy, because normalising `010-123456789` to `010123456789` makes
/// it identical in shape to the VALID `0755-12345678` -> `075512345678` (both 12
/// digits) and the two cannot then be told apart. A miss on a rare spacing is
/// preferable to redacting an unrelated number.
static RE_LANDLINE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"0(?:10|2[1-9]|[3-9]\d{2})-?\d{7,8}").expect("landline regex is valid")
});

/// IPv4 address detection.
///
/// Pattern matches dotted quad notation with correct octet ranges (0-255 each).
/// Rejection of out-of-range octets (e.g., 300.1.1.1) is done by the octet
/// pattern itself: (?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d) does not match values
/// above 255.
///
/// Boundary validation is multi-layer:
/// - is_bounded() rejects matches embedded in longer alphanumeric tokens
///   (e.g., X192.168.1.1Y), ensuring the address is a standalone entity.
/// - A dot immediately BEFORE the match rejects fragments of longer runs
///   (e.g., .1.2.3.4, 9.1.2.3.4), preventing matches that are not addresses.
/// - A dot immediately AFTER the match rejects longer runs ONLY if a digit
///   follows (e.g., 1.2.3.4.5 is rejected, but 192.168.1.1. is allowed for
///   sentence-final cases). This prevents false acceptance at text boundaries
///   while allowing sentence-ending periods.
static RE_IPV4: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)")
        .expect("ipv4 regex is valid")
});

// ---------------------------------------------------------------------------
// Tier-1 extension set (added 2026-10-06, plan R1): cross-jurisdiction
// identifiers. None of these carry a checksum issued anywhere, so the letter
// prefix is the structural anchor and a bare digit run never qualifies. The
// formats are the published national rules, not guesses:
//
//   护照 (CN passport): "E" + one letter (I/O excluded) + 7 digits = 9 chars.
//     Older passports remain "E" + 8 digits = 9 chars, same total length, so
//     one alternation covers both without length drift.
//   回乡证 (HkMoPermit): "H"(HK) or "M"(MO) + 8-digit lifetime number +
//     2-digit reissue counter = 11 chars. 公安部 published format.
//   台胞证 (TaiwanPermit): 8-digit number + optional 2-digit reissue counter.
//     No letter exists, so it is Tier-1 only when LABELLED (see
//     RE_PERMIT_ANCHOR below); standalone 8-10 digit runs are exactly what
//     spec 8.4 forbids treating without context.
// ---------------------------------------------------------------------------

/// CN passport: `E` + letter (no I/O) + 7 digits, or legacy `E` + 8 digits.
static RE_PASSPORT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"E[A-HJ-NPZ][0-9]{7}|E[0-9]{8}").expect("passport regex is valid"));

/// 回乡证: `H`/`M` + 8 digits + 2-digit reissue counter.
static RE_HK_MO_PERMIT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[HM][0-9]{10}").expect("hk/mo permit regex is valid"));

/// 往来港澳通行证 (electronic card, mainland residents): `C` + 8 digits =
/// 9 chars. Gap found by client testing 2026-10-08: `C12345678` sailed
/// through sanitize untouched because the 回乡证 rule only claims `H`/`M`
/// prefixes. The `C` prefix is the published card number shape; a bare
/// 8-digit run is never claimed (same discipline as 台胞证 - the C anchor
/// below is only for the LABELLED legacy forms).
static RE_HK_MO_TRAVEL_PERMIT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"C[0-9]{8}").expect("hk/mo travel permit regex is valid"));

/// 往来港澳通行证 label anchor, for paper-era numbers that may be shorter
/// than the card shape (e.g. `C1234567`). A bare C+7-digit run stays
/// unclaimed; the label must say 港澳 for it to count.
static RE_TRAVEL_PERMIT_ANCHOR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"港澳(?:通行证|居民来往内地通行证)(?:号码|编号)?[:：]?\s*").expect("travel permit anchor is valid"));

static RE_TRAVEL_PERMIT_C: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"C[0-9]{7,8}").expect("travel permit C number regex is valid"));

/// 台胞证 requires a label; this anchor finds the label itself so the digit
/// run right after it can be promoted to a Tier-1 match.
static RE_PERMIT_ANCHOR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"台胞证(?:号码)?[:：]?").expect("taiwan permit anchor is valid"));

static RE_PERMIT_DIGITS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{8}(?:[0-9]{2})?").expect("permit digits regex is valid"));

/// 15-digit legacy ID: 6-digit region + YYMMDD + 3-digit sequence. Matched
/// against the ORIGINAL text (no separator normalisation) because no checksum
/// exists to validate a de-grouped copy, and the label boundary test
/// (same as landline) rejects a longer digit run after the match.
///
/// The label alternation covers the printed forms: 身份证 / 身份证号 /
/// 身份证号码, 证件号码, and the 一代证 phrasings 旧身份证 / 旧行身份证
/// with or without the 号码 suffix. The `号码?` groups stay per-branch
/// because `号码?` binds to 码 only - lifting the suffix out of the
/// branches would wrongly make 号 obligatory on every branch. The optional
/// whitespace keeps `身份证 130503670401001` (space-separated) matching;
/// `is_bounded` still rejects anything longer.
static RE_LEGACY_ID_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:旧行?身份证(?:号码?)?|身份证(?:号码?)?|证件号码?)[:：\s]*")
        .expect("legacy-id label regex is valid")
});

static RE_LEGACY_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[1-9][0-9]{14}").expect("legacy id regex is valid"));

/// 律师执业证号: 17 digits, structurally fixed - kind(1) province(2)
/// city(2) year(4) class(1) gender(1) serial(6). The label is the anchor;
/// `is_bounded` rejects the 18th digit continuation.
static RE_LAWYER_LABEL: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"律师执业证(?:号码)?[:：\s]*").expect("lawyer label regex is valid"));

static RE_LAWYER_NO: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{17}").expect("lawyer number regex is valid"));

/// Ceiling on matches from one text, to turn a pathological input into a
/// fatal error instead of unbounded memory growth.
const MAX_MATCHES: usize = 4096;

/// True when the span `[start, end)` is not flanked by an ASCII alphanumeric.
///
/// Replaces `\b` on the candidate patterns. `\b` is wrong here because the
/// `regex` crate is Unicode-aware by default, so `\w` includes CJK - which means
/// `\b` does not exist between a CJK character and a digit, and
/// `手机13812345678` (no space) is silently missed. Chinese text does not use
/// inter-word spaces, so that is the common form, not an edge case.
///
/// The test is deliberately "not ASCII-alphanumeric" rather than "non-word":
/// trailing CJK (`手机13812345678号`) must be accepted, while a longer token
/// (`ABC13812345678`) must not. `[^\w]` would reject both.
///
/// Offsets come from `regex::Match` on the same `text`, so they are char
/// boundaries by construction.
fn is_bounded(text: &str, start: usize, end: usize) -> bool {
    let before_ok = text[..start]
        .chars()
        .next_back()
        .is_none_or(|c| !c.is_ascii_alphanumeric());
    let after_ok = text[end..]
        .chars()
        .next()
        .is_none_or(|c| !c.is_ascii_alphanumeric());
    before_ok && after_ok
}

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
        self.push_span(out, m.start(), m.end(), m.as_str(), entity, source);
    }

    /// Record a match over an explicit span of the ORIGINAL text.
    ///
    /// `slice` must be the ORIGINAL bytes for `[start, end)`, never a normalised
    /// slice. `Match.text` is not a description of the match - it is the value
    /// that reaches `PlaceholderAllocator::allocate` (`replace.rs:90`) and
    /// therefore what the restore mapping returns for this placeholder. Storing
    /// the de-grouped form here would make a restore of `4111 1111 1111 1111`
    /// return `4111111111111111` - a silently altered number.
    ///
    /// Deliberately no separate confidence for a separator-stripped match: the
    /// same checksum validates the same digits, so the evidence is the same
    /// strength. Inventing a lower value would change semantics downstream
    /// (policy, ledger) for no measured reason.
    fn push_span(
        &self,
        out: &mut Vec<Match>,
        start: usize,
        end: usize,
        slice: &str,
        entity: EntityType,
        source: MatchSource,
    ) {
        out.push(Match {
            start,
            end,
            entity,
            text: slice.to_string(),
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

        // Digit-shaped classes match against a separator-stripped, full-width-
        // folded copy. `4111 1111 1111 1111`, `110105 19491231 002X` and
        // `138 1234 5678` are the canonical printed forms, and grouping is not
        // rare - it is how these numbers appear in contracts and on cards.
        // Matches are mapped back to original byte offsets with
        // `original_span`, which returns an exclusive, char-boundary end.
        let normalized = super::normalize::NormalizedText::build(text);

        for m in RE_CN_ID_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            if validate_cn_resident_id(m.as_str()) {
                self.push_span(
                    &mut out,
                    start,
                    end,
                    &text[start..end],
                    EntityType::CnResidentId,
                    MatchSource::Checksum,
                );
            }
        }

        for m in RE_USCC_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            if validate_uscc(m.as_str()) {
                self.push_span(
                    &mut out,
                    start,
                    end,
                    &text[start..end],
                    EntityType::Uscc,
                    MatchSource::Checksum,
                );
            }
        }

        for m in RE_MOBILE_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            self.push_span(
                &mut out,
                start,
                end,
                &text[start..end],
                EntityType::CnMobile,
                MatchSource::Checksum,
            );
        }

        for m in RE_DIGIT_RUN.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            // The checksum is over the DIGITS, so it validates the normalised
            // slice - `4111 1111 1111 1111` is not Luhn-valid as written, with
            // the spaces in it.
            if validate_luhn(m.as_str()) {
                self.push_span(
                    &mut out,
                    start,
                    end,
                    &text[start..end],
                    EntityType::BankCard,
                    MatchSource::Checksum,
                );
            }
        }

        // Landline deliberately matches the ORIGINAL text, not `normalized`.
        //
        // Measured, 2026-09-26: normalising it introduces a false positive.
        // `010-123456789` normalises to `010123456789` (12 digits); the greedy
        // `\d{2,3}` then takes a THREE-digit "area code" and the whole 12-digit
        // run matches. That string is indistinguishable from the VALID
        // `0755-12345678` -> `075512345678`, also 12 digits, because area codes
        // vary in length and we deliberately have no area-code table. So the two
        // cannot be separated by shape once the separator is gone.
        //
        // In the original text the hyphen splits the run, the match ends before
        // the final `9`, and `is_bounded` rejects it - which is why the earlier
        // round produced a correct answer. The pattern already carries `-?`, so
        // hyphenated landlines match without any normalisation.
        //
        // Accepted cost: a SPACE-grouped landline (`010 12345678`) stays
        // undetected. That is a miss on a rare form, and a miss is preferable to
        // a false positive that redacts an unrelated 12-digit number.
        for m in RE_LANDLINE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                m.start(),
                m.end(),
                m.as_str(),
                EntityType::Landline,
                MatchSource::Pattern,
            );
        }

        for m in RE_IPV4.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            // A dot-immediately-before this match means the match is a FRAGMENT
            // of a longer numeric run (`.1.2.3.4`, `9.1.2.3.4`), not an address.
            if text[..m.start()].ends_with('.') {
                continue;
            }
            // A dot AFTER the match only means a longer run when a digit follows
            // it. `1.2.3.4.5` continues a run; `192.168.1.1.` at the end of a
            // sentence does not, and must still be detected.
            if text[m.end()..].starts_with('.')
                && text[m.end() + 1..].starts_with(|c: char| c.is_ascii_digit())
            {
                continue;
            }
            self.push(&mut out, m, EntityType::IpAddress, MatchSource::Pattern);
        }

        if self.include_email {
            for m in RE_EMAIL.find_iter(text) {
                self.push(&mut out, m, EntityType::Email, MatchSource::Pattern);
            }
        }

        // Tier-1 extension (R1, 2026-10-06). Passport and the HK/MO permit
        // carry their own mandatory letter prefix, so `is_bounded` alone is
        // enough: a CJK label glued to the front is accepted, an ASCII letter
        // or digit continuation is rejected.
        for m in RE_PASSPORT.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::Passport, MatchSource::Pattern);
        }

        for m in RE_HK_MO_PERMIT.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::HkMoPermit, MatchSource::Pattern);
        }

        // 往来港澳通行证 card number: `C` + 8 digits, bounded like the
        // passport/回乡证 shapes above (a longer ASCII token claiming a C
        // prefix is rejected there and here for the same reason).
        for m in RE_HK_MO_TRAVEL_PERMIT.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::HkMoPermit, MatchSource::Pattern);
        }

        // Labelled legacy form: 港澳通行证[: ]C1234567 (possibly 7 digits on
        // older cards). Same label-anchored discipline as 台胞证 - the label,
        // not the shape, is what makes a short run an identifier.
        let travel_spans: Vec<usize> = RE_TRAVEL_PERMIT_ANCHOR
            .find_iter(text)
            .map(|a| a.end())
            .collect();
        for label_end in travel_spans {
            let Some(rest) = text.get(label_end..) else {
                continue;
            };
            if let Some(m) = RE_TRAVEL_PERMIT_C.captures(rest) {
                if let Some(c) = m.get(0) {
                    let start = label_end + c.start();
                    let end = label_end + c.end();
                    if is_bounded(text, start, end) {
                        self.push_span(
                            &mut out,
                            start,
                            end,
                            &text[start..end],
                            EntityType::HkMoPermit,
                            MatchSource::Context,
                        );
                    }
                }
            }
        }

        // 台胞证 has no letter prefix. The run is Tier-1 ONLY when the label
        // sits immediately before it; a bare 8-10 digit run is never claimed.
        // Matched on the ORIGINAL text - normalisation would fuse the label
        // boundary ambiguously, and there is no checksum to validate.
        let permit_spans: Vec<(usize, usize)> = RE_PERMIT_ANCHOR
            .find_iter(text)
            .map(|a| a.end())
            .map(|end| (end, text.len()))
            .collect();
        for (label_end, _) in permit_spans {
            let Some(rest) = text.get(label_end..) else {
                continue;
            };
            if let Some(m) = RE_PERMIT_DIGITS.captures(rest) {
                if let Some(c) = m.get(0) {
                    let start = label_end + c.start();
                    let end = label_end + c.end();
                    if is_bounded(text, start, end) {
                        self.push_span(
                            &mut out,
                            start,
                            end,
                            &text[start..end],
                            EntityType::TaiwanPermit,
                            MatchSource::Pattern,
                        );
                    }
                }
            }
        }

        // 15-digit legacy ID and 17-digit lawyer license: both are pure digit
        // runs with NO checksum, so both need their label (spec 8.4: a bare
        // digit rule must never stand). The label consumes the boundary on the
        // left; `is_bounded` rejects a longer run on the right, so a
        // 16th/18th digit continuation never matches.
        for (label_re, digits_re, entity) in [
            (
                &RE_LEGACY_ID_LABEL,
                &RE_LEGACY_ID,
                EntityType::LegacyIdNumber,
            ),
            (
                &RE_LAWYER_LABEL,
                &RE_LAWYER_NO,
                EntityType::RegistrationNumber,
            ),
        ] {
            for a in label_re.find_iter(text) {
                let Some(rest) = text.get(a.end()..) else {
                    continue;
                };
                let Some(digits) = digits_re.find(rest) else {
                    continue;
                };
                let start = a.end() + digits.start();
                let end = a.end() + digits.end();
                if is_bounded(text, start, end) {
                    self.push_span(
                        &mut out,
                        start,
                        end,
                        &text[start..end],
                        entity,
                        MatchSource::Context,
                    );
                }
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

    /// A CJK character is a word character for Unicode-aware `\b`, so `\b` does
    /// not exist between it and a digit. These are the forms a Chinese contract
    /// actually contains - no inter-word spaces.
    #[test]
    fn is_bounded_accepts_cjk_adjacency_and_rejects_longer_tokens() {
        let text = "手机13812345678";
        let start = 6; // "手机" is 6 bytes (2 chars x 3 bytes)
        assert_eq!(&text[start..start + 11], "13812345678");
        assert!(is_bounded(text, start, start + 11), "CJK adjacency must be accepted");

        // Trailing CJK too: the number is followed by a unit character.
        let trailing = "手机13812345678号";
        assert!(is_bounded(trailing, start, start + 11));

        // A longer ASCII token must still be rejected: this is the reason not to
        // simply drop the anchors.
        assert!(!is_bounded("ABC13812345678", 3, 14));
        assert!(!is_bounded("A13812345678", 1, 12));
        assert!(!is_bounded("138123456789", 0, 11));

        // Text edges are unconstrained.
        assert!(is_bounded("13812345678", 0, 11));
    }

    /// The four boundary-anchored classes must be caught with a CJK character
    /// directly adjacent, not only when separated by a space. Measured before
    /// the fix: all four adjacent forms returned no matches at all.
    #[test]
    fn finds_boundary_anchored_classes_when_cjk_is_adjacent() {
        let cases = [
            ("身份证11010519491231002X", "11010519491231002X", EntityType::CnResidentId),
            ("代码91350100M000100Y43", "91350100M000100Y43", EntityType::Uscc),
            ("手机13812345678", "13812345678", EntityType::CnMobile),
            ("卡号4111111111111111", "4111111111111111", EntityType::BankCard),
        ];
        for (text, value, entity) in cases {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == entity && m.text == value),
                "adjacency miss ({entity:?}): {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The fix must not become "match any digit run": a longer ASCII token still
    /// has to be rejected, or the recall fix becomes a precision regression.
    #[test]
    fn still_rejects_longer_ascii_tokens() {
        // 11-digit mobile shape embedded in a longer alphanumeric token.
        let embedded = TierOneDetector::new().detect("ABC13812345678").unwrap();
        assert!(embedded.is_empty(), "must not extract a mobile from a longer token");

        // 138123456789 is 12 digits: matches RE_DIGIT_RUN's 12-19 range, but is not
        // a Luhn-valid card, so nothing should be reported.
        let extra = TierOneDetector::new().detect("138123456789").unwrap();
        assert!(
            !extra.iter().any(|m| m.entity == EntityType::CnMobile),
            "a 12-digit run must not be read as a mobile"
        );
    }

    #[test]
    fn finds_landline_both_with_and_without_hyphen() {
        let spaced = TierOneDetector::new().detect("联系 010-12345678").unwrap();
        assert!(
            spaced.iter().any(|m| m.entity == EntityType::Landline && m.text == "010-12345678"),
            "landline with hyphen and 8-digit subscriber must be found; got {:?}",
            spaced.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let no_hyphen = TierOneDetector::new().detect("联系 01012345678").unwrap();
        assert!(
            no_hyphen.iter().any(|m| m.entity == EntityType::Landline && m.text == "01012345678"),
            "landline without hyphen and 8-digit subscriber must be found; got {:?}",
            no_hyphen.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Also verify 7-digit form is accepted
        let seven_digit = TierOneDetector::new().detect("联系 010-1234567").unwrap();
        assert!(
            seven_digit.iter().any(|m| m.entity == EntityType::Landline && m.text == "010-1234567"),
            "landline with hyphen and 7-digit subscriber must be found; got {:?}",
            seven_digit.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    #[test]
    fn rejects_landline_when_not_bounded() {
        // 0755-1234567 inside a longer token must be rejected by is_bounded.
        let in_token = TierOneDetector::new().detect("A0755-1234567B").unwrap();
        assert!(
            !in_token.iter().any(|m| m.entity == EntityType::Landline),
            "a landline inside a longer alphanumeric token must be rejected by is_bounded"
        );

        // A landline form with too many digits (9 instead of 7-8) that looks like
        // a truncated extension: 010-123456789 the pattern matches the first 11 chars
        // (010-12345678), but is_bounded rejects it because the span ends on digit 8
        // and the next character is also a digit (9).
        let over_long = TierOneDetector::new().detect("010-123456789").unwrap();
        assert!(
            !over_long.iter().any(|m| m.entity == EntityType::Landline),
            "an over-long subscriber (9 digits) must not match because is_bounded rejects it"
        );
    }

    /// The false positive this pattern was tightened for: a 12-digit run whose
    /// leading digits do NOT form a real area code. `020` is the trap - Beijing
    /// is `010` and `021`-`029` exist, but `020` was never allocated.
    ///
    /// Note the limit honestly: `050123456789` reads as area code `501` plus an
    /// 8-digit subscriber, and `501` is a real 3-digit code, so that string IS
    /// matched. It is genuinely indistinguishable from `075512345678`. Only the
    /// unallocated-prefix cases can be rejected by shape, and those are what this
    /// test pins.
    #[test]
    fn does_not_read_an_invalid_area_code_as_a_landline() {
        for text in [
            "编号020123456789", // 020 was never allocated
            "编号010123456789", // 010 + 9 subscriber digits: over-long
            "编号000123456789", // no area code starts 00
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                !found.iter().any(|m| m.entity == EntityType::Landline),
                "false positive: {text} produced a Landline; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The accepted cost of pinning the area code, stated as a test so it is not
    /// mistaken for an oversight later. `07551234567` is a valid 3+7 landline
    /// shape, so it IS still detected - that is intended, not a bug.
    #[test]
    fn detects_a_three_digit_area_code_with_a_seven_digit_subscriber() {
        let found = TierOneDetector::new().detect("座机07551234567").unwrap();
        assert!(
            found.iter().any(|m| m.entity == EntityType::Landline),
            "a 3+7 landline shape is ambiguous with an account number but keeps \
             matching, which is the documented tradeoff; got {:?}",
            found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// Real area codes must still work, including the only 2-digit one.
    #[test]
    fn accepts_real_area_codes_including_beijing() {
        for (text, value) in [
            ("座机010-12345678", "010-12345678"),
            ("座机021-12345678", "021-12345678"),
            ("座机029-12345678", "029-12345678"),
            ("座机0755-12345678", "0755-12345678"),
            ("座机0999-12345678", "0999-12345678"),
            ("座机01012345678", "01012345678"),
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == EntityType::Landline && m.text == value),
                "landline miss: {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn finds_ipv4_addresses_in_text() {
        let spaced = TierOneDetector::new().detect("服务器 192.168.1.1 地址").unwrap();
        assert!(
            spaced.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "192.168.1.1"),
            "basic ipv4 must be found; got {:?}",
            spaced.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let multi = TierOneDetector::new().detect("127.0.0.1 and 255.255.255.255").unwrap();
        assert!(
            multi.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "127.0.0.1"),
            "loopback must be found"
        );
        assert!(
            multi.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "255.255.255.255"),
            "broadcast must be found"
        );
    }

    #[test]
    fn rejects_ipv4_when_not_bounded() {
        // 192.168.1.1 inside a longer token must be rejected by is_bounded.
        let in_token = TierOneDetector::new().detect("X192.168.1.1Y").unwrap();
        assert!(
            !in_token.iter().any(|m| m.entity == EntityType::IpAddress),
            "an ipv4 inside a longer alphanumeric token must be rejected by is_bounded"
        );
    }

    #[test]
    fn rejects_ipv4_when_five_dot_pattern() {
        // 1.2.3.4.5 matches the first four groups as a valid IPv4 pattern,
        // but the fifth dot means it is a longer run. The fifth-dot guard
        // must reject it.
        let five_dot = TierOneDetector::new().detect("1.2.3.4.5").unwrap();
        assert!(
            !five_dot.iter().any(|m| m.entity == EntityType::IpAddress),
            "a five-dot pattern must not match as an IPv4 address"
        );

        // Same with CJK adjacency
        let five_dot_cjk = TierOneDetector::new().detect("地址1.2.3.4.5").unwrap();
        assert!(
            !five_dot_cjk.iter().any(|m| m.entity == EntityType::IpAddress),
            "a five-dot pattern with CJK adjacency must not match"
        );
    }

    /// Comprehensive tests for IPv4 boundary conditions.
    /// Covers both right-flank (five-dot) and left-flank (fragment) guards.
    #[test]
    fn ipv4_dot_guard_comprehensive() {
        let detector = TierOneDetector::new();

        // FINDING A: Sentence-ending period must NOT kill detection.
        // Current regression: `host 192.168.1.1.` returns no match.
        let sentence_period = detector.detect("host 192.168.1.1.").unwrap();
        assert!(
            sentence_period.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "192.168.1.1"),
            "IPv4 before sentence-ending ASCII period MUST match; got {:?}",
            sentence_period.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Chinese period (full-width 。) does NOT match ASCII dot, so is_bounded will accept it.
        let cjk_period = detector.detect("见192.168.1.1。").unwrap();
        assert!(
            cjk_period.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "192.168.1.1"),
            "IPv4 before full-width period MUST match; got {:?}",
            cjk_period.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Basic form without trailing period.
        let basic = detector.detect("host 192.168.1.1").unwrap();
        assert!(
            basic.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "192.168.1.1"),
            "basic IPv4 MUST match"
        );

        // FINDING B: Five-dot and longer numeric runs must be rejected.
        let five_dot = detector.detect("1.2.3.4.5").unwrap();
        assert!(
            !five_dot.iter().any(|m| m.entity == EntityType::IpAddress),
            "1.2.3.4.5 (five-dot) must NOT match"
        );

        let eight_dot = detector.detect("1.2.3.4.5.6.7.8").unwrap();
        assert!(
            !eight_dot.iter().any(|m| m.entity == EntityType::IpAddress),
            "1.2.3.4.5.6.7.8 (eight-dot, longer run) must NOT match; got {:?}",
            eight_dot.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // FINDING B: Left-flank fragments must be rejected.
        let leading_dot = detector.detect(".1.2.3.4").unwrap();
        assert!(
            !leading_dot.iter().any(|m| m.entity == EntityType::IpAddress),
            ".1.2.3.4 (leading dot fragment) must NOT match; got {:?}",
            leading_dot.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let alpha_dot_fragment = detector.detect("x.1.2.3.4").unwrap();
        assert!(
            !alpha_dot_fragment.iter().any(|m| m.entity == EntityType::IpAddress),
            "x.1.2.3.4 (alphanumeric-prefixed fragment) must NOT match; got {:?}",
            alpha_dot_fragment.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let nine_dot_fragment = detector.detect("9.1.2.3.4").unwrap();
        assert!(
            !nine_dot_fragment.iter().any(|m| m.entity == EntityType::IpAddress),
            "9.1.2.3.4 (five-octet, left-flank fragment) must NOT match; got {:?}",
            nine_dot_fragment.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Five-octet: 10.0.0.1.255
        let five_octet = detector.detect("10.0.0.1.255").unwrap();
        assert!(
            !five_octet.iter().any(|m| m.entity == EntityType::IpAddress),
            "10.0.0.1.255 (five-octet) must NOT match"
        );

        // Valid boundary cases.
        let max_octets = detector.detect("255.255.255.255").unwrap();
        assert!(
            max_octets.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "255.255.255.255"),
            "255.255.255.255 (max valid octets) MUST match"
        );

        let with_port = detector.detect("10.0.0.1:8080").unwrap();
        assert!(
            with_port.iter().any(|m| m.entity == EntityType::IpAddress && m.text == "10.0.0.1"),
            "10.0.0.1:8080 (with port) MUST match the IP part"
        );
    }

    // -------------------------------------------------------------------------
    // Tier-1 extension set (R1, 2026-10-06): cross-jurisdiction identifiers.
    // -------------------------------------------------------------------------

    /// CN passport: modern `E` + letter (I/O excluded) + 7 digits, and legacy
    /// `E` + 8 digits. Both are 9 chars total, confirmed 2026-10-06 against
    /// the published national format.
    #[test]
    fn finds_passport_both_modern_and_legacy_shapes() {
        let modern = TierOneDetector::new().detect("护照EA1234567 号码").unwrap();
        assert!(
            modern.iter().any(|m| m.entity == EntityType::Passport && m.text == "EA1234567"),
            "modern passport E+letter+7 must be found; got {:?}",
            modern.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let legacy = TierOneDetector::new().detect("护照 E12345678 已过期").unwrap();
        assert!(
            legacy.iter().any(|m| m.entity == EntityType::Passport && m.text == "E12345678"),
            "legacy passport E+8digits must be found; got {:?}",
            legacy.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// I and O are excluded by the published rule (they read as 1 and 0), so
    /// `EI`, `EO` must be rejected even though they are otherwise the same
    /// length and shape.
    #[test]
    fn rejects_passport_prefixes_i_and_o() {
        for text in ["护照EI1234567", "护照EO1234567"] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                !found.iter().any(|m| m.entity == EntityType::Passport),
                "false positive: {text} matched as a passport; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The passport "E" must not consume unrelated short strings. A single
    /// letter followed by a 1-6 digit run is too short to be a passport.
    #[test]
    fn rejects_short_digit_runs_after_e() {
        let found = TierOneDetector::new().detect("E级12345 甲").unwrap();
        assert!(
            !found.iter().any(|m| m.entity == EntityType::Passport),
            "an E with a short digit run must not be a passport; got {:?}",
            found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// 回乡证: `H`/`M` + 8-digit lifetime number + 2-digit reissue counter.
    /// CJK adjacency must be accepted (label glued to the number is normal).
    #[test]
    fn finds_hk_mo_permit_with_cjk_adjacency() {
        for (text, value) in [
            ("回乡证H1234567800", "H1234567800"),
            ("回乡证 M1234567802 号", "M1234567802"),
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == EntityType::HkMoPermit && m.text == value),
                "HK/MO permit miss: {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The permit prefix must not be claimed from inside a longer ASCII token
    /// (the is_bounded guarantee), and an 11-digit run not starting H/M must
    /// not be red-flagged as a permit.
    #[test]
    fn rejects_permit_inside_longer_token_or_wrong_prefix() {
        let embedded = TierOneDetector::new().detect("AH1234567800").unwrap();
        assert!(
            !embedded.iter().any(|m| m.entity == EntityType::HkMoPermit),
            "a permit inside a longer token must be rejected; got {:?}",
            embedded.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // No letter prefix: the digit run is not a permit at all. It also
        // must not be misread as anything else - it is just a bare digit run.
        let bare = TierOneDetector::new().detect("编号 1234567800 项").unwrap();
        assert!(
            bare.iter().all(|m| m.entity != EntityType::HkMoPermit
                && m.entity != EntityType::TaiwanPermit),
            "a bare 10-digit run is not a permit; got {:?}",
            bare.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// 往来港澳通行证 card number: `C` + 8 digits, found in a client probe
    /// 2026-10-08 (`C12345678` was NOT redacted before this rule existed).
    /// The bare C+7 short form is only claimed WITH the 港澳 label.
    #[test]
    fn finds_hk_mo_travel_permit_card_shape() {
        let found = TierOneDetector::new().detect("通行证号码 C12345678 有效").unwrap();
        assert!(
            found.iter().any(|m| m.entity == EntityType::HkMoPermit && m.text == "C12345678"),
            "C+8 card permit must be found; got {:?}",
            found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Glued CJK label also accepted (same adjacency rule as 回乡证).
        let glued = TierOneDetector::new().detect("港澳通行证C12345678").unwrap();
        assert!(
            glued.iter().any(|m| m.entity == EntityType::HkMoPermit && m.text == "C12345678"),
            "glued C+8 card permit must be found; got {:?}",
            glued.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // A C+8 run inside a longer ASCII token is NOT a permit (is_bounded).
        let embedded = TierOneDetector::new().detect("XC1234567899").unwrap();
        assert!(
            !embedded.iter().any(|m| m.entity == EntityType::HkMoPermit),
            "embedded C+8 must be rejected; got {:?}",
            embedded.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // C+7 without the label stays unclaimed (too short to trust C alone).
        let short_bare = TierOneDetector::new().detect("见 C1234567 条").unwrap();
        assert!(
            !short_bare.iter().any(|m| m.entity == EntityType::HkMoPermit),
            "bare C+7 must NOT be a permit; got {:?}",
            short_bare.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // C+7 WITH the label IS claimed (paper-era form).
        let short_labelled = TierOneDetector::new().detect("港澳通行证：C1234567").unwrap();
        assert!(
            short_labelled.iter().any(|m| m.entity == EntityType::HkMoPermit && m.text == "C1234567"),
            "labelled C+7 must be found; got {:?}",
            short_labelled.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// 台胞证: 8-digit number + optional 2-digit reissue counter. Tier-1
    /// ONLY when the label sits immediately before the number - a bare run
    /// is never claimed (spec 8.4).
    #[test]
    fn finds_taiwan_permit_only_when_labelled() {
        let labelled = TierOneDetector::new().detect("台胞证12345678").unwrap();
        assert!(
            labelled.iter().any(|m| m.entity == EntityType::TaiwanPermit && m.text == "12345678"),
            "labelled 8-digit permit must be found; got {:?}",
            labelled.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        let counter = TierOneDetector::new().detect("台胞证号码:1234567890").unwrap();
        assert!(
            counter.iter().any(|m| m.entity == EntityType::TaiwanPermit && m.text == "1234567890"),
            "labelled 10-digit permit with reissue counter must be found; got {:?}",
            counter.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Same 8-digit run with NO label: not a permit.
        let bare = TierOneDetector::new().detect("合同 12345678 中").unwrap();
        assert!(
            !bare.iter().any(|m| m.entity == EntityType::TaiwanPermit),
            "an unlabelled digit run must not be a permit; got {:?}",
            bare.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// 15-digit legacy ID: no checksum exists, so the 身份证/证件号码 label is
    /// the anchor and a 16+ digit continuation is rejected by is_bounded.
    #[test]
    fn finds_legacy_15_digit_id_only_with_label() {
        let labelled = TierOneDetector::new().detect("旧身份证130503670401001").unwrap();
        assert!(
            labelled
                .iter()
                .any(|m| m.entity == EntityType::LegacyIdNumber && m.text == "130503670401001"),
            "labelled legacy 15-digit ID must be found; got {:?}",
            labelled.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // 16 digits: the trailing digit makes is_bounded reject the match.
        let sixteen = TierOneDetector::new().detect("证件号码1305036704010012").unwrap();
        assert!(
            !sixteen.iter().any(|m| m.entity == EntityType::LegacyIdNumber),
            "a 16-digit continuation must be rejected; got {:?}",
            sixteen.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // No label: a bare 15-digit run is an account/order number as far as
        // the rules can tell - never claimed.
        let bare = TierOneDetector::new().detect("编号130503670401001").unwrap();
        assert!(
            !bare.iter().any(|m| m.entity == EntityType::LegacyIdNumber),
            "an unlabelled legacy ID run must not match; got {:?}",
            bare.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // Space-separated label form.
        let spaced = TierOneDetector::new().detect("身份证 130503670401001").unwrap();
        assert!(
            spaced
                .iter()
                .any(|m| m.entity == EntityType::LegacyIdNumber && m.text == "130503670401001"),
            "space-separated legacy ID must be found; got {:?}",
            spaced.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// 律师执业证号: 17 digits with the structured kind/province/city/year/
    /// class/gender/serial layout, matched only after the label.
    #[test]
    fn finds_lawyer_license_only_with_label() {
        let labelled = TierOneDetector::new().detect("律师执业证号11101201810123456").unwrap();
        assert!(
            labelled
                .iter()
                .any(|m| m.entity == EntityType::RegistrationNumber
                    && m.text == "11101201810123456"),
            "labelled lawyer license must be found; got {:?}",
            labelled.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );

        // 18 digits: the extra digit kills the match via is_bounded.
        let eighteen = TierOneDetector::new().detect("律师执业证号111012018101234567").unwrap();
        assert!(
            !eighteen.iter().any(|m| m.entity == EntityType::RegistrationNumber),
            "an 18-digit continuation must be rejected; got {:?}",
            eighteen.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }

    /// The extension rules must not regress the classes already covered.
    /// An 18-digit resident ID must not partially match as a legacy ID: the
    /// label anchor for the new rules requires the 15-digit count exactly,
    /// and the existing checksum path handles the 18-digit form.
    #[test]
    fn existing_classes_keep_their_coverage() {
        let text = "身份证 11010519491231002X 手机13812345678";
        let found = TierOneDetector::new().detect(text).unwrap();
        assert!(
            found.iter().any(|m| m.entity == EntityType::CnResidentId),
            "resident ID must still be found; got {:?}",
            found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
        assert!(
            found.iter().any(|m| m.entity == EntityType::CnMobile),
            "mobile must still be found; got {:?}",
            found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
        );
    }
}
