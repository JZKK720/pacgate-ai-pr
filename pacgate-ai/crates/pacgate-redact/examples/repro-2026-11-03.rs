// Ad-hoc probe for the 2026-11-03 second-round review.
//
// Purpose: measure, not assert. Prints what the CURRENT build does to the exact
// values the reviewer listed, so the fix can be checked against the same inputs.

use pacgate_core::DataLevel;
use pacgate_redact::detect::tier_one_detectors;
use pacgate_redact::{MappingVersion, Sanitizer};

fn run(label: &str, inputs: &[&str]) {
    println!("--- {label}");
    for text in inputs {
        let mut s = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
        match s.sanitize(text, DataLevel::T3ProjectSpecific) {
            Ok(out) => println!("  IN  {text}\n  OUT {}", out.text),
            Err(e) => println!("  IN  {text}\n  ERR {e}"),
        }
    }
    println!();
}

/// Same value at different positions in one job.
fn position_drift() {
    println!("--- position drift: one job, same ID three times, other values between");
    let mut s = Sanitizer::new(tier_one_detectors(), MappingVersion::CURRENT);
    for text in [
        "身份证 44030119800101123X",
        "手机 13812345678 身份证 44030119800101123X",
        "身份证 310101198505054321 然后 44030119800101123X",
    ] {
        match s.sanitize(text, DataLevel::T3ProjectSpecific) {
            Ok(out) => println!("  IN  {text}\n  OUT {}", out.text),
            Err(e) => println!("  IN  {text}\n  ERR {e}"),
        }
    }
    println!();
}

fn main() {
    run(
        "resident id",
        &[
            "身份证 44030119800101123X",
            "身份证 440301198001011234",
            "身份证 310101198505054321",
        ],
    );
    run(
        "uscc",
        &[
            "统一社会信用代码 91110105CA01ABCD26",
            "统一社会信用代码 91350100M000100Y43",
        ],
    );
    run(
        "bank card luhn gate",
        &[
            "卡号 6222021234567890128",
            "卡号 6222029876543210987",
            "卡号 6222021234567890129",
            "卡号 6217000010000000123",
        ],
    );
    run(
        "ocr-mistyped id that happens to pass luhn",
        &["身份证 440301198001011234"],
    );
    run(
        "bank account",
        &["开户行：中国工商银行 账号：6222020200112345678"],
    );
    run(
        "uncovered jurisdictions",
        &[
            "香港身份证 A123456(7)",
            "新加坡 NRIC S1234567D",
            "马来西亚身份证 900101-14-5567",
            "台湾通行证 0123456789",
            "护照 PE1234567",
            "军官证 军字第1234567号",
            "泰国 TaxID 3101401176368",
            "Juristic ID No.0115565002108",
        ],
    );
    run(
        "thai tax id shapes",
        &[
            "TaxID 0115565002108",
            "Tax ID: 0115565002108",
            "Juristic ID No.0115565002108",
        ],
    );
    position_drift();
}
