# Plan 023 — deer-flow 2.1 upgrade (prepare now, execute at GA)

**Status:** TRIGGER FIRED - `v2.1.0` GA released (`f6e747be`, verified on
2026-10-07). §1.5 audit executed at the GA tag: **exit 0** - every bind-mount
path still exists, 718-line delta vs 7,829 upstream churn (re-measured
2026-10-27 from the tag objects), encodings 8/8 OK. The §2 rebase execution is
still the remaining work item, **but §2.5 now records a blocker that changes its
size**: the memory adapter does not satisfy the 2.1.0 contract (no `search()`,
`storage_class` superseded by `manager_class`) and `worker.py` needs a
rewrite-scale merge. Recommendation on 2026-10-27: **stay on v2.0.0 for the next
release** and revisit only on a concrete trigger (2.0.x CVE, a client defect only
2.1.0 fixes, or upstream 2.0.x EOL).
**Trigger:** the non-rc `v2.1.0` tag appears on `bytedance/deer-flow`, or
`ghcr.io/bytedance/deer-flow-backend:v2.1.0` resolves to a new digest. Verified
absent as of 2026-09-21 (only `v2.1.0-rc0` exists), so the trigger is unambiguous.
**Evidence:** `deploy/DEER-FLOW-UPSTREAM-DRIFT-ASSESSMENT-2026-09-21.md`
**Tooling:** `scripts/audit-deer-flow-patches.ps1`

## Why this plan exists

We pin upstream `v2.0.0` (backend digest `sha256:e7c503a8...`, frontend tag
`v2.0.0`, both 2026-06-25). Upstream is at `v2.1.0-rc0` (2026-09-17, 3,335
commits ahead, 11 breaking changes). The bump cannot be done casually because our
integration overrides upstream code in two ways:

| Mechanism | Scale | Rebase shape |
| --- | --- | --- |
| Backend: 8 whole-file bind-mounts over upstream modules | **718 lines of our delta** vs **7,829 lines of upstream churn** in those files (re-measured 2026-10-27 at v2.1.0 GA, including the loop-detection patch) | 3-way merge per file, **17 conflict regions** — see §2.5 |
| Backend: 1 bind-mount over a vendored package in the image venv | 579-line file | rebase inside the image |
| Frontend: 17 files copied over cloned source | locale file alone would delete 1,127 upstream lines | re-derive each overlay |

The sizing matters: our work is small and reviewable, the hazard is entirely
**not trampling upstream**. A snapshot copied forward builds green and silently
reverts upstream code.

## 1. Prep that can happen NOW (no GA needed)

### 1.1 Inventory the patch stack — DONE

`scripts/audit-deer-flow-patches.ps1` measures, per patch:

- our intended delta (patch vs the base revision it was built from)
- upstream churn in that upstream file between base and target
- **whether the patched upstream path still exists at the target** (the
  rebase-break signal; a bind-mount onto a missing path means our code is
  silently absent at runtime)

Current output against `v2.1.0` (re-run 2026-10-27 at GA): all eight paths exist,
718 lines of our delta, 7,829 lines of upstream churn. Exit 0. See §2.5 for the
conflict-region measurement and the memory-adapter blocker that the exit-0 audit
does NOT detect (it checks path existence and encoding, not API compatibility).

  NOTE (2026-09-22): this was 386 until commit `48f5a3b` added the delete-symlink
  guard (+52). The number is not a fixed property of the stack - it MOVES with any
  patch edit, and every edit must be reflected in the table in 1.2 because 2.1
  uses that table as a merge-correctness oracle. Re-run the audit and update the
  table after ANY change to a patch file.

The script is proven to fail: a mutated upstream path is caught and exits 1, and
a bad ref throws up front rather than reporting everything missing. Do not
"simplify" the ref precondition away — an earlier version wrapped git in a
PowerShell function, read `$LASTEXITCODE` (129 for every call), and reported all
seven paths missing while claiming the upgrade would break the runtime.

Encoding is checked too. An earlier version read the base blob through a
PowerShell string, which mis-decoded the UTF-8 em-dashes in these files and
inflated the totals to 527 lines. With the blob redirected to a file and
`[Console]::OutputEncoding` pinned, the same measurement gave **438 lines** at
the time of that check (seven patches then; **718** now that loop-detection is
in the set - re-measured 2026-10-27), and the two methods agree. A mis-decode
here would have overstated the rebase by roughly 30%.

### 1.2 Record each patch's INTENT — DONE (below)

A rebase needs the reason, not just the diff. Filled from the upstream base each
patch was built on:

| Patch | Lines | Intent | Classification |
| --- | --- | --- | --- |
| `deer-flow-sync.py` | +76/-2 | **Upstream bug workaround.** Upstream calls `asyncio.run()` per sync tool call, creating a new event loop per MCP tool call; the MCP session pool keys by `(server, scope_key)` + owning loop, so parallel calls on different loops evict each other and cancel the subprocess spawn, hanging the run. Our patch runs every sync coroutine on one shared background loop. | **STILL NEEDED** — verified upstream `v2.1.0` still calls `asyncio.run` per call and has no shared loop |
| `deer-flow-thread-runs.py` | +8/-2 | Default `multitask_strategy` from `reject` to `interrupt`, so a new message during a long run cancels the stale run instead of returning 409. Frontend never sends the field. | likely still needed; re-check the 2.1.0 default |
| `deer-flow-uploads.py` | +69/-2 | Markdown-companion metadata (`markdown_file`/`markdown_path`/`virtual_path`/`artifact_url`) + `original_filename` persistence in the listing; symlink-safe write helper import | keep — the symlink fixes in our listing/write path are ours; 2.1.0's #5547 does NOT touch `delete_file_safe` (see 1.4). Our delete guard is additive +52/-0 |
| `deer-flow-prompt.py` | +34/-1 | Agent prompt content (pacgate/citation/legal behaviour) | keep, but this is the file that needs the most upstream merge care |
| `deer-flow-worker.py` | +59/-0 | Run-worker behaviour additions | keep; largest upstream churn in the set (2,906 lines) |
| `deer-flow-agent.py` | +80/-3 | Lead-agent factory additions | keep; 1,013 lines upstream churn |
| `deer-flow-artifacts.py` | +64/-38 | Artifact route additions | keep; the 38 deletions need inspection at rebase |
| `deer-flow-loop-detection.py` | +105/-19 | **Upstream fix backport.** Layer 2 of the loop guard kept a monotonic same-tool counter (`_tool_freq[thread_id][name] += 1`) cleared only by `reset()`, which the gateway never calls, so every `bash` call for a thread's whole life summed against one ceiling of 50. A productive document run (92 calls / 71 bash / 55 distinct commands, thread `6cc8dfae`) was force-stopped mid-work on 2026-10-27. Backports `e492bb1c` (#4072 windowed deque + Counter) and `4746a257` (#4295 evict/reset cleanup) onto the pinned v2.0.0 file. | **DELETE AT THE 2.1.0 REBASE, but NOT because of #4072.** v2.1.0 does **not** contain `e492bb1c` (measured 2026-10-27: it postdates the 2026-09-24 tag). It ships an equivalent-or-stronger fix of its own: `type _RunScopeKey = tuple[str, str | None]` keys `_tool_name_history` / `_tool_name_counter` on **(thread_id, run_id)**, so the counts are per **run** - no sliding window needed. Monotonic-counter occurrences at v2.1.0: **0**. Remove the mount **and the file**; do not carry the snapshot forward |

> **Config survives the rebase - do NOT delete this block.** Measured against the
> real v2.1.0 source on 2026-10-27: `ToolFreqOverride`, `tool_freq_warn`,
> `tool_freq_hard_limit` and `tool_freq_overrides` all exist unchanged in
> `deerflow/config/loop_detection_config.py`. Our `bash: {warn: 100, hard_limit: 150}`
> override becomes *more* correct at 2.1.0, because a per-run counter is exactly
> the shape the measurement found: the worst single run packs 74 bash calls, and
> a thread's lifetime total was never the thing being measured. `window_size`
> remains a valid key but is inert for Layer 2 at 2.1.0 (the run scope replaces
> the window), so keep it only for Layer 1.


> Layer 2 sizing is a config concern, not part of this patch:
> `loop_detection.tool_freq_hard_limit` in `deer-flow-config.yaml` is set to 75
> globally with a `bash` override of 100/150, because the middleware auto-sizes
> its window to `max(window_size, hard_limit, overrides)` — at the shipped ceiling
> of 50 the window is also 50, and the worst measured run already packs 48 bash
> calls into 50 (2 calls of headroom). `scripts/test-loop-detection-window.ps1`
> gates both halves.
>
> **A/B proof (2026-10-27).** Replaying the 92 tool-call batches of the thread
> that was force-stopped, through the two implementations side by side:
>
> | middleware | result |
> | --- | --- |
> | published 0.2.6, shipped defaults | **FORCED STOP at batch 66/92** — `Tool bash called 50 times` |
> | this patch + this config | completes all 92 batches, no stop |
>
> Live confirmation on an isolated copy of the stack: a real agent turn issued
> 56 bash calls in one message and finished clean, with zero `FORCED STOP`
> messages in the final state. The same replay still stops a genuine loop at
> Layer 1 (identical call sets, 5) and a runaway `read_file` swarm at the global
> ceiling (75). |
| `langchain-mcp-tools.py` | 579-line file | MCP tool adapter — doubled server-name prefix + tool binding | rebase against the vendored package INSIDE the target image |

### 1.3 Memory adapter contract — DECIDED (2026-09-22)

**Decision: migrate `PacgateMemoryStorage` to the 2.1.0 `MemoryManager` contract.
Do not adopt the official OpenViking backend.** Reasons and evidence below; the
earlier framing of this section ("moves the base class, requires `__init__(config)`")
was reading the upstream doc's paraphrase and understated the change.

**What breaks is bigger than an `__init__` signature.** 2.1.0 DELETES
`deerflow/agents/memory/storage.py` and replaces it with
`deerflow/agents/memory/manager.py` + `backends/<name>/`. Our
`from deerflow.agents.memory.storage import MemoryStorage` fails at import, so
this is a hard break, not a deprecation. Our `load`/`reload`/`save` methods go
with it: `MemoryStorage` no longer exists at all.

**The 2.1.0 contract, read from the code rather than the docs:**

- `MemoryManager` is a **Pydantic `BaseModel`** whose metaclass derives from
  `ABCMeta`, so unimplemented `@abstractmethod`s raise `TypeError` at
  instantiation. Three tier-1 methods are abstract and a backend must implement
  them or it will not construct:
  - `add(thread_id, messages, *, agent_name, user_id, trace_id) -> None`
  - `get_context(user_id, ...)` — returns the text injected into the prompt
  - `from_config(cls, backend_config, *, mode, **host_hooks) -> MemoryManager`
- The data flow is therefore different, not renamed: `add` is fed raw
  conversation **messages** and is described as debounced/asynchronous, while
  `get_context` returns injectable text. Our adapter is a `load()`/`save()`
  document store. This mapping is the actual design work.
- Resolution accepts **either** a registered short name **or a dotted import
  path** (`pkg.mod:Cls` or `pkg.mod.Cls`) — see `_resolve_manager_class`. That is
  why this migration is additive in the image: **no backend folder has to be
  baked into deer-flow**, the adapter stays pip-installed and
  `manager_class: pacgate_deerflow_adapter.storage:PacgateMemoryManager` reaches
  it. It also **fails loud** rather than falling back to DeerMem, deliberately,
  because silently routing persistent memory to the wrong store is worse than
  refusing to start. Expect a hard startup error on a bad value, not a warning.
- `from_config` is called INSTEAD of the constructor, so the no-arg
  `__init__` question is moot: the entry point becomes a classmethod taking
  `backend_config`.

**Why not the official OpenViking backend.** 2.1.0 ships
`backends/openviking/` (verified present in `v2.1.0-rc0`), and we already run
OpenViking, so adopting it is tempting and would delete a whole adapter. Rejected
because it relocates firm memory out of `pacgate-api`. The per-matter lane,
`PACGATE_MATTER_ID`, the revision/`If-Match` conflict semantics that
`MatterMemoryConflict` exists to surface, and the matter-scoped isolation the
product sells all live on our side. Moving the store would make upstream a
dependency of the client's matter-isolation guarantee. Revisit only as an
explicit product decision, not as an upgrade convenience.

**Carry-forward risk to check at rebase.** Our adapter sits at the same import
path our *patch* does. `deer-flow-sync.py` overrides
`deerflow/tools/sync.py` and reaches memory through the package that 2.1.0
restructures. The bind-mount path itself (`.../deerflow/tools/sync.py`) survives,
which is why `audit-deer-flow-patches.ps1` reports exit 0 — it checks bind-mount
targets, not the imports inside them. Re-checking this is a §2.5 item, since the
audit cannot see it.

**Sequencing.** The migration itself must wait for GA: writing it against `rc0`
would be re-derived when rc0 moves, and rc0 is still taking ~17 commits/day. What
is settled now is the direction and the entry-point shape. The per-matter lane
regression test (`pacgate-adapters/python/tests/test_memory_revision.py`) is the
guard to keep green through the migration.

### 1.4 Independent, ship-now items (no bump required)

**Delivery mechanism for everything in this section — NO IMAGE REBUILD NEEDED
(verified 2026-09-22).** This is worth stating because it decides the sequencing
at the end of the project. All eight patches are bind-mounted by
`compose.prod.yaml` at repo-relative paths (`./patches/deer-flow-uploads.py`), so
a patch fix travels with the REPO, not the image. `install.ps1` step 7c exists
precisely for this and says so:

    # 7c. Restart services whose CODE is bind-mounted.
    # A changed bind-mounted FILE does not alter compose config, so `up -d` does NOT
    # ... Without this restart, patched code (patches/*.py) ...
    docker compose -f compose.prod.yaml restart deer-flow

Consequence for sequencing: a patch-only fix reaches an AIPC through `git pull`
plus that restart. It does NOT need a GHCR rebuild and does NOT need to wait for
2.1.0 GA. So the cheap fixes can be delivered either on their own, or folded into
the single rebuild the 2.1 bump requires — the operator's choice, not a forced
ordering. What DOES need the rebuild is anything baked into an image (the
frontend overlays copied in `build-ghcr.yml`) or any `FROM`/pin change.


- **Delete-symlink hardening — DONE (2026-09-22).** Shipped on the current base in
  `48f5a3b` with `scripts/test-upload-symlink-guard.ps1`. Two corrections to the
  text that was here:

  1. The original claimed the hole covers a host file — "so a symlink at the
     upload name still resolves to the file it points at". Probed against the real
     function, that case is ALREADY refused: the traversal check compares the
     resolved path against the base and raises `PathTraversalError`. Not an
     exposure. What actually remained is narrower: a symlink pointing at a
     **sibling file inside the same uploads dir** resolves within the base, passes
     validation, and IS deleted under the link's name. Intra-thread misreporting,
     not a host-file escape.

  2. "2.1.0 makes symlinks 404 (#5547)" is **not** true of the code. rc0's
     `delete_file_safe` and `validate_path_traversal` are byte-identical to
     `v2.0.0` (verified by diffing the extracted bodies: "no differences"), and
     rc0's new `lstat`/`S_ISREG` guard sits in `validate_upload_destination`
     (upload destinations) and `_make_file_sandbox_writable`, neither of which runs
     on the delete path. So this guard is OURS to carry forward BY HAND at the
     rebase. Do not assume the rebase covers it; re-run the gate and keep it.
- **`deploy/DEPLOYMENT-GUIDE.md`.** Sections 1.2 and line 441 reference
  `FROM ...:2.1.0` and `:2.2.0`; neither tag exists on GHCR (verified MISS). The
  example also shows the 2.1.0 memory schema we do not run. Plan 004 claimed this
  doc was fixed, so this is a regression — worth a guard, not just an edit.

### 1.5 Re-run the audit at GA

The audit takes seconds and is the first thing to run when the tag lands:

```powershell
pwsh -File scripts/audit-deer-flow-patches.ps1 -BaseRef v2.0.0 -TargetRef v2.1.0
```

## 2. Execution at GA

### 2.1 3-way merge each backend patch (do NOT copy snapshots forward)

**Normalise line endings first — this is not optional.** Our patch files are CRLF
throughout (e.g. `sync.py` 166 CRLF / 0 bare-LF) while the upstream blobs are LF.
`git merge-file` compares lines literally, so feeding it CRLF-ours against LF-base
makes *every* line differ and it emits a whole-file conflict (verified: 3 conflict
markers spanning the entire 2,231-line file, with our change buried inside). With
all three inputs normalised to LF the same merge yields **one** local conflict
block, located exactly at our delta. This is the difference between a 30-second
resolve and an unusable merge.

```powershell
$clone = 'deploy/deer-flow-src'
$up    = 'backend/app/gateway/routers/thread_runs.py'   # per patch
$patch = 'deploy/client-bundle/patches/deer-flow-thread-runs.py'
$tmp   = $env:TEMP

# LF-normalise a file in place (write bytes, no string round-trip)
function Normalize-LF($inPath, $outPath) {
    $t = [System.IO.File]::ReadAllText($inPath)
    $t = $t.Replace("`r`n", "`n").Replace("`r", "`n")
    [System.IO.File]::WriteAllText($outPath, $t, (New-Object System.Text.UTF8Encoding($false)))
}

git -C $clone cat-file blob "v2.0.0:$up"     > "$tmp\base.raw"
git -C $clone cat-file blob "v2.1.0:$up"     > "$tmp\new.raw"
Normalize-LF "$tmp\base.raw" "$tmp\base.py"
Normalize-LF "$tmp\new.raw"  "$tmp\new.py"
Normalize-LF $patch          "$tmp\ours.py"

git merge-file -p "$tmp\ours.py" "$tmp\base.py" "$tmp\new.py" > "$tmp\rebased.py"
```

`merge-file` exits with the number of conflicts (0 = clean). Expect roughly one
conflict per patch, sitting on our delta because upstream touched the same region.
Resolve, then **verify** the result carries upstream's changes:

```powershell
git diff --no-index --ignore-cr-at-eol --numstat "$tmp\new.py" "$tmp\rebased.py"
```

This diff must equal **only our intended delta** for that patch (from the table in
§1.2 — e.g. `+8/-2` for `thread-runs`). Two ways it catches a bad merge:

- If the numbers are much larger, the merge is unresolved — unresolved conflict
  markers and both sides of the conflict are still in the file. Observed on a real
  run: an unresolved merge reported `+31/-1` where `+8/-2` was expected, and the
  check flagged it.
- If upstream lines appear as *removed*, our delta clobbered upstream work.

Then normalise the resolved file's line endings to match the rest of the patch set
(CRLF, consistent with the existing files) before writing it back, so the patch
stack does not end up with mixed endings.

Two hard-won details:

- **Read base/new blobs to BYTES, never through a PowerShell string.** Non-ASCII
  (em-dashes) transcodes on the way through `Out-String`/`WriteAllText` and
  inflates every delta with phantom changes — this produced a spurious `+8/-1` of
  em-dash churn on `thread-runs` before it was caught. The audit script pins
  `[Console]::OutputEncoding` and redirects the blob to a file for this reason.
- **Use `--ignore-cr-at-eol` on every verification diff**, or the line-ending
  difference alone will look like a giant edit.

### 2.2 Rebase the vendored patch

`langchain-mcp-tools.py` overrides
`.venv/lib/python3.12/site-packages/langchain_mcp_adapters/tools.py`. Read that
file out of the **target image** and merge the same way. Do not assume the
vendored version moved; check.

### 2.3 Re-derive the frontend overlays

All 17 files are copied with `cp -rv` after a sparse `--branch v2.0.0` clone. Move
the clone branch to the new tag, then re-derive each overlay by 3-way merge.
Highest risk is `src/core/i18n/locales/en-US.ts`: our overlay is +52/-7 against
v2.0.0 but +62/**-1,127** against v2.1.0-rc0, so copying it forward would delete
1,127 upstream locale lines. Also re-check `types.ts`, `hooks.ts`,
`chat-box.tsx`, `input-box.tsx`, `env.js` and the sanitizer module.

### 2.4 Bump the pins

Five surfaces, one unified version:

- `deploy/deer-flow-pacgate/Dockerfile` — `FROM` digest (prefer the digest over a
  tag, matching current practice)
- `.github/workflows/build-ghcr.yml` — the frontend clone `--branch` tag
- `pacgate-ai/Cargo.toml`, `pacgate-ai/Cargo.lock`
- `deploy/client-bundle/compose.prod.yaml`, `compose.bundle.yaml`

Use `scripts/bump-release-version.ps1 -To X.Y.Z -Preview` first; it discovers
versions rather than hardcoding them and refuses to finish if the pins moved but
`Cargo.toml` did not.

### 2.5 Verify — nothing here is optional

1. `scripts/audit-deer-flow-patches.ps1 -TargetRef v2.1.0` → exit 0.
2. **Config schema diff.** The live rendered `deer-flow-config.yaml` carries 10
   top-level keys vs the wrapper default's 6, so an upstream key rename lands
   silently in the rendered file. Diff both against upstream
   `config.example.yaml` and against the 2.1.0 breaking-change list.
3. **Memory lane regression.** Re-run the adapter test with `PACGATE_MATTER_ID`
   active and confirm a run reaches `success` and the memory queue performs a
   real save (200 + fact readable back).
4. **Runtime proof of the patch set.** Start the stack and confirm the mounted
   patches are actually in effect — a bind-mount onto a renamed path fails
   silently. Check the deer-flow log line for MCP tool count and the presence of
   pacgate behaviour (e.g. the interrupt default).
5. **Fresh-clone validation** of any install-path change, per the standing rule.
   This dev box accumulates credentials, pulled models, and rendered gitignored
   configs, so it hides failures a clean AIPC would hit.
6. Full e2e suite.

### 2.5 MEASURED 2026-10-27 — the real cost of the rebase, and the one blocker

Measured against the actual `v2.0.0` and `v2.1.0` source with a byte-exact 3-way
merge (LF-normalised from the git index, per §2.1). These numbers replace the
estimate that used to be here.

**Rebase cost per patch (conflict regions, after LF normalisation):**

| Patch | Conflict regions | Largest block |
| --- | --- | --- |
| `deer-flow-artifacts.py` | 5 | 9,577 chars |
| `deer-flow-uploads.py` | 4 | 4,996 |
| `deer-flow-worker.py` | 4 | **28,024** |
| `deer-flow-prompt.py` | 2 | 1,943 |
| `deer-flow-agent.py` | 1 | 1,644 |
| `deer-flow-thread-runs.py` | 1 | 5,364 |
| `deer-flow-sync.py` | 0 | — clean |
| `deer-flow-loop-detection.py` | 10 | **delete instead** |

**17 conflict regions** across the seven patches we keep. `worker.py` is the
real work: 694 → 3,062 lines upstream, with a 28 KB and a 14 KB conflict block —
that is a rewrite, not a merge, and the runtime/worker is the core of run
execution.

**What does NOT break (verified at `v2.1.0`):** every import our `worker.py`
patch relies on still resolves — `runtime/serialization.py`,
`runtime/stream_bridge/` (now also has `redis.py`),
`runtime/user_context.py`, `tracing/`, `config/app_config.py`. The gateway
entrypoint `app.gateway.app` and the `/api/threads/{id}/runs/wait` route both
survive. The base image `ghcr.io/bytedance/deer-flow-backend:v2.1.0` is
**publicly pullable** (anonymous-token manifest 200), digest
`sha256:68426f84f06f…`. Python floor is unchanged at `>=3.12`.

**THE BLOCKER — our memory adapter does not satisfy the v2.1.0 contract.**

`memory.storage_class` is legacy at 2.1.0. The new shape is
`memory.manager_class` + `memory.backend_config`, and per the 2.1.0 release notes
"a backend without `search()` fails fast in `tool` mode". Measured on our
adapter (`pacgate-adapters/python/pacgate_deerflow_adapter/storage.py`): its
methods are `__init__`, `load`, `reload`, `save`, `write_artifact`,
`read_artifact`, `list_artifacts`. **There is no `search()`.**
`backend_config` is also passed to `__init__(backend_config=...)` by the new
factory, which our constructor (`**kwargs`) would silently swallow.

So the rebase is NOT only the 17 merge conflicts: the memory lane needs a real
adapter change (implement `search()`, accept `backend_config`, migrate the class
to the new path) before the stack can serve memory on 2.1.0. This is the item
that makes the upgrade a project rather than a patch-rebase, and it was not
identified before 2026-10-27.

Two smaller 2.1.0 defaults that would silently change client behaviour:
`database.checkpoint_delta_snapshot_frequency` moved and its default went
1000 → 10 (set it explicitly), and Docker now binds loopback by default
(`BIND_HOST` unset here, so we would need it set to keep the current
externally-reachable behaviour on an AIPC).

## 3. Out of scope

- **Adopting `v2.1.0` (or the RC) now.** For the RC the reason was "still
  receiving ~17 commits/day with open P1 items". For the GA the reason is
  different and stronger, measured 2026-10-27 — see §2.5: the memory adapter does
  not satisfy the new contract (no `search()`, `storage_class` superseded by
  `manager_class`), `worker.py` needs a rewrite-scale merge (28,024-char
  conflict), and nothing in 2.1.0 is a client-facing defect we are currently
  exposed to. A client-deployed legal system should not trade a known state for a
  project unless the project buys something. **Trigger to revisit: a 2.0.x CVE, a
  client-reported defect only 2.1.0 fixes, or an upstream 2.0.x EOL.**
- **Forking deer-flow.** The wrapper architecture is deliberate; the upgrade cost
  is real but bounded, and forking trades it for an unbounded merge debt.

## 4. Definition of done

- Audit exit 0 at the GA tag, and the verification diff shows only our delta.
- Memory adapter migrated and its regression test green with the matter lane on.
- Five pins bumped to one version; all images anonymous-pullable.
- Runtime proof that the patch set is live, not silently bypassed.
- Fresh-clone validation green.
- Assessment doc updated: pin moved, residual risks closed or re-listed.
