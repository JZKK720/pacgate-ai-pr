# Text-Native Document Coverage - Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every text-native document type the client uploads reach the sanitizer, with the text actually read — including headers, footers, footnotes and metadata that all three of our current converters silently skip.

**Architecture:** `extract_document` currently hands every format to `ocr-service`, which rasterises only `.pdf`; everything else is fed to PaddleOCR as raw bytes and fails. This plan routes text-native formats to a new Rust extractor in `pacgate-api` that reads the file's own text directly — a zip-scan of OOXML text elements for `.docx`/`.xlsx`/`.pptx`, `fs::read_to_string` for `.txt`/`.md`, and tag-stripping for `.html`. No new service, no Python in the safety path, no ML. Raster input (`.pdf`, images) keeps using `ocr-service` unchanged.

**Tech Stack:** Rust (pacgate-api, pacgate-core, pacgate-docx, sqlx/PostgreSQL), PowerShell gate scripts, Docker Compose. **No new crate dependencies** — `zip` and `regex`/manual scanning only, both already in the tree via `pacgate-docx`.

**Spec:** `docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md` — this implements §7 (workstream 3) and §8 (workstream 4). **Read the §7.1 amendment, the §7.2 amendment, and §11 before starting** — three measurements since the spec was written change the design, and they are recorded there.

## Global Constraints

- **Fail closed.** A text-native document whose content cannot be fully read reports `incomplete = true`, and `sanitize.rs` refuses. Do NOT add an "accept partial text" path.
- **Do NOT modify `sanitize.rs`.** It already refuses on `incomplete == true`; this plan feeds that guard. If you find yourself editing it, the fix has gone wrong.
- **Text-native formats must never reach `ocr-service`.** Not a preference: `document_spans` needs `x/y/w/h`, and a born-digital file has no raster to point at. OCR would manufacture coordinates and add recognition error where none is possible.
- **Zero new runtime dependencies.** No Python, no new compose service, no new crate beyond what `pacgate-docx` already pulls in (`zip`). The spec's conversion-service option is superseded — see §7.1 amendment.
- **`.pdf` and image handling is untouched.** Same `ocr-service` call, same behaviour, same tests.
- **Deploy path is `origin/main` → GHCR → `install.ps1 -Update`.** No per-machine code.
- **Dev-box image shadowing is expected** and needs a retag plus `--force-recreate --no-deps`. Build the API with `--build-arg PAC_SOURCE_REVISION=$(git rev-parse HEAD)` — omitting it leaves `/version` reporting `unknown` and breaks `test-version-marker-against-image.ps1` (measured in Plan A).
- **Run compose from `deploy/client-bundle/`.** `compose.prod.yaml` lives there; from the repo root compose reports the file as invalid.
- **`cargo` is NOT on PATH.** Use `$env:USERPROFILE\.cargo\bin\cargo.exe`.
- **PowerShell is case-INSENSITIVE for variables**; use named variables only.
- **Gate exit codes:** `0` pass, `1` real failure, `2` cannot check. A "cannot check" must never be reported as a pass.
- **The live stack publishes nginx on 8089**; derive it with `docker port pacgate-nginx 80`, never hardcode. `/version` is at the nginx ROOT, not under `/pacgate`.
- **Credential safety:** to test `.env` presence use ONLY `[bool](Select-String -Path 'deploy/client-bundle/.env' -Pattern '<KEY>=' -Quiet)`. NEVER `Get-Content` it, NEVER `Select-String` without `-Quiet`, NEVER print a line from it or `$Matches[1]`. A non-`-Quiet` grep leaked a password earlier in this work.
- **After any mutation suite, run `git status --short`** and `git checkout --` whatever it left. A stale `.git/mutation-guard-backup` then blocks later suites and cascades.

---

## Verified findings this plan is built on

All measured on this box; re-measured rather than recalled.

### F1 — All three of our converters skip header/footer/footnote text

```
mammoth 1.11 (markitdown's engine)  header MISSED  footer MISSED  table MISSED
pacgate-docx read_text (equiv)      header MISSED  footer MISSED  table OK
markitdown 0.1.7 (deployed)         header MISSED  footer MISSED  table MISSED
```

For a sanitizer this is a redaction hole that fails **open**: the document reports `sanitized` and egresses with client identifiers intact in the header.

### F2 — Scanning all `word/*.xml` for `<w:t>` reads every location

Measured against a fixture carrying a distinct token in body, header, footer, footnote, endnote, comment, text box and table:

| location | new scan | `document.xml` only |
|---|---|---|
| body | YES | YES |
| header | **YES** | MISSED |
| footer | **YES** | MISSED |
| footnote | **YES** | MISSED |
| endnote | **YES** | MISSED |
| comment | **YES** | MISSED |
| text box | YES | YES |
| table | YES | YES |

13 parts scanned, no hardcoded part list. **The spec's §7.2 proposal — "detect a skipped part and refuse" — is the wrong shape**: if we cannot read headers and must refuse when we cannot read a part, then every real Word document with a header becomes unsanitizable. Read the parts instead of refusing.

### F3 — `.xlsx` and `.pptx` fall out of the same scan

Same approach, different text element name:

| format | parts | text element | ID found | phone found |
|---|---|---|---|---|
| `.docx` | `word/*.xml` | `<w:t>` | YES | YES |
| `.xlsx` | `xl/*.xml` | `<t>` | YES | YES |
| `.pptx` | `ppt/*.xml` | `<a:t>` | YES | YES |

Known limit: `.xlsx` **numeric** cells live in `<v>`, not `<t>`, so numbers are not read as text. That is acceptable and out of scope — numbers carry no identity, and the client spec forbids scaling or shifting amounts.

### F4 — Metadata carries identifiers and NO extractor reads it

`docProps/core.xml` on a document saved with metadata set:

```
<title>            Matter 2026-CLIENT-ACME-11010519491231002X
<keywords>         Acme; 11010519491231002X
<creator>          Sylvie Chen (Attorney)
<lastModifiedBy>   Justin Zhang
<description>      Client contact 13812345678
```

`docProps` is **not** under `word/`, and these are element text rather than `<w:t>` runs — so the F2 scan does not reach them, and `grep docProps` across the deployed markitdown returns nothing. The client's requirements document lists "metadata coverage" explicitly. **A plain F2 implementation would still leak a client ID in `keywords`.**

### F5 — There is no user-facing document upload to `pacgate-api`

`/api/documents` exists and works, but a repo-wide search of the frontend patch set finds no caller. The only upload UI is the deer-flow chat, which converts to markdown in its own container. Consequences, both of which shape the plan:

- `POST /api/documents` is reached by the **agent/MCP** lane (`pacgate_upload_document`), and by tests. That is what this plan fixes.
- The chat lane's text is produced by **deer-flow's own mammoth-based conversion**, which per F1 has the identical header/footer hole. So the chat lane cannot be made safe by forwarding deer-flow's markdown either — a later plan must run THIS extractor on the original bytes. Recorded in the spec as §11; not in this plan's scope.

---

## File Structure

| File | Responsibility |
|---|---|
| `pacgate-ai/crates/pacgate-api/src/text_extract.rs` | **Create.** The whole text-native reader: OOXML zip-scan, direct read, HTML tag-strip, metadata, and a coverage report. One file, one job — "given bytes and a format, give me all the text and tell me if you got it all". |
| `pacgate-ai/crates/pacgate-api/src/lib.rs` | Modify. Register the module. |
| `pacgate-ai/crates/pacgate-api/src/extract.rs` | Modify. Route by format: text-native → `text_extract`, raster → `ocr-service`. Unchanged for PDF. |
| `pacgate-ai/crates/pacgate-core/src/lib.rs` | Modify. Add `DocumentFormat` variants (`Xlsx`, `Pptx`, `Html`). |
| `pacgate-ai/crates/pacgate-docx/src/store.rs` | Modify. Widen the upload allowlist and the format↔string maps. |
| `pacgate-ai/crates/pacgate-api/src/documents.rs` | Modify. Content-type and extension maps for the new formats. |
| `scripts/test-text-native-sanitize.ps1` | **Create.** The gate. Assertions grow as tasks land. |

`text_extract.rs` is new and self-contained; nothing else grows much. `extract.rs` gains a routing decision plus a branch, roughly 40 lines.

---

## Task 1: The failing gate (RED)

**Why first:** four of the six target formats already upload but extract to nothing; two are rejected at upload. Both are failures, and the gate must show them before any code changes.

**Files:**
- Create: `scripts/test-text-native-sanitize.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/test-text-native-sanitize.ps1` with `-BaseUrl`, `-EnvFile`, `-KeepArtifacts`, exit codes 0/1/2, and a `Check`/`Die` pair matching `test-empty-extraction-gate.ps1`. Later tasks append; Task 5 wires it into the suite.

- [ ] **Step 1: Write the gate**

Create `scripts/test-text-native-sanitize.ps1`. Model the shape on the existing `scripts/test-empty-extraction-gate.ps1` — read it first and reuse its conventions (`Check`, `Die`, live-container port probe, `/version` at the root, credential parsing, exit codes).

The cases and their fixtures:

| case | format | fixture content | today |
|---|---|---|---|
| T1 | `.txt` | ID + phone | extract fails |
| T2 | `.md` | ID + phone | extract fails |
| T3 | `.docx` | ID + phone in the **body** | extract fails |
| T4 | `.docx` | ID **only in the header** | extract fails — and this is the safety case |
| T5 | `.xlsx` | ID + phone in cells | upload rejected |
| T6 | `.pptx` | ID + phone in a slide | upload rejected |
| CONTROL | `.pdf` | ID + phone, readable | passes today — must not regress |

For each case assert, in order:
1. **upload** returns 2xx (T5/T6 fail here today with `unsupported file type`)
2. **extract** returns 200 with `incomplete = false`
3. the extracted text **contains** the identifiers (proves something was really read)
4. **sanitize** returns 200 with `verdict = pass` and `redaction_count >= 2`
5. the sanitized text **does not contain** the identifiers

Build fixtures with `docker run --rm -v "${dir}:/fix" --entrypoint python3 ocr-service:local -c @"..."@` — the here-string form the two existing fixture builders use (`test-legal-journey.ps1:161`, `test-sanitizer-e2e.ps1:18`). **Do not pipe to `python3 -` over stdin**; no gate in this repo uses that form.

**Fixture libraries in `ocr-service:local`, MEASURED (an earlier revision of this plan claimed all four and was wrong — it had confused this image with `pacgate-mcp`, where `openpyxl`/`python-pptx` happen to be installed):**

| library | `ocr-service:local` |
|---|---|
| `PIL` | present |
| `python-docx` | present |
| `openpyxl` | **ABSENT** |
| `python-pptx` | **ABSENT** |

So build `.docx` with `python-docx`, and `.xlsx`/`.pptx` with the **stdlib `zipfile` writer** — which is also what Task 3's Rust unit tests need, since a hand-built package is the only way to control exactly which parts carry text. A hand-built OOXML package is structurally valid and carries text in the elements the extractor scans (`xl/*.xml` `<t>`, `ppt/*.xml` `<a:t>`).

T4's fixture is the critical one: a `.docx` whose only identifier is in `sections[0].header.paragraphs[0].text`. Build it, then assert the identifier appears in the extracted text. That assertion is what proves the fix reads beyond `document.xml`.

**Guard against a false pass** (this bit us in Plan A): assert each fixture is **non-empty on disk** before uploading, and assert the extracted text contains the identifier rather than merely being non-empty. A zero-byte fixture once produced two "passing" assertions for the wrong reason.

**The size floor must be per-format.** A blanket `-gt 1000` is wrong: a legitimate `.txt` fixture is ~50 bytes and would fail the guard while being perfectly valid. Use a small floor (~8 bytes, i.e. "not empty") for `.txt`/`.md` and ~1000 for container formats, where no legitimate `.docx`/`.xlsx`/`.pptx`/`.pdf` is ever under 1 KB.

**Also guard the EGRESS assertion against passing vacuously.** `-not ''.Contains('x')` is `TRUE`, so a bare "sanitized text does not contain the identifier" check passes when sanitize failed and returned no text at all. Gate it on sanitize having succeeded AND produced non-empty text — the same false-pass class as the zero-byte incident, one layer deeper.

- [ ] **Step 2: Run the gate and record every failure**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
pwsh -File scripts/test-text-native-sanitize.ps1
```

Expected: exit 1, with T1-T4 failing at the extract assertions, T5/T6 failing at upload with `unsupported file type; expected .docx, .pdf, .txt, or .md`, and CONTROL passing all five of its checks.

**If CONTROL does not pass, STOP.** The gate is wrong, not the product.

- [ ] **Step 3: Commit**

```powershell
git add scripts/test-text-native-sanitize.ps1
git commit -m "test: failing gate for text-native document coverage"
```

---

## Task 2: Widen the upload allowlist and format model

**Why before the extractor:** T5/T6 cannot even be uploaded, so nothing downstream can be tested until the formats exist. This task is mechanical and small; the extractor is the substantive one.

**Files:**
- Modify: `pacgate-ai/crates/pacgate-core/src/lib.rs` (`DocumentFormat`)
- Modify: `pacgate-ai/crates/pacgate-docx/src/store.rs` (allowlist + maps)
- Modify: `pacgate-ai/crates/pacgate-api/src/documents.rs` (content-type + extension maps)

**Interfaces:**
- Consumes: nothing.
- Produces: `DocumentFormat::{Xlsx, Pptx, Html}`; `FsDocumentStore::upload_bytes` accepting `.xlsx`/`.pptx`/`.html`; the `format` string spelling for each (`"xlsx"`, `"pptx"`, `"html"`), which Task 3's router and Task 4's `engine` label both key on.

- [ ] **Step 1: Add the enum variants**

In `pacgate-ai/crates/pacgate-core/src/lib.rs`, extend `DocumentFormat` with `Xlsx`, `Pptx`, `Html`, preserving the existing derives and serde spelling convention used by the other variants.

- [ ] **Step 2: Extend the store's three match sites**

`pacgate-ai/crates/pacgate-docx/src/store.rs` has three places that enumerate formats and each must gain the new arms. Find them by searching the file for `"docx"` — they are the upload allowlist (≈line 70-85), `row_to_document`'s format parsing (≈line 438), and `rel_path`'s extension map (≈line 330).

The upload allowlist currently returns:

```rust
            _ => {
                return Err(pacgate_core::PacgateError::ValidationError(
                    "unsupported file type; expected .docx, .pdf, .txt, or .md".into(),
                ))
            }
```

Change it to accept `"xlsx"`, `"pptx"`, `"html"` as well, and update the message to list every supported type and to name the rejected ones:

```rust
            Some("xlsx") => "xlsx",
            Some("pptx") => "pptx",
            Some("html") | Some("htm") => "html",
            _ => {
                // Name what was rejected and what is accepted. The legacy binary
                // formats are called out with a specific remedy because clients do
                // send them and "unsupported" alone tells an operator nothing.
                let ext = file_path
                    .extension()
                    .and_then(|v| v.to_str())
                    .unwrap_or("(none)")
                    .to_ascii_lowercase();
                let msg = match ext.as_str() {
                    "doc" | "xls" | "ppt" | "wps" | "odt" | "ods" | "odp" | "msg" => format!(
                        ".{ext} is a legacy or unsupported format. Re-save it as \
                         .docx/.xlsx/.pptx and upload again; PacGate reads the modern \
                         formats directly."
                    ),
                    _ => format!(
                        ".{ext} is not a supported format. Supported: \
                         .docx .xlsx .pptx .pdf .txt .md .html"
                    ),
                };
                return Err(pacgate_core::PacgateError::ValidationError(msg));
            }
```

- [ ] **Step 3: Extend the API's content-type and extension maps**

In `pacgate-ai/crates/pacgate-api/src/documents.rs`, both matches on `doc.format` in `download_document` are exhaustive and will fail to compile once the enum grows. Add the arms:

```rust
        DocumentFormat::Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        DocumentFormat::Pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        DocumentFormat::Html => "text/html; charset=utf-8",
```

and for the extension map:

```rust
        DocumentFormat::Xlsx => "xlsx",
        DocumentFormat::Pptx => "pptx",
        DocumentFormat::Html => "html",
```

Also extend `row_to_document`'s format parsing in `extract.rs`'s sibling (`documents.rs` ≈line 32) so the new strings round-trip.

- [ ] **Step 4: Compile and confirm the gate's upload assertions now pass for T5/T6**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" build -p pacgate-api
```

Expected: compiles. Then rebuild and shadow the API (see Task 3 Step 5 for the exact commands; they are the same every time) and re-run the gate.

Expected: T5/T6 **upload** assertions now pass; their extract and sanitize assertions still fail. T1-T4 unchanged. CONTROL still fully passes.

- [ ] **Step 5: Commit**

```powershell
git add pacgate-ai/crates/pacgate-core/src/lib.rs pacgate-ai/crates/pacgate-docx/src/store.rs pacgate-ai/crates/pacgate-api/src/documents.rs
git commit -m "feat(formats): accept .xlsx, .pptx and .html uploads, and name legacy rejections"
```

---

## Task 3: The text extractor

**The substantive task.** Everything else is plumbing.

**Files:**
- Create: `pacgate-ai/crates/pacgate-api/src/text_extract.rs`
- Modify: `pacgate-ai/crates/pacgate-api/src/lib.rs`

**Interfaces:**
- Consumes: `DocumentFormat` from Task 2.
- Produces:
  ```rust
  pub struct TextExtraction {
      pub text: String,       // ALL readable text, including metadata
      pub incomplete: bool,   // true when any part could not be read
      pub parts_read: Vec<String>,   // for diagnostics + the gate's evidence
      pub engine: String,     // e.g. "ooxml-zip-scan", "plain-text", "html-strip"
  }
  pub fn extract_text_native(format: &DocumentFormat, bytes: &[u8]) -> TextExtraction;
  ```
  Task 4 calls exactly this and reads exactly these fields. It must not panic: any parse failure returns `incomplete: true`, never `Err` — an unreadable file is a fail-closed condition, not a server error.

- [ ] **Step 1: Write the unit tests FIRST**

Create `pacgate-ai/crates/pacgate-api/src/text_extract.rs` with tests only, and get them failing. Each test builds its fixture in-memory as bytes — no disk, no network, no container.

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use pacgate_core::DocumentFormat;

    // Distinct tokens so a silent skip is unambiguous.
    const BODY: &str = "BODYTOKEN1";
    const HEADER: &str = "HEADTOKEN2";
    const FOOTER: &str = "FOOTTOKEN3";
    const META: &str = "METATOKEN9";

    /// The safety-critical case: an identifier that lives ONLY in the header must
    /// reach the sanitizer. Every converter we currently ship misses this.
    #[test]
    fn docx_reads_header_and_footer_not_just_the_body() {
        let bytes = docx_with_header_footer();
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(out.text.contains(BODY), "body text missing");
        assert!(out.text.contains(HEADER), "HEADER TEXT MISSED - this is the fail-open");
        assert!(out.text.contains(FOOTER), "FOOTER TEXT MISSED");
        assert!(!out.incomplete, "a fully-read docx must not be incomplete");
    }

    /// docProps is not under word/, and the fields are element text rather than
    /// <w:t> runs, so the OOXML scan does not reach them. The client's requirements
    /// list metadata coverage explicitly.
    #[test]
    fn docx_reads_core_metadata() {
        let bytes = docx_with_metadata();
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(out.text.contains(META), "docProps metadata MISSED");
    }

    #[test]
    fn docx_reads_a_table() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_table());
        assert!(out.text.contains("TABLETOKEN8"), "table text MISSED");
    }

    #[test]
    fn xlsx_reads_cell_text() {
        let out = extract_text_native(&DocumentFormat::Xlsx, &xlsx_with_id());
        assert!(out.text.contains("11010519491231002X"), "xlsx cell text MISSED");
    }

    #[test]
    fn pptx_reads_slide_text() {
        let out = extract_text_native(&DocumentFormat::Pptx, &pptx_with_id());
        assert!(out.text.contains("11010519491231002X"), "pptx slide text MISSED");
    }

    #[test]
    fn txt_and_md_are_read_verbatim() {
        let out = extract_text_native(&DocumentFormat::Txt, b"id 11010519491231002X");
        assert!(out.text.contains("11010519491231002X"));
        assert!(!out.incomplete);
        let out = extract_text_native(&DocumentFormat::Markdown, b"# x\nid 11010519491231002X");
        assert!(out.text.contains("11010519491231002X"));
    }

    #[test]
    fn html_text_is_extracted_without_tags() {
        let out = extract_text_native(
            &DocumentFormat::Html,
            b"<html><body><p>id 11010519491231002X</p></body></html>",
        );
        assert!(out.text.contains("11010519491231002X"));
        assert!(!out.text.contains("<p>"), "tags must not survive as text");
    }

    /// Fail closed: undecodable bytes must NOT yield empty-but-complete.
    #[test]
    fn invalid_utf8_txt_is_incomplete_not_silently_empty() {
        let out = extract_text_native(&DocumentFormat::Txt, &[0xff, 0xfe, 0x00]);
        assert!(out.incomplete, "unreadable input must report incomplete");
    }

    /// Fail closed: a corrupt zip must not report a successful empty read.
    #[test]
    fn corrupt_docx_is_incomplete_not_silently_empty() {
        let out = extract_text_native(&DocumentFormat::Docx, b"not a zip at all");
        assert!(out.incomplete, "a corrupt archive must report incomplete");
    }
}
```

Fixture helpers (`docx_with_header_footer`, `docx_with_metadata`, etc.) build real OOXML **without** `python-docx` — this is Rust. The simplest correct approach is a minimal hand-built zip: a valid `.docx` only needs `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, and any extra part you want to test. Write a small `fn zip_of(parts: &[(&str, &str)]) -> Vec<u8>` helper using the `zip` crate (already a `pacgate-docx` dependency; add it to `pacgate-api`'s `Cargo.toml` as a dev-or-normal dependency — confirm which by whether the production code needs it, which it does, so a normal dependency).

- [ ] **Step 2: Run the tests and watch them fail**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api text_extract -- --nocapture
```

Expected: compile error (`extract_text_native` not defined). That is the RED for a new module.

- [ ] **Step 3: Implement the extractor**

Now write the implementation. Requirements, in order of importance:

1. **`docx`/`xlsx`/`pptx`: scan every part under the format's prefix for its text element**, rather than naming parts. For `.docx` that is `word/*.xml` and `<w:t>`; `.xlsx` is `xl/*.xml` and `<t>`; `.pptx` is `ppt/*.xml` and `<a:t>`. This is declared-vs-visited *by construction*: a part we do not read is a part we did not scan, so a future Word part type is covered without a code change. Decode with `from_utf8_lossy` so a weird part cannot abort the read, but see requirement 4.
2. **Also read `docProps/core.xml` and `docProps/app.xml`**, emitting each field as a labelled line (e.g. `creator: Sylvie Chen`) so the redactor sees a normal string and can act on it. Field names to include: `creator`, `lastModifiedBy`, `title`, `subject`, `keywords`, `description`, `category`, `contentStatus`, `company`, `manager`. This is finding F4 and it is not optional — the client spec requires metadata coverage.
3. **`.txt`/`.md`:** `String::from_utf8`. On failure return `incomplete: true` with empty text (never lossy-decode prose silently — that would change what the redactor sees).
4. **`.html`:** strip tags to text. Reuse the same scan-the-document approach rather than a regex over the whole file.
5. **`incomplete` is true when:** any zip part under the format prefix failed to be read, OR the archive could not be opened, OR a required part was absent, OR the format is not one of the six. Never `Err`.
6. **`parts_read`** records what was actually scanned, for diagnostics and for the gate to assert on.
7. **`engine`** is a short stable label per route (`ooxml-zip-scan`, `plain-text`, `html-strip`) — `extract.rs` persists it in `document_extractions.engine`.

Write thorough doc comments explaining *why* the scan is prefix-based rather than a part list (F2) and *why* `docProps` is read separately (F4). A future maintainer will otherwise "simplify" it back into the bug.

- [ ] **Step 4: Run the tests and watch them pass**

```powershell
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-api text_extract -- --nocapture
```

Expected: all pass. If `docx_reads_header_and_footer_not_just_the_body` passes only after you add an explicit header part name, you have reimplemented the bug — go back to requirement 1 and make it prefix-based.

- [ ] **Step 5: Register the module and commit**

Add `mod text_extract;` to `pacgate-ai/crates/pacgate-api/src/lib.rs` beside the other `mod` declarations.

```powershell
git add pacgate-ai/crates/pacgate-api/src/text_extract.rs pacgate-ai/crates/pacgate-api/src/lib.rs pacgate-ai/crates/pacgate-api/Cargo.toml
git commit -m "feat(extract): read text-native documents directly, including metadata"
```

---

## Task 4: Route text-native formats to the extractor

**Files:**
- Modify: `pacgate-ai/crates/pacgate-api/src/extract.rs`

**Interfaces:**
- Consumes: `text_extract::extract_text_native` and `TextExtraction` from Task 3.
- Produces: `extract_document` returns correct text for all six text-native formats, persisting `engine` from the extractor. `ExtractedDocument`'s shape is unchanged.

- [ ] **Step 1: Add the routing decision at the top of `extract_document`**

The function currently reads `version` and `storage_path`, checks the cache, then unconditionally reads bytes and calls `ocr-service`. Insert the branch immediately after the cache block, before the `ocr-service` call, so a text-native document never reaches OCR:

```rust
    // Route by format. Text-native documents have their text IN THE FILE, so they
    // are read directly and never reach ocr-service - OCR would invent coordinates
    // for content that never was pixels, and document_spans needs x/y/w/h
    // (spec section 3). Raster input keeps the OCR path unchanged.
    let doc_format: String = sqlx::query("SELECT format FROM documents WHERE id = $1 LIMIT 1")
        .bind(document_id.0)
        .fetch_one(&state.db)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?
        .get("format");

    let text_native = matches!(
        doc_format.as_str(),
        "docx" | "xlsx" | "pptx" | "txt" | "markdown" | "html"
    );

    if text_native {
        let abs_path = std::path::Path::new(&state.config.data_dir).join(&storage_path);
        let bytes = std::fs::read(&abs_path).map_err(|e| {
            ApiError::internal(format!(
                "failed to read stored document {}: {e}",
                abs_path.display()
            ))
        })?;

        let format = match doc_format.as_str() {
            "docx" => DocumentFormat::Docx,
            "xlsx" => DocumentFormat::Xlsx,
            "pptx" => DocumentFormat::Pptx,
            "html" => DocumentFormat::Html,
            "markdown" => DocumentFormat::Markdown,
            _ => DocumentFormat::Txt,
        };

        let out = crate::text_extract::extract_text_native(&format, &bytes);

        // Text-native formats have no raster, so there are no spans. Zero spans is
        // correct and is NOT "nothing was read" - `document_extractions` records
        // completeness, which is why the cache must not key on span-emptiness
        // (a point that cost a defect in the previous plan).
        let incomplete = out.incomplete || out.text.trim().is_empty();
        let pages = 1u32;

        record_extraction(
            state, tenant_id, matter_id, document_id, version, incomplete, pages,
            &out.engine,
        )
        .await?;
        if !out.text.is_empty() {
            ingest_text_pending(state, tenant_id, matter_id, document_id, &out.text).await?;
        }

        return Ok(ExtractedDocument {
            text: out.text,
            pages,
            spans: Vec::new(),
            incomplete,
        });
    }
```

Add `use pacgate_core::DocumentFormat;` to the file's imports.

Note `persist_extraction` is deliberately NOT called: there are no spans to persist, and calling it with an empty slice is a no-op that only obscures intent.

- [ ] **Step 2: Compile**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" build -p pacgate-api
```

Expected: compiles clean (the two pre-existing `memory_revision`/`check_revision` dead-code warnings are unrelated and stay).

- [ ] **Step 3: Rebuild and shadow the API image**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$sha = (git rev-parse HEAD).Trim()
docker build -t pacgate-api:local --build-arg PAC_SOURCE_REVISION=$sha -f pacgate-ai/Dockerfile pacgate-ai
docker tag pacgate-api:local ghcr.io/jzkk720/pacgate-api:0.1.17
cd deploy/client-bundle
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps pacgate-api
```

Both flags matter: `--build-arg` keeps `/version` honest (otherwise `test-version-marker-against-image.ps1` fails), and `--no-deps` avoids recreating dependencies. Run from `deploy/client-bundle/`.

- [ ] **Step 4: Run the gate — T1-T6 should now pass**

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr
pwsh -File scripts/test-text-native-sanitize.ps1
```

Expected: exit 0, every case green including **T4 (identifier only in the header)** and CONTROL.

T4 is the assertion that matters. If it fails, the header text is not reaching the sanitizer and the document would egress with a leaked identifier — stop and fix `text_extract`, do not adjust the gate.

- [ ] **Step 5: Confirm nothing regressed in the raster lane**

```powershell
pwsh -File scripts/test-empty-extraction-gate.ps1
```

Expected: 15 of 15, exit 0. The PDF/blank-page behaviour is untouched by this plan, so any change here is a real regression in the routing.

- [ ] **Step 6: Commit**

```powershell
git add pacgate-ai/crates/pacgate-api/src/extract.rs
git commit -m "feat(extract): route text-native formats to the direct reader, never to OCR"
```

---

## Task 5: Wire the gate in and record the delivery requirement

**Files:**
- Modify: `scripts/run-all-checks.ps1`
- Modify: `docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md` (§13 Delivery — NOT §12; the spec was renumbered when §11 was added)

**Interfaces:**
- Consumes: `scripts/test-text-native-sanitize.ps1` from Task 1.
- Produces: the gate runs in the standard suite; the release requirement is recorded.

- [ ] **Step 1: Read the existing live-stack gate list**

The suite has a `$liveStackGates` array plus its own loop that honours exit 2 as `SKIP CANNOT CHECK`. Read it before editing:

```powershell
Select-String -Path scripts/run-all-checks.ps1 -Pattern 'liveStackGates' -Context 2,12
```

Add `'scripts/test-text-native-sanitize.ps1'` to that list. Do NOT add it to `$gates` — it needs the stack and exits 2 when the stack is down.

- [ ] **Step 2: Run the full suite**

```powershell
pwsh -File scripts/run-all-checks.ps1
```

Expected: `ALL 21 GATES PASSED (2 live-stack gate(s) checked separately)`, exit 0. The count of live-stack gates rises from 1 to 2.

If a mutation suite fails, check `git status --short` for harness residue and a stale `.git/mutation-guard-backup` before investigating anything else — one residue cascades into four red gates.

- [ ] **Step 3: Record the release requirement**

Append to §13 (Delivery) of the spec. **Verify the section number first** with
`Select-String -Path docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md -Pattern '^## '`
— an earlier revision of this plan said §12, which is Non-goals.

```markdown
### Plan B release requirement

`pacgate-api` is a single image (the Dockerfile builds the crate), so the text
extractor cannot be delivered by config or a bind-mount. Plan B requires a **tagged
release** rebuilding `pacgate-api`. No migration is added by Plan B — the format
allowlist is code, not schema.

Until that release ships, the fix exists only as a dev-box image shadow and
`docker compose pull` reverts it.
```

- [ ] **Step 4: Commit**

```powershell
git add scripts/run-all-checks.ps1 docs/superpowers/specs/2026-09-24-document-coverage-and-text-sanitize-design.md
git commit -m "test: run the text-native gate in the suite; record Plan B's release requirement"
```

---

## Self-Review

**Spec coverage (§7 and §8):**

| spec requirement | task | note |
|---|---|---|
| `.txt`/`.md` direct read | 3 | |
| `.docx`/`.xlsx`/`.pptx` via a converter | 3 | **implemented as a Rust zip-scan, not the conversion service §7.1 recommended** — see the §7.1 amendment: no new service, no Python in the safety path, and one function covers all three |
| `.html` via converter | 3 | tag-strip, same principle |
| upload allowlist widened for images | **NOT IN THIS PLAN** | images are raster and belong with the OCR lane; widening the allowlist for `.png`/`.jpg` is a small separate change, deferred so this plan stays text-only. Recorded as a gap, not forgotten. |
| `.pdf` text-layer probe | **NOT IN THIS PLAN** | deferred: it changes the raster lane's routing, which this plan deliberately leaves untouched. |
| conversion coverage gate (§7.2) | 3, 4 | **reshaped**: refusing on a skipped part would make every real Word document unsanitizable (F2). Reading all parts is the fix, and `incomplete` still fails closed for a part that could not be read at all. |
| reject `.doc`/`.xls`/`.ppt`/`.wps`/`.msg`/`.odt` | 2 | named message with a re-save remedy |
| metadata coverage | 3 | F4; explicitly required by the client spec |

**Placeholder scan:** every step carries real code. The fixture helpers in Task 3 are described rather than written out — they are test scaffolding whose exact shape depends on the `zip` API, and the tests that consume them are given verbatim. That is the one place I chose description over code, and it is deliberate: a wrong helper signature written into the plan would be copied rather than corrected.

**Type consistency:** `extract_text_native(&DocumentFormat, &[u8]) -> TextExtraction` is declared in Task 3 and called in Task 4 with exactly those argument types. `TextExtraction`'s four fields (`text`, `incomplete`, `parts_read`, `engine`) are declared once and read in Task 4 (`text`, `incomplete`, `engine`) — `parts_read` is consumed only by tests and diagnostics. `record_extraction`'s signature is unchanged from Plan A (`state, tenant_id, matter_id, document_id, version, incomplete, pages, &engine`) and Task 4 calls it with those types (`version: i32`, `pages: u32`, `&out.engine` from a `String`). The format strings used by the router (`"docx" | "xlsx" | "pptx" | "txt" | "markdown" | "html"`) match what Task 2 writes into the store and reads back in `row_to_document`.

**One conflict I ruled on:** Task 2 changes the upload rejection message, which `scripts/probe-format-lanes.py` quotes in a docstring. That probe is diagnostic and not wired into any suite, so it does not fail — but its quoted message becomes stale. Left as-is deliberately: updating a probe's prose is not worth a task, and the message change is the point of Task 2.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-24-text-native-document-coverage.md`.

Two execution options:

**1. Subagent-Driven (recommended)** — a fresh subagent per task with review between tasks. Task 3 is the one that needs the closest review: its whole value is reading parts the old code missed, and a plausible-looking implementation that hardcodes `header1.xml`/`footer1.xml` would pass every test I wrote while reproducing the bug for a two-header document.

**2. Inline Execution** — tasks in this session with checkpoints.

**Which approach?**
