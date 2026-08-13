---
name: pacgate-frontend-design
description: 'Design and refine Pacgate proposal pages, docs HTML surfaces, temporary clarification workboards, and future UI concepts. Use for frontend design direction, visual hierarchy, anti-generic layout rules, bilingual presentation, and trust-first page refinement.'
argument-hint: 'Describe the target page, audience, and whether this is a static docs page, proposal surface, temporary Q&A board, or future product UI.'
user-invocable: true
---

# Pacgate Frontend Design

Use this skill when the task is about how a Pacgate page should look, read, or behave - especially for proposal pages, static docs surfaces, temporary Q&A workboards, and future UI concepts.

## When To Use

- Redesigning or refining `docs/*.html` pages
- Improving visual hierarchy, typography, spacing, or CTA structure
- Creating a temporary clarification board, Q&A workbench, or export-friendly HTML surface
- Planning a future product UI while keeping the repo's current business tone

## Step 1: Read The Surface Before Designing

State a one-line design read before making changes:

`Reading this as: <surface> for <audience>, with a <tone> language, leaning toward <static-docs / proposal / app-ui> behavior.`

Examples:

- `Reading this as: proposal summary page for procurement stakeholders, with a trust-first business language, leaning toward static-docs behavior.`
- `Reading this as: temporary Q&A workboard for client clarification rounds, with a working-session language, leaning toward static-docs behavior.`
- `Reading this as: future product shell for legal operations users, with an operational B2B language, leaning toward app-ui behavior.`

If the task could reasonably go in two directions, ask exactly one clarifying question. Otherwise, declare the read and proceed.

## Step 2: Pick The Correct Surface Mode

### A. Static Docs Mode

Use this for `docs/*.html` and small docs-side scripts.

- Default to vanilla HTML, CSS, and lightweight JavaScript.
- Optimize for readability, trust, and export-safe structure.
- Prefer existing design tokens, page shells, and language toggles over greenfield rewrites.

### B. Proposal Workboard Mode

Use this for temporary client clarification boards, Q&A trackers, or internal-facing HTML/PDF artifacts.

- Keep the surface explicitly temporary and separate from the public landing or onboarding flow.
- Favor structured boards, status markers, and evidence-backed notes over polished marketing presentation.
- Design for updateability and exportability, not just visual flair.

### C. Future Product UI Mode

Use this only when the user is explicitly planning future app surfaces.

- Keep the design grounded in legal operations and enterprise use cases.
- Do not let speculative app patterns leak back into the current static proposal pages.

## Step 3: Set Pacgate Design Dials

Use these dials explicitly in your reasoning when the task is more than a tiny edit.

- `DESIGN_VARIANCE` - layout experimentation from 1 to 10
- `MOTION_INTENSITY` - animation depth from 1 to 10
- `VISUAL_DENSITY` - information density from 1 to 10

Default starting points:

- Proposal page: `5 / 2 / 6`
- Quote or appendix page: `4 / 1 / 7`
- Temporary Q&A workboard: `4 / 1 / 8`
- Future marketing-style landing page: `6 / 3 / 5`
- Future product shell: `5 / 2 / 7`

If the task calls for heavier motion or stronger visual experimentation, justify the dial change explicitly.

## Hard Rules

- Audience decides the design. Pacgate's audience is usually procurement, investors, partners, client sponsors, legal operations, or deployment stakeholders.
- Trust-first beats trend-first. Do not chase visual novelty that weakens credibility.
- One accent family per page. No random section-level palette swaps.
- One theme family per page. Do not alternate unrelated dark and light sections without a clear reason.
- Preserve Chinese readability and bilingual parity where applicable.
- Use hyphens, not em-dashes, in visible copy unless the user asks otherwise.

## Pacgate Anti-Default Rules

These patterns are banned as defaults unless the user explicitly asks for them:

- purple glow AI gradients
- centered hero plus three identical feature cards
- fake dashboard screenshots made from decorative `div` rectangles
- decorative section numbering, badge spam, or scroll cues
- fake metrics, invented benchmark numbers, or empty comparison tiles
- generic startup copy such as "next-gen", "seamless", "revolutionize", or similar filler
- overbuilt motion with no communicative purpose

## Layout Guidance

- For proposal pages, keep the page scannable in long-form reading. Favor section rhythm, hierarchy, and comparison clarity over cinematic hero behavior.
- For board-like Q&A pages, use lanes, grouped cards, or evidence tables with strong status logic.
- Avoid repeated section families across the same page when the page is presentation-heavy.
- If you use cards, make sure they communicate real grouping. Do not card every section by default.
- Keep primary actions short, unambiguous, and visually legible.

## Asset Guidance

- Prefer real diagrams, actual page visuals, or existing repo assets.
- For proposal pages, diagrams and structured visuals are usually stronger than decorative photography.
- If no suitable visual exists, prefer a clean structural layout over a fake screenshot or decorative illustration.

## Copy Guidance

- Every visible string should sound like a serious business artifact.
- Avoid cute micro-copy, poetic labels, fake status strips, or pretend version metadata.
- Keep claims specific to the proposal, workflow, or page purpose.

## Procedure

1. Identify the page type and audience.
2. Decide whether the task belongs to static docs mode, proposal workboard mode, or future product UI mode.
3. Declare the design read and, for non-trivial tasks, the three dial values.
4. Audit what must be preserved before changing layout or tone.
5. Make targeted changes that fit the current stack.
6. Run the pre-flight check below before finishing.

## Pre-Flight Check

- Does the page still match the correct surface mode?
- If this is a docs page, is it still static HTML/CSS/JS without unnecessary framework assumptions?
- If this is bilingual, do EN and ZH still match structurally and visually?
- Is the palette coherent and restrained?
- Is the hierarchy clear without decorative clutter?
- Are the CTAs short, legible, and non-duplicative?
- Does the page avoid the banned generic AI patterns above?
- If this is a temporary Q&A surface, is it still clearly separate from committed public product surfaces?