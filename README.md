# Pacgate AI - Phase 1 Local Pilot

Privacy-first legal AI platform for multi-tenant attorney offices. Headless Rust metadata gateway with deer-flow research runtime, qm collaboration runtime, and OpenViking long-term memory lane.

**中文文档：** [README-ZH.md](README-ZH.md) | [员工使用手册](docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md)

## Release: v0.1.2 (2026-08-30)

- Rust metadata core: 12 crates + 4 WASM crates, smoke/agent/workflow/integration tests passing
- 220 YAML workflow templates across 15 files
- 30 legal personas (20 practice-area + 10 SOUL)
- 11 data source connectors (4 Chinese + 7 international)
- RAG retrieval (pgvector + tsvector + Ollama embeddings, T1-T4 data level filtering) — fully on-device
- OpenViking memory lane: ov-remember / ov-search / ov-read bridge via qm, MCP recall in deer-flow
- Auth (JWT + argon2 + SOUL resolver middleware)
- pacgate-api image: `ghcr.io/jzkk720/pacgate-api:0.1.2` (public; LLM router honors `OLLAMA_BASE_URL`, per-tenant model overrides)
- deer-flow wrapper image: `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` (public)
- qm collaboration bridge validated (Python CLI, HARNESS=pi, real Ollama)
- Client deployment bundle checked in at `deploy/client-bundle/` — fresh-clone install path verified
- Knowledge graph: 935 nodes, 2220 edges, 50 communities
- Staff-facing user handbooks (EN/ZH) at `docs/PACGATE-LAW-STAFF-HANDBOOK*.md` with PDF exports

### Model policy (decided 2026-08-30)

Workflow tiers run on-device (gemma4 / qwen3.8 / nomic-embed-text). Deer-flow and qm chat generation intentionally use cloud-routed Ollama models (`deepseek-*-cloud`) for research speed — the firm accepts prompt egress to ollama.com; document storage, RAG, and memory extraction never leave the AIPC. `ollama signin` is an install precondition.

## Quick deploy

Clone on each AIPC and follow the handbook:

```powershell
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
```

Read `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` for the full step-by-step install guide. GHCR runtime images are public — no `docker login` needed.

## Architecture

```
nginx :8081
├── /          -> pacgate-api :8080 (Rust, Axum)
├── /api/      -> pacgate-api :8080
├── /research/ -> deer-flow :8001 (Python, LangGraph)
└── qm :8182   -> (separate, via qm up)

Postgres :5432 (metadata DB)
Ollama :11434 (native, GPU/NPU)
```

Both AIPC machines run the full stack identically. Each machine is independently operational.

## Key directories

| Path | Purpose |
|------|---------|
| `pacgate-ai/crates/` | Rust workspace (12 crates) |
| `pacgate-adapters/python/` | deer-flow adapter (~150 lines) |
| `pacgate-adapters/typescript/` | qm contract library (8 tests) |
| `deploy/client-bundle/` | Client deployment bundle (compose, install.ps1, nginx, qm bootstrap) |
| `deploy/qm-pacgate/` | qm deployment directory (config, sandbox, bridge tool) |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` | Two-AIPC step-by-step install guide |
| `deploy/SETUP-AND-OPERATIONS.md` | Full 3-day on-site installation guide |
| `deploy/DEPLOYMENT-GUIDE.md` | Engineer-level deployment details |
| `docs/PACGATE-LAW-STAFF-HANDBOOK.md` | Non-technical staff user guide (EN; ZH + PDF alongside) |
| `docs/` | Proposal pages, build plans, progress reportcard |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | Phase 1 commercial and technical plan |

## GHCR images

Both Pacgate packages are **public** (anonymous pull verified 2026-08-30). The source repo remains private.

| Image | Contents | Base |
|-------|----------|------|
| `ghcr.io/jzkk720/pacgate-api:0.1.2` | Rust binary + SQL migrations | `rust:1.94-bookworm` -> `debian:bookworm-slim` |
| `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` | deer-flow backend + Python adapter | `ghcr.io/bytedance/deer-flow-backend` (pinned SHA) |

qm does not use a GHCR image. It runs via `qm up` from the checked-in `deploy/qm-pacgate/` directory.

## Testing

```powershell
cd pacgate-ai
cargo check
cargo test -p pacgate-api --test smoke
cargo test -p pacgate-agent
cargo test -p pacgate-workflow --test yaml_loader
```

Integration tests require Postgres at `localhost:5433/pacgate_test`:

```powershell
$env:PACGATE_TEST_DATABASE_URL='postgres://hermes:changeme@localhost:5433/pacgate_test'
cargo test -p pacgate-api --test integration -- --ignored
```

TypeScript adapter tests:

```powershell
cd pacgate-adapters/typescript
npm test
```

## License

Private repository. All Phase 1 deliverable copyright assigned to Pacgate. See `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` for commercial terms.