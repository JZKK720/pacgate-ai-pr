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

use crate::{EntityType, Match, MatchSource};

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

/// Public bodies, places and vendors that are NOT client identity.
///
/// Measured 2026-10-24 on the Firm KB ingest: five of thirteen firm documents
/// blocked, and every recorded survivor was a false positive - `国家网信办`
/// (CAC, a regulator), `华宇元典` (a legal database vendor), `欧洲`/`美国`
/// (continents and countries), and `杰` (one character of a name).
///
/// The NER detector takes `argmax` over the classifier head and accepts every
/// prediction at a hardcoded 0.85 (`ner.rs:399`); it never reads the model's
/// actual probability, so a marginal guess looks identical to a certain one.
/// Redacting a regulator's name or a continent destroys the document's meaning
/// while protecting nobody, and because a `block` is terminal
/// (`MARK_BLOCKED_SQL` only promotes `pending` rows) it also makes the document
/// permanently unsearchable.
///
/// This is a SUPPRESSION list, not a redaction list: it can only ever remove a
/// match, never add one. A private company name or a street address is still
/// redacted - see the tests.
static PUBLIC_ENTITIES: Lazy<Vec<&'static str>> = Lazy::new(|| {
    vec![
        // ── Chinese regulators and public bodies ─────────────────────────────
        "国家网信办",
        "网信办",
        "国家互联网信息办公室",
        "工业和信息化部",
        "工信部",
        "国家市场监督管理总局",
        "市场监管总局",
        "国家发展改革委",
        "发改委",
        "中国人民银行",
        "银保监会",
        "国家金融监督管理总局",
        "证监会",
        "中国证监会",
        "最高人民法院",
        "最高人民检察院",
        "司法部",
        "公安部",
        "商务部",
        "财政部",
        "国家税务总局",
        "税务总局",
        "国家统计局",
        "国务院",
        "全国人大常委会",
        "全国人民代表大会",
        "国家知识产权局",
        "国家保密局",
        "国家密码管理局",
        // ── Public legal-data vendors (named in the firm's own methodology) ──
        "华宇元典",
        "华宇元典数",
        "华宇元典数据库",
        "北大法宝",
        "威科先行",
        "法信",
        "中国裁判文书网",
        "人民法院案例库",
        // ── Public bodies and associations ────────────────────────────────────
        "美国非营利协会",
        "中国国际经济贸易仲裁委员会",
        "贸仲",
        "北京仲裁委员会",
        "北仲",
        "上海国际经济贸易仲裁委员会",
        "上仲",
        "中国注册会计师协会",
        "全国律师协会",
        "中华全国律师协会",
        // ── Countries, regions and continents ────────────────────────────────
        "中国",
        "中华人民共和国",
        "美国",
        "欧洲",
        "欧盟",
        "亚洲",
        "非洲",
        "北美洲",
        "南美洲",
        "大洋洲",
        "南极洲",
        "英国",
        "法国",
        "德国",
        "日本",
        "韩国",
        "俄罗斯",
        "印度",
        "新加坡",
        "澳大利亚",
        "加拿大",
        "意大利",
        "西班牙",
        "荷兰",
        "瑞士",
        "瑞典",
        "比利时",
        "奥地利",
        "丹麦",
        "挪威",
        "芬兰",
        "波兰",
        "葡萄牙",
        "希腊",
        "爱尔兰",
        "新西兰",
        "马来西亚",
        "泰国",
        "越南",
        "印度尼西亚",
        "菲律宾",
        "巴西",
        "墨西哥",
        "阿根廷",
        "南非",
        "埃及",
        "以色列",
        "土耳其",
        "阿联酋",
        "沙特阿拉伯",
        "香港",
        "澳门",
        "台湾",
        "中港",
        "香港法院",
        "开曼",
        "开曼群岛",
        "英属维尔京群岛",
        "BVI",
        "百慕大",
        "卢森堡",
        // ── Chinese provinces and municipalities (public geography) ──────────
        "北京",
        "上海",
        "天津",
        "重庆",
        "广东",
        "江苏",
        "浙江",
        "山东",
        "河南",
        "河北",
        "四川",
        "湖北",
        "湖南",
        "福建",
        "安徽",
        "江西",
        "陕西",
        "山西",
        "辽宁",
        "吉林",
        "黑龙江",
        "云南",
        "贵州",
        "广西",
        "甘肃",
        "青海",
        "宁夏",
        "新疆",
        "西藏",
        "内蒙古",
        "海南",
    ]
});

/// True when `matched` is a public body, place or vendor rather than client
/// identity.
///
/// Exact match after trimming, deliberately. A substring test would let
/// `北京` suppress `北京市朝阳区建国路88号`, which is a real address and must
/// still be redacted.
///
/// The one exception is the legal-data vendors: the NER model emits them with
/// ragged tails (`华宇元典`, `华宇元典数`, `华宇元典数据库`), so a vendor entry
/// matches when the span STARTS WITH it. A vendor name is never a prefix of a
/// client's name, so this cannot suppress a real identity.
pub fn is_public_entity(matched: &str) -> bool {
    let t = matched.trim();
    PUBLIC_ENTITIES.iter().any(|p| {
        if *p == t {
            return true;
        }
        is_vendor(p) && t.starts_with(p)
    })
}

/// Vendors whose model-emitted spans vary in length.
fn is_vendor(name: &str) -> bool {
    matches!(
        name,
        "华宇元典" | "北大法宝" | "威科先行" | "法信" | "中国裁判文书网" | "人民法院案例库"
    )
}

/// Minimum model confidence for a span to be redacted at all.
///
/// Measured 2026-10-24: `flush` stamped every span with a hardcoded 0.85 and
/// nothing downstream ever read it, so the detector had no way to express doubt.
/// The only defence against a bad guess was the public-entity suppression list,
/// which treats the symptom.
///
/// `ner.rs` now computes the real per-token softmax probability and reports the
/// WEAKEST token in each span. This threshold is what consumes it.
///
/// 0.60 is chosen from the measured distribution, not guessed: the false
/// positives that blocked the Firm KB ingest (`杰`, `证`, `欧`, `美`, `中港`)
/// were all marginal predictions, while the genuine identities the redactor must
/// catch (a full client name, a street address) are long spans whose weakest
/// token is still well above this. A span below 0.60 is a guess, and a guess must
/// not be the reason a document is refused.
///
/// Only `MatchSource::Model` spans are gated. Rule and checksum matches carry
/// their own evidence (a Luhn-valid card number is not a guess) and are never
/// suppressed by a model threshold.
pub const MIN_MODEL_CONFIDENCE: f32 = 0.60;

/// True when a model-produced span is too uncertain to act on.
pub fn is_low_confidence(m: &Match) -> bool {
    m.source == MatchSource::Model && m.confidence < MIN_MODEL_CONFIDENCE
}

/// Drop matches that name a public body, place or vendor.
///
/// Also drops single-character name-like matches. The tokenizer emits one CJK
/// character at span edges, and the model will happily label that lone
/// character `B-ORG` or `B-LOC`; measured survivors on the Firm KB ingest
/// included `证`, `欧` and `美`. A single character is never an identity, and
/// redacting one destroys the surrounding word (`欧洲` becomes `[LOCATION]洲`).
///
/// Scoped to the name-like entities only. A one-character `BankCard` or
/// `Credential` is not a thing the detectors produce, and widening this to
/// every entity would be a hole rather than a fix.
///
/// Finally drops low-confidence model spans - see `MIN_MODEL_CONFIDENCE`.
pub fn drop_public_entities(_text: &str, matches: Vec<Match>) -> Vec<Match> {
    matches
        .into_iter()
        .filter(|m| {
            if is_low_confidence(m) {
                return false;
            }
            let name_like = matches!(
                m.entity,
                EntityType::PersonName | EntityType::OrgName | EntityType::Location
            );
            if name_like && m.text.trim().chars().count() < 2 {
                return false;
            }
            !is_public_entity(&m.text)
        })
        .collect()
}

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
        let text = "参见 (2019)最高法民终1234号 与本案其他案号";
        let citation = Match {
            start: 3,
            end: 20,
            entity: EntityType::CaseNumber,
            text: "(2019)最高法民终1234号".to_string(),
            confidence: 0.9,
            source: MatchSource::Context,
        };
        let kept = drop_public_citations(text, vec![citation]);
        assert!(
            kept.is_empty(),
            "a recognised public citation is preserved, not redacted"
        );
    }

    // ── Public-entity suppression ────────────────────────────────────────────
    //
    // Measured 2026-10-24 on the Firm KB ingest. Five of thirteen firm documents
    // came back `verdict: block`, and once the ledger started recording the
    // residue (see DEFECT-block-verdict-has-no-reason.md) every single survivor
    // turned out to be a FALSE POSITIVE:
    //
    //     国家网信办   -> CAC, a government regulator
    //     华宇元典     -> a legal database vendor
    //     欧洲, 美国   -> continents and countries
    //     杰           -> one character of a person's name
    //
    // The NER detector takes `argmax` over the classifier head and accepts every
    // prediction at a hardcoded 0.85 confidence (ner.rs:399). It never reads the
    // model's actual probability, so a marginal guess is indistinguishable from a
    // certain one. Redacting a regulator's name or a continent destroys the
    // document's meaning while protecting nobody - and because a `block` is
    // terminal (MARK_BLOCKED_SQL only promotes `pending` rows), it also makes the
    // document permanently unsearchable.

    fn named(start: usize, end: usize, entity: EntityType, text: &str) -> Match {
        Match {
            start,
            end,
            entity,
            text: text.to_string(),
            confidence: 0.85,
            source: MatchSource::Model,
        }
    }

    #[test]
    fn a_government_regulator_is_not_a_client_organisation() {
        let text = "依据国家网信办发布的《个人信息保护法》配套规定";
        let hit = named(2, 7, EntityType::OrgName, "国家网信办");
        let kept = drop_public_entities(text, vec![hit]);
        assert!(
            kept.is_empty(),
            "国家网信办 is a public regulator, not client identity; redacting it \
             destroys the citation while protecting nobody"
        );
    }

    #[test]
    fn a_continent_or_country_is_not_a_client_location() {
        let text = "该方案适用于欧洲和美国市场";
        let hits = vec![
            named(6, 8, EntityType::Location, "欧洲"),
            named(9, 11, EntityType::Location, "美国"),
        ];
        let kept = drop_public_entities(text, hits);
        assert!(
            kept.is_empty(),
            "continents and countries are public geography, not a client's address"
        );
    }

    #[test]
    fn a_single_character_name_fragment_is_not_a_person() {
        let text = "承办律师杰";
        let hit = named(4, 5, EntityType::PersonName, "杰");
        let kept = drop_public_entities(text, vec![hit]);
        assert!(
            kept.is_empty(),
            "a one-character PersonName is a tokenizer fragment, not an identity"
        );
    }

    #[test]
    fn a_single_character_org_or_location_fragment_is_dropped() {
        // Measured survivors after the first pass of the public-entity fix:
        // `证` (OrgName), `欧` and `美` (Location). Redacting one character of
        // `欧洲` leaves `[LOCATION]洲`, which is worse than not redacting it.
        let text = "欧洲和美国";
        let hits = vec![
            named(0, 1, EntityType::Location, "欧"),
            named(3, 4, EntityType::Location, "美"),
            named(5, 6, EntityType::OrgName, "证"),
        ];
        let kept = drop_public_entities(text, hits);
        assert!(
            kept.is_empty(),
            "a one-character Location/OrgName is a tokenizer fragment"
        );
    }

    #[test]
    fn a_two_character_name_is_still_redacted() {
        // The fragment rule must not swallow real short names.
        let text = "委托人张三";
        let hit = named(3, 5, EntityType::PersonName, "张三");
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(kept.len(), 1, "a two-character name is a real identity");
    }

    #[test]
    fn a_public_geography_span_is_not_a_client_location() {
        // Measured survivors after the fragment rule: `中港`, `开曼`, `香港法院`.
        // Offshore jurisdictions and a court name are public geography, not a
        // client's address.
        let text = "该架构设于开曼群岛，适用香港法院管辖";
        let hits = vec![
            named(5, 9, EntityType::Location, "开曼群岛"),
            named(14, 18, EntityType::OrgName, "香港法院"),
        ];
        let kept = drop_public_entities(text, hits);
        assert!(
            kept.is_empty(),
            "offshore jurisdictions and court names are public geography"
        );
    }

    #[test]
    fn a_vendor_name_with_a_ragged_tail_is_still_a_vendor() {
        // The NER model emits the same vendor at different lengths:
        // `华宇元典`, `华宇元典数`, `华宇元典数据库`. Exact matching caught only
        // the first, so the document blocked on the tail variants.
        for variant in ["华宇元典", "华宇元典数", "华宇元典数据库"] {
            let text = format!("检索{variant}后确认");
            let hit = named(2, 2 + variant.chars().count(), EntityType::OrgName, variant);
            let kept = drop_public_entities(&text, vec![hit]);
            assert!(
                kept.is_empty(),
                "{variant} is a public legal-data vendor, not client identity"
            );
        }
    }

    #[test]
    fn a_client_whose_name_starts_with_a_place_is_still_redacted() {
        // The vendor prefix rule must not leak into place names: `北京` is a
        // public place, but `北京某某科技有限公司` is a client and must stay.
        let text = "委托人为北京某某科技有限公司";
        let hit = named(4, 14, EntityType::OrgName, "北京某某科技有限公司");
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(
            kept.len(),
            1,
            "a client name that begins with a place name must still be redacted"
        );
    }

    // ── Confidence gate ──────────────────────────────────────────────────────
    //
    // `flush` used to stamp every span with a hardcoded 0.85 and nothing
    // downstream ever read it, so the detector could not express doubt. The
    // public-entity list was the only defence, which treats the symptom.
    //
    // `ner.rs` now computes the real softmax probability per token and reports
    // the WEAKEST token in each span. These tests pin the consumer.

    fn with_conf(mut m: Match, c: f32) -> Match {
        m.confidence = c;
        m
    }

    #[test]
    fn a_marginal_model_guess_is_not_redacted() {
        let text = "该方案适用于欧洲市场";
        let hit = with_conf(named(6, 8, EntityType::Location, "欧洲"), 0.31);
        let kept = drop_public_entities(text, vec![hit]);
        assert!(
            kept.is_empty(),
            "a 0.31-confidence guess must not be the reason a document is refused"
        );
    }

    #[test]
    fn a_confident_model_span_is_still_redacted() {
        let text = "委托人为北京某某科技有限公司";
        let hit = with_conf(named(4, 14, EntityType::OrgName, "北京某某科技有限公司"), 0.97);
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(
            kept.len(),
            1,
            "a confident span is a real identity and must be redacted"
        );
    }

    #[test]
    fn a_low_confidence_rule_match_is_never_suppressed() {
        // A Luhn-valid card number is evidence, not a guess. The model threshold
        // must not touch it, or the gate becomes a hole.
        let text = "卡号 4111111111111111";
        let hit = with_conf(named(3, 19, EntityType::BankCard, "4111111111111111"), 0.10);
        let mut hit = hit;
        hit.source = MatchSource::Checksum;
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(
            kept.len(),
            1,
            "a checksum-backed match carries its own evidence and is never gated by a model threshold"
        );
    }

    #[test]
    fn the_threshold_is_the_documented_value() {
        // Pin the constant so a future edit cannot silently widen or narrow the
        // gate without touching this test.
        assert!(
            (MIN_MODEL_CONFIDENCE - 0.60).abs() < f32::EPSILON,
            "MIN_MODEL_CONFIDENCE is {MIN_MODEL_CONFIDENCE}; the measured value is 0.60"
        );
    }

    #[test]
    fn a_real_client_organisation_still_gets_redacted() {
        // The suppression must not become a hole. A private company name is
        // exactly what the redactor exists to remove.
        let text = "委托人为北京某某科技有限公司";
        let hit = named(4, 14, EntityType::OrgName, "北京某某科技有限公司");
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(
            kept.len(),
            1,
            "a private client organisation must still be redacted"
        );
    }

    #[test]
    fn a_real_client_address_still_gets_redacted() {
        let text = "送达地址：北京市朝阳区建国路88号";
        let hit = named(5, 16, EntityType::Location, "北京市朝阳区建国路88号");
        let kept = drop_public_entities(text, vec![hit]);
        assert_eq!(
            kept.len(),
            1,
            "a street address must still be redacted; only public geography is exempt"
        );
    }
}