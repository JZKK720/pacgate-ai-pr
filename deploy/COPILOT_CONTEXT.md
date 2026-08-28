# Pacgate-ai Architecture Context (for Copilot / agents)

> Compact context for AI agents working on the pacgate-ai codebase.
> Generated 2026-08-12. Full graph: deploy/knowledge-graph.json

## What this project is

Pacgate-ai is a **privacy-first, local-first legal AI platform** for multi-tenant attorney offices. It is the **metadata spine** — a headless Rust HTTP gateway + storage engines — behind two upstream runtimes (deer-flow for research, qm for collaboration) and one upstream context database (OpenViking for long-term conversational memory). None of the upstreams are forked; thin adapter packages translate between their native storage interfaces and pacgate-api's HTTP endpoints.

## The four layers

1. **Domain Core** (`pacgate-core`): Shared types. `TenantId`, `MatterId`, `DocumentId`, `UserId`, `Jurisdiction` (26 jurisdictions), `PracticeArea` (intl + China-specific), `LlmTier` (Main/Mid/Low), `CitationRef`. Every other crate depends on this.
2. **Engines** (`pacgate-docx`, `pacgate-llm`, `pacgate-rag`): DOCX OOXML generation, three-tier LLM routing, per-tenant RAG (pgvector + tsvector). These are the components neither deer-flow nor qm has.
3. **HTTP Gateway** (`pacgate-api`): Headless Axum server. Routes: `/api/auth`, `/api/chat`, `/api/documents`, `/api/matters`, `/api/workflows`, `/api/search`, `/api/tabular`. No user-facing UI. Both runtimes call these via adapters.
4. **Local Fallback Runtime** (`pacgate-agent`): `AgentLoop` + `ToolDispatcher` with 10 tools. For sub-second deterministic tasks (DOCX gen, WASM validation). Not the primary research or collaboration runtime.

## Integration architecture

```
Target ingress topology:
nginx :8081
├── /research/ → deer-flow :8001 (Python, LangGraph) → pacgate_deerflow_adapter → pacgate-api
├── /collab/   → qm :8765 (TypeScript, Deno)           → pacgate_qm_adapter    → pacgate-api
└── /api/      → pacgate-api :8080 (Rust, Axum)         → pacgate-docx, pacgate-rag, pacgate-llm, pacgate-auth
```

Current checked-in repo baseline now includes the client bundle, wrapper-image deployment docs, and the delivery-ready local stack. The root compose/nginx path is still the minimal local shell, but the practical operating baseline is the checked-in Phase 1 delivery package, not just the docs surface.

## Key design decisions

- **deer-flow** (bytedance, MIT, 19k stars): research runtime. Multi-step pipeline (Planner→Researcher→Coder→Reporter), citation extraction, legal skills. Integrated today via a Python adapter package plus Pacgate matter-memory/document APIs; DeerFlow config must explicitly opt in through `memory.manager_class: deermem` and `memory.backend_config.storage_class`.
- **qm** (yc-software): collaboration runtime. Scope model (`org`→`channel`→`personal`→`team`) maps to pacgate-ai's `TenantId`→`MatterId`→`UserId`→`PracticeArea`. Per-scope security posture = ethical walls. Per-scope egress = confidentiality control. Current repo state: tested TypeScript helper package + first-class `matters.external_key`; actual qm wrapper image is still pending.
- **Never fork** any upstream. Wrapper Dockerfiles `FROM` their published GHCR images + layer adapters on top. Upgrades = bump one `FROM` line. OpenViking runs unmodified as a side-car service (AGPL-3.0 — never modify or redistribute its source; config-only integration via its MCP endpoint at `/mcp`).
- **Memory boundary:** OpenViking stores conversational context only (session summaries, decisions, preferences). Matter documents and T1–T4-controlled content stay in pacgate-rag. Identity mapping: TenantId→OpenViking account, MatterId→peer, UserId→user (ethical walls enforced server-side by peer isolation).
- **Cubecloud owns code (GHCR images); client owns data (volume mount).** Client's `./data/tenants/{tenant_id}/` is on their disk, never in images.

## Crate status

| Crate            | src/ exists | Status                                                                                  |
| ---------------- | ----------- | --------------------------------------------------------------------------------------- |
| pacgate-core     | ✅          | Implemented (types, domain model)                                                       |
| pacgate-docx     | ✅          | Implemented (builder, styles, ooxml, diff)                                              |
| pacgate-api      | ✅          | Implemented for auth/matters/documents/workflows/search; tabular review remains stubbed |
| pacgate-agent    | ✅          | Implemented (AgentLoop, 10 tools, DocumentStore trait)                                  |
| pacgate-llm      | ✅          | Skeleton (LlmRouter, provider abstraction)                                              |
| pacgate-rag      | ❌          | Needs implementation (pgvector + tsvector)                                              |
| pacgate-tenant   | ❌          | Cargo.toml only (scope isolation, per-tenant config)                                    |
| pacgate-auth     | ❌          | Cargo.toml only (JWT, OIDC, argon2)                                                     |
| pacgate-persona  | ❌          | Cargo.toml only (20 legal personas)                                                     |
| pacgate-workflow | ❌          | Cargo.toml only (160+ templates)                                                        |
| WASM crates (4)  | ❌          | Cargo.toml only (citation-check, clause-parser, doc-validator, rule-engine)             |

## Current operating baseline

- The repo is now in a delivery-ready Phase 1 state rather than a pure prototype state.
- The story anchor remains the Phase 1 pilot contract, but the checked-in artifacts already include the deployable bundle and operational handoff docs.
- Immediate next steps are operational: rebuild `pacgate-api` with connector fixes, refresh the PkuLaw token, and deploy/verify on client AIPC hardware.

## Deployment model

- **Docker Compose** on client AI PC (Windows, AMD GPU/NPU)
- **Ollama native** (not Dockerized) for GPU access
- **3 GHCR images**: `pacgate-api`, `deer-flow-pacgate` (wrapper), `qm-pacgate` (wrapper)
- **Client bundle**: compose.prod.yaml + nginx config + install.ps1 + .env + ollama-models.txt + qm bootstrap materials + workflow/persona references
- **Data**: `./data/tenants/{tenant_id}/` on volume mount, never in images
- **Updates**: client runs `install.ps1 -Update`; data preserved across upgrades

## File path convention

```
./data/tenants/{tenant_id}/
├── matters/{matter_id}/
│   ├── docs/{name}_v{n}.docx
│   ├── uploads/
│   ├── memory/facts.jsonl
│   └── runs/{run_id}/
├── persona/*.yaml
├── workflows/*.yaml
├── kb/
└── config.yaml (model_overrides)
```

## Scope mapping (qm ↔ pacgate-ai)

| qm ScopeId             | pacgate-ai type | Path                       |
| ---------------------- | --------------- | -------------------------- |
| `org:{tenant_id}`      | TenantId        | `tenants/{tenant_id}/`     |
| `channel:{matter_id}`  | MatterId        | `tenants/{t}/matters/{m}/` |
| `personal:{user_id}`   | UserId          | `tenants/{t}/users/{u}/`   |
| `team:{practice_area}` | PracticeArea    | `tenants/{t}/teams/{p}/`   |
