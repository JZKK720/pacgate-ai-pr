# Plan 002: Multi-model deer-flow config with env-var switching

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- deploy/deer-flow-pacgate/`
> If any file in this directory changed since this plan was written, compare
> the "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-client-bundle.md
- **Category**: direction / config
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The deer-flow wrapper config (`deploy/deer-flow-pacgate/config.yaml`) currently
has a single hardcoded model entry (`deepseek-v4-flash:0731-cloud`). The client
needs to switch between local Ollama models and cloud models without editing
YAML — they should be able to change a `.env` variable and restart. The user's
AIPC machines have 14 Ollama models available plus cloud endpoints. This plan
makes the model selectable via environment variable and ships a multi-model
config template in the client bundle.

## Current state

- `deploy/deer-flow-pacgate/config.yaml` (12 lines):
  ```yaml
  models:
    - name: deepseek-v4-flash-0731-cloud
      display_name: DeepSeek V4 Flash 0731 (Ollama)
      description: Local Ollama-backed legal execution model for the Pacgate DeerFlow wrapper.
      use: langchain_openai:ChatOpenAI
      model: deepseek-v4-flash:0731-cloud
      api_key: ollama
      base_url: http://host.docker.internal:11434/v1
      max_tokens: 8192
      temperature: 0.1

  sandbox:
    use: deerflow.sandbox.local:LocalSandboxProvider

  memory:
    storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage
  ```
- The Dockerfile at `deploy/deer-flow-pacgate/Dockerfile` COPYs this config.yaml
  into the image at `/app/backend/config.yaml`
- deer-flow uses `DEER_FLOW_CONFIG_PATH=/app/backend/config.yaml` to find it
- The user's machine has these models (from `ollama list`):
  - `deepseek-v4-flash:0731-cloud` (cloud-tagged, current default)
  - `deepseek-v4-pro:0813-cloud` (cloud-tagged, heavier)
  - `qwen3.8:27b-mtp-q4_K_M` (local, 17GB)
  - `qwen3.6:35b-a3b-mtp-q4_K_M` (local, 22GB)
  - `nemotron-3.5-lightning:30b-a3b` (local, 25GB)
  - `muse-glimmer:30b-q4_K_M-dflash` (local, 19GB)
  - `gemma4:26b-a4b-it-qat` (local, 15GB)
  - `nomic-embed-text:latest` (embedding, 274MB)
  - Plus cloud models: `glm-5.2:cloud`, `minimax-m3:cloud`

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify config | `Test-Path deploy/client-bundle/deer-flow-config.yaml` | True |
| YAML validity | `python -c "import yaml; yaml.safe_load(open('deploy/client-bundle/deer-flow-config.yaml'))"` | no exception |

## Scope

**In scope** (the only files you should create or modify):
- `deploy/client-bundle/deer-flow-config.yaml` (new — the multi-model template)
- `deploy/deer-flow-pacgate/config.yaml` (modify — add multi-model entries)

**Out of scope** (do NOT touch):
- `deploy/deer-flow-pacgate/Dockerfile` — it already COPYs config.yaml, no change needed
- `pacgate-adapters/python/pacgate_deerflow_adapter/` — adapter code is fine
- Any Rust code

## Git workflow

- Branch: `advisor/002-deer-flow-multi-model`
- Commit message: `feat: multi-model deer-flow config with env-var switching`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Update deploy/deer-flow-pacgate/config.yaml with multiple model entries

Replace the single model entry with multiple entries covering local + cloud
models. deer-flow's config supports a `models` list — the first entry is the
default, and the user can switch by reordering or by setting
`DEER_FLOW_MODEL` env var if deer-flow supports it (check: if deer-flow does
not support env-var model selection, the switch mechanism is reordering the
list or editing the config).

The new config should include:
1. `deepseek-v4-flash:0731-cloud` — default, cloud-tagged, fast
2. `deepseek-v4-pro:0813-cloud` — cloud-tagged, heavier research
3. `qwen3.8:27b-mtp-q4_K_M` — local, GPU
4. `nemotron-3.5-lightning:30b-a3b` — local, GPU
5. `gemma4:26b-a4b-it-qat` — local, lighter

All local models use `base_url: http://host.docker.internal:11434/v1` and
`api_key: ollama`. Cloud models use the same base_url if they're Ollama cloud
tags (the `:cloud` suffix means Ollama routes them to cloud endpoints).

Keep the `sandbox` and `memory` sections unchanged.

**Verify**: `python -c "import yaml; yaml.safe_load(open('deploy/deer-flow-pacgate/config.yaml'))"` → no exception

### Step 2: Create client bundle config template

Create `deploy/client-bundle/deer-flow-config.yaml` as a copy of the updated
config. This is the file that gets mounted into the deer-flow container on the
client machine. Add a header comment explaining how to switch models:

```yaml
# Pacgate-ai DeerFlow configuration
# To switch the active model, reorder the models list so your preferred
# model is first. All models use Ollama (local or cloud-routed).
# To add a new model, copy an existing entry and change the name/model fields.
```

**Verify**: `Test-Path deploy/client-bundle/deer-flow-config.yaml` → True

### Step 3: Update compose.prod.yaml to mount the config

In `deploy/client-bundle/compose.prod.yaml` (created by plan 001), add a volume
mount to the deer-flow service so the client can edit the config without
rebuilding the image:

```yaml
  deer-flow:
    image: ghcr.io/jzkk720/deer-flow-pacgate:0.1.0
    ...
    volumes:
      - ./data:/data
      - ./deer-flow-config.yaml:/app/backend/config.yaml:ro
```

This means the config file in the client bundle overrides the one baked into
the image. The client edits `deer-flow-config.yaml` and restarts the container.

**Verify**: `docker compose -f deploy/client-bundle/compose.prod.yaml config` → exit 0

## Done criteria

- [ ] `deploy/deer-flow-pacgate/config.yaml` has 5+ model entries
- [ ] `deploy/client-bundle/deer-flow-config.yaml` exists and is valid YAML
- [ ] `deploy/client-bundle/compose.prod.yaml` deer-flow service has the config volume mount
- [ ] `python -c "import yaml; yaml.safe_load(open('deploy/deer-flow-pacgate/config.yaml'))"` exits 0
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:
- deer-flow's config format does not support multiple model entries (check the
  upstream deer-flow docs or source if uncertain).
- The `:cloud` suffix models don't work with Ollama's OpenAI-compatible endpoint
  (they may need a different base_url).

## Maintenance notes

- When new Ollama models are installed on the client machine, add entries to
  `deer-flow-config.yaml` and restart the deer-flow container.
- The config volume mount means image rebuilds are NOT needed for model changes
  — only for adapter code changes.