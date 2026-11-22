# 0.2.37 end-to-end verification

**Date:** 2026-10-05
**Tag:** `v0.2.37` (annotated, peels to `df1fa67d80ca`)
**Host:** this AIPC — AMD Radeon 8060S, **4 GB VRAM**
**Verdict: the release is good. One stage cannot be evaluated on this machine,
for a capacity reason unrelated to the release.**

---

## 1. What shipped, and why it was a bump

`b58c0e0` was committed but never built into an image, so the running stack was
0.2.36 while the source carried the fix. Bumped rather than rebuilt, per
`scripts/test-release-provenance.ps1`: the 0.1.28 defect was a `workflow_dispatch`
overwriting packages while the tag stayed put, so a new version is the only way to
make the tag mean the recipe again.

Content change is three images:

| Image | Change |
| --- | --- |
| `pacgate-mcp` | `pacgate_redline_compare` is dual-mode (docx / sanitized-text) with sanitize-on-demand |
| `deer-flow-pacgate`, `deer-flow-frontend-pacgate` | CJK granularity fix in the `pacgate-docx` crate |
| `pacgate-api` | version only |

## 2. Release integrity

| Check | Result |
| --- | --- |
| `preflight-release-tag.ps1 -Version 0.2.37` | 11/11 PASS, "safe to tag" |
| Workflow run `45014975595` (tag push) | completed / **success** |
| Six images public and anonymously pullable | 6/6 |
| `test-release-provenance.ps1 -Version 0.2.37` | **PASSED** — all six share revision `df1fa67d80ca`; tag is annotated and peels to that commit |

**One defect of mine, caught by the gate:** the tag was first created lightweight
(`git cat-file -t` → `commit`). Every prior release is annotated; the gate requires
`tag`. Deleted, recreated annotated, re-pushed, re-verified.

## 3. The stack, upgraded

All five release services recreated on 0.2.37 and healthy. `qm-pacgate-*` (0.1.4),
`pacgate-db`, `pacgate-nginx` and `openviking` were left untouched — they are not
part of this release.

| Gate | Result |
| --- | --- |
| `test-stack-version-coherence.ps1` | **14/14** — every service runs its pinned image |
| `test-mcp-tool-surface.ps1` | **6/6** — 29 tools, source == advertised |
| `smoke-full-stack.ps1` | **20 passed, 0 failed, 1 skip** (the skip is the lane documented as covered by `test-agent-mcp-e2e.ps1`) |
| `pacgate-docx` unit tests | **19/19** |
| `cargo clippy -p pacgate-docx -D warnings` | clean |

## 4. The redline blocker is actually closed

This is the assertion the release exists for, and it is proven against the **live
stack**, not the engine:

```
0. the MCP tool reaches its inputs through pacgate-api
  [PASS] pacgate_redline_compare returns a redline through MCP
  [PASS] the result names the mode it used
  [PASS] the TEXT-mode diff is granular, not a whole-sentence replacement
         reachable mode: text
RESULT: 11 passed
```

`reachable mode: text` is the proof: pacgate-api would only release redacted text,
and the tool now completes a real diff in that lane instead of returning 409.

Against the **0.2.36** image the same gate reports `8 passed, 2 failed` with
`409 conflict` and `format=None`. That before/after is the whole point — section 0
calls the MCP *tool*, which is the boundary the original gate missed.

## 5. Stage 8 cannot be evaluated here

`audit-post-deploy.ps1` reports `8 passed, 1 failed, 5 blocked`. The failure is stage
8, agent → MCP, and it is **not** a release defect:

```
llama-server startup failed ... cudaMalloc failed: out of memory
ggml_backend_buft_alloc_buffer_n_default: failed to allocate ROCm0 buffer of size 5020703744
```

Measured cause:

| Fact | Value |
| --- | --- |
| GPU | AMD Radeon 8060S (integrated) |
| VRAM | **4 GB** |
| Picker default (first roster entry) | `nemotron-3.5-bolt:e4b-q8_0`, **9.09 GB** |
| Smallest local chat tag installed | `ornith-1.5:9b`, **6.10 GB** |

No installed local chat model fits. Direct probes fail on the GPU path *and* the CPU
fallback (`unable to allocate CPU buffer`, 3.7 GB). Cloud tags work
(`glm-5.3-flash:cloud` answered), which is the documented, accepted egress model, but
the shipped `deer-flow-config.yaml` pins tags statically and does not read
`PACGATE_MODEL_*`, so `.env` cannot retarget it.

**Nothing in 0.2.37 touches model selection.** Verified by diff: the release changed
`redline.py`, `server.py`, `diff.rs`, the compose pins, the handbooks, one preflight
script and the redline gate. Model config is byte-identical to 0.2.36.

### 5.1 The five "blocked" stages all pass when run directly

The block cascade is an artefact of stage 8's position, not of broken services:

| Stage | Script | Result |
| --- | --- | --- |
| 9 | `test-workflow-library-served.ps1` | PASS — 222 workflows, 46 categories, library not built-ins |
| 10 | `test-kb-search-empty-signal.ps1` | **6/6** |
| 11 | `test-sanitizer-e2e.ps1` | **PASS** (minted download token, restore refused for attorney, admin restore, ledger + audit rows) |
| 12 | `test-format-coverage-e2e.ps1` | **48 passed, 0 failed** |
| 13 | `test-ner-enabled.ps1` | PASSED (weights copied and hash-verified in both base compose files) |

Stages 14 and 15 (generation, legal journey) genuinely need a loaded model and were
skipped with `-SkipGenerative`.

## 6. Three gate defects found and fixed while verifying

The release itself is small; the verification found more in the harness than in the
product. All three were the same shape: **a gate reaching a verdict it had no
evidence for.**

| Defect | Symptom | Fix |
| --- | --- | --- |
| `preflight-docker-egress.ps1` | probe image hardcoded to `deer-flow-pacgate:0.2.6`; `docker` printed "No such image", the loop fell through to `python:3.12-slim`, and the probe still printed `[ok]` — so it never tested our image | derive the tag from the bundle pin (`cc07f6b`) |
| `test-baked-patch-parity.ps1` | default `-Image` was `:0.2.8`; warned that two baked copies were STALE while 0.2.37 matches all three | derive the tag from the bundle pin (`1ef3782`) |
| `test-ollama-gpu-residency.ps1` | (a) the CANNOT CHECK branch fell through to "local inference is GPU-backed" — when no `inference compute` line existed, `$cpuOnly` was false and the success branch ran; (b) "no runner loaded (nothing can be on the CPU yet)" treated absence of evidence as evidence, which on a box where nothing can ever load is permanently green | cannot-check now precedes any success branch; SKIP instead of PASS; added a capacity check (enumeration ≠ fit) that filters `:cloud` tags — a cloud tag's manifest is ~300 **bytes**, so a size-only filter declared a 4 GB device adequate (`e3ec02b`) |

`test-agent-mcp-e2e.ps1` also now labels an out-of-memory failure as
`NOT EVALUATED - the model runtime never started` rather than implying a tool-plumbing
defect. It still exits non-zero; a green "cannot check" would repeat the false green
this repo keeps getting burned by.

Mutation checks run for each: the parity gate yields 2 warnings at `:0.2.8` and 0 at
the derived `0.2.37`; the residency classifier yields 1 failure for a `100% CPU` row
and 0 for `100% GPU`.

## 7. Still open

- **Stage 8 / stages 14-15** need a machine with enough VRAM, or a roster default that
  is a `:cloud` tag for this host. Not a code change until the firm decides whether the
  shipped default should vary by machine.
- **`/context`-style VRAM guidance** appears in the handbook as a checklist item
  ("`ollama ps` must say GPU, not 100% CPU") but nothing states a VRAM floor. A 4 GB
  box passes that checklist while being unable to run a single model.
- **qm stays on 0.1.4** — see `deploy/qm-pacgate/UPSTREAM-0.1.19-VERDICT.md`.
