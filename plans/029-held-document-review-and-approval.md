# Plan 029 — Held-document review: derived state + approval endpoint

**Date:** 2026-10-23
**Priority:** P1
**Effort:** ~2 hours (implemented and proven; this plan records the design)
**Depends on:** plan 028 (the T4 hold itself)
**Status:** **DONE 2026-10-23** — implemented, gate-tested, and proven end-to-end on the live stack. Released as 0.2.3.

---

## 0. The gap this closes

Plan 028 made `run_job` refuse to auto-pass a document when policy says
`allow_auto_pass == false` (T4 always does). The document stays at `pending`:
not downloadable, not searchable. That was the correct fail-closed behaviour, but
it left two problems:

1. **`pending` was ambiguous.** It meant both "never processed" and "processed,
   passed, and deliberately held". The review panel rendered both as "Pending",
   so a reviewer could not tell a document awaiting their decision from one
   nobody had touched.
2. **A held document had no path to release.** No approval endpoint existed
   anywhere in the router. The hold was a dead end, not a review gate. The only
   way out was re-running the job at a lower data level, which is a different
   decision (reclassifying the document) rather than approving it.

---

## 1. Design decision: derive the held state, do not store it

The obvious fix is a fifth state, `pending_review`. It was rejected.

| Option | Cost | Risk |
| --- | --- | --- |
| New `pending_review` state | migration + every egress gate + every state label | a second source of truth that can disagree with the ledger |
| **Derive `held_for_review`** | none | none — it is a function of data already stored |

A document is held **iff** a ledger row for it says `pass` **and** its
`sanitization_state` is still `pending`. That combination can only mean policy
refused to promote, because a passing job that was allowed to promote would have
written `sanitized`. So the flag is computed, not stored:

```rust
let held_for_review = doc_state == "pending"
    && sqlx::query(
        "SELECT 1 FROM redaction_ledger_rows \
         WHERE document_id = $1 AND tenant_id = $2 AND verdict = 'pass' LIMIT 1",
    )
    ...
    .is_some();
```

This cannot drift, needs no migration, and leaves the four-state model — and
every egress gate that depends on it — untouched. `pending` remains fail-closed.

---

## 2. The approval endpoint

`POST /api/documents/:id/approve` with `{"job_id": "..."}`.

### 2.1 Why the caller must name the job

Approving "whatever ran last" would let a job that ran *after* the reviewer
looked be silently blessed. The caller names the evidence it is approving, and
the server checks that evidence:

- the ledger row must exist for **this** job, **this** document, **this** tenant;
- the row's matter must match the document's matter (approval is matter-scoped);
- the verdict must be `pass` — **a Block is never approvable**, because a Block
  means the redaction could not be verified, and no human approval can make
  unverified redaction safe;
- the document must currently be `pending` — approving a `sanitized` document is
  a no-op that looks like an action, and `blocked` is a different decision.

### 2.2 Why approval re-runs the job instead of promoting the old result

The tempting implementation is "flip the state and rewrite the chunks from the
stored mapping". That would be a **second, weaker promotion path** — one that
could skip the verify stage or the delete-then-insert rewrite.

Instead, approval calls `run_job_approved`, which is `run_job_inner` with the
hold bypassed:

```rust
let held_for_review =
    !verdict_is_block && !outcome.decision.allow_auto_pass && approved_job_id.is_none();
```

Everything else is the ordinary job path: the same detectors, the same
`verify_reduced`, the same `reingest_sanitized_chunks`. The approval is recorded
in the audit row as `approved_job_id`, so the release names the evidence it was
based on.

A gate test asserts the handler does **not** call `reingest_sanitized_chunks` or
`MARK_SANITIZED_DOCUMENT_SQL` itself — if someone later "optimises" approval into
a direct promotion, that test fails.

### 2.3 Role gate

`role_may_approve` is defined as `role_may_restore` (admin | partner). Both
release sensitive content to a human, so both need the same authority. A
narrower gate on approval would be a way around restore.

---

## 3. Frontend

- `SanitizeStatusResponse` gained `held_for_review: boolean`.
- The review panel shows "Held for review" instead of "Pending" when the flag is
  set, plus an explanatory line.
- Labels added in **both** locales (`en-US`, `zh-CN`) and the `types.ts` contract,
  per the repo's bilingual parity rule.

---

## 4. Verification

### 4.1 Gate tests (mutation-tested)

| Test | Guards | Mutation that breaks it |
| --- | --- | --- |
| `an_approval_bypasses_the_hold_but_never_a_block` | the bypass is conditional on `approved_job_id` and never on a Block | dropping `&& approved_job_id.is_none()` → FAILED |
| `approval_refuses_a_block_and_a_non_pending_document` | Block refused, only `pending` approvable, role-gated | `if verdict != "pass"` → `if false` → FAILED |
| `approval_reuses_the_job_path_rather_than_a_second_promotion` | no direct chunk rewrite or state flip in the handler | — |
| `approval_is_role_gated_like_restore` | admin/partner only | — |
| `held_state_is_derived_not_stored` | the flag comes from the ledger | — |

`cargo test -p pacgate-api --lib`: **97 passed, 0 failed**.

### 4.2 Live proof on the HX370 stack

Built a Linux image locally (`pacgate-api:approve-test`) and deployed it via a
compose override, because the Windows release binary cannot run in the Linux
container.

```
1. Upload a clean document, sanitize at T4
   -> verdict=pass  chunks_promoted=0  job=9228eaa2-...

2. GET /sanitize-status
   -> state=pending  held_for_review=True        <-- the ambiguity is resolved
   GET /download -> 409                          <-- still fail-closed

3. POST /approve {"job_id":"9228eaa2-..."}
   -> state=sanitized  chunks_promoted=1

4. GET /sanitize-status
   -> state=sanitized  held_for_review=False  chunk_states=sanitized
   GET /download -> 200                          <-- released

5. POST /approve again
   -> 409 "document is 'sanitized'; only a held ('pending') document can be approved"

6. POST /approve on a Block-verdict job
   -> 409 "a Block verdict cannot be approved; the redaction could not be verified"
```

Step 6 used a real Block row already in the database, not a synthetic one.

---

## 5. What is still not done

- **No "list held documents" endpoint.** The panel shows the flag for a document
  it is already looking at; there is no way to ask "show me everything awaiting
  review". That needs a query over `documents` joined to
  `redaction_ledger_rows`, and is a separate piece of work.
- **No approval UI.** The endpoint exists and is proven; the review panel shows
  the held state but has no Approve button. Wiring it needs the panel to know the
  caller's role, which it currently does not receive.
- **Approval re-runs the job**, so it costs a full sanitize pass (seconds on a
  warm extraction cache, minutes on a cold one). Acceptable for a human-initiated
  action; would not be for a bulk operation.
