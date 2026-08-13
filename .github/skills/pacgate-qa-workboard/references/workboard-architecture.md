# Workboard Architecture Notes

This board is temporary working infrastructure for proposal clarification rounds.

## Default Technical Recommendation

- stack: self-contained static HTML, CSS, and JavaScript
- persistence: local JSON file
- exports: HTML in-browser plus PDF-friendly rendering path

Do not start with a hosted SaaS board, database, or public integration unless the user explicitly asks for that complexity.

## Recommended Lanes

- `Inbox` - raw captured questions not yet triaged
- `Triaged` - classified and prioritized questions
- `Needs Research` - questions waiting on supporting evidence or market validation
- `Draft Response` - answer direction exists, wording still being refined
- `Ready To Send` - approved response content
- `Deferred / Out Of Scope` - not part of current proposal commitment

## Recommended Card Fields

- question id
- category
- priority
- owner
- status
- source file or section
- direct answer summary
- client-facing response draft
- evidence or research note
- export tag

## Output Modes

### HTML Mode

- primary working view
- board lanes, filters, and card details
- easy to revise between client rounds

### PDF Mode

- summary snapshot for formal sharing
- optimized for stable typography and print layout
- should prefer grouped summaries over trying to render a fully interactive board

## Scope Warning

The board is not part of the public proposal site, landing page, or onboarding app.
It should be clearly labeled as temporary or internal/client working material.