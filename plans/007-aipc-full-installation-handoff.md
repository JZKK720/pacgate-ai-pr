# Plan 007 — AIPC Full Installation Handoff

> Status: **PHASE 2 COMPLETE — Phase 3 (AIPC installation) READY**
> Dates: 2026-08-27 → 2026-08-28
> Author: Audit + execution sessions (gstack-review × karpathy-guidelines × systematic-debugging)
> Scope: Fix audit findings → build/push corrected image → full installation on Pacgate Law AIPC(s): pacgate-api gateway middleware + deer-flow research workspace + qm collaboration runtime.

---

## 0. Consolidated stage log (sessions 15–16, 2026-08-27/28)

### Session 15 — Audit + Phase 1 (2026-08-27)

| Stage | Outcome | Evidence |
|---|---|---|
| Full gstack-review audit | All suites green; live e2e of prod compose on scratch port 8089 | smoke 23/23 · agent 5/5 · yaml 3/3 · TS 8/8 · integration 2/2 |
| Bug 1 found+fixed: LLM router hardcoded `localhost:11434` | Deploy blocker resolved | `default_local_with_base_url()` + `OLLAMA_BASE_URL` wired to router AND RAG |
| Bug 2 found+fixed: tenant `model_overrides` never consulted | Per-tenant routing live | `router_for_tenant()` + `run_with_router()` + `execute_with_router()` |
| Fix C: LLM error context | Errors self-diagnosing | model + URL in every LLM error |
| Docs corrections | `/api/health`→`/health` (11 occurrences, 6 files); `.env.example` connector placeholders; port-conflict note | committed |
| Phase 1 validation | All green | core 5/5 · llm 3/3 new tests; full regression pass |

### Session 16 — Phase 2 + model scan (2026-08-27/28)

| Stage | Outcome | Evidence |
|---|---|---|
| Bug 3 found+fixed: Ollama rejects object-typed tool content | Chat with tool calls works | `invalid message content type` reproduced directly; stringify fix |
| Bug 4 found+fixed: workflow step-2 hang on nemotron reasoning mode | Resolved by model choice + 600s timeout | >40 min hang evidence; gemma4 completes in 27s |
| Bug 5 found+fixed: StubDocStore in live path | Real FsDocumentStore wired | generate_docx now writes real files |
| Bug 6 found+fixed: generate_docx schema undocumented | Tool description lists all section types | LLM produces valid structures |
| Bug 7 found+fixed: document owner FK violation | Attributed to matter creator | `documents_owner_id_fkey` satisfied |
| Image `pacgate-api:0.1.2` | Built ×4, pushed to GHCR | digest `sha256:0d8dfa76...` |
| **Final acceptance e2e** | **Workflow execute 200 in 27s, all 3 steps, docx persisted** | full regression green |
| Ollama model scan (16 models inventoried, 5 benchmarked) | Tier split chosen | gemma4:12b 13s vs 73–115s for larger; both fit VRAM |
| Tier split applied to docs | Main=gemma4:12b · Mid=qwen3.8:27b · Low=gemma4:12b | handbook + Appendix A updated |
| Commits | 5 pushed to origin/main | b35b91a · b812791 · 1cb2549 · 7d3c10b · 836d75e |

### Release artifacts

| Artifact | Location | State |
|---|---|---|
| `pacgate-api:0.1.2` | `ghcr.io/jzkk720/pacgate-api:0.1.2` | pushed, pullable |
| `deer-flow-pacgate:0.1.0` | `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` | unchanged (wrapper) |
| Handbook | `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` v0.1.1 | final, references 0.1.2 |
| Tenant override SQL | Plan 007 Appendix A | final, tier-split values |

---

## Execution log (session 15 — 2026-08-27)

| Phase | Status | Evidence |
|---|---|---|
| Phase 1: Fix A (`default_local_with_base_url` + `OLLAMA_BASE_URL` wiring) | ✅ DONE | core tests 5/5 incl. base-url propagation |
| Phase 1: Fix B (tenant `model_overrides` honored via `router_for_tenant`, `run_with_router`, `execute_with_router`) | ✅ DONE | llm router tests 3/3; live e2e shows override model used |
| Phase 1: Fix C (LLM errors include model + URL) | ✅ DONE | error messages now self-diagnosing |
| Phase 1 regression | ✅ PASS | smoke 23/23 · agent 5/5 · yaml 3/3 · clippy back to baseline 2 warnings |
| Phase 2: image build `pacgate-api:0.1.2` | ✅ built ×4 | final build incl. doc-store wiring + FK fix |
| Phase 2: e2e re-run | ✅ **PASS** | workflow execute 200 in 27s, all 3 steps, docx persisted |
| Phase 2: GHCR push | ✅ DONE | `sha256:0d8dfa76...` pullable |
| Phase 2: commits | ✅ DONE | b35b91a (fix) + b812791 (release) + 1cb2549 (docs), pushed to origin/main |
| Phase 3: AIPC installation | ⬜ READY | handbook v0.1.1 + image 0.1.2 both final; execute Stage 1–6 per machine |

### Final e2e acceptance (2026-08-27, image 0.1.2 final)

| Check | Result |
|---|---|
| Stack health (`/health`) | ✅ 200 |
| Login / register / matter create | ✅ |
| Chat with tool-call round-trip | ✅ 200 |
| `generate_docx` via chat (explicit instruction) | ✅ docx written to disk + DB row with valid owner FK |
| **Workflow execute (Contract Review, 3 steps)** | ✅ **200 in 27s** — Read document → Identify risks → Generate review memo |
| Generated document persisted | ✅ `review_memo.docx` v1 |
| Regression: smoke 23/23 · agent 5/5 · core 5/5 · llm 3/3 | ✅ |

### Additional fixes applied during final verification (beyond original plan)

1. **StubDocStore removed** — `main.rs` now wires the real `FsDocumentStore`
   into `ToolDispatcher`, so `read_document` / `generate_docx` /
   `edit_document` operate on actual matter documents (previously stubs
   returned errors/empty lists).
2. **generate_docx schema documented** in the tool description — the LLM was
   producing `{type: content, content: [...]}` structures that failed to
   deserialize; the description now lists all valid section types with an
   example.
3. **Document owner FK fix** — `create_from_structure` attributes new
   documents to the matter's creator (`matters.created_by`) instead of a
   random `UserId::new()` that violated `documents_owner_id_fkey`.

### E2E re-run results (2026-08-27, image 0.1.2 with tool-content fix)

| Check | Result |
|---|---|
| Stack health (`/health`) | ✅ 200 |
| Login / register / matter create | ✅ |
| Chat round-trip WITH tool call (`list_documents` → result → answer) | ✅ **200** — the Ollama 400 is fixed |
| Workflow execute step 0 (Read document) | ✅ executed |
| Workflow execute step 1 (Identify risks) | ✅ executed |
| Workflow execute step 2 (Generate review memo → `generate_docx`) | ⚠️ **HANGS >40 min** — new finding, see below |

### Third finding: workflow step-2 hang (RESOLVED 2026-08-27)

With `nemotron-3.5-lightning:30b-a3b` as the Main tier model, workflow step 2
(`generate_docx`) started but never completed (>40 min, zero further log lines,
no DB writes, no error). Evidence:

- The API stayed responsive during the hang (parallel chat requests succeeded).
- No reqwest timeout fired despite the client's 120s timeout — the request was
  stuck reading a response body that never finishes.
- Baseline timing: a direct 500-word nemotron generation takes ~2 min; the
  model emits a large `reasoning` field alongside `content`, so a full memo
  structure JSON could take extremely long in reasoning mode.
- Suspected root cause: nemotron's reasoning-mode output for the docx
  structure JSON is enormous; the non-streaming `complete()` path waits for
  the entire body with no effective total-duration cap.

**Resolution (owner decision: option 1 + option 3, both applied):**
1. ✅ Main tier switched to non-reasoning `gemma4:12b-it-qat` — workflow now
   completes in 27s end-to-end.
2. ✅ Hard 600s total-request timeout added to `OpenAiCompatClient` — any
   future hang becomes a clean, diagnosable error.

Follow-on fixes discovered while verifying (all applied, see "Additional
fixes" below): StubDocStore replaced with the real FsDocumentStore,
generate_docx schema documented in the tool description, and the document
owner FK violation fixed.

### Second bug found during Phase 2 e2e (fixed)

**Ollama rejects object-typed tool-message content.** After Fix A/B routed the
request correctly to nemotron via tenant overrides, workflow/chat execution
still returned 400 from Ollama: `invalid message content type:
map[string]interface {}`. Root cause proven by direct request reproduction:
the agent loop sends tool results as raw `serde_json::Value` objects (works
with OpenAI, rejected by Ollama which requires string content). Fixed in
`pacgate-agent/src/lib.rs` by stringifying non-string tool-result values.
Rebuild of 0.1.2 with this fix is in progress at the time of this note.

### Serde casing note for Appendix A

`LlmTier` and `LlmProvider` serialize as **snake_case**: tiers are `main`/
`mid`/`low` (not `Main/Mid/Low`) and providers are `ollama` (not `Ollama`).
Appendix A below has been corrected accordingly.

---

## 1. Audit outcome (evidence-based, 2026-08-27)

### Verified green
| Check | Result |
|---|---|
| `cargo check` / clippy | clean (2 trivial warnings) |
| Smoke tests (`pacgate-api`) | 23/23 |
| Agent tests | 5/5 · YAML loader 3/3 · TS adapter 8/8 |
| Integration tests vs real Postgres | 2/2 (`full_api_flow`, 401 enforcement) |
| GHCR `pacgate-api:0.1.1` manifest | exists (amd64) |
| Live stack e2e (compose.prod on :8089) | containers up, `/health` 200, tenant seed, register ×2, login, workflows list (10), categories, registry (27), dd-configs (9), matter create |

### Findings fixed during audit (already committed to working tree)
1. `.env.example` — added commented placeholders for `PKULAW_API_KEY`, `VAQUILL_API_KEY`, `ANSVAR_API_KEY`, `OPENCORPORATES_API_KEY`.
2. Handbook/docs health-check route corrected: `/api/health` → `/health` (the unauthenticated route). Fixed in `AIPC-DEPLOYMENT-HANDBOOK.md` (×3), `README-client.md`, `DEPLOYMENT-GUIDE.md`, `SETUP-AND-OPERATIONS.md` (×3), `SETUP-AND-OPERATIONS-ZH.md` (×3).
3. Added `deploy/client-bundle/compose.e2e-override.yaml` (scratch e2e harness, documented as not-for-client).

### 🔴 BLOCKING BUG found by live e2e (must fix before any client install)

**Workflow/chat execution returns 500 "LLM HTTP request" in containerized deployment.**

Root cause (proven, not guessed):
- `pacgate-ai/crates/pacgate-core/src/lib.rs` → `ModelConfig::default_local()` hardcodes `base_url: "http://localhost:11434"` for all three tiers.
- `pacgate-ai/crates/pacgate-api/src/main.rs:72` builds `LlmRouter` from `default_local()` and **ignores the `OLLAMA_BASE_URL` env var** (which is only read at line ~158 for the RAG embedding service).
- Inside a container, `localhost:11434` is the container itself → connection refused (~40 ms failure matches logs).
- Additionally, `TenantConfig::model_overrides` exists in the schema/types but is **never consulted** by `LlmRouter` or the API handlers.
- Proven by network test from the API container's netns: `localhost:11434` → HTTP 000; `host.docker.internal:11434` → HTTP 200.
- Also proven: the default model names in `default_local()` (`nemotron3:33b`, `qwen3.6:27b`, `qwen3.5:9b`) do not exist on the target machine's Ollama; only `gemma4:12b-it-qat` fit VRAM during testing (30B-class models OOM'd under concurrent load).

Secondary issues (non-blocking, fix opportunistically):
- `AIPC-DEPLOYMENT-HANDBOOK.md` Stage 0 has a duplicated build/push command block.
- No note about host-port remap when 8081 is occupied.
- `LlmRouter` has no per-request timeout surfaced in error text ("LLM HTTP request" gives no URL/model context — poor DX when debugging).

---

## 2. Proposed solution set (options considered)

### Fix A (recommended): wire `OLLAMA_BASE_URL` into the router
In `main.rs`, after reading `OLLAMA_BASE_URL` (hoist it above the router construction), pass it into a new `ModelConfig::default_local_with_base_url(&str)` (or mutate `default_local()` to take `Option<&str>` defaulting to localhost). Minimal diff, no schema change, fixes every containerized deployment.

### Fix B (recommended, same PR): honor `TenantConfig.model_overrides`
When executing chat/workflows, look up the tenant row's `config_json.model_overrides`; if non-empty, build/replace router configs per request (or cache per tenant_id with TTL). This makes the already-shipped T1–T4-style per-tenant posture real and lets each firm pick models that actually exist on their hardware.

### Fix C (optional hardening): better LLM error context
Include base_url host + model_name + status in the `PacgateError::LlmError` message. One-line change, huge debugging payoff on-site.

### Rejected alternatives
- *Host-network mode for the API container* — works around the bug but breaks compose isolation and doesn't fix wrong-model-name defaults.
- *Only documenting "set PACGATE_OLLAMA_URL"* — there is no such env var today; docs-only fix would be dishonest.

### Model roster alignment (decision needed)
`ollama-models.txt` pulls cloud-tagged models (`deepseek-v4-flash/pro-cloud`) plus `nomic-embed-text`. `deer-flow-config.yaml` and `qm.config.jsonc` reference those cloud tags. But `default_local()` names local tags that aren't pulled anywhere. Proposal: after Fix B, set the seeded tenant's overrides to the models actually pre-pulled per AIPC (owner confirms which), and add `gemma4:12b-it-qat` (or chosen fallback) to `ollama-models.txt`.

---

## 3. Implementation phases (for the executing agent)

### Phase 0 — Preconditions (dev machine)
- [ ] Owner approval of this plan (esp. §2 model roster decision).
- [ ] Working tree committed: audit fixes from §1 already applied.

### Phase 1 — Code fix (pacgate-ai crate-scoped)
- [ ] `pacgate-core`: add `ModelConfig::default_local_with_base_url(base: &str)`; keep `default_local()` delegating to it with `"http://localhost:11434"`.
- [ ] `pacgate-api/main.rs`: read `OLLAMA_BASE_URL` once near config load; use it for both router and RAG embed service.
- [ ] `pacgate-api`: resolve tenant `model_overrides` for chat + workflow-execute paths (Fix B); fall back to env-config defaults when empty.
- [ ] `pacgate-llm`: enrich LLM error messages with model + host (Fix C).
- [ ] Tests: unit test that `default_local_with_base_url("http://host.docker.internal:11434")` produces that base_url on all tiers; smoke test asserting router honors override configs.
- [ ] Validate: `cargo check`, `cargo test -p pacgate-api --test smoke`, integration tests if Postgres available.

### Phase 2 — Release
- [ ] Bump image tag → `ghcr.io/jzkk720/pacgate-api:0.1.2`; update `compose.prod.yaml` + handbook references.
- [ ] Build + push; verify manifest pullable.
- [ ] Re-run the live e2e harness (`compose.e2e-override.yaml`, project `pacgate-e2e`, port 8089): full flow must now include a **successful workflow execute** (this was the failing step). Use a model confirmed present on the dev box.
- [ ] Clean handbook nits: dedupe Stage 0 block; add port-conflict note.

### Phase 3 — Client AIPC installation (per machine, identical steps)
Follow `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` v0.1.1 stages exactly, with these additions:
- [ ] Stage 2: fill `.env` including connector keys as applicable; confirm `PACGATE_TENANT_ID` matches the slug you will seed (`default-firm` unless changed — see Open Question Q2).
- [ ] After Stage 3: apply tenant model overrides matching the machine's actual pulled models (SQL via `docker exec pacgate-db psql`, template in Appendix A).
- [ ] Stage 4 qm bootstrap: run `setup-qm.ps1`, then `npm exec qm -- up`; verify bridge can list workflow categories through the API.
- [ ] Stage 5 deer-flow verification with citations + memory persistence.
- [ ] Stage 6 checklist fully ticked per machine; record results in a delivery log.

### Phase 4 — Acceptance criteria (definition of done)
- [ ] On a fresh AIPC: all four containers healthy; `/health` 200.
- [ ] Workflow execute returns 200 with real LLM content (no 500).
- [ ] deer-flow research round-trip with citations saved to matter memory.
- [ ] qm web UI sign-in + one workflow execution through the bridge.
- [ ] Both machines' checklists archived.

---

## 4. Open questions requiring owner approval before execution

| # | Question | Recommendation |
|---|---|---|
| Q1 | Approve Fixes A+B+C as one PR? | Yes — smallest coherent change set. |
| Q2 | Tenant slug: keep seeding `pacgate-law` then renaming to `default-firm` (current workaround), or change `PACGATE_TENANT_ID` default to `pacgate-law` everywhere? | Change default to `pacgate-law` in `.env.example` + handbook so slug matches brand from day one. |
| Q3 | Which models get pre-pulled on the client AIPCs? Cloud-tagged DeepSeek needs internet; confirm pilot policy. | Pull `deepseek-v4-flash:0731-cloud` + `nomic-embed-text` + one local fallback (`gemma4:12b-it-qat`). |
| Q4 | One AIPC first (pilot) or both simultaneously? | One first; freeze checklist; then replicate. |
| Q5 | Image tag `0.1.2` OK? | Yes. |

---

## 5. Agent handoff prompt — Phase 3: AIPC machine installation

Phases 1–2 are COMPLETE (see §0 stage log). This prompt is for the *next*
agent session that performs the actual installation on the client AIPC
machines. Copy everything inside the fence below into a fresh agent session
running ON the target AIPC (or with access to it).

```markdown
# TASK: Install Pacgate AI on this AIPC (Plan 007 Phase 3)

You are performing the on-machine installation of the Pacgate AI stack:
pacgate-api (Rust metadata gateway) + deer-flow (research workspace) + qm
(collaboration runtime) + Postgres + nginx, per
`deploy/AIPC-DEPLOYMENT-HANDBOOK.md`. Read that handbook FIRST, plus
`plans/007-aipc-full-installation-handoff.md` §0 (stage log) and Appendix A
(tenant model override SQL).

## Preconditions you must verify before starting
- [ ] Docker Desktop running (`docker info` succeeds)
- [ ] Ollama running (`curl http://localhost:11434/api/tags` returns models)
- [ ] Node.js 24+ installed (`node --version` ≥ v24)
- [ ] GitHub access to `JZKK720/pacgate-ai-pr` (private repo; `gh auth login`
      or PAT)
- [ ] Host port 8081 free (if occupied, remap nginx in compose.prod.yaml and
      use the new port in ALL verification URLs)

## Execution order (handbook stages)
1. **Stage 1** — clone the repo to `C:\pacgate-ai-pr` (or verify existing
   clone is on origin/main ≥ commit 836d75e).
2. **Stage 2** — `cd deploy\client-bundle`; copy `.env.example` to `.env`;
   generate strong `PACGATE_DB_PASSWORD` and `PACGATE_JWT_SECRET` (commands
   in handbook); set `PACGATE_TENANT_ID=pacgate-law`; run `.\install.ps1`.
   Verify: `docker compose -f compose.prod.yaml ps` shows 4 services;
   `curl http://localhost:8081/health` returns `ok`.
3. **Stage 3** — seed tenant + register users. NOTE: seed the tenant with
   slug matching `PACGATE_TENANT_ID` from `.env` (e.g. `pacgate-law`):
   `docker exec pacgate-db psql -U pacgate -c "INSERT INTO tenants (name,
   slug) VALUES ('Pacgate Law', 'pacgate-law');"` then register
   `admin@pacgate-law.com` and `qm-bridge@pacgate.local` via
   `POST /api/auth/register`.
4. **Model overrides (CRITICAL — do not skip)** — run `ollama list` on this
   machine; confirm `gemma4:12b-it-qat` and `qwen3.8:27b-mtp-q4_K_M` are
   present (pull via `ollama pull` if missing, plus `nomic-embed-text`).
   Then apply the Appendix A SQL template via
   `docker exec pacgate-db psql -U pacgate -f /tmp/overrides.sql`
   (docker cp the file in) with:
   MAIN=gemma4:12b-it-qat, MID=qwen3.8:27b-mtp-q4_K_M, LOW=gemma4:12b-it-qat,
   TENANT_SLUG=<your PACGATE_TENANT_ID>. Casing is snake_case
   (main/mid/low, ollama) — capitalized values silently fall back to
   defaults.
4b. **OpenViking memory service (Stage 3.5 in the handbook)** — the compose
   stack now includes `openviking` (5th container). The installer renders
   `OPENVIKING_CONF_CONTENT` into `.env` automatically. Verify:
   `curl http://localhost:1933/health` returns healthy JSON. Also set the
   qm-side secrets in `deploy/qm-pacgate/.env` (setup-qm.ps1 prompts, or add
   manually): `OPENVIKING_API_KEY` (same value as client-bundle .env),
   `OPENVIKING_ACCOUNT=<PACGATE_TENANT_ID>`, `OPENVIKING_USER=<admin user id>`.
5. **Stage 4** — qm bootstrap: `.\setup-qm.ps1` (prompts for admin email +
   bridge credentials), then `cd ..\qm-pacgate && npm exec qm -- up`.
   Verify: http://localhost:8182 loads; admin can sign in; qm lists Pacgate
   workflow categories through the bridge.
6. **Stage 5** — deer-flow verification: http://localhost:8081/research/;
   run a research query; verify citations + matter memory persistence.
7. **Stage 6** — complete the full smoke checklist in the handbook and write
   results to `plans/007-delivery-log.md` (create it; one section per
   machine, dated).

## Acceptance criteria (all must pass before declaring done)
- [ ] All five containers healthy; `/health` 200; OpenViking `/health` healthy
- [ ] Workflow execute returns 200 with real LLM content:
      login → create matter → POST /api/workflows/
      00000000-0000-0000-0000-000000000101/execute with
      {"matter_id":"<id>","input":"Review this sample contract clause for
      liability limitations."} — expect 200 in under 2 minutes with 3 steps
- [ ] Generated document appears in `documents` table
- [ ] deer-flow research round-trip with citations saved to matter memory
- [ ] qm web UI sign-in + one workflow execution through the bridge
- [ ] OpenViking memory lane: `pacgate-qm ov-remember` a fact, wait ~2 min,
      `pacgate-qm ov-search` recalls it in a new session

## Ground rules
- Never commit secrets; `.env` files stay local.
- If any step fails twice, STOP and report evidence (container logs, HTTP
  status, exact command) — do not improvise.
- Do not modify Rust code or rebuild images on the AIPC; the runtime comes
  from `ghcr.io/jzkk720/pacgate-api:0.1.2`.
- If a model is missing from `ollama list`, pull it; never substitute a
  reasoning-mode model (nemotron etc.) for Main tier.

## Report back
Delivery log path, checklist status per machine, any deviations with
justification, and the exact image digests running (`docker inspect
pacgate-api --format {{.Image}}`).
```

### Historical prompt (Phases 1–2, kept for reference)

<details>
<summary>Original Phase 1–2 execution prompt (completed)</summary>

```markdown
# TASK: Implement Plan 007 — Pacgate AI AIPC full installation

You are executing `plans/007-aipc-full-installation-handoff.md`. Read it FIRST,
plus `CONTINUE-FROM-OTHER-MACHINE.md` and `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`.
Work surgically (karpathy guidelines): smallest change that solves the problem,
every changed line traceable to the plan, validate each step before moving on.

## Ground rules
- Rust changes stay scoped to the owning crates; validate the touched crate
  first (`cargo test -p <crate>`), workspace-wide checks only at phase end.
- Do not touch `docs/` proposal pages, `scope-assets/`, or business materials.
- Never commit secrets. `.env` files are gitignored; use placeholders only.
- Windows: set `$env:NO_PROXY = "localhost,127.0.0.1,::1"` before anything
  talking to Ollama locally.
- If a step fails twice, stop and report evidence — do not improvise scope.

## Execution order
1. **Phase 1 (code)** — implement Fixes A/B/C from plan §2:
   - `ModelConfig::default_local_with_base_url()` in pacgate-core;
     `main.rs` reads `OLLAMA_BASE_URL` once and feeds BOTH the LlmRouter and
     the RAG EmbeddingService.
   - Honor `tenants.config_json.model_overrides` in chat + workflow execute.
   - Enrich LLM errors with model name + host.
   - Add the two tests named in plan §Phase-1. Run: cargo check, smoke tests,
     agent tests, yaml_loader, TS adapter npm test.
2. **Phase 2 (release)** — bump to pacgate-api:0.1.2, update compose.prod.yaml
   + handbook tag references, docker build + push to ghcr.io/jzkk720, then run
   the live e2e harness (project `pacgate-e2e`, override file
   `deploy/client-bundle/compose.e2e-override.yaml`, port 8089):
   seed tenant → register admin + qm-bridge → login → create matter →
   POST /api/workflows/{id}/execute MUST return 200 with content.
   Tear down with `down -v` afterwards.
3. **Phase 3 (install)** — follow the AIPC handbook stage-by-stage on the
   target machine(s) the owner designates, applying tenant model overrides
   (Appendix A of the plan) matched to that machine's `ollama list`.
   Complete the Stage 6 checklist and save results to
   `plans/007-delivery-log.md`.
4. **Report back** — commit log, test outputs, checklist status, any
   deviations from plan with justification.

## Definition of done
Plan §Phase-4 acceptance criteria all checked, delivery log written,
working tree committed with conventional-commit messages
(feat:/fix:/docs:/chore:), nothing pushed without owner confirmation.
```

</details>

---

## Appendix A — Tenant model override SQL template

**Recommended pilot values (benchmarked 2026-08-28):**
`<MAIN_MODEL>` = `gemma4:12b-it-qat` · `<MID_MODEL>` = `qwen3.8:27b-mtp-q4_K_M` · `<LOW_MODEL>` = `gemma4:12b-it-qat`

Rationale: gemma4:12b is 5–9× faster per tool-round (13s vs 73–115s) with
schema-valid tool calls — right for interactive chat/workflows (Main) and
fast labels (Low). qwen3.8:27b is stronger for batch tabular review (Mid)
where latency tolerance is higher. Both fit VRAM on the target AIPC class.

```sql
UPDATE tenants
SET config_json = jsonb_set(
  '{}'::jsonb,
  '{model_overrides}',
  '[
    {"tier":"main","provider":{"ollama":{"base_url":"http://host.docker.internal:11434"}},
     "model_name":"<MAIN_MODEL>","max_tokens":8192,"temperature":0.1},
    {"tier":"mid", "provider":{"ollama":{"base_url":"http://host.docker.internal:11434"}},
     "model_name":"<MID_MODEL>", "max_tokens":8192,"temperature":0.1},
    {"tier":"low", "provider":{"ollama":{"base_url":"http://host.docker.internal:11434"}},
     "model_name":"<LOW_MODEL>", "max_tokens":4096,"temperature":0.2}
  ]'::jsonb,
  true)
WHERE slug = '<TENANT_SLUG>';
```

Replace `<*_MODEL>` with tags confirmed via `ollama list` on the target machine.

> **Casing matters:** serde uses `snake_case` variants — tier values must be
> `main`/`mid`/`low` and the provider key must be `ollama`. Capitalized forms
> fail deserialization and silently fall back to defaults.
