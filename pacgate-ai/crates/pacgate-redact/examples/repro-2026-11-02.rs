// Repro harness for the 2026-11-02 client report.
//
// Prints the sanitize outcome for the exact text the client scanned, so the
// before/after difference is visible rather than inferred from a unit test.
//
// Run with:
//   cargo run -p pacgate-redact --example repro-2026-11-02

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{MappingVersion, Sanitizer};

fn main() {
    let inputs = [
        // The line the client found still searchable.
        "委托人：[PERSON_14BF81AB_1]身份证号：110105199003074512",
        // The rest of the eight classes, in contract-shaped sentences.
        "甲方：某某科技有限公司（统一社会信用代码：91350100M000100Y43）",
        "代理律师：李某，律师执业证号 11101201810123456",
        "开户行：中国工商银行北京分行 账号：6222020200112345678",
        "证件号码 C12345678 港澳通行证",
        "抵押车辆 粤B12345",
        "微信：zhang_san_88",
        "纳税人识别号 91350100M000100Y43",
        // Precision controls: none of these may change.
        "借款金额 1,250,000.00 元，年利率 4.35%，期限 2026-01-01 至 2028-12-31",
        "Contract No.PG-2026-0042 / Invoice Total USD 18,400.00",
        "参见 (2019)最高法民终1234号 的裁判要旨",
    ];

    for text in inputs {
        let mut s = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
        match s.sanitize(text, DataLevel::T3ProjectSpecific) {
            Ok(out) => {
                println!("IN   {text}");
                println!("OUT  {}", out.text);
                println!(
                    "     verdict={:?} redactions={} residue={}",
                    out.ledger.verdict(),
                    out.ledger.redaction_count,
                    out.ledger.residue.len()
                );
                for note in &out.ledger.verification_notes {
                    println!("     note: {note}");
                }
                println!();
            }
            Err(e) => println!("IN   {text}\nERR  {e}\n"),
        }
    }
}
