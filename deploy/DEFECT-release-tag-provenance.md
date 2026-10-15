# DEFECT: the 0.1.28 tag did not identify the published images

**Status:** fixed (`v0.1.28` moved to the built commit) — guard added so it cannot
recur silently.

**Severity:** release-integrity. The published artifacts were correct; the tag
that is supposed to describe them was not.

## What happened

Every step was reasonable and nothing reported an error:

1. `v0.1.28` was tagged at `fffec57` and pushed. `build-ghcr.yml` fired on the
   push and published five images with
   `org.opencontainers.image.revision = fffec57`. Correct at the time.
2. The PaddleOCR weights bake then landed in `afe2965` — *after* the tag.
3. `workflow_dispatch` was used to publish the bake without minting a new version
   number. Correct in intent: same version, new content.
4. The dispatch rebuilt from `main`, overwriting the existing `0.1.28` packages
   with `revision = afe2965`. **The tag was never moved.**
5. My local `v0.1.28` was likewise stale, so `install.ps1 -Update` on the dev box
   ran the older `fffec57` build while the registry served `afe2965`.

Measured, not inferred:

```
git ls-tree -r --name-only 'v0.1.28^{commit}' -- deploy/ocr-service/
  deploy/ocr-service/Dockerfile
  deploy/ocr-service/app.py
  deploy/ocr-service/requirements.txt          <- no warm_up.py

docker inspect ghcr.io/jzkk720/ocr-service:0.1.28 \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
  afe29654d05025e2f32eb9bd635be74f292d0df7     <- the bake
```

## Why it mattered

It is not cosmetic. `preflight-release-tag.ps1` correctly refuses to proceed while
the tag and the packages both exist, so **the only way to re-derive 0.1.28 is from
its own tag** — and a rebuild from that tag would have reproduced the
**bake-less** image, silently re-introducing an intermittent OCR failure the
release exists to remove.

## The mechanism, stated plainly

In `build-ghcr.yml`, `Resolve image tag` reads `inputs.tag` on a dispatch and
`github.ref_name` on a push, and `actions/checkout` sets no explicit `ref:`. So a
dispatch checks out `main` while still publishing the **old version number**. Any
dispatch that runs after a tag therefore moves the artifact without moving the
tag. Nothing in the repo could see it: `preflight-release-tag.ps1` checks only
*before* a release, and `smoke-full-stack.ps1` asserts only that `/version`
carries *some* revision.

## Fix

`v0.1.28` was re-created as an annotated tag and force-pushed, pointing at the
commit whose inputs actually produced the published images. The tag message now
records the bake and explains the move, so the next reader does not rediscover it.

## Guard

`scripts/test-release-provenance.ps1`, registered in `run-all-checks.ps1`.

It asserts three things, all self-contained (registry + git only; no docker, no
running stack):

1. **Every published image is readable from the registry**, and their
   `org.opencontainers.image.revision` labels all agree. The image set is
   *derived* from the compose pins rather than hardcoded, so adding a first-party
   image cannot silently drop out of coverage.
2. **The tag exists and is annotated.**
3. **No file that can reach a built image changed between the built revision and
   `HEAD`** — using each Dockerfile's real `COPY` sources plus
   `pacgate-ai/.dockerignore`, so the answer is about build inputs and not about
   "any file under a repo-root context".

Red-checked against the live defect: while the two states disagreed it failed with

```
FAIL  published images came from 2 DIFFERENT builds:
      ...:0.1.28=afe29654d050 (x3)   ...:0.1.28=50252862c826 (x2)
```

Note the registry read is fiddly and worth not rediscovering: two **different**
`Accept` lists are required (an index manifest 404s a child manifest), and the
revision is a **label in the image config blob** — a third request, authenticated
with the same token.

## Residual

- The guard proves *build-input* equivalence by a conservative path-prefix model.
  A new image whose context cannot be described by a prefix would be reported as
  "not image-affecting". The Dockerfile set is listed explicitly to keep that
  visible; a new fifth image needs a line here.
- This records and prevents the divergence; it does not stop a future
  `workflow_dispatch` from overwriting a published version. The durable fix is to
  have the workflow refuse a dispatch whose `main` is ahead of tag inputs, which
  is not done here.
