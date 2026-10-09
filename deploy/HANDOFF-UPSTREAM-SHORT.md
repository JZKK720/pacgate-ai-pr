# Upstream handoff — port 2 fixes, release 0.1.21

> Repo: `JZKK720/pacgate-ai-pr`. Detail + evidence: `deploy/HANDOFF-UPSTREAM-RELEASE-0.1.21.md`
> and `deploy/BENCHMARK-REPORT-2026-09-29.md` (both on this branch).

## Port these 2 fixes (paths map 1:1; monorepo `pacgate-ai/X` = here `X`)

**1. MCP 401-retry** — `deploy/pacgate-mcp/server.py`. pacgate-api issues 24 h
JWTs (`pacgate-core/src/lib.rs` L97), but `PacgateApi` logs in once in
`__init__` with no 401 handling → 24 h after every restart, every MCP tool
call 401s until the container is recreated (observed live: login 09-28 07:33,
first 401 09-29 08:05). Add `_relogin()` + retry-once-on-401 in `get`, `post`,
`delete`, `post_multipart` (skip retry when only `PACGATE_JWT_TOKEN` is set).
**Port the logic, not the file** — the monorepo copy has GBK-mojibake
em-dashes in comments; upstream's file is clean and structurally identical.

**2. OCR model volume** — compose-only, no image change. In BOTH
`deploy/client-bundle/compose.bundle.yaml` and `compose.prod.yaml`, add to
`ocr-service`: `volumes: [- paddleocr-models:/root/.paddleocr]`, and to the
top-level `volumes:` block: `paddleocr-models:`. PaddleOCR downloads ~18 MB
of PP-OCRv4 weights into `/root/.paddleocr` on first extraction (NOT baked
into the image); without the volume every recreate re-downloads from bcebos
— the only source — and an offline recreate breaks all extraction.

## Then release (a push to main builds NOTHING — trigger is tags/dispatch only)

1. Bump → `0.1.21`: workspace `pacgate-ai/Cargo.toml` + the 5 `image:` pins in
   both compose files (`scripts/bump-release-version.ps1`).
2. `git push fork main` (fast-forward, verified dry-run exit 0).
3. PR fork → `JZKK720/pacgate-ai-pr`, merge.
4. `workflow_dispatch` with `tag=0.1.21` (not a tag push — decouples the
   published tag from the build commit; the 0.1.14 release failed on that).
5. Verify GHCR: all 5 images at 0.1.21, anonymous manifest HEAD = 200.
6. AIPCs: `docker compose pull && docker compose up -d`; then
   `curl :8089/version` → 0.1.21, `docker exec pacgate-mcp grep -c _relogin
   /app/server.py` → 5, `pwsh -File scripts/test-legal-journey.ps1` → 17/17.

## Traps

- `docker compose pull` overwrites a locally rebuilt `pacgate-mcp:0.1.20`
  with the published (unfixed) image — the fix is lost until 0.1.21 exists.
- Do not port CI files from the monorepo — its `build-ghcr.yml` is stale;
  this repo's workflow is authoritative.
- AIPC builds need the daocloud mirror (`docker.io` unreachable there);
  GitHub CI is unaffected.