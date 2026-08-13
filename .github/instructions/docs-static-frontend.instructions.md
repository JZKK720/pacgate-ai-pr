---
name: "Pacgate Static Docs Frontend"
description: "Use when editing Pacgate static docs pages, proposal landing pages, or docs-side JavaScript. Covers trust-first visual direction, static HTML/CSS/JS constraints, anti-generic frontend rules, and PDF-friendly presentation choices."
applyTo: ["docs/**/*.html", "docs/assets/**/*.js"]
---

# Pacgate Static Docs Frontend

- These pages are proposal and business presentation surfaces first. Design for clarity, trust, and scanability before spectacle.
- Stay in the current delivery model: static HTML, CSS, and lightweight local JavaScript. Do not introduce framework or package-manager assumptions unless explicitly requested.
- Read the existing page structure before changing it. Preserve working anchors, navigation, language toggles, and linked proposal flows.

## Visual Direction

- Keep the interface intentional and refined, but not trend-chasing.
- Avoid generic AI defaults: purple glow gradients, centered hero plus three equal cards, badge spam, section numbering, decorative scroll cues, fake dashboards, fake screenshots, and filler statistics.
- Use one accent family per page and keep the palette coherent across sections.
- Match the trust-first Pacgate tone: restrained motion, strong hierarchy, measured contrast, and business-grade polish.

## Typography And Layout

- Preserve clean English and Chinese rendering. Prefer the existing font stacks unless the task explicitly calls for a type refresh.
- Keep headings short and readable. Long-form pages should favor structured sections over oversized marketing hero patterns.
- Reuse consistent container widths, spacing scales, and border-radius logic within a page.
- Keep layouts legible in browser view, narrow mobile widths, and PDF export or print contexts.

## JavaScript Rules

- Default to vanilla JavaScript for docs-side behavior.
- Keep scripts small and page-local. Avoid introducing state-heavy patterns for simple interactions.
- If motion is added, it must be optional, motivated, and safe under reduced-motion preferences.
- Do not attach scroll listeners or heavy animation loops unless the task requires them and there is no simpler alternative.

## Copy And Asset Rules

- Keep copy concrete and commercially credible. Remove vague slogans, fake precision, and filler labels.
- Prefer real diagrams, existing visuals, or clearly marked placeholders over hand-built fake product previews.
- When a page supports a temporary Q&A or clarification workflow, keep it visibly separate from the public proposal entry surface unless the user asks to merge them.

## Pre-Flight Check

- Confirm the page still works as static HTML with local assets only.
- Confirm CTAs, links, and language toggles still resolve correctly.
- Confirm mobile layout and long-form readability still hold.
- Confirm the page looks like a Pacgate business artifact, not a generic AI landing page.