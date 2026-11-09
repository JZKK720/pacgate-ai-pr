# Pacgate AI - Phase 1 Local Pilot

Privacy-first legal AI platform for multi-tenant attorney offices. Headless Rust metadata gateway with deer-flow research runtime, qm collaboration runtime, and OpenViking long-term memory lane.

**中文文档：** [README-ZH.md](README-ZH.md) | [员工使用手册](docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.md)

## Release: v0.2.33 (2026-11-09)

- **One admission decision for document body content.** `/api/documents/:id/download` refused a `pending` document while `/api/documents/:id/extract` returned its body text — the tenant check was the only check it had. Both now call `pacgate_api::egress::assert_readable`, and **every read and every refusal writes an audit row** (`document.read`, with `purpose`, `document_state`, `data_level` and `outcome`). The cause was structural rather than clerical: each handler carried its own rule, so the third one written later had nothing to inherit. `documents.rs` now pins the list of body-returning handlers, so adding one without the chokepoint fails the suite.
- **`/extract` no longer returns pre-redaction spans.** `document_spans.text` stores the text as the extractor read it, and a sanitize job never rewrites that table — redaction produces `kb_chunks`. So a `sanitized` document's cached extract returned the ORIGINAL body inside `spans[].text` while the top-level `text` field looked clean; gating `text` alone would have been a partial fix that reads as a complete one. A sanitized extraction now serves redacted `text` from `kb_chunks` and returns no spans, because redacted text has no page coordinates to report. This is a real capability reduction, stated here rather than left to be discovered.
- **An unparseable `max_data_level` is refused instead of silently widened.** `kb_search` resolved the ceiling with `.and_then(from_code).unwrap_or(T3)`, so a caller asking for `T1` who sent a typo received `T3` content — the filter failed in the one direction that discloses more, with a 200 and no warning. An absent parameter still defaults to `T3`; a present-but-invalid one is now 400. This is what makes the manual's "retrieval cannot silently widen" a description of the code rather than an intention.
- **`data_level` is gone from external connector search.** It was validated, logged as "tagged for audit", and then discarded — `SearchQuery` has no data-level field because a connector returns third-party results with no Pacgate classification, and nothing wrote an audit row. Accepting it was a false compliance signal, so it is now a 400 and the MCP tool no longer offers the argument. `/api/kb/search` is the endpoint that actually filters.
- **Boundary-rule enforcement is now real, and reports what it cannot enforce.** `EnforcementPoint` was declared with three variants and a doc comment on each saying *where* a red line is enforced, then written 35 times across the SOUL personas and **read nowhere** — a repo-wide search for the field returned only its own declaration. Every rule tagged `WorkflowGate` or `ApiMiddleware` therefore behaved exactly like `AgentPrompt` while reading as a platform control in the persona source, including `"No legal conclusion without Sylvie's review"` and `"Block any output with unverified citations"`. Two changes close this:
  - **The prompt no longer asserts controls that do not exist.** `pacgate_core::enforcement::render_rules_for_prompt` splits the rule list into `enforced outside the model` and `self-check`. Previously all 35 rules appeared under one `BOUNDARY RULES (red lines)` heading with identical formatting, so the prompt told the model that 16 external gates existed.
  - **One gate is now genuinely built: citations are verified against the source.** `enforcement::evaluate_turn` checks each `CitationRef.verbatim` against the **sanitised** text of the cited document (same fail-closed `sanitised_text` contract the agent tools use — a verifier is another reader). A quote not found, or a source that cannot be read, makes the citation unsupported. Full-width/half-width punctuation and extraction whitespace are normalised so a PDF line-break is not a false mismatch; a changed figure is still a mismatch.
  - **Every other advertised gate is reported as `not_implemented`, not as a pass.** `ChatResponse.enforcement` and the new `SsePayload::Enforcement` frame carry a per-rule verdict, and the verdicts are written to `audit_log` as `chat.boundary_gate.evaluated` / `.violated`. The streaming path runs the gates too: a gate that only fires on the buffered endpoint is a suggestion with two code paths.
  - Measured 2026-11-09: of 16 rules declaring external enforcement, **1 is built and 15 are not**. `pacgate-persona` pins both numbers, so a rule cannot be quietly re-labelled as a gate — red-checked by re-tagging one `AgentPrompt` rule as `WorkflowGate`, which fails the suite.
- **Local-service proxy fix.** `reqwest` 0.12 picks up the operating-system proxy when no `*_PROXY` variable is set, and that inherited configuration has no loopback exemption. Two consequences, both now closed by `pacgate_core::http::local_service_client`, which clears the platform proxy but still honours an explicit `HTTP(S)_PROXY` for remote providers:
  - **On Windows this broke loopback outright.** `127.0.0.0/8` is not bypassed by the platform setting, so a call to `http://127.0.0.1:<port>` went to the proxy and came back `502 Bad Gateway`. Measured 2026-11-04: 6 of 12 `pacgate-agent` tests failed this way and passed 12 of 12 once `NO_PROXY` was exported. The helper now exempts `localhost`, `127.0.0.0/8`, `::1`, `*.local` and `host.docker.internal`.
  - **The deployed containers do not inherit a proxy** (verified: no `*_PROXY` in the running `pacgate-api`), so the client-side Ollama, OCR and embedding calls were not affected. The change is still applied to those clients so a machine or image that does set a proxy cannot silently route internal traffic through it.
- Rust metadata core: 12 crates + 4 WASM crates, smoke/agent/workflow/integration tests passing
- 220 YAML workflow templates across 15 files
- 30 legal personas (20 practice-area + 10 SOUL)
- 10 data source connectors in the Rust `default_router()` (YuanDian, PkuLaw, Qcc, FyOpen, CourtListener, SecEdgar, Gleif, Vaquill, EurLex, OpenCorporates) — the deer-flow MCP surface exposes 17 enabled servers
- RAG retrieval (pgvector + tsvector + Ollama embeddings, T1-T4 data level filtering) — fully on-device
- OpenViking memory lane: ov-remember / ov-search / ov-read bridge via qm, MCP recall in deer-flow
- Auth (JWT + argon2 + SOUL resolver middleware)
- pacgate-api image: `ghcr.io/jzkk720/pacgate-api:0.2.33` (public; LLM router honors `OLLAMA_BASE_URL`, per-tenant model overrides)
- deer-flow wrapper image: `ghcr.io/jzkk720/deer-flow-pacgate:0.2.33` (public)
- pacgate-mcp bridge image: `ghcr.io/jzkk720/pacgate-mcp:0.2.33` (public; exposes 26 MCP tools incl. documents/workflows)
- deer-flow frontend wrapper image: `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.2.33` (public; gateway URL baked in at build time)
- OCR service image: `ghcr.io/jzkk720/ocr-service:0.2.33` (public; PaddleOCR extraction, first-class since 0.1.16)
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
| `docs/LOCAL-FIRST-LEGAL-AI-STACK-REFERENCE.md` | Bilingual (EN/ZH) technical reference for the legal-agent chain, figures included; DOCX + PDF rendered by `scripts/render_legal_ai_reference.py` |
| `docs/` | Proposal pages, build plans, progress reportcard |
| `docs/PACGATE-AI-BUILD-PLAN-PHASE1.md` | Phase 1 commercial and technical plan |

## GHCR images

Pacgate runtime images are **public** (anonymous pull verified). The source repo remains private. All images are built and pushed to GHCR by `.github/workflows/build-ghcr.yml`, so both AIPCs stay in sync.

**`ghcr.io/jzkk720/*` is the ONLY image namespace, and the only one `deploy/client-bundle/compose.prod.yaml` pins.** It is the code master repo and publishes all five images. `ghcr.io/pacgate-ai/*` is a legacy mirror: its tags still resolve for older releases but no longer receive new ones, so a `pacgate-ai` reference means an out-of-date document. If you find one, use the `jzkk720` tag from the table below.

> Corrected 2026-09-22. This paragraph previously stated the opposite (`pacgate-ai` only, `jzkk720` publishes nothing and mostly 404s). That was true before the namespace moved in plan 016 and has been inverted ever since. Verified at the time of writing: all five `jzkk720/*:0.1.19` images return HTTP 200 anonymously, and `pacgate-ai/*:0.1.14` still resolves but is superseded.

| Image | Contents | Base |
|-------|----------|------|
| `ghcr.io/jzkk720/pacgate-api:0.2.33` | Rust binary + SQL migrations | `rust:1.94-bookworm` -> `debian:bookworm-slim` |
| `ghcr.io/jzkk720/pacgate-mcp:0.2.33` | pacgate-api MCP bridge (19 tools incl. documents/workflows) | `python:3.12-slim` |
| `ghcr.io/jzkk720/deer-flow-pacgate:0.2.33` | deer-flow backend + Python adapter | `ghcr.io/bytedance/deer-flow-backend` (pinned SHA) |
| `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.2.33` | deer-flow Next.js research UI (gateway URL baked in) | `node:22-alpine` |
| `ghcr.io/jzkk720/ocr-service:0.2.33` | PaddleOCR extraction service (first-class since 0.1.16) | `python:3.12-slim` |

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