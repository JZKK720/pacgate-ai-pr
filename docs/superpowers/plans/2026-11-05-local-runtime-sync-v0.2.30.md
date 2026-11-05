# Local Runtime Sync to v0.2.30 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring this dev box's running Pacgate stack from 0.1.33 up to the release the tree now pins (0.2.30), close the environment gaps the version jump exposes, and prove the e2e lanes against the new release.

**Architecture:** Two phases, deliberately separated. **Phase A (merge)** is already complete and is history-only: a fast-forward, no rebase, no local commits to replay. **Phase B (runtime)** is the real work, and it is an *environment* migration, not a code migration - the images are published and verified pullable, and the tree's own gates already identify every stale service. Nothing in this plan edits application code.

**Tech Stack:** Docker Compose (client bundle lane), GHCR-published images, Ollama 0.40.14, PostgreSQL 16 + pgvector, PowerShell 7.6, Rust workspace at `pacgate-ai/`.

## Global Constraints

- **Never retag a `ghcr.io/jzkk720/*` image locally.** A local tag that disagrees with the registry digest is exactly what `scripts/test-stack-version-coherence.ps1` and `scripts/verify-delivery-state.ps1` exist to catch.
- **`PACGATE_SANITIZER_KEY` must be set per deployment and must not be shared between client sites.** Unset is not a crash: the sanitizer falls back to a per-process random key, which is safe but silently gives up cross-document token correlation (`pacgate-ai/crates/pacgate-api/src/state.rs`). Treat unset on a live box as a defect to close, not a default to accept.
- **`LAYA_MODELS` must keep both `multilingual` and `english`.** A partial load ships *silently*: compose reports `healthy`, `/health` returns 200, and only the missing language returns 500. See `docs/superpowers/plans/2026-11-02-verification-gaps.md`.
- **Do not mount anything over `/home/laya/.cache/huggingface`.** A bind mount REPLACES the image layer, hiding every baked weight (proven 2026-11-02 in `compose.prod.yaml`).
- **`laya` is behind the `laya` profile.** `docker compose config --images` omits it by design; a pull of the default lane will not fetch it.
- **Migration 009 rewrites `kb_chunks.content_tsv` and its GIN index** (`DROP COLUMN` + `ADD COLUMN GENERATED`). It is applied automatically at API boot and is idempotent. It rewrites the index, not the embeddings - no re-embed is needed, but a large corpus pays a reindex at first boot of the new API.
- Gate exit codes: **0 = pass, 1 = real defect, 2 = CANNOT CHECK**. Exit 2 is never a pass.
- **A fresh clone is the only valid test for install-path changes.** This box accumulates credentials, pulled models, and rendered gitignored configs. Nothing in this plan should be read as proof that a clean AIPC install works.

---

## Verified starting state

Measured on this box before writing the plan, not assumed.

| Claim | Verified result |
|---|---|
| Local `main` was behind upstream | `git status -sb` -> `behind 'origin/main' by 197 commits`, fast-forwardable |
| The merge was safe | `git merge --ff-only origin/main` -> `Updating a43d87c..28d73c4`, exit 0 |
| Working tree survived the merge | only the 13 pre-existing untracked files; none collide with `origin/main` (`git ls-tree` checked per path) |
| Backup point exists | `backup/pre-sync-2026-11-05` -> `a43d87c` |
| Tree version | `pacgate-ai/Cargo.toml` -> `version = "0.2.30"` |
| Running stack version | API `/build-info` -> `0.1.33`; every container label -> `0.1.33` |
| **Stack is stale, per the repo's own gate** | `test-stack-version-coherence.ps1` -> `9 passed, 5 failed`; all 5 release services run `0.1.33` against `0.2.30` pins |
| New images are published and anonymously pullable | token-scoped manifest HEAD on all 6 repos at `0.2.30` -> **HTTP 200** for `pacgate-api`, `deer-flow-pacgate`, `deer-flow-frontend-pacgate`, `pacgate-mcp`, `ocr-service`, `laya-serve` |
| No 0.2.x image was cached locally | `docker images` -> only `:0.1.33` for the five release services |
| Model roster changed upstream | `gemma4:12b-it-qat` retired; `nemotron-3.5-bolt:e4b-q8_0` promoted into LOW. Local `ollama list` still carries `gemma4:12b-it-qat`, and **lacks** `nemotron-3.5-bolt:e4b-q8_0` |
| Roster gates already green on the new tree | `audit-model-tags.ps1` exit 0; `test-model-roster-consistency.ps1` -> `14 of 14 checks passed` |
| Patch parity already green | `test-baked-patch-parity.ps1` -> `11 passed, 0 failed` (B1-B3; B4 skips without the 0.2.8 image) |
| Installer parses on both shells | `check-installer-syntax.ps1` -> `All checked scripts parse cleanly` |
| Compose wiring green | `test-compose-healthchecks.ps1` -> `0 failure(s), 0 skipped` |
| New required env keys | `.env` is missing **`PACGATE_SANITIZER_KEY`** and **`LAYA_MODELS`**. Both are new since `0.1.34` |
| `LAYA_HF_CACHE` is in the "required" list but must stay unset | It appears only in a comment explaining why **not** to mount it |
| Only one new migration | `009_cjk_fulltext.sql`; migrations `001`-`008` already applied, and the runner re-executes all of them idempotently at boot |
| Local corpus is small | `kb_chunks` -> 82 rows; the 009 reindex is effectively instant here |

### What the gates say about scope

Every *static* gate on the new tree is already green. The only red gate is `test-stack-version-coherence.ps1`, and every one of its five failures is the same single fact: the containers are old. That is the whole of Phase B's code-facing risk - the migration is an artifact swap plus three environment lines, not a source change.

---

## File Structure

| Path | Responsibility | Change |
|---|---|---|
| `deploy/client-bundle/.env` | Live deployment config (gitignored) | **Modify** - add `PACGATE_SANITIZER_KEY`, `LAYA_MODELS` |
| `deploy/client-bundle/compose.prod.yaml` | The lane this box runs | Read only - pins 0.2.30 |
| `scripts/test-stack-version-coherence.ps1` | Proves every container matches its pin | Run - the acceptance gate for Task 2 |
| `scripts/smoke-full-stack.ps1` | Live lane smoke | Run - Task 3 |
| `scripts/test-legal-journey.ps1` | Matter -> upload -> OCR -> sanitize -> review -> search -> qm -> recall | Run - Task 4 |

| `docs/superpowers/plans/2026-11-05-local-runtime-sync-v0.2.30.md` | This plan and its measured outcome | Created |

No application source is touched by this plan. If a task appears to need a source edit, stop: that is a defect to file, not a step to improvise.

### One gap this plan found that the gates did not

`audit-model-tags.ps1` and `test-model-roster-consistency.ps1` both read the **roster files** (`.env.example`,
`ollama-models.txt`, the Rust fallbacks, the compose defaults). Neither reads the **live `.env`** on an
existing box. So a machine that was installed before a roster change keeps pointing at the old tags and
both gates stay green - which is exactly how `pacgate-low:latest` (blob-identical to the retired
`gemma4:12b-it-qat`) survived a release change unnoticed. The three lines in Task 1 are the manual
equivalent of what `install.ps1` now does on a fresh install; on an existing box nothing else does it.
Worth a gate, but it is a separate change and deliberately not folded in here.

---

## Task 1: Close the environment gaps before swapping images

The `.env` gaps are cheap to fix and expensive to discover later, and two of them are silent-failure classes. Fix them while the old stack is still running, so the new stack boots correct.

- [ ] **Step 1: Generate a deployment-local sanitizer key**

```powershell
cd deploy/client-bundle
$key = -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
Add-Content -Path .env -Value "`n# Sanitizer token key: stable per deployment, never shared between sites." -NoNewline:$false
Add-Content -Path .env -Value "PACGATE_SANITIZER_KEY=$key" -NoNewline:$false
```

Do **not** copy `.env.example`'s `change-me-to-a-random-hex-string` literal into a live file. It would satisfy "set" while providing no key material at all.

- [ ] **Step 2: Add the laya model pin**

```powershell
Add-Content -Path .env -Value "LAYA_MODELS=multilingual,english" -NoNewline:$false
```

Both checkpoints, deliberately. See the constraint above.

- [ ] **Step 3: Verify both keys are now present and no BOM was written**

```powershell
foreach ($k in 'PACGATE_SANITIZER_KEY','LAYA_MODELS') {
    $hit = Select-String -Path .env -Pattern "^$k="
    if ($hit) { "OK   $k" } else { "MISS $k" }
}
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path .env))
"first bytes: $($bytes[0..2] -join ',')"   # must NOT be 239,187,191
```

`docker compose` rejects a BOM in `.env`. The expected output is `OK` twice and any first-byte triple other than `239,187,191`.

- [ ] **Step 4: Confirm the laya cache is NOT configured**

```powershell
if (Select-String -Path .env -Pattern '^LAYA_HF_CACHE=') { 'FAIL - this hides the baked weights' } else { 'OK - no laya mount' }
```

---

## Task 2: Swap all five release services onto 0.2.30

- [ ] **Step 1: Make every 0.2.30 image local**

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml pull
docker pull ghcr.io/jzkk720/laya-serve:0.2.30   # profile-gated; the lane pull skips it
docker images --format '{{.Repository}}:{{.Tag}}' | Select-String '0\.2\.30'
```

The registry was intermittently failing with `TLS handshake timeout` and a one-off `lookup ghcr.io: no such host` during this task. A failed pull leaves completed layers cached, so **retry the same command** rather than assuming the tag or visibility is wrong. Visibility is already proven (HTTP 200 above). If it fails repeatedly, run `pwsh -File scripts/preflight-docker-egress.ps1` and believe its host-vs-docker verdict.

Expected: six `0.2.30` tags, including `laya-serve`.

- [ ] **Step 2: Record the pre-swap evidence**

```powershell
docker ps -a --format '{{.Names}}|{{.Image}}' | Select-String 'pacgate|deer-flow|ocr-service|openviking' |
    Out-File "$env:TEMP\pre-swap-images.txt"
docker exec pacgate-db psql -U pacgate -d pacgate -c 'SELECT count(*) FROM kb_chunks;'
```

Cheap, and it is what lets Task 2 Step 4 distinguish "the new API broke" from "it was already like that".

- [ ] **Step 3: Recreate every release service on the new pin**

```powershell
docker compose -f compose.prod.yaml up -d --force-recreate pacgate-api pacgate-mcp ocr-service deer-flow deer-flow-frontend
```

`--force-recreate` matters: a changed bind-mounted file does not trigger a recreate, and most of these services bind-mount their code, so a plain `up -d` can leave the old container running against new files. The API applies migration 009 at boot.

- [ ] **Step 4: Prove the swap with the repo's own gate**

```powershell
cd ..\..
pwsh -NoProfile -File scripts/test-stack-version-coherence.ps1
```

Expected: **17 passed, 0 failed**, and the "MIXED STACK" block absent. Re-running this gate is the whole acceptance criterion for the task - a green summary line anywhere else does not substitute for it.

- [ ] **Step 5: Confirm the migration landed and the corpus still resolves**

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -c "SELECT indexname FROM pg_indexes WHERE indexname='idx_kb_chunks_content_tsv';"
docker exec pacgate-db psql -U pacgate -d pacgate -c "SELECT count(*) FROM kb_chunks;"
docker logs pacgate-api --tail 40 | Select-String 'RAG migrations applied|009'
```

Expected: the index exists, the chunk count is unchanged from Step 2, and the log line names `009_cjk_fulltext`.

- [ ] **Step 6: Pull the LOW-tier model the new roster requires**

```powershell
ollama pull nemotron-3.5-bolt:e4b-q8_0
```

The running box predates the roster change and does not have this tag. Without it, LOW-tier and the
`deer-flow` default agent model both 404 - see "Why the model pull did not finish" in the Outcome.

- [ ] **Step 7: Prove the agent tool loop actually calls a tool**

```powershell
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1
```

This must report `0 failed`. It cannot pass any other way: the gate now requires a structured
`tool_calls` record naming an advertised tool, and fails on `deerflow_error_fallback`. Before this session
it reported `5 passed, 0 failed` on a 404'ing model, so treat any future green here as meaningful only
because of that fix.

---

## Task 3: Smoke the live lanes

- [ ] **Step 1: Run the full-stack smoke**

```powershell
cd C:\Users\1\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/smoke-full-stack.ps1
```

It derives the expected version from `pacgate-ai/Cargo.toml`, so it is `0.2.30` on this tree. Exit 0 means every reachable lane passed. Exit 2 means not runnable - read the named reason, do not treat it as success.

- [ ] **Step 2: Confirm the two surfaces that changed most**

```powershell
curl.exe -s http://localhost:8089/pacgate/build-info
curl.exe -s -o NUL -w '%{http_code}' http://localhost:11434/api/tags
```

Expected `"version":"0.2.30"`, and HTTP 200 from Ollama.

---

## Task 4: Prove the legal journey, including CJK keyword search

Migration 009 exists because the keyword half of hybrid search matched **zero** Chinese chunks. That makes a Chinese keyword lookup the single most valuable assertion on this box, and the least likely to be covered by a generic smoke.

- [ ] **Step 1: Run the journey**

```powershell
pwsh -NoProfile -File scripts/test-legal-journey.ps1 -KeepArtifacts
```

Exit 0 = whole journey passed. Exit 1 = a step failed (the script fails loudly on the first broken step, deliberately). Exit 2 = could not check; the script prints the exact reason and this must not be reported as green.

- [ ] **Step 2: Re-test the exact defect 009 fixed, against the live database**

```powershell
docker exec pacgate-db psql -U pacgate -d pacgate -c @"
SELECT count(*) FROM kb_chunks
WHERE content_tsv @@ cjk_tsquery('质保金');
"@
```

`cjk_tsquery` is created by 009. A non-zero count on a Chinese corpus is the evidence; `plainto_tsquery` returning 0 was the pre-009 bug.

---

## Task 5: Record the outcome

- [x] **Step 1: Update the evidence table with the measured results.** See "Outcome" below.
- [ ] **Step 2: Leave the `gemma4:12b-it-qat` local model alone.** It is retired from the roster, not from disk. Deleting it is a separate, reversible-by-re-pull cleanup and is not part of proving the release.

---

## Outcome (measured 2026-11-05)

| Check | Before | After |
|---|---|---|
| `test-stack-version-coherence.ps1` | `9 passed, 5 failed` | **`14 passed, 0 failed`** |
| `smoke-full-stack.ps1` | n/a (0.1.33) | **20 passed, 0 failed, 1 skipped** (agent->MCP lane defers to the dedicated gate) |
| `test-agent-mcp-e2e.ps1` | not run | **3 passed, 3 FAILED (exit 1)** - and that is the correct answer; see the false-green note below |
| `test-legal-journey.ps1` | not run | **19 assertions, PASSED** - matter, workflow library (222), upload, OCR, sanitize (`verdict=pass`), review gate, internal + external search, deer-flow auth, qm, OpenViking recall |
| `verify-delivery-state.ps1` | n/a | **ALL CHECKS PASSED** - all 5 images anonymous-pullable 200 |
| API `/build-info` | `0.1.33` | **`0.2.30`**, revision `436d41ee` |
| Migration 009 | absent | **applied**; `cjk_tsquery` exists; `content_tsv` regenerated with the Han-splitting expression; `kb_chunks` still 82 rows |
| CJK keyword search | `to_tsvector('english', ...)` | `附录` -> **18 chunks**, `数据模型` -> **10**, `Mermaid` -> **10** |
| `PACGATE_SANITIZER_KEY` | absent | **set, 64 hex chars, confirmed inside the container** |
| `PACGATE_MODEL_LOW` | `pacgate-low:latest` (= retired `gemma4:12b-it-qat` by blob hash) | `nemotron-3.5-bolt:e4b-q8_0` |
| `PACGATE_MODEL_MID` | `pacgate-mid:latest` (duplicate name for `ornith-1.5:9b`) | `ornith-1.5:9b` |
| OpenViking VLM | `gemma4:12b-it-qat` (retired) | `nemotron-3.5-bolt:e4b-q8_0` |

`test-release-provenance.ps1` exits **2 (CANNOT CHECK)**, not 1: four of six registry reads hit the
script's own 20 s `HttpClient` timeout. The same property was proven independently by
`verify-delivery-state.ps1` (HTTP 200 on all five). Not a release defect - a network-timing artefact
of this session, which also produced `TLS handshake timeout` and one `no such host` during the pulls.

### Still outstanding

| Item | State |
|---|---|
| `nemotron-3.5-bolt:e4b-q8_0` on disk | **NOT pulled.** See below - this is the one item that leaves a real lane red. |
| `laya-serve:0.2.30` image | **NOT pulled.** Profile-gated; nothing depends on it unless `--profile laya` is enabled, and laya is opt-in. |
| Clean-clone install proof | **NOT done, by design.** This box has 28 h of accumulated state; only a fresh AIPC clone can prove the installer path. |

### A false-green gate, found and fixed

`scripts/test-agent-mcp-e2e.ps1` reported **5 passed, 0 failed** twice on a lane where the agent model was
**404ing**. The cause was E3: it scanned the whole serialized payload for an advertised tool name, and the
gate's *own prompt* ("Call the `pacgate_list_connectors` tool...") is echoed back in the human message. It
matched its own prompt. Proven by decoding the `/runs/wait` payload:

```
message[0] human  - system-reminder
message[1] human  - "...Call the pacgate_list_connectors tool..."   <- the match
message[2] ai     - "LLM request failed: Error code: 404 ... model 'nemotron-3.5-bolt:e4b-q8_0' not found"
                    deerflow_error_fallback: true, tool_call_ids: []
```

No assistant `tool_calls`, no tool-role message. The gate was green for the same reason it was green during
the 0.1.33 era: the assertion could not tell "the agent called a tool" from "the word appears somewhere".

Fixed in this session: E3 now reads `tool_calls` only from non-human messages and requires the name to be an
advertised tool; a new **E2b** fails on `deerflow_error_fallback`; E4 is a boolean over structured records
rather than a substring scan. Red-checked: the fixed gate now reports
`3 passed, 3 failed` with the 404 named, where it previously said `5 passed, 0 failed`.

This matters beyond this box: **any** stack with a missing model tag produced a green agent-gate. The
release's claim that the agent tool loop works was resting on an assertion that could not fail in that way.

### Why the model pull did not finish

The transfer is impaired at the network layer, not at the tag or the registry:

| Evidence | Value |
|---|---|
| Manifest `nemotron-3.5-bolt:e4b-q8_0` layers | model 7659.19 MB, projector 945.62 MB, draft 702.68 MB |
| Model layer on disk | **7659.19 MB - complete** |
| Projector / draft layers | **absent**; all 16 `-partial` siblings are 0 bytes |
| Direct blob GET, first try | `http=200` but only **17.22 MB** of 945 MB (truncated) |
| Direct blob GET, resumed (`-C -`) | `206`; 48.85 -> 66.82 -> 72.09 MB across 3 attempts |
| Ollama's own pulls | two runs returned `200` after 13m50s and 46m10s without finalising |

Sustained throughput is roughly 0.1 MB/s with frequent mid-stream truncation, so ~1.6 GB of remaining
layers is hours of transfer. Nothing about the tag, the registry, or the release is wrong - the earlier
GHCR pulls hit the same class of fault (`TLS handshake timeout`, one `lookup ghcr.io: no such host`) and
only succeeded on retry.

Measured at the end of the session with a bounded ranged GET against the registry:

```
curl -s -L -r 0-5242879 (5 MiB range), 60 s cap
  -> http=206, got=647,168 B, speed=10,781 B/s
```

**10.7 KB/s.** The two missing layers total 1,648 MB, which is ~42 hours at that rate. No proxy is
involved (`ProxyEnable=0`, no `HTTP(S)_PROXY`), and TCP 443 to `registry.ollama.ai` connects, so this is
plain end-to-end degradation on this host's uplink - not the proxy trap `preflight-docker-egress.ps1`
documents, and not something a retry loop fixes.

**Consequence:** the deer-flow default agent model and the `PACGATE_MODEL_LOW` tier both 404 on this box
until those two layers land. Every other lane is verified. To finish:

```powershell
ollama pull nemotron-3.5-bolt:e4b-q8_0     # resume; already-complete layers are skipped
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1   # must show 0 failed
```

Do **not** work around this by pointing the tier at `ornith-1.5:9b`, `gemma4:12b-it-qat`, or the 24 GB
`nemotron-3.5-bolt:74b-a9b-iq2` that is already on disk. The roster gate asserts Main and Mid are distinct
models for a reason, and quietly re-pointing LOW would hide the gap instead of closing it. If the transfer
cannot be completed on this host, the correct move is to stage the model from a machine with usable
bandwidth (`ollama push`/`pull` between hosts, or copy `~/.ollama/models`), not to change the roster.

---

## Out of scope, and why

| Thing | Why not here |
|---|---|
| Rebuilding any image | All six are published and pullable; a local build would create a tag that disagrees with the registry digest |
| Running `install.ps1 -Update` | It fast-forward-pulls a repo this box is already on at the tip, and it is the *client* path. The compose recreate is narrower and reversible; the installer's behaviour on a fresh clone is a separate verification |
| `git reset --hard` anywhere | Uncommitted work in the tree; the repository's own plans record that this destroyed a fix on 2026-11-01 |
| Fixing `hermes-gateway` (unhealthy, up 26h) | Unrelated to the Pacgate release and pre-existing |
| Pruning the 0.1.33 images | Keeps the rollback cheap until the e2e is green |

## Rollback

```powershell
# Runtime: one command back to the previous release, images still local
docker compose -f deploy/client-bundle/compose.prod.yaml up -d --force-recreate `
    pacgate-api pacgate-mcp ocr-service deer-flow deer-flow-frontend

# History: nothing to undo - the merge was a fast-forward
git log --oneline -1 backup/pre-sync-2026-11-05
```

Migration 009 is additive-with-rewrite: it drops and re-adds a generated column. Reverting the *image* leaves the new `content_tsv` expression in place, which the old API does not read. That is safe, and it is why the rollback above needs no SQL.
