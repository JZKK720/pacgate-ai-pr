# OpenViking Memory Lane (OV-2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenViking as an independent side-car memory service and wire deer-flow + qm to it via MCP, keeping pacgate-rag as the document-RAG layer.

**Architecture:** OpenViking runs as a fourth compose service from upstream's image (digest-pinned). deer-flow gets MCP recall tools via `extensions_config.json` (verified supported by our pinned deer-flow-backend image); qm mounts the same `/mcp` endpoint in its sandbox with identity headers. Session capture stays on the existing `PacgateMemoryStorage` → pacgate-api path. Identity mapping: `TenantId`→`X-OpenViking-Account`, `MatterId`→`X-OpenViking-Actor-Peer`, `UserId`→`X-OpenViking-User`.

**Tech Stack:** Docker Compose, OpenViking (`ghcr.io/volcengine/openviking@sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701`), Ollama (`nomic-embed-text`), deer-flow MCP config, qm sandbox config.

**Spec:** `docs/superpowers/specs/2026-08-28-openviking-memory-lane-design.md` (v2, OV-2a decision)

## Global Constraints

- OpenViking image pinned by digest: `ghcr.io/volcengine/openviking@sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701` — never `latest` in compose.prod.yaml.
- No OpenViking source modifications (AGPL-3.0; unmodified side-car is the license-safe pattern).
- No changes to pacgate-rag, pacgate-auth, SOUL personas, or workflow execution.
- OpenViking stores ONLY conversational context — never matter documents or T1–T4-controlled content.
- All OpenViking model calls go to local Ollama (`http://host.docker.internal:11434`) — no cloud.
- `root_api_key` and `OPENVIKING_API_KEY` are client secrets: `.env` only, never committed.
- Data lives in `./openviking/` volume on client disk (same ownership principle as `./data/tenants/`).
- Every phase independently revertible; deer-flow capture path (`PacgateMemoryStorage`) must remain functional at all times.
- serde/config casing: OpenViking identity headers are exact: `X-OpenViking-Account`, `X-OpenViking-User`, `X-OpenViking-Actor-Peer`.

---

### Task 1: OV-1 — Add OpenViking compose service (dev machine)

**Files:**
- Create: `deploy/client-bundle/openviking/ov.conf.template`
- Modify: `deploy/client-bundle/compose.prod.yaml`
- Modify: `deploy/client-bundle/.env.example`
- Modify: `deploy/client-bundle/install.ps1` (create `./openviking/` dir alongside `./data/`)

**Interfaces:**
- Produces: service `openviking` reachable at `http://openviking:1933` from the compose network; `/health` endpoint; `OPENVIKING_API_KEY` env var consumed by Tasks 2–3.

- [ ] **Step 1: Create `ov.conf.template`**

```json
{
  "server": {
    "host": "0.0.0.0",
    "port": 1933,
    "root_api_key": "${OPENVIKING_ROOT_API_KEY}"
  },
  "storage": {
    "workspace": "/app/.openviking/workspace"
  },
  "embedding": {
    "dense": {
      "provider": "ollama",
      "api_base": "http://host.docker.internal:11434/v1",
      "model": "nomic-embed-text",
      "dimension": 768
    }
  }
}
```

Note: no `vlm` block — verified optional (`VLMBase.is_available()`; bootstrap warns but does not fail). If image understanding is needed later, add an Ollama vision model then.

- [ ] **Step 2: Add service to `compose.prod.yaml`** (after `deer-flow`, before `nginx`)

```yaml
  openviking:
    image: ghcr.io/volcengine/openviking@sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701
    container_name: openviking
    ports:
      - "1933:1933"
    volumes:
      - ./openviking:/app/.openviking
    environment:
      OPENVIKING_CONF_CONTENT: ${OPENVIKING_CONF_CONTENT}
    restart: unless-stopped
```

(Use `OPENVIKING_CONF_CONTENT` env injection — upstream-documented; avoids mounting a config file the client must edit. `install.ps1` generates it from the template + secrets.)

- [ ] **Step 3: Add to `.env.example`**

```
# === OpenViking (memory lane) ===
# Root API key for the OpenViking server (generate: openssl rand -hex 32)
OPENVIKING_ROOT_API_KEY=change-me-to-a-random-hex-string
# API key clients use to call OpenViking (can equal root key in pilot)
OPENVIKING_API_KEY=change-me-to-a-random-hex-string
```

- [ ] **Step 4: Update `install.ps1`** — in the data-directory section, add `New-Item -ItemType Directory -Path .\openviking -Force` and a step that renders `OPENVIKING_CONF_CONTENT` from the template (replace `${OPENVIKING_ROOT_API_KEY}` with the `.env` value, minify to single-line JSON, append to `.env` if absent).

- [ ] **Step 5: Start and verify**

Run: `docker compose -f compose.prod.yaml up -d openviking` then `curl http://localhost:1933/health`
Expected: `200` with health JSON. If Ollama warning appears in logs, note it — embedding is the only required model path.

- [ ] **Step 6: Verify embedding round-trip via MCP**

Run: `curl -X POST http://localhost:1933/mcp -H "X-API-Key: $env:OPENVIKING_API_KEY" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`
Expected: JSON listing 15 tools (`find`, `search`, `read`, `remember`, `write`, `grep`, `glob`, `forget`, `health`, …).

- [ ] **Step 7: Verify persistence**

Write a memory via `remember` tool → restart container (`docker compose restart openviking`) → recall via `search`. Expected: memory survives restart (volume mount works).

- [ ] **Step 8: Commit** — `feat: add OpenViking side-car service (OV-1)`

---

### Task 2: OV-2a — deer-flow MCP recall (dev machine)

**Files:**
- Create: `deploy/deer-flow-pacgate/extensions_config.json`
- Modify: `deploy/deer-flow-pacgate/Dockerfile` (COPY the config into the image at the path DeerFlow expects)
- Modify: `deploy/client-bundle/.env.example` (no change — reuses `OPENVIKING_API_KEY`)

**Interfaces:**
- Consumes: `http://openviking:1933/mcp` (Task 1), `OPENVIKING_API_KEY`.
- Produces: deer-flow agents with `find`/`search`/`read`/`remember` MCP tools at runtime.

- [ ] **Step 1: Determine the config path DeerFlow expects**

Run: `docker run --rm --entrypoint sh ghcr.io/bytedance/deer-flow-backend@sha256:e7c503a803c99a039e08da61359932877a9e0d0196799429698244117338af13 -c "grep -rn 'extensions_config' /app/backend/packages/harness/deerflow/config/extensions_config.py | head -5"`
Expected: the default path (likely `/app/backend/extensions_config.json` — confirm exact value from source).

- [ ] **Step 2: Write `extensions_config.json`**

```json
{
  "mcpServers": {
    "openviking": {
      "enabled": true,
      "type": "http",
      "url": "http://openviking:1933/mcp",
      "headers": {
        "X-API-Key": "${OPENVIKING_API_KEY}"
      }
    }
  }
}
```

If the config loader does not do env substitution (verify in `extensions_config.py`), inject the key via the compose environment for deer-flow and template the file in `install.ps1` instead of committing a literal.

- [ ] **Step 3: COPY into wrapper Dockerfile** — add after the existing config COPY:
`COPY deploy/deer-flow-pacgate/extensions_config.json /app/backend/extensions_config.json`
Rebuild: `docker build -t ghcr.io/jzkk720/deer-flow-pacgate:0.1.1 -f deploy/deer-flow-pacgate/Dockerfile .` (bump tag — the wrapper layer changed).

- [ ] **Step 4: Verify MCP tools appear**

Start the stack; check deer-flow gateway logs for the MCP server load; run a research query that should trigger memory search. Expected: `openviking` in the agent tool list; no startup errors.

- [ ] **Step 5: Verify capture path still works**

Run a research session; confirm `PacgateMemoryStorage` still writes to pacgate-api (`GET /api/matters/{id}/memory` returns data). Expected: unchanged behavior — this is the rollback guarantee.

- [ ] **Step 6: Verify recall round-trip**

Session 1: ask deer-flow to "remember" a fact (via `remember` MCP tool or capture). Session 2 (new): ask a question that requires that fact. Expected: agent calls `search`/`find` and cites the memory.

- [ ] **Step 7: Push image + commit** — push `deer-flow-pacgate:0.1.1` to GHCR; update `compose.prod.yaml` tag; commit `feat: deer-flow OpenViking MCP recall (OV-2a)`.

---

### Task 3: OV-3 — qm sandbox MCP mount (dev machine)

**Files:**
- Modify: `deploy/qm-pacgate/qm.config.jsonc` (sandbox env + skills/MCP entry)
- Modify: `deploy/qm-pacgate/sandbox/` (MCP config for the sandbox image, per qm's mechanism — inspect `qm sandbox` docs in `deploy/qm-pacgate/.codex/skills/deploy-qm/`)

**Interfaces:**
- Consumes: `http://openviking:1933/mcp` (Task 1), `OPENVIKING_API_KEY`.
- Produces: qm agent sessions with OpenViking tools; peer-scoped memory per matter/channel.

- [ ] **Step 1: Read qm's MCP/sandbox docs** — `deploy/qm-pacgate/.codex/skills/deploy-qm/` and `AGENTS.md` to find how MCP servers are declared for the sandbox (the pi harness may take MCP config via env or a config file).

- [ ] **Step 2: Wire the MCP server** — add OpenViking as an HTTP MCP server with headers:
  `X-API-Key: ${OPENVIKING_API_KEY}`, `X-OpenViking-Account: ${PACGATE_TENANT_ID}`, `X-OpenViking-Actor-Peer: <matter/channel scope>`, `X-OpenViking-User: <attorney id>`.
  Peer derivation: qm channel scope ↔ `MatterId` per the existing scope mapping (`deploy/ARCHITECTURE-DIAGRAMS.md` §Scope model mapping).

- [ ] **Step 3: Verify from qm** — `qm up`; sign in; ask the agent to `remember` a fact; new session; ask for it back. Expected: recall works and is scoped to the channel's peer.

- [ ] **Step 4: Verify ethical wall** — write memory under matter A's channel; open matter B's channel; ask for the fact. Expected: NOT recalled (server-side `PEER_NOT_ALLOWED` isolation).

- [ ] **Step 5: Commit** — `feat: qm OpenViking MCP mount with peer-scoped identity (OV-3)`

---

### Task 4: Docs + delivery integration

**Files:**
- Modify: `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` (new Stage for OpenViking; smoke checklist entries)
- Modify: `deploy/ARCHITECTURE-DIAGRAMS.md` (add OpenViking node to system overview + ownership diagrams)
- Modify: `deploy/COPILOT_CONTEXT.md` (integration principles: third upstream, AGPL note)
- Modify: `deploy/client-bundle/ollama-models.txt` (ensure `nomic-embed-text` present — it already is)
- Create: `plans/008-openviking-delivery-log.md` (delivery log template)

**Interfaces:**
- Consumes: all prior tasks.
- Produces: client-installable documentation matching the actual stack.

- [ ] **Step 1: Handbook** — add "Stage 3.5: OpenViking memory service" (env vars, health check `curl http://localhost:1933/health`, model note); add smoke checklist items (service up, MCP tools reachable, cross-session recall works, ethical wall holds).
- [ ] **Step 2: Diagrams** — add OpenViking node; note AGPL in the ownership diagram's upstream box.
- [ ] **Step 3: COPILOT_CONTEXT** — add OpenViking to the upstream-runtimes list with the no-fork + AGPL caveat.
- [ ] **Step 4: Commit** — `docs: OpenViking delivery integration (OV-1..3)`

---

### Task 5: AIPC rollout (Phase 3 addendum)

**Files:**
- Modify: `plans/007-aipc-full-installation-handoff.md` (Phase 3 addendum: OpenViking steps)
- Modify: `plans/007-delivery-log.md` (per-machine OpenViking checklist results)

- [ ] **Step 1: Addendum** — insert OpenViking installation steps into the Phase 3 agent prompt (after Stage 3): pull digest-pinned image, generate `OPENVIKING_*` secrets, health check, MCP verification.
- [ ] **Step 2: Pilot machine first** — install on AIPC #1, run the full checklist including cross-session recall + ethical wall, record in delivery log.
- [ ] **Step 3: Replicate to AIPC #2** after pilot passes.
- [ ] **Step 4: Commit** — `docs: AIPC rollout addendum for OpenViking`

---

## Rollback procedures (per phase)

| Phase | Rollback |
|---|---|
| OV-1 | `docker compose -f compose.prod.yaml stop openviking` — nothing else depends on it yet |
| OV-2a | Remove the `mcpServers.openviking` block from `extensions_config.json`, rebuild wrapper (or revert to `deer-flow-pacgate:0.1.0` tag); capture path never changed |
| OV-3 | Remove the MCP entry from qm config; `qm down && qm up` |
| Data | `./openviking/` volume is client-owned; deleting it removes all OpenViking memory (pacgate-api memory is separate and untouched) |
