# QM Core Ollama Adaptation Plan

## Overview

Pacgate plus DeerFlow is already the shortest path to a real local legal-execution stack. QM is currently only a smoke-proven collaboration shell because the pinned QM runtime accepts base models from Anthropic, OpenAI, and OpenRouter only. This plan bounds the work required to make QM core support a local Ollama-backed real `pi` run without regressing the current Pacgate bridge, Windows wrapper, or durable `8180/8182` local topology.

## Tasks

### Task 1: Add Ollama provider to QM runtime contract

**Files:**

- Modify: upstream QM core checkout `/app/src/model/pi-models.ts`
- Modify: upstream QM core checkout `/app/src/model/model-credential-store.ts`
- Modify: upstream QM core checkout `/app/src/model/model-catalog.ts`
- Modify: upstream QM core checkout `/app/src/config.ts`

**Step 1: Extend provider ids**
Add `ollama` to the runtime provider set in `pi-models.ts`, including:

- `MODEL_PROVIDERS`
- `ModelProvider`
- `ModelProviderAvailability`
- `modelServiceable()`
- `onlyProvider()`

Keep the change surgical: do not alter existing Anthropic/OpenAI/OpenRouter behavior.

**Step 2: Add an Ollama-backed model entry**
In `pi-models.ts`, add at least one selectable base model entry for the local Pacgate-compatible deployment, for example:

```ts
{ id: "deepseek-v4-flash:0731-cloud", name: "DeepSeek V4 Flash 0731", fastMode: false, webui: true, base: true }
```

Replace the current `builtinModel()` helper with one that can resolve either:

- existing `getBuiltinModel(provider, id)` paths for Anthropic/OpenAI/OpenRouter, or
- an Ollama/OpenAI-compatible local adapter for `ollama`

The new Ollama resolver must read:

- `OLLAMA_BASE_URL` (default `http://host.docker.internal:11434/v1` for Docker local runs)
- `OLLAMA_API_KEY` (optional; default `ollama` if unset)

**Step 3: Extend runtime credential handling**
In `model-credential-store.ts`, add `ollama` to the provider state model. The credential rule should differ from the cloud providers:

- environment fallback allowed
- admin override optional
- blank key tolerated if the runtime defaults it to `ollama`

In `config.ts`, update the real-turn validation so `HARNESS=pi` accepts `MODEL_PROVIDER=ollama` and does not reject the deployment solely because it lacks Anthropic/OpenAI/OpenRouter keys.

**Step 4: Verify**
Run from the QM core checkout:

```bash
npm test
```

Expected:

- runtime unit tests pass
- `HARNESS=pi MODEL_PROVIDER=ollama` no longer throws provider-validation errors
- existing cloud-provider tests still pass

**Step 5: Commit**

```bash
git add src/model/pi-models.ts src/model/model-credential-store.ts src/model/model-catalog.ts src/config.ts
git commit -m "feat: add ollama model provider to qm core runtime"
```

---

### Task 2: Extend the QM CLI/deployment contract for Ollama

**Files:**

- Modify: deployment package source for QM CLI `dist/src/config.js` equivalent in upstream source
- Modify: deployment package source for QM CLI `dist/src/secrets.js` equivalent in upstream source
- Modify: deployment package source for QM CLI `dist/src/commands/setup.js` equivalent in upstream source
- Modify: local deployment docs [deploy/qm-pacgate/.env.example](d:/users/joeyzh/github-pr/pacgate-ai-pr/deploy/qm-pacgate/.env.example)

**Step 1: Add provider contract entries**
Update the QM CLI source so it recognizes `ollama` alongside the existing providers.

The contract must:

- allow `MODEL_PROVIDER=ollama`
- map it to `OLLAMA_API_KEY` only if you choose to make the key explicit
- otherwise treat `OLLAMA_BASE_URL` as the only required external setting for local runs

**Step 2: Update setup and secret playbooks**
In the setup wizard source, add a playbook entry explaining:

- local Ollama path
- `OLLAMA_BASE_URL`
- optional `OLLAMA_API_KEY=ollama`

In `secrets.js`, add or relax secret requirements so that `PUBLIC_API_URL` stays required for `pi`, but cloud-provider keys are not required when `modelProvider` is `ollama`.

**Step 3: Reflect the local topology**
Keep the durable local split already used in this repo:

- Pacgate host gateway: `http://localhost:8080`
- QM core: `8180`
- QM web UI: `8182`
- QM `PUBLIC_API_URL`: `http://host.docker.internal:8180`

**Step 4: Verify**
Run from the deployment package checkout:

```bash
npm test
npm exec qm -- check
```

Expected:

- `MODEL_PROVIDER=ollama` is accepted
- `HARNESS=pi` no longer demands Anthropic/OpenAI/OpenRouter keys when Ollama is selected
- `PUBLIC_API_URL` remains required for real-turn runs

**Step 5: Commit**

```bash
git add src/config.ts src/secrets.ts src/commands/setup.ts
git commit -m "feat: add ollama deployment contract to qm"
```

---

### Task 3: Build a local Pacgate QM core image with Ollama support

**Files:**

- Create: `deploy/qm-core-pacgate/Dockerfile`
- Modify: [deploy/qm-pacgate/qm.config.jsonc](d:/users/joeyzh/github-pr/pacgate-ai-pr/deploy/qm-pacgate/qm.config.jsonc)
- Modify: [deploy/qm-pacgate/.env.example](d:/users/joeyzh/github-pr/pacgate-ai-pr/deploy/qm-pacgate/.env.example)
- Modify: [scripts/qm-local.ps1](d:/users/joeyzh/github-pr/pacgate-ai-pr/scripts/qm-local.ps1)

**Step 1: Introduce a custom core image path**
Build a local QM core image from the patched upstream QM source, not the stock `ghcr.io/yc-software/qm/core` image. The Dockerfile should:

- copy the patched QM source
- build the core runtime
- preserve the existing `pacgate-qm` sandbox layer flow

**Step 2: Update local deployment config**
In `qm.config.jsonc`:

- set `env.core.HARNESS` back to `pi`
- set `modelProvider` or equivalent local runtime marker to `ollama`
- keep `basePort: 8180`
- keep `publicUrl: http://localhost:8182`
- keep `sandbox.env.PACGATE_API_URL: http://host.docker.internal:8080`

In `.env.example`, add:

- `PUBLIC_API_URL=http://host.docker.internal:8180`
- `OLLAMA_BASE_URL=http://host.docker.internal:11434/v1`
- optional `OLLAMA_API_KEY=ollama`

**Step 3: Preserve the Windows wrapper**
Extend `scripts/qm-local.ps1` only as needed to support the custom local core image path while retaining the existing deterministic Windows `docker` lookup workaround.

**Step 4: Verify**
Run locally:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.
\scripts\qm-local.ps1 check
.
\scripts\qm-local.ps1 up
.
\scripts\qm-local.ps1 status
```

Expected:

- QM core binds to `8180`
- QM web UI binds to `8182`
- no cloud-provider-key errors
- no `/bin/sh` docker lookup failure on Windows

**Step 5: Commit**

```bash
git add deploy/qm-core-pacgate/Dockerfile deploy/qm-pacgate/qm.config.jsonc deploy/qm-pacgate/.env.example scripts/qm-local.ps1
git commit -m "feat: wire local ollama qm runtime into pacgate deployment"
```

---

### Task 4: Reconnect the Pacgate legal bridge under QM pi mode

**Files:**

- Verify: [deploy/qm-pacgate/sandbox/tools/pacgate-qm/pacgate_qm.py](d:/users/joeyzh/github-pr/pacgate-ai-pr/deploy/qm-pacgate/sandbox/tools/pacgate-qm/pacgate_qm.py)
- Verify: [deploy/qm-pacgate/sandbox/skills/pacgate-workflow/SKILL.md](d:/users/joeyzh/github-pr/pacgate-ai-pr/deploy/qm-pacgate/sandbox/skills/pacgate-workflow/SKILL.md)
- Verify: [scripts/qm-local.ps1](d:/users/joeyzh/github-pr/pacgate-ai-pr/scripts/qm-local.ps1)

**Step 1: Keep the bridge scope unchanged**
Do not redesign the Pacgate tool layer. The bridge already knows how to:

- authenticate to Pacgate
- resolve scope → matter
- load/save matter memory
- execute Pacgate workflows

The goal here is only to prove that the bridge works under a real `pi` run with the patched QM core.

**Step 2: Verify**
With Pacgate host gateway up on `8080`, run a live QM session and confirm:

- the web UI loads on `8182`
- a real turn executes under `pi`
- the `pacgate-qm` tool can resolve the bound matter and return workflow or memory data

Expected user-facing smoke:

- create or resolve a matter through the QM scope binding
- read Pacgate matter memory
- execute one Pacgate workflow through the QM collaboration surface

**Step 3: Commit**

```bash
git add .
git commit -m "test: prove qm pi mode against pacgate ollama deployment"
```
