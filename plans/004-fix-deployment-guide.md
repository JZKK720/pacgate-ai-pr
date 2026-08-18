# Plan 004: Fix stale DEPLOYMENT-GUIDE references

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check (run first)**: `git diff --stat 395144f..HEAD -- deploy/DEPLOYMENT-GUIDE.md`
> If this file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs / correctness
- **Planned at**: commit `395144f`, 2026-08-18

## Why this matters

The DEPLOYMENT-GUIDE has inline Dockerfile examples that contradict the actual
checked-in Dockerfile. An engineer following the guide would use Rust 1.81
(which fails — dependencies need 1.88+) and the wrong binary name (`pacgate-api`
vs actual `pacgate-server`). This plan aligns the guide with reality.

## Current state

- `deploy/DEPLOYMENT-GUIDE.md` line 42-49 shows:
  ```dockerfile
  FROM rust:1.81-bookworm AS builder
  ...
  RUN cargo build --release --bin pacgate-api
  ...
  COPY --from=builder /build/target/release/pacgate-api /usr/local/bin/pacgate-api
  ...
  CMD ["pacgate-api"]
  ```
- The actual `pacgate-ai/Dockerfile` uses:
  ```dockerfile
  FROM rust:1.94-bookworm AS builder
  ...
  RUN cargo build --release --bin pacgate-server
  ...
  COPY --from=builder /build/target/release/pacgate-server /usr/local/bin/pacgate-server
  ...
  CMD ["pacgate-server"]
  ```
- The guide also says "The `pacgate-ai/Dockerfile` (you need to create this)"
  but the Dockerfile already exists and has been built + pushed to GHCR.
- The guide's qm section (line 77) says the Dockerfile is "optional future shape"
  but doesn't clarify that qm runs via `qm up`, not `docker compose`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Verify no stale refs | `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "1.81"` | no matches |

## Scope

**In scope** (the only file you should modify):
- `deploy/DEPLOYMENT-GUIDE.md`

**Out of scope** (do NOT touch):
- `pacgate-ai/Dockerfile` — already correct
- `deploy/DEPLOYMENT-GUIDE.md` content about compose.prod.yaml, nginx, install.ps1
  — plan 001 creates the actual files; this plan only fixes the inline examples

## Git workflow

- Branch: `advisor/004-fix-deployment-guide`
- Commit message: `docs: fix stale Rust version + binary name in DEPLOYMENT-GUIDE`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Fix the inline Dockerfile example

In `deploy/DEPLOYMENT-GUIDE.md`, find the section "### 1.1 Build pacgate-api (Rust)"
(around line 28). Replace the inline Dockerfile code block and the "you need to
create this" text with:

1. Remove the "(you need to create this)" text — the Dockerfile already exists.
2. Replace the inline Dockerfile code block with a reference to the actual file:
   "The Dockerfile is at `pacgate-ai/Dockerfile`. It uses `rust:1.94-bookworm`
   (Rust 1.88+ required by dependencies) and produces the `pacgate-server`
   binary."
3. Keep the `docker build` command but update it to match the actual Dockerfile
   path (it's already correct: `-f pacgate-ai/Dockerfile ./pacgate-ai`).

**Verify**: `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "1.81"` → no matches

### Step 2: Fix the qm wrapper section

In `deploy/DEPLOYMENT-GUIDE.md`, find "### 1.3 Build qm wrapper" (around line 75).
The current text says the Dockerfile is "optional future shape." Update it to
clearly state:

"qm does NOT run as a Docker Compose service. It runs via `qm up` from the
`deploy/qm-pacgate/` deployment directory. See the setup-qm.ps1 script in the
client bundle for first-run bootstrap. There is no qm-pacgate Docker image to
build or push."

Remove the commented-out Dockerfile example and the `docker build` / `docker push`
commands for qm-pacgate.

**Verify**: `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "qm-pacgate:0.1.0"` →
no matches in docker build/push commands (may still appear in compose examples
being fixed by plan 001)

### Step 3: Fix the push section

In "### 1.4 Push to GHCR", remove the `docker push ghcr.io/jzkk720/qm-pacgate:0.1.0`
line since that image does not exist and will not exist (qm runs via `qm up`).

**Verify**: `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "push.*qm-pacgate"` → no matches

## Done criteria

- [ ] `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "1.81"` → no matches
- [ ] `Select-String -Path deploy/DEPLOYMENT-GUIDE.md "pacgate-api"` in Dockerfile
      examples → no matches (actual binary is `pacgate-server`)
- [ ] No `docker push` commands for `qm-pacgate` image
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back if:
- The line numbers cited don't match (the guide has been edited since this plan
  was written).

## Maintenance notes

- When the Dockerfile Rust version is bumped again, update the guide's reference
  to match. The guide should always reference the actual Dockerfile, not
  duplicate its content.