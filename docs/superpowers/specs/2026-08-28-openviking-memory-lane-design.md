# OpenViking as Pacgate's Memory Lane — Design Spec

> Status: **DRAFT v2 — deep-dive verified against the OpenViking codebase (cloned 2026-08-28)**
> Date: 2026-08-28
> Decision basis: Option B (unified context layer) scoped by Option A (split duties) — OpenViking owns conversational/session memory; pacgate-rag keeps document RAG with T1–T4 compliance filtering.
> Related: `deploy/PLANS.md` (architecture memo), `deploy/COPILOT_CONTEXT.md` (integration principles), Plan 007 (AIPC delivery).

---

## 0. Deep-dive verification results (codebase-level, 2026-08-28)

The full OpenViking repo was cloned (`C:\Users\cubecloud-io\github-pr\OpenViking`, 3997 files) and the spec's four open items were resolved **from source, not docs**:

### 0.1 🔴 CRITICAL finding: the DeerFlow `manager_class: openviking` path does NOT exist in our pinned image

- The upstream doc `docs/images/agents/en/deerflow-memory-manager.md` documents `manager_class: openviking` — but `OpenVikingMemoryManager` **does not exist anywhere in the OpenViking repo** (grep: zero hits), and **does not exist in our pinned deer-flow-backend image** (`ghcr.io/bytedance/deer-flow-backend@sha256:e7c503...` — grep for `openviking` across `/app/backend/packages`: zero hits).
- The pinned image's `MemoryConfig` supports only `storage_class` (dynamic class-path loading — this is what our `PacgateMemoryStorage` adapter uses) and has **no `manager_class` field at all**.
- Conclusion: the upstream doc targets a *newer/different* DeerFlow build than the one we pin. **OV-2 as originally designed (config-only swap) is not possible with our current image.**

**Revised OV-2 options (decision needed):**
- **OV-2a (recommended): MCP path instead.** The pinned image *does* support MCP servers via `extensions_config.json` (`mcpServers` config verified in `config/extensions_config.py`). OpenViking exposes a streamable-HTTP MCP endpoint at `/mcp` with 15 tools (`find`, `search`, `read`, `remember`, `write`, `grep`, `glob`, `forget`, `health`, …). DeerFlow agents get active memory search/read as tools — this is the *other* officially documented DeerFlow integration (`deerflow-mcp.md`) and it works with our pinned version. Memory *capture* would still flow through our existing `PacgateMemoryStorage` (or a thin OpenViking-writing variant), while *recall* becomes agentic via MCP tools.
- **OV-2b: bump the deer-flow base image** to a version that ships `OpenVikingMemoryManager` (requires identifying which upstream DeerFlow release added it — the doc exists in OpenViking's repo, so the pairing is documented somewhere; needs a DeerFlow changelog check). Higher risk: our wrapper is validated against the pinned SHA.

### 0.2 ✅ VLM is optional (open item 1 resolved)

`VLMBase.is_available()` returns `True` when `api_key` OR `api_base` is set — and the bootstrap only *warns* ("Embedding/VLM may fail") if Ollama is unreachable; it does not hard-fail. A text-only deployment with embedding-only config is viable. For Pacgate: configure Ollama embedding (`nomic-embed-text`); add an Ollama vision model only if/when image understanding is needed.

### 0.3 ✅ qm integration mechanism confirmed (open item 2 resolved)

OpenViking server exposes **streamable-HTTP MCP at `/mcp`** with identity headers (`X-OpenViking-Account`, `X-OpenViking-User`, `X-OpenViking-Actor-Peer`) extracted per-request via contextvars. qm's sandbox can mount this as an HTTP MCP server with per-request headers — no plugin development needed, just config. The 15 registered MCP tools are the authoritative surface (`openviking/server/mcp_endpoint.py`).

### 0.4 ✅ Peer isolation is enforced server-side (ethical-wall property verified)

`openviking/session/memory/memory_isolation_handler.py` implements write-target resolution with explicit skip codes: `PEER_NOT_ALLOWED` ("Target peer is outside the allowed memory scope"), `INVALID_PEER_ID`, `SELF_MEMORY_DISABLED`, etc. Memory writes are resolved against the request's identity scope — the ethical-wall mapping in §4 is enforceable, not aspirational.

### 0.5 ✅ Release pinning (open item 3 resolved)

No git tags in the shallow clone; pin by **image digest** instead (same practice as our deer-flow wrapper): `ghcr.io/volcengine/openviking@sha256:<digest>` once OV-1 validates a version.

### 0.6 ⚠️ License: AGPL-3.0 (new consideration)

OpenViking is **AGPLv3** (deer-flow is MIT, qm per yc-software terms). Running it as an unmodified separate service over HTTP is the standard AGPL-safe pattern (we are not distributing or modifying it; network use triggers source-availability obligations for *OpenViking itself*, which upstream already satisfies). **However**: if we ever modify OpenViking source or link it into our distributed images, AGPL obligations attach. The no-fork principle protects us. Flag for Cubecloud commercial review before client deployment — upstream offers paid self-managed licenses if AGPL is unacceptable to the client.

### 0.7 Resource footprint

Helm defaults: 2 CPU / 4Gi memory limits (1 CPU / 2Gi requests). Acceptable alongside the existing AIPC stack; the Rust RAGFS crates compile into the published image (no local Rust toolchain needed on AIPCs).

### 0.8 Windows/Docker Desktop (open item 4 — partially resolved)

Official compose binds `1933:1933` directly; the socat workaround in the docs is **Mac-specific**. Windows Desktop port mapping is expected to work the same as our existing nginx mapping — verify live in OV-1.

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

### 5.2 deer-flow (REVISED after deep-dive — see §0.1)

The originally planned `manager_class: openviking` config swap is **not supported by our pinned deer-flow-backend image** (no `manager_class` field; no OpenViking code in the image). Two paths:

**OV-2a (recommended): MCP recall + existing capture.**
- Add OpenViking to deer-flow's `extensions_config.json` as an HTTP MCP server (`url: http://openviking:1933/mcp`, `X-API-Key` header) — verified supported by the pinned image's `extensions_config.py`.
- DeerFlow agents gain `find`/`search`/`read`/`remember` tools for active memory recall.
- Session *capture* continues through our `PacgateMemoryStorage` adapter (unchanged), optionally extended later to also mirror writes into OpenViking via its HTTP API.
- Zero image changes; fully reversible.

**OV-2b: bump the deer-flow base image** to a release that ships `OpenVikingMemoryManager` (the upstream doc's `manager_class: openviking` path). Requires identifying the compatible DeerFlow release and re-validating our wrapper against the new SHA. Higher risk; pursue only if middleware-style automatic recall (vs agentic tool recall) is a hard requirement.

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

## 9. Open items (updated after deep-dive)

1. ~~Is VLM strictly mandatory?~~ **RESOLVED** — optional; embedding-only config is viable (§0.2).
2. ~~Exact qm plugin/MCP mechanism~~ **RESOLVED** — streamable-HTTP MCP at `/mcp` with identity headers (§0.3).
3. ~~Release pinning~~ **RESOLVED** — pin by image digest after OV-1 validation (§0.5).
4. ~~Windows port-mapping~~ **Partially resolved** — Mac-only socat note; verify live in OV-1 (§0.8).
5. **NEW — DeerFlow integration path**: choose OV-2a (MCP tools, works with pinned image) vs OV-2b (bump base image for `manager_class: openviking`) — see §0.1. **This is the main decision blocking implementation.**
6. **NEW — AGPL review**: confirm Cubecloud/client accept AGPLv3 for an unmodified side-car service (§0.6).

## 10. Explicitly out of scope

- Replacing pacgate-rag or migrating document RAG into OpenViking (rejected Option B-full).
- Forking OpenViking source.
- Cloud (Volcengine-hosted) OpenViking — violates local-first posture.
- Any change to pacgate-auth, SOUL personas, or workflow execution.
