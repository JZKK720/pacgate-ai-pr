---
name: Pacgate Operator UI
version: alpha
description: Design language for the Pacgate deer-flow operator workspace (research UI, agent chats, sanitizer review panel). Light theme is canonical; dark values live in the Themes table.
colors:
  background: "oklch(0.9855 0.0098 87.47)"
  foreground: "oklch(0.145 0 0)"
  card: "oklch(1 0.0098 87.47)"
  card-foreground: "oklch(0.145 0 0)"
  primary: "oklch(0 0 0)"
  primary-foreground: "oklch(0.985 0 0)"
  secondary: "oklch(0.9455 0.0098 87.47)"
  secondary-foreground: "oklch(0.205 0 0)"
  muted: "oklch(0.97 0.0098 87.47)"
  muted-foreground: "oklch(0.556 0 0)"
  accent: "oklch(0.94 0.0098 87.47)"
  accent-foreground: "oklch(0.205 0 0)"
  destructive: "oklch(0.577 0.245 27.325)"
  border: "oklch(0.922 0.0098 87.47)"
  input: "oklch(0.88 0.0098 87.47)"
  sidebar: "oklch(0.965 0.0098 87.47)"
  sidebar-foreground: "oklch(0.145 0 0)"
typography:
  sans:
    fontFamily: ui-sans-serif
  title-sm:
    fontFamily: ui-sans-serif
    fontSize: 0.875rem
    lineHeight: 1.25rem
    fontWeight: 500
  body-sm:
    fontFamily: ui-sans-serif
    fontSize: 0.875rem
    lineHeight: 1.25rem
  label-xs:
    fontFamily: ui-sans-serif
    fontSize: 0.75rem
    lineHeight: 1rem
    fontWeight: 500
rounded:
  base: 0.625rem
  sm: 8px
  md: 10px
  lg: 14px
  full: 9999px
spacing:
  card-padding: 24px
  section-gap: 12px
  inline-gap: 8px
components:
  review-panel:
    backgroundColor: "{colors.card}"
    textColor: "{colors.card-foreground}"
    rounded: "{rounded.md}"
    padding: 0px
  review-panel-title:
    textColor: "{colors.card-foreground}"
  review-panel-helper:
    textColor: "{colors.muted-foreground}"
  review-panel-note:
    backgroundColor: "{colors.muted}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.sm}"
  review-panel-note-blocked:
    backgroundColor: "oklch(0.577 0.245 27.325 / 10%)"
    textColor: "oklch(0.985 0 0)"
    rounded: "{rounded.sm}"
  state-badge:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.secondary-foreground}"
    rounded: "{rounded.full}"
  state-badge-blocked:
    backgroundColor: "{colors.destructive}"
    textColor: "{colors.primary-foreground}"
  panel-divider:
    backgroundColor: "{colors.border}"
---

# Pacgate Operator UI — DESIGN.md

## Overview

The Pacgate operator workspace is the deer-flow research UI branded for Pacgate Law: a
sidebar + resizable-panel research workspace where operators run chats, agent workspaces
(the `sanitizer` agent among them), and document review. The audience is legal
professionals in a task flow, not visitors being persuaded — this is an **Operate-mode**
surface. The governing bar is *earned familiarity*: the tool should disappear into the
work, never surprise a category-fluent user.

The palette is a warm-paper neutral system (hue ≈ 87°, very low chroma) with a pure
ink primary. Interaction color is reserved for state — there is no decorative accent
anywhere in the product surface. Typography is a single system sans stack at fixed
rem sizes. All values below are read from `src/styles/globals.css` (the Tailwind v4
`@theme` + shadcn variable layer) and the shared `src/components/ui/*` primitives;
they are normative because every surface imports them.

## Colors

Two neutral layers carry the layout: a warm paper `background` for the app shell and
a brighter `card` for content panels, with a slightly-darker `sidebar` band that
separates navigation from content. `primary` is pure ink and is used almost
exclusively for the highest-emphasis action and the selected state. `destructive`
is the only saturated hue and appears solely on blocked/error states. A `dark`
variant exists (`.dark` class, warm dark paper at hue ≈ 107°); its full values are
in the Themes table below and must keep the same token names.

Agents extending this UI (including the sanitizer review panel) must use the
semantic tokens — `bg-card`, `text-muted-foreground`, `border-border`,
`bg-destructive/10` — never raw hex values. A blocked state must read through
`destructive` plus a tinted container (`bg-destructive/10`), not a solid red fill.

## Typography

One family: the system sans stack (`ui-sans-serif, system-ui, …`) for everything —
titles, labels, body, badges. No display face exists in this product. The scale is
fixed rem (no fluid clamps): `text-sm` (0.875rem) is the workhorse for panel
titles, body, and table content; `text-xs` (0.75rem) is for badge labels and
metadata; section headings inside cards stay at `text-sm font-medium` rather than
jumping to display sizes. Weight steps in use: 400 (body), 500 (titles, badges,
labels), 600 (`font-semibold` for `CardTitle`'s `leading-none font-semibold`
pattern only when a card header must dominate).

Chinese typography is a first-class constraint: strings render in zh-CN by
default for this firm. Full-width punctuation (。) is correct and must not be
"fixed" to ASCII periods. Do not pick fonts or letter-spacing that degrade CJK
rendering; the system stack plus Noto CJK in the container fonts is the contract.

## Layout

The workspace is a horizontal `ResizablePanelGroup`: chat (left), and — in agent
workspaces that mount them — `review` and `artifacts` panels. The sanitizer
workspace's closed layout is `{ chat: 70, review: 30, artifacts: 0 }` and open
layout `{ chat: 50, review: 25, artifacts: 25 }`. Panels hidden by gating use
`pointer-events-none opacity-0` (never conditional unmount — the layout state
must survive toggling). Panel content scrolls internally (`h-full overflow-y-auto`)
with `p-4` gutters.

## Elevation & Depth

Depth is deliberately flat: `Card` carries `border` + `shadow-sm` and nothing
else. There are no layered shadows, no glassmorphism, no decorative gradients.
Overlays (dropdowns, popovers) are the only elements allowed to float above
content, and they must escape overflow containers rather than being clipped.

## Shapes

One radius token governs: `--radius: 0.625rem` (10px), derived in Tailwind steps
(`rounded-sm` −2px, `rounded-md` −0, `rounded-lg` +4px, `rounded-xl` +8px).
Cards and panels use `rounded-xl`; badges are `rounded-full`; inline notes and
tinted callouts use `rounded-md`. Do not invent additional radii.

## Components

The shared vocabulary lives in `src/components/ui/*` (shadcn-style, imported by
every surface). The sanitizer review panel must compose these primitives —
`Card`, `Badge`, `Button`, `Separator` — rather than restyling them:

- **review-panel**: a `Card` (`bg-card`, `rounded-xl`, `border`, internal
  `py-6` rhythm; header/title gap per the primitive). The panel is a review
  surface: it never contains write actions against the spine.
- **state-badge**: `Badge` (`rounded-full`, `text-xs`, `px-2 py-0.5`,
  `font-medium`). State mapping is fixed: `sanitized` → `default` variant,
  `pending` → `secondary`, `blocked` → `destructive`, `never` → `outline`.
  Chunk-state badges are always `variant="outline"` and require a stable key
  (state + index), not the state string alone.
- **helper text**: `text-muted-foreground text-sm` (or `text-xs` for
  supplementary notes). Helper text answers the operator's implicit question
  ("what does this state mean for my document?") — it never restates the
  heading.
- Every state the panel can be in must render explicitly: loading (spinner +
  honest label), no-document (teach the flow: what the operator should ask the
  agent), not-sanitized, status, and blocked-with-note. Empty states explain
  and point to the next action; they are not blank panels.
- Interactive components need hover, focus-visible, and disabled treatments
  from the primitives; do not hand-roll new button shapes.

## Do's and Don'ts

**Do** keep the tool visually quiet so the document state is the loudest
element on screen; use the destructive tint container (`bg-destructive/10`)
with light foreground text for blocked state and say what happens next ("cannot
leave the machine until a human decides"); write
every new string in BOTH `en-US.ts` and `zh-CN.ts` (plus `types.ts`) with
full-width punctuation in Chinese; use hyphens, never em-dashes, in visible
copy; name the real operation in loading and empty states.

**Don't** introduce a second accent color, display font, or custom component
shape into operator surfaces; add decorative motion (spinners mid-content,
entrance choreography) — 150–250 ms state transitions only; render vault
contents, placeholder mappings, or restore affordances in any review surface;
expose internal codes as the primary message of an error; ship an empty state
that doesn't teach the next action; hardcode English strings.

## Themes

The spec (0.4.0) has no theme syntax, so light values sit in the canonical
tokens above. The `.dark` class variants below are documentation; keep values
in sync with `src/styles/globals.css`:

| Token | Dark value |
| --- | --- |
| background | oklch(0.24 0.0036 106.64) |
| foreground | oklch(0.985 0 0) |
| card | oklch(0.238 0.0036 106.64) |
| card-foreground | oklch(0.985 0 0) |
| primary | oklch(1 0 0) |
| primary-foreground | oklch(0.205 0 0) |
| secondary | oklch(0.3 0.0036 106.64) |
| muted | oklch(0.269 0.0036 106.64) |
| muted-foreground | oklch(0.708 0 0) |
| destructive | oklch(0.704 0.191 22.216) |
| border | oklch(1 0 0 / 10%) |
| sidebar | oklch(0.245 0.0036 106.64) |
| sidebar-primary | oklch(0.488 0.243 264.376) |