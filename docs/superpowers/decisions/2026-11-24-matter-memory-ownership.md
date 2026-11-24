# Decision: matter memory stays with pacgate-api; OpenViking is agent working memory (2026-11-24)

**Status:** adopted (direction); not yet implemented — blocked on the v2.2.0 adapter rewrite.
**Scope:** `deploy/client-bundle/`, `pacgate-adapters/python/pacgate_deerflow_adapter/`, `pacgate-ai/crates/pacgate-api`, `deploy/qm-pacgate/sandbox/tools/pacgate-qm/`

## The question

deer-flow v2.2.0 replaces the `storage_class` / `MemoryStorage` contract with a pluggable
`memory.manager_class` (`deermem` | `openviking` | `mem0` | `honcho`) configured via
`memory.backend_config`. That forces the choice: point deer-flow's memory at OpenViking, or keep a
pacgate-api-backed manager.

## Decision

pacgate-api (`/api/matters/:id/memory`, file-backed `memory.json` under the matter directory) remains
the only writer of matter memory. OpenViking remains the agent's scratch/working memory and the QM
sandbox's recall lane. Nothing else may write matter memory.

## Why

1. **One writer.** QM and deer-flow both reach pacgate-api today (insights: `pacgate-qm memory-get|save`,
   deer-flow `PacgateMemoryStorage`). Two writers against OpenViking would fork the matter's record.
2. **Revision semantics.** `memory.json` writes go through `memory_revision()` + atomic rename + `If-Match`
   semantics (`matters.rs`). OpenViking has no equivalent conditional-write for a matter-scoped document.
3. **Auditability and residency.** Matter memory is client-confidential and must live in the matter
   directory tree so it is covered by the same backup/export/deletion path as documents. OpenViking's
   store is shared, server-global, and its AGPL-3.0 terms are acceptable for a network service boundary
   but not as the system of record for client work product.
4. **Loss shape.** If OpenViking is wiped, the agent forgets scratch state. Acceptable. If it were the
   matter store, that would be data loss.
5. **Deletion / right to erasure.** Removing a matter is `rm -rf` of one directory plus a `documents` row
   delete. Splitting that across Postgres + OpenViking collections makes it unverifiable.

## Consequences

- The deer-flow adapter must be reimplemented against the 2.2.0 `MemoryManager` interface (class name,
  `backend_config` keys, `memory_type`, and the `memory.manager_class` config). Until that lands, the
  bundle stays on v2.0.0.
- The QM sandbox keeps calling `pacgate-qm memory-*`; no change.
- OpenViking holds no matter-of-record data; its upgrade risk is bounded to "agent forgets scratch".
- Any future proposal to move matter memory into OpenViking must supersede this file explicitly.

## What this does NOT decide

- Which `openviking` version to run (covered by `docs/runbooks/openviking-0.4.16-to-0.5.6.md`).
- Whether deer-flow's own `deermem` backend is used for *agent-local* memory (it is not wired today and
  stays off).
- Retention/encryption-at-rest for the bundle as a whole.

## Evidence

- `pacgate-ai/crates/pacgate-api/src/matters.rs` — `matter_memory_path`, `memory_revision`, atomic write.
- `pacgate-adapters/python/pacgate_deerflow_adapter/storage.py` — current `PacgateMemoryStorage`.
- `deploy/qm-pacgate/sandbox/tools/pacgate-qm/pacgate_qm.py` — `memory-get` / `memory-save` / `ov-*`.
- `deploy/client-bundle/openviking/ov.conf.template` — server config; no matter scoping.
