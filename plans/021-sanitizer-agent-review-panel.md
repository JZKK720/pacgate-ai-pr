# Sanitizer Agent + Review Panel

> Priority: P1 · Effort: M · Depends on: 020 (done), 019 (done)
> Status: DONE (2026-09-19)

Implements design section 3.4 (agent + left panel) and the review surface
contract in 3.4/3.5. The dedicated lane entry point.

## What shipped
- `deploy/sanitizer-agent/SOUL.md` + idempotent provisioning script.
- Review panel in the sanitizer agent chat (third resizable panel):
  egress state, chunk states, latest job, blocked note. Read-only.
- Pacgate proxy route (`/api/pacgate/*` -> pacgate-api) with service JWT;
  GET-only so the browser can never write through it.
- Bilingual strings (en-US + zh-CN, parity preserved).
- E2E spec + unit tests for the client.

## Boundaries held
- The panel holds NO vault contents, performs NO redaction, offers NO restore
  (restore is the plan-020 API endpoint, operator-only).
- The agent runs MCP tools; the panel never calls them.

## Release wiring
- compose env: NEXT_PUBLIC_PACGATE_REVIEW_ENABLED, PACGATE_API_URL,
  PACGATE_JWT_TOKEN on deer-flow-frontend.
- Rebuild deer-flow-frontend-pacgate with build-frontend.ps1 (or CI) so the
  overrides land in the published image.

## Implementation notes (2026-09-19)
- The plan's Task 5 thread-metadata access needed a correction caught by
  typecheck: `useThread()` returns the stream handle (no `metadata`), so the
  panel reads the document id through upstream's `useThreadMetadata(threadId)`
  hook (AgentThread.metadata). Commit e3ca366.
- The document id convention holds: the sanitizer agent sets
  `pacgate_document_id` on the LangGraph thread metadata; the panel resolves
  it via `useThreadMetadata` and polls sanitize-status through the proxy.