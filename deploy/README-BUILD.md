# Pacgate GHCR Image Build & Release

This document explains how the Pacgate runtime images get built and published
to GHCR, and how to keep both AIPCs in sync from a single source of truth.

## Why this matters

The client deployment (`deploy/client-bundle/`) references GHCR images. If some
images are built **locally** on each AIPC instead of pulled from GHCR, the two
machines can drift. The goal is: **every runtime image is published to GHCR, and
`install.ps1 -Update` pulls them all fresh.**

Before this change, two components were built locally and not on GHCR:

> **SUPERSEDED 2026-09-18 (plan 016).** The roles below were INVERTED by the
> maintainer: `jzkk720` is now the **release authority** for both the code and
> the images, and `pacgate-ai` is a **read-only mirror**. Everything from here
> to the end of the "Owner / namespace decision" section describes the
> 2026-09-17 model and is kept for history. The current model is in the next
> section.

## Release authority: jzkk720 (current)

| Account | Role | Publishes images? |
|---|---|---|
| `JZKK720` | **release authority** — code master AND image namespace | **YES** |
| `pacgate-ai` | read-only mirror of the same commits | no |

`GHCR_NAMESPACE: jzkk720` at the top of the workflow is the single source of
truth, and **every compose pin must match it**. If the workflow publishes to one
namespace and compose pins another, the client install pulls nothing and no
error is raised anywhere — that invariant is what `test-workflow-namespace.ps1`
exists to protect.

### Publishing without a PAT (the normal path)

The release runs from the `JZKK720` repo, so the pinned namespace and the token's
owner are the SAME account and the ordinary `GITHUB_TOKEN` is expected to
suffice. **Verified 2026-09-18, and it does not:**

    ERROR: failed to push ghcr.io/jzkk720/pacgate-api:0.1.14
    denied: permission_denied: write_package

Login succeeds and the job declares `packages: write`, so this is not a scope
problem — it is package **ownership**. Two `jzkk720` packages predate the repo
and are **not linked** to it (`GET /users/jzkk720/packages/container/<n>` shows an
empty `repository` field), while the fork's equivalents ARE linked to
`pacgate-ai/pacgate-ai-pr`. A package created BY a workflow gets that link; one
created by a manual `docker push` does not.

So the workflow path **needs `GHCR_RELEASE_PAT`** (a PAT with `write:packages`).
There is no GITHUB_TOKEN route to the unlinked packages.

### Publishing from a workstation (no PAT, no workflow)

The dev box's stored credential carries `write:packages`, and a registry-side
retag works from it — this is how 0.1.14 was published to `jzkk720`:

```powershell
docker buildx imagetools create --tag ghcr.io/jzkk720/<img>:0.1.14 `
                                   ghcr.io/pacgate-ai/<img>:0.1.14
```

Retag rather than rebuild: Docker builds are not reproducible (layer tars carry
mtimes), so a rebuild of identical source yields a DIFFERENT digest.

### Two traps that cost real cycles

1. **New GHCR packages are PRIVATE by default.** The only symptom is a failed
   *anonymous* pull; nothing errors at build time. The flip is **UI-only** for
   personal accounts — the REST `PATCH .../visibility` returns 404 even with
   `write:packages`. Use the package's settings page while signed in as the
   OWNING account (a session signed in as a different account 404s, and so does
a signed-out one).
2. **`pacgate-ai` appears in TWO unrelated roles.** It is the old image
   namespace AND the build-context directory `pacgate-ai/Dockerfile` (the Rust
   workspace in this repo). Never blind-replace the string; anchor on the image
   names.

### Required secrets

| Secret | Needed for | Required? |
|---|---|---|
| `GHCR_RELEASE_PAT` | PAT with `write:packages` for the release namespace; used by the build job | **Required** from `JZKK720` — the automatic token cannot write the unlinked packages |
| `GITHUB_TOKEN` | all other repo operations | automatic |

> There is no `GHCR_CLIENT_PAT` any more; the secret was renamed to
> `GHCR_RELEASE_PAT` to match its purpose.

### Historical: the 2026-09-17 single-namespace model (superseded)

Kept because the reasoning below is what was true at the time.

| Component | Before | After |
|---|---|---|
| `pacgate-mcp` | built from `../pacgate-mcp` per machine | `ghcr.io/pacgate-ai/pacgate-mcp:0.1.3` |
| `deer-flow-frontend` | built from `deer-flow-src/` per machine (`pacgate-deer-flow-frontend:0.2.0`) | `ghcr.io/pacgate-ai/deer-flow-frontend-pacgate:0.1.0` |
| `pacgate-api` | `ghcr.io/jzkk720/pacgate-api:0.1.2` (README) / `0.1.3` (compose) | aligned to `0.1.3` |
| `deer-flow-pacgate` | `ghcr.io/jzkk720/deer-flow-pacgate:0.1.0` | `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.3` |

> The `ghcr.io/jzkk720/*` references in the "Before" column are historical. As of
> 2026-09-17 `jzkk720` was declared the **code-only** master repo publishing **no**
> images. **That was reversed on 2026-09-18** — `jzkk720` is the release
> authority and every runtime image now lives under `ghcr.io/jzkk720/*`.

## Historical: owner / namespace decision (superseded)

The repo's push remote is `origin = JZKK720/pacgate-ai-pr` (the upstream /
developer account) and `fork = https://github.com/pacgate-ai/pacgate-ai-pr.git`
(the `pacgate-ai` org, used for client delivery).

> **Decided 2026-09-06:** publish under **`ghcr.io/pacgate-ai/*`**, and resolve
> it from a **committed constant** — not from `github.repository_owner`.
>
> The original workflow inferred the namespace from whichever repo triggered
> the run. That is correct on the fork and **wrong on a tag pushed from
> `JZKK720`**, which would publish to a namespace no compose file references.
> Nothing fails loudly in that case: the release goes green and every AIPC keeps
> pulling the previous images. The pinned constant removes the possibility.

`GHCR_NAMESPACE` at the top of the workflow is the single source of truth.
Precedence is:

1. the `namespace` dispatch input (deliberate override),
2. the committed `GHCR_NAMESPACE`,
3. `github.repository_owner` — last resort, so a fresh fork still builds.

Resolving to anything other than the pinned namespace emits a warning naming the
mismatch. The `scripts/test-workflow-namespace.ps1` + `-mutations.ps1` pair
guards these properties.

> The owner and the namespace are compared CASE-INSENSITIVELY: GHCR usernames
> are case-insensitive, but a shell comparison is not, and
> `github.repository_owner` preserves the account's real capitalization
> (`JZKK720`) while registry paths are lowercase (`ghcr.io/jzkk720`). Comparing
them raw emitted a warning about a 403 that would never happen.

### Historical: single namespace pacgate-ai (superseded)

`jzkk720` is the upstream/developer account where the project originated and is
maintained, but it is **code-only** — it publishes no images. A release populates
only `ghcr.io/pacgate-ai/*`, which is what both AIPCs pull:

| Namespace | Role | How |
|---|---|---|
| `ghcr.io/pacgate-ai/*` | client delivery, source of truth | `build-and-push` job |

The `mirror-upstream` job that once copied tags to `ghcr.io/jzkk720/*` has been
removed. Nothing automated pulls from that namespace, so the mirror was dead
weight and a misleading "mirror never ran" state.

### Historical: required secrets under that model

| Secret | Needed for | Required? |
|---|---|---|
| `GHCR_CLIENT_PAT` | PAT with `write:packages` for `pacgate-ai`, used by the **build** job | Optional on the `pacgate-ai` repo; **required** when running from `JZKK720` |

`secrets.GITHUB_TOKEN` is issued per repository and can only push to its own
owner's namespace. It therefore **cannot** cross into another account no matter
how the workflow is written — the automatic token is the default and the only
credential needed on the client-delivery repo.

> **First-publish gotcha:** new GHCR packages default to **private**. Flip each
> package to public in the UI, or clients cannot pull it. A private package has
> no other symptom than a failed anonymous pull.

Note `docker login ghcr.io` is **not** part of the client install path — the
runtime images are public by design and the on-site engineer pulls them
anonymously.

## How to build & push

### Option A — GitHub Actions (recommended, no local secrets)

Push a version tag; the workflow builds and pushes all four images:

```powershell
git tag v0.1.3
git push fork v0.1.3
```

The workflow `.github/workflows/build-ghcr.yml`:
1. Builds `pacgate-api`, `pacgate-mcp`, `deer-flow-pacgate`, `deer-flow-frontend-pacgate`.
2. Pushes each to `ghcr.io/pacgate-ai/<image>:0.1.3` and `:latest`.
3. Verifies each manifest is publicly pullable (anonymous HEAD returns 200).

#### The tag path has a failure mode - prefer dispatch

**The build runs from whatever commit the tag points at.** A tag created on a
commit where the workflow file is invalid produces nothing: the run shows
"Invalid workflow file" and no image is published. This is not hypothetical - it
is how the 0.1.14 release first failed, on a job-level `if:` that referenced the
`env` context, which GitHub rejects outright and which invalidates the ENTIRE
workflow rather than the one job.

Pushing a tag can also be impossible from a given machine. `secrets.GITHUB_TOKEN`
is scoped to its own repository, and a personal PAT is scoped to whichever
account issued it, so a developer whose credential belongs to the upstream
account cannot write a tag to the client fork.

### Option A2 - Dispatch the workflow (recommended when the tag path is blocked)

Dispatch decouples the image tag from the commit that builds it:

1. Actions -> **Build & Push GHCR Images** -> **Run workflow**.
2. **Use workflow from**: `main` (any ref with a valid workflow file).
3. **Image tag to build**: the version to publish, e.g. `0.1.14`.
4. Leave **GHCR owner override** empty - that resolves to the pinned
   `pacgate-ai` namespace.

The `tag` input sets what gets published; the branch selects the code. This needs
no local credential at all, so it works from any machine that can reach the
repository in a browser.

> **Note on `git tag` vs the release form.** There is no "Create tag" button on
> the Tags page - GitHub creates tags through the Releases form (or via git).
> The Releases form works from an account that cannot push tags, but it creates
> the tag at a commit of your choosing, so it still has the tag-vs-commit
> coupling above.

**Verify after either path:**

```powershell
pwsh -File .\scripts\verify-delivery-state.ps1   # pins, manifest version, GHCR 200s
pwsh -File .\scripts\report-ghcr-digests.ps1     # :latest tracks the version tag
```

**Then flip any NEW package to public.** New GHCR packages default to PRIVATE,
and a private package's only symptom is a failed anonymous pull on an AIPC.

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
