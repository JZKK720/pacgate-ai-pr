# DEFECT: the installer aborts on Windows PowerShell 5.1 before bootstrapping

**Status:** FIXED 2026-10-11; second defect of the same class fixed 2026-10-13 (rides the next image / next repo pull)
**Severity:** HIGH - a first install on a client AIPC produced a running stack with **no tenant, no admin and no matter**, and printed no error explaining why.
**Introduced:** `a8be956` (2026-09-28) - *"feat(install): bootstrap the tenant and admin, or a fresh install has no login"*
**Present in:** v0.1.25, v0.1.26, v0.1.27 (identically). **Not** in v0.1.24.
**Found by:** the fresh-clone proof, 2026-10-11 (defect 1) and 2026-10-13 (defect 2, found only because defect 1 was fixed first).

## The defect

`install.ps1` sets `$ErrorActionPreference = "Stop"` at the top. On the **built-in
Windows PowerShell 5.1**, *any* native command that writes to **stderr** becomes a
**terminating** error when a redirection is attached. All three forms are affected:

| Form | PS 5.1 | PowerShell 7 |
| --- | --- | --- |
| `cmd 2>&1` | **terminates** | fine |
| `cmd 2>$null` | **terminates** | fine |
| `cmd *>$null` | **terminates** | fine |
| `cmd` (no redirection) | fine | fine |

`docker compose up -d` writes its progress to **stderr on every run** - not just the
first:

```
Network pacgate-ai-bundle_default  Creating
Volume  pacgate-ai-bundle_pacgate-db-data  Creating
Container pacgate-api-1  Running
```

So the installer died at the compose-up step with a `NativeCommandError` and never
reached the tenant or admin bootstrap. The transcript ends like this:

```
Bootstrapping the default tenant and admin user...
docker :  Volume pacgate-ai-bundle_pacgate-db-data Creating
At ...\install.ps1:789 char:1
+ docker compose -f compose.prod.yaml up -d pacgate-api pacgate-db ngin ...
+ CategoryInfo : NotSpecified: ( Volume pacgate...-data Creating :String) [], RemoteException
+ FullyQualifiedErrorId : NativeCommandError
```

There is no `[OK] tenant ... present`, no `[OK] admin ... registered`, no
`[OK] Provisioned matter`, no `[OK] Stack running`. The install simply stops.

## Why it was invisible for three releases

1. **The dev box runs `pwsh` 7**, where the pattern is harmless. The defect only
   appears on the built-in shell a client AIPC actually has.
2. **The clean-clone proof log's run 2 (2026-10-07) tested 0.1.24**, which predates
   `a8be956`. It passed because the code that fails did not exist yet.
3. **The existing install tests cannot catch it.** `test-install-render.ps1`,
   `test-install-repo-pull.ps1` and `test-update-end-to-end.ps1` all run the
   installer under `pwsh` with a **stub docker that prints nothing**. A stub that
   never writes to stderr cannot reproduce a stderr-termination defect.
4. **The handbook asserted the opposite.** `AIPC-DEPLOYMENT-HANDBOOK.md` claimed
   PowerShell 7 was optional and that PS 5.1 was "compatible with everything it
   runs". That claim was false and is now corrected.

## Why `try/catch` and `trap` do not fix it

Both were measured on PS 5.1, not assumed:

- **`try/catch`** - the terminating error *is* caught, but **the remainder of the
  try block never executes** and **any assignment in flight is silently lost**.
  Measured: `C2 -> not-run`, `C5 -> ''` (vs `'admin'` on pwsh 7). This is why the
  installer printed no error: the 26 `try/catch` blocks in `install.ps1` are not a
  safety net for this defect.
- **`trap { continue }`** - execution continues, but the assignment is **still
  silently lost**. Measured: `W1 x=''`, `W2 y=''`. Strictly worse than the fix.

## The fix

A helper, defined in each client-facing script:

```powershell
function Invoke-WithNativeStderr {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Script } finally { $ErrorActionPreference = $previous }
}
```

Every native call that may write to stderr is routed through it. **24 sites** in
`install.ps1`, **2** in `setup-qm.ps1`, **6** in `smoke-deer-flow-outputs.ps1`.

**What it does** (measured on both shells): prevents termination; preserves
`$LASTEXITCODE` across the boundary (0, 3 and 7 all verified); keeps streaming
through a pipeline; restores `$ErrorActionPreference` to `Stop`; caller-scope
variables resolve inside the scriptblock.

**What it does not do:** it does **not** make a `2>&1 | Out-String` capture match
PowerShell 7. PS 5.1 still injects `NativeCommandError` decoration into that text
**and reorders the lines**. That is why the five `2>&1` capture sites were
**converted to `2>$null`** rather than merely wrapped - a `2>$null` capture *is*
byte-identical to PowerShell 7's. The one display-only site (the compose-up
progress echo) dropped its redirection entirely, which is also byte-identical.

## A second defect of the same class: `-SkipHttpErrorCheck`

Found by running the **fixed** installer end to end on a clean clone under
`powershell.exe` 5.1 (2026-10-13). That run finally reached the bootstrap, where
the first defect had always killed it - and the bootstrap then failed:

```
[OK] tenant 'default-firm' present (created if absent)
[WARN] could not register the admin 'admin@pacgate-law.com'.
[WARN] Could not authenticate to the API, so no matter could be provisioned.
```

**`-SkipHttpErrorCheck` is a PowerShell 7 parameter.** On 5.1 the call raises
`ParameterBindingException` **before a request leaves the machine**:

```
PS 5.1   : -SkipHttpErrorCheck available = False
           -> A parameter cannot be found that matches parameter name 'SkipHttpErrorCheck'.
PS 7.6.6 : -SkipHttpErrorCheck available = True -> call SUCCEEDED
```

The old code was:

```powershell
try {
    $resp = Invoke-WebRequest ... -SkipHttpErrorCheck
} catch { }          # <- swallows the ParameterBindingException
if ($resp) { ... }   # <- $resp stays $null, so this never runs
```

So the failure was **silent**: all 15 retries failed identically, the installer
printed "could not register the admin", and matter provisioning then could not
authenticate either - so deer-flow fell back to **unsanitized** on-disk memory.
Same class as the native-stderr defect: pwsh-7-only behaviour that the client's
built-in shell does not have, invisible on the dev box.

`Invoke-ApiRequest` replaces it. It reports `Status` / `Body` / `Error` as data
instead of throwing, which is what the retry loop actually needed. A **403 is
not a failure here** - the register route is first-user-only and answers 403 with
"the first account already exists" when the admin is already present; the loop's
existing `already|exists|duplicate` match now sees that message, which it never
could before. The failure branch also prints the last error, so this can never be
silent again.

**The body is read from `$_.ErrorDetails.Message`.** The obvious alternatives do
not work, measured on both shells: PS 5.1's `HttpWebResponse` stream reads
**empty** (PowerShell has already consumed it) and PS 7's
`HttpResponseMessage.Content` is **disposed** by the time `catch` runs.

## The gate

`scripts/test-ps51-native-stderr.ps1`, registered in `run-all-checks.ps1`.
**33 assertions.**

- **Static:** no executable `2>&1` survives in any client script; every
  `2>$null` / `*>` site is inside the helper; the helper is defined and used; and
  **no PowerShell 7-only parameter** (`-SkipHttpErrorCheck`, `-StatusCodeVariable`,
  `-AsHashtable`, `-AsByteStream`, `-ProgressAction`, `-FollowSymlink`) appears - in
  the three client scripts **and** in the five repo-side scripts fixed alongside them
  (`ov-mcp-call.ps1`, `ghcr-login.ps1`, `dispatch-release-via-api.ps1`,
  `test-install-render.ps1`, `test-auth-provisioning-gate.ps1`). Those five are
  checked for the parameter class only: they are dev-side and run under `pwsh`, so
  they are not held to the client scripts' stderr-redirection rules.
- **Dynamic:** both helpers are **extracted from `install.ps1` by AST** (so the
  gate cannot drift from the shipped implementation) and run under real
  `powershell.exe` 5.1 - the stderr helper must survive stderr, preserve
  `$LASTEXITCODE` and produce a clean capture; the API helper must return a result
  rather than throw.
- **Controls:** the same command **without** the stderr helper must still die
  under 5.1, and `-SkipHttpErrorCheck` must be **ABSENT** on 5.1. Without these the
  gate could pass for the wrong reason.
- **Parity:** the helper is a no-op under pwsh 7.

Red-green verified. Against the pre-fix `install.ps1` the gate reports 5 executable
`2>&1` lines, 19 unwrapped redirection sites, 0 helper definitions and 1
PowerShell 7-only parameter (**line 742**, the register call). Against the pre-fix
repo scripts it flags **all five**: `ov-mcp-call.ps1:67`, `ghcr-login.ps1:27`,
`dispatch-release-via-api.ps1:43`, `test-install-render.ps1:106`, and
`test-auth-provisioning-gate.ps1:76,105`.

## Residual

- The fix is in the repo. A client AIPC picks it up on the next `install.ps1
  -Update` (or a fresh clone). **Machines already installed from 0.1.25-0.1.27
  have an empty database** and need the bootstrap re-run - `install.ps1 -Update`
  does this, or the browser wizard at `/setup`.
- **Measured blast radius (2026-10-13), replacing an earlier guess of "~50 files".**
  A repo-wide scan for `$ErrorActionPreference = "Stop"` plus an unguarded
  redirection, excluding `.git`/`node_modules`/`.venv`, over **170 `.ps1` files**
  found **35**. Of those, only **four tracked files** carried the more dangerous
  *PowerShell 7-only parameter* class (the defect-2 shape, which fails **silently**
  rather than aborting) - and a **fifth, a security gate, was missed by that first
  scan** because it sets `ErrorActionPreference = 'Continue'`, so it never met the
  scan's precondition. All five are now fixed and covered by the gate:
  `scripts/ov-mcp-call.ps1` (could not call the MCP server at all under 5.1),
  `scripts/ghcr-login.ps1` (could not report token scopes), and
  `scripts/dispatch-release-via-api.ps1` (could not dispatch a release) - all three
  are **operational** - plus `scripts/test-install-render.ps1` (a BOM assertion that
   silently did not run) and `scripts/test-auth-provisioning-gate.ps1`, which is the
  worst of the five: under 5.1 its preflight reported "health is not answering" while
  the stack was **up and healthy**, and every probe returned `$null`, so it exited 2
  having verified **nothing**. It was fail-safe (never a false PASS) but it could not
  check register-refusal, the admin role, or non-admin escalation on the client's own
  shell. It now runs and passes 8/8 on both shells. The remaining 30 files are
  *redirection*-only and all gates run under `pwsh`, so they are latent.
- **`pacgate-docx/src/store.rs:774` (`apply_edit`) is a latent trap, not a live bug.**
  It is the only one of six version-increment sites using `doc.version + 1` instead of
  `latest_version(...) + 1`. The schema states the one-version-per-(matter, name)
  invariant is *"enforced at application level"*, and `insert_doc_row` is a plain
  `INSERT` with no conflict guard, so a duplicate version row would be accepted and the
  file path would collide. **Reachability was traced and it is currently unreachable:**
  the API's edit route calls `apply_edit_to_family` (the correct one), the only
  `apply_edit` caller is the agent's `edit_document`, `list_for_matter` returns only the
  latest version per name, and `read_document` **echoes back the id it was given** - so
  the agent never learns an older revision's uuid. Left unchanged deliberately rather
  than fixing an unreachable path; it is recorded here so it is not rediscovered.
