# Document Coverage + Text Sanitization Path - Design

> **Status:** DRAFT - awaiting approval
> **Date:** 2026-09-24
> **Author:** Copilot (diagnosis + design; every claim below is measured on the
> live 0.1.17 stack, not inferred)
> **Supersedes:** the "PDF-only sanitizer" finding in the 2026-09-24 AIPC 1 report,
> which named the wrong mechanism. See §10 for what that report got wrong.
> **Companion:** `2026-09-18-sanitizer-agent-design.md` (established OCR and
> sanitization as separate capabilities; this spec resolves the document-type
> coverage gap that design left open)

## 1. Problem

The client cannot sanitize most of the material they upload. Measured on the live
0.1.17 stack through the real ingress:

| input | upload | extract | sanitize |
|---|---|---|---|
| `.pdf` | 200 | `incomplete=false`, 797 chars | **200 pass**, 2 redactions |
| `.docx` | 200 | `incomplete=true`, 0 chars | **500** |
| `.txt` | 200 | `incomplete=true`, 0 chars | **500** |
| `.md` | 200 | `incomplete=true`, 0 chars | **500** |
| `.png` | **400 unsupported file type** | - | - |

Three separate defects sit behind that table, and one of them is a safety hole
rather than a coverage gap.

## 2. What was measured (evidence base)

Every finding below was reproduced against the running stack. These are the facts
the design rests on.

### 2.1 OCR rasterises only `.pdf`

`deploy/ocr-service/app.py::_prepare_pages` has two branches:

```python
if suffix.lower() == ".pdf":
    # rasterise with pdf2image
return [(1, tmp_path)]   # everything else: RAW FILE BYTES
```

Non-PDF bytes are handed to `PaddleOCR.ocr()` as if they were images. It raises,
the page is marked failed, `incomplete=True`, and `sanitize.rs` refuses.

**Discrimination that rules out a text-path defect in `extract.rs`.** Holding
bytes constant and varying only the filename suffix sent to ocr-service:

| case | result |
|---|---|
| real pdf as `.pdf` | 200, `incomplete=false`, 21 chars |
| **real png as `.png`** | **200, `incomplete=false`, 21 chars** |
| real pdf misnamed `.txt` | 200, `incomplete=true`, 0 chars |
| txt bytes renamed `.pdf` | 200, `incomplete=true`, 0 chars |

The OCR engine works. The defect is the file-type branch.

### 2.2 An extraction that reads NOTHING is reported as complete (safety hole)

```
=== BLANK page ===
  extract=200  incomplete=False  chars=0  spans=0
  sanitize=200 verdict=pass redactions=0
  document_state=sanitized
  download=200   <- EGRESS OPEN

=== TEXT on p1 + BLANK p2 ===
  extract=200  incomplete=False  chars=26  spans=1
  sanitize=200 verdict=pass
  document_state=sanitized
  download=200   <- EGRESS OPEN
```

Two causes:

1. `ocr-service` sets `incomplete = True` only on an **exception**. A page that
   rasterises fine and yields no text hits `if not result: continue` and stays
   "complete".
2. `extract.rs`'s cache-hit branch returns a **literal** `incomplete: false`, and
   `document_spans` has no completeness column - so the cache *cannot represent*
   an incomplete extraction. Proven by injecting one span for the current version
   (what a partial OCR leaves behind): `/extract` reported `incomplete=False` and
   the document reached `sanitized`.

This is **fail-open on the `.pdf` path that works**. It is the highest-severity
finding in this spec, and it is why §5 orders the work as it does.
`pacgate_ocr_batch` amplifies it: bulk OCR pre-warms this cache, so a partial bulk
pass is recorded as complete and every later sanitize inherits it.

### 2.3 The client's real path never touches the sanitizer

deer-flow already converts uploads itself and stores the markdown beside the original:

- `deploy/client-bundle/patches/deer-flow-uploads.py:296` calls
  `convert_file_to_markdown`
- `uploads.auto_convert_documents: true` in `deer-flow-config.yaml:215`
- deer-flow's venv holds the converters: `markitdown 0.1.5`, `mammoth 1.11.0`,
  `python-pptx`, `openpyxl`
- `CONVERTIBLE_EXTENSIONS = {.pdf .ppt .pptx .xls .xlsx .doc .docx}`

But that markdown is **not registered with pacgate-api**. The two stores are
physically separate, confirmed on disk:

```
chat upload   -> data/deer-flow/users/{uid}/threads/{tid}/user-data/uploads/
pacgate store -> data/tenants/...
```

`pacgate_sanitize_document` takes a *pacgate* document UUID, so a chat upload has
no document row, no chunks, and no spans. **Result: a `.docx` uploaded in chat is
converted and fed to the model without ever being sanitized.** The gate is not
bypassed; it is absent from that path. This is a larger gap than the `.docx`
extraction bug and it is the reason §6 exists.

### 2.4 No deployed converter reads legacy binary formats

Probed against deer-flow's own markitdown 0.1.5:

| format | result |
|---|---|
| `.doc` | FAIL - no converter claims it |
| `.xls` | FAIL - converter threw |
| `.ppt` | FAIL - no converter claims it |
| `.odt` | FAIL - no converter claims it |
| `.wps` | FAIL - no converter claims it |
| `.msg` | FAIL - missing extra |
| `.rtf` | **OK, but emits raw RTF control words** |

`.rtf` "succeeding" while producing control-word garbage is worse than failing - it
would be sanitized as-is and look clean.

### 2.5 What already works and must not be rebuilt

- **The sanitizer redacts correctly.** Given a large-font PDF, OCR read
  `11010519491231002X` verbatim and the sanitizer removed it: `2 redactions`,
  both identifiers gone. (An earlier `redactions=0` was this fixture's tiny font
  being misread - not a sanitizer defect.)
- **`pacgate_sanitize_text` is not a second defect.** It uploads its input as
  `sanitize-ephemeral.txt`, so it dies from §2.1's root cause.
- **All three routes share `extract.rs`**: `/extract`, `run_job`'s ingest step,
  and `pacgate_ocr_document`/`pacgate_ocr_batch`. That is the only real coupling
  between the OCR lane and the sanitizer lane.

## 3. Design principle: the coordinate model picks the lane

The lane is not a preference - it follows from what the review panel needs.

`document_spans` stores `x/y/width/height` per text element (`006_document_spans.sql`),
for row-level review queries and v2 pixel redaction. A born-digital document has
every character addressed in its own file; OCR would *invent* coordinates by
rendering text into a raster and reading it back with errors. So:

**Text-native formats must never go through OCR.** Not because OCR is "worse", but
because OCR manufactures coordinates that do not exist and adds recognition error
where none was possible. OCR's job is pixels -> text, and it stays exactly that.

## 4. The lanes

```
upload -> pacgate-api
          |
          +-- TEXT-NATIVE  .txt .md            -> Rust read_to_string
          |                .docx .xlsx .pptx   -> one text converter
          |                .rtf .eml .html     -> same converter
          |                => text, no spans   ------------------+
          |                                                       |
          +-- RASTER       .pdf                 text-layer probe   |
          |                .png .jpg .jpeg      scanned -> OCR ---+
          |                                     digital -> text   |
          |                                                       |
          +-- REJECT       .doc .xls .ppt .odt .wps .msg          |
                           named reason + "re-save as .docx"      |
                                                                  v
                                                    text ingest (pending chunks)
                                                                  |
                                                    sanitize.rs -> redact -> verify
                                                                  |
                                                    review gate -> egress
```

Both text-lane entry points converge on the same sanitize job, so the client gets
one guarantee regardless of format.

## 5. Workstream 1 - completeness (safety, first)

**Why first:** it is fail-open on the working path, and every later workstream adds
more formats into a pipeline that mishandles "read nothing".

**Changes**

1. `ocr-service`: set `incomplete = True` when a page yields **neither text nor
   spans**. A page that legitimately has no content is distinguishable from a page
   whose read failed only if the converter reports it; where it cannot, fail closed.
2. New migration `008_extraction_state.sql`: record extraction completeness per
   `(tenant_id, matter_id, document_id, document_version)`.
3. `extract.rs`: the cache-hit branch reads that record instead of the literal
   `false`.
4. `sanitize.rs` is **unchanged** - it already refuses on `incomplete == true`.

**Test:** a blank-page upload must NOT reach `document_state=sanitized`, and the
download must NOT return 200. Proven to fail before the fix (the probe in §2.2 is
the failing test), proven to pass after.

**Decision taken (overridable):** flag incomplete only when a page yields neither
text nor spans. A legitimately blank page in a real contract must not make the
whole document un-sanitizable. The stricter reading - every blank page fails - is
rejected because it makes ordinary documents impossible to process.

## 6. Workstream 2 - text ingest path

**This is the bridge for §2.3, and it repairs `pacgate_sanitize_text`.**

`pacgate-api` gains a text ingest endpoint: text -> pending chunks -> the existing
sanitize job. It bypasses extraction entirely, because the text already exists.

```
POST /api/matters/:matter_id/sanitize-text
  { text, name?, source_document_id?, data_level }
-> creates an ephemeral document record (so the job, ledger and
   review panel work unchanged)
-> ingests text as pending chunks
-> runs the same run_job path
-> returns verdict / redaction_count / mapping_count / sanitized_text
```

`pacgate_sanitize_text` is then repointed at this endpoint instead of uploading a
fake `.txt` document.

**Why a document record rather than a new job type:** the ledger, the vault, the
review panel and the egress decision all key on a document. Creating a
lightweight record reuses every one of them and keeps "one job shape" true.

**How this differs from §7's converter.** These are two different problems and
must not be conflated:

- §6 (this section) handles text **that already exists** because deer-flow
  produced it from a chat upload. Nothing needs extracting; the text is carried
  into the sanitizer.
- §7's converter is for documents **inside pacgate-api's own store**, where
  `extract.rs` must turn file bytes into text before a sanitize job can run.

A chat-uploaded `.docx` therefore uses §6 and never touches §7's converter. A
`.docx` uploaded through the pacgate document API uses §7. Both converge on the
same `run_job`, which is what keeps the guarantee uniform.

**Open item for the plan:** whether the chat upload markdown should be *pushed*
here by deer-flow, or *pulled* by the agent when it starts a sanitize. The pull
model needs no deer-flow patch and keeps the sanitizer agent as the control point;
the push model is automatic and cannot be forgotten. Recommendation: **pull**, in
the sanitizer agent, with a scripted path so a run without it is visible.

## 7. Workstream 3 - format lanes

| lane | formats | implementation |
|---|---|---|
| direct text | `.txt` `.md` | `fs::read_to_string` (Rust, no dependency) |
| converted text | `.docx` `.xlsx` `.pptx` `.rtf` `.eml` `.html` | one text converter (see §7.1) |
| OCR | `.pdf` scanned, `.png` `.jpg` `.jpeg` | existing ocr-service, unchanged |
| PDF digital | `.pdf` with a text layer | text-layer probe, then direct text |

**Upload allowlist** (`pacgate-docx/src/store.rs:81`) widens from
`.docx .pdf .txt .md` to include the image types. Today the OCR image lane works
but is unreachable through the API - that is a coverage hole in itself.

### 7.1 The converter decision

Measured coverage of what we already deploy:

| converter | location | coverage |
|---|---|---|
| markitdown 0.1.7 `[docx,pptx,xlsx,pdf]` | `pacgate-mcp` | docx, xlsx, pptx, rtf, eml, html, csv, json, xml |
| markitdown 0.1.5 + mammoth | `deer-flow` venv | same family |
| Docling | not installed | broadest, but needs PyTorch |
| `anydoc` (Rust, MIT) | not installed | legacy Office, ODT, RTF, ~100 MB, no ML |

**Recommendation:** extract text in the **conversion service** lane, reusing the
markitdown-based converter we already ship, behind an interface that allows a
second engine later. Rationale:

- It is the only option with **zero new runtime risk** for a client-deployed
  safety component.
- It mirrors `ocr-service`, so the deployment story is identical (one more
  compose service, same release path).
- Docling is the right long-term answer (its format list maps almost exactly onto
  the client's needs) but is not stable enough today: PyTorch is a hard dependency
  and the maintainer's own reply to issue #2393 is *"We will start a docling-slim
  package exactly for this purpose"*, with a 2026 PR fixing
  `docling-slim[format-office]` being broken by eager imports. Both are cited in §11.
- `anydoc` remains the strong option if we later want this **in-process in Rust**
  and legacy formats become a real requirement.

### 7.2 Conversion coverage gate

Measured, not assumed. All three candidate converters **silently drop header,
footer and footnote text**:

```
mammoth 1.11 (markitdown's engine)  header MISSED  footer MISSED  table MISSED
pacgate-docx read_text (equiv)      header MISSED  footer MISSED  table OK
markitdown 0.1.7 (deployed)         header MISSED  footer MISSED  table MISSED
```

(`read_text`'s "table OK" is accidental tag-stripping, not real table support.)

Under this product, silently skipping a part is a **redaction hole that fails
open**: the document reports `sanitized` and egresses with identifiers intact in
the header.

**Requirement:** before converted text reaches the sanitizer, compare the part
inventory the document declares against the parts the converter visited. For OOXML
(`.docx`/`.xlsx`/`.pptx`) the inventory is read from the package manifest
(`[Content_Types].xml` plus the `.rels` relationships), and any part referenced
there that carries text but was not visited counts as **skipped**. If any part was
skipped, report `incomplete=true` so `sanitize.rs` refuses. This makes coverage
measured rather than assumed, and no document can be declared sanitized while a
part was ignored.

The rule is deliberately asymmetric: we do not need to enumerate every text-bearing
part name in advance (that list drifts with every Word version). We compare what
the file *says* it contains against what the converter actually read, so a new
part type fails closed by default.

## 8. Workstream 4 - reject unsupported formats

`.doc` `.xls` `.ppt` `.odt` `.wps` `.msg` are rejected **at upload** with a named
reason and a "re-save as `.docx`" hint.

Rationale: §2.4 shows no deployed converter reads any of them, so today they fail
with a misleading `extract 200 / incomplete=true / sanitize 500` - which tells an
operator nothing. Rejecting early is honest and costs no image size.

`.wps` deserves a specific note: it is ambiguous between Microsoft Works and WPS
Office, and WPS Office's native format is actually `.docx`. Most `.wps` files a
client sends are likely mislabelled `.docx`, so the correct guidance is re-save,
not convert.

## 9. Workstream 5 - model pins as runtime configuration

Separate from document coverage, but it shares the delivery story.

`pacgate-core/src/lib.rs::ModelConfig::default_local_with_base_url` pins
`nemotron3:33b` / `qwen3.6:27b` / `qwen3.5:9b`. All three return **HTTP 404**
against the live Ollama, and `main.rs:89` uses them unconditionally when a tenant
has no `model_overrides` (tenant `Pacgate Law` has `{}`). Every
`POST /api/workflows/:id/execute` fails with `500` - 222 workflows listed, 0
executable - and the agent chat path is down with it.

The defect itself is a stale value; the **design** defect is that the values are
**compiled constants**, so no `.env` or compose value can reach them and only a
rebuild can change them. `scripts/audit-model-tags.ps1` - the guard for exactly
this defect class - exits 0 while this fires, because its `-Configs` list covers
only YAML and template files and never scans Rust.

**Change:** promote the three tiers to runtime configuration (the pattern
`OLLAMA_BASE_URL` already uses), so `origin/main` carries the *mechanism* and each
machine carries its *roster*. Then extend `audit-model-tags.ps1` to cover the new
config surface, so this class becomes catchable instead of invisible.

Values are chosen on the real AIPCs, not here - the user debugs those directly.

## 10. What the source report got wrong

Recorded because the wrong mechanism would have produced the wrong fix:

| claim | reality |
|---|---|
| "a text path in `extract.rs` or an ocr-service dependency" | neither - it is a missing file-type branch in `_prepare_pages` |
| "`pacgate_sanitize_text` is a second, cleaner defect" | same root cause (§2.5) |
| commit `3c95244`, "mirror synced" | the commit does not exist in any ref; `build-ghcr.yml` has no mirror job (removed in plan 016) |
| the impact conclusion (DD intake is `.docx`, none of it passes the gate) | correct |

It also missed both higher-severity findings: the §2.2 fail-open and the §2.3
missing bridge.

## 11. Non-goals

- Pixel-level redaction of images (v2 - `document_spans` already captures the BBox
  data, so it stays additive).
- A Docling adapter (the seam is designed in §7.1; the implementation waits for a
  stable slim install).
- Legacy binary Office conversion (rejected in §8; revisit only on client demand).
- Changing the sanitizer's redaction logic. §2.5 shows it is sound.

## 12. Delivery

All five workstreams ship through the existing path:

```
origin/main -> release workflow -> GHCR -> install.ps1 -Update -> git pull --ff-only
             + docker compose pull + recreate
```

No per-machine code. Workflow templates need no change (222 already served via
`WORKFLOWS_DIR` bind-mount, so content ships by `-Update` alone).

One new compose service if §7.1's conversion service is adopted, which the release
workflow must also build and publish - the same mechanical change `ocr-service`
already went through in 0.1.16.

## 13. Build order and why

| # | workstream | why this position |
|---|---|---|
| 1 | completeness fail-open (§5) | fail-open on the working path; everything else adds formats into this pipeline |
| 2 | text ingest path (§6) | makes the client's real path safe at all; repairs `pacgate_sanitize_text` |
| 3 | format lanes + coverage gate (§7) | requires 2 to exist; the gate is what makes multi-format safe |
| 4 | reject unsupported (§8) | cheap, and stops the misleading 500 |
| 5 | model pins as config (§9) | independent; unblocks workflows and chat |

**Decomposition.** This spec is intentionally larger than one implementation plan.
It is written as one design because the five workstreams share a single safety
argument, but they must be planned and shipped as **separate plans**:

- **Plan A - workstream 1.** Self-contained, no new services, ships alone, closes
  a fail-open. Should land first and independently of everything else.
- **Plan B - workstreams 2 + 3 + 4.** These form one coherent change (the lanes
  and the path that carries text between them) and are hard to split further,
  because §7's coverage gate is meaningless without §6's text path.
- **Plan C - workstream 5.** Independent of A and B; can run in parallel.

Each plan gets its own failing tests and its own release.

## 14. Success criteria

Each is a test that must fail before its change and pass after.

1. A blank-page PDF does NOT reach `document_state=sanitized` and does NOT
   download 200. *(fails today - §2.2)*
2. A cached partial extraction reports `incomplete=true`. *(fails today - §2.2)*
3. `.docx` `.txt` `.md` each reach `verdict=pass` with identifiers redacted.
4. `pacgate_sanitize_text` returns a verdict instead of a 500.
5. A `.docx` whose identifiers sit only in the header reports `incomplete=true`
   rather than `sanitized`.
6. `.png` and `.jpg` upload successfully and OCR-read.
7. `.doc` `.wps` `.msg` are rejected at upload with a named reason.
8. `POST /api/workflows/:id/execute` runs after the model roster is configured
   from a config value, with no rebuild.
9. A single `install.ps1 -Update` on a clean clone delivers all of the above.

## 15. Risks

| risk | mitigation |
|---|---|
| §7.2's coverage gate makes some real documents un-sanitizable | that is the correct direction - failing closed is visible; failing open is not. Report which part was skipped so an operator can act |
| a converter's part inventory is wrong | the comparison is declared-parts vs visited-parts, so an unknown part counts as "not visited" and fails closed |
| text ingest creates document records that clutter matters | ephemeral records, same cleanup pattern `pacgate_sanitize_text` already uses |
| the model roster differs per AIPC | §9 makes it config, which is what allows per-machine rosters without a release |

## 16. Sources

- `deploy/ocr-service/app.py` - `_prepare_pages`, page loop (the `.pdf`-only branch
  and the missing `incomplete` flag)
- `pacgate-ai/crates/pacgate-api/src/extract.rs` - cache-hit literal, `extract_document`
- `pacgate-ai/crates/pacgate-api/src/sanitize.rs` - `run_job`'s `incomplete` refusal
- `pacgate-ai/crates/pacgate-docx/src/store.rs:81` - upload allowlist
- `pacgate-ai/migrations/006_document_spans.sql` - coordinate model
- `deploy/client-bundle/patches/deer-flow-uploads.py:296` and
  `deploy/client-bundle/deer-flow-config.yaml:215` - the chat conversion path
- `deploy/sanitizer-agent/SOUL.md` - "identify the target document by its UUID"
- Docling supported formats: `raw.githubusercontent.com/docling-project/docling/main/docs/usage/supported_formats.md`
- Docling weight: GitHub issue #2393 ("Lightweight installation options"; maintainer:
  *"We will start a docling-slim package exactly for this purpose"*) and the 2026 PR
  fixing `docling-slim[format-office]` being broken by eager `pypdfium2` imports
- markitdown README (extras list) and issues #1220 (`.doc` unsupported),
  #1662 (`EmlConverter` does not process attachments), #1162 (`RtfConverter`)
- `anydoc` - crates.io metadata (MIT, 0.2.4, 390k downloads) and
  github.com/firecrawl/anydoc
- Live measurements: `scripts/probe-format-lanes.py`, `scripts/probe-ocr-suffix.py`
