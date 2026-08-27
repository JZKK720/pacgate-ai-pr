# Plan 007 — AIPC Full Installation Handoff

> Status: **IN EXECUTION — Q1–Q5 approved 2026-08-27; Phase 1 complete, Phase 2 in progress**
> Date: 2026-08-27 (updated same day during execution)
> Author: Audit session (gstack-review × karpathy-guidelines)
> Scope: Fix audit findings → build/push corrected image → full installation on Pacgate Law AIPC(s): pacgate-api gateway middleware + deer-flow research workspace + qm collaboration runtime.

## Execution log (session 15 — 2026-08-27)

| Phase | Status | Evidence |
|---|---|---|
| Phase 1: Fix A (`default_local_with_base_url` + `OLLAMA_BASE_URL` wiring) | ✅ DONE | core tests 5/5 incl. base-url propagation |
| Phase 1: Fix B (tenant `model_overrides` honored via `router_for_tenant`, `run_with_router`, `execute_with_router`) | ✅ DONE | llm router tests 3/3; live e2e shows override model used |
| Phase 1: Fix C (LLM errors include model + URL) | ✅ DONE | error messages now self-diagnosing |
| Phase 1 regression | ✅ PASS | smoke 23/23 · agent 5/5 · yaml 3/3 · clippy back to baseline 2 warnings |
| Phase 2: image build `pacgate-api:0.1.2` | ✅ built ×2 | rebuilt after tool-content fix |
| Phase 2: e2e re-run | ✅ DONE (partial pass) | see e2e results below |
| Phase 3: AIPC installation | ⬜ pending | blocked on push + step-2 hang decision |

### E2E re-run results (2026-08-27, image 0.1.2 with tool-content fix)

| Check | Result |
|---|---|
| Stack health (`/health`) | ✅ 200 |
| Login / register / matter create | ✅ |
| Chat round-trip WITH tool call (`list_documents` → result → answer) | ✅ **200** — the Ollama 400 is fixed |
| Workflow execute step 0 (Read document) | ✅ executed |
| Workflow execute step 1 (Identify risks) | ✅ executed |
| Workflow execute step 2 (Generate review memo → `generate_docx`) | ⚠️ **HANGS >40 min** — new finding, see below |

### Third finding: workflow step-2 hang (OPEN — needs owner decision)

With `nemotron-3.5-lightning:30b-a3b` as the Main tier model, workflow step 2
(`generate_docx`) starts but never completes (>40 min, zero further log lines,
no DB writes, no error). Evidence:

- The API stays responsive during the hang (parallel chat requests succeed).
- No reqwest timeout fires despite the client's 120s timeout — the request is
  stuck reading a response body that never finishes.
- Baseline timing: a direct 500-word nemotron generation takes ~2 min; the
  model emits a large `reasoning` field alongside `content`, so a full memo
  structure JSON could take extremely long in reasoning mode.
- Suspected root cause: nemotron's reasoning-mode output for the docx
  structure JSON is enormous; the non-streaming `complete()` path waits for
  the entire body with no effective total-duration cap.

Recommended fixes (owner decision 2026-08-27: **option 1 + option 3**):
1. ✅ APPLIED — Main tier switched to non-reasoning `gemma4:12b-it-qat`
   (verified end-to-end); handbook recommendation updated.
2. ✅ APPLIED — hard total-request timeout (600s) added to
   `OpenAiCompatClient`, converting any future hang into a clean error.

This does NOT block Fix A/B/C correctness: chat + tool calls work, steps 0–1
execute. It blocks the "workflow execute returns 200" acceptance criterion
until resolved or until a non-reasoning Main model is chosen.

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

## 5. Agent handoff prompt

Copy everything inside the fence below into a fresh agent session in this repo root.

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

---

## Appendix A — Tenant model override SQL template

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
