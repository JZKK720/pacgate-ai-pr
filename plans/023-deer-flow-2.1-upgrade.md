# Plan 023 — deer-flow 2.1 upgrade (prepare now, execute at GA)

**Status:** PREP IN PROGRESS. Blocked on upstream `v2.1.0` GA for execution.
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
| Backend: 7 whole-file bind-mounts over upstream modules | **386 lines of our delta** vs **7,153 lines of upstream churn** in those files | 3-way merge per file |
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

Current output against `v2.1.0-rc0`: all seven paths exist, 386 lines of our
delta, 7,153 lines of upstream churn. Exit 0.

The script is proven to fail: a mutated upstream path is caught and exits 1, and
a bad ref throws up front rather than reporting everything missing. Do not
"simplify" the ref precondition away — an earlier version wrapped git in a
PowerShell function, read `$LASTEXITCODE` (129 for every call), and reported all
seven paths missing while claiming the upgrade would break the runtime.

Encoding is checked too. An earlier version read the base blob through a
PowerShell string, which mis-decoded the UTF-8 em-dashes in these files and
inflated the totals to 527 lines. With the blob redirected to a file and
`[Console]::OutputEncoding` pinned, the same measurement gives **386 lines**, and
the two methods now agree. A mis-decode here would have overstated the rebase by
roughly 30%.

### 1.2 Record each patch's INTENT — DONE (below)

A rebase needs the reason, not just the diff. Filled from the upstream base each
patch was built on:

| Patch | Lines | Intent | Classification |
| --- | --- | --- | --- |
| `deer-flow-sync.py` | +76/-2 | **Upstream bug workaround.** Upstream calls `asyncio.run()` per sync tool call, creating a new event loop per MCP tool call; the MCP session pool keys by `(server, scope_key)` + owning loop, so parallel calls on different loops evict each other and cancel the subprocess spawn, hanging the run. Our patch runs every sync coroutine on one shared background loop. | **STILL NEEDED** — verified upstream `v2.1.0` still calls `asyncio.run` per call and has no shared loop |
| `deer-flow-thread-runs.py` | +8/-2 | Default `multitask_strategy` from `reject` to `interrupt`, so a new message during a long run cancels the stale run instead of returning 409. Frontend never sends the field. | likely still needed; re-check the 2.1.0 default |
| `deer-flow-uploads.py` | +17/-2 | Markdown-companion metadata (`markdown_file`/`markdown_path`/`virtual_path`/`artifact_url`) + `original_filename` persistence in the listing; symlink-safe write helper import | partially superseded — 2.1.0 landed its own symlink fixes (#5611/#5578/#5547); re-check before keeping |
| `deer-flow-prompt.py` | +34/-1 | Agent prompt content (pacgate/citation/legal behaviour) | keep, but this is the file that needs the most upstream merge care |
| `deer-flow-worker.py` | +59/-0 | Run-worker behaviour additions | keep; largest upstream churn in the set (2,906 lines) |
| `deer-flow-agent.py` | +80/-3 | Lead-agent factory additions | keep; 1,013 lines upstream churn |
| `deer-flow-artifacts.py` | +64/-38 | Artifact route additions | keep; the 38 deletions need inspection at rebase |
| `langchain-mcp-tools.py` | 579-line file | MCP tool adapter — doubled server-name prefix + tool binding | rebase against the vendored package INSIDE the target image |

### 1.3 Decide the memory adapter contract — DECISION NEEDED

2.1.0 replaces top-level `memory.storage_class` with `memory.manager_class` +
`memory.backend_config`, moves the base class to
`.../backends/deermem/deermem/core/storage.py`, and requires `__init__(config)`.
`PacgateMemoryStorage.__init__` is currently no-arg.

This is the one item that is design work rather than a rebase. It should be
settled **before** GA so the bump is not blocked on it. The per-matter lane was
fixed on 2026-09-20 and has a regression test
(`pacgate-adapters/python/tests/test_memory_revision.py`) to protect.

### 1.4 Independent, ship-now items (no bump required)

- **Delete-symlink hardening.** `v2.0.0`'s `delete_file_safe` does
  `(base_dir / filename).resolve()` then `unlink()`, so it follows a symlink;
  2.1.0 makes symlinks 404 (#5547). Self-contained fix on the current base.
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

## 3. Out of scope

- **Adopting `v2.1.0-rc0` now.** The RC is still receiving ~17 commits/day (48 of
  67 post-RC commits are `fix`) with open P1 items; a client-deployed legal system
  trades a known state for a moving one.
- **Forking deer-flow.** The wrapper architecture is deliberate; the upgrade cost
  is real but bounded, and forking trades it for an unbounded merge debt.

## 4. Definition of done

- Audit exit 0 at the GA tag, and the verification diff shows only our delta.
- Memory adapter migrated and its regression test green with the matter lane on.
- Five pins bumped to one version; all images anonymous-pullable.
- Runtime proof that the patch set is live, not silently bypassed.
- Fresh-clone validation green.
- Assessment doc updated: pin moved, residual risks closed or re-listed.
