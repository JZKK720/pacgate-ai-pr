# DEFECT: sanitized chunks kept their RAW text under a `sanitized` label

**Severity: CRITICAL for a legal workspace.** The product reported a document
sanitized, redacted its text, then served the *unredacted* text to chat - through
the very retrieval gate the sanitizer had just approved.

**Found:** 2026-10-14, by `scripts/test-format-coverage-e2e.ps1` (the first gate that
followed sanitization all the way to what a reader actually receives).
**Root-caused:** 2026-10-14 on the live 0.1.30 stack, by direct DB and HTTP probes.
**Status: FIXED and RELEASED in 0.1.31** (`ChunkIngestor::reingest_sanitized_chunks`).
Proven by controlled A/B on the *published* images: the same gate and fixture return
`FAIL (4)` against 0.1.30 and `PASS` against 0.1.31.
**Existing rows are repaired by re-running the sanitize job**, which is what
`scripts/remediate-sanitized-chunk-egress.ps1` drives - this machine's 37 affected
documents were remediated and the audit now returns clean. See "Deploy implication".

## What was measured

A `.docx` containing `11010519491231002X` and `13812345678` is uploaded, extracted,
and sanitized through the public API. The sanitizer answers:

```
verdict = pass
redactions = 2
sanitized_text = "ID CARD: 00000000000000000X PHONE: [CN_MOBILE_120D0E42_2]"
```

The redaction is **correct**. Then the raw text is still reachable, three ways.

**1. The download serves the original bytes.**

```
GET /api/documents/<id>/download   -> HTTP 200, 36620 bytes
downloaded .docx text              -> 'ID CARD: 11010519491231002X\nPHONE: 13812345678'
RAW ID IN DOWNLOAD:     True
```

**2. The knowledge base hands the raw identifiers to chat.** This is the one that
makes it CRITICAL rather than an export-policy question, because it is the lane the
sanitizer *claims* to protect:

```
$ psql -c "SELECT c.sanitization_state, d.name, left(c.content,110)
           FROM kb_chunks c JOIN documents d ON c.document_id=d.id
           WHERE c.content ~ '[0-9]{17}[0-9Xx]'"

 sanitization_state | name |                   snippet
--------------------+------+----------------------------------------------
 sanitized          | case | 11010519491231002X                          +
                    |      | 13812345678
 sanitized          | case | 11010519491231002X                          +
                    |      | 13812345678
 ... (25 rows in this state carried a raw ID on this dev box)
```

**3. It is reachable through the product's own API.** `kb_search` is auth-gated
(401 unauthenticated) and tenant-scoped (403 across tenants), but a `Default Firm`
user who owns the matter gets the raw value back:

```
kb_search: HTTP 200
    rows=1
    doc=None score=0.580 content=['11010519491231002X\n13812345678']
    *** rows carrying the raw ID: 1 ***
```

## Root cause

The promote step asserted a verdict instead of performing it. It set a **state
flag** and left the text alone:

```sql
-- pacgate-api/src/sanitize.rs, MARK_SANITIZED_DOC_SQL (now deleted)
UPDATE kb_chunks SET sanitization_state = 'sanitized' \
WHERE tenant_id = $1 AND matter_id = $2 AND document_id = $3 \
  AND sanitization_state = 'pending'
```

and the RAG gate then *whitelisted* exactly those rows:

```rust
// pacgate-rag/src/lib.rs:306
sql.push_str(" AND c.sanitization_state IN ('sanitized', 'never')");
```

So the flag did not merely fail to protect anything - it was the **selection key
for the leak**. Rows correctly left `pending` were excluded from retrieval; rows
mislabeled `sanitized` were served.

The redacted rendering existed only in the HTTP response body and was never
persisted. `sanitized_text` has exactly two occurrences in the whole workspace -
its declaration and its assignment in `JobOutcome`. **Nothing ever reads it.**

## Why this was first recorded as a product decision, and why that was WRONG

The first write-up of this finding offered two readings and declined to choose,
arguing that `restore` existing at all suggested the current behaviour was
intentional. **That reasoning is retracted.** It was wrong on the evidence:

- **The design decided it.** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md`
  is explicit that the label means the content is clean:
  - the persistence table calls `kb_chunks` "**THIS is what general chat retrieves**";
  - chat is described as running "over already-**sanitized chunks**, so its inputs
    are already clean";
  - the OpenViking lane is called out as a hole, and the argument for accepting it
    is that "**what it summarises is already redacted**" - which only holds if the
    chunks are.
  There is no reading of the spec under which `sanitization_state='sanitized'` on
  raw text is intended.
- **`restore` is not evidence of intent here.** Restore takes the *sanitized* text
  and un-redacts it (`restore_document_handler` -> `mapping.restore(&req.text, ..)`).
  It is the privileged path back to the original, and it presupposes that the
  placeholder rendering is what was stored. It is evidence *for* the fix, not
  against it.
- **The "analysis lane" is the lane that leaked.** The reading that download is an
  export of the matter's own file is fine as a statement about *download*. It does
  not extend to RAG, which is not an export - it is what the agent quotes from.

The two readings were not equally defensible. One of them required believing the
product serves raw PII to its own agent on purpose.

## The fix

`ChunkIngestor::mark_sanitized` (flip a flag) is replaced by
`ChunkIngestor::reingest_sanitized_chunks` (replace the text):

1. read one row's `jurisdiction` / `source_level` / `data_level`, so the sanitized
   chunks keep the document's own classification;
2. chunk the job's **redacted** rendering with the same splitter ingest uses, so
   boundaries and `page` values stay meaningful;
3. **delete** the rows being replaced, which also drops their now-stale embeddings;
4. **insert** the redacted chunks already `sanitized` - the label is now earned at
   insert time, which is the property the old code could not have.

Delete-then-insert, in ONE transaction. Both halves of that are load-bearing:

- **One transaction** makes the intermediate state - old rows gone, new rows not yet
  written - invisible to any concurrent reader, so a RAG query can never observe a
  document with no chunks. A crash rolls the delete back and leaves the document
  exactly as it was.
- **Delete first** because the `DELETE` predicate accepts `'sanitized'` and the
  `INSERT` writes `'sanitized'`. The two overlap by construction, so insert-then-delete
  has the `DELETE` remove the chunks that were just written. MEASURED 2026-10-14:
  `promoted=1` and the document was left with **zero** chunks - the repair silently
  stripped its RAG coverage while reporting success. Delete-first is what an earlier
  version of this fix got wrong, and the gate only caught it because it counts total
  chunks as well as leaks.

`kb_chunks.content` feeds a generated `content_tsv`, so keyword search reindexes
itself; nothing else had to change.

## Remediation of already-poisoned rows - and the second defect found while proving it

The rewrite must be able to repair documents the old code damaged, not only write
correctly going forward. The first version of the selection used
`sanitization_state = 'pending'`, copied from the old promote statement's guard.

MEASURED 2026-10-14, against a real historical document (`bf29d6e3`): re-running the
sanitize job on it returned `chunks_promoted=0` and **left the raw text in place**.
The document's rows had been stamped `sanitized` by the buggy code, so a pending-only
filter matched nothing - the repair was a silent no-op, and the audit script's
advice to "re-sanitize it" was, at that moment, **wrong**.

The selection and the delete therefore both use
`sanitization_state IN ('pending', 'sanitized')`. `blocked` stays excluded in both:
that state is a deliberate refusal and must never be overwritten or removed.

Re-proven after the change, on historical document `50dc3aa7`: `1` raw hit before,
`0` after, **and `1` sanitized chunk remaining** - clean without losing coverage.
The stored text is now the redacted rendering (`00000000000000000X`,
`[CN_MOBILE_E8845383_2]`).

## Deploy implication - the part a version bump does NOT solve

The write path is forward-only, but because the selection now accepts `sanitized`
rows, **re-running the sanitize job is itself the remediation**. Existing rows that
0.1.28 through 0.1.30 mislabeled keep their raw text until that job is re-run on
them; no image upgrade rewrites them on its own. Any client machine that ran 0.1.28
or later and sanitized a document has affected rows.

Two remediations, both needing the operator to decide:

- **Re-sanitize the document.** The job now rewrites chunks properly, even for rows
  already mislabeled. Clean path, preserves retrieval coverage. This is the
  recommended one, and it is proven end to end.
- **Delete the affected rows**, removing the leak immediately at the cost of RAG
  coverage until re-sanitization. Safe degradation: no leak, reduced recall.

Before either, the affected set has to be counted.
`scripts/audit-sanitized-chunk-egress.ps1` reports it read-only.

Neither option works on 0.1.30 or earlier: that code has no rewrite path at all, so
re-running the job there is a no-op that changes nothing.

## Why no gate caught it

`test-sanitizer-e2e.ps1` asserted:

```powershell
Check "chunks sanitized" (($status.chunk_states -join ',').Trim() -eq 'sanitized')
```

It read the **state column** - the one thing the defective code did set. Every
other assertion ran on `job.sanitized_text`, the response field, which was always
correct. Nothing had ever read the text the retrieval gate would serve.

This is the seventh instance of the same shape in this codebase: the test asserted
what was easy to observe rather than the property that mattered. The gate now also
asserts the chunk **content** for both identifiers, asserts that sanitized chunks
exist at all (so "0 leaks" cannot be satisfied by having none), and asserts the raw
row is gone rather than merely unlabelled.

## Residual

- **Chunks are not versioned.** `kb_chunks` has no `document_version` column even
  though `redaction_ledger_rows` records one, so a job sanitizes whatever chunks the
  document currently has. `delete_for_document` runs on re-ingest, so in practice the
  chunks track the latest extraction and this is consistent - but a job running
  against an older version would now rewrite the newer text with that version's
  redaction. Pre-existing modelling gap, not introduced here; noting it because the
  rewrite makes it visible where the flag flip merely hid it.
- Download still serves the matter's **original**. That is a separate, narrower
  question from the one above - it is a genuine export-policy decision, since a
  redacted `.docx` is not the executed contract. It is no longer concealable behind
  "the analysis lane is protected", because that lane is what was broken.
- Only the seven accepted formats were probed. A format reaching storage by another
  path (import or migration) is unmeasured.
- The stored artifact has no version marker tying it to the sanitization that
  approved it, so nothing detects a file edited after sanitization.
- **Remediation requires a re-run per document.** There is no bulk repair endpoint;
  `audit-sanitized-chunk-egress.ps1` names the affected documents and an operator (or
  a small loop) re-runs `POST /api/documents/:id/sanitize` on each. On a machine with
  a large affected set that is a manual pass, and it re-embeds each document. A batch
  entry point would be the natural follow-up, but it is a new surface and was not
  invented here.
- **The repair re-embeds the whole document.** Chunks are rewritten wholesale, so a
  document with 200 chunks makes 200 embedding calls to fix one leaking row. Correct,
  but a bulk remediation of many documents is load-proportional, not leak-proportional.
