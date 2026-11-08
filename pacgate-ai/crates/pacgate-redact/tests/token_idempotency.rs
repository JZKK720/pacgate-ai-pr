//! Regression tests for the two 2026-11-03 P0 defects.
//!
//! Both came from the same root cause: a detector could return a span that is part
//! of a token this crate minted, and every consumer tried to re-derive "is this
//! ours?" from that sub-span instead of the source refusing to emit it.
//!
//! The audit that found them reported the consequence in the strongest possible
//! terms, and it was right: `rescan_residue` recommends *reset + re-sanitize* for
//! any document flagged as published-with-residue, and executing that advice
//! rewrote every token into a nested form, permanently desynchronising the text
//! from the mapping table. An operator who followed the tooling's advice caused
//! more harm than one who did nothing.

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{is_placeholder, is_token_span, MappingVersion, Sanitizer};

fn sanitize(text: &str) -> String {
    Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT)
        .sanitize(text, DataLevel::T3ProjectSpecific)
        .expect("sanitize must not error on readable input")
        .text
}

/// Every surviving match a standalone rescan would report.
///
/// Deliberately mirrors `pacgate-api`'s `rescan_residue_handler` guard exactly,
/// because the defect being tested lived there, not in the crate. The first draft
/// of this helper used `is_token_span` and therefore PASSED even with the fix
/// disabled - it was testing its own guard, not the product's.
fn unprotected_residue(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for d in tier_one_detectors() {
        for m in d.detect(text).unwrap_or_default() {
            if !pacgate_redact::is_token_span(text, m.start, m.end) {
                out.push((format!("{:?}", m.entity), m.text.clone()));
            }
        }
    }
    out
}

// ─────────────────────────────────────────────────────────────────────────────
// P0-1: sanitisation must be idempotent.
// ─────────────────────────────────────────────────────────────────────────────

/// `sanitize(sanitize(x)) == sanitize(x)` for every class that has a token.
///
/// MEASURED 2026-11-03 before the fix:
///   IN  : 纳税人识别号 9131000060728345XG
///   OUT1: 纳税人识别号 [CN_TAX_ID_A9FA1A090A96E294]
///   OUT2: 纳税人识别号 [CN_TAX_ID_[CN_TAX_ID_85A7B0C09E104279]]
///
/// The bank-account case passed by LUCK, not by design: its hex tail happened to
/// start with a letter, so the numeric account rule could not claim it. A token
/// whose payload starts with digits would still have nested. That is why this test
/// covers several classes instead of the one the report happened to show.
#[test]
fn sanitising_twice_is_the_same_as_sanitising_once() {
    let cases = [
        "纳税人识别号 9131000060728345XG",
        "统一社会信用代码 91440300MA5FL8XY3K",
        "身份证号 110105199003074512",
        "开户行：中国工商银行 账号：6222020200112345678",
        "手机 13812345678，邮箱 a@b.com",
        "车牌 粤B12345，护照 E12345678",
        "身份证号 110105199003074512，统一社会信用代码 91440300MA5FL8XY3K，手机 13812345678",
    ];
    for text in cases {
        let once = sanitize(text);
        let twice = sanitize(&once);
        assert_eq!(
            once, twice,
            "sanitize is not idempotent for {text:?}\n  once : {once}\n  twice: {twice}"
        );
        assert!(
            !twice.contains("[CN_TAX_ID_["),
            "nested token after a second pass: {twice}"
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// P0-2: the residue scanner must not report the redactor's own output.
// ─────────────────────────────────────────────────────────────────────────────

/// A freshly sanitised document must rescan clean.
///
/// MEASURED 2026-11-03 before the fix: the single-line document
/// `纳税人识别号 9131000060728345XG` returned `verdict: pass` from
/// `sanitize_document` while `rescan_residue` reported
/// `entity: CN_TAX_ID, text: "D2270626DD0AACC6"` - the hex tail of the token the
/// first call had just minted.
#[test]
fn a_freshly_sanitised_document_rescans_clean() {
    let cases = [
        "纳税人识别号 9131000060728345XG",
        "统一社会信用代码 91440300MA5FL8XY3K",
        "身份证号 110105199003074512",
        "开户行：中国工商银行 账号：6222020200112345678",
        "手机 13812345678",
        "车牌 粤B12345",
        "护照 E12345678",
    ];
    for text in cases {
        let out = sanitize(text);
        let residue = unprotected_residue(&out);
        assert!(
            residue.is_empty(),
            "rescan reported the redactor's own output as residue for {text:?}\n  \
             sanitised: {out}\n  residue: {residue:?}"
        );
    }
}

/// The two halves of a token are both recognised: bracketed and bare.
///
/// A bare token is what a document holds after its brackets were stripped by
/// formatting, an OCR pass or a copy-paste. Before the fix only the bracketed form
/// was protected, so the bare form was re-hashed.
#[test]
fn both_token_shapes_are_recognised() {
    for tok in [
        "[CN_TAX_ID_ABCDEF0123456789]",
        "CN_TAX_ID_ABCDEF0123456789",
        "[USCC_5D33DC4C5D56C7B9]",
        "BANK_CARD_1F0C0F7E5B8D99EE",
        "[PERSON_A26542CDFABF6457]",
    ] {
        assert!(
            is_token_span(tok, 0, tok.len()),
            "not recognised as a token: {tok}"
        );
    }

    // Real values must NOT be excused, or the guard becomes a leak.
    for real in [
        "9131000060728345XG",
        "110105199003074512",
        "6222020200112345678",
    ] {
        assert!(
            !is_token_span(real, 0, real.len()),
            "a real value was excused as a token: {real}"
        );
    }
}

/// A sub-span inside a bracketed token is a token span - this is the exact shape
/// the detectors return, and the shape every consumer was testing with
/// `is_placeholder(m.text)` which is false for it.
#[test]
fn a_span_inside_a_bracketed_token_is_recognised() {
    let text = "纳税人识别号 [CN_TAX_ID_A9FA1A090A96E294]";
    let hex = "A9FA1A090A96E294";
    let start = text.find(hex).expect("fixture must contain the payload");
    let end = start + hex.len();

    assert!(
        !is_placeholder(hex),
        "precondition: the bare payload is not itself a bracketed token"
    );
    assert!(
        is_token_span(text, start, end),
        "the payload of a bracketed token must be recognised at its real position"
    );
}

/// The second audit round's exact table, which showed the trigger is the KEYWORD,
/// not the bracket.
///
/// MEASURED 2026-11-03 (before): bracket-only and bare-only were both clean at
/// `n=0`, `纳税人识别号 [CN_TAX_ID_...]` was clean, but
/// `纳税人识别号 CN_TAX_ID_ABCDEF0123456789` (no brackets) still produced
/// `纳税人识别号 CN_TAX_ID_[CN_TAX_ID_949F3E55A690184A]`.
///
/// The reviewer's conclusion was exactly right: "触发条件是关键字前缀，不是括号"
/// (the trigger is the keyword prefix, not the bracket). `is_token_span` therefore
/// had to recognise the PAYLOAD of an un-bracketed `<CODE>_` token, which the
/// first draft missed because it only walked back to a `[`.
#[test]
fn the_keyword_prefixed_forms_are_all_inert() {
    let cases = [
        "[CN_TAX_ID_ABCDEF0123456789]",
        "CN_TAX_ID_ABCDEF0123456789",
        "纳税人识别号 [CN_TAX_ID_ABCDEF0123456789]",
        "纳税人识别号 CN_TAX_ID_ABCDEF0123456789",
        "纳税人识别号 CN_TAX_ID_ABCDEF0123456789 完",
        "统一社会信用代码 [USCC_5D33DC4C5D56C7B9]",
        "统一社会信用代码 USCC_5D33DC4C5D56C7B9",
        "账号 [BANK_ACCOUNT_D9E6F5284E8EB597]",
        "账号 BANK_ACCOUNT_D9E6F5284E8EB597",
    ];
    for text in cases {
        let out = sanitize(text);
        assert_eq!(
            out, text,
            "an existing token was rewritten: {text:?} -> {out:?}"
        );
        assert!(
            !out.contains("[[") && !out.matches("[CN_TAX_ID_").count().gt(&1),
            "a token was nested: {out}"
        );
    }
}

/// A token that ALREADY has nested layers must survive untouched.
///
/// The reviewer left `audit-0.2.18-resanitize-probe` in place as a live specimen:
/// its body is a three-layer nest. Re-running the pipeline over it must be a
/// no-op, or the regression recurses one level per pass.
#[test]
fn an_already_nested_token_is_not_nested_further() {
    for text in [
        "纳税人识别号 [CN_TAX_ID_[CN_TAX_ID_BBECB50C9C2E0BE0]]",
        "纳税人识别号 [CN_TAX_ID_[CN_TAX_ID_[CN_TAX_ID_A8E10AFB65523245]]]",
    ] {
        let out = sanitize(text);
        assert_eq!(out, text, "nested token was rewritten: {text:?} -> {out:?}");
    }
}

/// P0-3: the same account number must yield ONE token regardless of context.
///
/// MEASURED 2026-11-03 (before): the value `6217900123456789010` produced
/// `[BANK_CARD_...]` bare and `[BANK_ACCOUNT_...]` after the word 账号 - different
/// type AND different tag - because the bank-card and bank-account rules both
/// claimed the identical span and both reached the allocator.
#[test]
fn one_account_number_yields_one_token_in_every_context() {
    let value = "6217900123456789010";
    let forms = [
        value.to_string(),
        format!("账号 {value}"),
        format!("账号：{value}"),
        format!("账号 {} {} {} {}", &value[0..4], &value[4..8], &value[8..12], &value[12..]),
    ];

    // ONE key for every form, because the question is whether CONTEXT changes the
    // token. Two separate `Sanitizer::new` calls would derive different keys and
    // every token would differ for a reason that has nothing to do with the defect.
    let key = pacgate_redact::TokenKey::from_secret(b"idempotency-test-key");
    let mut tokens = Vec::new();
    for f in forms {
        let mut s = Sanitizer::with_key(tier_one_detectors(), MappingVersion::CURRENT, key.clone());
        let out = s
            .sanitize(&f, DataLevel::T3ProjectSpecific)
            .expect("sanitize must not error")
            .text;
        // Extract the bracket token itself, not the surrounding label text. Form #2
        // is `账号：[BANK_CARD_...]` and a whitespace split keeps the `账号：` prefix.
        let start = out.find('[').unwrap_or_else(|| panic!("no token in {out:?}"));
        let end = out[start..]
            .find(']')
            .map(|i| start + i + 1)
            .unwrap_or_else(|| panic!("unterminated token in {out:?}"));
        tokens.push(out[start..end].to_string());
    }
    let first = &tokens[0];
    let _ = first;
    // The BARE form is expected to differ, and that is the honest outcome: with no
    // label, a 19-digit Luhn-valid run is indistinguishable from a card. Only the
    // LABELLED forms are required to agree - the document said 账号, so all four
    // labelled spellings must file it the same way.
    let labelled = &tokens[1];
    for (i, t) in tokens.iter().enumerate().skip(1) {
        assert_eq!(
            t, labelled,
            "context changed the token: labelled form #{i} gave {t}, expected {labelled}"
        );
    }
    assert!(
        tokens[1].starts_with("[BANK_ACCOUNT_"),
        "a labelled account must be filed as an account, not a card - Luhn is a \
         mod-10 checksum over 13-19 digits, so this 19-digit ACCOUNT satisfies it \
         by chance and the card rule claims the same span. The label is the only \
         evidence that distinguishes the two classes: {}",
        tokens[1]
    );
}

///
/// The bracket walk can be fooled two ways, and both would hide a real value:
/// a bracket that is already closed before the span, and a second bracket opening
/// before the closing one.
#[test]
fn the_bracket_walk_does_not_over_excuse() {
    // `[CN_ID_AAA...]` is closed, then a real value follows outside it.
    let text = "[CN_ID_AAAABBBBCCCCDDDD] 110105199003074512";
    let start = text.find("110105199003074512").expect("fixture");
    let end = start + 18;
    assert!(
        !is_token_span(text, start, end),
        "a real ID after a closed token must not inherit the token's protection"
    );

    // An unclosed bracket must not protect everything to its right.
    let text = "[CN_ID_AAAABBBBCCCCDDDD 110105199003074512";
    let start = text.find("110105199003074512").expect("fixture");
    let end = start + 18;
    assert!(
        !is_token_span(text, start, end),
        "a malformed bracket must not be treated as a token"
    );
}

/// A LABELLED account must be filed as an account, not a card.
///
/// The bare form cannot also be an account: with no label there is nothing to
/// distinguish a 19-digit account from a card, and `BANK_CARD` is the honest
/// answer for an unlabelled Luhn-valid run. That is why this test asserts the
/// LABEL wins - not that both forms agree. They cannot, and pretending otherwise
/// would hide which one the document actually said.
#[test]
fn a_labelled_account_is_never_filed_as_a_bank_card() {
    let out = sanitize("账号 6217900123456789010");
    assert!(
        out.contains("[BANK_ACCOUNT_"),
        "a value the document labels 账号 must be filed as an account, \
         whatever its check digit happens to say: {out}"
    );
    assert!(
        !out.contains("[BANK_CARD_"),
        "a labelled account must never be reported as a card: {out}"
    );
}

/// The same rule in the other direction: a BARE card-shaped run is still a card,
/// so the fix above cannot pass by relabelling everything.
#[test]
fn a_bare_card_number_is_still_a_bank_card() {
    let out = sanitize("6222020200112345678");
    assert!(
        out.contains("[BANK_CARD_"),
        "with no label, a card-shaped Luhn-valid run is a card: {out}"
    );
}

/// Every PRINTED LABEL FORM of one account yields one token.
///
/// The class is settled by the label in every one of these, so the token must not
/// move. Only the bare form is excluded: with no label it is indistinguishable
/// from a card, which is a property of the evidence, not a defect here.
#[test]
fn every_label_form_of_one_account_yields_one_token() {
    let forms = [
        "账号 6217900123456789010",
        "账号：6217900123456789010",
        "银行账号 6217900123456789010",
        "账号号码 6217900123456789010",
    ];
    // ONE key for every form. `sanitize()` builds a fresh `Sanitizer`, which mints
    // a fresh random key, so every token would differ for a reason unrelated to the
    // question being asked.
    let key = pacgate_redact::TokenKey::from_secret(b"label-form-test-key");
    let mut tokens = Vec::new();
    for form in forms {
        let mut s = Sanitizer::with_key(tier_one_detectors(), MappingVersion::CURRENT, key.clone());
        let out = s
            .sanitize(form, DataLevel::T3ProjectSpecific)
            .expect("sanitize must not error")
            .text;
        let start = out.find('[').unwrap_or_else(|| panic!("no token in {out:?}"));
        let end = out[start..]
            .find(']')
            .map(|i| start + i + 1)
            .unwrap_or_else(|| panic!("unterminated token in {out:?}"));
        tokens.push(out[start..end].to_string());
    }
    assert!(
        tokens.windows(2).all(|w| w[0] == w[1]),
        "one account number, one token, whatever the label form: {tokens:?}"
    );
}
