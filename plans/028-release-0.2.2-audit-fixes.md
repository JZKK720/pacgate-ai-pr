# Plan 028 — Release 0.2.2: ship the 2026-10-22 audit fixes

**Date:** 2026-10-22
**Priority:** P1
**Effort:** ~1 hour (version bump, tag, watch the build, verify the pull)
**Depends on:** nothing — the code changes are already on the working tree
**Status:** **RELEASED AND PROVEN 2026-10-22** — version bumped, committed `ddbb70e`, tagged `v0.2.2`, pushed, GHCR build green, all five images public with `revision=ddbb70e`. The T4 hold and the MCP memory write were both proven on the live HX370 stack, including the T3 control that shows the hold is not over-broad. See §2.5 and §2.6.

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

**DONE 2026-10-22.** Commit `ddbb70e`, annotated tag `v0.2.2`, pushed to
`origin/main`. `build-ghcr.yml` triggered on the `v0.2.*` pattern.

### 2.4 Watch the build, then verify the pull actually advanced

**DONE 2026-10-22.** Run `39785773569`: `credential-guard` success,
`build-and-push` success (24 steps). Verified by digest and by OCI label, not by
the "Pulled" log line:

| Image | Anonymous pull | `image.version` | `image.revision` |
| --- | --- | --- | --- |
| `pacgate-api` | 200 | 0.2.2 | `ddbb70e` |
| `pacgate-mcp` | 200 | 0.2.2 | `ddbb70e` |
| `ocr-service` | 200 | 0.2.2 | `ddbb70e` |
| `deer-flow-pacgate` | 200 | 0.2.2 | `ddbb70e` |
| `deer-flow-frontend-pacgate` | 200 | 0.2.2 | `ddbb70e` |

The `revision` label is the load-bearing check: it names the exact commit the
image was built from, so a tag that silently resolved to the previous build
would show a different SHA. All five match `ddbb70e`.

Note on the anonymous check: a bare `HEAD` on the manifest returns **401** even
for a public image, because GHCR requires a token exchange first. Fetch
`https://ghcr.io/token?scope=repository:jzkk720/<img>:pull&service=ghcr.io` and
send the result as `Authorization: Bearer <token>`; a public image then returns
**200**. A 401 after that exchange is the real "still private" signal.

### 2.5 Prove the T4 fix on a real stack

**DONE 2026-10-22 on the live HX370 stack.** This is the test the audit could not
run, and it is the whole point of the release.

The stack was running `0.2.1` (revision `a0003f8`), so the bug was reproduced
first, then the fix was proven against the same request shape.

**Before (0.2.1):**

```
POST /pacgate/api/documents/{id}/sanitize  {"data_level":"T4"}
  -> verdict=pass  allow_auto_pass=False  require_human_review=True  chunks_promoted=1
GET  /pacgate/api/documents/{id}/download
  -> 200, 56 bytes          <-- the T4 document was downloadable
```

`allow_auto_pass=False` and `chunks_promoted=1` in the same response is the bug
stated plainly: policy refused, the code promoted anyway.

**After (0.2.2, revision `ddbb70e`):**

```
POST /pacgate/api/documents/{id}/sanitize  {"data_level":"T4"}
  -> verdict=pass  allow_auto_pass=False  require_human_review=True  chunks_promoted=0
GET  /pacgate/api/documents/{id}/download
  -> 409                    <-- refused
GET  /pacgate/api/kb/search?matter_id=...&q=process
  -> the held T4 document is absent from the results
```

**Control (T3 must still release):**

```
POST /pacgate/api/documents/{id}/sanitize  {"data_level":"T3"}
  -> verdict=pass  allow_auto_pass=True  chunks_promoted=1
GET  /pacgate/api/documents/{id}/download
  -> 200                    <-- released, as it should be
```

The control is what proves the hold is not over-broad. A hold that never
releases is as broken as an auto-pass, just in the other direction.

### 2.6 Verify the MCP restart on an updated machine

**DONE 2026-10-22 on the live stack.** `docker compose restart pacgate-mcp`
loaded the bind-mounted `server.py`; the container's copy now carries the
`headers` kwarg on both `_request` and `post`.

Proven end-to-end through the MCP client, not by reading the file:

```
POST /api/matters/{id}/memory  If-Match: 0   -> 409 "file is at 1, caller expected 0"
POST /api/matters/{id}/memory  If-Match: 1   -> 200 {"revision": 2}
```

Before the fix both calls raised `TypeError: PacgateApi.post() got an unexpected
keyword argument 'headers'`, so the revision guard was unreachable from MCP.

---

## 3. What this plan deliberately does NOT do

- **No new `pending_review` state.** Held documents stay at `pending`, which is
  fail-closed and needs no migration. The ambiguity that used to come with that
  ("held" vs "never processed") is now resolved by a **derived** `held_for_review`
  flag on the status response — derived from the ledger, so there is no second
  source of truth to drift. See plan 029 for the approval endpoint that releases
  a held document.
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
