---
name: "Pacgate Proposal Bilingual Rules"
description: "Use when editing Pacgate proposal markdown, commercial appendix pages, quote summaries, or mirrored English-Chinese business materials. Covers bilingual parity, commercial consistency, and proposal-safe copy rules."
applyTo: ["docs/PACGATE-AI-*.html", "docs/PACGATE-AI-*.md", "docs/index.html", "scope-assets/generated/*.md"]
---

# Pacgate Proposal Bilingual Rules

- Treat these files as synchronized business materials. Changes should preserve scope, pricing logic, delivery framing, and cross-page consistency.
- Keep English and Chinese surfaces aligned in structure, section order, and commercial meaning. Do not update one language block and leave the mirrored block behind.

## Bilingual Structure

- When a page already uses full `.en` and `.zh` wrapper blocks, preserve that pattern instead of mixing line-by-line translation snippets into the same structure.
- Keep headings, tables, bullets, and emphasis patterns mirrored across languages unless the user explicitly wants a divergence.
- Chinese text should read like polished business writing, not literal machine translation.

## Proposal Framing

- Keep the copy grounded in the actual proposed scope, current delivery shape, and explicit constraints.
- Avoid broad claims that imply full product completion when the repo or proposal is presenting a phased pilot, quote, appendix, or clarification layer.
- Maintain a business and deployment focus. Do not drift into education, training, or generic thought-leadership positioning.

## Commercial Consistency

- When pricing, timing, or scope language changes, review the mirrored proposal and quote surfaces for alignment.
- Preserve currency assumptions, editable-quote framing, payment logic, and tax notes consistently where they appear.
- Temporary clarification or Q&A materials must remain clearly separate from committed scope unless the user explicitly converts them into proposal scope.

## Editing Rules

- Keep file diffs surgical. Do not rephrase adjacent proposal sections just to make the prose feel more uniform.
- Maintain stable links between index, build plans, quote summary, and commercial appendix pages.
- Do not weaken legal, commercial, or delivery precision for stylistic reasons.

## Pre-Flight Check

- Confirm EN and ZH content still map section-for-section.
- Confirm numbers, units, currencies, and timeline references match across mirrored surfaces.
- Confirm the copy still reads like a serious client-facing proposal artifact.