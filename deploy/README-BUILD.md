# Pacgate GHCR Image Build & Release

This document explains how the Pacgate runtime images get built and published
to GHCR, and how to keep both AIPCs in sync from a single source of truth.

## Why this matters

The client deployment (`deploy/client-bundle/`) references GHCR images. If some
images are built **locally** on each AIPC instead of pulled from GHCR, the two
machines can drift. The goal is: **every runtime image is published to GHCR, and
`install.ps1 -Update` pulls them all fresh.**

Before this change, two components were built locally and not on GHCR:

| Component | Before | After |
|---|---|---|
| `pacgate-mcp` | built from `../pacgate-mcp` per machine | `ghcr.io/pacgate-ai/pacgate-mcp:0.1.3` |
| `deer-flow-frontend` | built from `deer-flow-src/` per machine (`pacgate-deer-flow-frontend:0.2.0`) | `ghcr.io/pacgate-ai/deer-flow-frontend-pacgate:0.1.0` |
| `pacgate-api` | `ghcr.io/jzkk720/pacgate-api:0.1.2` (README) / `0.1.3` (compose) | aligned to `0.1.3` |
| `deer-flow-pacgate` | `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` | `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.3` |

## Owner / namespace decision

The repo's push remote is `fork = https://github.com/pacgate-ai/pacgate-ai-pr.git`
(the `pacgate-ai` org), and `origin = JZKK720/pacgate-ai-pr`. The CI workflow
(`.github/workflows/build-ghcr.yml`) publishes to
`ghcr.io/${{ github.repository_owner }}/*`, which is **whatever org owns the
repo that triggers the workflow**.

> **Decided 2026-09-06:** publish under **`ghcr.io/pacgate-ai/*`**. The repo
> pushes to the `pacgate-ai` fork, and the cached `pacgate-ai` credential owns
> that org, so `v0.1.3` tags triggered from the fork land in `pacgate-ai/*`.
> The compose pins, build scripts, and docs all reference `ghcr.io/pacgate-ai/*`.

To switch back to `jzkk720/*`, update the `image:` lines in
`deploy/client-bundle/compose.*.yaml`, the build scripts, and this doc — and
push the tag from the `JZKK720` repo instead.

## How to build & push

### Option A — GitHub Actions (recommended, no local secrets)

Push a version tag; the workflow builds and pushes all four images:

```powershell
git tag v0.1.3
git push fork v0.1.3
```

The workflow `.github/workflows/build-ghcr.yml`:
1. Builds `pacgate-api`, `pacgate-mcp`, `deer-flow-pacgate`, `deer-flow-frontend-pacgate`.
2. Pushes each to `ghcr.io/<owner>/<image>:0.1.3` and `:latest`.
3. Verifies each manifest is publicly pullable (anonymous HEAD returns 200).

### Option B — Local build & push

Requires `docker login ghcr.io` first (interactive; do not route secrets
through an assistant).

```powershell
# Build + push all four
.\deploy\build-images.ps1 -Push

# Build + push only pacgate-api and pacgate-mcp
.\deploy\build-images.ps1 -Only api,mcp -Push

# Frontend only (clones bytedance/deer-flow v2.0.0, builds with gateway baked in)
.\deploy\build-frontend.ps1 -Push
```

## The deer-flow-frontend fix

The published `ghcr.io/bytedance/deer-flow-frontend:latest` bakes
`DEER_FLOW_INTERNAL_GATEWAY_BASE_URL=http://127.0.0.1:8001` at build time, which
is unreachable from inside the compose network (the backend is `deer-flow:8001`).
Historically this required a runtime patch to `.next/routes-manifest.json`
(see `plans/007-signin-status.md`).

The Pacgate wrapper (`deploy/deer-flow-frontend-pacgate/Dockerfile`) builds from
the pinned bytedance `v2.0.0` tag with `DEER_FLOW_INTERNAL_GATEWAY_BASE_URL`
baked in at build time, so the `/api/*` rewrites are correct with **no runtime
patch** — making the image reproducible and safe to publish.

## Pinning the deer-flow backend

`deploy/deer-flow-pacgate/Dockerfile` wraps `ghcr.io/bytedance/deer-flow-backend`
at a pinned SHA. When bumping the backend, update that `FROM` line, rebuild, and
bump the compose pin. The frontend must be built from the **matching** bytedance
tag (the frontend `v2.0.0` tag matches the backend 2.0.0 image).

## Verification

After a push, confirm each image is publicly pullable:

```powershell
# Anonymous token flow (200 = public)
$tok = Invoke-RestMethod "https://ghcr.io/token?scope=repository:pacgate-ai/pacgate-mcp:pull"
Invoke-WebRequest -Uri "https://ghcr.io/v2/pacgate-ai/pacgate-mcp/manifests/0.1.3" `
  -Method Head -Headers @{Accept="application/vnd.oci.image.index.v1+json"; Authorization="Bearer $($tok.token)"}
```
