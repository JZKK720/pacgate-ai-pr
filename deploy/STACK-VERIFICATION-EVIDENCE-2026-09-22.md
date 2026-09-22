# Stack verification evidence — 2026-09-22

**Purpose:** restore currency on the stack we ship, before any 2.1 work.
Supersedes `plans/007-audit-smoke-report.md` (2026-09-01) as the current record.
**Design:** `docs/superpowers/specs/2026-09-22-stack-hardening-before-2.1-design.md`

## Why this exists

The last full-stack evidence was 2026-09-01, at `smoke 23/23 · agent 5/5 ·
yaml 3/3 · TS 8/8 · integration 2/2`. Since then the stack moved six releases
(0.1.11 -> 0.1.17) plus the auth-registration gate, the `/initialize` setup-token
gate, and the upload symlink guard. The suites passed; the **legal journey** had
not been re-proven on 0.1.17. This closes that.

The 2.1 upgrade is deliberately deferred: `v2.1.0` returns **404** upstream and
`latest` still resolves to the `v2.1.0-rc0` digest, so the rebase target does not
exist yet. Deferring costs nothing while that holds.

## Results — current release, all green

| Suite | Result | What it actually proves |
| --- | --- | --- |
| `cargo test -p pacgate-api` | **37 pass** (12 lib + 23 smoke) | API surface, string contracts, no DB |
| `cargo test --test integration -- --ignored` | **2 pass** | Real Postgres: register, login, matter, upload, versions, egress gate, cross-tenant isolation |
| `test-sanitizer-e2e.ps1` | **PASS (17 checks)** | The legal document flow, end to end |
| `test-sanitization-gate.ps1` | **ALL ASSERTIONS PASSED** | Chunk gate + NULL fail-closed |
| `test-ocr-extraction.ps1` | **PASS** | OCR text + spans with page/coords |
| `audit-qm-bootstrap.ps1` | **9/9** | qm env/bring-up |
| `test-qm-restage.ps1` | **13 pass** | qm restage |
| `test-qm-mutations.ps1` | **9 pass** | qm mutation coverage |
| `test-qm-sandbox-fingerprint.ps1` | **25 pass** | sandbox image drift |
| `run-all-checks.ps1` | **18/18 PASS, exit 0** | the full gate suite |

### The legal journey, itemised

`test-sanitizer-e2e.ps1` drives a real container with ocr-service attached and
passes every step, so this is measured rather than asserted:

```
PASS: matter created
PASS: upload ok
PASS: extract returned text
PASS: sanitize verdict pass
PASS: id card redacted          <- 11010519491231002X gone
PASS: phone gone                <- 13812345678 gone
PASS: mapping sealed server-side
PASS: document state sanitized
PASS: chunks sanitized
PASS: download allowed post-sanitize
PASS: restore refused for attorney role
PASS: admin restore returns originals
PASS: ledger row written
PASS: audit row written
```

That is the whole chain: a document goes in, gets extracted, gets sanitized with
real redactions, the gate opens only afterwards, restore is role-gated, and the
ledger and audit rows are written. Metadata and legal-work behaviour are
functional on the shipped release.

## THE DEFECT THIS PASS WAS WORTH DOING FOR

**The legal workflow library was mounted into the wrong service.** The product was
serving 10 built-in English workflows instead of the firm's 222-template Chinese
library. Full record: `deploy/DEFECT-workflow-mount-wrong-service.md`.

| | before | after |
| --- | --- | --- |
| `WORKFLOWS_DIR` | *(empty)* | `/app/workflows` |
| `/app/workflows` | does not exist | 15 files |
| `GET /api/workflows` | **10** | **222** |

Fixed in `b7fc540` (compose), guarded by `scripts/test-workflow-library-served.ps1`
(`76785db`), which is proven to fire: 222/exit 0 on the fixed stack, 10/exit 1 on a
probe reproducing the defect.

Three things worth carrying forward from it:

- **It was invisible.** A missing mount and a missing env var both yield a
  well-formed 200 with plausible content. Only a count or the language of the
  titles distinguishes library from fallback. No existing suite could see it:
  `check-workflow-validity.ps1` validates the repo YAML (always fine) and
  `test-workflow-namespace.ps1` checks pins. Both pass while the API serves the
  wrong set.
- **`plans/006`'s "220 templates" was right.** The number was real and reachable -
  just never through the API. Good example of a true claim that looked false.
- **The 2.1 upgrade would not have fixed it.** Ours, in compose, independent of the
  pin. Found by auditing the metadata surface against the live stack rather than
  reading the docs, which is the point of this pass.

## Two more defects found and fixed while doing this

Both were in TEST code, which is itself the finding: they had been failing
silently because they were unreachable or unrunnable.

1. **The gated integration test contradicted the egress gate** (`59313fe`).
   `GET /api/documents/:id/download` returns 409 for an unsanitized document by
   design (design 5.1), and the test asserted 200 with exact bytes. It had been
   FAILING, unnoticed because it is `#[ignore]`d. It now asserts the 409 - which
   is real new coverage, the gate had no assertion in that suite.

2. **A gated read used for a content assertion.** The docx section downloaded
   over HTTP to check accepted text; same gate, same 409. Now reads through
   `doc_state.doc_store.download_bytes` - the same method the route calls after
   its gate - so the content check survives and the gate is asserted once, where
   it belongs.

## Harness gaps worth knowing (not product bugs)

These cost real time and will cost it again to the next person:

- **`test-sanitizer-e2e.ps1` requires two hand-built local image tags that do not
  exist on a clean machine:** `ocr-service:local` and `pacgate-api:plan020-test`.
  Both are absent after a normal pull, and the failure mode is a silent
  "api boots: FAIL" followed by 10 cascading failures with no hint that an image
  is missing. Aliasing the published images is sufficient and non-destructive:

  ```powershell
  docker tag ghcr.io/jzkk720/ocr-service:0.1.17    ocr-service:local
  docker tag ghcr.io/jzkk720/pacgate-api:0.1.17    pacgate-api:plan020-test
  ```

  Worth turning into either a documented prerequisite or a preflight check that
  names the missing tag. As-is, a clean machine reports 11 failures that look
  like product regressions.

- **The integration test needs `scripts/bootstrap-integration-postgres.ps1`** to
  create the test DB on `localhost:5435`. Without it the test silently reports
  `2 ignored` and passes - green on nothing. Run the bootstrap first.

- **The test DB role is `hermes`, not `pacgate`.** Probing the *prod* DB needs
  `-U pacgate`; probing the *test* DB needs `-U hermes`. Using the wrong one gives
  `role does not exist`, which reads like a missing database.

## What is NOT verified

- **Genuine output quality on a real matter.** The pipeline is proven to run and
  redact correctly on a fixture; whether its analysis is good on real work needs
  human judgement. Not automatable.
- **The qm co-working surface and OpenViking recall in one continuous run.** Both
  have dedicated suites that pass (qm 13/9/25; OpenViking via the MCP lane), but
  there is no single scripted journey that walks qm + OpenViking + deer-flow
  together. That is item B and it does not exist yet.
- Anything about 2.1 - intentionally. That work resumes when GA lands.

## Standing rule reminder

Per the repo's install-path rule, any of this that changes a *deploy* path must be
re-proven on a **fresh clone**, not this dev box. This dev box accumulates
credentials, pulled models, and rendered gitignored configs, which hides failures
a clean AIPC would hit. The suites above were run here and are green here.
