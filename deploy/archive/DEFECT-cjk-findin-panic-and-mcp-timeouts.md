# DEFECT: tokio panic on Chinese text in find_in + MCP client kills long calls — "cannot generate documents as prompted"

**Found:** 2026-10-11, investigating why deer-flow glm-5.3-flash-cloud runs keep
dying mid-document-generation ("model picker / cloud models cannot generate
documents as prompted").
**Severity:** HIGH — kills agent runs mid-execution regardless of model.
**Status:** RESOLVED 2026-10-11 (two fixes applied; one requires the next
upstream pacgate-api image to reach client machines).

## Why this looked like a model problem

The user reported model pickers, "model regression", and cloud+local models both
failing to generate documents. None of that was the model. Live forensics:

| Time (2026-10-11 UTC) | Event | Model |
|---|---|---|
| 01:34-01:35 | 2 runs interrupted by user | deepseek-v4.1-flash-cloud |
| 01:36:12 | run 4c2754a2 started | nemotron-3.5-lightning-30b-local |
| 01:38:58 | stack restarted → run **orphaned as error** | nemotron |
| 01:42:53 | run 53720ae5 started | deepseek-v4.1-flash-cloud |
| 01:46:00 | **workflow COMPLETED server-side** (2 steps, steps_completed=2) | — |
| 01:47:26 | **pacgate-api PANIC** (`store.rs:606`) on find_in over the 资料收集目录 document | — |
| 01:47:41 | deer-flow: `pacgate_execute_workflow` → "Server disconnected without sending a response" | — |
| 01:48:55 | run interrupted by user | — |

Three independent, model-independent failure modes stack onto the same symptom:

## Failure 1 — tokio panic slicing Chinese text (pacgate-api, store.rs:606)

`FsDocumentStore::find_in` sliced raw byte offsets:

```rust
let context_start = pos.saturating_sub(100);
let context_end = (pos + query.len() + 100).min(content.len());
let context = content[context_start..context_end].to_string();  // PANICS mid-CJK
```

On the overnight run the panic message was exact:
`byte index 11111 is not a char boundary; it is inside '浜' (bytes 11110..11113)`.
CJK chars are 3 bytes; any match whose ±100-byte context window crosses a char
boundary panics the tokio worker. The in-flight HTTP response dies (the client
sees a disconnect), steps already executed are lost, and the agent run errors.

The panic ALSO explains "documents half-generated then run dies": the
"Search for issues" workflow step (`find_in_document`) is what panicked.

**Secondary bug in the same function:** the old loop called
`content_lower.find(&query_lower)` from byte 0 inside a per-page loop, so every
page reported the FIRST match in the document — later matches never surfaced and
the same context repeated `page_count` times.

**Fix (tested, in `pacgate-ai/crates/pacgate-docx/src/store.rs`):**
- `floor_char_boundary()` snaps both slice bounds DOWN to UTF-8 boundaries.
- `scan_matches()` scans once from a monotonic cursor (`str::find` + cursor),
  attributing every match to its page via newline counting — no repeated
  first-match duplication, and out-of-range pages clamp.
- 4 new regression tests in `store.rs::tests` (`7 passed` incl. the old suite):
  the exact byte-11111-style CJK repro, multi-match surfacing, empty query,
  and the boundary helper itself.
- **DURABILITY PATH:** this is compiled Rust — it rides the next upstream
  pacgate-api image build (upstream origin/main + GHCR, per the no-local-builds
  policy). Until then, any `find_in_document` over a CJK document whose match
  sits <100 bytes from a char boundary can still panic on the 0.1.25 image.

## Failure 2 — MCP SDK client timeout kills long tool calls (deer-flow side)

langchain-mcp-adapters builds its httpx client with MCP SDK defaults:
`MCP_DEFAULT_TIMEOUT=30.0` total, `MCP_DEFAULT_SSE_READ_TIMEOUT=300.0` read
(`mcp/shared/_httpx_utils.py`). Measured live: `pacgate_execute_workflow` takes
~174s; sanitize runs to ~655s. Any call racing those budgets is torn down
client-side — in the overnight run the workflow had COMPLETED at 01:46:00 and
the client still errored at 01:47:41.

**Fix (bind-mounted, live):** `deploy/client-bundle/patches/deer-flow-mcp-client.py`
mounted over `/app/backend/packages/harness/deerflow/mcp/client.py` in BOTH
`compose.prod.yaml` and `compose.bundle.yaml`. It injects
`httpx_client_factory` producing `httpx.Timeout(900, read=900)` (covers the
700s sanitize ceiling + headroom, stays under the nginx 720s chain so errors
surface deterministically) while avoiding the SDK's deprecated timeout kwargs.

## Failure 3 — silent SSE stream defers results (pacgate-mcp side)

With the SDK default `json_response=False`, a CallTool POST returns **202** and
the result is delivered later over a GET SSE stream that stays silent for the
entire tool execution. Anything reading the stream (client read-timeout, LB,
proxy idle timer) kills the call while the work proceeds pointlessly.

**Fix (bind-mounted, live):** `deploy/pacgate-mcp/server.py` →
`FastMCP(..., json_response=True)` — the CallTool POST now blocks and returns
**200 with the result JSON** (verified on the wire: `POST /mcp 200 OK` for both
`tools/list` and `call_tool`, vs the old `202 Accepted` + GET pattern).
Statefulness preserved (`stateless_http=False`).

## Verification (all live, 2026-10-11)

- `cargo test -p pacgate-docx --lib` → 7/7 pass (4 new regression tests).
- `cargo build -p pacgate-api` → clean.
- Patched client probe inside deer-flow: 19 pacgate MCP tools load through
  `MultiServerMCPClient`; real `call_tool(pacgate_list_matters)` →
  `is_error: False` with live data.
- `pacgate_execute_workflow` with a bogus id → structured 404 error text
  (full JSON round-trip, no transport death) — the exact lane that failed
  overnight now round-trips cleanly.
- pacgate-mcp wire: `POST /mcp 200 OK` (was `202 Accepted` + GET SSE).
- Smoke suite (`smoke-deer-flow-outputs.ps1`): PASS (note: run it with
  `-Email/-Password` from `.deer-flow-credentials`; its .env fallback defaults
  read the WRONG password source).
- Legal journey (`scripts/test-legal-journey.ps1`): 19/19 PASS all lanes.
- deer-flow restarted (not recreated); admin account and threads preserved.

## Overnight "ran all night" report — what the logs actually show

The tutorial thread (`学习关于pacgate-ai并创建教程`, thread aebd2862, glm-5.3-flash-cloud)
did NOT run all night. Server-side timeline:

- 13:29:53 Oct 10 run 96aff2ac started; **marked success 15:15:01** (1h45m).
  It looped late (loop-detection warnings at 14:50:48 and 15:14:02; repeated
  `debug_punct.py` runs) but terminated normally.
- After 15:17:09 (memory-updater tail) there are **ZERO** deer-flow log lines
  until 01:33:37 Oct 11. Ollama `server-1.log` also shows zero chat requests
  between 23:17 Oct 10 and 09:33 Oct 11.
- The spinner the user saw "running" overnight is the known browser-hang
  signature (run finishes server-side, UI never re-fetches or reconnects the
  stream → spinner forever; see repo memory mcp-timeout-fix-2026-10-09).
- The 01:34-01:48 activity was the user's own morning attempts; the 01:38:58
  stack restart (likely Docker Desktop startup on wake) orphaned the nemotron
  run as error.

So: no runaway overnight burn. But the 1h45m duration of a tutorial-writing
run IS the "generation is slow/stalling" experience, and its last hour was
looping on the same punctuation-fix step — a model-behavior loop that the
loop-detection middleware only warned about, plus every `pacgate_execute_workflow`
/ long tool call being one client-timeout away from a total loss.

## Remaining gaps (explicit)

1. The Rust `find_in` fix is NOT in any published image. Client AIPCs on
   0.1.25 remain exposed to Failure 1 until the next upstream release.
2. Failure 2/3 fixes are bind-mount-delivered on the dev box; they must ride
   compose.prod.yaml (already committed) on fresh installs.
3. Neither failure is covered by any committed E2E gate: the smoke suite skips
   agent runs, and the journey suite exercises sanitize but never
   `pacgate_execute_workflow` through deer-flow's MCP client. A >5-min tool
   call regression is again invisible to both.
4. The 1h45m+ tutorial-run loop (glm repeating the same fix step) is model
   behavior, not infrastructure; loop-detection middleware only warns. Left
   as-is per "don't fix the model, fix the plumbing" scope.