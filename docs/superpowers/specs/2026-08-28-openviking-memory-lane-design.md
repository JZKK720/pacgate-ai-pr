# OpenViking as Pacgate's Memory Lane — Design Spec

> Status: **DRAFT — awaiting owner review**
> Date: 2026-08-28
> Decision basis: Option B (unified context layer) scoped by Option A (split duties) — OpenViking owns conversational/session memory; pacgate-rag keeps document RAG with T1–T4 compliance filtering.
> Related: `deploy/PLANS.md` (architecture memo), `deploy/COPILOT_CONTEXT.md` (integration principles), Plan 007 (AIPC delivery).

---

## 1. Problem statement

Pacgate's two upstream runtimes each hold conversational memory in their own way:

- **deer-flow** stores matter memory via our `PacgateMemoryStorage` adapter — a flat JSON blob per matter (`GET/POST /api/matters/{id}/memory`). No semantic recall, no session extraction, no history compression.
- **qm** keeps session context inside its own runtime with no long-term memory lane at all.

Attorney workflows need *cross-session* memory: "what did we decide about this client's indemnity posture last month?" Neither runtime answers that today. Building it ourselves in Rust would duplicate a problem OpenViking has already solved.

## 2. What OpenViking provides (verified from upstream repo)

- **Context database** for agents: memories, resources, skills under `viking://` URIs; L0/L1/L2 tiered loading; session→memory extraction; observable retrieval.
- **Official DeerFlow integration**: `manager_class: openviking` in DeerFlow's `config.yaml` memory section (upstream doc: `docs/images/agents/en/deerflow-memory-manager.md`).
- **Self-hosted Docker**: `ghcr.io/volcengine/openviking`, port 1933, single volume `~/.openviking:/app/.openviking`, requires `root_api_key` when bound to 0.0.0.0.
- **Ollama provider support** for both embedding and VLM — consistent with our local-first posture.
- **Identity model**: `account` / `user` / `peer` scoping — *not* tenant/matter. Mapping is our design work.

## 3. Architecture: split duties (Option A within Option B)

```
nginx :8081
├── /research/  → deer-flow ──┐
├── /collab/    → qm ─────────┤
│                             ▼
│                    OpenViking :1933        ← NEW service (upstream image)
│                    conversational memory,  (no wrapper — mounted ov.conf)
│                    session extraction,
│                    semantic recall
│
└── /api/       → pacgate-api :8080
                    ├── pacgate-rag (UNCHANGED)  ← document RAG, T1–T4,
                    │                              jurisdiction tags, citations
                    ├── pacgate-docx, pacgate-llm, pacgate-auth (UNCHANGED)
                    └── (Phase 3, optional) pacgate-ov client crate
```

**Boundary rule:** OpenViking never stores matter documents or anything subject to T1–T4 access control. It stores *conversational* context: session summaries, user/peer memories, agent experience. Document retrieval with compliance filtering stays in pacgate-rag.

## 4. Identity mapping (the core design work)

| Pacgate | OpenViking | Mechanism |
|---|---|---|
| `TenantId` (firm) | `account` | One OpenViking account per firm; set at deploy time in `ov.conf` |
| `MatterId` (case) | `peer` (workspace peer) | Adapters derive peer_id from `PACGATE_MATTER_ID` / qm channel scope |
| `UserId` (attorney) | `user` | Adapters pass the authenticated attorney's id per request |
| Ethical walls | peer isolation | Recall is scoped to the request's peer; cross-matter recall is impossible by construction |

This preserves the ethical-wall property: memory written under matter A's peer is not retrievable from matter B's context.

## 5. Component changes

### 5.1 New compose service (no new image)

```yaml
openviking:
  image: ghcr.io/volcengine/openviking:latest   # pin a release tag at implementation
  container_name: openviking
  ports: ["1933:1933"]
  volumes:
    - ./openviking:/app/.openviking             # client-owned data, same principle as ./data
  environment:
    OPENVIKING_CONF_CONTENT: ${OPENVIKING_CONF_CONTENT}  # JSON: root_api_key, ollama embedding+vlm
  restart: unless-stopped
```

`ov.conf` essentials: `root_api_key` (required for 0.0.0.0 binding), embedding → Ollama (`nomic-embed-text`), VLM → Ollama vision model (or skipped if not using image understanding initially — verify at implementation whether VLM is mandatory).

### 5.2 deer-flow (config-only)

Our wrapper's mounted `config.yaml` memory section changes from:

```yaml
memory:
  storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage
```

to the upstream-documented OpenViking manager:

```yaml
memory:
  enabled: true
  injection_enabled: true
  manager_class: openviking
  mode: middleware
  backend_config:
    base_url: http://openviking:1933
    owner_user_id: ${PACGATE_TENANT_ID}
    api_key_env: OPENVIKING_API_KEY
    startup_policy: fail_fast
    failure_policy: { read: fail_open, write: log_and_drop }
    retrieval: { top_k: 8, score_threshold: 0.25, max_injection_chars: 12000, content_mode: overview }
```

`PacgateMemoryStorage` is **kept in the adapter package** (not deleted) so the previous behavior remains available via config rollback.

### 5.3 qm (config-only)

`qm.config.jsonc` gains OpenViking MCP tools in the sandbox (`skills`/plugin entry pointing at OpenViking's stdio MCP proxy, `PACGATE_API_URL`-style env for the OpenViking URL + key). Exact mechanism per qm's plugin surface — verify at implementation; fallback is the LangChain-style middleware pattern if qm lacks a plugin slot.

### 5.4 pacgate-api (unchanged in Phase 1–2)

No Rust changes. Memory endpoints (`/api/matters/{id}/memory`) remain for rollback. **Phase 3 (optional, deferred):** a `pacgate-ov` client crate so pacgate-agent's `kb_search` can also consult OpenViking session memory — only if a real need emerges.

## 6. Data ownership & privacy

- OpenViking state lives in `./openviking/` on the client's disk (volume mount) — same ownership principle as `./data/tenants/`.
- All model calls (embedding, VLM) go to local Ollama — no cloud dependency.
- `root_api_key` is a client secret in `.env`, never committed.
- OpenViking's own encryption-at-rest options are available via `ov.conf` if the client requires them.

## 7. Rollout plan

| Phase | Scope | Risk |
|---|---|---|
| OV-1 | Add `openviking` compose service + `ov.conf` template; verify `/health` and Ollama embedding round-trip on dev machine | Low — additive service |
| OV-2 | Switch deer-flow memory to `manager_class: openviking` in the wrapper config; e2e: research run → session commit → recall in a *new* session | Low — config swap, rollback = revert one YAML block |
| OV-3 | Wire qm sandbox to OpenViking MCP; verify cross-session recall from qm | Medium — depends on qm plugin surface |
| OV-4 (optional, deferred) | `pacgate-ov` Rust client for pacgate-agent memory recall | Deferred until needed |

Each phase is independently revertible. Phase 2 (AIPC delivery, Plan 007) is **not blocked** — OpenViking is a post-pilot enhancement; the current delivery stays as-is.

## 8. Testing

- **OV-1**: `curl http://localhost:1933/health`; write a memory via HTTP API; recall it; restart container; verify persistence (volume).
- **OV-2**: deer-flow research run in session 1; new session 2 asks about session 1's topic; verify recall injection (check deer-flow logs for OpenViking recall header).
- **OV-3**: qm conversation commits; new qm session recalls; verify peer isolation (matter A memory not visible from matter B context).
- **Rollback drill**: revert `config.yaml` memory block to `PacgateMemoryStorage`; verify deer-flow still works against pacgate-api memory endpoints.

## 9. Open items (to resolve during implementation)

1. Is VLM strictly mandatory in `ov.conf`, or can a text-only deployment omit it? (Affects whether an Ollama vision model must be pulled on AIPCs.)
2. Exact qm plugin/MCP mounting mechanism (OV-3).
3. Pin an OpenViking release tag (avoid `latest`) once validated.
4. Confirm OpenViking's Windows/Docker-Desktop behavior on AIPCs (upstream notes a socat workaround for Mac; verify Windows port mapping is clean).

## 10. Explicitly out of scope

- Replacing pacgate-rag or migrating document RAG into OpenViking (rejected Option B-full).
- Forking OpenViking source.
- Cloud (Volcengine-hosted) OpenViking — violates local-first posture.
- Any change to pacgate-auth, SOUL personas, or workflow execution.
