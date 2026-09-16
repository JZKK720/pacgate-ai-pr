# 015 — 0.1.14 release

Priority: **P1** · Status: **RELEASED — all four images published and verified**
Depends on: 012 (namespace), 014 (unattended updates)

## Released (2026-09-17)

Run **#19**, dispatched with `tag=0.1.14` on branch `main`.

| Item | State |
| --- | --- |
| Version bump to 0.1.14 (25 edits / 4 files + qm handbook pin) | ✅ `04df497` |
| Tests de-hardcoded to derive the version | ✅ `04df497` |
| Workflow validity bug fixed | ✅ `927bf93` |
| Image test no longer requires the old version | ✅ `5925857` |
| `GHCR_MIRROR_NAMESPACE` repository variable | ✅ created (`jzkk720`) |
| Upstream + fork in sync | ✅ `5925857` |
| **All four images at 0.1.14, publicly pullable** | ✅ **200 on all four** |
| `:latest` in sync with the version tag | ✅ all four |
| Binary reports `0.1.14` + revision `9cd8484` | ✅ from the real image |

Verified with: `verify-delivery-state.ps1` (ALL CHECKS PASSED),
`report-ghcr-digests.ps1` (`:latest` in sync on all four),
`test-version-marker-against-image.ps1` (5/5 against the published image),
`run-all-checks.ps1` (**18 of 18 gates**).

## How it shipped, and why not the obvious way

The tag `v0.1.14` was created on `04df497` — the commit where the workflow was
**invalid** — so its push triggered runs #16/#17/#18, all of which died at parse
time and produced nothing. That commit can never produce images.

The plan was to move the tag, but **GitHub disables "Delete tag" for a tag with a
published release**, so it cannot be re-pointed without deleting the release
first. The cleaner path was taken instead: dispatch the workflow with
`tag=0.1.14` while building from `main`. The dispatch input sets the image tag and
the build runs from a ref that has the fix.

That is the better mechanism anyway — it decouples "which tag to publish" from
"which commit to build", which is exactly the split the broken tag forced.

## The outage this release exposed

```yaml
jobs.mirror-upstream.if: ${{ env.GHCR_MIRROR_NAMESPACE != '' }}
```

`env` is **not** an available context in a job-level `if:` — only `github`,
`needs`, `vars`, `inputs` are. GitHub rejects the entire workflow file, so
`build-and-push` — which had worked for the 0.1.13 release — never ran at all.

The blast radius is the lesson: a guard added to a **new optional job** took down
the **existing required one**, because an unevaluable expression invalidates the
whole pipeline rather than the single job. It was invisible locally — the file
parses as YAML and every string-grep check found the words it looks for.

Now guarded by `check-workflow-validity.ps1` (YAML parse, job-level `if:` context
rules, `needs:` target existence), and `test-workflow-validity-mutations.ps1`
proves the check fails on the real outage by reverting the guard to `env`.

## Building that guard found five more defects

All the same family — **a check reporting success because the thing it inspected
went away**:

1. `test-workflow-namespace.ps1` asserted the BROKEN form (`env.`), so the fix
   looked like a regression.
2. A `needs:` scan that matched **zero lines**: in .NET, `$` in Multiline mode
   matches before `\n`, not before `\r`, so with CRLF the anchor can never match.
   It scanned nothing and passed.
3. The mutation harness could not report its own failure: `Write-Output ''` writes
   to the *success* stream, so callers received `@('', $False)`, and `-not` on a
   non-empty array is always `$false` — all three mutation suites exited 0
   regardless of failures.
4. A coverage marker that a comment could satisfy (`/version`).
5. `test-version-marker-against-image.ps1` required the OLD version in the
   response body, so it reported a healthy release as broken.

Two of my own mutations were also wrong rather than the check:
`mirror-upstream:::` is **valid** YAML (it just renames the job), and a
double-escaped regex matched nothing and surfaced as an unapplied mutation.

## Follow-up

- **The mirror job has still never actually mirrored.** `GHCR_MIRROR_PAT` is not
  set, so `mirror-upstream` skipped with a warning. Add a PAT with
  `write:packages` for `jzkk720`, then flip the resulting packages to public —
  new GHCR packages default PRIVATE and the only symptom is a failed anonymous
  pull.
- The tag `v0.1.14` remains at `04df497` and produces nothing. Harmless but
  misleading; deleting the release and re-pointing the tag would tidy it.
