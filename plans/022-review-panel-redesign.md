# Review Panel Redesign (document identity + job outcome)

> Priority: P2 · Effort: M · Depends on: 021 (done)
> Status: DONE (2026-09-19)

Makes the sanitizer review panel answer the operator's questions - which
document, what was redacted, what is the verdict - instead of showing only
abstract state chips. Plan:
`docs/superpowers/plans/2026-09-19-review-panel-redesign.md`.

## What shipped
- `deploy/frontend-patches/DESIGN.md` - the operator-UI design language
  (lint-clean against @google/design.md, css-tailwind export verified).
- Document-identity client: `fetchDocumentMeta` + `useDocumentMeta` reading
  the spine's `GET /api/documents/:id` through the existing pacgate proxy.
- `pacgate_last_job` thread-metadata contract + tolerant parser
  (`readLastJobFromMetadata`): verdict, redaction/mapping counts, data level,
  human-review flag, reason - counts only, never mapping contents.
- Re-rendered panel per DESIGN.md: document header (name, format, version),
  egress state badge, plain-language job outcome, blocked tint note, and a
  proper error state (resolves the plan-021 parked item).
- SOUL rule 11: the sanitizer agent records every job outcome into thread
  metadata so the panel can show it.
- E2E: 3/3 passed against the built image - EN title, ZH localization
  (`脱敏审查`), document identity + job outcome from thread metadata.

## Boundaries held
- Panel stays read-only: no vault contents, no redaction, no restore.
- Thread metadata carries counts + verdict + reason only; the mapping column
  never leaves pacgate-api.
- Proxy unchanged (GET-only); no new spine endpoints.

## Release wiring
- Rebuild `deer-flow-frontend-pacgate` (build-frontend.ps1 or CI) so the
  overrides land in the published image; compose env unchanged from 021.
