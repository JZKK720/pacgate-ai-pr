# DEFECT: test-update-end-to-end.ps1 cannot run under Windows PowerShell 5.1

**Status:** OPEN - found 2026-10-14 while running the compose-related gates after the
healthcheck and setup-token changes. Pre-existing: reproduced with those changes stashed,
so it is not a regression from that work.

**Severity:** MEDIUM. It is a harness defect, not a product defect - the gate that verifies
`install.ps1 -Update` cannot itself run on the machines clients actually have. The suite
passes because it runs under `pwsh`, so the failure is invisible on the dev box.

## What was measured

```
=== install.ps1 -Update end-to-end (real git origin) ===
  work dir: C:\Users\1\AppData\Local\Temp\e2e-ecc37f
  [FAIL] harness error: You cannot call a method on a null-valued expression.
         at Invoke-Git, scripts\test-update-end-to-end.ps1: line 63
at <ScriptBlock>, scripts\test-update-end-to-end.ps1: line 218
0 passed, 1 FAILED
```

Reproduced identically with `git stash` holding the healthcheck/setup-token work, so HEAD
carries this too.

## Root cause

`Invoke-Git` builds its process the .NET Core way:

```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'git'
...
foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) }   # line 63
```

`ProcessStartInfo.ArgumentList` was added in **.NET Core 2.1 / .NET 5+**. Windows
PowerShell 5.1 runs on **.NET Framework**, where the property does not exist. Reading a
non-existent property yields `$null` rather than throwing, so the failure surfaces one step
later as `You cannot call a method on a null-valued expression` on `.Add()` - a message that
names neither the property nor the real cause.

`pwsh` 7 is .NET 5+, so the same line works there. `run-all-checks.ps1` falls back to
`powershell.exe` when `pwsh` is absent, which is the client AIPC arrangement, so on client
hardware this gate fails at its first `git` call.

## This is the third defect of the same shape

All three are "works under pwsh 7, silently wrong on the client":

| defect | mechanism |
| --- | --- |
| `DEFECT-ps51-cjk-literal-parse-failure.md` | BOM-less `.ps1` decoded as ANSI -> CJK literals mangle |
| `DEFECT-ps51-native-stderr.md` | native stderr becomes terminating when redirected |
| **this one** | `ProcessStartInfo.ArgumentList` absent on .NET Framework |

The common property is that the dev box has both launchers and the client has only 5.1, so
**the dev box cannot fail the way the client fails.** A dual-launcher run of the suite would
surface all three at once.

## Fix

Set `Arguments` instead of `ArgumentList`, which exists on both runtimes:

```powershell
# Quote each argument for the command line. Arguments is a single string on
# .NET Framework, where ArgumentList does not exist.
$psi.Arguments = ($GitArgs | ForEach-Object {
    if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
}) -join ' '
```

Note this is not a drop-in: `Arguments` is a single command-line **string** and needs
quoting, whereas `ArgumentList` takes pre-split arguments and does not. The quoting above is
the minimum; a `\` immediately before a closing quote is the classic edge case, and none of
the current call sites pass a path ending in a backslash inside a quoted argument.

`ArgumentList` is preferable where it exists, so the most robust form is to branch on
runtime capability rather than pick one:

```powershell
if ($psi.ArgumentList) { foreach ($a in $GitArgs) { $psi.ArgumentList.Add($a) } }
else { $psi.Arguments = ... }
```

Either way, verify by running the gate under `powershell.exe` - the dev box's `pwsh` will not
show the bug.
