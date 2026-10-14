# DEFECT: four credential-guard scripts cannot be parsed by Windows PowerShell 5.1

**Status:** OPEN - found 2026-10-14, not fixed here, deliberately out of scope for the
0.1.31 release commit. Recorded because it is security-relevant and nothing else in the
repo notices it.

**Severity:** the scripts fail loudly rather than silently, so this is a broken-guard
problem, not a false-negative problem. See "Why it matters" for why it still counts.

## What was measured

A parse check (`[Parser]::ParseFile`) run over the twelve scripts that carry non-ASCII
content on a code line, first under Windows PowerShell 5.1, then under PowerShell 7 to
isolate the launcher:

```
== under powershell.exe 5.1 (5.1.26100.8875) ==
PARSE-FAIL  detect-literal-credentials.ps1        10 error(s): Unexpected token '(' in expression or statement.
PARSE-FAIL  assert-no-staged-secrets.ps1           4 error(s): Missing '=' operator after key in hash literal.
PARSE-FAIL  assert-range-no-new-secrets.ps1        2 error(s): Missing '=' operator after key in hash literal.
PARSE-FAIL  redact-exposed-credentials.ps1         6 error(s): Unexpected token '(' in expression or statement.
parses ok   check-credential-state.ps1
parses ok   purge-credentials-from-history.ps1
parses ok   audit-doc-freshness.ps1
parses ok   smoke-full-stack.ps1
parses ok   test-document-generation-e2e.ps1
parses ok   test-handoff-command-safety.ps1
parses ok   test-install-repo-pull.ps1
parses ok   bump-release-version.ps1

== the same files under pwsh 7 ==
all twelve parse ok
```

So the failure is specific to the launcher, not to the files being malformed in some
absolute sense. On this dev box `pwsh` is the suite launcher, which is exactly why none
of this showed up in `run-all-checks.ps1`.

## Root cause

None of these files has a UTF-8 BOM, and **Windows PowerShell 5.1 decodes a `.ps1` without
a BOM using the ANSI code page** rather than UTF-8. CJK literals in the source are
therefore mis-decoded before the parser ever sees them.

The failure is not limited to regexes that simply stop matching. Three different
outcomes were measured, and the worst is a parse error:

1. **A CJK regex still matches, but captures corrupted text.** `'密码\s*[：:]\s*(?<v>[^\s|`]+)'`
   against the sample `密码：SuperSecret123` captures `歋uperSecret123` under 5.1 and
   `SuperSecret123` under 7 - the match succeeds and the value is wrong.
2. **A CJK placeholder list breaks the parser.** The line
   `if ($v -match '^(待填写|待补|xxx|\*+|-+|□+)$')` mangles into
   `'^(寰呭～鍐檤寰呰ˉ|xxx|\*+|-+|鈻?)$'`, and the mangled `?` plus the broken byte sequence
   terminates the string early:
   `The string is missing the terminator: "`.
3. **A CJK hash key breaks the parser.** `'cjk-密码' = '...'` produces
   `Missing '=' operator after key in hash literal.`

Categories 2 and 3 are what take the four scripts out entirely: the file does not parse,
so the whole guard does nothing on a 5.1-only machine.

## Why it matters

Three of the four are **credential and secret scanners** whose specific purpose is
detecting CJK-labelled credentials:

| script | role |
| --- | --- |
| `detect-literal-credentials.ps1` | finds literal credentials in docs; holds the `密码` / `登录名` / `密钥` rules |
| `assert-no-staged-secrets.ps1` | pre-commit style guard on staged content |
| `assert-range-no-new-secrets.ps1` | range-wide guard; exists to keep a known leak from spreading |
| `redact-exposed-credentials.ps1` | the redaction path for those findings |

`assert-range-no-new-secrets.ps1` was added precisely because of a real fork-embedded
secret, so its silent non-execution is the least acceptable of the four.

Two mitigating facts keep this off the release-blocking list:

- The scripts **fail loudly** when run under 5.1 (parser errors, non-zero exit) rather
  than passing quietly, so an operator who runs one sees it break.
- **None of the four is wired into `run-all-checks.ps1`**, so no gate was ever relying on
  them. That is also why the breakage went unnoticed: nothing executes them in CI or in
  the suite, in either launcher.

The reason to record it anyway is that the guards are what stands between a Chinese-labelled
credential and a commit, the client AIPCs are 5.1-only, and an unwired guard that cannot run
is indistinguishable from no guard.

## Not affected

- **`bump-release-version.ps1` had the same root cause and IS fixed** - see commit
  `9d31936`. Its write pattern and its verification now match the release heading
  structurally (`##[^\r\n]*?vX.Y.Z`) with no non-ASCII byte involved, proven under PS 5.1
  in a throwaway HEAD export. That one was release-critical: it silently left
  `README-ZH.md` at the previous release while reporting success.
- Scripts whose non-ASCII appears only in comments, or only in box-drawing characters in
  comments, parse and run fine. The 39 no-BOM scripts found by the scan are not 39
  breakages; four are.

## Fix, when it is picked up

Add a UTF-8 BOM to the four files. That is the minimal change: it makes 5.1 decode the
same bytes as 7 without touching a single regex or literal.

```
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
foreach ($f in @(
    'scripts/detect-literal-credentials.ps1',
    'scripts/assert-no-staged-secrets.ps1',
    'scripts/assert-range-no-new-secrets.ps1',
    'scripts/redact-exposed-credentials.ps1')) {
    $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($f, $t, $utf8Bom)
}
```

Two things worth doing at the same time, because the BOM alone does not stop a future
file from regressing:

1. A guard that parse-checks every `.ps1` under **both** launchers. The suite already
   knows how to fall back to `powershell.exe`; the check is the `[Parser]::ParseFile`
   call above, and it is cheap enough to run on all 90 scripts.
2. Wire the four credential guards into `run-all-checks.ps1`. They are currently
   unreferenced, which is the deeper problem: they were written to catch something and
   nothing executes them.

Note that adding a BOM changes files that other tooling may read; verify git's
`core.autocrlf` handling and the `.gitattributes` rules do not fight it before committing
the whole set.
