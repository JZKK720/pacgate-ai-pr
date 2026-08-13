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

## Current status (as of 2026-08-13, session 4)

### Done — Phase 1 critical path complete
- Full Rust workspace compiles cleanly (`cargo check` passes)
- 15 smoke tests pass (`cargo test -p pacgate-api --test smoke`)
- Storage layer: FsDocumentStore + MatterStore + TenantStore + SQL migrations
- Auth: JWT + argon2 + login/register + middleware + soul_id in Claims
- API routes: matters, documents, chat, workflows, auth — all wired to real stores
- LLM router: 7 providers, 3-tier routing
- RAG: pgvector + tsvector hybrid retrieval + Ollama embeddings + chunk ingestor
- 20 legal personas (practice-area personas) + 6 SOUL personas (Justin, Sylvie, A1, A4, A5, A8)
- 10 workflow templates (contract review, DD, legal research, etc.)
- SOUL architecture: identity overlay types (SoulPersona, BoundaryRule, EscalationRule, etc.)
- Legal domain enums: SourceLevel, ReviewStatus, SecurityLevel, RiskGrade
- deer-flow Python adapter (~150 lines)
- deer-flow wrapper Dockerfile
- Deployment docs (PLANS, DEPLOYMENT-GUIDE, USER-MANUAL, ARCHITECTURE-DIAGRAMS)
- Graphify knowledge graph: 595 nodes, 1221 edges, 30 communities
- Git: 4 commits on main, 2 pushed to origin (2 pending push due to network)

### Next steps (resume from here on other machine)
1. **Push pending commits** — `git push` (2 commits ahead of origin)
2. **Convert 150+ prompt templates** from client assets into pacgate-workflow
3. **Add jurisdiction filtering + source level tagging** to pacgate-rag
4. **Add data source connectors** (15+ external legal databases, 3 Chinese MCP endpoints)
5. **Add remaining BigLaw agents** (A2 Intake/Conflicts, A3 Domain Experts, A6 Devil's Advocate, A7 Document Pipeline)
6. **SOUL resolver middleware** in pacgate-auth (resolves soul_id → SoulPersona at request time)
7. **Clean up 38 clippy warnings** (unused imports)
8. **Integration test** — start Postgres + pacgate-api, verify end-to-end
9. **qm TypeScript adapter** — Phase 2 collaboration runtime

### Important reminders
- **Repo is private** — only accessible to JZKK720 account
- **Windows proxy fix**: set `$env:NO_PROXY = "localhost,127.0.0.1,::1"` before graphify or Ollama tools
- **sqlx uses postgres** (not sqlite) — workspace Cargo.toml has `features = ["postgres", ...]`
- **2 commits need pushing** — `git push` when network is available
- **Client assets in pacgate-ai-assets/** — 150+ prompt templates, SOUL definitions, BigLaw architecture, data source configs. See deploy/PLANS.md for the enrichment plan.

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