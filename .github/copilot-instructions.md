# Pacgate Repo Guidelines

Pacgate AI is currently a proposal-heavy repository with static presentation pages, supporting scripts, and a Rust workspace. Work from the nearest concrete file, symbol, or behavior instead of mapping the whole repo first.

## Execution Baseline

- Start with one local hypothesis and one cheap check before the first edit on non-trivial tasks.
- Make the smallest reviewable change that solves the request. Do not add abstractions, frameworks, or config layers unless the task requires them.
- Validate the touched slice immediately after the first substantive edit. Prefer focused checks over broad repo-wide commands.
- Keep unrelated cleanup out of the diff. If you notice a separate issue, mention it instead of folding it into the same patch.

## Current Surface Priorities

- Treat `docs/` as the primary presentation surface. Default to static HTML, CSS, and light JavaScript for those pages.
- Treat proposal, quote, appendix, and clarification artifacts as business materials, not generic startup marketing pages.
- Keep temporary Q&A workboards, client clarification forms, and other working materials separate from the public landing or onboarding flow unless the user explicitly asks to integrate them.

## Proposal And Copy Rules

- Keep business copy grounded in real Pacgate surfaces, delivery scope, and commercial logic.
- Prefer procurement, partner, OEM, investor, and client-deployment language over education or training positioning.
- Avoid generic SaaS hype, invented product claims, placeholder metrics, and decorative labels that weaken credibility.
- Use hyphenated punctuation instead of em-dashes in visible copy unless the user explicitly asks otherwise.

## Bilingual And Presentation Rules

- Preserve English and Chinese parity on mirrored proposal surfaces.
- Maintain the established full-block bilingual structure when a page already uses separate `.en` and `.zh` wrappers.
- Protect Chinese typography, spacing, and line-break quality. Do not make font choices or layout changes that degrade Chinese rendering.
- Keep long-form proposal pages readable on desktop, mobile, and PDF export paths.

## Technology Expectations

- For docs work, do not assume React, Next.js, Tailwind, or build tooling. Stay within the existing static stack unless the task says otherwise.
- For Rust work, keep changes scoped to the owning crate when possible and validate the touched crate or module instead of the entire workspace first.
- When adapting outside guidance or reusable skills, translate it into Pacgate-specific rules instead of copying generic upstream conventions verbatim.