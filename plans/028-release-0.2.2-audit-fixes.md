# Plan 028 — Release 0.2.2: ship the 2026-10-22 audit fixes

**Date:** 2026-10-22
**Priority:** P1
**Effort:** ~1 hour (version bump, tag, watch the build, verify the pull)
**Depends on:** nothing — the code changes are already on the working tree
**Status:** **STEP 2.1 DONE** — version bumped to 0.2.2 in all three files, gates green. Steps 2.3–2.6 (commit, tag, build, prove on a real stack) remain.

---

## 0. Why this plan exists

The 2026-10-22 audit (`deploy/AUDIT-2026-10-22-v0.2.1.md`) fixed four defects.
Three of them are **compiled into `pacgate-api`**, so they are not in any
published image. `v0.2.1` was tagged at `a0003f8` (2026-10-22 14:39) and the
fixes sit uncommitted on top of `ad1da71`.

**A machine running `0.2.1` today still has all three:**

| Defect | Severity | Still live on 0.2.1? |
| --- | --- | --- |
| T4 documents auto-pass to `sanitized` | HIGH | **yes** |
| `kb_search` ignores the caller's tenant | MEDIUM-HIGH | **yes** |
| `kb_search` misreports `data_level` | MEDIUM | **yes** |
| MCP `pacgate_write_memory` `TypeError` | HIGH | **no** — bind-mounted, ships via `git pull` + restart |

The fourth is already deliverable without a new image because
`deploy/pacgate-mcp/server.py` is bind-mounted. The other three need a tag.

---

## 1. What ships in 0.2.2

| File | Change | Channel |
| --- | --- | --- |
| `pacgate-ai/crates/pacgate-api/src/sanitize.rs` | T4 hold: promotion requires `allow_auto_pass`; `disposition` in the audit row | image |
| `pacgate-ai/crates/pacgate-api/src/search.rs` | `kb_search` scoped to the JWT tenant; reports the chunk's own `data_level` | image |
| `pacgate-ai/crates/pacgate-rag/src/lib.rs` | `KbSearchResult.data_level`; both queries select `c.data_level` | image |
| `deploy/pacgate-mcp/server.py` | `post()` accepts `headers`, merged inside `send()` | bind mount |
| `deploy/client-bundle/compose.bundle.yaml` | MCP timeout 700, `PACGATE_MATTER_ID`, `server.py` mount | compose |
| `deploy/client-bundle/install.ps1` | step 7c restarts `pacgate-mcp` | installer |
| `scripts/audit-aipc-update-coverage.ps1` | `pacgate-mcp server.py` coverage row | gate |
| `deploy/ocr-service/app.py` | `_page_spans` extracted; malformed lines skipped, not fatal | image |
| `deploy/ocr-service/test_app.py` | 22 fail-closed assertions | test |

---

## 2. Steps

### 2.1 Bump the version in all four places

**DONE 2026-10-22.** `pacgate-ai/Cargo.toml` (workspace version, inherited by all
13 crates) plus all five image pins in each of `compose.prod.yaml` and
`compose.bundle.yaml` — 11 references, all now `0.2.2`. Verified: no `0.2.1`
remains in any of the three files, and both compose files still validate.

They must agree or the staleness marker (`/version` vs the compose pin) reports
a false mismatch. `scripts/audit-aipc-update-coverage.ps1` covers the marker but
not the pins, so check them by hand:

```
Select-String -Path pacgate-ai\Cargo.toml,deploy\client-bundle\compose.*.yaml -Pattern '0\.2\.[12]'
```
must show only `0.2.2`.

### 2.2 Run the gates before tagging

**DONE 2026-10-22 at 0.2.2** — all six green:

```
cargo test --workspace --offline          41 suites, 0 failed (api 92, rag 19, redact 136)
python scripts/test-mcp-401-retry.py      20 assertions, 0 failed
python deploy/ocr-service/test_app.py     22 assertions, 0 failed
audit-aipc-update-coverage.ps1            13 of 13, 0 gaps
compose.prod.yaml config --quiet          exit 0
compose.bundle.yaml config --quiet        exit 0
```

Re-run them after any further edit before tagging.

### 2.3 Commit and tag

```
git add -A
git commit -m "fix: T4 auto-pass, kb_search tenant scope, MCP memory write, MCP update restart"
git tag v0.2.2
git push origin main --tags
```

`build-ghcr.yml` triggers on `v0.2.*` and builds exactly five images. Do not
expect qm or openviking to rebuild — they are vendor images pinned by digest.

### 2.4 Watch the build, then verify the pull actually advanced

The installer already documents why this matters: `compose pull` reports
"Pulled" even when the local tag does not advance (observed 2026-10-13, where
every image logged "Pulled" and the machine kept running the previous build of
the same version). So verify by digest, not by the log line:

```
docker pull ghcr.io/jzkk720/pacgate-api:0.2.2
docker image inspect ghcr.io/jzkk720/pacgate-api:0.2.2 --format '{{index .RepoDigests 0}}'
```

Compare against the digest the workflow published. A tag that resolves to the
0.2.1 digest means the build did not publish.

### 2.5 Prove the T4 fix on a real stack

This is the test the audit could not run. It is the whole point of the release,
so do not skip it:

1. Upload a document, sanitize it with `data_level: "T4"`.
2. Assert the response has `verdict: "pass"` **and** `allow_auto_pass: false`
   **and** `chunks_promoted: 0`.
3. Assert `GET /api/documents/{id}/sanitize/status` reports
   `document_state: "pending"` — not `sanitized`.
4. Assert `GET /api/documents/{id}/download` returns **409**.
5. Assert `GET /api/kb/search?matter_id=…&q=…` does not return that document's
   chunks.
6. Sanitize the same document with `data_level: "T3"` and assert it **does**
   reach `sanitized` and **does** download — otherwise the hold is over-broad
   and every document is stuck.

Step 6 is the one that catches an over-correction. A hold that never releases is
as broken as an auto-pass, just in the other direction.

### 2.6 Verify the MCP restart on an updated machine

On a machine that already has the stack running:

```
git pull
.\install.ps1 -Update
docker inspect pacgate-mcp --format '{{.State.StartedAt}}'
```

`StartedAt` must be **after** the pull. Then call `pacgate_write_memory` through
MCP and confirm it returns a revision instead of raising `TypeError`.

---

## 3. What this plan deliberately does NOT do

- **No new `pending_review` state.** Held documents stay at `pending`, which is
  fail-closed and needs no migration. The cost is that "held for review" is
  indistinguishable from "never processed" in the document list. If the review
  panel must *list* held documents, that is a separate plan with a migration and
  an approval endpoint — neither exists today.
- **No approval endpoint.** `restore_document_handler` restores redacted text
  from the vault; it does not promote a document's sanitization state. A held
  document currently has no path to release other than re-running the job at a
  lower data level, which is a deliberate operator action, not an approval flow.
- **No OCR image rebuild for the `_page_spans` refactor alone.** It rides along
  with 0.2.2 because the image is rebuilt anyway. The refactor is behaviour-
  preserving except for one deliberate change: a malformed OCR line is now
  skipped instead of panicking the request.

---

## 4. Rollback

The three Rust fixes are additive and fail-closed. If 0.2.2 misbehaves, pin the
compose files back to `0.2.1` and `docker compose up -d` — but understand what
that restores: T4 auto-pass, cross-tenant `kb_search`, and misreported
`data_level`. Rolling back is a security regression, not a neutral act.

The `install.ps1` and `compose.bundle.yaml` changes are independent of the image
tag and can stay.
