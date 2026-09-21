# Deer-flow upstream drift assessment - 2026-09-21

**Question:** do we need to update our current version of deer-flow with upstream
new commits and updates?

**Short answer:** not now for correctness, yes soon for security and for feature
parity. We are frozen on upstream `v2.0.0` (2026-06-25) while upstream has moved
to `v2.1.0-rc0` (2026-09-17, now the `latest` image). The bump is a real project,
not a one-line change, because we override seven backend modules by bind-mount
and overwrite seventeen frontend files by copy.

Evidence below is measured from the repo and from upstream, not assumed.

---

## 1. Where we actually are

| Item | Pinned value | Upstream now | Gap |
| --- | --- | --- | --- |
| Backend base image | `ghcr.io/bytedance/deer-flow-backend@sha256:e7c503a8...` | same digest is tag `v2.0.0`; `latest` and `v2.1.0-rc0` are `sha256:4f30bb45...` | one minor release |
| Frontend source | git clone `--branch v2.0.0` | `main` / `v2.1.0-rc0` | see below |
| Commits `v2.0.0..v2.1.0-rc0` (the bump target) | - | **3,335** | - |
| Commits `v2.0.0..origin/main` | - | 3,402 (67 of them land after the rc) | - |
| 2.1.0 milestone scope | - | 765 merged PRs | - |
| 2.1.0 milestone state | - | **95% complete, no due date** | - |
| Commits in the rc0 phase | - | 67 in 4 days (48 `fix` / 15 `feat`) | - |
| Breaking changes in 2.1.0 | - | **11** bullets | - |

Verified by digest, not by tag name:

```
v2.0.0       -> sha256:e7c503a803c99a039e08da61359932877a9e0d0196799429698244117338af13
v2.1.0-rc0   -> sha256:4f30bb450cec56ddf3e1896d9183a2982f5da7deffc5067fffb868cd7659d838
latest       -> sha256:4f30bb450cec56ddf3e1896d9183a2982f5da7deffc5067fffb868cd7659d838
```

The digest we build on **is** the `v2.0.0` tag image, built 2026-06-25. Our
wrapper is therefore exactly one minor release behind, and the frontend build
clones the matching `v2.0.0` tag. Backend and frontend are consistent with each
other today, which is the right state to be in.

## 2. Why this is a project and not a bump

Our integration is deliberately non-invasive (no fork, wrapper image + adapter).
But three mechanisms pin us to specific upstream code, and all three break on a
minor bump:

**a. Seven backend modules are bind-mounted over upstream files.** From
`deploy/client-bundle/compose.prod.yaml`:

```
./patches/deer-flow-artifacts.py    -> /app/backend/app/gateway/routers/artifacts.py
./patches/deer-flow-thread-runs.py  -> /app/backend/app/gateway/routers/thread_runs.py
./patches/deer-flow-uploads.py      -> /app/backend/app/gateway/routers/uploads.py
./patches/deer-flow-prompt.py       -> /app/backend/packages/harness/deerflow/agents/lead_agent/prompt.py
./patches/deer-flow-agent.py        -> /app/backend/packages/harness/deerflow/agents/lead_agent/agent.py
./patches/deer-flow-worker.py       -> /app/backend/packages/harness/deerflow/runtime/runs/worker.py
./patches/deer-flow-sync.py         -> /app/backend/packages/harness/deerflow/tools/sync.py
./patches/langchain-mcp-tools.py    -> /app/backend/.venv/lib/python3.12/site-packages/langchain_mcp_adapters/tools.py
```

Each mounted file is a snapshot of the `v2.0.0` module plus our changes. They are
not patches against a moving target; they are whole-file replacements. Upstream
churn in exactly these seven files, measured `v2.0.0..v2.1.0-rc0` (the real bump
target), is **6,219 insertions across 934 deletions**:

| Overridden upstream file | diff size |
| --- | --- |
| `runtime/runs/worker.py` | 2,902 lines changed |
| `gateway/routers/thread_runs.py` | 1,666 |
| `agents/lead_agent/agent.py` | 1,022 |
| `agents/lead_agent/prompt.py` | 847 |
| `gateway/routers/artifacts.py` | 504 |
| `gateway/routers/uploads.py` | 383 |
| `tools/sync.py` | 16 |

All seven plus the eighth mount (`langchain-mcp-tools.py`, which overrides a
vendored package rather than upstream source) must be re-derived, not carried
forward.

A naive bump would silently discard all of that upstream work in the eight
overridden paths, while the rest of the image moves forward. That is the failure
mode to fear: not a build error, but a container that starts green and behaves
like a half-upgraded mix.

**b. The frontend patch is a whole-file copy, not a diff.** From
`build-ghcr.yml`:

```
cp -rv deploy/frontend-patches/files/. deploy/deer-flow-src/frontend/
```

Seventeen files are copied in this way (fourteen source plus three tests),
including the i18n locales, the workspace chat surfaces, and the sanitizer
module. Locale files are the most exposed, because upstream rewrites the whole
file as strings are added. Measured against the `en-US.ts` locale:

| Comparison | Added | Deleted |
| --- | --- | --- |
| our patch vs upstream `v2.0.0` | 52 | 7 |
| our patch vs upstream `v2.1.0-rc0` | 62 | **1,127** |

Against the tag we pin, the overlay is a nearly clean addition. Against the tag
we would bump to, copying the patch file forward would **delete 1,127 lines of
upstream locale strings** and rewind that file to a June-era snapshot. Every
other copied file under `deploy/frontend-patches/files/` (`chat-box.tsx`,
`input-box.tsx`, `hooks.ts`, `types.ts`, `env.js`, the sanitizer module) has the
same shape of risk.

**c. The memory adapter is written against a schema that 2.1.0 removes.**
`deploy/deer-flow-pacgate/config.yaml` currently sets:

```yaml
memory:
  storage_class: pacgate_deerflow_adapter.storage.PacgateMemoryStorage
```

Upstream 2.1.0 breaking changes move the memory system to a pluggable manager:

- `memory.manager_class` selects a backend; default `deermem`.
- Private settings move from the top level of `memory:` into
  `memory.backend_config`.
- `storage_class` no longer exists as a top-level key in the documented schema.
- The old base path `deerflow.agents.memory.storage.FileMemoryStorage` is gone;
  the class moved to
  `deerflow.agents.memory.backends.deermem.deermem.core.storage.FileMemoryStorage`.
- `MemoryStorage` subclasses must now accept `config` in `__init__` (was
  no-argument), and `storage_path` changes meaning from a file path to a root
  directory.

Our `PacgateMemoryStorage.__init__` is currently no-argument
(`pacgate-adapters/python/pacgate_deerflow_adapter/storage.py:34`). Under 2.1.0
the documented contract is `manager_class` plus `backend_config`, and the module
our adapter subclasses has moved. This is the single highest-risk item in the
bump, and it is not mechanical.

Worth noting: `deploy/DEPLOYMENT-GUIDE.md` already documents the 2.1.0 shape
(`FROM ...:2.1.0`, `manager_class: deermem`, `backend_config.storage_class`) as
though it were current. That example does not match what we ship. Verified
against GHCR, the tag it names does not even exist:

```
MISS 2.1.0     MISS v2.1.0     MISS v2.2.0     MISS v2.1.0-rc1
OK   v2.0.0    OK   v2.1.0-rc0
```

So `DEPLOYMENT-GUIDE.md` line 71 (`FROM ...:2.1.0`) and line 441
(`FROM ...:2.2.0`) are broken copy-paste examples, not just out of date.

## 3. What we are currently frozen out of

These are upstream fixes that landed after our pin and cannot reach an AIPC
without the bump:

**Security (the reason this is not purely cosmetic).** The 2.1.0 Security
section describes symlink attacks in the uploads directory, which is
sandbox-writable by design:

- `#5611` - document conversion re-opened the upload by name, so a sandbox that
  swapped the name for a symlink had a host file converted into the thread.
- `#5578` - `DeerFlowClient.upload_files` wrote through a symlink and
  overwrote a host file while reporting success.
- `#5547` - `DELETE /api/threads/{id}/uploads/{filename}` followed a symlink and
  deleted a different file, reporting the requested name as deleted.

We are partially covered on the write and delete paths. Our mounted
`deer-flow-uploads.py` imports `open_upload_file_no_symlink` and uses it for
streamed writes, and our delete path routes through `delete_file_safe`. But
`delete_file_safe` in the `v2.0.0` manager does `(base_dir / filename).resolve()`
and then `unlink()`. It resolves first, then unlinks the target, so a symlink at
the upload name still resolves to the file it points at. Upstream's 2.1.0 fix
makes symlinks return 404 instead. That specific hole is still ours.

The exposure is bounded: it requires a sandbox process that can write into the
thread's uploads directory, and the delete route is authenticated per thread. It
is a hardening gap, not an open door to an unauthenticated attacker. It should
still be fixed deliberately rather than by drift.

**Product capability.** 2.1.0 adds a scheduler (`interval` cadence plus
`preview-cron`), personal access tokens for programmatic API access with scoped
default-deny route policy, richer scheduled-task run history with server-side
status filtering, memory backends selected by `manager_class` including an
official OpenViking adapter, skill sandboxing changes, and a large set of
frontend and observability work. For a legal-research product, PAT-based API
access and the scheduler are the two with real client relevance.

## 4. Why it is not urgent this week

- Our pinned release is internally consistent: backend digest and frontend tag
  both `v2.0.0`. Nothing is broken by being one minor behind.
- The full release pipeline works end to end. 0.1.17 is published, all five
  images are anonymous-pullable, and the AIPC install and update path is proven.
- Upstream `v2.1.0` is at `rc0`. Adopting a release candidate as the base for a
  client-deployed legal system trades a known state for a moving one.
- We are on the last release of a completed milestone, not on an unmaintained
  branch. `v2.0.0` is the 2.0.0 GA tag, not an intermediate snapshot.
- The repo already documents this cadence rather than an immediate-upgrade rule:
  `deploy/PLANS.md` line 202 sets "deer-flow wrapper (adapter, upstream bumps)"
  to **Quarterly**, and line 146 to "Quarterly or when deer-flow ships value".
  Being one minor behind at this point in the cycle is on plan, not a lapse.

**How soon is "when GA ships"?** Measured, not guessed:

- The 2.1.0 milestone is **95% complete with no due date** published, last
  updated roughly five hours before this assessment was written. There is no
  maintainer date to plan against.
- The post-RC phase is active and fix-dominated: 67 commits in 4 days after
  `v2.1.0-rc0` (48 `fix`, 15 `feat`, one each `chore`/`docs`/`refactor`/`test`),
  dated 2026-09-17 to 2026-09-21. The release is converging, but it has not
  stopped moving. Open milestone items still include `P1` work.
- The previous release is a usable precedent: `v2.0.0-rc0` (2026-06-14) to GA
  (2026-06-25) was **11 days**. Applied to 2.1.0, that puts GA in late
  September 2026, roughly one to two weeks out.
- That precedent is directionally useful but not a commitment. The 2.0.0 tag
  ancestry does not line up cleanly, so "11 days" is an order-of-magnitude
  signal, not a schedule.

**So "as soon as GA lands" has a cost worth naming.** At roughly two weeks out,
holding the whole patch rebase for GA means the work either begins within a
fortnight or slips to the next quarterly window. And GA can slip: a milestone at
95% with no due date and open `P1` items frequently takes longer than the prior
cycle. The preparation in step 1 below can and should happen now, so that the
elapsed time between "GA tagged" and "0.1.x shipped" is dominated by
verification rather than by patch archaeology.

## 5. Recommendation

**Do not bump right now. Prepare the bump, and start it as soon as 2.1.0 GA
lands.** Waiting for GA is a deliberate gate on release quality, not a reason to
delay the preparation.

The distinction matters: "no" to an unplanned upgrade today, "yes" to an owned
upgrade track that starts now. Concretely:

**This week, cheap and additive (no image change):**

1. Close the delete-symlink gap in `patches/deer-flow-uploads.py` independently
   of the bump, since it is a self-contained hardening fix we can ship on the
   current base.
2. Fix `deploy/DEPLOYMENT-GUIDE.md` so the documented wrapper example matches the
   pinned digest and the `storage_class` schema we actually run, and replace the
   non-existent `2.1.0` / `v2.2.0` tag references with the digest we build on.
3. Record the pin as an explicit decision so it is not rediscovered as drift:
   base digest `sha256:e7c503a8...`, frontend tag `v2.0.0`, both dated
   2026-06-25, with the reason (2.1.0 at rc).

**Start immediately once upstream cuts 2.1.0 GA** (late September 2026 if the
2.0.0 cadence holds; no upstream date is published, so watch for the tag). Run it
as a scoped project:

4. Re-derive all eight mounted patches against the new upstream revision by
   three-way diff of `v2.0.0 -> new base -> our patch`, keeping only our
   intended deltas. Do not copy the `v2.0.0` snapshots forward.
5. Rebase the seventeen frontend overlay files the same way and verify the built
   image carries upstream's locale and component changes rather than rewinding
   them.
6. Migrate the memory adapter to `manager_class` + `backend_config` and accept
   `config` in `__init__`. This is the item most likely to need real design work,
   and it is already a known area: the per-matter lane was fixed on 2026-09-20
   and has a regression test to protect.
7. Re-run the config schema diff. The live rendered `deer-flow-config.yaml`
   carries 10 top-level keys against the wrapper default's 6, so any upstream
   key rename lands silently in the rendered file too.
8. Validate against a fresh clone and the full e2e suite, per the standing rule
   for install-path changes. Prove it on a clean machine, not this dev box.

**Sequencing note.** Steps 4 through 8 land as a normal `0.1.x` release: bump the
four version pins, rebuild, republish, and let AIPCs pull it through
`install.ps1 -Update`. There is no separate mechanism, which is one benefit of
the wrapper architecture. The cost is that this release cannot be shipped
half-done, because a partially rebased patch set produces a container that starts
green and misbehaves.

## 6. Residual risk if we do nothing

- The delete-symlink hardening gap stays open until the bump or an independent
  fix. Small, bounded, but real and documented upstream.
- We keep paying the patch-maintenance cost, and the delta grows: 6,219 changed
  lines in our overwritten paths today, more by the time we act.
- Feature expectations drift. Upstream's own docs and skill ecosystem will
  increasingly assume 2.1.0 shapes, so upstream-integration guidance we read
  will stop matching what we run.
- Nothing breaks on its own. The pinned image is immutable and public, and the
  client stack does not depend on upstream moving.

## 7. Decision needed

1. Confirm the freeze on `v2.0.0` until 2.1.0 GA, versus adopting `v2.1.0-rc0`
   now for earlier feature access. The timing evidence favours the freeze: GA is
   plausibly 1-2 weeks out, and the RC is still receiving fixes at ~17 commits a
   day.
2. Confirm whether the delete-symlink hardening ships standalone on the current
   base or waits for the bump. Recommendation: ship it standalone, because it is
   independent of the bump and the bump's date is not ours to control.
3. Nominate an owner and a trigger for the bump project. Concrete trigger:
   `ghcr.io/bytedance/deer-flow-backend:v2.1.0` resolving to a new digest, or the
   `v2.1.0` tag appearing on `bytedance/deer-flow`. Verified today that
   `v2.1.0` does **not** exist (`v2.1.0-rc0` does), so the trigger is unambiguous
   and checkable - watch for the non-rc tag rather than assuming a date.

---

## Evidence index

| Claim | Source |
| --- | --- |
| Base digest equals `v2.0.0` tag | `docker buildx imagetools inspect` on both refs |
| 3,335 commits to the bump target | `git rev-list --count v2.0.0..v2.1.0-rc0` in `deploy/deer-flow-src` |
| 67 commits after the rc | `git rev-list --count v2.1.0-rc0..origin/main` |
| 11 breaking changes | `CHANGELOG.md` at `origin/main`, lines 14..103 |
| 6,219 insertions / 934 deletions in overridden files | `git diff --shortstat v2.0.0 v2.1.0-rc0 -- <7 backend paths>` |
| Eight mounted patches | `deploy/client-bundle/compose.prod.yaml` |
| Frontend whole-file copy | `.github/workflows/build-ghcr.yml` lines 285..303 |
| Locale overlay: +52/-7 pinned, +62/-1127 on the bump target | `git diff --no-index --numstat` patch file vs both tags |
| Memory schema break | `CHANGELOG.md` 2.1.0 memory bullets; upstream `config.example.yaml` memory block |
| No-arg adapter `__init__` | `pacgate-adapters/python/pacgate_deerflow_adapter/storage.py:34` |
| Delete follows symlink on `v2.0.0` | `git show v2.0.0:backend/packages/harness/deerflow/uploads/manager.py`, `delete_file_safe` |
| Existing doc already shows 2.1.0 | `deploy/DEPLOYMENT-GUIDE.md` section 1.2 |
| Documented tags `2.1.0` / `v2.1.0` / `v2.2.0` do not exist | `docker buildx imagetools inspect` on each, all MISS |
| Documented cadence is quarterly | `deploy/PLANS.md` line 202 ("deer-flow wrapper (adapter, upstream bumps) ... Quarterly") |
| 2.1.0 milestone is 95% complete, no due date | `github.com/bytedance/deer-flow/milestone/2` |
| 67 post-RC commits, 48 of them `fix` | `git log --format=%s v2.1.0-rc0..origin/main`, grouped by type prefix |
| Prior RC-to-GA was 11 days | `v2.0.0-rc0` 2026-06-14 to `v2.0.0` 2026-06-25 (precedent, not a commitment) |
| GA tag absent as of today | `docker buildx imagetools inspect` on `v2.1.0` -> MISS |
