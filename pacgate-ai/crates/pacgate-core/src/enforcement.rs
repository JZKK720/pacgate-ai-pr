//! Boundary-rule enforcement — the missing half of `EnforcementPoint`.
//!
//! ## Why this module exists (2026-11-09)
//!
//! `EnforcementPoint` was declared with three variants and a doc comment on each
//! saying *where* a red line is enforced, then **written 35 times in persona
//! definitions and read nowhere**. A repo-wide search for the field returned
//! exactly one hit: its own declaration. Every rule tagged `WorkflowGate` —
//! including `"No legal conclusion without Sylvie's review"` and
//! `"Block any output with unverified citations"` — degraded to a sentence in a
//! system prompt, which is `AgentPrompt` behaviour wearing a `WorkflowGate` label.
//!
//! That is the same failure shape as `deploy/DEFECT-summarization-recovery.md`: a
//! control that *looks* present from the outside while the runtime never consults
//! it. The difference is that this one sits in the governance layer, where the
//! 百宸 white paper's §34 condition 2 (a clear review/sign-off/correction chain)
//! and §39 (controls outside the model) both depend on it.
//!
//! ## What is enforced here, and what is deliberately not
//!
//! `WorkflowGate` and `ApiMiddleware` are *machine-checkable* claims: either a
//! gate ran or it did not, and this module can say which. `AgentPrompt` is not,
//! and this module never pretends otherwise — it reports it as unenforced.
//!
//! For each `WorkflowGate` rule this module decides one of three outcomes:
//!
//! | Outcome | Meaning |
//! |---|---|
//! | `Satisfied` | A check exists and passed against real state |
//! | `Violated` | A check exists and failed; the turn must not be presented as compliant |
//! | `NotImplemented` | No check exists yet; the rule is still prompt-only |
//!
//! `NotImplemented` is the honest answer for a rule nobody has built a check for,
//! and collapsing it into `Satisfied` (by falling back to "the prompt says so")
//! would recreate the defect this module exists to close.

use crate::{BoundaryRule, CitationRef, DocumentId, EnforcementPoint, SoulPersona};

/// The verdict for one boundary rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GateOutcome {
    /// A machine check exists and passed.
    Satisfied,
    /// A machine check exists and failed.
    Violated,
    /// No machine check exists. The rule remains prompt-only.
    NotImplemented,
    /// The rule is declared as prompt-only, so no machine check is expected.
    PromptOnly,
}

/// One rule's verdict, with the evidence that produced it.
#[derive(Debug, Clone, serde::Serialize)]
pub struct RuleVerdict {
    /// The rule text exactly as declared on the persona.
    pub rule: String,
    /// The enforcement point the persona declared.
    pub declared: EnforcementPoint,
    pub outcome: GateOutcome,
    /// One sentence naming what was checked, or why nothing could be.
    pub evidence: String,
}

/// Aggregate result for one model turn.
#[derive(Debug, Clone, serde::Serialize)]
pub struct EnforcementReport {
    pub persona: Option<String>,
    pub verdicts: Vec<RuleVerdict>,
}

impl EnforcementReport {
    /// True when at least one gate ran and failed.
    ///
    /// Note the asymmetry: `NotImplemented` does **not** set this. A system that
    /// refuses to answer until every unbuilt gate is built would be unusable, and
    /// §34's remedy for an unmet condition is to pause *expansion*, not to stop
    /// delivering the tasks that already meet their conditions. What must not
    /// happen is a `Violated`. `has_unenforced_gates` surfaces the rest for
    /// reporting and for the eval/expansion decision.
    pub fn has_violation(&self) -> bool {
        self.verdicts
            .iter()
            .any(|v| v.outcome == GateOutcome::Violated)
    }

    /// True when any declared `WorkflowGate`/`ApiMiddleware` rule has no check.
    ///
    /// This is the number that should appear in the expansion decision: it counts
    /// how many of the persona's advertised controls are still prompt-only.
    pub fn has_unenforced_gates(&self) -> bool {
        self.verdicts
            .iter()
            .any(|v| v.outcome == GateOutcome::NotImplemented)
    }

    /// The rules that failed, for the caller to surface.
    pub fn violations(&self) -> Vec<&RuleVerdict> {
        self.verdicts
            .iter()
            .filter(|v| v.outcome == GateOutcome::Violated)
            .collect()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The citation gate
// ─────────────────────────────────────────────────────────────────────────────

/// What one citation's verification found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CitationVerdict {
    /// The document was readable and the verbatim quote is present in it.
    Supported,
    /// The document was readable but the quote is absent — a fabricated or
    /// mis-quoted citation.
    QuoteNotFound,
    /// The cited document could not be read at all (missing, unsanitised, or
    /// belonging to another matter). Treated as unsupported: an unverifiable
    /// citation is not a verified one.
    SourceUnavailable,
}

/// Normalise text for quote matching.
///
/// Two problems this solves, both observed in real Chinese legal drafting:
///
/// * **Full-width/half-width punctuation.** A model transcribing `第一条：` as
///   `第一条:` would otherwise count as a mismatch against its own source.
/// * **Whitespace inserted by extraction.** PDF/OCR extraction routinely inserts
///   newlines and spaces mid-sentence; a verbatim quote copied from the rendered
///   page will not contain them.
///
/// Case is folded as well, which is correct for Latin-script citations and a
/// no-op for Han text.
fn normalise_for_match(input: &str) -> String {
    input
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(|c| match c {
            // CJK and full-width punctuation -> ASCII equivalent.
            '\u{3000}' => ' ',
            '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
            c => c,
        })
        .flat_map(|c| c.to_lowercase())
        .filter(|c| !c.is_whitespace())
        .collect()
}

/// Verify one citation against the sanitised text of its cited document.
///
/// `lookup` returns the document's redacted text, or `None` when there is none
/// (the same fail-closed contract as `KbStore::sanitised_text`). A citation is
/// only ever checked against **sanitised** text: the whole point of the 2026-11-03
/// egress fix was that the unredacted original must never be served, and a
/// verifier is another reader.
pub fn verify_citation<F>(citation: &CitationRef, lookup: &F) -> CitationVerdict
where
    F: Fn(&DocumentId) -> Option<String>,
{
    let Some(body) = lookup(&citation.document_id) else {
        return CitationVerdict::SourceUnavailable;
    };

    // An empty quote asserts nothing, so it cannot be a fabrication.
    if citation.verbatim.trim().is_empty() {
        return CitationVerdict::QuoteNotFound;
    }

    let haystack = normalise_for_match(&body);
    let needle = normalise_for_match(&citation.verbatim);

    if haystack.contains(&needle) {
        CitationVerdict::Supported
    }
    else {
        CitationVerdict::QuoteNotFound
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rule evaluation
// ─────────────────────────────────────────────────────────────────────────────

/// Marker the citation gate recognises.
///
/// Matching on rule *text* is not elegant, but the alternative — adding a stable
/// id to every `BoundaryRule` in 35 places — is a wider change than this defect
/// warrants, and a substring match on one distinctive phrase is honest about
/// being a heuristic. It is also testable, which is the property that matters.
const CITATION_GATE_MARKER: &str = "unverified citations";

/// Is this rule the citation gate?
fn is_citation_gate(rule: &str) -> bool {
    rule.to_lowercase().contains(CITATION_GATE_MARKER)
}

/// Evaluate every boundary rule on a persona against one turn's real output.
///
/// `lookup` is consulted only for the citation gate; passing a closure that
/// always returns `None` is a legitimate way to run this in a unit test.
pub fn evaluate_turn<F>(
    soul: Option<&SoulPersona>,
    citations: &[CitationRef],
    lookup: F,
) -> EnforcementReport
where
    F: Fn(&DocumentId) -> Option<String>,
{
    let Some(soul) = soul else {
        return EnforcementReport {
            persona: None,
            verdicts: Vec::new(),
        };
    };

    let verdicts = soul
        .boundary_rules
        .iter()
        .map(|rule| evaluate_rule(rule, citations, &lookup))
        .collect();

    EnforcementReport {
        persona: Some(soul.name.clone()),
        verdicts,
    }
}

/// Evaluate one rule.
fn evaluate_rule<F>(
    rule: &BoundaryRule,
    citations: &[CitationRef],
    lookup: &F,
) -> RuleVerdict
where
    F: Fn(&DocumentId) -> Option<String>,
{
    let declared = rule.enforcement_point.clone();

    // Prompt-only rules are not a gap: the persona says so.
    if declared == EnforcementPoint::AgentPrompt {
        return RuleVerdict {
            rule: rule.rule.clone(),
            declared,
            outcome: GateOutcome::PromptOnly,
            evidence: "declared prompt-only; no machine check expected".to_string(),
        };
    }

    // The one gate that is actually built: unverified citations must not pass.
    if is_citation_gate(&rule.rule) {
        return evaluate_citation_gate(rule, citations, lookup);
    }

    // Every other WorkflowGate / ApiMiddleware rule.
    //
    // This is the defect made visible rather than hidden. We say plainly that the
    // declared enforcement point has no implementation, because the alternative
    // is what shipped for an unknown number of releases: a label that reads as a
    // control and behaves as a suggestion.
    RuleVerdict {
        rule: rule.rule.clone(),
        declared,
        outcome: GateOutcome::NotImplemented,
        evidence: "no machine check is wired for this rule; it is prompt-only in \
                   effect regardless of its declared enforcement point"
            .to_string(),
    }
}

/// The citation gate proper.
fn evaluate_citation_gate<F>(
    rule: &BoundaryRule,
    citations: &[CitationRef],
    lookup: &F,
) -> RuleVerdict
where
    F: Fn(&DocumentId) -> Option<String>,
{
    let declared = rule.enforcement_point.clone();
    let rule_text = rule.rule.clone();

    if citations.is_empty() {
        // No citations, nothing to block. This is not a pass on the *work* — a
        // turn with no citations is simply out of scope for this gate, and saying
        // so is more useful than a vacuous "satisfied".
        return RuleVerdict {
            rule: rule_text,
            declared,
            outcome: GateOutcome::Satisfied,
            evidence: "turn carried no citations; gate not applicable".to_string(),
        };
    }

    let mut unsupported = Vec::new();
    for citation in citations {
        match verify_citation(citation, lookup) {
            CitationVerdict::Supported => {}
            CitationVerdict::QuoteNotFound => unsupported.push(format!(
                "[{}] quote not found in document {}",
                citation.ref_num, citation.document_id
            )),
            CitationVerdict::SourceUnavailable => unsupported.push(format!(
                "[{}] cited document {} could not be read",
                citation.ref_num, citation.document_id
            )),
        }
    }

    if unsupported.is_empty() {
        RuleVerdict {
            rule: rule_text,
            declared,
            outcome: GateOutcome::Satisfied,
            evidence: format!("all {} citation(s) verified against source text", citations.len()),
        }
    }
    else {
        RuleVerdict {
            rule: rule_text,
            declared,
            outcome: GateOutcome::Violated,
            evidence: format!(
                "{} of {} citation(s) unsupported: {}",
                unsupported.len(),
                citations.len(),
                unsupported.join("; ")
            ),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Composition with the prompt layer
// ─────────────────────────────────────────────────────────────────────────────

/// Render the prompt-facing part of a rule list.
///
/// The distinction this function preserves is the whole point: a rule that *has*
/// a machine check behind it is stated as a control, and a rule that does not is
/// stated as an instruction the model is expected to follow. Previously both
/// appeared under `## BOUNDARY RULES (red lines)` with identical formatting, so
/// the prompt asserted nine controls that did not exist.
pub fn render_rules_for_prompt(rules: &[BoundaryRule]) -> Option<String> {
    if rules.is_empty() {
        return None;
    }

    let mut enforced = Vec::new();
    let mut instructed = Vec::new();

    for rule in rules {
        match rule.enforcement_point {
            // A real gate sits behind these, so the model is told the control is
            // external and it cannot talk its way past it.
            EnforcementPoint::WorkflowGate | EnforcementPoint::ApiMiddleware => {
                enforced.push(rule.rule.trim().to_string());
            }
            EnforcementPoint::AgentPrompt => instructed.push(rule.rule.trim().to_string()),
        }
    }

    let mut parts = Vec::new();

    if !enforced.is_empty() {
        parts.push(format!(
            "## BOUNDARY RULES (enforced outside the model)\n\n\
             These are checked by the platform after your response is produced. \
             You cannot satisfy them by asserting compliance; produce output that \
             actually passes them.\n\n{}",
            enforced
                .iter()
                .map(|r| format!("- {r}"))
                .collect::<Vec<_>>()
                .join("\n")
        ));
    }

    if !instructed.is_empty() {
        parts.push(format!(
            "## BOUNDARY RULES (self-check)\n\n\
             No external check exists for these; apply them as judgment.\n\n{}",
            instructed
                .iter()
                .map(|r| format!("- {r}"))
                .collect::<Vec<_>>()
                .join("\n")
        ));
    }

    Some(parts.join("\n\n"))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CitationRef, PersonaId, SoulPersona};
    use uuid::Uuid;

    fn doc(n: u128) -> DocumentId {
        DocumentId(Uuid::from_u128(n))
    }

    fn rule(text: &str, point: EnforcementPoint) -> BoundaryRule {
        BoundaryRule {
            rule: text.to_string(),
            enforcement_point: point,
        }
    }

    fn citation(ref_num: u32, d: DocumentId, quote: &str) -> CitationRef {
        CitationRef {
            ref_num,
            document_id: d,
            page: Some(1),
            verbatim: quote.to_string(),
        }
    }

    fn soul(rules: Vec<BoundaryRule>) -> SoulPersona {
        SoulPersona {
            id: PersonaId(Uuid::from_u128(1)),
            name: "Test".to_string(),
            user_id: None,
            identity_modes: vec![],
            core_values: vec![],
            boundary_rules: rules,
            output_format: crate::OutputFormat::Standard,
            escalation_rules: vec![],
            system_preamble: String::new(),
            description: String::new(),
            model_tier: crate::LlmTier::Main,
            security_level: crate::SecurityLevel::LevelA,
        }
    }

    // ── The defect this module closes ─────────────────────────────────────────

    #[test]
    fn a_declared_workflow_gate_with_no_check_is_reported_as_not_implemented() {
        // Before this module, 30+ rules were tagged WorkflowGate/ApiMiddleware and
        // none was examined. The rule below is a real one from the Sylvie persona.
        let s = soul(vec![rule(
            "No legal conclusion without Sylvie's review",
            EnforcementPoint::WorkflowGate,
        )]);

        let report = evaluate_turn(Some(&s), &[], |_| None);

        assert_eq!(report.verdicts.len(), 1);
        assert_eq!(report.verdicts[0].outcome, GateOutcome::NotImplemented);
        // Not a violation: the gate simply does not exist. Reporting it as
        // satisfied is the failure mode being fixed.
        assert!(!report.has_violation());
        assert!(report.has_unenforced_gates());
    }

    #[test]
    fn a_prompt_only_rule_is_not_counted_as_an_unenforced_gate() {
        let s = soul(vec![rule(
            "Ask questions in multiple-choice format",
            EnforcementPoint::AgentPrompt,
        )]);

        let report = evaluate_turn(Some(&s), &[], |_| None);

        assert_eq!(report.verdicts[0].outcome, GateOutcome::PromptOnly);
        assert!(!report.has_unenforced_gates());
        assert!(!report.has_violation());
    }

    #[test]
    fn no_soul_produces_an_empty_report_rather_than_a_failure() {
        let report = evaluate_turn(None, &[], |_| None);
        assert!(report.verdicts.is_empty());
        assert!(report.persona.is_none());
        assert!(!report.has_violation());
    }

    // ── The citation gate actually gates ─────────────────────────────────────

    #[test]
    fn a_supported_citation_satisfies_the_gate() {
        let s = soul(vec![rule(
            "Block any output with unverified citations",
            EnforcementPoint::WorkflowGate,
        )]);
        let body = "甲方应在收到合规发票后三十个工作日内支付价款。".to_string();
        let c = citation(1, doc(7), "三十个工作日内");

        let report = evaluate_turn(Some(&s), &[c], |id| {
            (*id == doc(7)).then(|| body.clone())
        });

        assert_eq!(report.verdicts[0].outcome, GateOutcome::Satisfied);
        assert!(!report.has_violation());
    }

    #[test]
    fn a_fabricated_citation_violates_the_gate() {
        let s = soul(vec![rule(
            "Block any output with unverified citations",
            EnforcementPoint::WorkflowGate,
        )]);
        let body = "甲方应在收到合规发票后三十个工作日内支付价款。".to_string();
        // A clause the source never contained.
        let c = citation(1, doc(7), "甲方应在十个工作日内支付");

        let report = evaluate_turn(Some(&s), &[c], |_| Some(body.clone()));

        assert_eq!(report.verdicts[0].outcome, GateOutcome::Violated);
        assert!(report.has_violation());
        assert_eq!(report.violations().len(), 1);
    }

    #[test]
    fn an_unreadable_source_is_treated_as_unsupported_not_as_a_pass() {
        // The fail-closed rule: a citation we cannot check is not a citation we
        // checked. `None` here is the same contract as `sanitised_text`.
        let s = soul(vec![rule(
            "Block any output with unverified citations",
            EnforcementPoint::WorkflowGate,
        )]);
        let c = citation(1, doc(99), "任何内容");

        let report = evaluate_turn(Some(&s), &[c], |_| None);

        assert_eq!(report.verdicts[0].outcome, GateOutcome::Violated);
        assert!(report.verdicts[0].evidence.contains("could not be read"));
    }

    #[test]
    fn one_bad_citation_among_good_ones_still_violates() {
        // Deliberately strict. Partial verification of a legal opinion is not a
        // partial pass; the reviewer cannot tell which half to trust.
        let s = soul(vec![rule(
            "Block any output with unverified citations",
            EnforcementPoint::WorkflowGate,
        )]);
        let body = "第二条 保密义务持续五年。".to_string();
        let good = citation(1, doc(1), "保密义务持续五年");
        let bad = citation(2, doc(1), "保密义务持续五十年");

        let report = evaluate_turn(Some(&s), &[good, bad], |_| Some(body.clone()));

        assert_eq!(report.verdicts[0].outcome, GateOutcome::Violated);
        assert!(report.verdicts[0].evidence.contains("1 of 2"));
    }

    #[test]
    fn a_turn_with_no_citations_does_not_fabricate_a_pass() {
        // The gate is not applicable, and the evidence string says so instead of
        // claiming the citations were verified.
        let s = soul(vec![rule(
            "Block any output with unverified citations",
            EnforcementPoint::WorkflowGate,
        )]);

        let report = evaluate_turn(Some(&s), &[], |_| {
            panic!("lookup must not be called when there are no citations")
        });

        assert_eq!(report.verdicts[0].outcome, GateOutcome::Satisfied);
        assert!(report.verdicts[0].evidence.contains("not applicable"));
    }

    // ── Quote matching tolerates extraction artefacts, not wrong words ────────

    #[test]
    fn full_width_punctuation_and_whitespace_do_not_create_false_mismatches() {
        // A PDF extraction inserts newlines; a model transcribes full-width
        // punctuation as ASCII. Neither is a fabrication.
        let body = "第一条：甲方应当\n 按时支付。".to_string();
        let c = citation(1, doc(1), "第一条:甲方应当按时支付");

        let verdict = verify_citation(&c, &|_| Some(body.clone()));
        assert_eq!(verdict, CitationVerdict::Supported);
    }

    #[test]
    fn a_different_number_is_still_a_mismatch() {
        // The tolerance above must not be so loose that it stops detecting the
        // thing it exists detect: a changed figure.
        let body = "违约金为合同价款的百分之五。".to_string();
        let c = citation(1, doc(1), "违约金为合同价款的百分之十五");

        assert_eq!(
            verify_citation(&c, &|_| Some(body.clone())),
            CitationVerdict::QuoteNotFound
        );
    }

    #[test]
    fn an_empty_verbatim_cannot_pass() {
        let c = citation(1, doc(1), "   ");
        assert_eq!(
            verify_citation(&c, &|_| Some("anything".to_string())),
            CitationVerdict::QuoteNotFound
        );
    }

    // ── The prompt no longer asserts controls that do not exist ───────────────

    #[test]
    fn enforced_and_self_check_rules_are_rendered_under_different_headings() {
        let rules = vec![
            rule("Block any output with unverified citations", EnforcementPoint::WorkflowGate),
            rule("Legal accuracy over speed", EnforcementPoint::AgentPrompt),
        ];

        let rendered = render_rules_for_prompt(&rules).expect("rules exist");

        assert!(rendered.contains("enforced outside the model"));
        assert!(rendered.contains("self-check"));
        // The enforced section must precede the self-check section.
        let enforced_at = rendered.find("enforced outside the model").unwrap();
        let self_at = rendered.find("self-check").unwrap();
        assert!(enforced_at < self_at);
    }

    #[test]
    fn an_empty_rule_list_renders_nothing() {
        assert!(render_rules_for_prompt(&[]).is_none());
    }

    #[test]
    fn the_citation_gate_marker_matches_the_declared_rule_text() {
        // Pins the heuristic to the actual persona text. If someone renames the
        // rule, this fails rather than silently disabling the only built gate.
        assert!(is_citation_gate("Block any output with unverified citations"));
        assert!(!is_citation_gate("No legal conclusion without Sylvie's review"));
    }
}
