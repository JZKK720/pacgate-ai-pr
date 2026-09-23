# Solidify the current stack before the 2.1 upgrade

**Date:** 2026-09-22
**Status:** A DONE, B DELIVERED 2026-09-23 (`151d05b`). See "Outcome" below.
**Supersedes nothing.** Plan 023 stays valid; its execution start is deferred.

## Outcome (2026-09-23)

**A - currency restored.** `scripts/run-all-checks.ps1` reports **21/21 gates**,
and the numbers are published in `deploy/STACK-VERIFICATION-EVIDENCE-2026-09-22.md`.

**B - the artifact exists.** `scripts/test-legal-journey.ps1` proves the journey in
one command and fails loudly on the first broken step. It runs on the LIVE stack
and needs no scratch containers, unlike the boot-your-own-container E2E scripts.
Verified: **15 assertions pass** on 0.1.17 / revision `2a51fbd`.

**Two lanes are NOT yet proven, and the test says so rather than quietly passing:**

- **qm co-work** - the qm stack is not running on this box. SKIP, with the start
  command named.
- **OpenViking recall - this is a REAL GAP, not a test defect.** OpenViking is
  two-tier: the configured `root_api_key` is an ADMIN credential (200 on
  `/api/v1/admin/accounts`) while `/api/v1/search/recall` needs an ACCOUNT-USER
  key. The `default` account currently reports `user_count: 0`, so **no user is
  provisioned and the recall lane cannot work at all**. Provisioning one
  (`POST /api/v1/admin/accounts/{id}/users/{uid}/key`) is the unblocking step.
  This is a genuine finding about the shipped state, discovered by refusing to
  let a 403 read as "probably fine".

**Still open from this spec:** the clean-clone proof (see the standing rule - this
dev box masks clean-machine failures), and the human judgement pass on output
quality, which is explicitly not automatable.

## The decision

Freeze the deer-flow pin at `v2.0.0` and harden the stack we actually ship,
before spending effort on the 2.1 rebase. Upgrade later, from a proven base.

Evidence for freezing (measured 2026-09-22, not assumed):

- `ghcr.io/bytedance/deer-flow-backend:v2.1.0` -> **404**. There is no GA tag.
- `latest` -> `sha256:4f30bb45...`, **identical to `v2.1.0-rc0`**. Upstream's own
  `latest` is still a release candidate.

So "too early" is not a preference, it is the current state. The rebase target
does not exist yet. Deferring costs nothing measurable while that holds.

## Why the two halves are independent (this is the part that mattered)

The instinct to "harden qm + OpenViking first" is sound, and it is also FREE of
the upgrade: **2.1 would not have touched that pipeline.**

Our OpenViking integration is **MCP-based**, over
`extensions_config.json` + `DEER_FLOW_EXTENSIONS_CONFIG_PATH`. It is not a
memory backend. Pinned `v2.0.0` has no `manager_class` field at all, so there is
nothing for 2.1's `manager_class`/`backend_config` rework to migrate in that lane.
The memory-adapter migration in plan 023 §1.3 concerns the adapter that talks to
pacgate-api; it is a separate concern from OpenViking recall.

Consequence: hardening qm + OpenViking is not a deferral of the upgrade, it is
parallel work that stands on its own. It can ship in a `0.1.x` release with no
`FROM` change and no rebase.

## What is actually verified today, and what is not

The legal-work surface is real and larger than it looks from the scripts folder:

- 31 routes on pacgate-api (`/api/matters`, `/api/documents`, `/api/matters/:id/memory`,
  `/api/workflows`, `/api/tabular`, `/api/search`, `/api/kb/search`, sanitize/restore).
- 220 legal workflow templates + 30 personas, pre-loaded in the image.
- A working sanitizer pipeline: `sanitize.rs`, string-contract tests runnable
  without Postgres, and `scripts/test-sanitizer-e2e.ps1` drives
  matter -> upload -> extract -> sanitize -> status -> download -> restore.

So coverage is not absent. It is STALE. The last full-stack E2E evidence is
`plans/007-audit-smoke-report.md`, dated **2026-09-01**, recording
`smoke 23/23 - agent 5/5 - yaml 3/3 - TS 8/8 - integration 2/2`.

Since that report the stack has moved **six releases** (0.1.11 -> 0.1.17) plus
the auth-registration gate, the `/initialize` setup-token gate, and the upload
symlink guard. The suite passes on current HEAD, but nobody has re-proven the
**whole legal journey** against 0.1.17. That gap is the real risk, not a missing
feature.

A note on `scripts/test-sanitizer-e2e.ps1`: it targets `127.0.0.1:8097`, which is
not a shipped service port. It is a test-only binding (`-p 127.0.0.1:8097:8080`)
that the script creates itself. Anything citing "port 8097" as a component is
reading a harness detail as architecture.

## Scope

**A. Restore currency (do first, cheap).** Re-run the existing suites against
0.1.17 and publish the numbers. B is not credible without A, and A is the
cheapest way to discover that something already broke.

**B. Add the one missing artifact.** A single scripted legal-journey acceptance
test that a clean machine can run: matter -> upload -> OCR/extract -> sanitize ->
review -> search -> qm co-work -> OpenViking recall. This does not exist today,
and it is the difference between "the suites pass" and "the product works".

**Explicitly out of scope:** the 2.1 rebase, the memory-adapter migration, and
any `FROM`/pin change. Plan 023 resumes when GA lands; the GA watcher keeps that
trigger honest.

## Open decision (user unavailable, assumption flagged)

The acceptance bar for "perfectly functional" was asked and not answered. Proceed
on the recommendation: **A then B**, with B proven on a clean clone rather than
this dev box, per the standing rule for install-path work. If the intended bar is
instead a metadata/contract inventory (option C), that is additive and does not
invalidate A or B.

Not automatable: genuinely using the stack on a real matter and judging output
quality. That needs a human. What can be prepared is the matter and the runbook,
so the human's time goes to judgement rather than setup.

## Definition of done

- Suite results on 0.1.17 published, with any regression named rather than tuned
  away.
- One command proves the legal journey end to end, and fails loudly on the first
  broken step.
- The freeze is recorded where it will be read, so it is not rediscovered as
  drift.
- Nothing in this spec requires an image rebuild to deliver: patches and tests
  travel with the repo.
