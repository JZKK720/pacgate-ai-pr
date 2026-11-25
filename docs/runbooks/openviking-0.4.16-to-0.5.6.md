# Runbook: OpenViking 0.4.16 -> 0.5.6

**Status:** EXECUTED 2026-11-25. Running `ghcr.io/volcengine/openviking@sha256:121dc552743bb4cdf1db9782b9662dd0ef2cea128362f0d1a4b3e19ad9e07b38` (v0.5.6), pinned in both compose lanes.

**What the runbook got wrong, measured during execution (read this before the next upgrade):**

1. **The root key no longer opens the data API.** v0.5.x refuses it on every tenant-scoped
   route: `-32001 "ROOT API keys cannot access tenant-scoped data APIs in api_key mode."`
   The root key survives only on `/api/v1/admin`, `/api/v1/observer`, `/api/v1/console`,
   `/api/v1/tasks`, `/api/v1/system/*` and `/api/v1/debug/health`. Every client therefore
   needs an **account-scoped user key**, issued with `scripts/ov-issue-service-key.ps1`.
   Symptom if missed: `/health` stays 200, so the container reports healthy, while every
   `ov-*` tool and deer-flow memory recall fails. Nothing in the runbook predicted this.
2. **`remember` changed shape.** It now takes `messages:[{role,content}]` and answers
   "Submitted N message(s) for memory extraction", not "Stored". The old `{content: ...}`
   payload is rejected with a pydantic `Field required` error.
3. **Writes are confined to the key's own user namespace.** `viking://user/default/...`
   returns PERMISSION_DENIED when the key belongs to `pacgate-service`.
4. **Extraction silently produced NOTHING on the default protocol.** `memory.extraction_output_format`
   defaults to `python` (the internal memory-SDK DSL). With a local Ollama extractor that
   committed sessions in ~2.5s with `completion_tokens=5` and `memories_extracted: {}` -
   no error anywhere. Setting it to `json` fixed it.

   **Correction, and why it matters (measured 2026-11-25).** The first diagnosis also blamed
   the model size and pinned the 24 GB 74B as the extractor. That was wrong in a way worth
   recording: the protocol and the model were changed in the SAME step, so the model got
   credit for the protocol's fix. Re-tested with the protocol alone, the 9.8 GB
   `nemotron-3.5-bolt:e4b-q8_0` captures facts correctly - a concept-level question
   ("when is the Kelmarsh arbitration hearing, and when must the expert report be filed?")
   returned the hearing date and the deadline from natural language. The 74B is NOT needed.

   That matters commercially: 24 GB cannot fit the 16 GB card in an HX370/HX470 AIPC, so
   shipping it as the default would have broken memory extraction on the small machines
   silently - extraction still reports memory operations while writing none. The shipping
   template therefore keeps the 9.8 GB tag, and a big-memory box (Ryzen AI MAX 395) opts up
   with `OPENVIKING_VLM_MODEL` in `.env`. `scripts/test-aipc-capacity-fit.ps1` now fails if
   the template pin does not fit the 16 GB card.

   One caution when testing this: do NOT use a unique token as the canary. Extraction
   CONSOLIDATES facts into entity documents and legitimately rewrites or drops per-run
   tokens, so token matching reports failures on stored facts. Ask a concept-level question
   and check the answer, or read the memory file directly.5. **First extraction costs minutes.** 81s warm, 279s cold on this box; the acceptance
   budget must be minutes, not seconds.

Timings and evidence: `scripts/test-openviking-roundtrip.ps1` and
`scripts/test-legal-journey.ps1` both pass with all lanes verified. Before this run the host was on `sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701` (v0.4.16).
**Risk:** high-medium. The data directory is the only copy of agent memory. There is no online downgrade path.
**Estimated window:** 60-90 minutes including rollback rehearsal. Run with the bundle stopped, not against a live practice.

## Why this is not a digest bump

v0.5.6 is 9 minor releases ahead. The release notes are the only changelog (no CHANGELOG.md upstream). The material points, verified against the v0.5.6 notes and tag:

| Release | Change | Consequence here |
|---|---|---|
| 0.5.0 | New gateway mode | Not needed. We talk to `/mcp` directly; do not enable it. |
| 0.5.1 | `/api/v1/admin/*` moved to `/gateway/admin/*`; session/resume must be migrated before 0.5.3; `root_api_key` required non-empty even on localhost | We call no admin endpoint, so no code change, but a stored empty root key is now fatal instead of ignored. |
| 0.5.3 | Legacy `viking://session/...` URIs rejected (`INVALID_URI`); `POST /api/v1/admin/migrate` returns 400 | Any agent memory already written under old session URIs must be inventoried **before** upgrade. There is no migrate endpoint afterwards. |
| 0.5.5 | Snapshot log index (SQLite per account) backfills history on first boot; QueueFS serial/group keys now persisted | First start after upgrade is slow and writes a lot. Disk headroom required. Rust extension and Python server must move together — single image, so fine, but never a mixed fleet. |
| 0.5.6 | PostgreSQL stores for account/task/watch become available and are opt-in | We stay on the file stores. Ignore unless we later go multi-node. |
| 0.5.6 | ACL: cross-account grants rejected; `ls`/`tree`/`stat` now return `access` | Our clients ignore the new field; no change. |

Pinned target:

```
ghcr.io/volcengine/openviking@sha256:121dc552743bb4cdf1db9782b9662dd0ef2cea128362f0d1a4b3e19ad9e07b38   # tag v0.5.6 (2026-11-24)
```

## 0. Preconditions

- [ ] No client session in flight; announce the window.
- [ ] `df -h` on the volume holding `deploy/client-bundle/openviking/workspace`. Need **at least 3x** `du -sh` of that directory free (0.5.5 backfill + rollback copy).
- [ ] `.env` `OPENVIKING_ROOT_API_KEY` is non-empty.
- [ ] `docker compose -f deploy/client-bundle/compose.bundle.yaml stop openviking` and `docker ps` confirms nothing is holding port 1933.

## 1. Backup (do not skip; verify it)

```powershell
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$src   = 'C:\Users\1\github-pr\pacgate-ai-pr\deploy\client-bundle\openviking'
$dst   = "D:\pacgate-backup\openviking-$stamp"
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item -Recurse -Force "$src\*" $dst
$hash = { param($p) (Get-ChildItem $p -Recurse -File | Get-FileHash -Algorithm SHA256 | Measure-Object Length -Sum).Sum }
(& $hash $src) -eq (& $hash $dst)   # must print True
```

Keep at least two generations. Verify before touching anything else.

## 2. Legacy URI sweep (still on 0.4.16)

```powershell
Select-String -Path "$src\workspace\**\*.json" -Pattern 'viking://session/' -List -ErrorAction SilentlyContinue
```

Record every hit (account, session id). Those sessions cannot be auto-migrated after 0.5.3. Either re-create them after upgrade or accept the loss and say so in the run log. Do not hand-edit the store.

## 3. Config

`ov.conf` (and `ov.conf.template` to match):

- keep `server` block, keep non-empty `root_api_key`
- keep `storage.workspace` as-is (`/app/.openviking/workspace`)
- keep `embedding` (ollama / `nomic-embed-text` / 768) and `vlm` blocks unchanged — changing the embedding model invalidates every stored vector and is a separate decision
- do **not** add `account_store`/`task_store`/`watch_store`; `provider: postgres` is opt-in and not part of this change

## 4. Compose change

In `compose.bundle.yaml` and `compose.prod.yaml`, replace the 0.4.16 pin with the v0.5.6 digest above. Commit message records the old and new digests.

## 5. Upgrade

```powershell
cd deploy\client-bundle
docker compose -f compose.bundle.yaml pull openviking
docker compose -f compose.bundle.yaml up -d openviking
docker compose -f compose.bundle.yaml logs -f --tail 200 openviking
```

First boot is slow. It must reach healthy and answer:

```powershell
.\scripts\ov-mcp-call.ps1 -Tool health
.\scripts\ov-mcp-call.ps1 -Tool tools/list
```

If either throws, do **not** retry blindly. Capture logs, restore from the backup in step 1, file what you saw. The 0.5.5 snapshot backfill can leave a half-written per-account SQLite; a second start on a broken store is worse than a clean restore.

## 6. Acceptance gate (all must pass, in this order)

1. `scripts\test-openviking-roundtrip.ps1` — writes a canary memory, reads it back, and confirms it persists across a container restart. Must be run **after** upgrade.
2. `scripts\test-lane-connectivity.ps1` — deer-flow and qm lanes reach OpenViking.
3. `scripts\test-legal-journey.ps1` — end-to-end matter flow including a memory write.
4. Manual: `pacgate_kb_search` for a known document returns non-empty hits.
5. `git status` — compose files staged with only the digest change.

## 7. Rollback

```powershell
docker compose -f compose.bundle.yaml stop openviking
Remove-Item -Recurse -Force "$src\workspace"
Copy-Item -Recurse -Force "D:\pacgate-backup\openviking-<stamp>\workspace" "$src\workspace"
# revert the two compose pins to the 0.4.16 digest
docker compose -f compose.bundle.yaml up -d openviking
```

There is no in-place downgrade: 0.5.x writes indexes 0.4.16 cannot read. Restore, do not "fix forward".

## 8. Out of scope (deliberately)

- Postgres-backed account/task/watch stores (new in 0.5.6; needs a separate decision).
- Gateway / `openviking-gateway` service (new attack surface; we use `/mcp`).
- Privacy scanner, skill governance, Antigravity/Qoder adapters.
- Any change to the embedding model.

## 9. After this works

Update `deploy/AIPC-0.2.37-E2E-VERIFICATION.md` (or the successor) with the measured timings, the digest, and the canary output, so the next person does not re-derive this from release notes.
