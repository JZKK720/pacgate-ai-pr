# Verification Checklist

Use this checklist before closing a clarification-workflow task.

## Markdown Output

- Is the converted question set complete enough for review?
- Are section headings and numbering preserved where available?
- Are extraction uncertainties explicitly flagged instead of guessed away?

## Analysis Report

- Does every question have a category?
- Does every question have a priority?
- Is there a direct answer or corrective direction for each question?
- Are irrelevant or mistaken questions explicitly identified?
- Where research matters, is there a clear note about the supporting source or validation angle?

## Design Mockup Or Workboard Plan

- Is the board clearly temporary and outside production scope?
- Does the architecture support HTML, Kanban-style tracking, and PDF export?
- Is the recommended implementation self-contained before introducing external tooling?
- Is local JSON the default persistence model unless the user asks for more?

## Final Decision Check

- Scope boundary respected: working-in-progress only, not a production integration
- Research scope respected: external research used to validate technical and commercial claims, not as filler
- Recommendations documented: self-contained HTML board and local JSON persistence remain the default starting point