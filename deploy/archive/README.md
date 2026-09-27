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
- `AUTH-ASSIGNED-USERS-DESIGN.md`, `MULTI-USER-ARCHITECTURE-PLAN.md`,
  `QM-BRINGUP-RUNBOOK.md`, `QM-BRINGUP-AUDIT-2026-09-21.md` — no inbound links,
  so they are *candidates* for a future sweep, but they describe architecture
  that has not changed. They are not misleading, which was this sweep's bar.
