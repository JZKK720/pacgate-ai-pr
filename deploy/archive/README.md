# deploy/archive/ — retired documents

Nothing in this directory is active. These files were **superseded**, are
**frozen snapshots**, or describe a **release that has shipped and moved on**.
They are kept only so an operator can consult the reasoning behind an old
decision, and because `git mv` preserves the history.

**Do not cite these as current instructions.** No gate, script, workflow, or
compose file reads them. If you find yourself following one, stop and use the
live document named in its row.

## Why these are here

They were removed from the `deploy/` root on 2026-09-27 because they were being
read as current. The specific hazard: several carried **stale version pins and
stale revision markers**, so an operator following them would verify the wrong
release (for example asserting `{"version":"0.1.17"}` on a 0.1.20 machine) and
conclude a correct install was broken.

## What to use instead

| Retired document | Superseded by |
|---|---|
| `AIPC1-HANDOFF-PROMPT-v2.md` | `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`, `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md` |
| `AIPC2-HANDOFF-PROMPT-v2.md`, `AIPC2-HANDOFF-PROMPT.md` | `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` |
| `HANDOFF-AIPC-0.1.17.md` | `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` |
| `CONTINUE-HERE-2026-09-23.md` | `deploy/PLANS.md`, the active `plans/` entries |
| `CONTINUE-FROM-OTHER-MACHINE.md` | `README.md`, `deploy/DEPLOYMENT-GUIDE.md` |
| `RUNBOOK-ROTATE-SYNC-RELEASE-PURGE.md` | `deploy/SETUP-AND-OPERATIONS.md` |
| `GHCR-MASTER-BUILD-AUDIT.md` | `plans/011-ghcr-master-release.md`, `plans/012-master-release-namespace.md` |

The two handoff prompts were already flagged as wrong by the repo's own
`deploy/PLAN-CORPUS-AUDIT.md`: they pointed AIPC #2 at the layer branch and the
pre-`jzkk720` namespace.

## Sweep 2026-11-27 — point-in-time records

The 2026-09-27 sweep retired documents that were *misleading*. This sweep used a
narrower bar: **documents with zero inbound references from any live script,
gate, workflow, compose file, or source comment.** Everything below is a dated
audit, benchmark, handoff, incident, or regression record — historically useful,
never an instruction. Nothing here is cited by tooling; that was verified with a
full-tree reference index before each move.

Dated records are grouped rather than tabulated because their "superseded by" is
simply whatever shipped next. For all of them, the live sources are
`deploy/AIPC-DEPLOYMENT-HANDBOOK.md`, `deploy/SETUP-AND-OPERATIONS.md`,
`deploy/DEPLOYMENT-GUIDE.md`, and `plans/`.

| Retired document | Kind |
|---|---|
| `AIPC-0.2.37-AUDIT-AND-BENCHMARK.md`, `AIPC-HX370-CAPACITY-VERDICT-2026-10-20.md` | aipc |
| `AUDIT-2026-10-21-v0.1.34.md`, `AUDIT-2026-11-08-round-trips.md`, `AUDIT-AND-BENCHMARK-2026-10-23-v0.2.3.md`, `AUDIT-CORRECTION-2026-10-15-document-generation.md`, `AUDIT-E2E-2026-10-06.md`, `AUDIT-OUTCOME-2026-10-15-generation-and-skills.md`, `AUDIT-TOOLS-2026-10-14.md`, `E2E-AUDIT-2026-10-21-v0.1.34.md` | audit |
| `BENCHMARK-2026-10-25-0.2.6.md`, `BENCHMARK-2026-10-29-0.2.7.md`, `BENCHMARK-REPORT-2026-09-29.md`, `BENCHMARK-REPORT-2026-10-08-E2E-LOCAL.md`, `BENCHMARK-REPORT-2026-10-09-0.1.25.md`, `BENCHMARK-REPORT-2026-10-09-v0.1.25.md`, `BENCHMARK-REPORT-2026-10-10-REGRESSION-AUDIT.md`, `BENCHMARK-REPORT-2026-10-13-v0.1.27.md`, `BENCHMARK-REPORT-2026-10-13-v0.1.28.md`, `BENCHMARK-REPORT-2026-10-14-v0.1.29.md`, `BENCHMARK-REPORT-2026-10-15-0.1.31.md`, `BENCHMARK-REPORT-2026-10-21-v0.1.34.md` | benchmark |
| `DEFECT-cjk-findin-panic-and-mcp-timeouts.md`, `DEFECT-initialize-bootstrap-token.md`, `DEFECT-ocr-weights-not-baked.md`, `DEFECT-pdf-read-pip-install-hang.md`, `DEFECT-redactor-blocks-on-public-entities.md`, `DEFECT-release-tag-provenance.md` | defect |
| `HANDOFF-AIPC-GENERAL.md`, `HANDOFF-UPSTREAM-RELEASE-0.1.21.md`, `HANDOFF-UPSTREAM-SHORT.md`, `HANDOVER-AIPC-UPGRADE-0.1.31.md` | handoff |
| `ADOPTABILITY-AUDIT-2026-10-18.md`, `AUTH-ASSIGNED-USERS-DESIGN.md`, `CLEAN-CLONE-PROOF-LOG.md`, `CONCURRENCY-AND-VRAM-2026-10-21.md`, `DEV-MACHINE-CLEAR-ANALYSIS.md`, `EXTERNAL-REPO-AUDIT-AND-STACK-ROUNDTRIP-2026-11-24.md`, `MODEL-REGRESSION-AND-CAPACITY-2026-10-21-v0.1.34.md`, `MULTI-USER-ARCHITECTURE-PLAN.md`, `PRODUCTION-READINESS-2026-10-14.md`, `REINSTALL-AND-BENCHMARK-2026-10-19.md`, `RELEASE-PLAN-0.1.32.md`, `RUNTIME-VALIDATION-2026-10-11-v0.1.27.md`, `SMOKE-FULL-STACK-2026-10-15-0.1.31.md` | record |
| `REGRESSION-REPORT-2026-10-14-v0.1.29.md` | regression |

### Note on three documents this README previously kept

`AUTH-ASSIGNED-USERS-DESIGN.md`, `MULTI-USER-ARCHITECTURE-PLAN.md`,
`QM-BRINGUP-RUNBOOK.md` and `QM-BRINGUP-AUDIT-2026-09-21.md` were recorded in the
previous revision of this README as "candidates for a future sweep" that were
deliberately **not** retired, on the grounds that they are not misleading. That
judgement still holds; they are retired here only because this sweep's bar was
"zero inbound references", which they also meet. `auth.rs` and `plans/` remain the
live source of truth for assigned-users behaviour and multi-user architecture.

## Graph artifacts

`graph.html`, `GRAPH_REPORT.md`, `graphify-graph.json` and
`knowledge-graph.json` are a **frozen 2026-08-28 graphify output** that was
committed at the `deploy/` root. The generator writes to
`pacgate-ai/crates/graphify-out/` instead, which is where
`deploy/DEPLOYMENT-GUIDE.md` documents the output. Regenerate rather than reuse
these. `deploy/COPILOT_CONTEXT.md` is a hand-written context file that still
exists and was **not** retired; only its one-line pointer to
`knowledge-graph.json` was updated.

## Deliberately NOT retired

These were considered and kept, so the decision is recorded rather than
rediscovered:

- `DEFECT-workflow-mount-wrong-service.md` — still referenced by three gates
  (`test-workflow-compose-wiring.ps1`, `test-workflow-compose-wiring-mutations.ps1`,
  `test-workflow-library-served.ps1`). Removing it would break them.
- `AIPC-UPDATE-GAP-ANALYSIS.md` — referenced by the active plan
  `plans/014-unattended-aipc-updates.md` as evidence.
- `safe_markdown_to_pdf.py`, `safe_clarification_html_to_pdf.py`,
  `safe_clarification_board_to_pdf.py`, `extract_pdfs.py` — live tooling that
  `plans/008-refine-user-manuals-bilingual-mermaid-pdf.md` documents with
  **root-relative** invocations and line-number citations, so moving them would
  invalidate that plan. Tidier tree, real cost: not worth it.
- `HANDOFF-SYNC-TO-ORIGIN-MAIN.md` — **deliberately kept by the 2026-11-27 sweep
  too.** It is linked from `docs/superpowers/plans/2026-11-08-push-local-commits.md`
  and cited by `scripts/audit-post-deploy.ps1`, and
  `plans/2026-11-14-cut-0.2.35-to-close-the-release-gap.md` instructs that its
  "one thing 0.2.34 does not contain" section be **rewritten, not deleted**.
  Archiving it would dangle a link and destroy a document a plan still owns.
- `LOCAL-MODEL-PICKER-74B.md` — kept for the same reason: linked from three
  `docs/superpowers/` documents and cited by `scripts/regen-local-model-override.py`
  as the justification for the local-model override it generates.
- `DEFECT-summarization-treadmill.md` — kept: the 74B threshold reasoning is cited
  by `docs/superpowers/decisions/2026-11-08-billion-context-evaluation.md`.
- `DEFECT-ps51-cjk-literal-parse-failure.md` — kept: the ASCII-only rule it explains
  is cited by three comment blocks in `scripts/detect-literal-credentials.ps1`, and
  the rule is live in that script's regexes.
- `AUTH-ASSIGNED-USERS-DESIGN.md`, `MULTI-USER-ARCHITECTURE-PLAN.md`,
  `QM-BRINGUP-RUNBOOK.md`, `QM-BRINGUP-AUDIT-2026-09-21.md` — **retired by the
  2026-11-27 sweep above.** They were kept by the 2026-09-27 sweep on the grounds
  that they are not misleading, which is still true; the newer sweep used a
  different bar (zero inbound references), which they also met. See the note in
  the 2026-11-27 section.
