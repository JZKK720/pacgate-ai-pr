# Decision: this box does not cut releases (2026-11-08)

**Status:** adopted
**Scope:** this machine and this branch. Cutting a version and publishing images is upstream's job.

## The decision

Do not bump the version and do not dispatch an image build from this box. `0.2.33` is not ours to
ship. When the redactor fix needs to reach clients, it goes upstream and upstream cuts the release.

This was stated directly after the audit proposed `bump-release-version.ps1 -To 0.2.33` plus a build
dispatch. That proposal is withdrawn.

## Why this matters, and what it costs

`scripts/test-release-provenance.ps1` fails on this branch, and it is **correct** to fail:

```
FAIL  2 file(s) that CAN reach a built image changed after the published revision was built:
        pacgate-ai/crates/pacgate-redact/src/pipeline.rs
        pacgate-ai/crates/pacgate-redact/src/verify.rs
```

`v0.2.32` peels to `7a6dd73`, which is exactly the revision the published images report, so the tag
is internally consistent. But the redactor verdict fix (`9f0e0c8`) landed after it, so a rebuild from
`v0.2.32` would not reproduce what clients pull. That is the precise defect the gate exists to catch.

**This failure is accepted, not suppressed.** It is the honest signal that this branch carries an
unreleased change to a shipped artifact. It clears on its own once upstream cuts a release that
includes the fix. Do not:

- re-point or move `v0.2.32`
- add a skip, allowlist, or `-AllowUnreleased` flag to the gate
- bump the version locally to make the gate green

A green gate bought by any of those means the tag no longer describes the artifact, which is the
0.1.28 defect the gate was written from.

## Consequence for the knowledge base

The 397 blocked chunks stay blocked until a release carrying the fix is published and pulled. That is
the accepted cost of not cutting a release here. The fix is committed and tested; it is not lost, it
is waiting on upstream.

Measured state at the time of this decision, admin tenant `9fc20614`:

| | Value |
| --- | --- |
| Retrievable chunks | 473 of 868 (54.5%) |
| Blocked chunks | 397, across 4 documents |
| Blocked documents | `合规律师实用Prompts指南` (144), `基金律师实用Prompts指南` (108), `presented-pacgate-ai-平台实战教程` docx (73) + pdf (70), `SOUL_Justin_v1.0` (2) |

## What to do instead

1. Get the fix upstream. It is one commit (`9f0e0c8`) plus its tests, and upstream does not have it -
   verified against `upstream/main` directly.
2. Let upstream cut the release.
3. Pull the new images here, then re-sanitize the four blocked documents. `POST
   /api/documents/:id/sanitize` reopens a blocked document first, so it is a real recovery path, not
   a no-op.
