---
name: pacgate-redesign
description: 'Audit and upgrade existing Pacgate pages without broad rewrites. Use for redesigning proposal pages, docs HTML, bilingual business materials, or temporary workboards while preserving structure, links, and commercial meaning.'
argument-hint: 'Describe the existing page or file, whether the redesign should preserve or overhaul the current visual language, and what must not change.'
user-invocable: true
---

# Pacgate Redesign

Use this skill when the task is to improve an existing Pacgate page or document surface rather than create a brand-new one.

## Core Principle

Audit first. Preserve what carries business value. Improve what is weak. Do not turn a focused redesign into a framework rewrite or a different product story.

## Modes

Pick one mode before editing:

- `Preserve` - keep the existing page language and structure, improve hierarchy and polish
- `Overhaul` - keep the content purpose, but substantially recompose the page
- `Workbench` - build or refine a temporary board-like surface for ongoing internal or client-facing clarification work

If the correct mode is unclear and the choice would materially change the work, ask one question.

## Audit Checklist

Before changing the page, document the current state in these categories:

### Structure

- page purpose
- target audience
- language toggle or bilingual structure
- section order and major navigation paths
- internal links and proposal cross-links that must stay stable

### Design

- current palette and accent logic
- type scale and readability issues
- repeated layout families or generic card patterns
- contrast, spacing, rhythm, and scanability issues
- motion or JavaScript behavior that should be preserved, simplified, or removed

### Business Content

- scope statements that must remain precise
- commercial details that must not drift
- claims that are too vague, too strong, or too generic
- temporary versus committed surfaces

## What Must Not Change Silently

- public file names, routes, or stable links
- bilingual wrapper structure on mirrored pages
- commercial meaning, payment logic, or proposal scope intent
- language toggle behavior
- the separation between temporary Q&A materials and the public proposal entry flow

## Fix Priority

Apply changes in this order unless the task says otherwise:

1. Clarify the page purpose and section hierarchy.
2. Fix typography, spacing, and scanability.
3. Remove generic AI patterns and visual clutter.
4. Tighten copy so it reads like a serious business artifact.
5. Improve visual grouping, comparison blocks, and call-to-action clarity.
6. Add or refine motion only if it has a real communicative role.

## Hard Rules

- Work with the existing stack first. For docs pages, that means static HTML, CSS, and light JavaScript.
- Do not migrate to a new framework as part of a redesign unless the user explicitly asks for that migration.
- Keep diffs reviewable and local.
- Do not rewrite proposal content just to make it sound more "designed".
- Do not introduce decorative labels, fake status metadata, or filler stats.

## Procedure

1. Determine redesign mode.
2. Audit the current page under the checklist above.
3. Separate "preserve", "retire", and "upgrade" elements.
4. Make the smallest high-leverage layout and copy changes first.
5. Validate the touched slice immediately.
6. Re-check links, bilingual parity, and business meaning before finishing.

## Red Flags

Stop and reassess if any of these appear:

- the redesign starts changing the product story instead of the page quality
- a temporary workboard begins to look like committed public scope
- EN and ZH stop matching after layout edits
- the page becomes more stylish but less readable or less export-friendly
- the redesign requires many unrelated file changes to feel complete

## Done Criteria

- The page reads more clearly and looks more intentional.
- The redesign stays inside the current stack and business framing.
- Stable links, toggles, and mirrored language blocks still work.
- The result looks like Pacgate material, not a generic AI-generated redesign.