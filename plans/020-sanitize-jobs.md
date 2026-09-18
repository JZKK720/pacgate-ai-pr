# Sanitize Jobs, Vault, Gates, MCP Tools

> Priority: P1 · Effort: M · Depends on: 019 (done), 017 (done)
> Status: DONE (2026-09-19)

Implements design `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md`
sections 3.3, 5, 5.1, 6, plus locked decisions 2/3.

## What shipped

- Migration 007: `sanitizer_jobs` (the vault; JSONB mapping) + `redaction_ledger_rows` (evidence).
- `POST /api/documents/:id/sanitize` - cache-first job; promotes pending to sanitized / blocked per document.
- `POST /api/documents/:id/restore` - admin/partner only, job + matter scoped, audit-logged.
- `GET /api/documents/:id/sanitize-status` - review-panel feed (document state + chunk states + latest job).
- Download gate: non-sanitized documents refuse download (409 Conflict).
- MCP: `pacgate_sanitize_document`, `pacgate_verify_sanitized`, `pacgate_sanitize_text`. No `pacgate_restore`.
- `Mapping::serialize`/`deserialize` in pacgate-redact (round-trip tested).
- E2E: `scripts/test-sanitizer-e2e.ps1` (upload, extract, sanitize, status, download gate, restore refusal + admin restore, ledger/audit rows).

## Commits

- `ee9780a` feat(db): sanitizer_jobs + redaction_ledger_rows (migration 007)
- `97a4350` feat(api): sanitize job service persisting vault, ledger and audit rows; serialize the mapping
- `9d42312` chore: Cargo.lock
- `00eecb7` feat(api): sanitize/restore/sanitize-status endpoints
- `1d24fef` feat(api): download gate + OpenViking lane limitation note
- `a6e8286` feat(mcp): sanitize/verify tools

## Not in this plan (deliberate)

- OpenViking write gate (accepted limitation, recorded in compose comments).
- Combination-risk detector + re-identification red-team suite (v2).
- Pixel redaction (v2, uses plan-019 spans).
- deer-flow sanitizer agent + review panel (plan 021).

## Release wiring (for the next release, not yet applied)

- `compose.prod.yaml` needs `OCR_SERVICE_URL: http://ocr-service:8100` and
  `PACGATE_NER_MODEL_DIR: /models/bert4ner-base-chinese` once ocr-service joins
  the master build and the weights manifest ships via install.ps1.
- New GHCR image required: `ocr-service` (PaddleOCR, ~2.7GB) - see plan 016
  build workflow for the image list to extend.