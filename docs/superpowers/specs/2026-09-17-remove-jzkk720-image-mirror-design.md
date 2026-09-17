# Design: Remove the jzkk720 image mirror — jzkk720 becomes code-only

**Date:** 2026-09-17
**Status:** Approved
**Author:** Copilot (autonomous, user unavailable — decision flagged)

## Problem

The `build-ghcr.yml` workflow publishes images to `ghcr.io/pacgate-ai/*` (the
client-delivery namespace both AIPCs pull) and mirrors the same tags to
`ghcr.io/jzkk720/*` (the upstream/developer namespace). The mirror has **never
actually run** — `GHCR_MIRROR_PAT` is unset, so `mirror-upstream` always skips
with a warning. It is dead weight and a misleading "mirror never ran" state.

The maintainer's intent: keep the fork's `origin/main` publishing its own GHCR
images (that is what both AIPCs already pull), and make `jzkk720` purely the
**master codebase for maintenance** — no image namespace.

## Approach: Fully remove the mirror machinery

`jzkk720` becomes code-only. `pacgate-ai` is the sole image source of truth.

### Changes

1. **`.github/workflows/build-ghcr.yml`**
   - Delete the entire `mirror-upstream` job.
   - Remove `GHCR_MIRROR_NAMESPACE: jzkk720` from the `env:` block.
   - Update the header comment: `jzkk720` is now the code repo only; `pacgate-ai`
     is the sole image source. Remove the "TWO ACCOUNTS, TWO ROLES" mirror framing
     and the "THE MIRROR JOB ONLY RUNS IF..." note.

2. **`scripts/check-workflow-validity.ps1`**
   - Remove the mirror-guard assertion and the comment reference.

3. **`scripts/test-workflow-namespace.ps1`**
   - Remove the entire "mirror-upstream job" assertion block and the
     jzkk720-mirror-marking checks.

4. **`scripts/test-workflow-validity-mutations.ps1`**
   - Remove the mirror-guard mutation and its comment.

5. **`deploy/README-BUILD.md`**
   - Update the namespace table: `jzkk720` is code-only; remove the mirror row,
     `GHCR_MIRROR_PAT` row, and mirror prose.

### What stays unchanged

- `GHCR_NAMESPACE: pacgate-ai` (the source of truth — both AIPCs pull this).
- The `namespace` dispatch input (still allows deliberate override).
- `GHCR_CLIENT_PAT` (still the cross-namespace credential for the build job).
- All compose pins (`ghcr.io/pacgate-ai/*`).

### Trade-off

The only thing lost is the ability to pull images from `ghcr.io/jzkk720/*`.
Since nothing automated pulls from there (the mirror never ran, and compose pins
`pacgate-ai`), this is zero functional loss. The benefit is a simpler, honest
workflow: one namespace, one source of truth, no dead mirror.

## Validation

- `scripts/check-workflow-validity.ps1` passes (mirror assertions removed).
- `scripts/test-workflow-namespace.ps1` passes (mirror assertions removed).
- `scripts/test-workflow-validity-mutations.ps1` passes (mirror mutation removed).
- `git grep` for `GHCR_MIRROR` / `mirror-upstream` returns no remaining references.
