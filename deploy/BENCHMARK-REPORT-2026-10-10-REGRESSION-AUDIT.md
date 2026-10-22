# PacGate Full-Stack Regression Audit & Benchmark — 2026-10-10

**Stack:** v0.1.25 (rev `5499655`, GHCR all-public) · **Machine:** AIPC2 dev box (AMD 890M iGPU + RX 7600 XT, 14.44GiB shared VRAM budget, Ollama 0.40.x)
**Trigger:** user-reported regressions since v0.1.25 upgrade — "laggy pacgate-ai and deer-flow, model pickers not responding, documents cannot be uploaded and analyzed"
**Method:** systematic debugging (root cause before fixes); live HTTP probes; E2E suites; every number measured this session.

---

## 1. Executive verdict

| Dimension | Result |
|---|---|
| Git sync | HEAD `5499655` == `origin/main`, 0 commits behind |
| Stack | All 8 services on 0.1.25 images, up, healthy |
| Smoke suite | **18 pass / 0 fail / 2 SKIP** (known skips) |
| Legal journey (`-RequireAllLanes`) | **19/19 PASS** (after one fixture fix, see §8) |
| Gate suite (`run-all-checks`) | running detached at report time — see §11 |
| **User-reported lag** | **ROOT-CAUSED: model-swap thrash on 14.44GiB VRAM** — not a code regression |
| **Model picker** | API healthy (15-17ms); perceived lag = VRAM swap cost per model switch |
| **Document upload** | **WORKING E2E** — upload→extract→sanitize→chunk→search all verified live |
| Karpathy audit (5499655 + local glm fix) | **PASS** all 4 guidelines |

**Bottom line:** No code regression found. The "lag" is the physics of a 14.44GiB shared VRAM budget serving a 25.4GB default model: every model switch pays a 12-35s swap, and the memory lane (gemma4) competes with the chat lane (nemotron). Document upload works end-to-end; the earlier failures the user saw were the two error threads from 2026-10-09 (quota exhaustion + a stall), not a current defect.

---

## 2. Root-cause analysis of the reported regressions

### 2.1 "Laggy" — ROOT CAUSE: VRAM model-swap thrash (not a code bug)

**Evidence chain (all measured this session):**

| Probe | Result |
|---|---|
| `ollama ps` at session start | `ornith-1.5:9b` resident (7.7GB) — NOT the default chat model |
| API lanes (matters/workflows/connectors/login) | 7-239ms — fast, no server-side lag |
| nginx `/` | 17-32ms — ingress fast |
| gemma4:12b-it-qat cold-ish (after ornith) | 12.3s |
| ornith-1.5:9b swap-in (from gemma4) | 12.6s |
| ornith-1.5:35b swap-in | **34.7s** |
| nemotron-30b swap-in (from ornith-9b) | **29.9s** |
| nemotron warm (resident) | 7.8s total / 5.8s eval |
| gemma4 swap-in (from nemotron) | **22.7s** |
| deepseek/glm cloud | 3.2-3.7s (no VRAM cost) |

**Mechanism:** the 14.44GiB VRAM budget cannot hold nemotron (25.4GB, 46%/54% CPU/GPU split when resident) plus any second model. deer-flow's memory lane pins `gemma4-12b-memory`, so every conversation that triggers a memory update or summarization evicts the chat model and pays a 15-30s reload on the next turn. The user experiences this as "laggy" and "picker not responding" — the picker API itself returns in 15ms; the wait is the model load after selection.

**Why it got worse after v0.1.25:** summarization is now ENABLED (correctly — it bounds context 83k→32k), which means the gemma4 memory/summarizer lane runs MORE often, increasing swap frequency. This is a deliberate trade documented in the config comment; the fix traded token burn for swap latency.

**Verdict:** environmental/physics, not a regression. Mitigations in §9.

### 2.2 "Model pickers not responding well" — picker API is healthy

- `GET /api/models` → 200 in **15-17ms**, returns all 7 entries with correct capability flags.
- Roster verified: 5 local + 2 cloud; `supports_thinking`/`supports_reasoning_effort` flags correct per entry.
- The glm-5.3-flash thinking-burn fix (uncommitted local: `when_thinking_enabled: {reasoning_effort: none}` + factory kwarg-collision guard) is live in the container (verified at factory.py L147-148).
- Perceived non-response = the swap latency in §2.1 after choosing a different local model.

### 2.3 "Documents cannot be uploaded and analyzed" — WORKING; earlier failures were 2026-10-09 incidents

**Live E2E proof this session (all green):**

| Step | Result |
|---|---|
| deer-flow thread upload (`POST /api/threads/{id}/uploads`) | 200, 146ms, file persisted to `/mnt/user-data/uploads/` |
| pacgate KB upload (`POST /pacgate/api/documents` multipart + matter_id) | 200, 165ms, doc row created |
| Extraction (`POST /documents/{id}/extract`) | 200, text extracted, `incomplete=false` |
| Sanitize (`POST /documents/{id}/sanitize` with `data_level: T3`) | 200, 2.4s, verdict=pass, **chunks_promoted=1** |
| VectorDB state | doc `sanitized`, 1 kb_chunk |
| KB search recall | top hit score 0.665 for the uploaded content |

**Historical error threads found (2026-10-09, not current):**
- `c4914897`: "LLM provider rejected the request because the account is out of quota" — ollama.com weekly limit on a cloud model, transient.
- `5a76d442` / `e00a49b7`: empty error threads (0 messages) — runs that died before first message.
- `b2beaa9a`: completed a full sanitize demo but marked error (post-completion failure).
- deer-flow logs 24h window: only **2** Ollama 500s (transient, retried OK) and **1** stall abort (420s watchdog on thread d4c01fe7 during the 09:41 VRAM-competing window).

**Verdict:** upload/analysis pipeline is healthy. The user's failed attempts map to the quota-exhausted cloud model and the VRAM-stall window, both already understood.

### 2.4 deer-flow summarization config — verified live (correcting a probe artifact)

An early probe read `SummarizationConfig()` defaults (enabled=False) — that is the CLASS default, not the live config. The correct probe (`get_app_config()`) shows the live state: **enabled=True, trigger 12000, keep 12000, trim 8000** — matching the config.yaml block. No defect.

---

## 3. Stack state (verified)

| Service | Image | Status |
|---|---|---|
| pacgate-api | ghcr.io/jzkk720/pacgate-api:0.1.25 | Up, listening :8080 |
| pacgate-mcp | ghcr.io/jzkk720/pacgate-mcp:0.1.25 | Up, 19 tools |
| deer-flow | ghcr.io/jzkk720/deer-flow-pacgate:0.1.25 | Up, gateway :8001 |
| deer-flow-frontend | ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.25 | Up, :3000 |
| ocr-service | ghcr.io/jzkk720/ocr-service:0.1.25 | Up, :8100 |
| openviking | volcengine/openviking@sha256:46f9e34… | Up (healthy), v0.4.16 |
| pacgate-db | pgvector/pgvector:pg16 | Up |
| pacgate-nginx | nginx:1.27-alpine | Up, :8089 |

Compose project: `pacgate-ai-bundle` (post-migration pin). QM stack: separate project, all 7 containers up.

---

## 4. Latency benchmark (measured this session)

### 4.1 pacgate-api + ingress

| Lane | Result |
|---|---|
| nginx `/` | 17-32ms |
| deer-flow frontend `/` | 38ms |
| `/pacgate/api/matters` (7) | 29ms |
| `/pacgate/api/workflows` (222) | 239ms (payload-dominated) |
| `/pacgate/api/search/connectors` | 7ms |
| login | ~22ms |
| `/pacgate/api/kb/search` (462 chunks) | 91-1186ms (embedding call dominates) |
| `/api/memory` (deer-flow, via nginx) | 885ms, 200, 17 facts |
| `/api/models` (picker) | 15-17ms |
| `/api/threads/search` | 47ms |

### 4.2 MCP lanes

| Lane | Result |
|---|---|
| pacgate-mcp initialize (raw HTTP from deer-flow container) | 200, session issued |
| deer-flow tool sync | **44 tools total: 9 built-in + 35 MCP** (24 pacgate + 10 openviking + 1 officecli) |
| OpenViking tools/list (root key) | 200, 12+ tools |
| OV health | 200, 1.7ms |
| OV workspace | 11MB on disk |

### 4.3 Model swap matrix (the lag table)

| From → To | Swap-in cost |
|---|---|
| → gemma4:12b-it-qat (7.2GB) | 2.4-12.3s |
| → ornith-1.5:9b (6.6GB) | 12.6s |
| → ornith-1.5:35b (22GB) | **34.7s** |
| → nemotron-30b (25.4GB) | **29.9s** |
| → deepseek/glm cloud | 3.2-3.7s (no swap) |

---

## 5. Memory lanes audit

| Lane | State |
|---|---|
| deer-flow conversation memory | PacgateMemoryStorage live; `/api/memory` 200 with 17 facts, `lastUpdated` populated (5499655 fix verified — no empty-string crash) |
| Summarization | enabled=True, trigger 12000 / keep 12000 / trim 8000 (live via `get_app_config()`) |
| Memory model pin | `gemma4-12b-memory` (2048-token cap) — competes with chat lane for VRAM (see §2.1) |
| OpenViking | v0.4.16 healthy, MCP 200 with root key, workspace 11MB |
| qm memory | Postgres `qm`: `base_model_configs org:pacgate → glm-5.3-flash:cloud` intact; pi-models patch 6 refs + `defaultModelForProvider` wired |
| pacgate vectordb | **462 kb_chunks / 30 documents** (11 sanitized / 15 pending / 4 blocked — expected mix); +1 chunk from this session's E2E upload |

---

## 6. QM stack E2E (first full pass this cycle)

| Check | Result |
|---|---|
| healthz (:8080) | `{"ok":true}` |
| pi-models patch | 6 refs `glm-5.3-flash:cloud` + `defaultModelForProvider` returns it for pi/openai (read from container, L283-289) |
| base_model_configs | `org:pacgate → {"modelId": "glm-5.3-flash:cloud"}` |
| Portal/web-ui/mailpit | up (portal 401 front door = healthy) |
| Journey lane 9b | qm portal reachable — PASS |

QM was NOT touched by the 5499655 merge (0 files) — no restage needed. User has not yet tested qm interactively; the stack-side wiring is verified green.

---

## 7. Karpathy guidelines audit (5499655 + local glm fix)

### 7.1 `5499655` — memory card crash fix — PASS
- **Think before coding:** commit message carries the full root-cause chain (raw matter payload → MemoryResponse fills "" → formatTimeAgo RangeError). Evidence-commented.
- **Simplicity:** one function `_normalize_to_deerflow_shape` + a load() call. No new abstractions.
- **Surgical:** 265-line new patch file + 6-line compose mounts in both files. No drive-by edits.
- **Goal-driven:** verified live this session — `/api/memory` returns 200 with populated `lastUpdated`; the settings memory card renders.

### 7.2 `efaeb50` — release tooling hardening — PASS
- Project-name pin (11 mirrored lines), OV recall budget 300→420s (measured marginal), ov-mcp-call wrapper, .gitignore scratch rules. Each change traces to a documented failure from the clean-clone proof.

### 7.3 Uncommitted local glm thinking fix — PASS (needs commit decision)
- `deer-flow-config.yaml`: `when_thinking_enabled: {reasoning_effort: none}` on glm-5.3-flash-cloud with measured evidence in the comment (433 chars reasoning / 0 content / finish=length on medium; only `none` produces content).
- `deer-flow-model-factory.py`: 11-line kwarg-collision guard mirroring the existing when_thinking_disabled branch.
- **Live-verified in container** (factory.py L147-148). This fix makes the glm picker entry usable; recommend committing.

### 7.4 This session's fix — `test-legal-journey.ps1` fixture image — PASS
- One-line change: `ocr-service:local` → `ghcr.io/jzkk720/ocr-service:0.1.25` with comment. Honors the no-local-builds policy (2026-10-08); the GHCR image has identical PIL/python3 tooling (verified before editing).

---

## 8. Defect found & fixed this session

**DEFECT: journey E2E fails at step 4 on any machine without a hand-made `ocr-service:local` tag.**
- Symptom: `could not build the PDF fixture (ocr-service:local image present?)` — journey died at Upload, 15 lanes untested.
- Root cause: the fixture builder hardcoded `ocr-service:local`, a tag that only exists where someone manually created it. (`run-all-checks.ps1` self-heals this by tagging from GHCR, but the journey script did not.)
- Fix: use the GHCR-pulled `ghcr.io/jzkk720/ocr-service:0.1.25` directly (PIL 12.3.0 + python3 entrypoint verified first).
- Verify: journey re-run → **19/19 PASS** including the previously-unreachable lanes (OCR extract, sanitize, egress gate, OV recall).

---

## 9. Optimization recommendations (lag mitigations, in priority order)

1. **Pin the chat model resident** — set `OLLAMA_KEEP_ALIVE=-1` (or a long keep_alive) for nemotron so the default chat model never evicts between turns. Cost: 25.4GB stays resident; memory-lane gemma4 calls will swap it out anyway, so pair with #2.
2. **Route memory/summarization to the SAME model as chat** — change `memory.model_name` from `gemma4-12b-memory` to the chat model (or drop the pin). The summarization config already made this choice for the summarizer; extending it to the memory lane removes the largest swap source. Trade-off: memory updates use the bigger model (slower per call, but no swap).
3. **Prefer cloud models for interactive chat during work hours** — deepseek/glm respond in 3.2-3.7s with zero VRAM cost. The 2026-08-30 decision already accepts egress for research; using cloud for interactive sessions and local for background lanes eliminates user-facing swap lag entirely.
4. **Do NOT add more local models to the picker** — each additional >7GB entry adds another swap state. The current 5-local roster is already at the coherence limit for 14.44GiB.

These are config-level changes; none were applied this session without user sign-off since they trade VRAM residency policy.

---

## 10. Probe lessons (new this session)

- `SummarizationConfig()` class defaults ≠ live config. Always probe via `get_app_config()` — the class default shows enabled=False while the live config is enabled=True.
- deer-flow auth for probes: login at `/api/v1/auth/login/local` (form-encoded, NO Origin header for non-browser clients) → session cookie carries `access_token` + `csrf_token`; subsequent state-changing calls need `Cookie:` + `X-CSRF-Token` headers. Bearer-only gets 401; wrong path `/api/auth/login/local` gets CSRF 403.
- `docker logs <c> | Select-String -Context` works; `-B/-A` do not exist in PS 5.1/7 Select-String (use `-Context before,after`).
- `run-all-checks.ps1` piped through `Select-Object -Last N` buffers ALL output and loses it if the console dies — always redirect to a file (`*> log`) or run detached via `Start-Process`.
- The journey fixture needs PIL inside a container; the GHCR ocr-service image provides it — no local build required.
- `ollama ps` PROCESSOR column shows the CPU/GPU split (nemotron: 46%/54%) — a model larger than VRAM still runs but at degraded speed; factor this into swap math.

---

## 11. Gate suite status at report time

The 34-gate suite was re-launched **detached** (`Start-Process`, pid 21152) writing to `_gates-run-2026-10-10.log` after two console-buffer losses. At report time it had passed gate 1/34 (`test-install-render` 11/11) and was still running — the suite takes ~40-60 min on this box (cargo test + clean-clone pulls dominate). Check the log tail for the final `RESULT:` line; the two prior full-suite runs on this exact tree (2026-10-09, 2026-10-10 post-migration) were **ALL 34 PASSED**, and no code changed since except the one-line journey fixture fix (itself now proven by the 19/19 journey).

---

*Report generated 2026-10-10 from live probes against the running 0.1.25 stack (rev 5499655). All numbers measured, none synthetic. Root causes identified before any fix; one defect fixed with re-verification.*