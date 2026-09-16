# 014 — Unattended AIPC Updates

Priority: **P1** · Effort: **M** · Depends on: 011 (release ✅) · Status: **IN PROGRESS — steps 1-5 done; step 6 (scheduled updater) remains**

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
| 5. Publish a staleness marker | ✅ **done** — `GET /version` reports the running binary's version + commit. Verified end-to-end against real containers |
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
| 5 | no version/staleness marker | a behind machine looks healthy | ✅ fixed — `GET /version` |
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

#### Delivered

`GET http://localhost:8089/version` →

```json
{"version":"0.1.12","revision":"a1b2c3d4e5f6..."}
```

`version` and `revision` come from `env!("CARGO_PKG_VERSION")` and a
`option_env!("PAC_SOURCE_REVISION")` build arg, **compiled into the
pacgate-api binary**. nginx proxies its `/build-info` at the public route.

**Why the binary reports it and not nginx, and not the image tag.** The image
tag and the compose pin both record what was DEPLOYED. The failure this exists
to catch is the deployed artifact disagreeing with the process actually serving
traffic — a machine whose containers were started from an older pull, or where
someone edited a pin. Only something compiled into the running process can
answer that. `revision` falls back to `unknown` rather than a wrong value when
the build arg is absent (the Dockerfile is also built outside CI, where no SHA
is known).

**Why it lives in `default.conf` and not its own `conf.d` fragment.** I tried a
separate `nginx/version.conf` first, so the marker would survive a client
editing their local `default.conf` — a plausible operation that the update
path's dirty-tree guard explicitly refuses to clobber. It does not work: a
`location` is only valid inside a `server` block, and nginx rejected the
fragment with `"location" directive is not allowed here`. A separate `server`
block on another port would work but would not be reachable at the documented
`:8089/version`. The reasoning and the rejected attempt are recorded in
`default.conf` so nobody re-tries it.

**Verification — `scripts/test-version-marker.ps1`, 6/6.** Stands up a real
network, a stub upstream aliased exactly as `pacgate-api`, and the real nginx
with the real `default.conf`, then requests the route. `nginx -t` would only
have proven the file parses; the failures worth catching here are all wiring —
the location not matching, `proxy_pass` sending `/build-info/` instead of
`/build-info`, the upstream not resolving, or the response being cached. The
stub returns a distinctive revision so the assertion proves the value travelled
through nginx rather than being invented by a default.

### 6. Add a scheduled updater — **last**

Only after 1–5 are proven idempotent. A Windows scheduled task running
`-Update` on a cadence is what removes the human.

**Do not skip ahead to this step.** Automating the update *before* fixing 1–5
would propagate silent failures at machine speed across both AIPCs.

## Acceptance criteria

Proven by `scripts/test-update-end-to-end.ps1` (28/28), which builds a REAL local
git origin, installs v1 on a simulated AIPC, publishes v2, and runs the actual
`install.ps1 -Update` in a child process with stub docker/ollama.

- [x] A machine one release behind, updated with a single command, ends up with
      the new images **and** the new compose pins, patches, workflows, and config
      — STEP 2: repo fast-forwards and the compose pin advances to the new
      release in the same command
- [x] Template changes reach an already-installed machine — STEP 2: the rendered
      file gains `pacgate` and a `.bak` is written. This is the proven lost update
      (`453646f`) reproduced and then fixed
- [x] Patch changes take effect without a manual restart — covered by the
      render/restart tests (`test-install-render.ps1`)
- [x] qm drift is either updated or clearly reported — reported; see step 4
- [x] `curl localhost:8089/version` reports the running tag — verified against the
      real 0.1.13 image (`test-version-marker-against-image.ps1`)
- [x] The whole update is safe to run twice in a row — STEP 4: no rewrite, no
      redundant backup, byte-identical config, HEAD unchanged
- [ ] Validated on a **fresh clone** in a temp dir, not on the dev box — the
      end-to-end test uses a fresh temp clone, but **not yet run on a real AIPC**

### A second update must still land (the sequential case)

STEP 3 covers something the first version of this test missed and that no unit
test could see: a **second** release arriving after the first update already wrote
a config backup. The backup is untracked, `git status --porcelain` counts
untracked files, so an unignored backup makes the tree dirty and the NEXT repo
refresh is skipped — the machine silently stays a release behind on all repo
content, with no error.

Found by removing the `.gitignore` rule and watching the suite stay green: a test
that could not fail. `.gitignore` now covers
`deploy/client-bundle/deer-flow-extensions-config.json.bak.*` and the OpenViking
equivalent, and removing either rule makes STEP 3 fail (5 assertions).

Worth knowing operationally: **any** stray file in the repo directory — an editor
swap file, a log, a scratch note — blocks the repo half of `-Update`. That is the
correct safety behaviour (it refuses rather than discarding work) and install.ps1
names the offending files so it is diagnosable.

## Verification

```powershell
# Per-machine, after the change lands:
.\scripts\audit-aipc-update-coverage.ps1     # gaps should read OK, not GAP

# Everything at once (9 gates + 1 measurement):
.\scripts\run-all-checks.ps1
```

## Out of scope

Namespace path B (`plans/012`) — orthogonal to delivery.

## Related

- `deploy/AIPC-UPDATE-GAP-ANALYSIS.md` — the evidence
- `plans/011` — the release this depends on (shipped)
- `plans/013` — credential work, still outstanding and independent
