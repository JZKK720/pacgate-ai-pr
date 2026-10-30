---
name: cn-nda-review
description: Review a confidentiality agreement (NDA / 保密协议) clause by clause from a Chinese-law perspective, flag unbalanced terms, and propose redlines. Use when a client asks whether an NDA is safe to sign, or when one party's template needs marking up.
---

<!-- Pacgate 2026-10-30: this skill deliberately declares NO `allowed-tools`.

     `allowed_tools` is a UNION across every loaded skill, and once ANY skill
     declares it, skills that omit it contribute nothing (verified: two
     un-declaring skills -> None = all tools; one declaring ["bash"] -> {'bash'}).
     So a correct declaration here must list bash, read_file, write_file,
     str_replace, glob, grep, ls, present_files, ask_clarification, skill_manage,
     every openviking_*, every pacgate_pacgate_* AND officecli. Any partial list
     silently amputates the rest of the agent's surface, mid-conversation, with
     no error. Omitting the declaration keeps the surface intact.

     Also verified: a SCALAR `allowed-tools: pacgate` does not fall back to
     allow-all - the loader rejects the skill outright ("must be a list of
     strings") and it never loads at all. -->

# NDA review - Chinese law

Reviewing an NDA is a **form-and-balance** exercise, not a research one. Most
defects are visible on the page; the rest need the firm's own precedent.

## Before you start

- Confirm **which side you act for**. An NDA that is fine for a recipient is
  unacceptable for a discloser, and vice versa. If the user has not said, ask
  with `ask_clarification` - do not assume.
- Identify whether this is **one-way** (unilateral) or **mutual** (双向). Mutual
  NDAs that read like a one-way agreement with a swapped preamble are a common
  template defect.

## Read the document

Use `pacgate_pacgate_get_workspace` to find the document, then
`pacgate_pacgate_read_document`. If the document is binary and comes back as
base64, use `pacgate_pacgate_convert_document` first - it returns Markdown that
is directly readable.

Do **not** use `bash` to read the file. The sandbox cannot write under the
skills path, and `read_document` is the supported path for matter documents.

## The checklist

Work through these in order and report **every** item as present, absent, or
one-sided. Do not silently drop a line you find nothing wrong with - "clause 4
is balanced" is a finding.

1. **Definition of Confidential Information** - is it enumerated (narrow) or
   "all information disclosed in any form" (broad)? Broad definitions are normal
   between sophisticated parties and dangerous for an employee or a supplier.
2. **Exclusions / carve-outs** - the standard five: (a) already public, (b)
   already known to the recipient without duty, (c) independently developed, (d)
   received from a third party without duty, (e) required by law or regulator to
   be disclosed. **A missing (e) is a hard blocker** - the recipient cannot
   comply with a court order without breaching.
3. **Term of confidentiality** - perpetual is acceptable for trade secrets,
   aggressive for ordinary commercial information. Flag anything over 5 years
   for ordinary information.
4. **Residual knowledge** - absent clause means the recipient's staff may reuse
   what they remember. For a discloser (employer, licensor) this is a real leak.
5. **Permitted recipients** - employees, affiliates, professional advisers,
   financing parties. Is onward flow conditioned on written back-to-back
   obligations?
6. **Return / destruction** - obligation, deadline, certification, and whether
   one archival copy may be retained for legal/compliance purposes.
7. **Indemnity and liability** - is it one-way? Is there a cap? An uncapped
   one-way indemnity against the recipient is the single most common trap.
8. **Non-solicit / non-compete hidden in an NDA** - check for clauses that
   restrict hiring or competing. These need separate consideration and often
   separate advice under 劳动合同法 if the counterparty is an individual.
9. **Governing law and dispute forum** - foreign law or foreign arbitration in a
   purely domestic deal should be questioned, not just noted.
10. **Breach remedy** - injunctive relief clauses are standard; punitive
    liquidated damages are not enforceable as drafted in PRC practice and should
    be reframed as actual-loss compensation.

## Verifying authority

When a conclusion depends on a statute - for example the 民法典 provisions on
confidentiality and pre-contractual liability, or the 反不正当竞争法 provisions on
trade secrets - search the firm's corpus first:

```
pacgate_pacgate_kb_search(query="<statute or issue>", matter_id="<matter>")
```

Cite only what it returns. If it returns an `empty_reason`, say so plainly
("the firm corpus has no material on this point") rather than filling the gap
from memory.

**Do not state article numbers you have not seen in a retrieved source.** Article
numbering shifts with amendments, and a wrong article in a client-facing memo is
worse than no citation. Name the statute and the rule; let the lawyer add the
article, or retrieve it first.

Do **not** claim you checked 国家法律法规数据库, 北大法宝, or 元典法务. On this
deployment those connectors are unconfigured, and
`pacgate_pacgate_connector_search` returns an empty array. See "Research reality"
below.

## Output

Deliver a table, then a redline list:

| # | Clause | Position | Risk | Proposed change |
|---|--------|----------|------|-----------------|

Risk levels: **高** (must change before signing), **中** (negotiate), **低**
(acceptable, note for the file).

Then list the specific replacement wording for each 高 and 中 item. Draft in
Chinese for a Chinese-law agreement; keep defined terms consistent with the
original.

## Research reality - read this before promising anything

The external legal connectors are **not available on this deployment**.
`pacgate_pacgate_connector_search` fans out across 元典, 北大法宝, 企查查,
法源开, CourtListener, SEC EDGAR, GLEIF, EUR-Lex and OpenCorporates, but only the
international free ones can answer, and this box has no outbound TLS, so it
returns `[]`. `pacgate_pacgate_list_connectors` shows the live availability
flags - check it rather than assuming.

Therefore:
- Ground conclusions in **the firm's own documents** via `pacgate_pacgate_kb_search`.
- Where the corpus is silent, say so and mark the point **"需律师核验"**.
- Never present recalled statutory text as verified. Never invent a citation.

## Boundaries

- This output is a **draft for lawyer review**, not legal advice to the client.
- Do not sign off, send, or promise a position to the counterparty.
- If the NDA touches employment, equity, or a transaction with its own
  indemnities, flag that it needs the responsible lawyer, not just this review.

## Improving this skill

If you find a defect pattern this checklist does not cover, patch this skill
with `skill_manage` (action `patch`) so the next review catches it. Prefer
patching over rewriting, and confirm with the user before changing a shared
skill.
