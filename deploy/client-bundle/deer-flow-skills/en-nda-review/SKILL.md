---
name: en-nda-review
description: Review a confidentiality agreement (NDA) clause by clause under common-law principles, flag unbalanced terms, and propose redlines. Use for English-law or US-style NDAs, mutual or one-way, when a client asks whether an NDA is safe to sign or a counterparty template needs marking up.
---

<!-- Pacgate 2026-11-01: this skill deliberately declares NO `allowed-tools`.
     `allowed_tools` is a UNION across every loaded skill, and once ANY skill
     declares it, skills that omit it contribute nothing. A partial list
     silently amputates the rest of the agent's surface, mid-conversation, with
     no error. Omitting the declaration keeps the surface intact.
     See cn-nda-review for the measured detail and the scalar-rejection case. -->

# NDA review - common law

This is the English/common-law counterpart to `cn-nda-review`. Use it when the
governing law is a common-law jurisdiction (England & Wales, US states, Hong
Kong, Singapore, Australia, Canada), or when the document is in English and
neither party has said it is a PRC-law deal.

**If the agreement is governed by PRC law, use `cn-nda-review` instead.** The two
differ on points of substance, not just language: penalty enforcement,
non-compete consideration, and the treatment of equitable relief all diverge.

Reviewing an NDA is a **form-and-balance** exercise, not a research one. Most
defects are visible on the page.

## Before you start

- Confirm **which side you act for**. An NDA that is fine for a recipient is
  unacceptable for a discloser, and vice versa. If unclear, ask with
  `ask_clarification` - do not assume.
- Identify **one-way** (unilateral) or **mutual**. A mutual NDA that reads like a
  one-way agreement with a swapped preamble is a common template defect, and the
  obligations must be symmetric in substance, not merely mirrored.
- Confirm the **governing law and forum**. This decides which of the points below
  actually bites.

## Read the document

Use `pacgate_pacgate_get_workspace` to find the document, then
`pacgate_pacgate_read_document`. If it returns base64, use
`pacgate_pacgate_convert_document` first - it returns readable Markdown.

Do **not** use `bash` to read the file; `read_document` is the supported path.

## The checklist

Report **every** item as present, absent, or one-sided. Do not silently drop a
clause you find nothing wrong with - "clause 4 is balanced" is a finding.

1. **Definition of Confidential Information** - enumerated (narrow) versus "all
   information disclosed in any form" (broad). Broad is normal between
   sophisticated parties and dangerous for an employee or supplier.

2. **Exclusions / carve-outs** - the standard five: (a) already public, (b)
   already known without duty, (c) independently developed, (d) received from a
   third party without duty, (e) required by law, regulation, or court order to be
   disclosed. **A missing (e) is a hard blocker**: the recipient cannot comply with
   a subpoena without breaching. Also check whether (e) carries a notice duty, and
   whether it permits disclosure *without* prior notice where giving notice is
   legally prohibited - a notice duty with no such carve-out is unworkable in a
   regulatory investigation.

3. **Term of confidentiality** - perpetual suits trade secrets; more than 5 years
   is aggressive for ordinary commercial information. Check whether the term runs
   from disclosure or from termination, and whether each item has its own clock.

4. **Residual knowledge / residual information** - an express residual clause
   permits reuse of what staff retain unaided. Common and defensible for a
   recipient, a real leak for a discloser. In some US states residual clauses in
   an employment context attract specific scrutiny.

5. **Permitted recipients** - employees, affiliates, professional advisers,
   financing parties, auditors. Is onward flow conditioned on written back-to-back
   obligations? Are **representatives** defined, and does the discloser remain
   liable for their breaches?

6. **Return / destruction** - obligation, deadline, certification, and whether one
   archival copy may be retained for legal or compliance purposes. Check whether
   the obligation extends to backups and IT systems, where literal compliance is
   often impossible; absent carve-outs, that invites technical breach.

7. **Indemnity and liability** - one-way or mutual? Is there a cap? An uncapped
   one-way indemnity against the recipient is the single most common trap. Check
   whether indirect or consequential loss is recoverable, and whether the cap bears
   any relation to the deal value.

8. **Injunctive relief and equitable remedies** - standard and usually acceptable,
   but check whether it is expressed as the *sole* remedy or as being "without
   prejudice to any other remedy". Also check for agreed **liquidated damages or
   penalty** clauses: under English law a genuine pre-estimate of loss is
   enforceable while a penalty is not (Cavendish Square v Makdessi), and US states
   split between enforcing and voiding them.

9. **Non-solicit / non-compete hidden in an NDA** - the most commonly buried
   clauses. Under English law a post-termination restrictive covenant is void
   unless reasonable and protecting a legitimate interest; several US states
   restrict or ban employee non-competes outright, and consideration requirements
   differ. Flag any such clause as needing separate advice - it does not belong in
   an NDA checklist.

10. **Governing law, jurisdiction, and arbitration** - foreign law or foreign
    arbitration in a purely domestic deal should be questioned, not just noted.
    Check the arbitration seat, the institution, and whether the language of the
    arbitration matches the language of the contract.

11. **Assignment and change of control** - can either party assign the NDA,
    including by change of control, without consent? A recipient acquired by a
    competitor is a disclosure risk the NDA may not address.

12. **Term, termination, and survival** - which obligations survive, and for how
    long? Check that survival periods in the body match any schedule.

## Verifying authority

When a conclusion depends on a statute or a leading case, search the firm's corpus
first:

```
pacgate_pacgate_kb_search(query="<statute or issue>", matter_id="<matter>")
```

Cite only what it returns. If it returns an `empty_reason`, say so plainly ("the
firm corpus has no material on this point") rather than filling the gap from
memory.

**Do not invent citations or article numbers.** A wrong case name or section
number in a client-facing memo is worse than no citation. Name the rule; let the
lawyer add the authority, or retrieve it first.

Do **not** claim you checked a public database you did not query.

## Output

Deliver a table, then a redline list:

| # | Clause | Position | Risk | Proposed change |
|---|--------|----------|------|-----------------|

Risk levels: **High** (must change before signing), **Medium** (negotiate),
**Low** (acceptable, note for the file).

Then give the specific replacement wording for each High and Medium item. Draft in
English for an English-law agreement; keep defined terms consistent with the
original.

## Research reality - read this before promising anything

The external legal connectors may be **unavailable on this deployment**.
`pacgate_pacgate_list_connectors` shows live availability flags - check it rather
than assuming. Where the deployment has no outbound access, external search
returns `[]` and only the firm's own corpus can answer.

Therefore:
- Ground conclusions in **the firm's own documents** via `pacgate_pacgate_kb_search`.
- Where the corpus is silent, say so and mark the point **"requires lawyer
  verification"**.
- Never present recalled statutory text or case law as verified. Never invent a
  citation.

## Boundaries

- This output is a **draft for lawyer review**, not legal advice to the client.
- Do not sign off, send, or promise a position to the counterparty.
- If the NDA touches employment, equity, competition, or a transaction with its own
  indemnities, flag that it needs the responsible lawyer, not just this review.

## Improving this skill

If you find a defect pattern this checklist does not cover, patch this skill with
`skill_manage` (action `patch`) so the next review catches it. Prefer patching over
rewriting, and confirm with the user before changing a shared skill.
