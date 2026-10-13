# DEFECT: sanitized documents are downloadable in their ORIGINAL form

**Severity: CRITICAL for a legal workspace.** The product reports a document
sanitized, redacts its text, then hands out the unsanitized file.

**Found:** 2026-10-14, by `scripts/test-format-coverage-e2e.ps1` (the first gate that
followed sanitization all the way to what a reader actually receives).
**Status:** root-caused and reproduced on the published 0.1.29. **Not fixed** - see
"Why this is recorded rather than patched", because the correct behaviour is a
product decision, not a code change I should make unilaterally.

## What was measured

A `.docx` containing `11010519491231002X` and `13812345678` is uploaded, extracted,
and sanitized through the public API. The sanitizer answers:

```
verdict = pass
redactions = 2
sanitized_text = "ID CARD: 00000000000000000X PHONE: [CN_MOBILE_120D0E42_2]"
```

The redaction is **correct**. Then:

```
GET /api/documents/<id>/download   -> HTTP 200, 36620 bytes
downloaded .docx text              -> 'ID CARD: 11010519491231002X\nPHONE: 13812345678'
RAW ID IN DOWNLOAD:     True
RAW PHONE IN DOWNLOAD:  True
```

Reproduced for **all seven accepted formats** (`docx, pdf-text, xlsx, pptx, html, txt,
md`) on the published 0.1.29. The gate prints it on every run.

The same bytes are what `pacgate_convert_document` (MCP) feeds to markitdown, so an
agent's `read`/`convert` of a "sanitized" document returns the raw identifiers too.

## Root cause

`sanitize_document_handler` persists a **state flag, not an artifact**:

```sql
UPDATE documents SET sanitization_state = 'sanitized' WHERE id = $1
```

There is no sanitized rendering stored anywhere - `grep` over the schema shows only
`documents.sanitization_state` and `kb_chunks.sanitization_state`. The redacted text
exists solely in the HTTP response body, which is not retained.

`download_document` then gates on that flag and serves the original:

```rust
if doc_state != "sanitized" && doc_state != "never" {
    return Err(ApiError::conflict(...));      // the EGRESS GATE
}
let (doc, bytes) = state.doc_store.download_bytes(&doc_id, query.version).await?;
...
.body(axum::body::Body::from(bytes))          // <-- the ORIGINAL bytes
```

So the gate controls **when** you may download, not **what** you get. The handler
matches its own spec - `plans/020-sanitize-jobs.md` says "non-sanitized documents
refuse download (409 Conflict)", which they do - and nothing in the design says the
download should be the redacted rendering.

## Why no gate caught it

`test-sanitizer-e2e.ps1` asserts:

```powershell
Check "download allowed post-sanitize" ($dl.StatusCode -eq 200)
```

It asserts the **status code**. `200` is the correct status under the documented
contract, so the assertion passes while carrying the original. Every other assertion
in that gate runs on `job.sanitized_text` - the response field - not on the bytes a
reader receives. Nothing had ever opened the downloaded file.

This is the same failure shape as the OCR weights and the round cap: the test asserted
the thing that was easy to observe rather than the property that mattered.

## Why this is recorded rather than patched

Two readings are defensible and they imply opposite code:

- **It is a defect.** "Sanitized" should mean every egress path serves redacted
  content. Then download must serve a sanitized artifact (which requires storing one,
  and re-rendering the redacted text back into docx/xlsx/pptx/pdf to preserve the
  format), and `restore` remains the admin-only route to the original.
- **It is the design.** Download is an *export* of the matter's own file, gated so that
  an unsanitized document cannot leave. The sanitizer protects the **analysis and
  memory lanes** (RAG chunks are marked sanitized, and `sanitized_text` is what the
  agent is given), while the stored file stays the client's original - which is
  arguably required for legal work, since a redacted docx is not the executed
  contract.

The second reading is supported by `restore` existing at all: if download served the
sanitized rendering, "restore" would be redundant. That is real evidence that the
current behaviour is intentional.

**What is not defensible is that the distinction was invisible.** A user cannot tell
these apart, and a reviewer reading "sanitize passed, download allowed" would
reasonably conclude the file was redacted. Making it observable is the change that is
unambiguously correct, so that is the change made here.

## What was changed

`scripts/test-format-coverage-e2e.ps1` now, for every format:

1. extracts, sanitizes, and asserts both identifiers are gone from `sanitized_text`;
2. **downloads the document and inspects the bytes**, and also reads it through
   `pacgate_convert_document`, recording whether either path still carries the raw
   identifiers;
3. prints a single `EGRESS:` summary naming every format where the original was
   served.

It is a **WARN, not a FAIL**, precisely because the intent is unresolved: failing the
suite on behaviour that matches the written spec would train people to ignore it.
The finding is loud, attributed to this document, and now impossible to miss.

## The decision this needs

Someone who owns the product must choose, and the choice is cheap to state:

- **Serve sanitized:** store a sanitized rendering per version; re-render into the
  original format; keep `restore` as the privileged path to the original. This is a
  real feature (re-rendering redactions into OOXML/PDF while preserving layout), not a
  small patch.
- **Keep the original, rename the guarantee:** leave download as-is and make the
  surfaces say so - the sanitizer protects the **analysis lane**, and the file you
  download is the matter's original. A one-word change in the UI and docs, and no
  behaviour change.

Until that is decided, the honest statement to a client is: *sanitization governs what
the agent reads and what the knowledge base stores; it does not alter the file you
download.*

## Residual

- Only the seven accepted formats were probed. A format that reaches storage by another
  path (an import or migration) is unmeasured.
- `restore`'s own path was not exercised here; the sanitizer gate covers its role
  gate (attorney refused, admin allowed).
- The stored artifact has no version marker tying it to the sanitization that approved
  it, so nothing can detect a file edited after sanitization.
