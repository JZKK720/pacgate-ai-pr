# AIPC1 Delta Adoption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt upstream the AIPC1 deltas that survive independent verification, reject the ones that do not, and add the gates that make each adoption detectable when it regresses.

**Architecture:** Every fix is a whole-file bind-mounted patch over the pinned `ghcr.io/jzkk720/deer-flow-pacgate:0.2.7` image, plus one static PowerShell gate. No image rebuild is required for any item. Two items are not patches at all: the installer's connector render must merge instead of overwrite, and the frontend thinking default must be corrected in `deploy/frontend-patches/files/` (build-time source, so it only takes effect on the next frontend image build).

**Tech Stack:** Python 3.12 (deer-flow harness inside the container), PowerShell 5.1-compatible gate scripts, Docker Compose (both `compose.prod.yaml` and `compose.bundle.yaml`), Rust workspace for the tier roster.

## Global Constraints

- Patches are **whole-file replacements**, not diffs. Each patch must remain a valid, importable Python module on its own.
- Every patch file must be LF. `.gitattributes` already pins `deploy/client-bundle/patches/** text eol=lf`; do not add a conflicting rule.
- Every patch mount goes in **both** `deploy/client-bundle/compose.prod.yaml` and `deploy/client-bundle/compose.bundle.yaml`. Gate `test-workflow-compose-wiring.ps1` assertion A5 fails on drift.
- Gates run on Windows PowerShell 5.1. No `??`, no `?.`, no ternary, no `ConvertFrom-Json -AsHashtable`, no `.Where({...})` on non-collections.
- A `.ps1` containing CJK literals needs a UTF-8 BOM. A `.ps1` with only ASCII must **not** have one.
- Exit code contract: `0` pass, `1` real assertion failure, `2` CANNOT CHECK (stack down). Exit 2 must never be treated as a failure.
- Do not port: the 60 skills, the live `deer-flow-extensions-config.json`, or any credential file. See Part 4 of the handoff.
- Do not invent or reference a `0.2.8` version. The newest tag is `v0.2.7`.
- Every new gate must be **red-checked**: prove it fails when the defect is reintroduced, then prove it passes once the fix is in.

---

## Verified findings this plan is built on

Measured in this repo and its live container on 2026-10-30. Each line is the evidence a later task depends on; do not re-derive it, and do not "fix" anything not listed here.

| # | Claim in the AIPC1 handoff | Verified here? | Adjustment |
|---|---|---|---|
| V-01 | MCP tool **arguments** never had `/mnt/user-data` resolved | **Yes**, and the root cause is confirmed by experiment | The handoff's own diagnosis is the correct one: the closure is `async def call_with_persistent_session(runtime: Runtime \| None = None, ...)` with **no** `InjectedToolArg`. Measured: `_get_all_injected_args` reports `runtime='runtime'` only when the parameter name is `runtime`, and `ToolNode` injects **by name**. A plain `runtime: X = None` parameter *is* detected by name, but the value passed is whatever the model supplied — which is nothing — so it arrives as `None`. Adding `Annotated[Runtime \| None, InjectedToolArg()]` makes the injected value survive `_parse_input`: measured `fixed -> thread_id=THREAD-42`, `broken -> runtime_none=True`. |
| V-01b | `get_thread_data(runtime)` is the right accessor | **Yes** | It reads `runtime.state["thread_data"]`, which is populated by `ThreadDataMiddleware` at `agents/middlewares/thread_data_middleware.py:114`. Measured present in a compiled graph. |
| V-02 | `read_file` on a binary told the model to use `pandoc` | **No — already fixed upstream** | The live 0.2.7 container returns `"...Use bash with a suitable library instead (pandas/openpyxl for spreadsheets), or view_image for images."` `git log -S pandoc` over `sandbox/tools.py` in deer-flow finds **nothing**; upstream fixed this in `6a4a30fa`. **Do not write this patch.** |
| V-02b | A patch existed but was mounted in neither compose file | n/a | No patch needed, so no mount. Keep the handoff's *lesson* (adopt patch + mount together) as a review rule. |
| V-03 | Recursion default was a hardcoded 100 | **Partially — the clamp is already adopted; the default is not** | `_PACGATE_MAX_RECURSION_LIMIT` already defaults to `4000` and `compose.prod.yaml` already documents it. But `config: dict[str, Any] = {"recursion_limit": 100}` is still the floor, and `app/channels/manager.py:51` (`DEFAULT_RUN_CONFIG`) plus `deerflow/client.py:218` each independently hardcode `100`. The live gate asserts `an API run with no config still gets the 100 default (got '100')` — so the gate currently **pins the defect**. |
| V-03b | A 500 ceiling is stale in the compose comment | **Yes** | `compose.prod.yaml:296-298` still says "default 500". `compose.bundle.yaml` carries no such comment and no env var. |
| V-04 | `officecli set` rejects `body/p[1]` but accepts `/body/p[1]` | **Yes, reproduced live** | `officecli set t.docx body/p[1]` → `No elements matched selector`. `officecli set t.docx /body/p[1]` → `Updated /body/p[1]`. officecli 1.0.149. |
| V-04b | The sandbox blocks the slash form | **Yes, reproduced live** | `validate_local_bash_command_paths` raises `Unsafe absolute paths in command: /body/p[1]` once real `thread_data` is supplied. This also blocks the exact commands the shipped prompt tells the agent to run: `officecli add <f> /body --type paragraph` is **BLOCKED**, `officecli get <f> /body --depth 2` is **BLOCKED**. Only `create` and `validate` are allowed. |
| V-04c | `batch --input` is the workaround | **Yes, verified** | `officecli batch t2.docx --input cmds.json` with `[{"command":"set","path":"/body/p[1]","props":{"text":"..."}}]` → `Batch complete: 1 succeeded`. |
| V-05 | 14 skills declared tools that resolve to nothing | **Not applicable upstream** | Upstream ships **3** seeded skills and **all three deliberately declare no `allowed-tools`**, with the measured reason written in their headers. Gate `test-skill-evolution.ps1` E5 already enforces "no partial `allowed-tools`". **Adopt nothing**; the coverage already exists. |
| V-06 | `audit-model-tags.ps1` failed on `subagents:` false positives | **Confirmed latent, currently green** | The matcher is `^\s*model:\s*(\S+)` over every line, so a `subagents:` block *would* produce a false positive (reproduced with a fixture). It is green today only because `deer-flow-config.yaml` has no `subagents:` block. `audit-model-tags.ps1` is **not** in the `run-all-checks.ps1` gate list. |
| V-07 | `install.ps1` wipes connectors not in the template | **Yes — worse than described** | The render is a plain `.Replace()` of the whole file. It **does** back up and it **does** name removals, but `$knownServers = @('openviking','pacgate','firecrawl')` hardcodes three names, so any of the other 27 would be removed with **no warning at all**. The rendered file is gitignored (`.gitignore:50`). |
| V-08 | `thinking_enabled` defaults ON | **Yes in source, unverifiable in the shipped image** | `deploy/frontend-patches/files/src/core/threads/hooks.ts:974` is `thinking_enabled: context.mode !== "flash"`, and `getResolvedMode()` returns `"pro"` on mount. The compiled image chunk reads `thinking_enabled:"flash"!==d.mode` — same logic. AIPC1 is right that this needs a frontend rebuild; upstream owns that build. |
| V-09 | A local `0.2.8` was invented and reverted | **Confirmed: nothing to do** | No `0.2.8` string exists anywhere in the tracked tree. Recorded only so it is not repeated. |
| Part 4 | `OPERATOR.md` is "tracked and public" | **No — it is not tracked, and history is redacted** | `git ls-files` returns nothing; `git check-ignore` matches `.gitignore:175`. The two historical blobs are 40 B (the pre-redaction note) and 52 B (the post-redaction note) with real values **already replaced by `[REDACTED - see password manager]`**. `check-credential-state.ps1` reports `missing` on all three trees. Treat credential status as **already handled by `plans/013`**; this plan does not touch it. |
| Part 3 | 5 of 6 playbook references are dangling; NDA-review is ungeneratable | **Not applicable upstream** | Upstream ships no `playbooks/` and none of the three seeded skills references one. The dangling references live in AIPC1's 60-skill corpus, which lives in a different repo and must not be ported. **Adopt nothing**; record the decision instead. |
| — | `langchain-mcp-tools.py` is mounted and load-bearing | **Yes, mount proven live** | MD5 of the mounted file equals the repo patch (`54e82d5bd951c93eb7de512d43e95649`). deer-flow imports `langchain_mcp_adapters.client`, which imports `...tools.load_mcp_tools`, so the patch *is* executed. |
| — | That patch renames the tool prefix hyphens→underscores | **Yes, and it silently breaks server attribution for 3 of 3 hyphenated names** | `tool.name.startswith(f"{name}_")` in `get_mcp_tools()` is evaluated against the **renamed** prefix. Measured: `yuandian-law` → `yuandian_law_...` → `attributed=False`. Those tools therefore fall into the `else: wrapped_tools.append(tool)` branch and lose the persistent session **and** the path-rewrite result conversion. Today's template has no hyphenated servers, so it is latent — but AIPC1 runs 13 of them. |

---

## File Structure

**Create**

| Path | Responsibility |
|---|---|
| `deploy/client-bundle/patches/deer-flow-mcp-args.py` | Whole-file replacement of `deerflow/mcp/tools.py` that (a) restores `runtime` injection for MCP tools and (b) rewrites `/mnt/user-data/...` inside string arguments to real host paths. |
| `scripts/test-mcp-argument-paths.ps1` | Gate: proves injection is annotated, the rewrite runs at the call site, both compose files mount the patch, and (live) that a rewritten argument resolves. |
| `scripts/test-connector-template-safety.ps1` | Gate: proves the installer merges rather than overwrites and fails loudly on an unexplained removal. |
| `scripts/test-thinking-default.ps1` | Gate: proves an unset mode does not enable thinking in the frontend patch source. |

**Modify**

| Path | Change |
|---|---|
| `deploy/client-bundle/compose.prod.yaml:397` | Add the MCP-args patch mount; correct the stale "default 500" comment at 296-298. |
| `deploy/client-bundle/compose.bundle.yaml:313` | Add the MCP-args patch mount. |
| `deploy/client-bundle/install.ps1:994-1092` | Replace overwrite-with-`.Replace()` by a merge that preserves unknown servers and fails on loss. |
| `scripts/audit-model-tags.ps1:81-92` | Scope the `model:` scan to the `models:` block. |
| `scripts/run-all-checks.ps1` | Register the three new gates and `audit-model-tags.ps1`. |
| `deploy/client-bundle/patches/deer-flow-run-recursion-cap.py:276` | Default the budget to the ceiling instead of 100. |
| `scripts/test-run-recursion-cap.ps1:175` | Flip the assertion that currently pins the 100 default. |
| `deploy/client-bundle/patches/deer-flow-prompt.py:497-498` | Stop telling the agent to run `/body` selectors on a bash command line; document `batch --input`. |
| `deploy/frontend-patches/files/src/core/threads/hooks.ts:974` | Only enable thinking when a thinking mode is explicitly selected. |
| `deploy/AIPC-UPDATE-GAP-ANALYSIS.md` | One section recording which AIPC1 verdicts were adopted, rejected, and why. |

---

### Task 1: MCP argument path translation (V-01)

**Files:**
- Create: `deploy/client-bundle/patches/deer-flow-mcp-args.py`
- Modify: `deploy/client-bundle/compose.prod.yaml:397`
- Modify: `deploy/client-bundle/compose.bundle.yaml:313`
- Test: `scripts/test-mcp-argument-paths.ps1` (created in Task 2)

**Interfaces:**
- Consumes: `deerflow.sandbox.tools.get_thread_data(runtime)` → `ThreadDataState | None`; `deerflow.sandbox.tools.replace_virtual_path(path, thread_data)` → `str`; `deerflow.tools.types.Runtime`.
- Produces: module-level `_rewrite_virtual_paths_in_args(args: dict[str, Any], thread_data: ThreadDataState | None) -> dict[str, Any]` and `_thread_data_for_mcp(runtime: Runtime | None) -> ThreadDataState | None`, both importable for the gate's assertions.

- [ ] **Step 1: Copy the live module as the patch base**

The patch must be a whole-file copy of what the container is actually running, not a copy of deer-flow `main` (the pinned image predates several upstream changes).

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
docker cp deer-flow:/app/backend/packages/harness/deerflow/mcp/tools.py `
  deploy/client-bundle/patches/deer-flow-mcp-args.py
```

Verify it is 653 lines and contains `async def call_with_persistent_session(`:

```powershell
(Get-Content deploy/client-bundle/patches/deer-flow-mcp-args.py | Measure-Object -Line).Lines
Select-String -Path deploy/client-bundle/patches/deer-flow-mcp-args.py -Pattern 'async def call_with_persistent_session\('
```

Expected: `653` and one match at line 436.

- [ ] **Step 2: Add the imports**

The file already imports `Any`, `Path`, `get_paths`, `VIRTUAL_PATH_PREFIX`, `Runtime`. Two symbols are missing. Add after the `from deerflow.tools.types import Runtime` line (currently line 25):

```python
# Pacgate 2026-10-30: the two helpers this patch needs. They already exist in
# the image - imported rather than copied so this patch cannot drift from them.
from deerflow.sandbox.tools import get_thread_data, replace_virtual_path
from langchain_core.tools.base import InjectedToolArg
```

`Annotated` must also be imported. The file's `from typing import Any` (line 10) becomes:

```python
from typing import Annotated, Any
```

- [ ] **Step 3: Add the argument rewriter above `_make_session_pool_tool`**

Insert immediately before the `def _make_session_pool_tool(` line. `_ARG_PATH_MAX_DEPTH` bounds recursion so a hostile MCP schema cannot make the walk expensive.

```python
# Pacgate 2026-10-30: MCP tool ARGUMENTS were never path-translated.
#
# WHY: `sandbox/tools.py` rewrites the bash COMMAND string via
# `replace_virtual_paths_in_command`, and `read_file`/`write_file` rewrite their
# `path` argument. MCP tools had no equivalent, so this was reachable from a live
# run:
#
#   officecli_officecli({"command": "create /mnt/user-data/outputs/x.docx"})
#     -> ToolException: Could not find a part of the path
#
# `/mnt/user-data/...` is a VIRTUAL path. It is not a mount inside this container;
# the real directory is `{data}/deer-flow/users/<user>/threads/<thread>/user-data/
# outputs`. officecli receives the virtual string, `open()` fails, and the model
# concludes the tool is broken and falls back to `pandoc` - which produces a docx
# that fails `officecli validate`.
#
# Verified end to end in the live 0.2.7 container: with the rewrite applied,
# `officecli create <host outputs path>/probe.docx` -> "Created ...",
# `officecli validate` -> "Validation passed: no errors found".
#
# SCOPE - deliberately narrow, because a blind string rewrite inside arbitrary
# arguments is how a prompt injection becomes a filesystem write:
#   * only str values are considered, and only when they CONTAIN the virtual
#     prefix. A value that does not mention it is passed through untouched.
#   * `replace_virtual_path` only maps the three known roots
#     (workspace/uploads/outputs) plus their common parent. Any other prefix is
#     returned unchanged, so `..` cannot be introduced by this code.
#   * dicts and lists are walked to a bounded depth; everything else is left alone.
_ARG_PATH_MAX_DEPTH = 8


def _rewrite_virtual_paths_in_args(
    args: dict[str, Any],
    thread_data: Any,
    *,
    _depth: int = 0,
) -> dict[str, Any]:
    """Return *args* with virtual ``/mnt/user-data`` paths mapped to host paths.

    A no-op when *thread_data* is falsy, so a caller with no thread context keeps
    exactly the previous behaviour rather than failing.
    """
    if not thread_data or not isinstance(args, dict):
        return args
    if _depth >= _ARG_PATH_MAX_DEPTH:
        return args

    rewritten: dict[str, Any] = {}
    changed = False
    for key, value in args.items():
        new_value = _rewrite_virtual_paths_in_value(value, thread_data, _depth=_depth)
        if new_value is not value:
            changed = True
        rewritten[key] = new_value
    return rewritten if changed else args


def _rewrite_virtual_paths_in_value(value: Any, thread_data: Any, *, _depth: int) -> Any:
    """Recursive helper for :func:`_rewrite_virtual_paths_in_args`."""
    if _depth >= _ARG_PATH_MAX_DEPTH:
        return value
    if isinstance(value, str):
        if VIRTUAL_PATH_PREFIX not in value:
            return value
        # replace_virtual_path is segment-boundary aware and longest-prefix-first,
        # so it rewrites every occurrence-safe token without inventing paths.
        new_value = replace_virtual_path(value, thread_data)
        if new_value != value:
            logger.info("MCP argument path rewrite applied")
        return new_value
    if isinstance(value, dict):
        return _rewrite_virtual_paths_in_args(value, thread_data, _depth=_depth + 1)
    if isinstance(value, (list, tuple)):
        items = [_rewrite_virtual_paths_in_value(item, thread_data, _depth=_depth + 1) for item in value]
        if isinstance(value, tuple):
            items = tuple(items)
        return items if any(a is not b for a, b in zip(items, value)) else value
    return value


def _thread_data_for_mcp(runtime: Runtime | None) -> Any:
    """Best-effort thread data for an MCP tool call.

    Preferred source is the injected ``runtime.state["thread_data"]``, which
    ``ThreadDataMiddleware`` writes. When this tool is invoked outside a graph
    (a direct unit call, or an older LangGraph that does not inject), fall back to
    deriving the same three directories from the thread id - the identical
    derivation ``ThreadDataMiddleware`` uses - so the rewrite still works.
    """
    thread_data = get_thread_data(runtime)
    if thread_data:
        return thread_data

    thread_id = _extract_thread_id(runtime)
    if not thread_id or thread_id == "default":
        return None

    user_id = resolve_runtime_user_id(runtime)
    try:
        paths = get_paths()
        return {
            "workspace_path": str(paths.sandbox_work_dir(thread_id, user_id=user_id)),
            "uploads_path": str(paths.sandbox_uploads_dir(thread_id, user_id=user_id)),
            "outputs_path": str(paths.sandbox_outputs_dir(thread_id, user_id=user_id)),
        }
    except Exception as exc:  # noqa: BLE001 - a failed derivation must not break the call
        logger.warning("MCP argument path rewrite skipped: could not derive thread dirs: %s", exc)
        return None
```

- [ ] **Step 4: Mark the `runtime` parameter as injected**

This is the actual defect. Change the closure signature at line 436 from:

```python
    async def call_with_persistent_session(
        runtime: Runtime | None = None,
        **arguments: Any,
    ) -> Any:
```

to:

```python
    async def call_with_persistent_session(
        # Pacgate 2026-10-30: WITHOUT InjectedToolArg the model's (empty) tool
        # arguments are the only source for this parameter, so the injected
        # ToolRuntime never reaches the function and `runtime` is None.
        #
        # This is not a theory. Measured in the live 0.2.7 container against a
        # real ToolNode with an MCP-shaped args schema:
        #     plain `runtime: Runtime | None = None` -> runtime_none=True
        #     Annotated[Runtime | None, InjectedToolArg()] -> thread_id=THREAD-42
        # LangGraph discovers injection by parameter NAME (`runtime`) and then
        # needs InjectedToolArg for `StructuredTool._parse_input` to keep the
        # value instead of dropping it as a non-schema key.
        runtime: Annotated[Runtime | None, InjectedToolArg()] = None,
        **arguments: Any,
    ) -> Any:
```

- [ ] **Step 5: Rewrite the arguments at both call sites**

Both the interceptor path and the direct path pass `arguments` straight through. Add one local rewrite *before* the branch, so both paths use it. Insert directly after the `session = await pool.get_session(...)` line:

```python
        # Pacgate 2026-10-30: map virtual /mnt/user-data paths in the ARGUMENTS to
        # the real per-thread directories. Done once here so the interceptor path
        # and the direct path cannot diverge. A no-op when thread data is absent.
        arguments = _rewrite_virtual_paths_in_args(arguments, _thread_data_for_mcp(runtime))
```

**Do not touch the two call sites.** The statement above rebinds the local name
`arguments`, so both downstream uses already carry the rewritten dict:

- line ~506: `args=arguments,` inside the `MCPToolCallRequest(...)` construction
- line ~512: `call_tool_result = await session.call_tool(original_name, arguments)`

Confirm the rebind sits **above** both by reading them back:

```powershell
docker cp deploy/client-bundle/patches/deer-flow-mcp-args.py deer-flow:/tmp/mcp_args_probe.py
docker exec deer-flow sh -c "grep -n '_rewrite_virtual_paths_in_args(arguments\|args=arguments,\|call_tool(original_name, arguments)\|if tool_interceptors:' /tmp/mcp_args_probe.py"
```

Expected order, ascending: the `_rewrite_virtual_paths_in_args(arguments` line first, then `if tool_interceptors:`, then `args=arguments,`, then `call_tool(original_name, arguments)`. If the rewrite line is **not** the smallest, it was inserted in the wrong place and one branch would skip it.

- [ ] **Step 6: Verify the patch imports and behaves**

```powershell
docker cp deploy/client-bundle/patches/deer-flow-mcp-args.py deer-flow:/tmp/mcp_args_probe.py
docker exec deer-flow sh -c "cd /app/backend && .venv/bin/python -c 'import ast,sys; ast.parse(open(\"/tmp/mcp_args_probe.py\").read()); print(\"AST OK\")'"
```

Then exercise the two helpers directly:

```powershell
docker exec deer-flow sh -c "cd /app/backend && .venv/bin/python -c \"`nimport importlib.util,sys`nspec=importlib.util.spec_from_file_location('m','/tmp/mcp_args_probe.py')`nm=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)`ntd={'workspace_path':'/HOST/w','uploads_path':'/HOST/u','outputs_path':'/HOST/o'}`nprint(m._rewrite_virtual_paths_in_args({'command':'create /mnt/user-data/outputs/x.docx'}, td))`nprint(m._rewrite_virtual_paths_in_args({'note':'no paths here'}, td))`n\""
```

Expected: `{'command': 'create /HOST/o/x.docx'}` and `{'note': 'no paths here'}` (identical object, unchanged).

- [ ] **Step 7: Mount the patch in both compose files**

In `deploy/client-bundle/compose.prod.yaml`, insert after line 397 (`- ./deer-flow-skills:/app/backend/.deer-flow/skills/public:ro`):

```yaml
      # Pacgate 2026-10-30: MCP tool ARGUMENTS were never path-translated.
      # `officecli_officecli({"command":"create /mnt/user-data/outputs/x.docx"})`
      # failed with "Could not find a part of the path" because /mnt/user-data is
      # a VIRTUAL path, not a mount. The bash command string and read_file's path
      # were rewritten; MCP arguments were not. The same patch also restores
      # `runtime` injection, without which the rewrite has no thread context.
      - ./patches/deer-flow-mcp-args.py:/app/backend/packages/harness/deerflow/mcp/tools.py:ro
```

Insert the identical block after line 313 in `deploy/client-bundle/compose.bundle.yaml`.

- [ ] **Step 8: Recreate the container and prove the mount is live**

`up -d` alone does not recreate on a mount-only change.

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps deer-flow
docker exec deer-flow sh -c "grep -c '_rewrite_virtual_paths_in_args' /app/backend/packages/harness/deerflow/mcp/tools.py"
docker exec deer-flow sh -c "mount | grep 'mcp/tools.py'"
```

Expected: a non-zero grep count, and a `ro` mount line naming `deer-flow-mcp-args.py`. A `docker cp` would not show up here — only a real bind mount will.

- [ ] **Step 9: Commit**

```powershell
git add deploy/client-bundle/patches/deer-flow-mcp-args.py `
        deploy/client-bundle/compose.prod.yaml `
        deploy/client-bundle/compose.bundle.yaml
git commit -m "fix(deer-flow): translate virtual paths in MCP tool arguments

The bash command string and read_file's path argument were rewritten from
/mnt/user-data/... to the per-thread host directory. MCP tool arguments were
passed verbatim, so officecli received a path that does not exist inside the
container and returned \"Could not find a part of the path\". The model then
fell back to pandoc and shipped a docx that failed officecli validate.

The second half of the defect is why a naive patch no-ops: the tool closure is
an async function whose runtime parameter is not annotated InjectedToolArg, so
StructuredTool._parse_input drops the injected ToolRuntime and the function
always sees None. Measured both ways against a real ToolNode.

Mounts the patch in both compose files; A5 parity would otherwise fail.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 2: Gate for MCP argument paths

**Files:**
- Create: `scripts/test-mcp-argument-paths.ps1`
- Modify: `scripts/run-all-checks.ps1` (register in the `$gates` array near line 669)

**Interfaces:**
- Consumes: `deploy/client-bundle/patches/deer-flow-mcp-args.py`; both compose files.
- Produces: exit 0/1/2 as documented in the header.

- [ ] **Step 1: Write the gate**

Content must be pure ASCII (no BOM needed). Follow the shape of `scripts/test-mcp-tool-surface.ps1` for the `Check` helper and the exit-2 contract.

```powershell
# Guard: MCP tool ARGUMENTS must be path-translated, and the rewrite must have
# the thread context it needs to do that.
#
# WHY THIS EXISTS (measured 2026-10-30 on 0.2.7)
#
#   officecli_officecli({"command":"create /mnt/user-data/outputs/x.docx"})
#     -> ToolException: Could not find a part of the path
#
# `/mnt/user-data` is a VIRTUAL path. Inside the container the real directory is
# `{data}/deer-flow/users/<user>/threads/<thread>/user-data/outputs`. bash
# commands were rewritten by `replace_virtual_paths_in_command` and read_file's
# `path` by `replace_virtual_path`; MCP ARGUMENTS were passed verbatim.
#
# WHAT IS ASSERTED
#   A1  the patch exists and parses (it is a whole-file module, not a diff)
#   A2  the tool closure marks `runtime` with InjectedToolArg - without this the
#       injected ToolRuntime never arrives and the rewrite is a silent no-op
#   A3  the argument rewrite is wired at the call site, before the two branches
#   A4  the rewriter leaves a path-free argument object untouched
#   A5  both compose files mount the patch (patch-mount parity)
#   A6  live: the deployed file is the patch, and the mounted file is the
#       rewrite applied inside the running container
#
# Exit 2 means CANNOT CHECK and must never be read as a failure.
[CmdletBinding()]
param(
    [string]$Container = 'deer-flow'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$patch = 'deploy/client-bundle/patches/deer-flow-mcp-args.py'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$mountTarget = '/app/backend/packages/harness/deerflow/mcp/tools.py'

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== MCP argument path translation ===' -ForegroundColor Cyan

# A1
Check 'A1 the patch exists' (Test-Path $patch) $patch
if (-not (Test-Path $patch)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $patch -Raw

Check 'A1 the patch is a whole file (defines _make_session_pool_tool)' `
      ($src -match '(?m)^def _make_session_pool_tool\(')

# A2 - the defect that made a first patch attempt silently no-op.
Check 'A2 runtime is annotated InjectedToolArg' `
      ($src -match 'runtime:\s*Annotated\[\s*Runtime\s*\|\s*None\s*,\s*InjectedToolArg\(\)\s*\]') `
      'without InjectedToolArg the injected ToolRuntime is dropped by _parse_input'
Check 'A2 InjectedToolArg is imported' ($src -match 'from langchain_core\.tools\.base import InjectedToolArg')

# A3 - the rewrite must run ONCE before the branch, so no path can skip it.
$rewriteAt = $src.IndexOf('_rewrite_virtual_paths_in_args(arguments')
$branchAt  = $src.IndexOf('if tool_interceptors:')
Check 'A3 the argument rewrite is wired' ($rewriteAt -ge 0)
Check 'A3 the rewrite precedes the interceptor branch' `
      ($rewriteAt -ge 0 -and $branchAt -ge 0 -and $rewriteAt -lt $branchAt) `
      "rewriteAt=$rewriteAt branchAt=$branchAt"

# A4 - the rewriter must be a no-op on arguments that name no virtual path.
Check 'A4 the rewriter short-circuits without thread data' `
      ($src -match 'if not thread_data or not isinstance\(args, dict\):\s*\r?\n\s*return args')
Check 'A4 the rewriter is depth-bounded' ($src -match '_ARG_PATH_MAX_DEPTH')
Check 'A4 a path-free string is returned unchanged' `
      ($src -match 'if VIRTUAL_PATH_PREFIX not in value:\s*\r?\n\s*return value')

# A5 - parity. A bundle-only mount leaves the deployment path unfixed.
foreach ($c in $composes) {
    $body = if (Test-Path $c) { Get-Content $c -Raw } else { '' }
    Check "A5 $c mounts the patch over $mountTarget" `
          ($body -match [regex]::Escape("./patches/deer-flow-mcp-args.py:$mountTarget"))
}

# A6 - live. Static checks stay green while the container runs the old module.
$running = $false
try {
    $state = docker inspect -f '{{.State.Health.Status}}' $Container 2>$null
    $running = ($state -eq 'healthy')
} catch { $running = $false }

if (-not $running) {
    Write-Host ''
    Write-Host '  [skip] CANNOT CHECK: deer-flow is not running healthy.' -ForegroundColor Yellow
    $colour = if ($script:failed -gt 0) { 'Red' } else { 'Yellow' }
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed (live checks skipped)" -ForegroundColor $colour
    if ($script:failed -gt 0) { exit 1 } else { exit 2 }
}

$liveCount = (docker exec $Container sh -c "grep -c '_rewrite_virtual_paths_in_args' $mountTarget" 2>$null)
Check 'A6 the running container executes the patch' `
      ($liveCount -and [int]$liveCount -ge 2) `
      "grep count in container: $liveCount"

$mnt = (docker exec $Container sh -c "mount | grep '$mountTarget'" 2>$null)
Check 'A6 the patch is a live read-only bind mount' `
      ($mnt -and $mnt -match 'ro') `
      'a docker cp copy would not appear here; only a real mount will'
Check 'A6 the mount source is the tracked patch' `
      ($mnt -and $mnt -match 'deer-flow-mcp-args\.py')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Red-check the gate**

Prove it fails on each defect. Restore the file after each.

```powershell
# (a) remove the InjectedToolArg annotation
$p = 'deploy/client-bundle/patches/deer-flow-mcp-args.py'
Copy-Item $p "$env:TEMP\mcp_args.bak"
(Get-Content $p -Raw).Replace('runtime: Annotated[Runtime | None, InjectedToolArg()] = None','runtime: Runtime | None = None') |
  Set-Content $p -NoNewline -Encoding utf8
pwsh -NoProfile -File scripts/test-mcp-argument-paths.ps1; "exit=$LASTEXITCODE"
Copy-Item "$env:TEMP\mcp_args.bak" $p
```

Expected: `[FAIL] A2 runtime is annotated InjectedToolArg`, `exit=1`. Then repeat for: removing the `_rewrite_virtual_paths_in_args(arguments` call (`A3`), and removing the mount from `compose.bundle.yaml` only (`A5`).

- [ ] **Step 3: Green-check the gate**

```powershell
pwsh -NoProfile -File scripts/test-mcp-argument-paths.ps1; "exit=$LASTEXITCODE"
```

Expected: every assertion PASS, `exit=0`.

- [ ] **Step 4: Register the gate**

In `scripts/run-all-checks.ps1`, immediately after the `'scripts/test-mcp-tool-surface.ps1'` entry (line 669), add:

```powershell
    # MCP ARGUMENT path translation, registered 2026-10-30. `test-mcp-tool-surface`
    # proves the tools are ADVERTISED; this proves they can accept a path. The
    # measured failure was officecli returning "Could not find a part of the path"
    # for /mnt/user-data/outputs/x.docx, because MCP arguments were the one input
    # the sandbox never translated. Static checks plus a live mount assertion.
    'scripts/test-mcp-argument-paths.ps1'
```

- [ ] **Step 5: Commit**

```powershell
git add scripts/test-mcp-argument-paths.ps1 scripts/run-all-checks.ps1
git commit -m "test(deer-flow): gate MCP argument path translation

Asserts the rewriter is wired before the interceptor branch, that runtime is
annotated InjectedToolArg (the silent no-op), that both compose files mount the
patch, and - live - that the running container is executing the mount.

Red-checked three ways: removing the annotation, removing the call site, and
dropping the bundle mount each fail the gate.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 3: Fix the hyphen attribution break in the mounted adapter patch

**Files:**
- Modify: `deploy/client-bundle/patches/langchain-mcp-tools.py:424-434`
- Modify: `deploy/client-bundle/patches/deer-flow-mcp-args.py` (the `get_mcp_tools` attribution loop it now owns)

**Interfaces:**
- Produces: `deerflow/mcp/tools.py` attributes a tool to its server by comparing against **both** the raw and the underscore-normalized name.

- [ ] **Step 1: Confirm the break is real before changing anything**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
docker exec deer-flow sh -c "sed -n '625,642p' /app/backend/packages/harness/deerflow/mcp/tools.py"
```

You will see the loop compares `tool.name.startswith(f"{name}_")` while the patched adapter emitted `name.replace("-","_")`. Measured: `yuandian-law` → `yuandian_law_x` → `False`.

- [ ] **Step 2: Make the attribution accept the normalized prefix**

In `deploy/client-bundle/patches/deer-flow-mcp-args.py`, find the attribution loop inside `get_mcp_tools()`:

```python
            for name in servers_config:
                if tool.name.startswith(f"{name}_"):
                    tool_server = name
                    break
```

Replace with:

```python
            # Pacgate 2026-10-30: the mounted langchain_mcp_adapters patch renames
            # the tool prefix's hyphens to underscores ("yuandian-law" ->
            # "yuandian_law_<tool>") so models can transcribe the name. This loop
            # still compared against the RAW server key, so every hyphenated
            # server fell through to `else: wrapped_tools.append(tool)` and lost
            # the persistent session AND the result conversion. Measured:
            # "yuandian-law" -> attributed False, "officecli" -> True.
            #
            # Match either spelling, longest name first, so a server called
            # "qcc" cannot claim a tool that belongs to "qcc-company".
            for name in sorted(servers_config, key=len, reverse=True):
                normalized = name.replace("-", "_")
                if tool.name.startswith(f"{normalized}_") or tool.name.startswith(f"{name}_"):
                    tool_server = name
                    break
```

- [ ] **Step 3: Verify against a hyphenated server name**

```powershell
docker cp deploy/client-bundle/patches/deer-flow-mcp-args.py deer-flow:/tmp/attr_probe.py
@'
import importlib.util
spec = importlib.util.spec_from_file_location("m", "/tmp/attr_probe.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
servers = ["yuandian-law", "qcc", "qcc-company", "officecli"]
for tool_name in ["yuandian_law_search", "qcc_company_risk", "qcc_doc", "officecli_create"]:
    hit = None
    for name in sorted(servers, key=len, reverse=True):
        norm = name.replace("-", "_")
        if tool_name.startswith(f"{norm}_") or tool_name.startswith(f"{name}_"):
            hit = name; break
    print(f"{tool_name:22s} -> {hit}")
'@ | Out-File -Encoding utf8 "$env:TEMP\attr.py"
docker cp "$env:TEMP\attr.py" deer-flow:/tmp/attr.py
docker exec deer-flow sh -c "cd /app/backend && .venv/bin/python /tmp/attr.py"
```

Expected: `yuandian_law_search -> yuandian-law`, `qcc_company_risk -> qcc-company` (not `qcc`), `qcc_doc -> qcc`, `officecli_create -> officecli`.

- [ ] **Step 4: Commit**

```powershell
git add deploy/client-bundle/patches/deer-flow-mcp-args.py
git commit -m "fix(deer-flow): attribute hyphenated MCP servers to their tools

The mounted adapter patch normalizes hyphens to underscores in the tool
prefix, but get_mcp_tools() still compared against the raw server key. Every
hyphenated server therefore fell through to the unwrapped branch, losing its
persistent session and the result path conversion. Latent today (the shipped
template has no hyphenated servers); live on any machine that enables the
yuandian/pkulaw/qcc connectors.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 4: Recursion default must equal the ceiling (V-03)

**Files:**
- Modify: `deploy/client-bundle/patches/deer-flow-run-recursion-cap.py:276`
- Modify: `deploy/client-bundle/compose.prod.yaml:296-298`
- Modify: `scripts/test-run-recursion-cap.ps1:175`

**Interfaces:**
- Produces: `build_run_config()` with no caller config returns `recursion_limit == _PACGATE_MAX_RECURSION_LIMIT`.

- [ ] **Step 1: Flip the assertion first, so the gate is red for the right reason**

In `scripts/test-run-recursion-cap.ps1`, line 175 currently reads:

```powershell
Assert-That ($none -eq '100') "an API run with no config still gets the 100 default (got '$none')"
```

Replace with:

```powershell
# Pacgate 2026-10-30: this assertion used to PIN the defect. The comment above it
# called 100 "the documented server default" and treated a run that died at 100
# as correct behaviour. It is not: 100 super-steps is ~10 model calls, because
# nine middleware after_model/before_model hooks are each their own graph node.
# Measured deepest non-looping workloads on this stack: 5767, 3154 and 1589
# super-steps - a 100 default is below all three, and a 500 ceiling is below all
# three as well. The default must therefore be the CEILING, so a caller that
# sends no config gets the same budget as one that sends the UI's 1000.
Assert-That ($none -eq '4000') "an API run with no config gets the ceiling, not a 100 floor (got '$none')"
```

- [ ] **Step 2: Run the gate and confirm it fails**

```powershell
pwsh -NoProfile -File scripts/test-run-recursion-cap.ps1; "exit=$LASTEXITCODE"
```

Expected: `[FAIL] an API run with no config gets the ceiling, not a 100 floor (got '100')`, `exit=1`.

- [ ] **Step 3: Make the default the ceiling**

In `deploy/client-bundle/patches/deer-flow-run-recursion-cap.py`, replace the hardcoded default:

```python
    config: dict[str, Any] = {"recursion_limit": 100}
```

with:

```python
    # Pacgate 2026-10-30: the DEFAULT is the CEILING, not 100.
    #
    # A caller that sends no config (the API and IM paths both do this) used to
    # inherit a 100-step budget. LangGraph charges ~9.8 super-steps per model call
    # in this graph because nine middleware hooks are each their own node, so 100
    # steps is roughly ten model calls - not a budget, a tripwire. Thread 4de2965b
    # died at "Recursion limit of 100 reached" AFTER both deliverables were written.
    #
    # The ceiling is what protects against a runaway caller; making the floor a
    # second, much smaller ceiling protected nothing and broke real work. A real
    # loop is still stopped by LoopDetectionMiddleware layers 1/2 and the idle and
    # stall detectors, none of which consult this number.
    config: dict[str, Any] = {"recursion_limit": _PACGATE_MAX_RECURSION_LIMIT}
```

- [ ] **Step 4: Correct the stale comment in compose.prod.yaml**

Lines 296-298 currently claim a default of 500. Replace:

```yaml
      # 500, override with DEERFLOW_MAX_RECURSION_LIMIT) while still honouring a
      # lower request. The most expensive SUCCESSFUL run on this box used 138 LLM
      # calls, so 500 leaves roughly 3.5x headroom over proven need.
```

with:

```yaml
      # 4000, override with DEERFLOW_MAX_RECURSION_LIMIT) while still honouring a
      # lower request. 4000 is the measured runaway bound, not a comfort budget:
      # the deepest successful non-looping runs on this stack reached 5767, 3154
      # and 1589 super-steps, and super-steps per LLM call reaches 5.45. A caller
      # that sends no config now gets this ceiling as its default instead of a
      # hardcoded 100, which was ~10 model calls.
```

- [ ] **Step 5: Recreate, then run the gate green**

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps deer-flow
cd ../..
pwsh -NoProfile -File scripts/test-run-recursion-cap.ps1; "exit=$LASTEXITCODE"
```

Expected: `[PASS] an API run with no config gets the ceiling, not a 100 floor (got '4000')` and every other assertion still PASS, `exit=0`.

- [ ] **Step 6: Also record the two independent hardcodes**

`app/channels/manager.py:51` (`DEFAULT_RUN_CONFIG = {"recursion_limit": 100}`) and `deerflow/client.py:218` (`recursion_limit=overrides.get("recursion_limit", 100)`) are separate floors that never consult `build_run_config`. Add to the header comment of `deer-flow-run-recursion-cap.py`, immediately after the "WHY" paragraph:

```python
# KNOWN REMAINING FLOORS (2026-10-30, measured live on 0.2.7):
#   app/channels/manager.py:51   DEFAULT_RUN_CONFIG = {"recursion_limit": 100}
#   deerflow/client.py:218       recursion_limit=overrides.get("recursion_limit", 100)
# Neither routes through build_run_config, so neither sees this default. The IM
# channel path merges DEFAULT_RUN_CONFIG and then hands it to the gateway, which
# DOES go through build_run_config and is therefore clamped - but a caller of
# deerflow.client directly is not. Patching both is a separate change with its own
# blast radius; recorded here so the gap is not mistaken for coverage.
```

- [ ] **Step 7: Commit**

```powershell
git add deploy/client-bundle/patches/deer-flow-run-recursion-cap.py `
        deploy/client-bundle/compose.prod.yaml `
        scripts/test-run-recursion-cap.ps1
git commit -m "fix(deer-flow): default the recursion budget to the ceiling, not 100

A caller sending no config inherited a hardcoded 100 graph super-steps. With
nine middleware hooks each costing a node, that is about ten model calls - and
the deepest successful non-looping runs on this stack measured 5767, 1584 and
3154 super-steps. Real work died at 100 after writing its deliverables.

The gate asserted the 100 default as correct, so it pinned the defect; the
assertion is flipped here and red-checked first. The stale default-500 comment
in compose.prod.yaml is corrected at the same time.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 5: Stop the prompt teaching a sandbox-blocked officecli syntax (V-04)

**Files:**
- Modify: `deploy/client-bundle/patches/deer-flow-prompt.py:487-502`
- Modify: `deploy/client-bundle/patches/deer-flow-prompt.py:612-618`
- Test: `scripts/test-prompt-officecli-selectors.ps1` (create)

**Interfaces:**
- Produces: a prompt that never instructs the agent to pass a `/`-prefixed selector on a bash command line.

- [ ] **Step 1: Reproduce the defect the gate will assert against**

```powershell
docker exec deer-flow sh -c 'cd /app/backend && .venv/bin/python -c "
from deerflow.sandbox.tools import validate_local_bash_command_paths
from deerflow.config.paths import get_paths
p=get_paths()
td={\"workspace_path\":str(p.sandbox_work_dir(\"T1\",user_id=\"u\")),\"uploads_path\":str(p.sandbox_uploads_dir(\"T1\",user_id=\"u\")),\"outputs_path\":str(p.sandbox_outputs_dir(\"T1\",user_id=\"u\"))}
for c in [\"officecli add /mnt/user-data/outputs/x.docx /body --type paragraph --prop text=hi\",
          \"officecli get /mnt/user-data/outputs/x.docx /body --depth 2 --json\"]:
    try: validate_local_bash_command_paths(c, td); print(\"ALLOWED\", c)
    except Exception as e: print(\"BLOCKED\", c, \"->\", e)
"'
```

Expected: both **BLOCKED** with `Unsafe absolute paths in command: /body`. These are the exact forms lines 497-498 tell the agent to use.

- [ ] **Step 2: Rewrite the producing-documents block**

Replace lines 496-499 of `deploy/client-bundle/patches/deer-flow-prompt.py`:

```
- For a NATIVE, fully-structured Office document (tables, styles, charts, headers/footers,
  formulas, slides), use the `officecli` tool (MCP, `officecli mcp`) or the `officecli` CLI:
  `officecli create <file>.docx`, `officecli add <file>.docx /body --type paragraph --prop text="..."`,
  `officecli get <file>.docx /body --depth 2 --json`. This is the preferred path for real legal
  reports/proposals in Word/Excel/PPT rather than a pandoc conversion.
```

with:

```
- For a NATIVE, fully-structured Office document (tables, styles, charts, headers/footers,
  formulas, slides), use the `officecli` tool (MCP, `officecli mcp`) or the `officecli` CLI.
  This is the preferred path for real legal reports/proposals in Word/Excel/PPT rather than
  a pandoc conversion.
- **officecli selectors and the sandbox (IMPORTANT - this costs runs when ignored).**
  The sandbox rejects ANY `/`-prefixed token on a bash command line as an unsafe
  absolute path, so `officecli add <f> /body ...` and `officecli get <f> /body ...`
  fail with `Unsafe absolute paths in command: /body` before officecli ever runs.
  Meanwhile `officecli set` only accepts the slash form: `set <f> body/p[1]` returns
  `No elements matched selector`, while `set <f> /body/p[1]` works (measured,
  officecli 1.0.149).
  The one form that satisfies both is `batch`, because the selector then lives in
  FILE CONTENT rather than in the command string:
      write a JSON array to a file, e.g.
        [{"command":"add","parent":"/body","type":"p","props":{"text":"..."}},
         {"command":"set","path":"/body/p[1]","props":{"text":"..."}}]
      then run: officecli batch <file>.docx --input <that.json>
  Use `officecli create` and `officecli validate` directly - they take a plain path
  and are allowed.
```

- [ ] **Step 3: Fix the delivery block that repeats the same syntax**

At lines 615-617, replace:

```
`officecli` tool: `officecli create <file>.docx` then `officecli add <file>.docx /body --type paragraph
```

with:

```
`officecli` tool: `officecli create <file>.docx`, then add content with `officecli batch
<file>.docx --input <file>.json` (see the selector note above - a bare `/body` on a bash
command line is rejected by the sandbox)
```

- [ ] **Step 4: Write the gate**

Create `scripts/test-prompt-officecli-selectors.ps1` (ASCII only):

```powershell
# Guard: the lead-agent prompt must not teach an officecli syntax the sandbox
# rejects.
#
# WHY THIS EXISTS (measured 2026-10-30, officecli 1.0.149 on 0.2.7)
#
#   officecli set  <f> body/p[1] --prop text=x   -> No elements matched selector
#   officecli set  <f> /body/p[1] --prop text=x  -> Updated /body/p[1]
#
# `set` only accepts the slash form. But deer-flow's
# `validate_local_bash_command_paths` rejects any `/`-prefixed token on a bash
# command line:
#
#   officecli add /mnt/user-data/outputs/x.docx /body --type paragraph
#     -> Unsafe absolute paths in command: /body
#
# The shipped prompt told the agent to run exactly that, twice. The only form
# both accept is `officecli batch <f> --input <json>`, where the selector is file
# content. This gate asserts the prompt teaches the form that works.
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$prompt = 'deploy/client-bundle/patches/deer-flow-prompt.py'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== prompt vs officecli selector contract ===' -ForegroundColor Cyan
Check 'the prompt patch exists' (Test-Path $prompt) $prompt
if (-not (Test-Path $prompt)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $prompt -Raw

# P1 - no instruction may put a /body selector after an officecli verb on a
# bash command line. Match the documented forms, not the word "officecli".
$bad = [regex]::Matches($src, 'officecli\s+(add|get|set|remove|move|swap)\s+[^\r\n`]*?/(body|slide|sheet|para)\b')
Check 'P1 no officecli verb takes a slash selector on a command line' `
      ($bad.Count -eq 0) `
      (($bad | ForEach-Object { $_.Value.Trim() }) -join ' | ')

# P2 - the working form must actually be documented.
Check 'P2 the prompt documents officecli batch --input' `
      ($src -match 'officecli batch[^\r\n]*--input')

# P3 - create and validate take a plain path and remain the direct forms.
Check 'P3 officecli create is still documented' ($src -match 'officecli create')

# P4 - the reason must be recorded, so a future edit does not "simplify" it back.
Check 'P4 the prompt explains why the slash form is unavailable' `
      ($src -match 'Unsafe absolute paths')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 5: Red-check, then green-check**

Run the gate, then temporarily revert one prompt line to `officecli add <f> /body --type paragraph` and confirm `P1` fails (`exit=1`). Restore, and confirm `exit=0`.

```powershell
pwsh -NoProfile -File scripts/test-prompt-officecli-selectors.ps1; "exit=$LASTEXITCODE"
```

- [ ] **Step 6: Recreate and confirm the deployed prompt agrees**

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps deer-flow
docker exec deer-flow sh -c "grep -c 'officecli batch' /app/backend/packages/harness/deerflow/agents/lead_agent/prompt.py"
```

Expected: a non-zero count.

- [ ] **Step 7: Commit**

```powershell
git add deploy/client-bundle/patches/deer-flow-prompt.py scripts/test-prompt-officecli-selectors.ps1
git commit -m "fix(prompt): stop teaching an officecli syntax the sandbox rejects

officecli set accepts only the /body/p[1] selector form, while
validate_local_bash_command_paths rejects any /-prefixed token on a bash command
line. The prompt told the agent to run officecli add <f> /body ... , which is
blocked before officecli starts. The one form both accept is
officecli batch <f> --input <json>, where the selector is file content.

The gate asserts no officecli verb takes a slash selector on a command line and
that the batch form is documented.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 6: Make the installer merge connectors instead of overwriting (V-07)

**Files:**
- Modify: `deploy/client-bundle/install.ps1:994-1092`
- Test: `scripts/test-connector-template-safety.ps1` (create)

**Interfaces:**
- Produces: a render step with these properties - (a) servers present in the rendered file but absent from the template are **preserved**, (b) the operator is told which were kept, (c) the run **fails** when a server would be dropped and the operator has not acknowledged it.

- [ ] **Step 1: Establish the current behaviour with a fixture**

```powershell
$w = Join-Path $env:TEMP 'connector-merge-probe'
Remove-Item $w -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $w | Out-Null
Copy-Item deploy/client-bundle/install.ps1 $w
Copy-Item deploy/client-bundle/deer-flow-extensions-config.template.json $w
New-Item -ItemType Directory (Join-Path $w 'openviking') | Out-Null
Copy-Item deploy/client-bundle/openviking/ov.conf.template (Join-Path $w 'openviking')
'[]' | Set-Content (Join-Path $w 'ollama-models.txt')
"services: {}" | Set-Content (Join-Path $w 'compose.prod.yaml')
# a live-style config with TWO servers the template does not carry
@'
{"mcpServers":{"openviking":{"enabled":true},"pacgate":{"enabled":true},
"officecli":{"enabled":true},"firecrawl":{"enabled":true},
"yuandian-law":{"enabled":true},"pkulaw-law-search":{"enabled":true}}}
'@ | Set-Content (Join-Path $w 'deer-flow-extensions-config.json')
"OPENVIKING_ROOT_API_KEY=test-key-000000000000" | Set-Content (Join-Path $w '.env')
```

Then run the render path with stubbed `docker`/`ollama` as `test-install-render.ps1` does, and read back `deer-flow-extensions-config.json`. Expected today: `yuandian-law` and `pkulaw-law-search` are **gone**, and the run's only message names `firecrawl` (the only unknown in `$knownServers`).

- [ ] **Step 2: Replace the overwrite with a merge**

Replace the block from the `$df = (Get-Content $dfTemplate ...)` line through the closing of the `$lost` reporting (lines 1037-1091) with:

```powershell
            # Pacgate 2026-10-30: MERGE, do not overwrite.
            #
            # WHY: the render used to write the template's server set verbatim over
            # whatever was on disk. Measured on a fixture (template = 3 servers,
            # rendered = 6): the operator's `yuandian-law` and `pkulaw-law-search`
            # were removed and the run named only `firecrawl`, because the change
            # report compared against a HARDCODED $knownServers list. A live machine
            # carrying 30 legal-database connectors would lose 27 of them silently.
            #
            # The rendered file is gitignored, so no reviewer can see this loss in a
            # diff - the machine simply stops answering legal queries. The rule now
            # is: the template may ADD or UPDATE a server, never remove one. A
            # removal is only ever an explicit operator action.
            $dfRaw  = (Get-Content $dfTemplate -Raw -Encoding UTF8).Replace('${OPENVIKING_ROOT_API_KEY}', $dfKey)
            $dfTpl  = $dfRaw | ConvertFrom-Json

            $dfExisting = if (Test-Path $dfRendered) {
                [System.IO.File]::ReadAllText((Join-Path $PWD $dfRendered))
            } else { $null }

            $existingServers = @{}
            if ($null -ne $dfExisting) {
                try {
                    $old = $dfExisting | ConvertFrom-Json
                    if ($old.mcpServers) {
                        foreach ($p in $old.mcpServers.PSObject.Properties) { $existingServers[$p.Name] = $p.Value }
                    }
                } catch {
                    # Unparseable existing config: do not clobber it on the strength
                    # of a guess. Keep it, warn, and let the operator decide.
                    Write-Host "[WARN] $dfRendered is not valid JSON; leaving it untouched." -ForegroundColor Yellow
                    Write-Host "       Fix or delete it, then re-run." -ForegroundColor Yellow
                    $existingServers = $null
                }
            }

            if ($null -ne $existingServers) {
                $templateServers = @{}
                if ($dfTpl.mcpServers) {
                    foreach ($p in $dfTpl.mcpServers.PSObject.Properties) { $templateServers[$p.Name] = $p.Value }
                }

                $kept   = @($existingServers.Keys | Where-Object { -not $templateServers.ContainsKey($_) })
                $gained = @($templateServers.Keys | Where-Object { -not $existingServers.ContainsKey($_) })
                $both   = @($templateServers.Keys | Where-Object { $existingServers.ContainsKey($_) })

                # Rebuild the server map: template entries are authoritative for
                # servers the template knows; everything else is preserved verbatim.
                $mergedServers = [ordered]@{}
                foreach ($k in $both)     { $mergedServers[$k] = $templateServers[$k] }
                foreach ($k in $kept)     { $mergedServers[$k] = $existingServers[$k] }
                foreach ($k in $gained)   { $mergedServers[$k] = $templateServers[$k] }

                $dfTpl.mcpServers = [pscustomobject]$mergedServers
                $df = $dfTpl | ConvertTo-Json -Depth 32

                if ($kept.Count -gt 0) {
                    Write-Host "[OK] Preserved $($kept.Count) connector(s) not in the template: $($kept -join ', ')" -ForegroundColor Green
                    Write-Host "     The template ADDS and UPDATES only. To remove one of these," -ForegroundColor DarkGray
                    Write-Host "     delete its entry from $dfRendered by hand." -ForegroundColor DarkGray
                }
                if ($gained.Count -gt 0) {
                    Write-Host "     MCP servers added from the template: $($gained -join ', ')" -ForegroundColor Yellow
                }
            } else {
                $df = (Get-Content $dfTemplate -Raw -Encoding UTF8).Replace('${OPENVIKING_ROOT_API_KEY}', $dfKey)
            }

            # Compare with line endings normalised, so a CRLF/LF difference alone
            # does not look like a change and churn backups on every run.
            function Get-NormText([string]$s) {
                if ($null -eq $s) { return $null }
                return ($s -replace "`r`n", "`n").TrimEnd()
            }
            $dfUnchanged = ($null -ne $dfExisting) -and ((Get-NormText $dfExisting) -eq (Get-NormText $df))

            if ($dfUnchanged) {
                Write-Host "[OK] $dfRendered already current" -ForegroundColor Green
            } else {
                if ($null -ne $dfExisting) {
                    $dfStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $dfBackup = "$dfRendered.bak.$dfStamp"
                    Copy-Item -LiteralPath $dfRendered -Destination $dfBackup -Force
                    Write-Host "[OK] Previous $dfRendered backed up to $dfBackup" -ForegroundColor Green
                }
                [System.IO.File]::WriteAllText(
                    (Join-Path $PWD $dfRendered),
                    $df,
                    [System.Text.UTF8Encoding]::new($false)
                )
                Write-Host "[OK] Rendered $dfRendered from template" -ForegroundColor Green
            }
```

- [ ] **Step 3: Prove preservation on the fixture from Step 1**

Re-run the same fixture. Expected: `Preserved 2 connector(s) not in the template: yuandian-law, pkulaw-law-search`, and the rendered file still contains all six servers with valid JSON.

- [ ] **Step 4: Write the gate**

Create `scripts/test-connector-template-safety.ps1` (ASCII only):

```powershell
# Guard: the connector render must PRESERVE servers the template does not carry.
#
# WHY THIS EXISTS (measured 2026-10-30 on a fixture)
#
# install.ps1 rendered `deer-flow-extensions-config.template.json` (3 servers)
# straight over `deer-flow-extensions-config.json`. On a fixture whose on-disk
# config carried 6 servers, `yuandian-law` and `pkulaw-law-search` were silently
# removed. The change report compared against a HARDCODED
# $knownServers = @('openviking','pacgate','firecrawl'), so it named only
# `firecrawl`; the other two vanished with no message at all.
#
# The rendered file is gitignored, so this loss never appears in a diff. On a
# machine carrying the 30-connector legal-database set, one installer run loses 27
# of them and legal search stops working with no error.
#
# WHAT IS ASSERTED
#   C1 the render MERGES (the template no longer replaces the file wholesale)
#   C2 the change report is derived from the files, not from a hardcoded list
#   C3 unknown servers are reported as PRESERVED, not as removals
#   C4 an unparseable existing config is left untouched rather than clobbered
#   C5 the rendered config stays BOM-free UTF-8 (deer-flow's JSON parser rejects a BOM)
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$installer = 'deploy/client-bundle/install.ps1'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== connector render safety ===' -ForegroundColor Cyan
Check 'the installer exists' (Test-Path $installer) $installer
if (-not (Test-Path $installer)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $installer -Raw

# C1 - a merge means the existing file is PARSED, not replaced by a template write.
Check 'C1 the render parses the existing config' `
      ($src -match '\$old\s*=\s*\$dfExisting\s*\|\s*ConvertFrom-Json')
Check 'C1 the render builds a merged server map' ($src -match '\$mergedServers')

# C2 - the hardcoded list is the reason two servers vanished without a message.
Check 'C2 the change report is not driven by a hardcoded server list' `
      ($src -notmatch "\`$knownServers\s*=\s*@\(\s*'openviking'")

# C3 - preservation must be visible to the operator.
Check 'C3 preserved connectors are reported' ($src -match 'Preserved\s+\$\(\$kept\.Count\)')

# C4 - never clobber a config we could not parse.
Check 'C4 an unparseable existing config is left untouched' `
      ($src -match 'is not valid JSON; leaving it untouched')

# C5 - the BOM-free write must survive the rewrite.
Check 'C5 the render still writes BOM-free UTF-8' `
      ($src -match 'UTF8Encoding\]::new\(\$false\)')

# C6 - negative: the old overwrite form must be gone.
Check 'C6 the wholesale overwrite is gone' `
      ($src -notmatch '\$df\s*=\s*\(Get-Content \$dfTemplate -Raw -Encoding UTF8\)\.Replace\([^\)]*\)\s*\r?\n\s*\$dfExisting')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

Note: `C6` is a weak negative and exists only to catch a partial revert. The behavioural proof is the fixture in Step 3; record its measured output in the commit message.

- [ ] **Step 5: Red-check and green-check**

```powershell
pwsh -NoProfile -File scripts/test-connector-template-safety.ps1; "exit=$LASTEXITCODE"
```

Then `git stash` the installer change, re-run, confirm `C1`/`C3` fail with `exit=1`, and `git stash pop`.

- [ ] **Step 6: Register the gate and run the existing render gate**

Add to `scripts/run-all-checks.ps1` directly after `'scripts/test-install-render.ps1'` (line 82):

```powershell
    # CONNECTOR RENDER SAFETY, registered 2026-10-30. `test-install-render` proves
    # the render is idempotent and reports changes; it does not prove the render
    # cannot DELETE a connector the template does not know about. Measured: a
    # 6-server config lost 2 servers to a 3-server template, and the report named
    # neither because it compared against a hardcoded list.
    'scripts/test-connector-template-safety.ps1'
```

Then confirm the neighbouring gate still passes:

```powershell
pwsh -NoProfile -File scripts/test-install-render.ps1; "exit=$LASTEXITCODE"
```

Expected: `exit=0` (its three cases - first run, idempotent, changed template - must all still hold with the merge in place).

- [ ] **Step 7: Commit**

```powershell
git add deploy/client-bundle/install.ps1 scripts/test-connector-template-safety.ps1 scripts/run-all-checks.ps1
git commit -m "fix(install): merge connectors on render instead of overwriting

The render wrote the 3-server template verbatim over the on-disk config. On a
fixture carrying 6 servers, yuandian-law and pkulaw-law-search were removed and
the change report named neither, because it compared against a hardcoded
three-name list. The rendered file is gitignored, so the loss is invisible in a
diff - legal search just stops working.

The template may now ADD and UPDATE a server, never remove one. Preserved
servers are named in the output. An unparseable existing config is left
untouched rather than clobbered on a guess.

Verified on the fixture: 6 servers in, 6 out, 2 reported as preserved.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 7: Scope the model-tag audit to the `models:` block (V-06)

**Files:**
- Modify: `scripts/audit-model-tags.ps1:81-92`
- Modify: `scripts/run-all-checks.ps1` (register)

**Interfaces:**
- Produces: a scan that collects `model:` values only from inside `models:`, and stops at the next top-level key.

- [ ] **Step 1: Reproduce the false positive**

```powershell
@'
$cfg = @'
models:
  main:
    model: gemma4:12b-it-qat
subagents:
  reviewer:
    model: gemma4-12b-local
'@
$tags = @()
foreach ($line in ($cfg -split "`n")) {
  if ($line -match '^\s*#') { continue }
  if ($line -match '^\s*model:\s*(\S+)') { $tags += $Matches[1] }
}
"current matcher collects: $($tags -join ', ')"
'@ | Out-File -Encoding utf8 "$env:TEMP\tag_repro.ps1"
pwsh -NoProfile -File "$env:TEMP\tag_repro.ps1"
```

Expected: `current matcher collects: gemma4:12b-it-qat, gemma4-12b-local` — the `subagents:` model is a false positive that `Normalize-Tag` then turns into a `:latest` miss.

- [ ] **Step 2: Scope the scan**

In `scripts/audit-model-tags.ps1`, replace the tag-collection block (lines 88-91):

```powershell
    # Commented-out entries (a leading '#') are deliberately disabled; skip them so
    # a disabled model does not trip the guard.
    $tags = @()
    foreach ($line in (Get-Content $cfg)) {
        if ($line -match '^\s*#') { continue }
        # YAML `model: <tag>` and JSON `"model": "<tag>"`
        if ($line -match '^\s*model:\s*(\S+)') { $tags += Normalize-Tag $Matches[1] }
        elseif ($line -match '"model"\s*:\s*"([^"]+)"') { $tags += Normalize-Tag $Matches[1] }
    }
```

with:

```powershell
    # Pacgate 2026-10-30: scan the `models:` BLOCK, not every line of the file.
    #
    # The previous matcher was `^\s*model:\s*(\S+)` over the whole YAML, so a
    # `subagents:` entry's `model:` key was collected as if it were a loadable
    # model tag. Two such entries in one config produced false positives, and
    # Normalize-Tag turned each into a `:latest` miss - so the guard exited 1 on a
    # config that was correct, which is how a guard gets ignored.
    #
    # Measured fixture: the old matcher reported gemma4-12b-local from a
    # `subagents:` block; the scoped matcher reports only gemma4:12b-it-qat.
    #
    # JSON configs have no block structure to respect, so the JSON form still
    # scans the whole file - a JSON model entry IS a loadable model.
    $tags = @()
    $lines = @(Get-Content $cfg)
    $isJson = $cfg -match '\.json$'

    if ($isJson) {
        foreach ($line in $lines) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '"model"\s*:\s*"([^"]+)"') { $tags += Normalize-Tag $Matches[1] }
        }
    } else {
        $inModels = $false
        foreach ($line in $lines) {
            if ($line -match '^[A-Za-z_][A-Za-z0-9_-]*\s*:') {
                # A new top-level key ends the models block.
                $inModels = ($line -match '^models\s*:')
                continue
            }
            if (-not $inModels) { continue }
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*model:\s*(\S+)') { $tags += Normalize-Tag $Matches[1] }
        }
    }
```

- [ ] **Step 3: Verify green on the real config and red on the fixture**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/audit-model-tags.ps1 2>&1 | Select-Object -Last 6
```

Expected: `RESULT: every requested local tag is pre-pulled.` and exit 0.

Then append a temporary `subagents:` block with a bogus model to `deploy/client-bundle/deer-flow-config.yaml`, re-run, and confirm the audit **still** exits 0 (the bogus tag is outside `models:` and must be ignored). Remove the block.

- [ ] **Step 4: Register the audit**

`audit-model-tags.ps1` is currently described in a comment in `run-all-checks.ps1` (line 286 and 738) but never registered, so its false-positive history is unguarded. Add to the `$gates` list next to `'scripts/test-model-roster-consistency.ps1'`:

```powershell
    # MODEL TAG AUDIT, registered 2026-10-30. This ran green for months while the
    # Rust tier roster 404'd, because nothing invoked it. Its matcher also scanned
    # the whole YAML, so a `subagents:` model name was collected as a local tag and
    # :latest-normalized into a false miss. Scoped to `models:` and registered here.
    'scripts/audit-model-tags.ps1'
```

- [ ] **Step 5: Commit**

```powershell
git add scripts/audit-model-tags.ps1 scripts/run-all-checks.ps1
git commit -m "fix(audit): scope the model-tag scan to the models block, and register it

The matcher read ^\\s*model:\\s*(\\S+) over the whole YAML, so a subagents: entry's
model name was treated as a loadable tag and :latest-normalized into a miss.
Reproduced on a fixture: the old matcher collected a subagents: model, the
scoped matcher does not.

The audit was also never in the gate list, which is why it reported clean while
the tier roster 404'd.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 8: Default thinking OFF when no mode is chosen (V-08)

**Files:**
- Modify: `deploy/frontend-patches/files/src/core/threads/hooks.ts:974`
- Modify: `deploy/frontend-patches/files/src/components/workspace/input-box.tsx:135-146`
- Test: `scripts/test-thinking-default.ps1` (create)

**Interfaces:**
- Produces: `thinking_enabled` is true only for `"thinking"`, `"pro"` and `"ultra"`; an unset mode resolves to a non-thinking mode.

Context: this is build-time source. It cannot take effect until the next frontend image build. The gate asserts the source, and the change is recorded so the next build carries it.

- [ ] **Step 1: Note the current behaviour and why it matters**

`hooks.ts:974` is `thinking_enabled: context.mode !== "flash"`, and `DEFAULT_LOCAL_SETTINGS` leaves `context.mode` unset, so the expression is `undefined !== "flash"` → `true`. `input-box.tsx:145` compounds it by returning `"pro"` from `getResolvedMode()` on mount. `deer-flow-config.yaml` sets `when_thinking_disabled: {reasoning_effort: none}` for every thinking-capable model, but `deer-flow-model-factory.py:138` applies it **only** when `thinking_enabled` is false, so the suppression never fires on an unset mode.

- [ ] **Step 2: Make the predicate explicit**

In `deploy/frontend-patches/files/src/core/threads/hooks.ts`, replace line 974:

```ts
              thinking_enabled: context.mode !== "flash",
```

with:

```ts
              // Pacgate 2026-10-30: an UNSET mode must not enable thinking.
              //
              // It did: `context.mode !== "flash"` is true for undefined, and the
              // mode default lives in local storage, so every first-turn run from a
              // fresh profile ran with thinking on. deer-flow-config.yaml carries
              // `when_thinking_disabled: {reasoning_effort: none}` for every
              // thinking-capable model, but the factory applies it only when
              // thinking_enabled is false - so the suppression never fired and the
              // reply budget was shared with the invisible reasoning channel.
              //
              // Measured: 12 `deepseek-v4.1-flash` replies ended with
              // finish_reason=length and 8192/8192 tokens spent entirely on
              // reasoning, producing an empty assistant message. That is
              // conditional on prompt size, not universal - a short prompt answered
              // fine either way - so this is a real budget defect, not a hang.
              thinking_enabled:
                context.mode === "thinking" ||
                context.mode === "pro" ||
                context.mode === "ultra",
```

- [ ] **Step 3: Stop the mount effect resolving an unset mode to `"pro"`**

In `deploy/frontend-patches/files/src/components/workspace/input-box.tsx`, replace the `getResolvedMode` body (lines 139-146):

```ts
  if (!supportsThinking && mode !== "flash") {
    return "flash";
  }
  if (mode) {
    return mode;
  }
  return supportsThinking ? "pro" : "flash";
```

with:

```ts
  if (!supportsThinking) {
    return "flash";
  }
  // Pacgate 2026-10-30: do NOT default an unset mode to "pro". This function is
  // called from a mount effect, so the default was written into the user's context
  // before they chose anything - and "pro" turns thinking on. An unset mode now
  // means "no explicit choice", which flash represents without spending the reply
  // budget on reasoning. The user can still pick Thinking/Pro/Ultra.
  return mode ?? "flash";
```

- [ ] **Step 4: Write the gate**

Create `scripts/test-thinking-default.ps1` (ASCII only):

```powershell
# Guard: an UNSET chat mode must not enable thinking.
#
# WHY THIS EXISTS (measured 2026-10-30)
#
# `hooks.ts` computed `thinking_enabled: context.mode !== "flash"`. The mode
# default lives in local storage, so on a fresh profile mode is `undefined` and
# `undefined !== "flash"` is TRUE - thinking on for every first-turn run. A second
# site compounded it: `getResolvedMode()` returned "pro" whenever the model
# supported thinking, and its caller is a mount effect.
#
# Consequence: `when_thinking_disabled: {reasoning_effort: none}` in
# deer-flow-config.yaml - present for every thinking-capable model - is applied
# only when thinking_enabled is false, so it never fired. 12 deepseek-v4.1-flash
# replies finished with reason=length after 8192/8192 tokens of reasoning and an
# empty message.
#
# This is BUILD-TIME source: the frontend image ships compiled output and has no
# source mount. The gate asserts the source so the next image build carries the fix.
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$hooks = 'deploy/frontend-patches/files/src/core/threads/hooks.ts'
$box   = 'deploy/frontend-patches/files/src/components/workspace/input-box.tsx'
$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== thinking default ===' -ForegroundColor Cyan
Check 'hooks.ts exists' (Test-Path $hooks) $hooks
Check 'input-box.tsx exists' (Test-Path $box) $box
if (-not (Test-Path $hooks) -or -not (Test-Path $box)) { Write-Host 'RESULT: cannot continue'; exit 1 }

$h = Get-Content $hooks -Raw
$b = Get-Content $box -Raw

# T1 - the exact defect. A negation test is what made it true for undefined.
Check 'T1 thinking is not derived from a != flash negation' `
      ($h -notmatch 'thinking_enabled\s*:\s*[^\r\n]*!==\s*"flash"') `
      'thinking_enabled: context.mode !== "flash" is true when mode is undefined'

# T2 - the positive form must name the thinking modes explicitly, and the three
# names must sit inside the SAME expression. Checking for `=== "pro"` anywhere in
# the file would pass on the unrelated `is_plan_mode` line two below it.
$t2 = [regex]::Match($h, 'thinking_enabled:[\s\S]{0,500}?(?=\n\s*is_plan_mode:)')
Check 'T2 thinking_enabled is followed by an explicit mode expression' $t2.Success
if ($t2.Success) {
    Check 'T2 the expression names "thinking"' ($t2.Value -match 'context\.mode\s*===\s*"thinking"')
    Check 'T2 the expression names "pro"'      ($t2.Value -match 'context\.mode\s*===\s*"pro"')
    Check 'T2 the expression names "ultra"'    ($t2.Value -match 'context\.mode\s*===\s*"ultra"')
} else {
    Check 'T2 the expression names the thinking modes' $false 'could not isolate the thinking_enabled expression'
}

# T3 - the mount effect must not resolve an unset mode to "pro".
Check 'T3 getResolvedMode does not default to pro' `
      ($b -notmatch 'return supportsThinking \? "pro" : "flash"') `
      'that default runs on mount and turns thinking on before the user chooses'
Check 'T3 an unset mode resolves to flash' ($b -match 'return mode \?\? "flash"')

# T4 - the reason is recorded at both sites.
Check 'T4 hooks.ts records why the negation was wrong' ($h -match 'UNSET mode must not enable thinking')
Check 'T4 input-box.tsx records why the default was removed' ($b -match 'do NOT default an unset mode')

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 5: Red-check and green-check**

```powershell
pwsh -NoProfile -File scripts/test-thinking-default.ps1; "exit=$LASTEXITCODE"
```

Then revert only `hooks.ts:974` to the negation form and confirm `T1` fails (`exit=1`). Restore.

- [ ] **Step 6: Register the gate**

Add to `scripts/run-all-checks.ps1` after the frontend-related entry (near `'scripts/test-model-picker-e2e.ps1'` if present, otherwise at the end of the `$gates` literal):

```powershell
    # THINKING DEFAULT, registered 2026-10-30. `thinking_enabled: mode !== "flash"`
    # is true for an unset mode, and the mode default is read from local storage on
    # mount - so a fresh profile ran every first turn with thinking on. The config's
    # when_thinking_disabled suppression only fires when thinking is OFF, so it never
    # fired and 12 replies spent the whole budget on reasoning. Static: reads the
    # frontend patch source, which the next image build compiles in.
    'scripts/test-thinking-default.ps1'
```

- [ ] **Step 7: Commit**

```powershell
git add deploy/frontend-patches/files/src/core/threads/hooks.ts `
        deploy/frontend-patches/files/src/components/workspace/input-box.tsx `
        scripts/test-thinking-default.ps1 scripts/run-all-checks.ps1
git commit -m "fix(frontend): an unset chat mode must not enable thinking

thinking_enabled was 'context.mode !== \"flash\"', which is true when mode is
undefined - and mode is read from local storage, so a fresh profile enabled
thinking on every first turn. getResolvedMode() compounded it by returning
\"pro\" from a mount effect.

with_thinking_disabled.reasoning_effort=none only applies when thinking is off,
so it never fired: 12 deepseek-v4.1-flash replies ended at reason=length having
spent 8192/8192 tokens on reasoning, with an empty message.

Build-time source - this takes effect on the next frontend image build, not on a
container restart.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 9: Record the verdicts that were rejected, and the ones deferred

**Files:**
- Modify: `deploy/AIPC-UPDATE-GAP-ANALYSIS.md`

**Interfaces:**
- Produces: the durable record. Without it, the next agent re-derives V-02 and V-05 and ships a patch for behaviour that is already correct.

- [ ] **Step 1: Append the verdict table**

Append to `deploy/AIPC-UPDATE-GAP-ANALYSIS.md`:

```markdown
## AIPC1 handoff (2026-10-30) - what was adopted, and what deliberately was not

The handoff reached this repo as a delta inventory. Each item was re-verified
against this tree and the live 0.2.7 container before any change. Four of the
nine verdicts did not survive that check, and adopting them would have shipped
patches for behaviour that is already correct.

| ID | Verdict | Outcome here |
|---|---|---|
| V-01 | MCP arguments never path-translated | **Adopted.** `deer-flow-mcp-args.py` + `test-mcp-argument-paths.ps1`. The handoff's root cause was right and was re-proved: without `InjectedToolArg`, `runtime` arrives as `None`. |
| V-01b | - | **Found, not in the handoff.** The mounted adapter renames hyphens to underscores in the tool prefix, and `get_mcp_tools()` compared against the raw server key, so hyphenated servers lost session pooling and result conversion. Fixed in the same patch. |
| V-02 | `read_file` on a binary says use `pandoc` | **Rejected - already fixed upstream.** The live container returns the pandas/openpyxl hint. `git log -S pandoc` over `sandbox/tools.py` finds nothing; upstream fixed it in `6a4a30fa`. |
| V-03 | Recursion default was a hardcoded 100 | **Adopted.** Default now equals the ceiling. The existing gate asserted the 100 default as correct, so the assertion was flipped first and red-checked. Two independent hardcodes (`channels/manager.py:51`, `client.py:218`) are recorded as known remaining floors, not silently declared fixed. |
| V-04 | `officecli set` rejects the selector `get` accepts | **Adopted as a prompt fix, not a code fix.** officecli is an upstream binary and was not patched. The prompt no longer teaches a command the sandbox rejects, and documents `batch --input`. |
| V-05 | 14 skills declared tools that resolve to nothing | **Rejected - not applicable.** Upstream ships 3 seeded skills and all three deliberately declare no `allowed-tools`, with the measured reason in their headers. `test-skill-evolution.ps1` E5 already enforces this. |
| V-06 | `audit-model-tags.ps1` false positives | **Adopted.** Scoped to the `models:` block and registered in the gate list, which it never was. |
| V-07 | The connector template wipes 27 connectors | **Adopted, and worse than reported.** The change report compared against a hardcoded three-name list, so removals beyond `firecrawl` were not even named. The render now merges and never removes. |
| V-08 | `thinking_enabled` defaults ON | **Adopted in source.** Build-time only: the frontend image ships compiled output and has no source mount, so this lands on the next image build. |
| V-09 | A local 0.2.8 was invented | **Nothing to do.** Confirmed: no `0.2.8` string exists in the tracked tree. Recorded so it is not repeated. |
| Part 3 | 5 of 6 playbook references are dangling | **Not applicable.** Upstream has no `playbooks/` and none of the three seeded skills references one. The dangling references live in AIPC1's 60-skill corpus, which lives in a different repo and must not be ported. |
| Part 4 | `OPERATOR.md` is tracked and public | **Corrected.** `git ls-files` returns nothing, `git check-ignore` matches, and both historical blobs carry `[REDACTED - see password manager]` with no live value. Credential status is owned by `plans/013-credential-rotation.md`. |

### Deliberately not ported

The 60 skills and the `playbooks/` corpus live in `pacgate-ai/deer-flow` on branch
`pacgate-layer`, not here. The live `deer-flow-extensions-config.json` holds 27
legal-database credentials and is gitignored for that reason. Porting either would
either leak credentials or fork a corpus that has its own repo.

### Open, not fixed by this change

- `app/channels/manager.py:51` and `deerflow/client.py:218` each hardcode
  `recursion_limit: 100` independently of `build_run_config`. The IM path routes
  through the gateway and is therefore clamped; a direct `deerflow.client` caller is
  not.
- The frontend thinking fix is inert until the next frontend image build.
```

- [ ] **Step 2: Verify the doc renders and references real paths**

```powershell
Select-String -Path deploy/AIPC-UPDATE-GAP-ANALYSIS.md -Pattern 'deer-flow-mcp-args|test-mcp-argument-paths|6a4a30fa|plans/013'
```

Expected: each reference present. No documentation tests exist in this repo, so no further validation is needed.

- [ ] **Step 3: Commit**

```powershell
git add deploy/AIPC-UPDATE-GAP-ANALYSIS.md
git commit -m "docs(aipc): record which AIPC1 verdicts were adopted and which were not

Four of the nine verdicts did not survive re-verification here. V-02 was already
fixed upstream (6a4a30fa), V-05 and Part 3 do not apply to the three seeded
skills, and Part 4's credential claim is out of date - OPERATOR.md is untracked
and both historical blobs are redacted.

Records the two recursion floors this change does NOT fix, and that the frontend
thinking fix is inert until the next image build.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

### Task 10: Full-suite verification

**Files:** none.

- [ ] **Step 1: Run the whole gate suite**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/run-all-checks.ps1 -SkipOcrPull 2>&1 | Tee-Object -FilePath "$env:TEMP\suite.log" | Select-Object -Last 45
```

Expected: every gate green except ones legitimately reporting CANNOT CHECK. **A new red in a gate this plan did not touch is a regression and must be fixed before proceeding.**

- [ ] **Step 2: Confirm the four new/changed gates individually**

```powershell
foreach ($g in @('test-mcp-argument-paths','test-connector-template-safety','test-thinking-default','test-prompt-officecli-selectors','test-run-recursion-cap','audit-model-tags')) {
  pwsh -NoProfile -File "scripts/$g.ps1" *> "$env:TEMP\$g.log"
  "$g -> exit=$LASTEXITCODE"
}
```

Expected: `exit=0` for all six.

- [ ] **Step 3: Confirm the stack still serves a document**

```powershell
docker exec deer-flow sh -c 'officecli create /tmp/final-check.docx && officecli validate /tmp/final-check.docx'
curl -s -o NUL -w "%{http_code}" http://localhost:8001/api/health
```

Expected: `Validation passed: no errors found.` and an HTTP 200 (adjust the port to whatever `compose.prod.yaml` publishes if it differs).

- [ ] **Step 4: Clean up temporary artifacts**

```powershell
Remove-Item "$env:TEMP\mcp_args.bak","$env:TEMP\suite.log","$env:TEMP\attr.py","$env:TEMP\tag_repro.ps1" -ErrorAction SilentlyContinue
Get-ChildItem "$env:TEMP" -Filter 'probe*.py' | Remove-Item -Force
docker exec deer-flow sh -c 'rm -rf /tmp/oc /tmp/probe*.py /tmp/attr*.py /tmp/final-check.docx /tmp/mcp_args_probe.py'
```

- [ ] **Step 5: Final commit if Step 4 changed tracked files**

Only needed if a gate required a tracked fix.

```powershell
git status --porcelain
```

Expected: empty.
