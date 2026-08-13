# Pacgate-ai Architecture Context (for Copilot / agents)

> Compact context for AI agents working on the pacgate-ai codebase.
> Generated 2026-08-12. Full graph: deploy/knowledge-graph.json

## What this project is

Pacgate-ai is a **privacy-first, local-first legal AI platform** for multi-tenant attorney offices. It is the **metadata spine** — a headless Rust HTTP gateway + storage engines — behind two upstream runtimes (deer-flow for research, qm for collaboration). Neither upstream is forked; thin adapter packages translate between their native storage interfaces and pacgate-api's HTTP endpoints.

## The four layers

1. **Domain Core** (`pacgate-core`): Shared types. `TenantId`, `MatterId`, `DocumentId`, `UserId`, `Jurisdiction` (26 jurisdictions), `PracticeArea` (intl + China-specific), `LlmTier` (Main/Mid/Low), `CitationRef`. Every other crate depends on this.
2. **Engines** (`pacgate-docx`, `pacgate-llm`, `pacgate-rag`): DOCX OOXML generation, three-tier LLM routing, per-tenant RAG (pgvector + tsvector). These are the components neither deer-flow nor qm has.
3. **HTTP Gateway** (`pacgate-api`): Headless Axum server. Routes: `/api/chat`, `/api/documents`, `/api/matters`, `/api/workflows`, `/api/tabular`. No user-facing UI. Both runtimes call these via adapters.
4. **Local Fallback Runtime** (`pacgate-agent`): `AgentLoop` + `ToolDispatcher` with 10 tools. For sub-second deterministic tasks (DOCX gen, WASM validation). Not the primary research or collaboration runtime.

## Integration architecture

```
nginx :8081
├── /research/ → deer-flow :8001 (Python, LangGraph) → pacgate_deerflow_adapter → pacgate-api
├── /collab/   → qm :8765 (TypeScript, Deno)           → pacgate_qm_adapter    → pacgate-api
└── /api/      → pacgate-api :8080 (Rust, Axum)         → pacgate-docx, pacgate-rag, pacgate-llm, pacgate-auth
```

## Key design decisions

- **deer-flow** (bytedance, MIT, 19k stars): research runtime. Multi-step pipeline (Planner→Researcher→Coder→Reporter), citation extraction, legal skills. Integrated via `DeerFlowClient` + `config.yaml` storage_class override.
- **qm** (yc-software): collaboration runtime. Scope model (`org`→`channel`→`personal`→`team`) maps to pacgate-ai's `TenantId`→`MatterId`→`UserId`→`PracticeArea`. Per-scope security posture = ethical walls. Per-scope egress = confidentiality control.
- **Never fork** either upstream. Wrapper Dockerfiles `FROM` their published GHCR images + layer adapters on top. Upgrades = bump one `FROM` line.
- **Cubecloud owns code (GHCR images); client owns data (volume mount).** Client's `./data/tenants/{tenant_id}/` is on their disk, never in images.

## Crate status

| Crate | src/ exists | Status |
|---|---|---|
| pacgate-core | ✅ | Implemented (types, domain model) |
| pacgate-docx | ✅ | Implemented (builder, styles, ooxml, diff) |
| pacgate-api | ✅ | Scaffolded (routes defined, return "not yet wired") |
| pacgate-agent | ✅ | Implemented (AgentLoop, 10 tools, DocumentStore trait) |
| pacgate-llm | ✅ | Skeleton (LlmRouter, provider abstraction) |
| pacgate-rag | ❌ | Needs implementation (pgvector + tsvector) |
| pacgate-tenant | ❌ | Cargo.toml only (scope isolation, per-tenant config) |
| pacgate-auth | ❌ | Cargo.toml only (JWT, OIDC, argon2) |
| pacgate-persona | ❌ | Cargo.toml only (20 legal personas) |
| pacgate-workflow | ❌ | Cargo.toml only (160+ templates) |
| WASM crates (4) | ❌ | Cargo.toml only (citation-check, clause-parser, doc-validator, rule-engine) |

## Deployment model

- **Docker Compose** on client AI PC (Windows, AMD GPU/NPU)
- **Ollama native** (not Dockerized) for GPU access
- **3 GHCR images**: `pacgate-api`, `deer-flow-pacgate` (wrapper), `qm-pacgate` (wrapper)
- **Client bundle**: compose.prod.yaml + nginx config + install.ps1 + .env + ollama-models.txt
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

| qm ScopeId | pacgate-ai type | Path |
|---|---|---|
| `org:{tenant_id}` | TenantId | `tenants/{tenant_id}/` |
| `channel:{matter_id}` | MatterId | `tenants/{t}/matters/{m}/` |
| `personal:{user_id}` | UserId | `tenants/{t}/users/{u}/` |
| `team:{practice_area}` | PracticeArea | `tenants/{t}/teams/{p}/` |