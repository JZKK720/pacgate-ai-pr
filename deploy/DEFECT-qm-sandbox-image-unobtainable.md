# DEFECT (HIGH for a clean machine): the qm sandbox image the config pins cannot be obtained

**Found:** 2026-10-03, while answering "can another new machine pull and compose
the whole stack and have every runtime work?"
**Root cause CORRECTED 2026-10-04** — the first version had the mechanism wrong.
See *Correction* below, because the correction is what determines the fix.
**Severity:** HIGH on a fresh machine. Silent — no error is raised anywhere.
**Status:** OPEN. Mechanism fully traced. Fix designed but NOT applied.

## The defect in one line

`qm.config.jsonc` pins the sandbox as
`localhost:5000/pacgate-sandboxes@sha256:207a779d…`. **Nothing provisions a
registry on `:5000`**, so the reference the config pins cannot resolve on this
machine or any other. The core is told to boot an image that is not there.

## Correction to the first version of this file

The first version said the pinned image was built and then lost, and implied
`qm sandbox build` had produced a differently-named artefact by mistake. Both
were wrong, and the real mechanism matters because it determines the fix:

- **The digest is self-consistent.** The `sandbox/Dockerfile`'s `FROM` is
  `ghcr.io/yc-software/qm/sandbox-base@sha256:52cb44a6…`. A digest-pinned `FROM`
  makes the build reproducible, so rebuilding the same context yields the same
  layer digest. Nothing was lost; it was never published anywhere.
- **The mechanism is `localhost:5000`, not the digest.** The build is correct and
  the pin is correct. The only wrong part is the repository prefix: it names a
  registry that does not exist.

## Measured evidence (2026-10-04)

| # | Check | Result |
|---|---|---|
| 1 | `qm.config.jsonc` `sandbox.image` | `localhost:5000/pacgate-sandboxes@sha256:207a779d…` |
| 2 | `qm.config.jsonc` `sandbox.baseImage` | `ghcr.io/yc-software/qm/sandbox-base@sha256:52cb44a6…` |
| 3 | Is the **base** publicly pullable? | **200 anonymous** — this half is fine |
| 4 | A registry on `:5000` | **none**, on any machine in this repo |
| 5 | `docker pull` the pinned reference | **fails** — `dial tcp [::1]:5000: i/o timeout` |
| 6 | Published under the qm namespace? | **403** — `ghcr.io/yc-software/qm/pacgate-sandboxes` does not exist |
| 7 | `qm sandbox publish --dry-run` | targets **`registry.fly.io/pacgate-sandboxes:latest`** |
| 8 | Is a sandbox container running *now*? | **no** — zero sandboxes, ever |

Row 7 matters: the dry-run resolves its repository from `sandbox.app`
(`pacgate-sandboxes`) through `flySandboxRepository`, so it would publish to
**Fly.io** — not to `localhost:5000` and not to GHCR. The config, the dry-run
target, and reality are three different places.

## How the reference reaches the core

`node_modules/@yc-software/qm/dist/src/config.js:98`, in `sandboxCoreEnv`:

```js
env.FLY_BASE_IMAGE = sb.image;      // <- the localhost:5000 reference
env.SANDBOX_BACKEND = backend;      // <- "local"
```

The core is handed a `localhost:5000` base image. That is a build-time identity
for a local registry; it is meaningless to the daemon that must run the
container, which is why a pull for it can never succeed.

## Masked five ways — which is why it went unnoticed

1. **`qm check` prints `check passed` with the pinned image absent.** Its
   `sandbox:` entry is the *source directory* (`sandbox/`), not the image. The
   config validates as valid while the artefact it names does not exist.
2. **`setup-qm.ps1` step 8 prints an unconditional `[OK] Sandbox built`.** It did
   build something; nothing compares the result to the pin.
3. **`qm-sandbox-fingerprint.ps1` checks source-vs-digest drift, never
   existence**, so the stronger failure arrives as a weaker warning — and its
   advice ("rebuild and repin") assumes the pinned image exists.
4. **No gate starts a sandbox.** The legal journey checks `qm portal reachable
   (200)` (HTTP only) and `smoke-full-stack.ps1` explicitly SKIPs the agent lane.
5. **The Dockerfile comment calls the image "published**", which reads as a
   working artefact rather than "nothing publishes this".

## Why it matters

The sandbox is where the co-working agent's tools execute. On a new machine the
third runtime starts, answers HTTP, and cannot run the agent. Every signal says
success, so the failure surfaces to a user mid-task rather than at install.

## The fix — designed, not yet applied

**Publish the layer to the namespace already in use, and pin THAT.** Rationale,
in the order the constraints actually bind:

- The five other qm images are already public at `ghcr.io/yc-software/qm/*`, so
  no new namespace, credential class, or reachability question is introduced.
- The pin survives: `isDigestPinned` accepts any `repository@sha256:<64 hex>`, so
  the immutability the validator enforces is kept. A purely local reference
  cannot satisfy it — after a local build the image carries **no `RepoDigest` at
  all** (verified: `docker image inspect pacgate-sandbox:local` returns none),
  because a registry assignation is what creates one.
- `publish --app` resolves through `imageRepository` **only when the value
  contains a `/`**:
  `opts.app.includes("/") ? imageRepository(opts.app) : flySandboxRepository(opts.app)`.
  So `--app ghcr.io/jzkk720/pacgate-sandboxes` targets GHCR, and
  `authenticateFlyRegistry` returns early because the repository is not
  `registry.fly.io`. No Fly dependency is triggered.
- A GHCR login is required to **push**, and is **not present on this machine**
  (`~/.docker/config.json` has no `auths`). So publishing is a provisioning
  prerequisite, not something the installer can assume.

Then: repin both `qm.config.jsonc:72` and the `compose.qm.yaml:57` fallback to the
published digest, and record the source fingerprint so
`qm-sandbox-fingerprint.ps1` stops reporting "no fingerprint recorded".

## Why not fixed here

It needs a registry login this machine does not have, and it changes what client
machines pull — which per this repo's rule must be proven on a clean clone.
Designing it blind and shipping it would be the guess-and-check these notes
repeatedly warn against. Recorded with the full mechanism so the next attempt
starts from the truth rather than the first version's wrong story.

## Related

- `deploy/qm-pacgate/INTEGRATION-MAP.md:67` — "machine-local registry: this image
  cannot be pulled, only rebuilt". True, and exactly why pinning it to a
  `localhost:5000` reference is broken for every machine but the one that once
  had a registry.
- `deploy/AIPC-UPDATE-GAP-ANALYSIS.md:53` — lists this among the 9-of-16 bind
  mounts needing human action.
- `deploy/client-bundle/setup-qm.ps1:371` — the `qm sandbox build` call.
