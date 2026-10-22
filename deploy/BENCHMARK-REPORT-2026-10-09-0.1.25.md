# PacGate Full-Stack Benchmark & Audit Report — 2026-10-09

**Stack:** v0.1.25 (rev `003a4f9`, GHCR all-public) · **Machine:** dev box (8060S iGPU, 14.44GiB shared VRAM budget, Ollama 0.40.x)
**Method:** live HTTP against the running stack; median of 3 passes for API lanes; model timings measured warm on the iGPU; all suites executed this session.

---

## 1. Executive verdict

| Dimension | Result |
|---|---|
| Stack version | **All 5 versioned services on 0.1.25** (pacgate-api rev `003a4f9` confirmed via `/version`) |
| Smoke suite | **18 pass / 0 fail / 2 SKIP** (both skips known-covered by journey lanes) |
| Legal journey (`-RequireAllLanes`) | **19/19 PASS** incl. OpenViking MCP write→recall round trip |
| Gate suite (`run-all-checks`) | **ALL 34 GATES PASSED** (exit 0) |
| Karpathy audit of v0.1.25 changes | **PASS** — all 4 guidelines hold; findings below |
| qm-pacgate re-audit | **GREEN** — health, patches, env parity, memory lane all verified |
| Wire-up | login OK · 7 matters · **222 workflows** · 10 connectors · **19 MCP tools** |

**Bottom line:** the 0.1.25 stack is fully green E2E, the upstream fixes are verified live in the containers, and no regressions were found in the Karpathy audit.

---

## 2. Karpathy guidelines audit (v0.1.25 changes)

Audited commits: `366545d` (compose patch mounts), `140a2ae` (nginx memory route), `dd7f4f0`/`dd3887b` (frontend memory route), `b3ba91e` (release staging), plus the two new patches and the summarization config.

### 2.1 Think Before Coding — PASS
- Every fix commit carries a root-cause comment with measured evidence (e.g. the summarization block documents the 83k→32k input bound and the 65536-token ctx-slot stall analysis; the nginx block documents the GBK mojibake failure mode and the exact `nginx -t` error).
- The compose fix (`366545d`) was driven by a mechanical check (`verify-surviving-components`: 16 patch files vs 14 mounts), not guesswork.

### 2.2 Simplicity First — PASS
- `deer-flow-tool-policy.py`: the entire fix is one function (`_tool_matches_declaration`) — exact match or normalized underscore-prefix. No config surface, no new abstractions.
- `deer-flow-skill-storage.py`: the fixture exclusion is a single `if "evals/fixtures" not in s.relative_path.as_posix()` guard inside the existing discovery loop.
- Summarization config: 8 lines of YAML, no model pin (deliberately avoids VRAM swap).

### 2.3 Surgical Changes — PASS
- `366545d` adds exactly 11 lines to `compose.prod.yaml`, mirrored verbatim from the bundle block. No drive-by edits.
- `140a2ae` touches only the broken `set` line plus its comment; the rest of the block is unchanged.
- Frontend route files are additive (new files under `deploy/frontend-patches/files/`), no modification of upstream source.

### 2.4 Goal-Driven Execution — PASS
- All three fixes have verifiable acceptance criteria that were checked live this session:
  - tool-policy patch present in container (`grep -c 'normalized = declaration.replace'` = 1)
  - skill-storage exclusion present (`grep -c 'evals/fixtures'` = 3)
  - summarization parses live: `enabled: True | trigger: [{'type': 'tokens', 'value': 12000}] | keep: {'type': 'tokens', 'value': 12000}`
  - nginx `-t` passes; `/api/memory` returns **401** (auth required — the healthy state; was 500 ECONNREFUSED before the fix)
  - frontend compiled chunk contains the fallback chain `DEER_FLOW_INTERNAL_GATEWAY_BASE_URL ?? NEXT_PUBLIC_BACKEND_BASE_URL ?? 127.0.0.1:8001`, and the container env sets `DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=http://deer-flow:8001`

**One observation (not a defect):** `dd7f4f0` and `dd3887b` are duplicate commits with identical messages (the `[...path]` route and the base route were committed separately). Harmless; noted for history hygiene.

---

## 3. E2E suite results (this session)

| Suite | Result | Notes |
|---|---|---|
| `smoke-full-stack.ps1` | 18 pass / 0 fail / 2 SKIP | skips: agent→MCP invocation (needs session), OV MCP 401 (covered by journey lane 10) |
| `test-legal-journey.ps1 -RequireAllLanes` | **19/19** | incl. sanitize verdict=pass, egress gate, 140 external results, OV recall round trip |
| `run-all-checks.ps1` | **ALL 34 GATES PASSED** | exit 0; includes install-render 11/11, repo-pull 29/29, update-e2e 28/28, scheduled-update 38/38, workflow-namespace 42/42, chat-no-auto-egress 12/12, roster 13/13 |

---

## 4. Latency benchmark (median of 3, measured from inside the compose network)

### 4.1 pacgate-api + ingress lanes

| Lane | Median | Notes |
|---|---|---|
| `/version` | 1.1 ms | |
| `/pacgate/api/matters` (7) | 3.1 ms | |
| `/pacgate/api/search/connectors` (10) | 2.3 ms | |
| `/pacgate/api/workflows` (222) | 41.7 ms | payload-dominated |
| login (`/pacgate/api/auth/login`) | 21.8 ms | argon2 verify dominates |
| nginx `/` | 62.9 ms | frontend proxy hop |
| deer-flow frontend `/` | 15.2 ms | |
| qm portal front door | 6.7 ms | 401 = healthy auth gate |

### 4.2 MCP bridge (pacgate-mcp:8000, streamable HTTP)

| Lane | Median | Notes |
|---|---|---|
| initialize + tools/list | 12.7 ms | **19 tools** listed |

Tool roster (19): `pacgate_connector_search`, `pacgate_convert_document`, `pacgate_execute_workflow`, `pacgate_get_workflow`, `pacgate_get_workspace`, `pacgate_kb_search`, `pacgate_list_connectors`, `pacgate_list_documents`, `pacgate_list_matters`, `pacgate_list_workflows`, `pacgate_ocr_batch`, `pacgate_ocr_document`, `pacgate_read_document`, `pacgate_read_memory`, `pacgate_sanitize_document`, `pacgate_sanitize_text`, `pacgate_upload_document`, `pacgate_verify_sanitized`, `pacgate_write_memory`.

### 4.3 deer-flow MCP server registry (extensions config)

| Server | Type | Endpoint | Status |
|---|---|---|---|
| openviking | http | `http://openviking:1933/mcp` (root key header) | initialize **200** |
| pacgate | http | `http://pacgate-mcp:8000/mcp` | initialize 200 (19 tools) |
| officecli | stdio | `officecli mcp` | baked into image 0.1.10+ |

---

## 5. Model benchmark (iGPU, warm)

| Model | Size | Warm latency | Notes |
|---|---|---|---|
| gemma4:12b-it-q8_0 | 12.8 GB | 2.6 s (dedicated) / 22.9 s (after nemotron loaded) | VRAM swap cost visible |
| nemotron-3.5-lightning:30b-a3b | 25.4 GB | 32.4 s first call (load) → 2.5 s warm | |
| nomic-embed-text | 0.3 GB | 2.1–3.2 s per embed call | embedding lane |
| deepseek-v4.1-flash:cloud / glm-5.3-flash:cloud | 0 GB (cloud) | n/a | intentional egress per 2026-08-30 decision |

**Local roster on disk:** qwen3.8:27b-mtp-q4_K_M (17.7GB), gemma4:12b-it-qat (7.2GB), gemma4:12b-it-q8_0 (12.8GB), gemma4:e4b-it-qat (6.1GB), nemotron-3.5-lightning:30b-a3b (25.4GB), ornith-1.5:35b (22.6GB), ornith-1.5:9b (6.6GB), glm-ocr (2.2GB), nomic-embed-text (0.3GB).

### 5.1 deer-flow model picker (live config roster)

| Picker name | Model tag | Class |
|---|---|---|
| Nemotron 3.5 Lightning 30B (Local) | `nemotron-3.5-lightning:30b-a3b` | local, 25.4GB |
| Gemma 4 12B (Local) | `gemma4:12b-it-qat` | local, 7.2GB |
| Gemma 4 12B (Memory, capped) | `gemma4:12b-it-qat` | local, memory lane pin |
| Ornith 1.5 9B (Local) | `ornith-1.5:9b` | local, 6.6GB |
| Ornith 1.5 35B (Local) | `ornith-1.5:35b` | local, 22.6GB |
| DeepSeek V4.1 Flash (Cloud) | `deepseek-v4.1-flash:cloud` | cloud (intentional) |
| GLM 5.3 Flash (Cloud) | `glm-5.3-flash:cloud` | cloud (intentional) |

**Reasoning-burn suppression verified live on 0.1.25** (both cloud models): `supports_reasoning_effort: true` + `when_thinking_disabled: {reasoning_effort: none}` present in config, AND the factory patch is baked into the image — `kwargs.pop("reasoning_effort", None)` fires when `when_thinking_disabled` sets it (prevents the "multiple values for keyword argument" crash). The adapter re-login-on-401 patch is also live (14 refs in `pacgate_deerflow_adapter/client.py`).

**Observation:** with 14.44GiB shared VRAM, the 25.4GB nemotron and 12.8GB gemma4 cannot be resident simultaneously — every model switch pays a 15–30s swap. The summarization fix (no model pin) correctly keeps the summarizer on the default chat model to avoid extra swaps.

---

## 6. Memory lanes audit

### 6.1 deer-flow conversation memory
- `storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage` (per-matter sync to pacgate-api), memory model pinned `gemma4-12b-memory`.
- Summarization now **enabled** (trigger 12000 msg-tokens, keep 12000, trim 8000) — bounds per-call input ~32k vs the previous unbounded 83k.

### 6.2 OpenViking (v0.4.16, pinned by design)
- Health: `{"status":"ok","healthy":true,"version":"v0.4.16","auth_mode":"api_key"}`.
- MCP lane from deer-flow: initialize **200** with root key.
- **MCP tool roster (12):** `find`, `forget`, `glob`, `grep`, `health`, `list`, `list_watches`, `read`, `remember`, `search`, `tree`, `write`.
- Workspace on disk: `/app/.openviking/workspace` = **11 MB** (dirs: `_system`, `bot`, `vectordb`, `viking`).
- Protocol note: OV's MCP endpoint is stateless-per-request — no `mcp-session-id` needed for `tools/list` (unlike pacgate-mcp which requires it). Probe scripts must not assume the pacgate-mcp session pattern.
- Newer upstream exists (v0.4.5/latest, different digests) but repinning is a deliberate act (ov.conf vlm section + workspace migration risk) — out of scope, unchanged.

### 6.3 qm memory (Postgres `qm` db)
- `memory_revisions`: **11 rows** — remember→recall lane has live data.
- `base_model_configs`: `org:pacgate → {"modelId": "glm-5.3-flash:cloud"}` — model routing config intact.

### 6.4 pacgate vectordb (pacgate-db, pgvector)
- 10 tables: audit_log, document_extractions, document_spans, documents, kb_chunks, matters, redaction_ledger_rows, sanitizer_jobs, tenants, users.
- **462 kb_chunks** · **27 documents** · db size 20 MB.
- Embedding lane: `nomic-embed-text` (768-dim) via Ollama at `host.docker.internal:11434/v1`, wired through `OPENVIKING_CONF_CONTENT` (dense provider block) — fully on-device.
- Extraction lane: OpenViking VLM = `gemma4:12b-it-q8_0` (max_tokens 8192, temp 0.1) via the same Ollama endpoint — also on-device.

---

## 7. qm-pacgate re-audit (full)

| Check | Result |
|---|---|
| `healthz` (core :8080) | `{"ok":true}` |
| Portal front door (:8181) | 401 (auth gate healthy) |
| Web UI (:8182) | 200 |
| Mailpit (:8025) | 200 |
| pi-models patch | **6 refs** to `glm-5.3-flash:cloud` + `defaultModelForProvider` wired (1) |
| Patch mounts | `pi-models.ts` → `/app/src/model/pi-models.ts`, `local-sandbox.ts` → `/app/src/sandbox/local-sandbox.ts`, `docker-cli/docker` → `/usr/local/bin/docker` (all bind-mounted from repo) |
| Env parity | `FLY_RESIDENT_ENV_PACGATE_API_URL=http://host.docker.internal:8089/pacgate` ✓, `MODEL_PROVIDER=openai` ✓, `QM_CORE_CONTAINER=qm-pacgate-core` ✓, `FLY_RESIDENT_ENV_OPENVIKING_API_KEY` set ✓ |
| Docker socket | mounted (sandbox exec path) |
| Memory lane | 11 revisions in Postgres |
| Model routing | `org:pacgate → glm-5.3-flash:cloud` |

**Note:** `FLY_RESIDENT_ENV_OPENVIKING_ROOT_API_KEY` is empty in the core env — the user key (`b4ccf9e6…`) is what's wired, which matches the tenant-scoped data-API design (root key is rejected for tenant APIs). Not a defect.

No qm sandbox containers are currently running (they spawn per-turn and exit after teardown — exit 137 on `stop -t2` is the normal kill path, verified in prior sessions). Sandbox exec was E2E-proven live on 2026-10-09 (prior session): turn spawned `qm-sbx-channel-*` container, microvm-agent listening, reply carried exec output; `docker.sock` + `docker-cli` mount + `LOCAL_SANDBOX_IMAGE` env are the operative wiring (`FLY_BASE_IMAGE` was verified inert and removed).

---

## 8. Container resource profile (idle)

| Container | CPU | Memory |
|---|---|---|
| pacgate-api | 0.00% | 1.578 GiB / 4 GiB limit |
| deer-flow-frontend | 0.00% | 1.547 GiB |
| ocr-service | 0.18% | 811 MiB |
| qm-pacgate-core | 1.76% | 533 MiB |
| openviking | 1.91% | 306 MiB |
| deer-flow | 0.18% | 235 MiB |
| qm-pacgate-pg | 3.91% | 126 MiB |
| pacgate-db | 0.00% | 72 MiB |
| pacgate-mcp | 0.22% | 65 MiB |
| qm web-ui/portal/admin/auth/mailpit | ~0% | 31–45 MiB each |
| pacgate-nginx | 0.00% | 25 MiB |

Total pacgate+qm footprint ≈ **5.4 GiB** of the 14.44 GiB host budget — healthy headroom for model serving.

---

## 9. Decisions & standing policy (reconfirmed this session)

1. **Cloud chat models are intentional** (deepseek-v4.1-flash / glm-5.3-flash via ollama.com) — decided 2026-08-30. RAG pipeline (nomic embeddings, OpenViking extraction via gemma4, local Postgres) stays fully on-device. Do not re-flag as residency bug.
2. **No local image builds** — deployment images come from GHCR pulls only (user decision 2026-10-08). v0.1.25 was pulled, not built.
3. **OpenViking stays pinned at v0.4.16** — upgrading is a deliberate act with migration risk, not part of routine releases.
4. **qm is a separate compose project** (`qm-pacgate`) — never `qm up` against it; lifecycle via `compose.qm.yaml`.
5. **`.env` is untracked + gitignored** — survives all syncs by construction; admin password `PacgateAdmin!53d4a5c5` verified working this session.

---

## 10. Probe lessons (recurring, for future sessions)

- Benchmark from **inside the compose network** (`pacgate-nginx:80`, `deer-flow-frontend:3000`) — `localhost:8089` from a container hits nothing (Connection refused).
- qm Postgres: user is `postgres`, db is `qm` (not `qm/qm`).
- `base_model_configs` columns are `id` + `json` (not `config`).
- Inline `python -c` via `docker exec` breaks PowerShell quoting — always write a probe file, `docker cp`, `docker exec`.
- Ollama warm numbers are only meaningful per-resident-model: measure immediately after the model you care about ran, or the swap cost pollutes the number.
- `docker stats` CPU for idle Rust services reads 0.00% — that's expected (event-driven), not a stall.
- **OpenViking MCP is stateless-per-request**: no `mcp-session-id` needed for `tools/list` (unlike pacgate-mcp, which 400s without it). Don't reuse the pacgate-mcp session pattern against OV.

---

*Report generated 2026-10-09 from live probes against the running 0.1.25 stack. All numbers are measured, none synthetic.*