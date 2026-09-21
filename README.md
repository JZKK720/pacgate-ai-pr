# Pacgate AI - Phase 1 Local Pilot

Privacy-first legal AI platform for multi-tenant attorney offices. Headless Rust metadata gateway with deer-flow research runtime, qm collaboration runtime, and OpenViking long-term memory lane.

**中文文档：** [README-ZH.md](README-ZH.md) | [员工使用手册](docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md)

## Release: v0.1.14 (2026-09-16)

- Rust metadata core: 12 crates + 4 WASM crates, smoke/agent/workflow/integration tests passing
- 220 YAML workflow templates across 15 files
- 30 legal personas (20 practice-area + 10 SOUL)
- 10 data source connectors in the Rust `default_router()` (YuanDian, PkuLaw, Qcc, FyOpen, CourtListener, SecEdgar, Gleif, Vaquill, EurLex, OpenCorporates) — the deer-flow MCP surface exposes 17 enabled servers
- RAG retrieval (pgvector + tsvector + Ollama embeddings, T1-T4 data level filtering) — fully on-device
- OpenViking memory lane: ov-remember / ov-search / ov-read bridge via qm, MCP recall in deer-flow
- Auth (JWT + argon2 + SOUL resolver middleware)
- pacgate-api image: `ghcr.io/jzkk720/pacgate-api:0.1.17` (public; LLM router honors `OLLAMA_BASE_URL`, per-tenant model overrides)
- deer-flow wrapper image: `ghcr.io/jzkk720/deer-flow-pacgate:0.1.17` (public)
- pacgate-mcp bridge image: `ghcr.io/jzkk720/pacgate-mcp:0.1.17` (public; exposes 10 MCP tools incl. documents/workflows)
- deer-flow frontend wrapper image: `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.17` (public; gateway URL baked in at build time)
- OCR service image: `ghcr.io/jzkk720/ocr-service:0.1.17` (public; PaddleOCR extraction, first-class since 0.1.16)
- qm collaboration bridge validated (Python CLI, HARNESS=pi, real Ollama)
- Client deployment bundle checked in at `deploy/client-bundle/` — fresh-clone install path verified
- Knowledge graph: 935 nodes, 2220 edges, 49 communities
- Staff-facing user handbooks (EN/ZH) at `docs/PACGATE-LAW-STAFF-HANDBOOK*.md` with PDF exports

### Model policy (decided 2026-08-30)

Workflow tiers run on-device. The **client runtime** (`deploy/client-bundle/deer-flow-config.yaml`) defaults to local `ornith-1.5:9b/35b` and `nemotron-3.5-lightning:30b` for research; `nomic-embed-text` is used for RAG embeddings. The **dev/CI reference** config (`deploy/deer-flow-pacgate/config.yaml`) uses cloud-routed `deepseek-*-cloud` tags for speed. qm uses `glm-5.3-flash:cloud` via `PI_MODEL`. The firm accepts prompt egress to ollama.com for chat generation; document storage, RAG, and memory extraction never leave the AIPC. `ollama signin` is an install precondition for cloud-tagged models.

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
| `pacgate-adapters/python/` | deer-flow adapter (176 lines) |
| `pacgate-adapters/typescript/` | qm contract library (8 tests) |
| `deploy/client-bundle/` | Client deployment bundle (compose, install.ps1, nginx, qm bootstrap) |
| `deploy/client-delivery/` | Client-facing delivery package (docs PDFs + README index) |
| `deploy/handbooks/` | Integration handbooks (deer-flow/qm + OpenViking + pacgate gateway) + render script |
| `deploy/qm-pacgate/` | qm deployment directory (config, sandbox, bridge tool) |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` | Two-AIPC step-by-step install guide |
| `deploy/SETUP-AND-OPERATIONS.md` | Full 3-day on-site installation guide |
| `deploy/DEPLOYMENT-GUIDE.md` | Engineer-level deployment details |
| `docs/PACGATE-LAW-STAFF-HANDBOOK.md` | Non-technical staff user guide (EN; ZH + PDF alongside) |
| `docs/` | Proposal pages, build plans, progress reportcard |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | Phase 1 commercial and technical plan |

## GHCR images

Pacgate runtime images are **public** (anonymous pull verified). The source repo remains private. All images are built and pushed to GHCR by `.github/workflows/build-ghcr.yml`, so both AIPCs stay in sync.

**`ghcr.io/jzkk720/*` is the ONLY image namespace, and the only one `deploy/client-bundle/compose.prod.yaml` pins.** It is the code master repo and publishes all five images. `ghcr.io/pacgate-ai/*` is a legacy mirror: its tags still resolve for older releases but no longer receive new ones, so a `pacgate-ai` reference means an out-of-date document. If you find one, use the `jzkk720` tag from the table below.

> Corrected 2026-09-22. This paragraph previously stated the opposite (`pacgate-ai` only, `jzkk720` publishes nothing and mostly 404s). That was true before the namespace moved in plan 016 and has been inverted ever since. Verified at the time of writing: all five `jzkk720/*:0.1.17` images return HTTP 200 anonymously, and `pacgate-ai/*:0.1.14` still resolves but is superseded.

| Image | Contents | Base |
|-------|----------|------|
| `ghcr.io/jzkk720/pacgate-api:0.1.17` | Rust binary + SQL migrations | `rust:1.94-bookworm` -> `debian:bookworm-slim` |
| `ghcr.io/jzkk720/pacgate-mcp:0.1.17` | pacgate-api MCP bridge (10 tools incl. documents/workflows) | `python:3.12-slim` |
| `ghcr.io/jzkk720/deer-flow-pacgate:0.1.17` | deer-flow backend + Python adapter | `ghcr.io/bytedance/deer-flow-backend` (pinned SHA) |
| `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.17` | deer-flow Next.js research UI (gateway URL baked in) | `node:22-alpine` |
| `ghcr.io/jzkk720/ocr-service:0.1.17` | PaddleOCR extraction service (first-class since 0.1.16) | `python:3.12-slim` |

Every image also carries `:latest`, kept in lockstep with the version tag.

qm does not use a GHCR image. It runs via `qm up` from the checked-in `deploy/qm-pacgate/` directory.

See `deploy/README-BUILD.md` for the build/push flow and the owner-namespace decision.

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