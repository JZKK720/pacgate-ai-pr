# Plan 005: Package workflow YAMLs for agent workspaces

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- pacgate-ai/workflows/ deploy/qm-pacgate/sandbox/`
> If these directories changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-client-bundle.md
- **Category**: architecture / delivery
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The 220 YAML workflow templates in `pacgate-ai/workflows/*.yaml` are loaded
by the Rust API and discoverable via the qm sandbox bridge tool
(`pacgate-qm workflows --search`). However, the workflow YAML files themselves
are not mounted into any container — they only exist in the Rust binary's
memory after `load_from_yaml_dir()` at startup. This means:

1. The qm agent can discover workflows (via API) but cannot read the workflow
   step definitions locally — it must call `pacgate-qm workflow <id>` to see
   steps, which works but adds latency.
2. The deer-flow runtime has no access to the workflow templates at all —
   it would need to call pacgate-api to discover them.
3. If the Cubecloud engineer wants to preview or customize workflows on the
   client machine, the YAML files aren't there.

This plan copies the workflow YAMLs and persona definitions into the client
bundle as reference material, and mounts them into the qm sandbox as a
read-only skills directory so the agent can browse workflow definitions
locally.

## Current state

- `pacgate-ai/workflows/*.yaml` — 15 files, 220 templates. Loaded by
  `pacgate_workflow::load_from_yaml_dir()` at API startup.
- `deploy/qm-pacgate/sandbox/skills/pacgate-workflow/SKILL.md` — tells the
  agent to use `pacgate-qm` CLI commands to discover/execute workflows.
- `deploy/qm-pacgate/qm.config.jsonc` has `"skills": []` — no extra skill
  directories mounted.
- The qm config `skills` field accepts directories of SKILL.md files that get
  mounted into the agent. The workflow YAMLs are NOT SKILL.md files, so they
  can't go in `skills` directly. But they CAN be placed in a directory the
  sandbox can read.
- The compose.prod.yaml (from plan 001) does not mount workflow files into
  deer-flow or qm containers.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify copy | `Test-Path deploy/client-bundle/workflows` | True |
| File count | `(Get-ChildItem deploy/client-bundle/workflows/*.yaml).Count` | 15 |
| qm check | `cd deploy/qm-pacgate; npm exec qm -- check` | `check passed` |

## Scope

**In scope** (the only files you should create or modify):
- `deploy/client-bundle/workflows/` (new directory — copy of pacgate-ai/workflows/)
- `deploy/client-bundle/personas/` (new directory — copy of persona definitions)
- `deploy/client-bundle/compose.prod.yaml` (modify — add volume mounts)
- `deploy/qm-pacgate/qm.config.jsonc` (modify — add skills directory if applicable)

**Out of scope** (do NOT touch):
- `pacgate-ai/workflows/*.yaml` — source files, don't modify
- `pacgate-ai/crates/pacgate-persona/` — Rust persona code, don't modify
- `deploy/qm-pacgate/sandbox/skills/pacgate-workflow/SKILL.md` — already correct
- `deploy/qm-pacgate/sandbox/tools/pacgate-qm/` — already working

## Git workflow

- Branch: `advisor/005-workflow-packaging`
- Commit message: `feat: package workflow YAMLs + personas into client bundle`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Copy workflow YAMLs into client bundle

Copy all 15 YAML files from `pacgate-ai/workflows/` to
`deploy/client-bundle/workflows/`. These are reference files — the client
or engineer can browse them to understand what workflows are available.
They are NOT loaded by any container directly (pacgate-api loads them
from its own bundled copies at startup).

**Verify**: `(Get-ChildItem deploy/client-bundle/workflows/*.yaml).Count` → 15

### Step 2: Extract persona definitions into client bundle

The persona definitions live in the Rust crate `pacgate-persona`. Extract
the key persona information (name, description, practice area, SOUL identity)
into a readable reference file at `deploy/client-bundle/personas/README.md`.

This is a human-readable reference, not machine-loaded. Include:
- The 20 practice-area personas (name, practice area, description)
- The 10 SOUL personas (Justin, Sylvie, A1-A8 — name, role, identity modes)
- How to assign a persona to a user (via pacgate-api auth + soul_id)

Read the persona definitions from:
- `pacgate-ai/crates/pacgate-persona/src/lib.rs` (practice-area personas)
- `pacgate-ai/crates/pacgate-persona/src/soul.rs` (SOUL personas)

**Verify**: `Test-Path deploy/client-bundle/personas/README.md` → True

### Step 3: Add a workflow reference skill to qm sandbox

Create `deploy/qm-pacgate/sandbox/skills/pacgate-workflow-reference/SKILL.md`
that tells the agent where to find workflow definitions locally:

```markdown
---
name: pacgate-workflow-reference
description: Reference directory of Pacgate workflow YAML templates. Browse these to understand available legal workflows, their steps, and tools before executing them via the pacgate-qm CLI.
---

The workflow YAML templates are at `/app/workflows/` inside the sandbox.
Browse them with `ls /app/workflows/` or `cat /app/workflows/<filename>.yaml`.

Each YAML file contains multiple workflow definitions with steps, tools,
and descriptions. Use these to understand what a workflow does before
executing it with `pacgate-qm execute-workflow`.
```

Then in `deploy/qm-pacgate/qm.config.jsonc`, add the workflows directory to
the sandbox config so it gets mounted. Check if qm supports mounting extra
directories into the sandbox — if the `skills` field mounts SKILL.md
directories, the workflow YAMLs need a different mount mechanism.

If qm does NOT support mounting arbitrary directories into the sandbox, then
SKIP this step and leave the workflow discovery via API as the only path.
Document this limitation in the plan's maintenance notes.

**Verify**: `cd deploy/qm-pacgate; npm exec qm -- check` → `check passed`

### Step 4: Add workflow volume mount to compose.prod.yaml

In `deploy/client-bundle/compose.prod.yaml`, add a read-only volume mount
to the deer-flow service so the workflows are available as reference material:

```yaml
  deer-flow:
    ...
    volumes:
      - ./data:/data
      - ./deer-flow-config.yaml:/app/backend/config.yaml:ro
      - ./workflows:/app/workflows:ro
```

This gives deer-flow read-only access to the workflow YAMLs. The deer-flow
agent can browse them to understand what legal workflows are available
through pacgate-api, even though it executes them via API calls.

**Verify**: `docker compose -f deploy/client-bundle/compose.prod.yaml config` → exit 0

## Done criteria

- [ ] `deploy/client-bundle/workflows/` exists with 15 YAML files
- [ ] `deploy/client-bundle/personas/README.md` exists with persona reference
- [ ] `deploy/qm-pacgate/sandbox/skills/pacgate-workflow-reference/SKILL.md` exists (if qm supports it)
- [ ] `cd deploy/qm-pacgate; npm exec qm -- check` → `check passed`
- [ ] `deploy/client-bundle/compose.prod.yaml` deer-flow service has workflows volume mount
- [ ] `docker compose -f deploy/client-bundle/compose.prod.yaml config` → exit 0
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:
- qm's sandbox does not support mounting extra directories beyond `skills/`.
  In that case, skip step 3 and document the limitation.
- The persona definitions in the Rust source are not easily extractable (e.g.,
  they're generated programmatically, not static constants). In that case,
  create a shorter reference file listing just the persona names and practice
  areas from the API response.

## Maintenance notes

- When new workflow YAMLs are added to `pacgate-ai/workflows/`, re-copy them
  to `deploy/client-bundle/workflows/` and rebuild the client bundle.
- The workflow YAMLs in the client bundle are reference copies — the
  authoritative source is `pacgate-ai/workflows/` which gets compiled into
  the pacgate-api Docker image.
- If qm later supports mounting arbitrary directories, revisit step 3 to
  give the agent direct filesystem access to workflow definitions.