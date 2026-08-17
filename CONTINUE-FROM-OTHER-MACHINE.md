# How to Continue Work from Another Machine

## Quick start (on your other machine)

```powershell
# 1. Clone the repo
cd C:\Users\cubecloud-io\github-pr
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr

# 2. Set up Python venv (for PDF scripts + graphify)
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install graphifyy openai httpx

# 3. Verify the Rust workspace compiles
cd pacgate-ai
cargo check
cargo test -p pacgate-api --test smoke

# 4. (Optional) Run graphify on the crates
$env:NO_PROXY = "localhost,127.0.0.1,::1"
$env:no_proxy = "localhost,127.0.0.1,::1"
$env:OLLAMA_MODEL = "ornith:9b-q8_0"
$env:OLLAMA_API_KEY = "ollama"
$env:OLLAMA_BASE_URL = "http://localhost:11434/v1"
python -m graphify pacgate-ai/crates --no-viz --backend ollama
```

## What's in the repo

```
pacgate-ai-pr/
├── pacgate-ai/              ← Rust workspace (the metadata gateway)
│   ├── crates/
│   │   ├── pacgate-core/     ← Domain types + store traits (DONE)
│   │   ├── pacgate-docx/     ← OOXML engine + FsDocumentStore (DONE)
│   │   ├── pacgate-api/      ← Axum HTTP gateway + main.rs + auth routes (DONE)
│   │   ├── pacgate-agent/    ← 10-tool AgentLoop (DONE)
│   │   ├── pacgate-llm/      ← 3-tier LLM router (DONE)
│   │   ├── pacgate-tenant/   ← TenantStore + MatterStore + migrations (DONE)
│   │   ├── pacgate-auth/     ← JWT + argon2 + middleware (DONE)
│   │   ├── pacgate-rag/      ← STUB (needs pgvector impl)
│   │   ├── pacgate-persona/  ← STUB (needs 20 personas)
│   │   ├── pacgate-workflow/ ← STUB (needs 160+ templates)
│   │   └── ... (other stubs)
│   ├── wasm-crates/          ← 4 WASM crates (stubs)
│   ├── migrations/           ← SQL schema
│   └── Dockerfile            ← Multi-stage Rust build
├── pacgate-adapters/
│   └── python/pacgate_deerflow_adapter/  ← ~150 line Python adapter (DONE)
├── deploy/                   ← All deployment docs + Dockerfiles
│   ├── PLANS.md              ← Architecture memo
│   ├── DEPLOYMENT-GUIDE.md   ← Engineer guide
│   ├── USER-MANUAL.md        ← Client-facing guide
│   ├── ARCHITECTURE-DIAGRAMS.md
│   ├── COPILOT_CONTEXT.md    ← Compact context for AI agents
│   ├── deer-flow-pacgate/Dockerfile  ← Wrapper image
│   └── ...
├── docs/                     ← Proposal HTML pages
├── scope-assets/             ← Business materials (contracts, research)
├── compose.yaml              ← Dev Docker compose
├── auth-gate/                ← Auth gate service
└── nginx/                    ← Nginx config
```

## Current status (as of 2026-08-17, session 12)

### Done — Phase 1 critical path complete + Sessions 5-12 enrichment

- Full Rust workspace compiles cleanly (`cargo check` passes)
- 15 smoke tests pass (`cargo test -p pacgate-api --test smoke`)
- 3 YAML loader tests pass (`cargo test -p pacgate-workflow --test yaml_loader`)
- Integration test scaffold added (`cargo test -p pacgate-api --test integration -- --ignored`, requires Postgres at `localhost:5433/pacgate_test`)
- Storage layer: FsDocumentStore + MatterStore + TenantStore + SQL migrations (**4 migrations**)
- Auth: JWT + argon2 + login/register + middleware + soul_id in Claims + **SOUL resolver middleware** (resolves soul_id → SoulPersona at request time, injects into request extensions)
- API routes: matters, documents, chat, workflows, auth — all wired to real stores, **auth middleware now applied to protected routes**
- **Chat handler wired to SOUL** — compose_persona_prompt() builds layered prompt from SoulPersona (preamble + boundary rules + output format) + optional persona_id, passed to AgentLoop::run()
- LLM router: 7 providers, 3-tier routing
- RAG: pgvector + tsvector hybrid retrieval + Ollama embeddings + chunk ingestor + **jurisdiction filtering + source level tagging + T1-T4 data level filtering** (SearchFilter struct, migrations 003+004)
- 20 legal personas (practice-area personas) + **10 SOUL personas** (Justin, Sylvie, A1-A8 complete BigLaw roster)
- **51 YAML workflow templates** loaded from `pacgate-ai/workflows/*.yaml` (9 files). Categories: investment_financing, contract_review, ma_due_diligence, litigation, compliance_corporate, fund_lawyer, capital_markets, compliance_specialized, banking_general. YAML loader: `load_from_yaml_dir()`, `merge_workflows()`, `list_all_workflows()`
- **WorkflowExecutor** — drives AgentLoop step-by-step through workflow templates, chains outputs as context. Re-exported from `pacgate_agent::WorkflowExecutor`
- **Workflow execution API** — `POST /api/workflows/:id/execute` endpoint runs workflows end-to-end. `GET /api/workflows?category=X&search=Y` filters by category and searches by keyword. `GET /api/workflows/categories` returns distinct categories with counts.
- **Legal search agent tool** — `legal_search` tool in pacgate-agent with `SearchRouter` integration. A4 Research Agent can query external legal databases (CourtListener, SEC EDGAR, GLEIF, Chinese DBs) with jurisdiction/doc_type/connector filtering. Tool description instructs agent to never fabricate citations.
- SOUL architecture: identity overlay types (SoulPersona, BoundaryRule, EscalationRule, etc.)
- Legal domain enums: SourceLevel, ReviewStatus, SecurityLevel, RiskGrade, Jurisdiction
- **T1-T4 data classification** (DataLevel enum) — 4-tier system from client archive standard. Controls access scope: T1 shared templates, T2 restricted seeds, T3 project-specific, T4 special sensitive. Wired into RAG SearchFilter and chunk ingestor.
- **9-directory archive taxonomy** (ArchiveDirectory enum) — the 百宸 project archive submission standard (目录编号 00-08). Includes ProjectOverview, FileDirectoryEntry, ProjectBusinessModule types.
- **Chinese MCP connectors implemented** — YuanDian (元典), PkuLaw (北大法宝), Qcc (企查查) `search()` methods now make real HTTP calls to MCP endpoints. Plus new **FYOpen (法源开)** connector added. 4 Chinese connectors + 3 international = 7 total.
- **ConnectorRegistry** — 27 connector entries from 百宸AI系统资源接入清单 v1/v2. ConnectorMetadata struct with name, display_name, description, type, url, usage, auth_method, env_var, priority, region, implemented. Exposed via `GET /api/search/registry`.
- **9 DD agent configs** — DdAgentDomain (9 domains), DdSeverity (P0-P3), FocusAreaAction (Keep/Delete/Add), DdFocusArea, DdAgentConfig with dd_agent_configs() factory. From dd-agents 中国法智能体改写清单. Exposed via `GET /api/dd-configs`.
- **Phase 1 API endpoints** — `GET /api/search/registry` (27 connector metadata entries) + `GET /api/dd-configs` (9 DD agent configs). Both static, no DB needed. Available for deer-flow and qm adapters to discover via HTTP.
- deer-flow Python adapter (~150 lines)
- deer-flow wrapper Dockerfile
- Deployment docs (PLANS, DEPLOYMENT-GUIDE, USER-MANUAL, ARCHITECTURE-DIAGRAMS)
- Graphify knowledge graph: 595 nodes, 1221 edges, 30 communities
- Clippy warnings: 25 → 32 (new dead-code scaffolding from archive taxonomy + connectors, will be wired up)
- Git: 40 commits on main (session 12), all pushed to origin

### Next steps (resume from here on other machine)

1. ~~Push pending commits~~ — DONE (all pushed)
2. **Convert remaining ~173 prompt templates** from client assets into YAML workflows (51/~206 done). See `pacgate-ai/workflows/*.yaml` for format. Source: `pacgate-ai-assets/.../律师角色提示指南/*.md` (5 files, ~206 code blocks). Remaining: 诉讼律师(~57), 非诉律师(~52), 合规律师(~28 remaining), 基金律师(~26 remaining), 律师日常(~23 remaining)
3. ~~Add jurisdiction filtering + source level tagging to pacgate-rag~~ — DONE
4. ~~Add data source connectors~~ — DONE (7 connectors: 4 Chinese active + 3 international active)
5. ~~Add remaining BigLaw agents~~ — DONE (A1-A8 complete)
6. ~~SOUL resolver middleware~~ — DONE
7. ~~Clean up clippy warnings~~ — DONE (43→25, now 32 after session 12 new code)
8. ~~Integration test scaffold~~ — DONE (compiles, requires Postgres at `localhost:5433/pacgate_test`)
9. **qm TypeScript adapter** — Phase 2 collaboration runtime
10. ~~Wire SOUL persona into chat handler~~ — DONE
11. **Run integration test** against real Postgres — test compiles, ready to run when Postgres is reachable
12. ~~Wire workflow YAML loading into API~~ — DONE
13. ~~Wire workflow steps to agent tools~~ — DONE (WorkflowExecutor)
14. ~~Wire WorkflowExecutor into API~~ — DONE (`POST /api/workflows/:id/execute`)
15. ~~Add workflow category filter~~ — DONE (`GET /api/workflows?category=X`)
16. ~~Add workflow categories endpoint~~ — DONE (`GET /api/workflows/categories`)
17. ~~Add workflow search~~ — DONE (`GET /api/workflows?search=keyword`)
18. ~~Add data source connector trait~~ — DONE (`DataSourceConnector` + `SearchRouter` in pacgate-search)
19. ~~Wire SearchRouter into API~~ — DONE (`GET /api/search?q=keyword`, `GET /api/search/connectors`, `GET /api/search/health`)
20. ~~Add data source health check endpoint~~ — DONE (`GET /api/search/health`)
21. ~~Wire SearchRouter into A4 Research Agent~~ — DONE (`legal_search` tool in pacgate-agent with SearchRouter integration)
22. ~~Implement Chinese MCP connectors~~ — DONE (YuanDian/PkuLaw/Qcc/FYOpen `search()` methods implemented with real HTTP calls)
23. ~~Add T1-T4 data classification~~ — DONE (DataLevel enum in pacgate-core, migration 004, RAG SearchFilter)
24. ~~Add 9-directory archive taxonomy~~ — DONE (ArchiveDirectory enum, ProjectOverview, FileDirectoryEntry, ProjectBusinessModule)
25. ~~Expose ConnectorRegistry via API~~ — DONE (`GET /api/search/registry`)
26. ~~Expose DD configs via API~~ — DONE (`GET /api/dd-configs`)
27. **Convert remaining ~173 prompt templates** from client assets into YAML workflows (51/~206 done). Source: `pacgate-ai-assets/.../律师角色提示指南/*.md` (5 files, ~206 code blocks). Remaining: 诉讼律师(~57), 非诉律师(~52), 合规律师(~28 remaining), 基金律师(~26 remaining), 律师日常(~23 remaining)
28. **Add archive collection workflow templates** — the 3-phase project archive workflow from 项目档案目录及说明
29. **Add international connectors** — Vaquill (US), Ansvar (EU), OpenCorporates (offshore), EUR-Lex from client asset credentials
30. **Wire DD configs into WorkflowExecutor** — Phase 2: inject DdAgentConfig as system prompt layer when running DD workflows
31. **qm TypeScript adapter** — Phase 2 collaboration runtime
32. **Run integration test** against real Postgres — test compiles, ready to run when Postgres is reachable at `localhost:5433/pacgate_test`
33. **Wire DataLevel into API** — expose data_level filtering in `GET /api/search` and document upload endpoints

### Important reminders

- **Repo is private** — only accessible to JZKK720 account
- **Windows proxy fix**: set `$env:NO_PROXY = "localhost,127.0.0.1,::1"` before graphify or Ollama tools
- **sqlx uses postgres** (not sqlite) — workspace Cargo.toml has `features = ["postgres", ...]`
- **All commits pushed** — repo is in sync with origin (session 12)
- **Client assets in pacgate-ai-assets/** — 150+ prompt templates, SOUL definitions, BigLaw architecture, data source configs, project archive taxonomy. See deploy/PLANS.md for the enrichment plan.
- **YAML workflows** — `pacgate-ai/workflows/*.yaml` (9 files, 51 templates). Load with `pacgate_workflow::load_from_yaml_dir()`. Test: `cargo test -p pacgate-workflow --test yaml_loader`. API: `GET /api/workflows?category=X&search=Y`, `GET /api/workflows/categories`, `GET /api/workflows/:id`, `POST /api/workflows/:id/execute`
- **Data source connectors** — `pacgate-search` crate with `DataSourceConnector` trait, `SearchRouter`, 7 connectors (4 Chinese: YuanDian, PkuLaw, Qcc, FYOpen + 3 international: CourtListener, SEC EDGAR, GLEIF). `default_router()` factory. Env vars: `YUANDIAN_API_KEY`, `PKULAW_API_KEY`, `QCC_API_KEY`, `FYOPEN_API_KEY`, `COURTLISTENER_API_KEY`
- **Integration test** — run with `cargo test -p pacgate-api --test integration -- --ignored` (requires Postgres at `localhost:5433/pacgate_test`, user=hermes, password=changeme)
- **RAG migrations** — 003: adds `jurisdiction` + `source_level` columns; 004: adds `data_level` column (T1-T4). Run automatically by `RagStore::run_migrations()`
- **Archive taxonomy** — `DataLevel` (T1-T4), `ArchiveDirectory` (00-08), `ProjectOverview`, `FileDirectoryEntry`, `ProjectBusinessModule` in `pacgate-core`. From client asset 百宸完整项目及事项档案提交目录与整理说明_v1.0
- **Client asset MCP credentials** — found in `pacgate-ai-assets/.../MCP授权/法律数据库MCP.md` and `境外法律数据库和网站.md`. Contains endpoints + API keys for YuanDian, PkuLaw, Qcc, FYOpen, CourtListener, Vaquill, Ansvar, OpenCorporates

## Commit checklist (before pushing from another machine)

```powershell
cd pacgate-ai
cargo check                    # must pass
cargo test -p pacgate-api --test smoke  # 15 tests must pass
cargo clippy                   # check for new warnings
git add -A
git commit -m "feat: <description>"
git push
```

## Important notes

- **Repo is private** — only accessible to JZKK720 account
- **Windows proxy fix**: set `$env:NO_PROXY = "localhost,127.0.0.1,::1"` before any tool that calls Ollama or localhost services (graphify, OpenAI SDK, etc.)
- **sqlx uses postgres** (not sqlite) — workspace `Cargo.toml` has `features = ["postgres", ...]`
- **No .env in repo** — it's gitignored. Copy `.env.example` to `.env` and fill in secrets
- **Cargo.lock is committed** — ensures reproducible builds across machines
