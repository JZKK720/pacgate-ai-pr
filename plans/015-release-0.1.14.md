# 015 — 0.1.14 release is BUILT but NOT PUBLISHED

Priority: **P1** · Status: **BLOCKED on one manual GitHub action**
Depends on: 012 (namespace), 014 (unattended updates)

## Where things stand (2026-09-17)

Everything is bumped, committed and pushed. The images are **not published** and
the local gates say so honestly (2 red, both reporting 404 for 0.1.14).

| Item | State |
| --- | --- |
| Version bump to 0.1.14 (25 edits / 4 files + handbook) | ✅ pushed (`04df497`) |
| Tests de-hardcoded to derive the version | ✅ pushed |
| **Workflow validity bug fixed** | ✅ pushed (`927bf93`) |
| `GHCR_MIRROR_NAMESPACE` repository variable | ✅ created (`jzkk720`) |
| Upstream + fork in sync | ✅ `927bf93` |
| Tag `v0.1.14` | ⚠️ exists, but on `04df497` - the commit where the workflow was invalid |
| **Images published** | ❌ **404 on all four** |

## The one action required

The tag `v0.1.14` was created on `04df497`, which is BEFORE the workflow fix.
Pushing that tag triggered runs #16/#17/#18, and all three died immediately with:

```
Invalid workflow file: .github/workflows/build-ghcr.yml#L1
(Line: 322): Unrecognized named-value: 'env'
```

A job-level `if:` referenced the `env` context, which is not one of the
github/needs/vars/inputs contexts available there. GitHub **rejects the whole
file**, so `build-and-push` - which had worked for 0.1.13 - never ran. The tag
therefore points at a commit that can never produce images.

### Do this

Re-point the tag to the fix (`927bf93`). GitHub cannot move a tag, so:

```powershell
# 1. Delete the tag (it produced nothing; no artifacts are lost)
git push https://github.com/pacgate-ai/pacgate-ai-pr.git :refs/tags/v0.1.14

# 2. Re-create it at the fix - from a machine whose credential can write the
#    pacgate-ai fork (this dev box authenticates as JZKK720, which is denied)
git tag v0.1.14 927bf93
git push https://github.com/pacgate-ai/pacgate-ai-pr.git refs/tags/v0.1.14
```

Or via the UI: Tags -> `v0.1.14` -> Delete, then Releases -> Draft a new release
-> tag `v0.1.14`, target `927bf93` -> Publish.

The tag push is the trigger, so creating it fires the build automatically.

### Then

1. Watch the run. It should build all four images (~9 min).
2. **Flip any new package to public** in the GHCR UI - new packages default
   PRIVATE, and a private package's only symptom is a failed anonymous pull.
3. Verify: `pwsh -File ./scripts/verify-delivery-state.ps1` -> ALL CHECKS PASSED.

## Why the local gate suite is red right now

Both failures are CORRECT and are the de-hardcoding working as intended:

- `verify-delivery-state.ps1` reads the version from `Cargo.toml` (0.1.14),
  confirms all eight compose pins and the manifest agree, and reports 404 for
  each image. That is the true state.
- `test-version-marker-against-image.ps1` derives its image tag from the manifest
  and cannot pull `pacgate-ai/pacgate-api:0.1.14`.

Neither is a bug. Both turn green the moment the images publish.

## The real lesson from this release

The release failed because of ONE expression in a job guard, and the blast radius
was the entire pipeline rather than the one job. Nothing local could catch it:
the file parses as YAML, and every string-grep check found the words it looks
for. `scripts/check-workflow-validity.ps1` now covers structural validity, and
`scripts/test-workflow-validity-mutations.ps1` proves it fails on the real
outage by reverting the guard to `env`.

Building those two found three further bugs of the same family - a `needs:` scan
that matched zero lines (a .NET `$`-vs-CRLF anchoring error, so it passed
vacuously), a mutation harness that could not report its own failure (`-not` on a
non-empty array is always `$false`), and a namespace test that asserted the
broken form of the guard. All three are fixed and mutation-tested.
