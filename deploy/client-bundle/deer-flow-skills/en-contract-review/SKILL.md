---
name: en-contract-review
description: Review a commercial contract from a specified party's position under common law (England & Wales, US, Hong Kong, Singapore), run the firm's review workflow when one matches, and produce a clause-by-clause risk table with redlines. Use when a client asks whether an English-language contract is safe to sign, or when a counterparty template needs marking up.
---

<!-- Pacgate 2026-11-01: no `allowed-tools` on purpose. `allowed_tools` is a UNION
     across every loaded skill, so once ANY skill declares it, skills that omit it
     contribute nothing. A partial list silently amputates the agent's surface.
     See cn-nda-review for the measured detail and the scalar-rejection case. -->

# Commercial contract review - common law

This is the English/common-law counterpart to `cn-contract-review`. Use it when the
governing law is a common-law jurisdiction, or when the contract is in English and
nobody has said it is a PRC-law deal.

**If the contract is governed by PRC law, use `cn-contract-review` instead.** The
checklists differ on substance - penalty enforcement, implied terms, good faith,
and termination remedies are not the same questions.

Two paths, and choosing correctly is the whole skill:

- **A workflow template already covers this contract type.** Run it. The firm's
  templates encode the review dimensions its lawyers actually use, and a generic
  review is worse than a template run.
- **No template matches.** Do the manual review below.

Never do both for the same document. A template run followed by a manual pass
produces two overlapping risk tables and the user cannot tell which to trust.

## Step 1 - establish position and scope

Ask, via `ask_clarification`, if not already clear:
- **Which side are we?** buyer/seller, licensor/licensee, lessor/lessee,
  lender/borrower, investor/company/founder, contractor/customer. Every risk call
  depends on this. Never default to "neutral review" - that produces a checklist
  with no positions, which is useless.
- **What kind of contract?** (sale of goods, services, SaaS, distribution,
  agency, licence, loan, share purchase, joint venture, construction, employment.)
- **Which governing law and forum?** If the answer is a PRC-law jurisdiction, stop
  and switch to `cn-contract-review`.

## Step 2 - read the document

Use `pacgate_pacgate_get_workspace` then `pacgate_pacgate_read_document`. Convert
binary documents with `pacgate_pacgate_convert_document` first.

Read the **entire** document, including schedules, annexes, and any document
incorporated by reference. A limitation of liability in the body that is
overridden by a schedule is a real trap.

## Step 3 - the review dimensions

Report every item as present, absent, or one-sided.

**Liability and risk allocation**
1. **Limitation of liability** - is there a cap? Is it a fixed sum, a multiple of
   fees paid, or the contract value? Does it bear any relation to the deal? Are
   indirect and consequential losses excluded, and is that exclusion mutual?
2. **Carve-outs from the cap** - typically fraud, death or personal injury,
   IP infringement, breach of confidentiality. Are the carve-outs mutual or
   one-way? An unlimited indemnity for one party with a capped liability for the
   other is the most common asymmetry in commercial contracts.
3. **Indemnities** - what triggers them, are they subject to the cap, and do they
   require notice and control of the defence?
4. **Liquidated damages / penalties** - check enforceability by jurisdiction. Under
   English law, a genuine pre-estimate is enforceable and a penalty is not
   (Cavendish Square v Makdessi); US states split.
5. **Insurance** - is cover required, in what amount, and does it match the
   liability the contract imposes?

**Performance and payment**
6. **Scope and specifications** - defined objectively, or "as agreed from time to
   time" (a gap)?
7. **Payment terms** - period, method, disputed-invoice mechanism, set-off rights,
   late-payment interest. Check whether statutory default interest applies and
   whether the contract displaces it.
8. **Delivery, acceptance, and risk** - when does risk pass? Are Incoterms used
   correctly and matched to the transport mode?
9. **Change control** - who can request a change, who prices it, and what happens
   if the parties cannot agree?

**Duration and exit**
10. **Term, renewal, and notice** - auto-renewal with a long notice window is a
    common client complaint. Check the notice mechanics (form, recipient, deemed
    receipt).
11. **Termination for convenience and for cause** - are the cure periods and
    notice requirements workable? Is there an exit fee?
12. **Consequences of termination** - accrued rights, survival, return of
    materials, transition assistance.

**Risk that lawyers are often asked to assume away**
13. **Data protection and confidentiality** - controller/processor roles, cross-
    border transfer, security obligations, breach notification timelines.
14. **IP ownership** - does the customer own the deliverables but the supplier
    retain background IP and a licence-back? Is the licence broad enough for the
    stated purpose?
15. **Warranties and disclaimers** - what is warranted, for how long, and does a
    disclaimer of implied terms actually work in this jurisdiction?
16. **Force majeure** - defined events or a general standard? Does it cover supply
    chain failure, and what is the termination right after prolonged force majeure?
17. **Anti-bribery, sanctions, and export control** - required clauses, and are the
    termination rights for breach enforceable?
18. **Assignment and change of control** - consent required? A change-of-control
    right matters if the counterparty is a competitor.
19. **Governing law and dispute resolution** - litigation or arbitration, seat,
    institution, language, number of arbitrators, and whether the choice is valid
    for the parties involved.
20. **Entire agreement and variation** - does the entire-agreement clause exclude
    pre-contractual representations? Are variations required to be in writing and
    signed?

## Step 4 - verify authority

For any conclusion resting on statute or case law, search the firm's corpus first:

```
pacgate_pacgate_kb_search(query="<issue>", matter_id="<matter>")
```

Cite only what it returns. If it returns an `empty_reason`, say so plainly rather
than filling the gap from memory. **Do not invent section numbers or case names.**

## Output

A clause-by-clause table, then a redline list:

| # | Clause | Position | Risk | Issue | Proposed change |
|---|--------|----------|------|-------|-----------------|

Risk levels: **High** (must change before signing), **Medium** (negotiate),
**Low** (acceptable, note for the file).

For every High and Medium item, give the specific replacement wording. Keep
defined terms consistent with the original and mark any defined term you introduce.

## Research reality - read this before promising anything

`pacgate_pacgate_list_connectors` reports live availability. On a deployment with
no outbound access, external connectors return `[]` and only the firm's own corpus
answers. Ground conclusions in `pacgate_pacgate_kb_search`; where the corpus is
silent, mark the point **"requires lawyer verification"**.

## Boundaries

- This output is a **draft for lawyer review**, not legal advice to the client.
- Do not sign off, send, or promise a position to the counterparty.
- Flag anything employment-related, tax-related, or requiring regulatory analysis
  as needing the responsible specialist, not just this review.

## Improving this skill

If you find a defect pattern this checklist does not cover, patch this skill with
`skill_manage` (action `patch`). Prefer patching over rewriting, and confirm with
the user before changing a shared skill.
