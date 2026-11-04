//! Deterministic Tier-1 detectors.
//!
//! Ordering inside this module mirrors the spec's priority: checksum-backed
//! validators first, then labelled patterns, then plain patterns. A plain
//! pattern never fires without either a checksum or a label.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::checksum::{
    bank_account_shape_ok, card_number_shape_ok, cn_resident_id_shape_ok, malaysian_id_shape_ok,
    uscc_shape_ok, validate_cn_resident_id, validate_luhn, validate_uscc, vehicle_plate_shape_ok,
};
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

/// PRC mobile number, with an optional country code.
///
/// The `(?:86)?` is required, not cosmetic. MEASURED 2026-11-02: a business card
/// written `手机 +8613912345679` kept the number in the text, because `is_bounded`
/// saw the `6` of `86` immediately before the `1` as an ASCII alphanumeric and
/// rejected the match. The digits were then offered to the bank-card rule, which
/// claims them only when they happen to pass Luhn - so whether a mobile leaked
/// depended on its checksum. `+8613812345678` was redacted (a `+` breaks the run and
/// the 13-digit remainder passed Luhn) while `+8613912345679` was not.
///
/// Anchoring `86` inside the candidate is safe because it is at the START of the
/// match: it cannot swallow a digit that belongs to a preceding number.
static RE_MOBILE_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?:86)?1[3-9]\d{9}").expect("mobile regex is valid"));

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

/// 护照 label, for the passport shapes the structural rule cannot claim.
///
/// MEASURED 2026-11-03: `护照 PE1234567` survived verbatim. `RE_PASSPORT` is
/// anchored on the PRC issuing prefix (`E`, plus the legacy `G` series), so a
/// passport printed with any other prefix - a foreign passport in a cross-border
/// file, which is exactly the case this class exists for - matched nothing.
///
/// The label is what makes the wider shape safe, the same trade the 台胞证 rule
/// makes: an unlabelled `PE1234567` is still not claimed, so this cannot become
/// "any two letters and seven digits".
static RE_PASSPORT_ANCHOR: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"护照(?:号码?)?[:：\s]*").expect("passport anchor is valid"));

/// A passport number after a 护照 label: 1-2 letters then 7-8 digits.
///
/// ICAO 9303 documents are `[A-Z]{1,2}` followed by up to seven significant
/// digits; the PRC `E`-series is one instance of that family.
///
/// `I` and `O` are excluded for the same published reason as in `RE_PASSPORT`:
/// they are not used because they read as `1` and `0`. Allowing them here would
/// make the labelled path claim `护照 EI1234567`, which the structural rule
/// deliberately rejects - the same value accepted by one rule and refused by
/// another is how a class gains a hole.
static RE_PASSPORT_NUMBER: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[A-HJ-NP-Z][A-HJ-NP-Z]?[0-9]{7,8}").expect("passport number regex is valid")
});

/// 回乡证: `H`/`M` + 8 digits + 2-digit reissue counter.
static RE_HK_MO_PERMIT: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[HM][0-9]{10}").expect("hk/mo permit regex is valid"));

/// 香港入境许可 (entry permit) and 澳门非本地劳工证 (non-resident worker permit):
/// `HK` / `M` + 7 digits.
///
/// MEASURED 2026-11-03, and this is a REAL LEAK, not a coverage nicety:
/// `probe-0217-regression` carries the line
/// `香港入境许可 HK1234567；澳门非本地劳工证 M1234567` verbatim, is marked
/// `sanitized`, and is retrievable through kb_search. Both were invisible because
/// `RE_HK_MO_PERMIT` above demands exactly TEN digits after the prefix - these are
/// seven. The 0.2.16 notes listed both classes as supported; they were not.
///
/// The label is required. An unlabelled `HK` + 7 digits would collide with order
/// numbers and flight codes, and this repo's rule is that a bare digit run is never
/// claimed. `(?:香港)?入境许可`, `(?:澳门)?非本地劳工证` and the shorter `劳工证`
/// cover the spellings that appear in practice.
static RE_HK_ENTRY_PERMIT_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:香港)?入境许可(?:证)?|(?:澳门)?非本地劳工证|劳工证")
        .expect("hk entry permit label regex is valid")
});

static RE_HK_ENTRY_PERMIT_NUMBER: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?:HK|M)[0-9]{7}").expect("hk entry permit number regex is valid"));

/// 澳门居民身份证: 7 digits with a parenthesised check digit, e.g. `5123456(7)`.
///
/// MEASURED 2026-11-03: returned 0 redactions and `verdict: pass`. The shape is
/// closed enough to claim unlabelled - the parentheses are not ambiguous - but the
/// label form is also accepted because the check digit is sometimes printed
/// separately.
static RE_MO_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b[1-9][0-9]{6}\([0-9]\)").expect("macau id regex is valid"));

/// 澳门车牌: `澳` + authority letter + 4 digits. One of 31 province ideographs is
/// replaced by a jurisdiction ideograph, so the shape stays closed.
///
/// MEASURED 2026-11-03: `澳A1234` returned 0 redactions, `verdict: pass`.
static RE_MO_PLATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"澳[A-Za-z][0-9]{4}").expect("macau plate regex is valid"));

/// Vietnam MST (mã số thuế) and Philippines TIN.
///
/// Both are LABEL-ONLY, deliberately. Their bare shapes are 10 digits and
/// `3-3-3-000`, and a bare 10-digit run is exactly what this repo refuses to claim
/// (`RE_DIGIT_RUN` exists for the labelled case only). `0101243150` is the value
/// the audit saw misclassified as a LANDFILE - see the priority note in the detect
/// loop.
static RE_VN_MST_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:越南)?(?:MST|Mã\s*số\s*thuế|税号)\s*[:：]?\s*").expect("vn mst label valid")
});

static RE_VN_MST: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{10}(?:-[0-9]{3})?").expect("vn mst regex is valid"));

static RE_PH_TIN_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:菲律宾)?(?:TIN|Taxpayer\s*Identification\s*Number)\s*[:：]?\s*")
        .expect("ph tin label valid")
});

/// Philippines TIN is printed `123-456-789-000` (or `123-456-789`). The dashes are
/// part of the printed form, so the pattern owns them rather than relying on
/// normalisation.
static RE_PH_TIN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{3}-[0-9]{3}-[0-9]{3}(?:-[0-9]{3})?").expect("ph tin valid"));

/// Indonesia NPWP, printed dotted: `01.234.567.8-901.000`.
///
/// MEASURED 2026-11-03: the `NPWP：` prefix was consumed by the LOCATION rule and
/// the number body survived verbatim - the worst of both, a redaction that hides
/// the label and leaves the value.
static RE_ID_NPWP_LABEL: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?:印尼)?NPWP\s*[:：]?\s*").expect("npwp label valid"));

static RE_ID_NPWP: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{2}\.[0-9]{3}\.[0-9]{3}\.[0-9]-[0-9]{3}\.[0-9]{3}")
        .expect("npwp regex is valid"));

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

/// The number after a 港澳通行证 label, in any prefix the permit is issued with.
///
/// `[CHM]`, not `C`. MEASURED 2026-11-02: the label-anchored path accepted only a
/// `C`-prefixed number, while the unlabelled `RE_HK_MO_PERMIT` rule requires `H`/`M`
/// followed by exactly TEN digits. So `港澳通行证 H01234567` - a labelled permit
/// with the shorter printed form - matched NEITHER, stayed in the text through a
/// `verdict: pass`, and was published to the knowledge base. The label is what makes
/// this safe: an unlabelled `[HM]` + 7 digits is still never claimed.
static RE_TRAVEL_PERMIT_NUMBER: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[CHM][0-9]{7,10}").expect("travel permit number regex is valid"));

/// A complete PRC street address, claimed as ONE span.
///
/// The NER model emits addresses but splits one address into several disjoint
/// spans. MEASURED 2026-11-03: `北京市朝阳区建国路88号` became
/// `[LOCATION_9BC6…][LOCATION_BF56…][LOCATION_CE8B…]88号` - three tokens and the
/// house number left in clear text. That is worse than either extreme: the address
/// is unreadable, the sensitive part is disclosed, and a single place becomes three
/// tokens so it cannot be correlated across documents.
///
/// Rules run before the model and the noise filter keeps the longer, structurally
/// anchored span, so claiming the whole address here also collapses the fragments:
/// the three model spans fall inside this one and are dropped as overlaps.
///
/// The shape is anchored on 省/市/区/路/街/巷/弄 and must end at a house number,
/// which is what makes it a complete address rather than "any sentence containing
/// 市". `号` is required: without it this would swallow ordinary prose.
static RE_CN_ADDRESS: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"(?:[\u4e00-\u9fff]{2,8}(?:省|自治区|特别行政区))?(?:[\u4e00-\u9fff]{2,10}(?:市|自治州))[\u4e00-\u9fff0-9]{0,20}?(?:[\u4e00-\u9fff]{2,10}(?:区|县|市))?[\u4e00-\u9fff0-9]{0,24}?(?:路|街|道|巷|弄|大道)[\u4e00-\u9fff0-9]{0,20}?[0-9]{1,5}号",
    )
    .expect("cn address regex is valid")
});

/// 台胞证 / 台湾居民来往大陆通行证 requires a label; this anchor finds the label
/// itself so the digit run right after it can be promoted to a Tier-1 match.
///
/// The alternation covers the printed names: `台胞证` (the colloquial form on
/// contracts), `台湾通行证` and the full `台湾居民来往大陆通行证`. MEASURED
/// 2026-11-03: only `台胞证` was anchored, so `台湾通行证 0123456789` - the form the
/// second review used - matched nothing and stayed verbatim.
static RE_PERMIT_ANCHOR: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:台胞证|台湾(?:居民来往大陆)?通行证)(?:号码)?[:：]?")
        .expect("taiwan permit anchor is valid")
});

static RE_PERMIT_DIGITS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{8}(?:[0-9]{2})?").expect("permit digits regex is valid"));

/// 15-digit legacy ID: 6-digit region + YYMMDD + 3-digit sequence. Matched
/// against the ORIGINAL text (no separator normalisation) because no checksum
/// exists to validate a de-grouped copy, and the label boundary test
/// (same as landline) rejects a longer digit run after the match.
///
/// The label alternation covers the printed forms: 身份证 / 身份证号 /
/// 身份证号码, 证件号码, and the 一代证 phrasings 旧身份证 / 旧行身份证
/// with or without the 号码 suffix.
///
/// `号码?` inside each branch, NOT `(?:号码)?`. The non-capturing form binds
/// 号 and 码 into one optional unit, so it matches 号码 or nothing - never the
/// far more common 号 alone. Measured 2026-11-02: the lawyer-licence label had
/// that shape and did not match `律师执业证号 11101201810123456`; it only worked
/// because the detector then searched the remaining text for a digit run, which
/// a single-pattern SQL audit cannot do. See `RE_LAWYER_LABEL`.
static RE_LEGACY_ID_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:旧行?身份证(?:号码?)?|身份证(?:号码?)?|证件号码?)[:：\s]*")
        .expect("legacy-id label regex is valid")
});

static RE_LEGACY_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[1-9][0-9]{14}").expect("legacy id regex is valid"));

/// 律师执业证号: 17 digits, structurally fixed - kind(1) province(2)
/// city(2) year(4) class(1) gender(1) serial(6). The label is the anchor;
/// `is_bounded` rejects the 18th digit continuation.
///
/// `号码?`, not `(?:号码)?` - see `RE_LEGACY_ID_LABEL`. The non-capturing form
/// cannot match 号 on its own, so `律师执业证号 11101201810123456` failed here;
/// it still worked because the detector then searched forward for the digits,
/// but a single-pattern consumer (the SQL audit in
/// `scripts/lib/RawPiiPatterns.ps1`) has no second step and silently missed it.
/// Measured 2026-11-02, found while reconciling the two.
static RE_LAWYER_LABEL: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:律师)?执业证(号码?)?[:：\s]*").expect("lawyer label regex is valid")
});

static RE_LAWYER_NO: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9]{17}").expect("lawyer number regex is valid"));

// ---------------------------------------------------------------------------
// Identifier classes the 2026-11-02 client scan showed were still surviving.
//
// That run reported `verdict: pass` with 13 replacements while these eight
// classes stayed verbatim in the text:
//   身份证号, 统一社会信用代码, 律师执业证号, 银行账号, 港澳通行证, 车牌,
//   微信号, 纳税人识别号.
//
// Two of those were a rule-layer gap in an existing class (the 18-digit ID and
// the USCC both required a CHECKSUM, so a mistyped or OCR-damaged number was
// skipped); the rest had no rule at all. Each rule below is anchored on the
// document's own label or on a closed structural shape, never on "a long
// digit run", so spec 8.4 still holds.
// ---------------------------------------------------------------------------

/// 车牌号: province + authority letter + 5 characters, or 6 for new energy.
///
/// No label needed: the leading character must be one of the 31 province
/// ideographs, so the shape is closed. `vehicle_plate_shape_ok` re-checks it so
/// the pattern and the validator cannot drift.
///
/// The authority letter is `[A-Za-z]`, not `[A-Z]`. A plate printed in lower case
/// (`京a12345`) is the same plate, and refusing it meant the value stayed in the
/// text. `vehicle_plate_shape_ok` normalises case before the I/O exclusion.
static RE_VEHICLE_PLATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"[京津冀晋蒙辽吉黑沪苏浙皖闽赣鲁豫鄂湘粤桂琼渝川贵云藏陕甘青宁新][A-Za-z][A-Za-z0-9]{5,6}",
    )
    .expect("vehicle plate regex is valid")
});

/// 纳税人识别号 label. The number itself may be a USCC (18 chars) or one of
/// the older 15/17/18/20-digit tax codes, so only the label is fixed here.
static RE_TAX_ID_ANCHOR: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"纳税人识别号(?:码)?[:：\s]*").expect("tax id anchor regex is valid")
});

static RE_TAX_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9A-Z]{15,20}").expect("tax id regex is valid"));

/// 银行账号 / 对公账户 label.
static RE_BANK_ACCOUNT_ANCHOR: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:基本户|一般户|开户行|开户银行)?(?:银行)?(?:账号|帐号|账户|帐户)(?:号码)?[:：\s]*")
        .expect("bank account anchor regex is valid")
});

/// A digit run that may carry printed grouping separators. The width is
/// bounded generously here and trimmed to the real range by
/// `bank_account_shape_ok` after the separators are stripped.
static RE_GROUPED_DIGITS: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[0-9][0-9 \u{FF0D}\u{2013}\u{2014}\-]{6,40}[0-9]").expect("grouped digit regex is valid"));

// ---------------------------------------------------------------------------
// Overseas and minority identifiers (added 2026-11-03).
//
// The second review measured seven classes surviving verbatim, and two of them
// (`TaxID 3101401176368`, `Juristic ID No.0115565002108`) were still in plaintext
// inside ALREADY-INDEXED chunks of a live matter - `invoice-ganjong`. For a
// cross-border practice these are not edge cases.
//
// Two anchoring disciplines, chosen per class:
//
//   * Own structural shape (HK ID, SG NRIC, MY ID): the letter/date structure is
//     published and closed, so no label is needed. Same reasoning as the passport
//     rule - a bare digit run is never claimed.
//   * Label only (Thai TaxID, Thai Juristic ID, military ID): the number is a bare
//     digit run of a length that is ALSO the length of a Thai phone number, a
//     Chinese ID or an order number. Only the printed label distinguishes them, so
//     these fire on `TaxID`, `Juristic ID`, `军字第...号` and nothing shorter.
// ---------------------------------------------------------------------------

/// Hong Kong identity card: letter + 6 digits + `(check)`.
///
/// The bracketed check digit is MANDATORY here. `A123456` alone is also the shape
/// of a WeChat-style handle (`A123456` matched the WeChat rule in the review's own
/// probe and the parentheses were left behind), so requiring the `(d)` keeps the
/// two classes from stealing each other's values and keeps the whole printed value
/// in one span - the review measured `[WECHAT_...](7)`, where the redaction split
/// the number and left its check digit in the clear.
static RE_HK_ID: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[A-Z]{1,2}[0-9]{6}\([0-9A]\)").expect("hk id regex is valid"));

/// Singapore NRIC / FIN: `[STFGM]` + 7 digits + checksum letter.
///
/// The trailing letter is the published check character; the class is closed on
/// both ends by a letter, which is what makes it safe without a label.
static RE_SG_NRIC: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"[STFGM][0-9]{7}[A-Z]").expect("sg nric regex is valid"));

/// Malaysian identity card: `YYMMDD-PB-###G`.
///
/// The HYPHENATED form only, deliberately. A first draft also accepted the
/// run-together 12-digit variant, and it immediately claimed `编号010123456789`
/// and `编号020123456789` as identity cards: any 12-digit run whose head parses as
/// `YYMMDD` qualifies, which is a large slice of ordinary order numbers. The date
/// prefix is not specific enough to stand alone, and the card is printed with its
/// hyphens, so the hyphens are the anchor. `tests/recall.rs`
/// (`rule_layer_landline_false_positives_stay_rejected`) is what caught this.
static RE_MY_ID: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[0-9]{6}-[0-9]{2}-[0-9]{4}").expect("my id regex is valid")
});

/// 军官证: `军字第` + digits + `号`.
///
/// Label-anchored on both ends. A bare 7-digit run is an order number; the printed
/// form `军字第1234567号` is unambiguous, and the trailing 号 is what proves the
/// run ended rather than continuing into a longer number.
static RE_MILITARY_ID: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"军字第[0-9]{6,10}号").expect("military id regex is valid")
});

/// Thai TaxID (13 digits) and Juristic ID, label-anchored.
///
/// The label alternation covers the printed English forms the review's document
/// used: `TaxID`, `Tax ID`, `Juristic ID`. Both labels are anchored to the
/// numbers that follow them rather than to a bare digit run, because 13 digits is
/// also the length of a Thai mobile number and of a Chinese legacy ID.
///
/// The two classes are SEPARATE on purpose. The review measured a Thai juristic
/// id being swallowed by a preceding `泰国税号` window and labelled `TH_TAXID`;
/// here the label decides the class, and the window is bounded by the match
/// itself rather than by a lookback, so a label on a previous line cannot reach
/// forward past its own value.
static RE_TH_TAXID: Lazy<Regex> = Lazy::new(|| {
    // `Tax\s*ID` collapses to `TaxID` in running text, and the label also appears in
    // Chinese. MEASURED 2026-11-03: `买方TaxID3101401176368` in a real chunk matched
    // nothing, so the buyer's tax id stayed in plaintext beside a correctly-tokenised
    // seller registration number.
    Regex::new(
        r"(?:Tax\s*ID|纳税人识别号)(?:\s*No\.?)?[\s:：|()（）\[\]【】`]*([0-9]{13})",
    )
    .expect("thai tax id regex is valid")
});

/// The label may be PRINTED IN CHINESE with the English form in parentheses, and the
/// two words of the English label may be collapsed together:
///
/// ```text
/// 法人登记号 (Juristic ID)
/// 0115565002108
/// 卖方JuristicID0115565002108
/// ```
///
/// MEASURED 2026-11-03 on a live `sanitized` chunk: the English-only pattern missed
/// both layouts, so the seller's juristic registration number stayed in plaintext and
/// stayed searchable - while the BUYER's number two fields later was correctly
/// tokenised. Half a document redacted is the worst outcome, because the leftover
/// value looks like a deliberate exception rather than a miss.
static RE_TH_JURISTIC: Lazy<Regex> = Lazy::new(|| {
    // An explicit separator class, NOT `[:punct:]`.
    //
    // MEASURED 2026-11-03: the same document printed `法人登记号（Juristic ID）` with
    // FULL-WIDTH parentheses and `法人登记号 (Juristic ID)` with half-width ones. An
    // explicit `[:：\s)]` class caught the second and silently missed the first, so the
    // seller's registration number survived in one chunk of a document whose other
    // chunk was correctly tokenised. The class therefore lists both bracket widths and
    // the table pipe, rather than assuming one style.
    Regex::new(
        r"(?:Juristic\s*ID|法人登记号|法人登記號)(?:\s*No\.?)?[\s:：|()（）\[\]【】`]*([0-9]{13})",
    )
    .expect("thai juristic id regex is valid")
});

/// The same Thai TaxID printed with a CHINESE label and no English form at all.
///
/// Two live layouts, both measured 2026-11-03 in `sanitized` chunks of a real matter:
///
/// ```text
/// 泰国税号    0115565002108
/// | 泰国企业税号 | 0115565002108 |
/// ```
///
/// The separator is restricted to whitespace and table pipes, so this cannot reach
/// across a sentence the way a general "N characters after the label" window would.
static RE_TH_TAXID_CN: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"(?:泰国(?:企业)?(?:纳税人识别号|识别号|税号)|泰国(?:企業)?(?:納稅人識別號|識別號|稅號))[\s:：|()（）\[\]【】`]*([0-9]{13})",
    )
    .expect("chinese-labelled thai tax id regex is valid")
});


/// 微信号 label. The handle form is fixed by the platform: starts with a
/// letter, then 5-19 letters/digits/underscore/hyphen.
///
/// The label and the handle are matched as ONE pattern, deliberately. The opaque
/// placeholder `[WECHAT_8CA97849_8]` contains the literal text `WECHAT`; with a
/// separate label regex the label matched inside the redactor's own output and the
/// following `_`-run was then read as a handle. Measured 2026-11-02: the rescan
/// reported an otherwise clean document as leaking a WeChat handle, because the
/// placeholder became the handle.
///
/// The `regex` crate has no lookahead, so the separation is done structurally: after
/// the label the separator is optional, and the handle must begin with a letter.
/// `WECHAT_8CA...` fails on the letter requirement - the text right after the label
/// starts with `_`.
///
/// The separator is `[:：\s]*`, not `[:：\s]+`. Measured 2026-11-02: Chinese documents
/// routinely write `微信号zhangsan_2024` with no separator at all, so requiring one
/// left that handle in the text. Dropping the `+` is safe ONLY because the handle
/// must start with an ASCII letter: `微信号是主要联系方式` still fails, since 是 is not
/// `[A-Za-z]`. That is why the leading-letter requirement cannot be relaxed to gain
/// recall - it is what makes the optional separator safe.
static RE_WECHAT: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"(?:微信号?|WeChat\s*ID)[:：\s]*([A-Za-z][A-Za-z0-9_\-]{5,19})")
        .expect("wechat regex is valid")
});

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
/// Preference order when two rules claim the SAME span with different entities.
///
/// Lower is preferred. A `Context` match read a label from the document itself
/// (`账号`, `纳税人识别号`); a `Pattern` match only inferred from the characters.
/// When they disagree about the same bytes, the document has already said which
/// one it is, so the labelled claim wins.
///
/// MEASURED 2026-11-03, before this existed: `账号 6217900123456789010` produced a
/// `BankCard` AND a `BankAccount` match on the identical span. Both reached the
/// allocator, both minted a token, and the one written second won - so the same
/// account number was `[BANK_CARD_...]` alone and `[BANK_ACCOUNT_...]` after the
/// word 账号. Same for `纳税人识别号 91440300MA5FL8XY3K`, which is why one legal
/// entity got two tokens under the USCC and TIN keywords.
///
/// ## Why the LABEL outranks the CHECKSUM here
///
/// A passing validator is strong evidence about the VALUE, but the class is a
/// claim about what the value IS - and no checksum can settle that for these
/// pairs. Luhn is a mod-10 checksum over 13-19 digits, so roughly one in ten
/// 19-digit bank ACCOUNTS satisfies it by chance; a USCC's MOD-31 and a TIN's
/// digits are unrelated to each other. The label is the only evidence that
/// distinguishes them, and it is the one the document itself supplied.
///
/// MEASURED 2026-11-03, and this is why the ordering was corrected: ranking
/// `Checksum` above `Context` made
///
/// ```text
/// 账号 6217900123456789010      -> [BANK_CARD_...]      WRONG CLASS
/// 账号 6222020200112345678      -> [BANK_ACCOUNT_...]   correct (Luhn happened to fail)
/// ```
///
/// so whether a labelled account was filed as a card or an account depended on
/// the tenth digit of the number. The value was redacted either way, but the
/// class decides which downstream control applies, and it flipped on a coin toss.
/// `Pattern` still loses to both: a shape guess never beats a label or a
/// validator.
fn source_rank(s: &MatchSource) -> u8 {
    match s {
        MatchSource::Context => 0,
        MatchSource::Checksum => 1,
        MatchSource::Pattern => 2,
        MatchSource::Model => 3,
    }
}

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

/// True when the span is not continued by another DIGIT.
///
/// Used only by rules that are anchored on a document LABEL and whose value has a
/// published fixed length (a Thai TaxID is exactly 13 digits, a Thai Juristic ID is
/// exactly 13). For those, a trailing ASCII LETTER is not a continuation of the
/// number - it is the next field starting immediately.
///
/// MEASURED 2026-11-03 on the live `invoice-ganjong` OCR text:
///
/// ```text
/// Juristic IDNo.0115565002108Tel（02）0332333Fax.020332391
/// ```
///
/// Boundary test for a label-anchored numeric field: the digit run must not be
/// followed by another digit.
///
/// Only the RIGHT side is tested. A label like `JuristicID` or `TaxID` already
/// establishes that the value starts where the match does, so checking the
/// character before it would only reject layouts where the label and the value
/// are flush - which is exactly how a bilingual summary prints them
/// (`卖方JuristicID0115565002108`). OCR routinely runs fields together like this.
///
/// The precision this gives up is confined to label-anchored rules: a longer DIGIT
/// run is still rejected, which is the case that matters (an order number that
/// starts with the same digits). A trailing letter cannot extend a numeric value.
fn ends_at_digit_boundary(text: &str, end: usize) -> bool {
    !text[end..]
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_digit())
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

    /// True when this span is already claimed by a stronger rule.
    ///
    /// Precedence has to be explicit, because the classes overlap by construction:
    /// a 13-digit Thai TaxID is card-shaped, an 18-digit mistyped resident ID can
    /// satisfy Luhn, and a USCC's alphabet is a superset of the ID's. Without one
    /// place that answers "who owns this span", each rule grew its own ad-hoc
    /// check and they drifted - the review measured a resident ID labelled
    /// BANK_CARD and a Thai TaxID labelled BANK_CARD in the same pass.
    ///
    /// A LABEL is stronger evidence than a structural shape, which is why the
    /// label-anchored rules run first and claim their span here.
    fn claimed(&self, out: &[Match], start: usize, end: usize) -> bool {
        out.iter()
            .any(|existing| existing.start == start && existing.end == end)
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

        // Overseas and minority classes that need their own LABEL.
        //
        // These run BEFORE the checksum/shape rules for one reason: a 13-digit
        // Thai TaxID is also a card-shaped 13-digit run, and a bare `RE_DIGIT_RUN`
        // claimed it as BANK_CARD. MEASURED 2026-11-03: `TaxID 3101401176368`
        // came back as `TaxID [BANK_CARD_905BCB78D25953F7]` - the value was
        // redacted but the wrong class was recorded, which is the review's
        // "label says one thing, token says another" defect in a new place.
        //
        // A label is stronger evidence than a shape, so it decides the class when
        // both are present. Later rules skip a span that is already claimed.
        // The label is the LEFT boundary, so only the right side is bounded here.
        //
        // MEASURED 2026-11-03: `卖方JuristicID0115565002108` puts the letter `D`
        // immediately before the digits, so the two-sided `is_bounded` rejected a
        // layout that bilingual summaries produce in ordinary running text. The right
        // side still matters - it stops the rule claiming a PREFIX of a longer number.
        for c in RE_TH_JURISTIC.captures_iter(text) {
            let Some(value) = c.get(1) else { continue };
            if !ends_at_digit_boundary(text, value.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                value.start(),
                value.end(),
                &text[value.start()..value.end()],
                EntityType::ThJuristicId,
                MatchSource::Context,
            );
        }
        for c in RE_TH_TAXID.captures_iter(text) {
            let Some(value) = c.get(1) else { continue };
            if !ends_at_digit_boundary(text, value.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                value.start(),
                value.end(),
                &text[value.start()..value.end()],
                EntityType::ThTaxId,
                MatchSource::Context,
            );
        }
        // The Chinese-labelled form. Runs after the English one; `push_span` collapses
        // the two spans if a document carries both.
        for c in RE_TH_TAXID_CN.captures_iter(text) {
            let Some(value) = c.get(1) else { continue };
            if !ends_at_digit_boundary(text, value.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                value.start(),
                value.end(),
                &text[value.start()..value.end()],
                EntityType::ThTaxId,
                MatchSource::Context,
            );
        }
        // 军官证: label-anchored on both ends, so the whole printed form is the span.
        for m in RE_MILITARY_ID.find_iter(text) {
            self.push(&mut out, m, EntityType::MilitaryId, MatchSource::Context);
        }

        // 护照 - label anchored, for the prefixes the PRC structural rule cannot
        // claim. See RE_PASSPORT_ANCHOR: `护照 PE1234567` matched nothing before.
        for a in RE_PASSPORT_ANCHOR.find_iter(text) {
            let Some(rest) = text.get(a.end()..) else {
                continue;
            };
            let Some(m) = RE_PASSPORT_NUMBER.find(rest) else {
                continue;
            };
            let start = a.end() + m.start();
            let end = a.end() + m.end();
            if !is_bounded(text, start, end) || self.claimed(&out, start, end) {
                continue;
            }
            self.push_span(
                &mut out,
                start,
                end,
                &text[start..end],
                EntityType::Passport,
                MatchSource::Context,
            );
        }

        for m in RE_CN_ID_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            // Checksum first: a valid ID is the strongest evidence there is.
            // A value that has the FULL SHAPE but fails the check digit is
            // still personal data - it is a mistyped or OCR-damaged ID, not a
            // non-ID - so it is claimed at Pattern strength instead of skipped.
            //
            // Measured 2026-11-02: the client OCR sample's
            // `110105199003074512` (region 110105, birth 1990-03-07, expected
            // check `X`) survived exactly here and was then indexed as
            // searchable, so the number itself could be used as a lookup key
            // against the vector store. A miss in this class is a defect, not a
            // tuning choice (entity.rs, Tier 1), and "your typo is safe" is not
            // a policy.
            let (entity, source) = if validate_cn_resident_id(m.as_str()) {
                (EntityType::CnResidentId, MatchSource::Checksum)
            } else if cn_resident_id_shape_ok(m.as_str()) {
                (EntityType::CnResidentId, MatchSource::Pattern)
            } else {
                continue;
            };
            self.push_span(&mut out, start, end, &text[start..end], entity, source);
        }

        for m in RE_USCC_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            // Precedence: an 18-character run that has the FULL resident-ID
            // shape is an ID. The USCC alphabet is a superset of the ID's
            // (digits plus uppercase letters, `X` included), so a resident ID
            // is always also a USCC CANDIDATE and would otherwise be reported
            // twice - once correctly, once as a company registration. The ID
            // test is the stricter of the two (region prefix plus a real
            // calendar birthdate), so it decides.
            if cn_resident_id_shape_ok(m.as_str()) {
                continue;
            }
            if self.claimed(&out, start, end) {
                continue;
            }
            // Same two-strength discipline as the resident ID above: a bad
            // MOD-31 digit does not un-register a company.
            let (entity, source) = if validate_uscc(m.as_str()) {
                (EntityType::Uscc, MatchSource::Checksum)
            } else if uscc_shape_ok(m.as_str()) {
                (EntityType::Uscc, MatchSource::Pattern)
            } else {
                continue;
            };
            self.push_span(&mut out, start, end, &text[start..end], entity, source);
        }

        for m in RE_MOBILE_CANDIDATE.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            if self.claimed(&out, start, end) {
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

        // Card-shaped runs.
        //
        // Luhn used to GATE this: only a checksum-valid run became a match, so a
        // card with one digit misread - the single most likely OCR outcome - stayed
        // in the text untouched. MEASURED 2026-11-03 on the review's set:
        // `6222021234567890128` and `6222029876543210987` were redacted, while
        // `6222021234567890129` (one digit off) and `6217000010000000123` came back
        // verbatim. That is the same defect the resident ID had until 2026-11-02,
        // in the same rule layer, fixed for one class and not the other.
        //
        // The check digit is now a LABEL, not a gate: a valid card is Checksum
        // strength, a card-shaped run that fails it is Pattern strength. Both are
        // redacted; the ledger records the difference for review.
        //
        // Precision is preserved by the requirement that matters: `RE_DIGIT_RUN` is
        // 12-19 digits AND the run must be bounded, and a bare numeric run of that
        // width that is not a card is claimed only when it is card-shaped (issuer
        // prefix 2-6, which every bank card carries and no amount, date or order
        // number does). `claimed` suppresses the double-report of an
        // 18-digit value that is already an ID: MEASURED 2026-11-03, an
        // OCR-mistyped 身份证 `440301198001011234` happens to satisfy Luhn and was
        // relabelled BANK_CARD, which would route it past any downstream control
        // keyed on identifier type.
        for m in RE_DIGIT_RUN.find_iter(&normalized.text) {
            let Some((start, end)) = normalized.original_span(text, m.start(), m.end()) else {
                continue;
            };
            if !is_bounded(text, start, end) {
                continue;
            }
            let digits = m.as_str();
            // Already claimed by a labelled or checksum-validated rule: the span
            // belongs to that class, and relabelling it here would send the value
            // past any downstream control keyed on identifier type.
            if self.claimed(&out, start, end) {
                continue;
            }
            if !card_number_shape_ok(digits) {
                continue;
            }
            let source = if validate_luhn(digits) {
                MatchSource::Checksum
            } else {
                MatchSource::Pattern
            };
            self.push_span(
                &mut out,
                start,
                end,
                &text[start..end],
                EntityType::BankCard,
                source,
            );
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

        // 香港入境许可 / 澳门非本地劳工证: label first, then the 7-digit number.
        // See RE_HK_ENTRY_PERMIT_LABEL - `HK1234567` and `M1234567` were a live
        // leak in a document marked `sanitized` and retrievable through kb_search.
        let entry_label_ends: Vec<usize> = RE_HK_ENTRY_PERMIT_LABEL
            .find_iter(text)
            .map(|a| a.end())
            .collect();
        for label_end in entry_label_ends {
            let Some(rest) = text.get(label_end..) else {
                continue;
            };
            // Skip the separator between label and number.
            let skip = rest
                .char_indices()
                .find(|(_, c)| !matches!(c, ':' | '：' | ' ' | '\t' | '\u{3000}'))
                .map(|(i, _)| i)
                .unwrap_or(rest.len());
            let Some(tail) = rest.get(skip..) else {
                continue;
            };
            if let Some(m) = RE_HK_ENTRY_PERMIT_NUMBER.find(tail) {
                let start = label_end + skip + m.start();
                let end = label_end + skip + m.end();
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

        // A complete street address, claimed whole. See RE_CN_ADDRESS - the model
        // splits one address into fragments and leaves the house number behind.
        for m in RE_CN_ADDRESS.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                m.start(),
                m.end(),
                &text[m.start()..m.end()],
                EntityType::PostalAddress,
                MatchSource::Pattern,
            );
        }

        // 澳门居民身份证 `5123456(7)`: a closed shape, so no label is needed.
        for m in RE_MO_ID.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::HkMoPermit, MatchSource::Pattern);
        }

        // 澳门车牌 `澳A1234`: closed shape, no label needed.
        for m in RE_MO_PLATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                m.start(),
                m.end(),
                &text[m.start()..m.end()],
                EntityType::VehiclePlate,
                MatchSource::Pattern,
            );
        }

        // Labelled regional tax identifiers. `Context`, so the same-span collapse
        // prefers them over the shape rules that used to steal the digits:
        // MEASURED 2026-11-03, `越南 MST 0101243150` came out as
        // `[LANDLINE_...]` because a bare-10-digit rule claimed it first.
        for (label_re, num_re, entity) in [
            (&*RE_VN_MST_LABEL, &*RE_VN_MST, EntityType::CnTaxId),
            (&*RE_PH_TIN_LABEL, &*RE_PH_TIN, EntityType::CnTaxId),
            (&*RE_ID_NPWP_LABEL, &*RE_ID_NPWP, EntityType::CnTaxId),
        ] {
            for label in label_re.find_iter(text) {
                let Some(rest) = text.get(label.end()..) else {
                    continue;
                };
                if let Some(m) = num_re.find(rest) {
                    let start = label.end() + m.start();
                    let end = label.end() + m.end();
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
            if let Some(m) = RE_TRAVEL_PERMIT_NUMBER.captures(rest) {
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
                EntityType::LawyerLicense,
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

        // 车牌号 - shape only, no label. See RE_VEHICLE_PLATE: the province
        // character set is closed, so an arbitrary ASCII token cannot match.
        for m in RE_VEHICLE_PLATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if vehicle_plate_shape_ok(m.as_str()) {
                self.push(&mut out, m, EntityType::VehiclePlate, MatchSource::Pattern);
            }
        }

        // 纳税人识别号 - label anchored. The 15/17/18/20-digit tax codes and the
        // 18-character USCC share this label, so the run is accepted on shape
        // breadth rather than a single fixed length.
        for a in RE_TAX_ID_ANCHOR.find_iter(text) {
            let Some(rest) = text.get(a.end()..) else {
                continue;
            };
            let Some(m) = RE_TAX_ID.find(rest) else {
                continue;
            };
            let start = a.end() + m.start();
            let end = a.end() + m.end();
            if !is_bounded(text, start, end) {
                continue;
            }
            // A 15-20 character run of uppercase/digits; require at least one
            // digit so a bare word cannot satisfy the label.
            if !m.as_str().chars().any(|c| c.is_ascii_digit()) {
                continue;
            }
            self.push_span(
                &mut out,
                start,
                end,
                &text[start..end],
                EntityType::CnTaxId,
                MatchSource::Context,
            );
        }

        // 银行账号 / 对公账户 - label anchored, then a digit run whose printed
        // grouping separators are stripped before the length test.
        for a in RE_BANK_ACCOUNT_ANCHOR.find_iter(text) {
            let Some(rest) = text.get(a.end()..) else {
                continue;
            };
            let Some(m) = RE_GROUPED_DIGITS.find(rest) else {
                continue;
            };
            let start = a.end() + m.start();
            let end = a.end() + m.end();
            if !is_bounded(text, start, end) {
                continue;
            }
            let digits: String = text[start..end].chars().filter(|c| c.is_ascii_digit()).collect();
            if !bank_account_shape_ok(&digits) {
                continue;
            }
            // `Match.text` must be the ORIGINAL bytes - it is what the restore
            // mapping returns (rules.rs `push_span`). The stripped digits are
            // only used for the length decision above.
            self.push_span(
                &mut out,
                start,
                end,
                &text[start..end],
                EntityType::BankAccount,
                MatchSource::Context,
            );
        }

        // 微信号 - label and handle in ONE pattern. See RE_WECHAT: a separate
        // label regex matched inside the opaque `[WECHAT_...]` placeholder.
        //
        // Runs BEFORE the structural overseas rules: `A123456` is a legal WeChat
        // handle and the first six digits of a Hong Kong ID. The WeChat rule needs
        // its label, so whichever value actually has a label wins, and a HK ID
        // (`A123456(7)`) has no 微信号 label in front of it.
        for c in RE_WECHAT.captures_iter(text) {
            let Some(handle) = c.get(1) else {
                continue;
            };
            if !is_bounded(text, handle.start(), handle.end()) {
                continue;
            }
            self.push_span(
                &mut out,
                handle.start(),
                handle.end(),
                &text[handle.start()..handle.end()],
                EntityType::WeChatId,
                MatchSource::Context,
            );
        }

        // Hong Kong identity card. Structural: letter + 6 digits + `(check)`.
        for m in RE_HK_ID.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::HkId, MatchSource::Pattern);
        }

        // Singapore NRIC / FIN. Structural: letter + 7 digits + check letter.
        for m in RE_SG_NRIC.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::SgNric, MatchSource::Pattern);
        }

        // Malaysian identity card. The 12-digit run-together form is only claimed
        // when it has a real YYMMDD head, or `RE_MY_ID`'s 12-digit branch would
        // make every 12-digit number an identity card.
        for m in RE_MY_ID.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if malaysian_id_shape_ok(m.as_str()) {
                self.push(&mut out, m, EntityType::MyId, MatchSource::Pattern);
            }
        }

        if out.len() > MAX_MATCHES {
            return Err(RedactError::Internal(format!(
                "detector produced {} matches, exceeding the ceiling of {MAX_MATCHES}",
                out.len()
            )));
        }

        out.sort_by_key(|m| (m.start, m.end));

        // One match per span.
        //
        // Two rules can claim the SAME span with DIFFERENT entities, and both then
        // reach the allocator, which mints a token for each. Whichever is written
        // second wins, so the value's token depends on rule ordering - and a
        // document holding the same account got `BANK_CARD_...` or `BANK_ACCOUNT_...`
        // depending only on whether the word 账号 preceded it. MEASURED 2026-11-03:
        //
        //   6217900123456789010        -> BankCard,  BankAccount? no - BankCard only
        //   账号 6217900123456789010    -> BankCard + BankAccount  (same span)
        //   纳税人识别号 91440300MA5FL8XY3K -> Uscc + CnTaxId      (same span)
        //
        // The second case is why the same value produced different tokens in
        // different contexts: two entities, two HMAC domains, two tags.
        //
        // Preference is CONTEXT over shape. A labelled rule read the document's own
        // words; a shape rule guessed from the digits. When they disagree about the
        // same characters, the document has told us which it is.
        let mut deduped: Vec<Match> = Vec::with_capacity(out.len());
        for m in out {
            match deduped.last_mut() {
                Some(prev) if prev.start == m.start && prev.end == m.end => {
                    // `Context` (label read from the document) beats `Pattern`
                    // (shape guessed from the characters); on a tie keep the first.
                    if source_rank(&m.source) < source_rank(&prev.source) {
                        *prev = m;
                    }
                }
                _ => deduped.push(m),
            }
        }
        let mut out = deduped;

        // A token this crate minted is never a value to redact.
        //
        // ROOT fix for both 2026-11-03 P0s, and it belongs here rather than in
        // either consumer. The consumers each tried to re-derive "is this the
        // redactor's own output" from a SUB-SPAN:
        //   * the pipeline passes the applied-redaction list, which is EMPTY when
        //     the input is already the pipeline's output - so a second pass
        //     re-hashed the token payload into `[CN_TAX_ID_[CN_TAX_ID_...]]`;
        //   * the rescan has no list at all and called `is_placeholder` on the bare
        //     hex tail, which is false, so it reported the token as live residue.
        out.retain(|m| !crate::placeholder::is_token_span(text, m.start, m.end));

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

    /// The Luhn check digit is a LABEL, not a gate.
    ///
    /// Until 2026-11-03 only a Luhn-valid run became a card, so a card with one
    /// digit misread - the most likely OCR outcome - stayed in the text verbatim.
    /// Measured on the second review's set: `6222021234567890129` (one digit off)
    /// and `6217000010000000123` both came back untouched while their valid
    /// neighbours were redacted.
    #[test]
    fn finds_a_bank_card_whether_or_not_luhn_passes() {
        let good = TierOneDetector::new().detect("卡号 4111111111111111").unwrap();
        let card = good
            .iter()
            .find(|m| m.entity == EntityType::BankCard)
            .expect("a Luhn-valid card must be found");
        assert_eq!(card.source, MatchSource::Checksum);

        let bad = TierOneDetector::new().detect("卡号 4111111111111112").unwrap();
        let card = bad
            .iter()
            .find(|m| m.entity == EntityType::BankCard)
            .expect("a one-digit-off card must still be found");
        assert_eq!(
            card.source,
            MatchSource::Pattern,
            "a failed check digit is weaker evidence, not a reason to leave the value"
        );
    }

    /// Dropping the Luhn gate must not turn `RE_DIGIT_RUN` into "any long number".
    #[test]
    fn a_long_number_that_is_not_card_shaped_stays_untouched() {
        // Starts with 1: a mobile, a legacy ID or an order number, never a card.
        for text in ["编号 1381234567890123", "订单 7000000000000000"] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                !found.iter().any(|m| m.entity == EntityType::BankCard),
                "not a card: {text} -> {found:?}"
            );
        }
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

    /// The licence label must match 号 on its own, not only 号码.
    ///
    /// `(?:号码)?` binds 号 and 码 into one optional unit, so it matches 号码 or
    /// nothing - never the common `律师执业证号`. The detector still worked because
    /// it searched forward for the digits after whatever the label consumed, which
    /// hid the defect from every test here. The SQL audit in
    /// `scripts/lib/RawPiiPatterns.ps1` has no second step, so it silently missed a
    /// real 17-digit licence. Found 2026-11-02 while reconciling the two.
    #[test]
    fn finds_lawyer_license_only_with_label() {
        for text in [
            "律师执业证号11101201810123456",
            "律师执业证号码11101201810123456",
            "律师执业证11101201810123456",
            "律师执业证号 11101201810123456",
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == EntityType::LawyerLicense
                    && m.text == "11101201810123456"),
                "labelled lawyer license must be found in {text:?}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
        // 18 digits: the extra digit kills the match via is_bounded.
        let eighteen = TierOneDetector::new().detect("律师执业证号111012018101234567").unwrap();
        assert!(
            !eighteen.iter().any(|m| m.entity == EntityType::LawyerLicense),
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



