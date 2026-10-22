# DEFECT: four credential-guard scripts cannot be parsed by Windows PowerShell 5.1

**Status:** FIXED 2026-10-15. All four scripts are now ASCII-only and parse under both
launchers, and `detect-literal-credentials.ps1` is registered in `run-all-checks.ps1` so
the class cannot regress unnoticed. Found 2026-10-14.

**Severity:** higher than first recorded. The original note said the scripts "fail loudly
rather than silently, so this is a broken-guard problem, not a false-negative problem".
**That is wrong, and it was measured on 2026-10-15:** a BOM-less `.ps1` holding a CJK hash
key, run as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File bad.ps1`, prints its
parser errors and then **exits 0**. Any caller that keys on the exit code - a gate, a
pre-commit hook - reads a completely dead guard as PASS. This is a **fail-open** defect,
not a loud one.

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

- The scripts print parser errors when run under 5.1, so an operator watching the OUTPUT
  sees it break. **But the exit code is 0** (measured 2026-10-15), so an operator watching
  the STATUS - or a gate reading `$LASTEXITCODE` - does not. See the fail-open note above.
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

## Fix applied (2026-10-15)

**Chosen approach: convert to ASCII-only, not add a BOM.** The original recommendation was
a UTF-8 BOM, which is minimal and correct. It was rejected for a concrete reason: a BOM is
a single leading byte sequence that any editor rewrite, `Set-Content`, or git filter can
silently drop, and its loss is invisible until someone runs the script on a 5.1 machine.
Every other client-facing script in this repo is ASCII-only for exactly this reason
(`test-compose-healthchecks.ps1`, `test-ps51-native-stderr.ps1`). ASCII-only has no
dependency on the file's encoding at all.

Changes, all five credential scripts (the four failing plus `check-credential-state.ps1`,
which parsed but held CJK literals and the same `Get-Content` defect):

| Change | Why |
| --- | --- |
| CJK regexes written as `\u5BC6\u7801` escapes | .NET regex expands `\uXXXX`; the file stays ASCII |
| Rule NAMES rewritten to ASCII labels (`cjk-password`) | single-quoted PowerShell strings do NOT expand `\uXXXX`, so escape-names would print literally |
| Placeholder lists as `\u5F85\u586B\u5199` escapes | avoids the string-terminator parse error (category 2 above) |
| Target PATHS escaped and expanded via `[regex]::Unescape()` | paths must resolve at runtime, and 5.1 cannot read a raw CJK string from a BOM-less file |
| `Get-Content -Encoding UTF8` in the detector | **separate latent bug**: 5.1 defaults to the ANSI/GBK codepage, so a UTF-8 CJK label arrived as mojibake and every CJK rule missed while reporting CLEAN, exit 0 |
| `exit 1` on findings | the detector had no exit statement at all and always returned 0 - it could not have failed CI even with a correct rule |
| Registered in `run-all-checks.ps1` | it was never executed by anything, which is why this went unnoticed |

Red-checked on both launchers: a staged `密码：<secret>` and a `| Password | \`<secret>\` |`
row are each detected (exit 1) by `assert-no-staged-secrets.ps1` and
`assert-range-no-new-secrets.ps1` under **powershell.exe 5.1**, and the detector finds a
planted CJK credential on both. Before the change those cases were PARSE-FAIL/exit 0.

Still worth doing, because ASCII-only does not stop a future file from regressing:

1. A guard that parse-checks every `.ps1` under **both** launchers. The suite already
   knows how to fall back to `powershell.exe`; the check is the `[Parser]::ParseFile`
   call above, and it is cheap enough to run on all 90 scripts. This is the check that
   would have caught the defect the day it was introduced.
2. `detect-literal-credentials.ps1` is now wired into `run-all-checks.ps1`.
   `assert-no-staged-secrets.ps1` and `assert-range-no-new-secrets.ps1` are still
   unreferenced by the suite - they are pre-commit/range guards, so the right place for
   them is a git hook or the release script, not this runner. Until they are called from
   somewhere, they remain "a guard nothing executes", which is the deeper problem: they
   were written to catch something and nothing runs them.

