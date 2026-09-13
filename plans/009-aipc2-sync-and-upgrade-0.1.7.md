# Plan 009 — AIPC2: sync to origin/main and upgrade live stack to v0.1.7

Date: 2026-09-06. Mode: **direct** (single machine, live Docker stack, no PR dance for deploy state).
Validated assumptions are marked ✅ (verified this session); unverified ones ⚠️.

## Verified ground truth (do not re-derive)

- ✅ `main` is **strictly behind `origin/main` by 10 commits, 0 ahead** → clean fast-forward.
- ✅ What the 10 upstream commits deliver:
  - `aa1af15` — all four runtime images published to **`ghcr.io/pacgate-ai/*`** org namespace + `build-ghcr.yml` CI (trigger: tag `v0.1.*`) + `deploy/build-images.ps1` / `build-frontend.ps1` + frontend wrapper Dockerfile.
  - `bba04a8` → `3cf9995` (v0.1.4–v0.1.7) — **RAG wired for real**: migrations + real stores + `seed` bin, then three score-decode type fixes (`ts_rank` f64 / pgvector f32, measured via `pg_typeof`). This is the biggest functional jump: `GET /api/kb/search` hybrid retrieval was broken on score decode before 0.1.4.
  - `25e0356` — **AIPC2-specific deploy fixes**: deer-flow SQLite state persisted via `./data/deer-flow:/app/backend/.deer-flow` mount (kills the admin-loss-on-recreate bug), OpenViking `vlm` section (gemma4 via native Ollama base, no `/v1`), optional cloud model picker entries, `deepseek-v4-pro:cloud` tag fix, install URL 8081→8089.
  - `86d8b91` + `84392dd` — new **single-stack `deploy/qm-pacgate/compose.qm.yaml`** with external network/volumes + pinned `FLY_BASE_IMAGE` digest.
- ✅ GHCR anonymous HEAD (with manifest `Accept` header) returns **200 for all four `pacgate-ai/*:0.1.7`** images — public, no `docker login` needed (client-path rule respected).
- ✅ Live stack on this AIPC2: `pacgate-api / deer-flow / deer-flow-frontend / pacgate-mcp` all at **`ghcr.io/pacgate-ai/*:0.1.3`**, up ~9 h. QM stack + hermes/odysseus unrelated.
- ✅ **The running `deer-flow` container has NO `.deer-flow` persistence mount** (only config/workflows/extensions + `/data`). Today, any `up -d`/recreate destroys the admin account + thread history. This makes the upgrade time-sensitive.
- ✅ Local uncommitted work splits into three buckets:
  1. **Superseded** — `compose.bundle.yaml` + `compose.prod.yaml` edits (hand-bumped images to `pacgate-ai:0.1.3`): upstream already carries `pacgate-ai:0.1.7` + the persistence mount. Discard local copy, take upstream.
  2. **Unique, keep** — `pacgate-search/src/lib.rs` EUR-Lex fix (`cdm:work_title`, verified against live SPARQL 2026-09-05) and `deploy/qm-pacgate/qm.config.jsonc` sandbox digest `5da1e086…` (this machine's published sandbox).
  3. **Untracked, keep** — `deploy/qm-pacgate/tasks/` (`patch-pi-models.sh`, `seed-base-model.sql` — the proven QM fix from the V2 handoff) and `deploy/client-bundle/data/deerflow.db.backup` (44 MB, gitignored ✅). Root scratch files (`bm.txt`, `rm*.txt`, etc.) are junk.
- ⚠️ `qm.config.jsonc` sandbox digest is machine-specific; keep it **out of the committed history** (stash or assume-unchanged), do not push AIPC2's localhost:5000 digest as a repo default.

## Step graph

Serial chain 1→2→3→4; step 5 after 3; steps 6→7 serial. No parallelism worth orchestrating (single machine, shared Docker daemon).

---

### Step 1 — Preserve state before anything moves

**Context:** deer-flow DB lives in the container writable layer. QM core carries the in-layer `pi-models.ts` patch. Both die on recreate.

1. `docker cp deer-flow:/app/backend/.deer-flow/data/deerflow.db deploy/client-bundle/data/deerflow.db.pre-upgrade` (also copy `-wal`/`-shm` if present).
2. Verify QM patch still live: `docker exec qm-pacgate-core grep -c "glm-5.3-flash" /app/src/model/pi-models.ts` → expect ≥1. If 0, re-run `deploy/qm-pacgate/tasks/patch-pi-models.sh` via `docker exec -u root` **before** touching anything else, so the working baseline is known.
3. `docker compose -f deploy/client-bundle/compose.prod.yaml down --remove-orphans` is **NOT** used at this step; nothing is stopped yet.

**Exit:** two `.db*` files + wal/shm in `deploy/client-bundle/data/`, non-zero size.

### Step 2 — Reconcile local WIP, then fast-forward

**Context:** `main` is a strict ancestor of `origin/main`; the only obstacle is the working tree.

1. Commit the unique Rust fix to `main` first (it must not be lost in checkout):
   `git add pacgate-ai/crates/pacgate-search/src/lib.rs` → commit `fix(search): EUR-Lex SPARQL uses cdm:work_title (verified live)`.
   Note: this becomes a **local commit ahead of origin** — that is intentional and fine; the fast-forward becomes a linear merge/rebase below.
2. `git stash push deploy/qm-pacgate/qm.config.jsonc` (machine-specific digest).
3. Discard superseded compose edits: `git checkout -- deploy/client-bundle/compose.bundle.yaml deploy/client-bundle/compose.prod.yaml`.
4. `git pull --rebase origin main` → replay the search fix on top of `84392dd`. Result: `main = origin/main + 1 commit`.
5. `git stash pop` → re-apply the sandbox digest; **keep it uncommitted** (or `git update-index --assume-unchanged deploy/qm-pacgate/qm.config.jsonc`).
6. Commit the QM tasks scripts: `git add deploy/qm-pacgate/tasks/` → `chore(qm): check in pi-models patch + seed SQL from V2 handoff`.
7. Delete root scratch files (`bm*.txt`, `rm*.txt`, `reg*.txt`, `mp.txt`, `pi*.txt`, `gbm.txt`, `corecmd.txt`, `mtime.txt`) — they're investigation leftovers, not deliverables.

**Exit:** `git status -sb` clean except `qm.config.jsonc` (assume-unchanged) + gitignored `data/`; log shows the 10 upstream commits + 2 local ones on top.

### Step 3 — Build/test gate on the synced tree (repo convention)

1. `cd pacgate-ai; cargo check`
2. `cargo test -p pacgate-api --test smoke` (expect 23+; upstream added 5 RAG/DataLevel smoke tests in 0.1.4 — count may be higher)
3. `cargo test -p pacgate-rag` and `cargo test -p pacgate-search` (the two crates the upgrade + local fix touch)
4. `cargo clippy -p pacgate-search` on the committed EUR-Lex change.

**Exit:** all green. Anything red → stop, fix before deploy. Do not proceed on a red gate.

### Step 4 — Upgrade the live stack to 0.1.7 (the actual AIPC2 fix)

**Context:** upstream compose now pins `pacgate-ai/*:0.1.7` and mounts `./data/deer-flow:/app/backend/.deer-flow`. Which compose file the live stack uses must be confirmed first: `docker inspect pacgate-api --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'`.

1. `docker pull` the four 0.1.7 images (anonymous — verified public).
2. Create `deploy/client-bundle/data/deer-flow/` and seed it with the Step-1 backup: copy `deerflow.db` (+ **do not** copy wal/shm — stale WAL replays the empty first-boot state, known gotcha).
3. Recreate only the bundle services: `docker compose ... up -d` (project dir `deploy/client-bundle`). This is the one case where `up` (recreate) is correct — persistence is now a host mount, so the admin survives.
4. **Do not** recreate `qm-pacgate-core` (writable-layer patch) — QM services are untouched by this upgrade. The new `compose.qm.yaml` single-stack migration is explicitly **deferred** (Step 7).
5. OpenViking: recreate `openviking` with the updated `ov.conf.template` (vlm section). Confirm `gemma4:12b-it-q8_0` is present in `ollama list` on this box first (model choice is the user's; don't assume the tier set).

**Exit:** `docker ps` shows all four bundle containers at `:0.1.7`; `deer-flow` has the `.deer-flow` mount.

### Step 5 — E2E verification on the upgraded stack

- `GET http://localhost:8089/pacgate/api/matters` / `workflows` / `search/connectors` → 200 (nginx `/pacgate/` prefix routing preserved).
- deer-flow: log in as `admin@pacgate-law.com` (proves DB restore worked), run one short chat; `ollama ps` shows the local tier model loaded (not cloud).
- **RAG jump check** (the v0.1.4–0.1.7 payload): upload or seed a doc, then `GET /api/kb/search?q=...&matter_id=...` returns hybrid results with sane scores — no f32/f64 decode 500s. Use `cargo run --bin seed` equivalents only if the DB is fresh; existing `pacgate-db` volume already has schema + migration 004 applied by `RagStore::run_migrations()`.
- OpenViking: trigger one memory extraction, confirm no `OPENAI_API_KEY` error in `docker logs openviking` (vlm fix).
- QM: existing session still works (`localhost:8181`); pi-models patch intact.

**Exit:** all five checks pass; browser pages currently shared show a working chat.

### Step 6 — Push the delta

- `git push origin main` (search fix + qm tasks scripts). CI triggers **only on `v0.1.*` tags**, so no image rebuild fires — correct, images are unchanged.
- Do **not** bump `Cargo.toml` version or tag: no shipped Rust change beyond the search-connector fix; if the user wants 0.1.8 with the EUR-Lex fix inside the image, that's a separate explicit decision (tag → CI → compose bump).

### Step 7 — Deferred follow-ups (not in this plan's scope)

1. **QM single-stack migration** to `compose.qm.yaml` (upstream `86d8b91`/`84392dd`) — plan separately; it recreates qm containers, so it must be paired with the pi-models re-patch ritual.
2. **Fresh-clone dry-run** of `install.ps1` in a temp dir (repo rule: only valid test for install-path changes) before this bundle goes to the client AIPC.
3. Decide whether `qm.config.jsonc` sandbox digest belongs in a gitignored overlay instead of a tracked file.

---

## Execution log (2026-09-06, completed)

- Steps 1–6 all green. Live stack: `pacgate-ai/*:0.1.7` × 4, deer-flow persistence mount active, admin + 175 checkpoints survived recreate, `kb/search` returns ranked hybrid results (decode fix proven), OpenViking vlm loaded (no OPENAI_API_KEY error), QM core untouched.
- Two upstream commits arrived mid-session (`c69a34e` docs, `0047ee9` GATEWAY_CORS_ORIGINS-from-.env) — both rebased cleanly; live container CORS already equals the new default, so no recreate.
- Pushed: `4facdc2` (EUR-Lex fix), `72b29d8` (qm tasks + plan), `20da94e` (gitignore `data/`).
- **Plan corrections discovered during execution:**
  1. `deploy/client-bundle/data/` was NOT gitignored (the old `.gitignore:45` match was stale). It now holds the LIVE deer-flow DB bind mount — fixed in `20da94e`.
  2. Seed gotcha: `pacgate-seed` defaults to `--tenant-slug default-firm`, but this machine's API runs `PACGATE_DEFAULT_TENANT=pacgate-law` → first seed produced chunks the API couldn't see (`kb/search` → `[]`). Re-seeded with `--tenant-slug pacgate-law`; stray `default-firm` copy purged.
  3. Login response field is `token` (not `access_token`); deer-flow browser session invalidates on backend recreate (JWT secret rotation) — re-login once after upgrades, expected.
  4. `docker exec -d` lost its log here; run `pacgate-seed` synchronously via `docker exec` instead.

## Adversarial self-review (anti-pattern check)

- ❌ "Just `git pull` and `up -d`": rejected — would wipe deer-flow admin (no mount yet at 0.1.3) and silently lose the QM patch. Steps 1/4 handle both.
- ❌ Committing machine-specific sandbox digest: rejected (Step 2.5).
- ⚠️ Remaining unknown: which compose file the live project uses (Step 4 pre-check) and whether `gemma4:12b-it-q8_0` exists on this box (Step 4.5 pre-check). Both are cheap checks inserted at the right point, not assumptions.
- ⚠️ `data/deer-flow/` seeding copies a DB that may be mid-write; Step 1 stops nothing but the `docker cp` of a live SQLite file is the same proven procedure used in the V2 handoff — acceptable, wal/shm deliberately excluded.
