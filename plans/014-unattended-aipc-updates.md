# 014 — Unattended AIPC Updates

Priority: **P1** · Effort: **M** · Depends on: 011 (release ✅) · Status: **IN PROGRESS — steps 1-3 done, step 4 drift detection done**

**This is the end-goal plan.** 011 shipped the artifacts; this makes them reach
both AIPCs without a developer logging in. Full evidence:
`deploy/AIPC-UPDATE-GAP-ANALYSIS.md`.

## Progress (2026-09-16)

| Step | Status |
| --- | --- |
| 1. `-Update` refreshes the repo | ✅ **done** — fast-forward only; refuses on a dirty or diverged tree; `-SkipRepoPull` to opt out. Tests `scripts/test-install-repo-pull.ps1` (13/13) |
| 2. Render-and-compare the config | ✅ **done** — regenerates and compares every run, backs up, and NAMES what changed. Tests `scripts/test-install-render.ps1` (11/11) |
| 3. Restart services with bind-mounted code | ✅ **done** — folded into step 2's commit (`docker compose restart deer-flow` on `-Update`) |
| 4. Bring qm into the update path | 🟡 **partly** — sandbox drift is now DETECTED and reported on every `-Update`; the rebuild itself is deliberately left manual |
| 5. Publish a staleness marker | ⬜ not started |
| 6. Scheduled updater | ⬜ last, deliberately |

Steps 1 and 2 both had their tests validated by breaking the implementation and
confirming the tests fail — so they detect regressions rather than passing
vacuously. Step 4's fingerprint tool was validated the same way.

## Goal

An AIPC picks up upstream repo + GHCR updates and runs a fully functional
runtime **with no developer on the machine**. Every fix that ships reaches both
machines, and a stale machine is detectable rather than silently behind.

## Why now

The 0.1.12 release is live and green, so the artifacts are correct. But the
delivery path cannot carry them: `install.ps1 -Update` pulls images and reloads
nginx, and nothing else. **9 of 16 bind mounts need a human action**, one class
of fix never lands at all, qm is outside the loop, and no machine can tell
whether it is current.

## The defects to close

| # | Defect | Impact | Status |
| --- | --- | --- | --- |
| 1 | `-Update` never runs `git pull` | repo content (compose, patches, workflows) stays stale unless remembered | ✅ fixed |
| 2 | config rendered **only if absent** | template updates **never land** — proven lost update (`453646f` added `pacgate-mcp` and fixed an API key) | ✅ fixed |
| 3 | bind-mounted `.py` needs restart, none performed | patch fixes sit on disk doing nothing | ✅ fixed |
| 4 | qm untouched by `-Update` | 7 containers + sandbox drift independently | 🟡 sandbox drift now detected + reported; rebuild left manual by design |
| 5 | no version/staleness marker | a behind machine looks healthy | ⬜ open |
| — | two unrelated renders shared one guard | a missing OpenViking template silently skipped the deer-flow config | ✅ fixed (found while testing step 2) |

## Steps — in this order

### 1. Make `-Update` update the repo

Add repo currency handling to `install.ps1` before pulling images. Prefer
`git fetch` + compare + `git pull --ff-only` so a dirty machine fails loudly
rather than merging unexpectedly.

**Guard:** if the working tree is dirty, stop and say so — never auto-stash on a
client machine.

### 2. Replace render-if-absent with render-and-compare

Regenerate `deer-flow-extensions-config.json` from the template on **every**
update. If the existing file differs from a fresh render, back it up to
`*.bak.<timestamp>` and write the new one, reporting what changed.

This is what makes defect 2 permanently safe — and it is the fix with the
highest value, because a silently-stale config produces no error at all.

### 3. Restart what needs restarting

After `up -d`, explicitly restart services whose code is bind-mounted:
`docker compose restart deer-flow`. Idempotent and cheap.

### 4. Bring qm into the update path

Either extend `-Update` to cover the qm stack, or add a `-UpdateQm` switch that
runs the qm equivalent. At minimum, **detect and report** qm drift so it is
visible.

Note the sandbox image is `localhost:5000/pacgate-sandboxes@sha256:…` — a
machine-local registry. Updating it means rebuilding via
`npm exec qm -- sandbox build` from the repo's `sandbox/` directory, not pulling.

#### Delivered: sandbox drift is detected and reported

`scripts/qm-sandbox-fingerprint.ps1` hashes the tracked contents of
`deploy/qm-pacgate/sandbox/` and compares it with a `sourceFingerprint`
recorded next to the digest pin.

**The failure this exists for.** The sandbox image is pinned by DIGEST. Digest
pinning is right — the isolation boundary should be immutable — but it means a
repo update can change `sandbox/` while the pinned image stays exactly as it
was, so the agent keeps running OLD skills and tools with no error anywhere.
`qm sandbox build` alone does not fix it either: that produces a new image whose
digest is not the one in `qm.config.jsonc`, so the digest must be repinned too.

`-Update` now calls it and reports `OK` / `NOT_RECORDED` / `DRIFT` when qm is
running on the machine.

**Why it reports instead of rebuilding.** The rebuild needs Node 24 + npm +
buildx and takes minutes, and the digest must be repinned afterwards — a config
change we should not make unattended on a client machine. A wrong automatic
rebuild is a worse failure than a visible warning. Automating the rebuild belongs
with step 6, once 1–5 are proven.

Two properties worth keeping if this is ever rewritten:

- **Line endings are normalised before hashing.** The same commit checked out
  with `core.autocrlf=true` and `false` has different bytes but identical
  content. Hashing raw bytes would report phantom drift on every cross-machine
  comparison, and a check that cries wolf gets ignored — which is how the REAL
  drift gets missed. Verified by test: a CRLF rewrite of identical content is
  not drift.
- **Only tracked files count.** An untracked scratch file in `sandbox/` is not
  part of the image's provenance and must not report drift, or the check fires
  on work-in-progress.

#### Still open in step 4

- The **qm stack containers** (7) are still outside `install.ps1`.
- No machine has a recorded fingerprint yet, so every machine reads
  `NOT_RECORDED` until someone runs the rebuild + repin + `-Write` once. That is
the honest state: we cannot claim the sandbox matches its source when nobody has
recorded what it was built from.

### 5. Publish a staleness marker

Expose the running version (image tag) on an unauthenticated route, e.g. nginx
`/version`. Then any machine, monitor, or the operator can answer "is this
current?" without SSH.

### 6. Add a scheduled updater — **last**

Only after 1–5 are proven idempotent. A Windows scheduled task running
`-Update` on a cadence is what removes the human.

**Do not skip ahead to this step.** Automating the update *before* fixing 1–5
would propagate silent failures at machine speed across both AIPCs.

## Acceptance criteria

- [ ] A machine one release behind, updated with a single command, ends up with
      the new images **and** the new compose pins, patches, workflows, and config
- [ ] Template changes reach an already-installed machine (test: change the
      template, update, confirm the rendered file changed and a `.bak` exists)
- [ ] Patch changes take effect without a manual restart
- [ ] qm drift is either updated or clearly reported
- [ ] `curl localhost:8089/version` reports the running tag
- [ ] The whole update is safe to run twice in a row
- [ ] Validated on a **fresh clone** in a temp dir, not on the dev box

## Verification

```powershell
# Per-machine, after the change lands:
.\scripts\audit-aipc-update-coverage.ps1     # gaps should read OK, not GAP
```

## Out of scope

Namespace path B (`plans/012`) — orthogonal to delivery.

## Related

- `deploy/AIPC-UPDATE-GAP-ANALYSIS.md` — the evidence
- `plans/011` — the release this depends on (shipped)
- `plans/013` — credential work, still outstanding and independent
