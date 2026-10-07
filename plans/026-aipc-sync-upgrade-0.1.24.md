# Plan 026 — AIPC dev-box sync to origin/main + 0.1.24 upgrade evaluation

**Date:** 2026-10-07
**Machine:** dev box (pacgate-ai-pr workspace root = live install)
**Trigger:** user request — full sync + merge with JZKK720 upstream origin/main, verify + evaluate a plan for full upgrade implementation, preserve local metadata (vectorDB, architectures, workflows, templates), do not break the harness wire-up (deer-flow ↔ pacgate-api ↔ pacgate-mcp ↔ qm ↔ openviking).

---

## 1. What the sync delivered (executed)

### 1.1 Git sync — executed as a pure fast-forward

Evidence before acting (systematic-debugging Phase 1):

| Check | Result |
| --- | --- |
| `git rev-list --left-right --count main...origin/main` | `0 75` — zero local-only commits, 75 upstream commits |
| merge-base | = local HEAD (`7adfd84`) → strictly behind, no divergence |
| Remotes | `origin` = `upstream` = JZKK720/pacgate-ai-pr (canonical); `fork` = pacgate-ai/pacgate-ai-pr (stale, never deploy from it) |
| Uncommitted local work | `scripts/test-legal-journey.ps1` (130 insertions) — genuine local work upstream lacked |
| Untracked | one docx in `pacgate-ai-assets` (git never touches it) |

Execution:

1. Backed up all gitignored local state to `C:\pacgate-backup-20261007-124340`:
   `data/` (179 MB: deer-flow SQLite + tenants), `openviking/` (9.7 MB), `qm-pacgate/` (1.3 MB), `.env`, `.deer-flow-credentials`, `deer-flow-extensions-config.json`, plus `test-legal-journey-local.patch`.
2. Stashed the harness change, fast-forwarded `7adfd84..9e16546` (75 commits, 99 files, new tag `v0.1.23`, staging for 0.1.24).
   - One CRLF-only blocker (`deploy/qm-pacgate/qm.config.jsonc`, `i/lf w/crlf` with `core.autocrlf=true`) — resolved by `git checkout --` re-normalization, zero content loss.
3. Popped the stash → 3 conflict regions in `test-legal-journey.ps1` → resolved by evidence:
   - **Kept local**: deer-flow sign-in surface lane (step 9: setup-status + wrong-password→401 assertion; upstream had zero coverage on this lane), user-key preference in preflight (`OPENVIKING_USER_API_KEY` preferred; both principals authenticate on `/mcp`).
   - **Adopted upstream**: qm `/healthz` probe (verified against the running stack), MCP remember/find recall design (supersedes the local REST `content/write` variant — the root key works on MCP, eliminating the 403 the local version worked around).
   - **Folded local lesson into upstream design**: MCP poll budget 180s → 300s (gemma4 measured 200s cold on 2026-09-29; 180s was a false failure).
4. Committed as `ec6d191` — `test(journey): merge local harness improvements into upstream 0.1.24 rewrite`. Parse-validated (`PARSE OK`), stash dropped.

### 1.2 What the 75 commits change (upgrade surface)

| Area | Change | Wire-up impact |
| --- | --- | relationships preserved |
| compose.bundle.yaml | image repins 0.1.20→0.1.24; `PACGATE_ALLOW_REGISTRATION: "false"` (security gate); `DEERFLOW_TITLE_INVOKE_TIMEOUT_S` (hang fix); PaddleOCR weights volume; new patches (title-middleware, present-file) | topology unchanged: `./data`, `./workflows`, `./openviking`, `./data/deer-flow` mounts intact |
| pacgate-api (Rust) | auth.rs +604 lines (registration gate, admin provisioning), workspace.rs +198 (unified matter-workspace view + present_files matter mirror), redact R1 cross-jurisdiction ID set | API surface grows; existing routes unchanged |
| pacgate-mcp server.py | +179 lines (401-retry on 24h JWT expiry, matter_id 'None'/'null' handling) | bridge contract unchanged |
| qm stack | compose.qm.yaml +49, sandbox launch mechanism wired (static docker CLI + socket), sandbox-local image published | qm lifecycle stays compose-only |
| scripts/ | new gates: smoke-full-stack, auth-provisioning, mcp-401-retry; journey rewritten (MCP recall lane) | harness relationships preserved |
| docs/handbooks | refreshed for 0.1.23/0.1.24 | — |

### 0.1.24 security posture changes (notable)

- `PACGATE_ALLOW_REGISTRATION: "false"` — registration is now FIRST-USER-ONLY and gated by env; closes the open-registration leak (matter data exposure, upstream DEFECT doc).
- Sanitizer Tier-1 cross-jurisdiction ID extension set (R1) — legacy 15-digit ID placeholder is now opaque, not format-preserving.
- deer-flow title-invoke timeout (8s) — bounds the pregel-loop freeze (silent-no-reply fix 2026-10-06).

### 1.3 Local metadata preservation — verified

| Asset | Location | Protection |
| --- | --- | --- |
| pacgate-ai vectorDB (Postgres+pgvector) | docker volume `client-bundle_pacgate-db-data` | **pg_dump taken: 3.5 MB, 10 tables** → `C:\pacgate-backup-20261007-124340\pacgate-vectordb-dump.sql` |
| deer-flow SQLite (users, threads, admin) | `deploy/client-bundle/data/deer-flow/` (bind mount) | backed up + bind mount survives recreates |
| OpenViking memory store | `deploy/client-bundle/openviking/` (bind mount) | backed up + bind mount survives recreates |
| 222-template workflow library | `pacgate-ai/workflows/` (15 YAMLs, tracked) | tracked in git; upstream did not touch it |
| prompt templates | `docs/prompt-templates/` (tracked) | tracked in git |
| qm stack data | `deploy/client-bundle/qm-pacgate/` + volumes `qm-pacgate-pgdata`, `qm-pacgate-coredata` | backed up; named volumes survive recreates |
| credentials | `.env`, `.deer-flow-credentials`, `extensions-config.json` | gitignored + backed up |
| architectures/docs | `docs/`, `plans/`, `deploy/*.md` | tracked in git |

**Key fact:** git fast-forward cannot touch gitignored files or Docker volumes — data was safe by construction; the backup is belt-and-braces for the recreate step.

---

## 2. Upgrade execution state (as of this plan)

### 2.1 Pre-recreate verification — all green

| Check | Result |
| --- | --- |
| compose.bundle.yaml + compose.qm.yaml `config --quiet` | both VALID |
| GHCR anonymous token flow → `tags/list` | all five 0.1.24 images **public** (pacgate-api, deer-flow-pacgate, deer-flow-frontend-pacgate, pacgate-mcp, ocr-service) |
| `.env` vs 0.1.24 compose interpolation | 3 vars missing → appended BOM-safe: `PACGATE_COOKIE_SECURE=false`, `DEERFLOW_TITLE_INVOKE_TIMEOUT_S=8` |
| Persistence mounts in new compose | all 5 intact (db-data, ./data, ./workflows, ./data/deer-flow, ./openviking) |
| docker.io base images (nginx:1.27-alpine, pgvector/pgvector:pg16) | already cached locally — no docker.io pull needed |

### 2.2 Network constraint discovered (evidence, not guesswork)

- `ghcr.io:443` reachable; `registry-1.docker.io:443` **blocked** (TCP fails; DoH via Cloudflare/Google also blocked; TLS SNI handshake RST even on reachable IPs → SNI-based filtering of docker.io in this network region).
- Consequence: `docker compose pull` fails as a whole (it re-checks docker.io images even when cached). **Workaround: pull GHCR images individually, then `up -d --no-pull`** (docker.io images come from local cache).
- This is the same network-region failure mode as the 2026-09-23 incident (git fetch silent abort). It is environmental, not a repo defect.

### 2.3 .env additions (BOM-safe, per the 3af9605 lesson)

```
PACGATE_COOKIE_SECURE=false
DEERFLOW_TITLE_INVOKE_TIMEOUT_S=8
```

(`PACGATE_ALLOW_REGISTRATION` is hardcoded `"false"` in compose — no .env entry needed.)

---

## 3. Remaining execution steps (the plan to finish the upgrade)

### Step A — pull the five GHCR images individually (GHCR reachable)

```powershell
docker pull ghcr.io/jzkk720/pacgate-api:0.1.24
docker pull ghcr.io/jzkk720/deer-flow-pacgate:0.1.24
docker pull ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.24
docker pull ghcr.io/jzkk720/pacgate-mcp:0.1.24
docker pull ghcr.io/jzkk720/ocr-service:0.1.24
```

### Step B — recreate the stack without a registry re-check

```powershell
docker compose -f deploy/client-bundle/compose.bundle.yaml --env-file deploy/client-bundle/.env up -d --no-pull
```

- `--no-pull` avoids the docker.io re-check that fails in this network region.
- Persistence mounts are intact, so deer-flow SQLite, OpenViking memory, tenants, and the vectorDB volume survive.
- deer-flow admin account survives (bind mount `./data/deer-flow`), one browser re-login expected (JWT secret unchanged — `.env` untouched for JWT).

### Step C — verify the wire-up (the harness relationships)

```powershell
pwsh -File scripts/test-legal-journey.ps1 -RequireAllLanes
```

Expected: all lanes green including the merged deer-flow sign-in lane and the 300s-budget MCP recall lane. CANNOT-CHECK IS NOT A PASS.

### Step D — qm stack (separate compose project)

```powershell
docker compose -f deploy/qm-pacgate/compose.qm.yaml --env-file deploy/client-bundle/qm-pacgate/.env up -d --no-pull
```

- qm containers were up pre-upgrade; recreate them onto the new compose (sandbox launch mechanism now wired).
- Verify: does the qm core's pi-models patch survive? **No — recreate wipes the writable layer.** If 0.1.24's qm image bakes the fix, skip; if not, re-run `deploy/qm-pacgate/tasks/patch-pi-models.sh` (root, LF line endings) after recreate.

### Step D2 — qm pi-models patch check (critical, from memory)

- The qm core's `pi-models.ts` patch (glm-5.3-flash:cloud in MODEL_REGISTRY) is writable-layer state — a recreate wipes it. If 0.1.24's qm image bakes the fix, skip; if not, re-run the patch script (root + LF).
- Verify with: `docker exec qm-pacgate-core grep -c 'glm-5.3-flash:cloud' /app/src/model/pi-models.ts`

### Step E — gates

```powershell
pwsh -File scripts/run-all-checks.ps1
pwsh -File scripts/test-workflow-library-served.ps1   # exit 0 = 222 workflows
pwsh -File scripts/test-workflow-namespace.ps1
```

Step E expected: all gates green; workflow library serves 222 (not 10 built-ins).

### Step F — record evidence

- Append results to this plan (section 4) with exit codes and timestamps.
- Update `plans/README.md` row for 026.

---

## 4. Execution evidence (to be filled during execution)

| Step | Result | Evidence |
| --- | --- | --- |
| Pre-recreate checks | GREEN | compose valid ×2, GHCR public ×5, .env complete, mounts intact |
| Step A (GHCR pulls) | **BLOCKED — environmental** | GHCR API + blob CDN reachable, but blob transfer throttled to ~30-65 KB/s (957 MB image ≈ 9 h). Standalone pull stalled at "Pulling fs layer" with zero progress; killed after measurement. Same network-region degradation as the 2026-09-23 incident. |
| Step B (recreate) | **DEFERRED** until images obtainable | stack intentionally left on 0.1.20 (healthy) |
| Wire-up verification (ran instead of C) | **GREEN on 0.1.20** | api `/version` = 0.1.20; deer-flow setup-status 200 (needs_setup=False); openviking health=ok; fresh login → `/pacgate/api/matters` = 2 items; `/pacgate/api/workflows` = **222**; qm `/healthz` = 200; 15 workflow YAMLs mounted on pacgate-api; qm pi-models patch present (2 matches) |
| Step D (qm recreate) | deferred with Step B | — |
| Step D2 (pi-models check) | baseline recorded: patch present pre-recreate | `grep -c` = 2 |
| Step E (gates) | deferred with Step B | — |
| Step F (record) | this document + plans/README.md row 026 | — |

### Post-verification stack state (2026-10-07)

- All 13 containers up on 0.1.20 images; every wire-up lane answers.
- The 0.1.24 upgrade is **staged, not executed**: compose now pins 0.1.24, `.env` completed, images verified public — the only blocker is blob-transfer throughput from GHCR's CDN in this network region.
- Next viable execution window: retry `docker pull` per image (Step A) when the network recovers, then Steps B→E in order. No repo work remains blocked on this.

---

## 5. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| docker.io blocked → compose pull fails | pull GHCR individually + `up -d --no-pull` (docker.io images cached) |
| qm core recreate wipes pi-models patch | check after recreate; re-run patch script (root, LF) if missing |
| deer-flow JWT secret rotation kills sessions | .env JWT vars untouched → sessions survive; one re-login if not |
| OpenViking recall false-failure on cold gemma4 | poll budget now 300s (merged lesson) |
| Registration gate flips behavior | `PACGATE_ALLOW_REGISTRATION=false` hardcoded in compose — client stack stays closed |
| Backup restore needed | `C:\pacgate-backup-20261007-124340` has data/, openviking/, qm-pacgate/, .env, credentials, vectordb dump |

---

## 6. Verdict

**GO for the 0.1.24 upgrade on this dev box**, with the network constraint handled by individual GHCR pulls + `--no-pull` recreate. All local metadata is preserved (backed up + bind mounts + named volumes + git-tracked). The harness wire-up (deer-flow ↔ pacgate-api ↔ pacgate-mcp ↔ qm ↔ openviking) is structurally preserved by the 0.1.24 compose; the merged harness now covers the deer-flow sign-in lane that upstream lacked.

**Remaining after execution:** Step A→F above, then update `plans/README.md` row 026 to DONE with evidence.