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
  makes the *layers* reproducible. Nothing was lost; it was never published
  anywhere.
  *One nuance added 2026-10-04, because I first wrote "so rebuilding yields the
  same digest" and that is not true:* the **layers** are reproducible, but the
  **manifest-list digest is not** — two consecutive `qm sandbox build` runs from
  unchanged source produced `e2dd07b0…` then `9283f270…`. Cause and consequence in
  the fix section below.
- **The mechanism is `localhost:5000`, not the digest.** The pin is correct *in
  form*; the only wrong part is the repository prefix, which names a registry that
  does not exist. (The value pinned is also one no build reproduces, but that is a
  second, independent defect — see the fix section.)

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

## STATUS 2026-10-04: the pin is fixed; the LANE IS STILL BROKEN. Read this first.

The image is now published and pinned (`ghcr.io/jzkk720/pacgate-sandboxes@sha256:d9645e9c…`),
the config and both compose copies agree, and the running core carries the new
reference. **But the sandbox lane has still never executed, and cannot yet.**

Measured state of the four links in the chain:

| Link | State |
|---|---|
| core holds the published pin | **YES** |
| image anonymously pullable | **NO** — `403`, package is PRIVATE |
| core holds docker credentials | **NO** — no `/root/.docker/config.json` |
| core can reach the docker daemon | **NO** — no socket, no `DOCKER_HOST`, no CLI |
| **=> can core boot a sandbox?** | **NO** |

And the empirical confirmation that no configuration has ever worked here: the
core's `/data` volume is **empty** — no run artifacts, no sandbox traces, nothing.

### A mechanism question this audit could not settle

The config declares `"target": "docker"`, and the CLI documents that target as
*"docker runs local containers"*. Yet the core has **no docker socket**, no
`DOCKER_HOST`, and no docker CLI, and `compose.qm.yaml` mounts none. So whatever
`SANDBOX_BACKEND=local` means in the core, it is **not** "core shells out to
`docker run`" — that could never have worked on this box. What actually launches
the sandbox is **not established**, and the CLI carries no socket reference.

This matters because it decides which fix is correct:

- if core is *supposed* to have a socket, the missing mount is the real defect and
  publishing the image was necessary but not sufficient; or
- if some other launcher is involved, the image reference may not even be what it
  consumes.

**Do not treat this as understood.** It needs the core's own source or docs, or a
run with debug logging, before anyone claims the lane works.

### What is still required for the lane to work

1. **Flip the package to PUBLIC** (manual UI step; the API 404s for a personal
   account). Without this no client — and no core without credentials — can pull.
2. **Establish how the sandbox is launched** (above), and mount what it needs.
3. **An end-to-end test that actually starts a sandbox** and runs one tool in it.
   None exists. Everything green today is green without ever exercising this lane,
   which is exactly how it got to this state.

## Why it matters

The sandbox is where the co-working agent's tools execute. On a new machine the
third runtime starts, answers HTTP, and cannot run the agent. Every signal says
success, so the failure surfaces to a user mid-task rather than at install.

## The fix — designed and measured 2026-10-04, NOT applied

Two options were tested against the actual validator and daemon rather than
reasoned about. **The measurements changed the design**, so read all of this
before picking one.

### What was measured

| Question | Measured answer |
|---|---|
| Does a locally built image get a `RepoDigest`? | **Yes** — `pacgate-sandbox@sha256:e2dd07b0…` |
| Does that satisfy `isDigestPinned` (`/@sha256:[0-9a-f]{64}$/`)? | **Yes** |
| Can Docker boot from it with no registry? | **Yes** — `docker run pacgate-sandbox@sha256:…` → `boot-ok` |
| **Is the `build` digest reproducible from unchanged source?** | **NO** — two consecutive builds gave `e2dd07b0…` then `9283f270…` |

### Why the digest moves — the actual root cause of the instability

`commands/sandbox.js`, build path:

```js
const args = ["buildx","build","--platform",SANDBOX_RUNTIME_PLATFORM,
              "--load","-t",tag,"--file",prepared.dockerfilePath,prepared.sandboxDir];
```

publish path:

```js
const args = ["buildx","build","--platform",SANDBOX_RUNTIME_PLATFORM,
              "--provenance=false","--push", ...];
```

**`build` does not pass `--provenance=false`; `publish` does.** Modern buildx
attaches an attestation manifest carrying a **timestamp**, so every `build`
produces a different manifest-list digest even when every layer is byte-identical.
`publish` suppresses the attestation, which is why its digest is the stable,
pinnable one.

This is why `qm sandbox build` alone can never satisfy the config — it is not
just that it writes no config (see below); its output digest is *inherently*
unstable, so there would be nothing stable to write.

### Option A — publish and pin (the documented path)

`publish` pushes the layer to a registry and writes the digest-pinned reference
into `qm.config.jsonc` itself (`updateConfigSandbox`, `sandbox.js:409`). That is
exactly what the config's comment says produced the current value.

- **Where it would push today:** `registry.fly.io/pacgate-sandboxes:latest`. The
  dry-run resolves the repository from `sandbox.app` via `flySandboxRepository`,
  and `authenticateFlyRegistry` would demand a `FLY_SANDBOX_API_TOKEN`. So
  publishing is wired to Fly, and Fly is not part of this deployment.
- **The workaround is clean:** `--app` resolves through `imageRepository` **only
  when the value contains a `/`**
  (`opts.app.includes("/") ? imageRepository(opts.app) : flySandboxRepository(opts.app)`).
  Verified: `--app ghcr.io/jzkk720/pacgate-sandboxes --dry-run` targets
  `ghcr.io/jzkk720/pacgate-sandboxes:latest`, and the Fly auth path is skipped
  because the repository is not `registry.fly.io`. The other five qm images are
  already public at `ghcr.io/yc-software/qm/*`, so no new namespace or
  reachability question is introduced.
- **Requires:** a GHCR login to push. **Not present here** — `~/.docker/config.json`
  has no `auths`. So it is a provisioning prerequisite, not something the
  installer can assume.

### Option B — do not pin a digest at all (rejected)

An earlier draft of this file proposed a local `name@sha256:` reference on the
grounds that "a locally built image carries no RepoDigest at all". **That was
wrong** — I measured one. But Option B still fails, for a better reason: the
`build` digest is not reproducible (above), so a local pin would go stale on the
very next rebuild and the fingerprint gate would report drift forever. And
`isDigestPinned` is only consulted for *format*; `config.js:98` still exports
`FLY_BASE_IMAGE = sb.image`, so whatever string is written there is what the core
tries to boot. A local reference only works if the build and the pin are produced
by the same step and the digest never moves — which `--provenance=false` would
give, but that is `publish`'s path anyway.

### So the fix is Option A, with one extra requirement

1. Publish with `--app ghcr.io/jzkk720/pacgate-sandboxes` (needs a GHCR login).
2. It writes the new digest-pinned reference into `qm.config.jsonc` aut.
3. Repin the `compose.qm.yaml:57` fallback to the same value, since that fallback
   is what the core receives when `.env` omits `FLY_BASE_IMAGE` — and the
   generated `qm-pacgate/.env` does omit it.
4. Record the source fingerprint so `qm-sandbox-fingerprint.ps1` stops reporting
   "no fingerprint recorded".
5. Make `setup-qm.ps1` stop printing an unconditional `[OK] Sandbox built`: the
   build is not what the core boots, so reporting it as success is the mask.

## Why not fixed here

Step 1 needs a registry login this machine does not have, and the whole change
alters what client machines pull, which per this repo's rule must be proven on a
clean clone. The mechanism is now fully traced and the option space measured, so
the next attempt can execute rather than re-derive.

## Related

- `deploy/qm-pacgate/INTEGRATION-MAP.md:67` — "machine-local registry: this image
  cannot be pulled, only rebuilt". True, and exactly why pinning it to a
  `localhost:5000` reference is broken for every machine but the one that once
  had a registry.
- `deploy/AIPC-UPDATE-GAP-ANALYSIS.md:53` — lists this among the 9-of-16 bind
  mounts needing human action.
- `deploy/client-bundle/setup-qm.ps1:371` — the `qm sandbox build` call.
- `deploy/INCIDENT-2026-10-04-qm-sandbox-env-printed.md` — while probing this
  defect I printed the sandbox's secret set. Third incident of that class.
