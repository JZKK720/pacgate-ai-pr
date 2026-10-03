# DEFECT (HIGH for a clean machine): the qm sandbox image the config pins cannot be obtained

**Found:** 2026-10-03, while answering "can another new machine pull and compose
the whole stack and have every runtime work?"
**Severity:** HIGH on a fresh machine. Silent — no error is raised anywhere.
**Status:** OPEN. Root cause identified and measured. Not fixed (see *Why not fixed here*).

## The defect in one line

`qm.config.jsonc` and `compose.qm.yaml` both pin the sandbox image as
`localhost:5000/pacgate-sandboxes@sha256:207a779d0d40ba0b…`. **That image exists
nowhere** — not on a registry, not on this machine — and the image the installer
actually builds has a *different name and digest* that is recorded in neither
file. So the agent's sandbox can never start from what the repo contains.

## Measured evidence (2026-10-03, 0.1.22)

| # | Check | Result |
|---|---|---|
| 1 | Pinned in `qm.config.jsonc:72` and as the `compose.qm.yaml:57` fallback | `localhost:5000/pacgate-sandboxes@sha256:207a779d0d40ba0b…` |
| 2 | Any local image matching that digest | **none** |
| 3 | A local registry on `:5000` | **none** (`docker ps -a` shows nothing on 5000) |
| 4 | `docker pull` the pinned reference | **failure** — `dial tcp [::1]:5000: i/o timeout` |
| 5 | Published publicly like the other qm images | **403** — `ghcr.io/yc-software/qm/pacgate-sandboxes` does not exist |
| 6 | What `npm exec qm -- sandbox build` produces | **`pacgate-sandbox:local`**, digest `e817c1f3aacbbd6c…`, 5 GB |
| 7 | Is that built digest recorded in either config? | **no** — only `207a779d` appears |
| 8 | Has a sandbox container ever run on this box? | **no** — zero containers, ever |
| 9 | `FLY_BASE_IMAGE` set in the generated `.env`? | **no** — so compose falls back to the unobtainable pin |

Note #6: the build **succeeds** (exit 0). The CLI is not the problem; my earlier
note that `qm` cannot drive Docker on Windows is **wrong for `sandbox build`** —
it uses buildx and works. That correction matters, because it is why nobody
looked here.

## Why it is silent — the failure is masked three times over

1. **`setup-qm.ps1` step 8 prints `[OK] Sandbox built`.** It *did* build
   something. It built a different thing from the one the config references, and
   nothing compares the two. This is the same class as the other cases in the
   repo's false-confidence notes.
2. **`qm-sandbox-fingerprint.ps1` cannot see it.** Its job is source-vs-digest
   drift, and it correctly reports `No fingerprint recorded for the pinned
   sandbox image`. But its advice is *"rebuild and repin"* — which assumes the
   pinned image exists to begin with. It never checks existence, so the stronger
   failure passes through as a weaker warning.
3. **No gate exercises a sandbox.** The legal journey verifies
   `qm portal reachable (200)` — HTTP only. `smoke-full-stack.ps1` explicitly
   SKIPs the agent lane. So the entire suite is green while the one component
   that runs model-directed tool calls cannot start.

## Why it matters

The qm sandbox is where the co-working agent's tools execute. If it cannot start,
the "all three runtimes fully functional" goal is not met on a new machine — the
third runtime comes up, answers HTTP, and cannot do its job. And because every
signal says success, the failure would be discovered by a user mid-task, not at
install.

## What the correct fix has to decide (NOT mechanical)

Two candidate designs, and they are genuinely different:

**A. Publish and pin (keeps immutability).** Push the sandbox image to a registry
the client can reach — `ghcr.io/jzkk720/…` is the established pattern here, and
the other five qm images are already public — then pin THAT reference. Keeps the
digest pin meaningful, and the provenance gate starts working because the digest
can finally be recorded against a source fingerprint.

**B. Build-and-reference locally (no registry needed).** Have `setup-qm.ps1`
build the image and then *write the resulting reference into the config it just
generated*, so the pin and the artefact are produced by the same step and cannot
disagree. Removes the registry dependency entirely. Costs the immutability
guarantee unless the digest is still pinned after the build.

Either way, `setup-qm.ps1` must stop printing an unconditional `[OK]`, and the
fingerprint gate should report a MISSING image as a hard failure distinct from
"no fingerprint recorded".

## Why not fixed here

This is not a one-line change, and the choice between A and B is a deployment
decision with a real trade-off (registry reachability on a client site vs. the
immutability of the isolation boundary). It also cannot be validated without a
clean machine. Recorded, with the measurements, so it is not lost and so the next
person does not have to re-derive it.

## Related

- `scripts/qm-sandbox-fingerprint.ps1` — the provenance gate (detects drift, not absence).
- `deploy/qm-pacgate/INTEGRATION-MAP.md` — states the image is machine-local and
  "can be rebuilt, never pulled". That is true, and it is exactly why pinning it
  to a `localhost:5000` reference is broken for any machine but the one that had
  the registry.
- `deploy/client-bundle/setup-qm.ps1:371` — the `qm sandbox build` call.
