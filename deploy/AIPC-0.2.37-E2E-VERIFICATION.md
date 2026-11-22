# 0.2.37 end-to-end verification

**Date:** 2026-10-05
**Tag:** `v0.2.37` (annotated, peels to `df1fa67d80ca`)
**Host:** this AIPC — AMD Radeon 8060S, **4 GB VRAM**
**Verdict: the release is good, and the whole 18-stage audit is green on this host.**
Stage 8 was unevaluable until the picker default was made loadable; it now passes 9/9.

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

## 5. Stage 8: resolved, and the full audit is now green

Stage 8 initially could not be evaluated at all. It now passes, and so does every
stage behind it: **18 passed, 0 failed, 0 cannot-check, 0 blocked**, including the
three generative stages (14, 15, 17) that had never run on this machine.

```
  [PASS] E1b the DEFAULT picker model 'glm-5.3-flash:cloud' is installed
  [PASS] E2 an agent run completes (the KeyError-class defect)
  [PASS] E2b the run produced an answer, not an LLM error fallback
  [PASS] E3 the run invoked at least one real MCP tool
         called: pacgate_pacgate_list_connectors
  [PASS] E4 a tool-call record came back (the call did not fail after issuance)
RESULT: 9 passed, 0 failed
```

### 5.1 The original failure, measured

```
llama-server startup failed ... cudaMalloc failed: out of memory
ggml_backend_buft_alloc_buffer_n_default: failed to allocate ROCm0 buffer of size 5020703744
```

| Fact | Value |
| --- | --- |
| GPU | AMD Radeon 8060S (integrated) |
| VRAM | **4 GB** |
| Picker default (first roster entry) | `nemotron-3.5-bolt:e4b-q8_0`, **9.09 GB** |
| Smallest local chat tag installed | `ornith-1.5:9b`, **6.10 GB** |

No installed local chat model fits. Direct probes fail on the GPU path *and* the CPU
fallback (`unable to allocate CPU buffer`, 3.7 GB). Cloud tags work — which is the
firm's deliberate, documented decision for deer-flow, not a residency bug.

### 5.2 The fix

The infrastructure already existed and was simply not used here: a gitignored
machine-local override (`compose.local-model-override.yaml` → `deer-flow-config.local.yaml`),
and a generator that writes it. What the generator could not do was anything other
than activate the commented-out 74B entry, which is the wrong answer on a small GPU.

`python scripts/regen-local-model-override.py --promote glm-5.3-flash-cloud`

- Moves an **already-active** roster entry to `models[0]`. Nothing is added, so the
  tracked config stays the single source of truth and the shipped client contract is
  untouched — the tracked config, `ollama-models.txt`, both compose lanes and every
  image are unchanged.
- Converges the five auxiliary lane pins (`model_name` ×3, `local_model`,
  `cloud_model`) onto the promoted entry. A lane left on a different tag forces an
  evict and cold reload every turn.
- `models[0]` **is** the picker default: `agent.py` takes
  `default_model_name = app_config.models[0].name`, and the frontend falls back to it.

**A defect of mine, caught by the container:** the first generated file relabelled
`description:` with an unquoted scalar containing `tag: glm-5.3-flash:cloud`. YAML read
the colon-space as a mapping and deer-flow crash-looped:

```
RuntimeError: Failed to load configuration during gateway startup: mapping values are not allowed here
```

The description is now quoted, and both write sites validate the whole document with
PyYAML before writing, so the generator cannot leave a broken mount behind again.

### 5.3 The capacity gate was also a false green

`test-aipc-capacity-fit.ps1` hardcoded `$AipcVramGB = 16` — the reference client card
(RX 7600 XT). That is correct for judging what **ships**, and wrong to read as "this
box can run it". On a 4 GB host it printed `FITS` for a 9.8 GB entry.

It now takes `-VramGB`. The default stays 16 so shipped-contract behaviour is
unchanged; passing the host value asks the different question:

| Invocation | Result |
| --- | --- |
| (default, 16 GB) | 0 warnings — unchanged |
| `-VramGB 4` | **9 capacity warnings** — every active entry OVER_CAP |

### 5.4 What this does and does not prove

- **Proven:** the agent → MCP lane works end to end on 0.2.37, a real tool call is
  issued and recorded, and the whole 18-stage audit passes.
- **Not proven:** that a *local* model works on this host. It cannot: no installed tag
  fits 4 GB. The promoted default is a `:cloud` tag, so this run exercises the cloud
  egress path the firm already accepted.
- **Deliberate:** the tracked config was **not** changed. A client machine with a
  16 GB card keeps the local default. Making the default vary by host is a commercial
  decision, and §7 flags it.

### 5.5 The five stages the audit had marked BLOCKED

They were blocked only because stage 8 failed ahead of them. All pass, both directly
and in the full run:

| Stage | Script | Result |
| --- | --- | --- |
| 9 | `test-workflow-library-served.ps1` | PASS — 222 workflows, 46 categories |
| 10 | `test-kb-search-empty-signal.ps1` | 6/6 |
| 11 | `test-sanitizer-e2e.ps1` | PASS (minted token, attorney restore refused, admin restore, ledger + audit) |
| 12 | `test-format-coverage-e2e.ps1` | 48 passed, 0 failed |
| 13 | `test-ner-enabled.ps1` | PASSED |

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

## 7. Recommendations, in value order

### 7.1 Decide whether the shipped default may vary by host — the one open decision

This is the only item that needs a commercial call, and it is now measurable rather
than a guess.

**The situation.** The tracked `deer-flow-config.yaml` hardcodes `models[0]` as
`nemotron-3.5-bolt:e4b-q8_0` (9.09 GB). It does not read `PACGATE_MODEL_*`, so `.env`
cannot retarget it, and `install.ps1` pre-pulls whatever `ollama-models.txt` lists on
every client. A 4 GB host therefore receives a stack whose default cannot load, and
nothing detects that until an agent run fails three stages later.

**Options:**

| Option | For | Against |
| --- | --- | --- |
| **A. Leave as is.** Document a VRAM floor in the handbook and refuse to install below it. | Smallest change. Keeps the local-only default, which is the better privacy posture and is genuinely faster when it fits. | Excludes any client on integrated graphics. The current checklist ("`ollama ps` must say GPU") passes on a 4 GB box that cannot run a single model, so the floor is silent. |
| **B. Make `models[0]` host-derived at install time.** `install.ps1` reads VRAM and, when no local tag fits, generates the override with `--promote <cloud entry>`. | The failure mode disappears. Cloud chat is already the accepted decision for deer-flow, and the override machinery exists. | Every client without a big dGPU sends its conversation to ollama.com by default, rather than by deliberate act. That inverts the "escalation stays local" comment in the tracked config, so it needs explicit sign-off. |
| **C. Keep the local default, but fail the install loudly.** Run `test-aipc-capacity-fit.ps1 -VramGB <host>` in `install.ps1` and stop if the default is OVER_CAP. | Honest. Forces the decision to a human instead of silently degrading. | An install that refuses to proceed is a support burden. |

**Recommendation: C now, B as an opt-in flag.** A client install should never silently
produce a stack that cannot answer, and it should never silently start sending prompts
off-machine either. C gives a clear stop with an actionable message; `-AllowCloudDefault`
(or equivalent) lets a client who has signed off on cloud chat proceed automatically.
That keeps the privacy default intact and makes the exception explicit, which is the
same posture the tracked config already takes in prose ("picking cloud is always a
deliberate act").

Whichever is chosen, add a VRAM line to the handbook checklist. Today it states only
that `ollama ps` must say GPU, which a machine with no loadable model passes trivially.

### 7.2 Watch for the stale-literal-in-a-gate pattern

Four of the defects this round were one class: **a version literal in a script outlives
the version.** `preflight-docker-egress.ps1` pinned `:0.2.6`, `test-baked-patch-parity.ps1`
defaulted to `:0.2.8`, and `test-aipc-capacity-fit.ps1` pinned `$AipcVramGB = 16`. Each
produced a confident verdict about something nobody was running.

Both tag cases now derive from `deploy/client-bundle/compose.bundle.yaml`. A cheap
guard would be a repo-wide check that no `scripts/*.ps1` contains a
`ghcr.io/jzkk720/*:<semver>` literal outside an explicit negative-test fixture
(`test-stack-version-coherence.ps1` legitimately needs two different tags). Worth
adding when someone next touches the gate harness, not worth a release on its own.

### 7.3 Two things to leave alone

- **qm stays on 0.1.4.** See `deploy/qm-pacgate/UPSTREAM-0.1.19-VERDICT.md`. `qm check`
  is a false green from 0.1.10 to 0.1.15, and 0.1.17+ is a topology rewrite.
- **Do not rebuild 0.2.36 or 0.2.37.** The 0.1.28 defect is why the rule exists; a
  new version is the only thing that makes a tag mean the recipe again.

