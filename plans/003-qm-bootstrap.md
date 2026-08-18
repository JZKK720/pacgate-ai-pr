# Plan 003: qm first-run bootstrap script + config

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- deploy/qm-pacgate/`
> If any file in this directory changed since this plan was written, compare
> the "Current state" excerpts against the live code before proceeding.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-client-bundle.md
- **Category**: direction / config
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The qm deployment directory (`deploy/qm-pacgate/`) passes `qm check` and
`qm sandbox build`, but is stuck in `HARNESS=mock` mode — every message gets
canned text, no real model runs. To make qm functional for the client, we need:
1. A bootstrap script that generates the 4 signing secrets and creates `.env`
2. Config changes to switch from `mock` to a real model harness
3. A Pacgate bridge service account (email/password) for the sandbox tool
4. Clear documentation of the `qm up` first-run sequence

This is done by the Cubecloud engineer during the 3-day on-site installation,
not by the client.

## Current state

- `deploy/qm-pacgate/qm.config.jsonc` key fields:
  ```jsonc
  {
    "orgId": "pacgate",
    "publicUrl": "http://localhost:8182",
    "basePort": 8180,
    "target": "docker",
    "services": ["core", "web-ui"],
    "env": { "core": { "HARNESS": "mock", "SANDBOX_BACKEND": "local" } },
    "sandbox": {
      "image": "localhost:5000/pacgate-sandboxes@sha256:...",
      "env": { "PACGATE_API_URL": "http://host.docker.internal:8080" },
      "secretEnv": ["PACGATE_API_EMAIL", "PACGATE_API_PASSWORD"]
    }
  }
  ```
- `deploy/qm-pacgate/.env.example` lists 7 required secrets, all blank:
  `ANTHROPIC_API_KEY`, `CAPABILITY_SECRET`, `CONNECTOR_SECRET_KEY`,
  `CORE_SIGNING_SECRET`, `PORTAL_IDENTITY_SECRET`, `PACGATE_API_EMAIL`,
  `PACGATE_API_PASSWORD` (plus `SKILL_SIGNING_SECRET`)
- `deploy/qm-pacgate/.gitignore` exists and ignores `.env`
- `qm check` output shows: `check passed — config, sandbox layer, and plugins are valid`
- `qm sandbox build` output shows: `built local image pacgate-sandbox:local`
- The `deployment.md` documents the full qm setup flow (steps 1-5) but is
  written for a CLI operator, not scripted

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify script | `Test-Path deploy/client-bundle/setup-qm.ps1` | True |
| qm check | `cd deploy/qm-pacgate; npm exec qm -- check` | `check passed` |
| qm version | `cd deploy/qm-pacgate; npm exec qm -- version` | prints version |

## Scope

**In scope** (the only files you should create or modify):
- `deploy/client-bundle/setup-qm.ps1` (new — bootstrap script)
- `deploy/qm-pacgate/qm.config.jsonc` (modify — switch HARNESS, add modelProvider)
- `deploy/qm-pacgate/.env.example` (modify — add generation instructions)

**Out of scope** (do NOT touch):
- `deploy/qm-pacgate/sandbox/` — sandbox tools and skills are validated, no changes
- `deploy/qm-pacgate/package.json` or `package-lock.json` — qm CLI version is pinned
- `deploy/qm-pacgate/deployment.md` — upstream qm documentation, not our file to edit
- Any Rust code or pacgate-api endpoints

## Git workflow

- Branch: `advisor/003-qm-bootstrap`
- Commit message: `feat: qm first-run bootstrap script + real model config`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Update qm.config.jsonc for real model harness

In `deploy/qm-pacgate/qm.config.jsonc`, make these changes:

1. Change `env.core.HARNESS` from `"mock"` to `"pi"` (pi is qm's local model
   harness that connects to an OpenAI-compatible endpoint — i.e., Ollama).
2. Add `env.core.MODEL_BASE_URL` set to `"http://host.docker.internal:11434/v1"`
   so qm's pi harness talks to the host's Ollama.
3. Add `env.core.MODEL_API_KEY` set to `"ollama"` (Ollama's default key).
4. Add `env.core.MODEL_NAME` set to `"deepseek-v4-flash:0731-cloud"` (the
   default model — client can change this).
5. Keep `SANDBOX_BACKEND` as `"local"` (sandbox runs locally, not on Fly).
6. Keep all other fields unchanged.

The resulting `env` section should look like:
```jsonc
"env": {
  "core": {
    "HARNESS": "pi",
    "SANDBOX_BACKEND": "local",
    "MODEL_BASE_URL": "http://host.docker.internal:11434/v1",
    "MODEL_API_KEY": "ollama",
    "MODEL_NAME": "deepseek-v4-flash:0731-cloud"
  }
},
```

**Verify**: `cd deploy/qm-pacgate; npm exec qm -- check` → `check passed`

### Step 2: Update .env.example with generation instructions

In `deploy/qm-pacgate/.env.example`, add inline comments showing how to
generate each secret. The 4 signing secrets all use `openssl rand -hex 32`.
Also add the model-related env vars:

```env
# === Signing secrets (generate each with: openssl rand -hex 32) ===
CAPABILITY_SECRET=
CONNECTOR_SECRET_KEY=
CORE_SIGNING_SECRET=
PORTAL_IDENTITY_SECRET=
SKILL_SIGNING_SECRET=

# === Model provider (optional — qm can use Ollama via pi harness) ===
# If using ANTHROPIC_API_KEY, set modelProvider in qm.config.jsonc to "anthropic"
# ANTHROPIC_API_KEY=

# === Pacgate bridge credentials (create a service account in pacgate-api) ===
PACGATE_API_EMAIL=
PACGATE_API_PASSWORD=

# === Admin grants (set to the first administrator's email) ===
ADMIN_GRANTS=

# === Public API URL for sandbox agents ===
PUBLIC_API_URL=http://localhost:8180
```

**Verify**: Read the file back and confirm all 7+ secrets have generation instructions.

### Step 3: Create setup-qm.ps1 bootstrap script

Create `deploy/client-bundle/setup-qm.ps1`. This script is run by the
Cubecloud engineer on the client AIPC machine during installation. It:

1. Checks prerequisites: Node 24+, npm, Docker, Ollama
2. Copies `deploy/qm-pacgate/` to `C:\pacgate\qm-pacgate\` (if not already there)
3. Runs `npm ci` (or `npm install`) in the qm directory
4. Generates the 4 signing secrets using `openssl rand -hex 32` (or PowerShell
   equivalent: `[System.Security.Cryptography.RandomNumberGenerator]::GetBytes`)
5. Creates `.env` from `.env.example` with the generated secrets filled in
6. Prompts the engineer for:
   - Admin email (set as `ADMIN_GRANTS`)
   - Pacgate bridge service-account email + password (or generates a random
     password and prints it for the engineer to register in pacgate-api)
7. Runs `npm exec qm -- check` to validate the config
8. Runs `npm exec qm -- sandbox build` to build the sandbox image
9. Prints the next step: `npm exec qm -- up` to start the deployment
10. Does NOT run `qm up` itself — the engineer should verify config first

The script must NOT:
- Print or log any secret values after generating them
- Commit `.env` to git
- Run `qm up` automatically (engineer verifies first)

**Verify**: `Test-Path deploy/client-bundle/setup-qm.ps1` → True

### Step 4: Document the qm + pacgate-api bridge account setup

The `pacgate-qm` sandbox tool needs a service account in pacgate-api to
authenticate. The setup-qm.ps1 script prompts for `PACGATE_API_EMAIL` and
`PACGATE_API_PASSWORD`, but these must be registered in pacgate-api first.

Add a section to `deploy/client-bundle/README-client.md` (created by plan 001)
explaining the qm setup sequence:

```markdown
## Setting up qm (co-working workspace)

qm runs separately from the main Docker Compose stack. To set it up:

1. First, start the main stack: .\install.ps1
2. Register a service account in pacgate-api:
   - POST http://localhost:8081/api/auth/register with email + password
   - This account is used by the qm sandbox bridge tool
3. Run the qm bootstrap: .\setup-qm.ps1
   - This generates signing secrets, creates .env, and validates the config
4. Start qm: cd qm-pacgate && npm exec qm -- up
5. Access qm at: http://localhost:8182
```

**Verify**: Read README-client.md and confirm the qm setup section exists.

## Done criteria

- [ ] `deploy/qm-pacgate/qm.config.jsonc` has `HARNESS: "pi"` (not `"mock"`)
- [ ] `deploy/qm-pacgate/qm.config.jsonc` has MODEL_BASE_URL, MODEL_API_KEY, MODEL_NAME
- [ ] `deploy/qm-pacgate/.env.example` has generation instructions for all secrets
- [ ] `deploy/client-bundle/setup-qm.ps1` exists
- [ ] `cd deploy/qm-pacgate; npm exec qm -- check` → `check passed`
- [ ] `deploy/client-bundle/README-client.md` has qm setup section
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:
- `qm check` fails after changing HARNESS to "pi" — qm may require additional
  config fields for the pi harness that aren't documented in our files.
- The pi harness doesn't support Ollama's OpenAI-compatible endpoint (it may
  need a specific model format or a different env var name).
- `openssl` is not available on the client AIPC machine (use PowerShell
  `[System.Security.Cryptography.RandomNumberGenerator]::GetBytes` as fallback).

## Maintenance notes

- When the client wants to switch qm's model, change `MODEL_NAME` in
  `qm.config.jsonc` and restart qm (`npm exec qm -- down` then `npm exec qm -- up`).
- The 4 signing secrets are generated once and must NOT be regenerated on
  updates — that would break all existing sessions.
- If qm upstream changes the harness name from "pi" to something else, update
  `qm.config.jsonc` accordingly.