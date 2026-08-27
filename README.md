# Pacgate AI - Phase 1 Local Pilot

Privacy-first local legal AI platform for multi-tenant attorney offices. Headless Rust metadata gateway with deer-flow research runtime and qm collaboration runtime.

## Release: v0.1.1 (2026-08-19)

- Rust metadata core: 11 crates, 23 smoke tests + 5 agent tests + 3 workflow tests + 2 integration tests passing
- 220 YAML workflow templates across 15 files
- 30 legal personas (20 practice-area + 10 SOUL)
- 11 data source connectors (4 Chinese + 7 international)
- RAG retrieval (pgvector + tsvector + Ollama embeddings, T1-T4 data level filtering)
- Auth (JWT + argon2 + SOUL resolver middleware)
- deer-flow wrapper image: `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0`
- pacgate-api image: `ghcr.io/jzkk720/pacgate-api:0.1.2` (includes YuanDian/PkuLaw connector fixes)
- qm collaboration bridge validated (Python CLI, HARNESS=pi, real Ollama)
- Client deployment bundle checked in at `deploy/client-bundle/`
- Knowledge graph: 917 nodes, 2157 edges, 47 communities

## Quick deploy

Clone on each AIPC and follow the handbook:

```powershell
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
```

Read `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` for the full step-by-step install guide.

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
| `pacgate-ai/crates/` | Rust workspace (11 crates) |
| `pacgate-adapters/python/` | deer-flow adapter (~150 lines) |
| `pacgate-adapters/typescript/` | qm contract library (8 tests) |
| `deploy/client-bundle/` | Client deployment bundle (compose, install.ps1, nginx, qm bootstrap) |
| `deploy/qm-pacgate/` | qm deployment directory (config, sandbox, bridge tool) |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` | Two-AIPC step-by-step install guide |
| `deploy/SETUP-AND-OPERATIONS.md` | Full 3-day on-site installation guide |
| `deploy/DEPLOYMENT-GUIDE.md` | Engineer-level deployment details |
| `docs/` | Proposal pages, build plans, progress reportcard |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | Phase 1 commercial and technical plan |

## GHCR images

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