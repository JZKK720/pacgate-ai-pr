# Pacgate-ai bundle upgrade & architecture review — deer-flow 2.2.0, qm 0.1.19, OpenViking 0.5.6, graph + harness engineering

**Date:** 2026-11-24
**Status:** Draft for review. Nothing has been changed, built, or deployed. Every version claim below was measured against the repo, the registry, or upstream docs on 2026-11-24; where evidence is thin it is labelled as such.
**Companion doc:** `docs/superpowers/specs/2026-11-24-deer-flow-2.2.0-upgrade-design.md` (deer-flow-specific patch rebase detail).
**Inputs this consolidates:** (a) full-repo `graphify` build at `graphify-out/`, (b) local code inspection of pacgate-api / pacgate-adapters / deploy bundle, (c) web research on harness engineering, graph engineering, and the three upstream projects' release notes.

---

## 1. Executive summary

Three upgrades are queued, and they are not the same class of work:

| Component | Ours | Latest | Gap | Class | Risk |
|---|---|---|---|---|---|
| deer-flow backend+frontend | v2.0.0 digest `e7c503a8…` | **v2.2.0** (2026-11-04) | 2 minor, 2,248 commits | Re-derivation, not a bump | **High** |
| qm (`@yc-software/qm`) | 0.1.18 (dist-tag `latest`) | **0.1.19** (dist-tag `next`, 2026-11-11) | 1 patch, 4 files | Digest swap, staged | **Low–Medium** |
| OpenViking | v0.4.16 (image created 2026-08-21) | **v0.5.6** (2026-11-24) | 9 minors | Migration project | **High–Medium** |

The architecture question the user asked — *should the bundle adopt "graph engineering" and "harness engineering"?* — has a shorter answer than the marketing suggests: **harness engineering, yes, explicitly, and we already do half of it; graph engineering, only as a narrow retrieval layer, not as a memory system.** The details below include the evidence against both over-adoption and under-adoption.

No component should be upgraded in the same release. Sequence them (§8).

---

## 2. What graphify actually showed

`graphify update .` on the working tree (commit `eef49a8`) produced **11,166 nodes, 16,411 edges, 904 communities** (609 shown, 295 thin). 96% of edges are `EXTRACTED`, 4% `INFERRED`, 0 ambiguous. `graphify diagnose multigraph`: zero duplicate endpoints, zero dangling endpoints — the graph is clean as a *code-navigation* artefact.

What it gives us, honestly stated:

- It is a fast architectural index: `pacgate-api` (Rust), `pacgate-adapters` (Py), `deploy/qm-pacgate`, `deploy/client-bundle` patches, and the docs corpus all land in one queryable graph. `graphify query "how does deer-flow persist matter memory to pacgate-api"` returned the correct subgraph (storage.py → PacgateMemoryStorage → PacgateApiClient, plus the QM bridge `pacgate_qm.py`).
- It is a **snapshot of code structure, not runtime behaviour**, and it includes docs/markdown as nodes, so large generic hubs (`environment`, `json`, `typing`) are noise.
- 60 files produced no symbols; 11 `.sql` and 8 `.tf` files were skipped (missing `tree_sitter_sql`/`tree_sitter_hcl`), so the **migrations** — the source of truth for persistence — are *not* in the graph. That is the single most important caveat for planning an upgrade from it.
- `graphify-out/` is gitignored and regenerable; `deploy/archive/graphify-graph.json` (2026-10-04, 935 nodes) is the previous snapshot and is stale.

**Recommendation:** keep graphify as a developer navigation tool and as a *review aid during the upgrade* (diff node sets between HEAD and the post-upgrade tree to spot unexpectedly deleted modules). Do not promote it to a runtime component. It is not memory, not RAG, and not an audit artefact — and its licence and maintenance posture have not been evaluated for distribution to clients (see §9.4).

---

## 3. Where persistence actually lives today (the thing being upgraded)

This is the spine the three upgrades touch. Everything below is in the repo today.

### 3.1 Postgres (`pacgate-db`, `pgvector/pgvector:pg16`) — durable business state
Migrations `pacgate-ai/migrations/001`–`009`:

| Table | Purpose | Notes |
|---|---|---|
| `tenants`, `users` | tenancy, roles (`admin`/`partner`/`associate`…), `system_role` | `tenant_id` everywhere |
| `matters` | the matter — the atom of the whole product | `matter_dir` under `DATA_DIR` |
| `documents` | uploaded/generated documents, versions | `storage_path`, `format`, `owner_id` |
| `audit_log` | append-only audit | unchanged |
| `audit`/`document_events` | (via API handlers) | event stream for matter activity |
| `kb_chunks` | RAG chunks, `embedding vector(768)` (nomic-embed-text), `content_tsv`, `data_level` (T1–T4), `jurisdiction`, `source_level`, `sanitization_state` | HNSW + GIN indexes |
| `sanitizer_jobs` + `redaction_ledger_rows` | sanitizer runs, verdicts, redaction ledger | the legal-safety spine |

`004_data_level.sql` (T1–T4) and `004_matter_external_keys.sql` (qm↔pacgate matter linking), `005_sanitization_state.sql`, `009_cjk_fulltext.sql` are all live. **There is no graph table, no entity table, no relationship table.** Nothing in Postgres models cross-matter relationships.

### 3.2 Filesystem (`DATA_DIR=/data/tenants`, bind-mounted per tenant)

```
tenants/{tenant_id}/matters/{matter_id}/
    memory.json                  <- written by pacgate-api, read/written by deer-flow adapter
    docs/…                       <- uploads, extracted text, generated docx/pdf
    memory.json (tmp + fsync)    <- crash-safe write path (matters.rs:63)
```
Matter memory is **a JSON file per matter on disk**, not a database row and not in OpenViking. `pacgate-adapters/python/pacgate_deerflow_adapter/storage.py` implements `MemoryStorage.load/save` against `GET/POST /api/matters/:id/memory`, which round-trips the JSON file with `If-Match`-style revision semantics (`memory_revision()`, atomic tmp+rename).

### 3.3 pacgate-api (Rust/Axum) — the only writer with authority
Key handlers (all under `pacgate-ai/crates/pacgate-api/src/`):

- `matters.rs` — matter CRUD, `/api/matters/:id/memory` get/save (the file-backed memory store, with revision checks — this is the same contract the deer-flow adapter expects).
- `documents.rs` / `extract.rs` / `text_extract.rs` — upload → extract (OCR/markitdown) → `document_extractions` table.
- `sanitize.rs` — sanitization jobs, redaction ledger, approval gate.
- `workflows.rs` — workflow catalogue (file-backed `*.yaml` list) + execute via agent loop.
- `workspace.rs` — aggregated matter workspace view (documents + extractions + chunk status).
- `search.rs` — semantic + lexical retrieval over `kb_chunks`.
- `chat.rs` — the main agent endpoint; 2025-era agent loop lives in `pacgate-agent`.

### 3.4 pacgate-mcp (Python, stdio/HTTP MCP) — the tool surface for LLM lanes
`deploy/pacgate-mcp/server.py` — 25+ `pacgate_*` tools: `pacgate_kb_search`, `pacgate_read_memory`/`pacgate_write_memory`, `pacgate_list_workflows`/`pacgate_execute_workflow`, `pacgate_sanitize_*`, `pacgate_redline_compare`, `pacgate_upload_document`, etc. Every tool is a thin HTTP call to pacgate-api. **The MCP server holds no state.** This is the correct layering and it survives every upgrade described here.

### 3.5 OpenViking (`ghcr.io/volcengine/openviking@sha256:46f9…`, v0.4.16) — agent working memory / context DB
Used by deer-flow via the OpenViking MCP (`ov-*` tools: `ov-remember`, `ov-search`, `ov-read`) and by the QM sandbox via `pacgate-qm`-injected `OPENVIKING_*` env. Storage: `./openviking/workspace/{viking,vectordb,...}` on disk; embedding via Ollama `nomic-embed-text` (768d); VLM via `nemotron-3.5-bolt:e4b-q8_0`. It holds **agent working memory and extracted knowledge**, scoped by user/session, **not** matter-of-record legal state. That separation is correct and should be kept.

### 3.6 deer-flow (`deer-flow-pacgate:0.2.37`) — agent runtime
Bind-mounted patches over an upstream v2.0.0 image (28 files). Memory goes through the adapter in §3.2/§3.3 — *not* through OpenViking for matter facts. OpenViking is only the agent's own working set/scratch.

### 3.7 qm (`@yc-software/qm`, pinned 0.1.18) — the team surface
Two-service compose (`core` + `pg`). qm agents get their own Postgres; they reach pacgate through `pacgate-qm` (a ~600-line CLI shipped in the sandbox image) which:
- `ensure-matter` — create/fetch a matter keyed by `(org_id, channel_id)` via pacgate-api,
- `memory-get`/`memory-save` — read/write the *same file-backed matter memory* as deer-flow,
- `doc-upload` / `doc-list` / `doc-convert` — push files into the matter and trigger extraction,
- `workflow-list` / `workflow-execute` — run pacgate workflows,
- `ov-remember`/`ov-search`/`ov-read` — the same OpenViking instance deer-flow uses.

So the "two AIs, one matter" path is: **QM chat → sandbox → `pacgate-qm` → nginx `/pacgate/` → pacgate-api → matters/memory.json**, and **QM chat → `ov-*` → OpenViking** for recall. The pacgate-ui → deer-flow → pacgate-api path is the same matter memory file. That is the round trip.

### 3.8 What is *not* persisted anywhere (gap list)
1. Agent run traces / tool-call ledger (beyond `audit_log` summaries) — no structured span store.
2. Workflow *execution* records — `workflows.rs` executes but there is no `workflow_runs` table.
3. Redline/docx comments as first-class objects (they live inside documents).
4. Cross-matter relationships (parent/child, related parties, precedent links).
5. `outline`/`template` library metadata beyond the YAML files (`pacgate-ai/workflows/*.yaml`, 15 tracked workflows).
6. qm-side matter links are stored in qm's own Postgres, not joined to pacgate's `matters` — the `external_key` on `matters` (migration 004) is the only bridge and nothing writes it except pacgate-api.

---

## 4. What "graph engineering" would and would not buy us

The phrase is being used for two different things in 2025–2026 literature. They need separating before anyone budgets for them.

**4.1 Graph-structured retrieval (knowledge graphs).** Microsoft GraphRAG, LightRAG, Zep/Graphiti, Mem0-graph, Cognee. The honest reading of the evidence:
- GraphRAG is **in maintenance mode** (Microsoft, 2025-07). LazyGraphRAG (Nov 2024) cuts indexing cost ~1000× and is the cost-effective path, but it is folded into Microsoft Discovery/Azure Local, not a self-hostable OSS product we can pin.
- LightRAG (HKU, MIT, ~41k★) is the de-facto OSS replacement; incremental updates, dual-level retrieval, dramatically cheaper. It is still a *second indexing pipeline* over the same corpus we already chunk into `kb_chunks`.
- Independent benchmarks (GraphRAG-Bench, arXiv 2506.05690) show graph RAG wins on multi-hop/global questions and **loses** on simple factual lookup vs vanilla vector RAG. Legal matters produce mostly the latter; the former appears in cross-matter precedent research and counterparty/entity resolution.
- Graphiti (Zep) is the only temporal-KG option that models validity *windows* — relevant to "what did we believe about clause X on 2025-03-01", which legal genuinely needs. It needs Neo4j/FalkorDB/Kuzu. Kuzu was acquired by Apple (Feb 2026) and archived Oct 2025 — do not start on it. Neo4j Community is GPLv3 and single-instance; FalkorDB is SSPL.
- Legal-specific work exists (Smart-Slic arXiv 2502.20364; Domain-Partitioned Hybrid RAG arXiv 2602.23371) and both converge on **router → (vector | lexical | graph) → citation-grounded synthesis**, never graph-only.

**4.2 Graph-as-orchestration (LangGraph-style agent graphs).** deer-flow already *is* this. This sense needs no new dependency.

**4.3 Recommendation (the "graph engineering" line item)**
Do **not** add a graph database now. Do three cheap things instead:
1. Add a nullable `matter_id`/`document_id`/`chunk_id` **provenance edge table** (`entity_links(subject_type, subject_id, predicate, object_type, object_id, source, confidence, created_at)`) written by the extractors we already run (NER in `pacgate-redact`, `document_spans`). Cost: one migration + ~200 LOC. It gives us the identity/entity graph *without* a new store, and it is exportable to Graphiti later if retrieval quality justifies it.
2. Add a **router** in `search.rs`: classify query → `vector | lexical | graph(1-hop from entity_links) | workflow`. Graph path is a SQL recursive CTE over `entity_links` joined to `kb_chunks`, not a new engine.
3. Re-evaluate LightRAG/Graphiti as a *sidecar evaluation* in Q1 2027 against 30 golden multi-hop queries from real matters. Adopt only if it beats the CTE router on those, measured.

This gets the value (multi-hop, provenance, citations) without betting a legal product on an immature store and without a second source of truth for document truth.

---

## 5. What "harness engineering" means for this bundle

Anthropic/OpenAI both published on this in 2025. The consensus, stripped of vendor gloss:

| Harness layer | State of the art | Our bundle today | Gap |
|---|---|---|---|
| **Harness = the product**; model is swappable | OpenAI "Harness engineering", Anthropic managed-agents | We already treat model as config (`deer-flow-config.yaml` models list) | Keep; OpenAI post is an internal-velocity optimisation, **not** valid under legal HITL requirements |
| **Durable session/event log** outside the context window | Anthropic managed agents: append-only session; context re-derived | deer-flow checkpoints in LangGraph SQLite/Postgres; we additionally have `checkpoints.db` under `data/deer-flow` | OK for resumption; **not** exported for audit. Add session-export to `audit_log` or a `run_events` table |
| **Sandbox with egress control** | Anthropic: network-deny by default, tool-allowlist | We have `SANDBOX_BACKEND=local`, `PRIVATE_NETWORK_ALLOWED_ORIGINS`, sidecar sandbox | Document threat model; add egress allowlist test to `test-lane-connectivity.ps1` |
| **Approval gates for irreversible actions** | human-in-the-loop at write/egress boundary | sanitizer approval gate + matter-scope checks; **no gate on `pacgate_execute_workflow` or external search send** | Add policy: external egress (firecrawl, connector search) requires matter-level opt-in or admin approval for T3/T4 |
| **Deterministic invariants in code, not prompts** | OpenAI: linters/tests as the contract | `pacgate-redact`, sanitizer ledger, revision-checked memory, `test-sanitizer-e2e.ps1` | Strong already. Extend the same pattern to workflow outputs (schema-validate every generated docx against the template it claims to fill) |
| **Agent-legible observability** | OTel GenAI conventions; per-worktree logs the agent can read | `tracing` + `audit_log`; no OTel export | Add OTel GenAI spans behind a flag; export to a local collector; keep off by default (privacy) |
| **Eval-gated release** | Braintrust/LangSmith eval gates | `scripts/run-all-checks.ps1` ~70 gates, but **no quality eval** of agent answers | Add a small golden-set eval (20 matters, 60 questions, citation-grounded scoring) to release gates; block release on regression |
| **Context engineering** | progressive disclosure, AGENTS.md as map not encyclopedia | `pacgate-skills` are good; `deploy/client-bundle/deer-flow-skills` holds them | Add per-skill token budgets + a `skills/INDEX.md` map; audit `en-US.ts`/`zh-CN.ts` bloat |
| **Fail-closed defaults** | Anthropic + deer-flow 2.2 | deer-flow 2.2 adds fail-closed `allowed_users`, credential encryption, SSRF CGNAT block | **We inherit these by upgrading** — a concrete reason to do it |

**The single highest-leverage harness change for us is #3 (egress gate) and #6 (eval gate).** Neither requires an upstream upgrade.

---

## 6. Upgrade plan

### 6.0 Ground rules
- One component per release. No bundling.
- Every step has a rollback: previous image digest recorded, `compose.bundle.yaml` one-line revert, `install.ps1 -Rollback` path documented.
- Clean-clone verification (`scripts/verify-install.ps1` / RUNBOOK-clean-clone-proof) for every step that touches the installer or the compose graph.
- Nothing ships to a client machine until it has run on this AIPC for ≥3 days *and* on a clean VM.

### 6.1 qm 0.1.18 → 0.1.19 (do this first; smallest blast radius)
Evidence (`npm view @yc-software/qm`, 2026-11-24): `latest=0.1.18`, `next=0.1.19`, published 2026-11-11; 4 changed files only (`package.json`, `services.js` one line removing `PI_DETECT_MODEL` from Fly stack keys, sources map, `manifest.json` with new core/egress-proxy digests and sandbox-base `9c20219…`→`39954e4…`). No config migration. Fixes a managed-Postgres migration regression; adds intentional `PI_DETECT_MODEL` removal (detection now uses the session model).

Steps:
1. Do **not** run `qm upgrade`. Hand-edit `deploy/qm-pacgate/compose.qm.yaml`: `qm/core` digest → new, sandbox-base digest → `39954e4…`; set `"PI_DETECT_MODEL"` removed from `deploy/qm-pacgate/qm.config.jsonc` env (or leave, harmlessly ignored — remove anyway).
2. `docker compose -f deploy/qm-pacgate/compose.qm.yaml pull && up -d`.
3. Gates: `test-qm-currentness.ps1`, `test-qm-mutations.ps1`, `test-qm-restage.ps1`, `test-qm-upstream-drift.ps1` (expect `latest` still 0.1.18 → drift report unchanged; 0.1.19 is `next`). Then `smoke-full-stack.ps1`, `test-lane-connectivity.ps1`, one real `pacgate-qm ensure-matter` + `doc-upload` round trip against a scratch matter.
4. **Do not promote 0.1.19 to `latest` yourself.** Wait for the maintainer; re-run drift gate then.
Effort: 0.5 day. Risk: low. Rollback: pin previous digest, `up -d`.

### 6.2 OpenViking v0.4.16 → v0.5.6 (second; needs a maintenance window)
This is the risky one. 9 minor releases, no changelog file (release notes on GitHub are the only source), no online migration tool.

Blocking facts:
- **v0.5.3 removes `viking://session/...` URIs** (`INVALID_URI`) and `POST /api/v1/admin/migrate` returns 400 — sessions must be migrated *before* 0.5.3.
- **v0.5.0** flips `memory_policy.working_memory.enabled` default to false; **v0.5.5** turns on a per-account snapshot log SQLite and QueueFS Redis persistence of `serial_key`/`group_key` → **Rust extension and Python server must move together; mixed-version nodes are unsupported** (repeat warning in 0.5.5 and 0.5.6).
- **v0.5.6** adds PostgreSQL stores for account/task/watch with **manual DDL** (`001_watch_tasks_postgres.sql`, `CREATE INDEX CONCURRENTLY`).
- v0.5.5: gateway `disabled_tools` default becomes **empty** → all tools including write-capable ones enabled for any bearer key. For an air-gapped legal box this is the single most dangerous default in the release. Must be pinned explicitly.

Migration route (staged, in one window, with a tested rollback):
1. Snapshot `./openviking/workspace` (tar) and dump the pacgate Postgres. Verify restore.
2. `0.4.16 → 0.5.3` only. Run any session migration *before* start; confirm `ov-remember`/`ov-search`/`ov-read` and the deer-flow `openviking` MCP server (root key, `/mcp`) work; confirm `usage`/`cost` accounting unchanged.
3. Then `0.5.3 → 0.5.6` in the same window (do not run production on an intermediate 0.5.x for days).
4. Config changes: set `memory_policy.working_memory.enabled: false` explicitly if we want the old behaviour (decide deliberately, don't inherit); pin `disabled_tools` to a deny-list that excludes anything write-ish we don't use; keep `root_api_key` required (trusted mode now requires non-empty even on localhost); switch embeddings check — nomic-embed-text-768 is still supported via Ollama but verify the model name the 0.5.x config wants.
5. Watch for `/gateway/v1` prefix move (v0.5.1 moved admin API under `/gateway`) — anything calling `/api/v1/admin/*` breaks.
6. Re-run: `test-openviking-*` (none exist — **write one**: seed 3 memories, restart container, recall, assert; this is a current coverage gap), `test-legal-journey.ps1`, `test-sanitizer-e2e.ps1`.
7. Rollback: restore workspace tar + `0.4.16` digest. Data written by 0.5.x (new indices, manifest) is not readable by 0.4.16 — rollback means restore, not downgrade in place. Say so out loud in the runbook.

Effort: 2–4 days including rehearsal on a copied volume. Risk: medium-high, dominated by data-format change. **Do not skip the snapshot.**

### 6.3 deer-flow v2.0.0 → v2.2.0 (third, and the largest)
Detailed in `2026-11-24-deer-flow-2.2.0-upgrade-design.md`. Summary of what research adds:

- Upstream ships `scripts/config-upgrade.sh` (`make config-upgrade`) — migrates `config.yaml` `config_version` automatically and is idempotent-ish. **Use it; do not hand-edit.** It does not touch patches, IM credentials, or the DB.
- Memory: v2.1 makes `memory` pluggable (`manager_class`: `deermem` (default) | `openviking` | `mem0` | `honcho`). Our `PacgateMemoryStorage` (implements the removed `storage_class` interface) **must** be rewritten as a deermem-compatible manager or replaced by `manager_class: openviking` pointed at our OpenViking — which would make OpenViking the matter-memory store instead of `memory.json`. That is a real architectural fork:
  - **Option A (recommended): keep pacgate-api as matter-memory owner.** Rewrite the adapter to the new manager interface, keep `/api/matters/:id/memory` as the only writer. Preserves the file-backed, revisioned, audit-friendly semantics and the `If-Match` contract. OpenViking stays agent working memory.
  - **Option B: switch to `manager_class: openviking`.** Less code, one less service concept, but matter memory becomes OpenViking-native: loses the JSON revision ledger, complicates the QM bridge (which reads the same endpoint), couples legal record retention to an AGPL component's storage format. Not recommended this cycle; revisit after 6.2 proves out.
- `#5535`: thread delete now cascades to runs/events/feedback — update `test-legal-journey` expectations.
- `#6935`: `allowed_tools` in skills is *metadata only*, never filters. Our `deer-flow-skills/*/SKILL.md` that declare `allowed-tools` are inert — delete the field or expect no enforcement, and rely on MCP-side authz instead (which is where it should live anyway).
- `#7319`: `tool_output.elide_superseded_writes` defaults false — fine, keep the default.
- Frontend: zod 3→4.6.6 and the `?settings=` → Capability Center change break the assumption behind our `frontend-patches` overlay; the overlay must be re-cut against v2.2.0, not merged blind.
- Docker bind defaults to 127.0.0.1 (`#4618`, extended in 2.2.0) — irrelevant (we set our own hostnames) but confirm nginx `/pacgate/` path still resolves.
- New `DEER_FLOW_CREDENTIALS_KEY` (Fernet, multi-instance only) — we are single-node, so not required; do not add it speculatively.

Effort: 1.5–3 weeks including overlay re-cut and clean-clone proof. Risk: high, contained by the staging branch + `test-agent-mcp-e2e`, `test-legal-journey`, `test-model-picker-e2e`.

### 6.4 What is explicitly NOT in this programme
Neo4j/FalkorDB/Kuzu, GraphRAG/LightRAG index pipelines, Mem0, Zep, LangGraph Platform, OTel collector rollout, multi-instance QM, deer-flow plugins/agent-teams, scheduler. All are possible follow-ons; none are required to land these three upgrades safely.

---

## 7. Concrete deliverables (in order)

1. `docs/runbooks/openviking-0.4.16-to-0.5.6.md` — rehearsed migration + rollback. **Blocks 6.2.**
2. `deploy/qm-pacgate/compose.qm.yaml` + `qm.config.jsonc` 0.1.19 bump + `test-qm-*` green.
3. `pacgate-adapters/python/pacgate_deerflow_adapter/` rewritten to the 2.2 `MemoryManager` contract (or thin wrapper over upstream `deermem` pointed at pacgate-api), with a contract test that replays a real `memory.json`.
4. deer-flow base image bump + 3 obsolete patches deleted + `config-upgrade.sh` run + `frontend-patches` re-cut.
5. New gates: `test-openviking-roundtrip.ps1`, `test-agent-run-events.ps1` (audit export), and a 20-question golden-set eval wired into `run-all-checks.ps1` as advisory.
6. `entity_links` migration + NER → link writer + `entity_links`-aware retrieval booster in `pacgate-rag` (behind a flag `PACGATE_GRAPH_RETRIEVAL=0` default off).
7. ADR: "Matter memory stays file-backed behind pacgate-api; OpenViking is agent working memory" — so this decision is not re-litigated each quarter.
8. Update `deploy/AIPC-0.2.37-E2E-VERIFICATION.md` → `AIPC-0.3.0-E2E-VERIFICATION.md` after all three land.

---

## 8. Sequencing and calendar

```
Week 1   qm 0.1.19 (0.5d)  +  openviking runbook draft + dry-run on copied volume
Week 2   openviking 0.4.16→0.5.6 window (1 day) + 3 days soak on dev box
Week 2-4 deer-flow 2.2.0 branch; backend re-derive; contract tests green
Week 4   frontend overlay re-cut; zod 4 fixes; build
Week 5   clean-clone proof; golden-set eval; release 0.3.0; client runbook update
```

Rationale: qm first (cheapest, builds confidence in digest-pin workflow), OpenViking second (data-migration risk, needs a quiet dev box), deer-flow last (longest, benefits from OpenViking already being current).

---

## 9. Risks, unknowns, and honest negatives

1. **OpenViking data format is not backwards compatible** and we have no published migration tool; the plan's snapshot-restore rollback is the only safety net. If the workspace is corrupt, restore-from-backup is the answer, not a downgrade.
2. **deer-flow patch rebase is unbounded work.** If >40% of `deer-flow-*.py` patches conflict semantically (not just textually), stop and reassess with the maintainer of the patch set; the fallback is to drop the cosmetic patches and keep only security/behaviour patches (tool-policy drop, loop-detection drop, recursion-cap drop are already planned).
3. **The golden-set eval does not exist yet** — until it does, "no regression" means "existing gates green", which is weaker than it sounds. This is the weakest link in the plan.
4. **Graphify is not a product dependency.** It is a dev tool; nothing in the bundle may import or shell out to it. It is also unlicensed-checked — fine as a local analysis aid, not shippable.
5. **"Grain" could not be identified.** No credible project of that name exists in the agent-memory/graph space (closest: Graphiti, the grain-lang language, or a confusion of the two). If a specific vendor was meant, it needs a link; otherwise the plan assumes Graphiti/GraphRAG-class tools only.
6. **AGPL/SSPL exposure:** OpenViking is AGPL-3.0; Neo4j Community GPLv3; FalkorDB SSPL. We already ship OpenViking as a separate container talking HTTP, which is the safe boundary; do not statically link, do not offer it as a network service to third parties beyond the bundle's own components without counsel review.
7. **Obsidian/HTML `deploy/client-bundle/data/`** is inside the repo tree (gitignored). Nothing in this plan changes that, but the upgrade should not add data files to git.
8. Legal review of the egress-gate policy (§5, #3) is required — it changes what an associate can ask the agent to fetch.
9. Benchmark numbers quoted from vendors (Zep +18.5% LongMemEval, Mem0 p95 latency) are self-reported; treat as directional only.
10. If any of the three upgrades destabilises `test-legal-journey.ps1`, the correct action is to fix forward or revert that component only — never to weaken the gate to make it pass.

---

## 10. Open decisions for the owner

1. deer-flow memory: Option A (pacgate-api stays the matter-memory owner — recommended) or Option B (delegate to OpenViking)?
2. OpenViking cutover window: this maintenance week, or after the deer-flow branch is green?
3. Appetite for the `entity_links` graph layer now (small) or after 0.3.0 (safer)?
4. Do we want the OTel GenAI export behind a flag at all, given the privacy posture of matter data?
5. Should `test-legal-ai-reference-freshness` (currently CANNOT CHECK) be fixed before or after this programme?
