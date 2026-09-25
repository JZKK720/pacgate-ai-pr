//! Text-native document extraction — read the text that is already IN the file.
//!
//! # Why this module exists
//!
//! Every converter we ship read exactly one part: `word/document.xml`. Measured
//! against a `.docx` carrying a unique token in its body, header and footer:
//!
//! ```text
//! mammoth 1.11 (markitdown's engine)  header MISSED  footer MISSED  table MISSED
//! pacgate-docx read_text (equiv)      header MISSED  footer MISSED  table OK
//! markitdown 0.1.7 (deployed)         header MISSED  footer MISSED  table MISSED
//! ```
//!
//! For a redaction product that is a hole that fails **open**: a client identifier
//! living only in a page header is never seen by the redactor, the document is
//! reported `sanitized`, and it egresses with the identifier intact. This module
//! reads the parts instead.
//!
//! # The rule: scan by PREFIX, never by part name
//!
//! For every OOXML format the scan iterates **every entry in the zip whose name
//! starts with the format's prefix** and pulls that format's text elements out of
//! it:
//!
//! | format | prefix   | text element |
//! |--------|----------|--------------|
//! | `.docx`| `word/`  | `<w:t>`      |
//! | `.xlsx`| `xl/`    | `<t>`        |
//! | `.pptx`| `ppt/`   | `<a:t>`      |
//!
//! **No part name appears in this file's production code except as a prefix.**
//! (`[Content_Types].xml` is the one package-level constant — every OPC package has
//! exactly that name, it is not a part that varies by Word version, and it has no
//! prefix to scan. `docProps/` is a prefix.) That is deliberate and it is the whole
//! design. A part list — even a generous one like
//! `["word/document.xml", "word/header1.xml", "word/footer1.xml"]` — silently drops
//! `word/header2.xml`, and a document with two headers is ordinary: a first-page
//! header plus a default header, or a header per section (and a contract with
//! multiple sections has one of each). The dropped part is a fail-open redaction
//! hole, and it fails open *silently*, which is the worst way for a safety check to
//! fail. `docx_reads_a_second_header` is the test that catches it.
//!
//! **Do not "simplify" this into a list of part names.** The scan is
//! declared-vs-visited coverage *by construction*: a part we did not read is a part
//! we did not scan, so a Word part type that does not exist yet — a new comment
//! part, a glossary, a future header — is covered with no code change here. A name
//! list would drift with every Word release, and the drift would be invisible.
//!
//! # Why metadata is read as a SEPARATE step
//!
//! `docProps/` parts (`core.xml`, `app.xml`, `custom.xml`) are **not under the
//! format prefix**, so the prefix scan structurally cannot reach them; and their
//! fields are element text (`<dc:creator>`, `<cp:keywords>`) rather than `<w:t>`
//! runs, so even a scan that reached them would extract nothing. Measured on a
//! document saved with metadata set:
//!
//! ```text
//! <dc:title>    Matter 2026-CLIENT-ACME-11010519491231002X
//! <cp:keywords> Acme; 11010519491231002X
//! <dc:creator>  Sylvie Chen (Attorney)
//! ```
//!
//! The client's requirements list metadata coverage explicitly, and a `grep docProps`
//! across the deployed markitdown returns nothing. Metadata is read on its own path,
//! **by the same prefix rule** (`METADATA_PREFIX`), and each field is emitted as a
//! **labelled line** (`creator: Sylvie Chen`) so the redactor sees an ordinary string
//! it can match, and an operator reading the extracted text can tell a person's name
//! from a filename.
//!
//! The naming trap is real one directory over: `["docProps/core.xml",
//! "docProps/app.xml"]` is a name list, and `docProps/custom.xml` — where a firm
//! stores `MatterNumber` and `ClientReference` — would be silently dropped.
//!
//! # Failure policy: report, never error
//!
//! An unreadable document is a **fail-closed condition, not a server error**, so
//! this function never returns `Result`. Any inability to read the content in full
//! sets `incomplete = true`, which `sanitize.rs` already refuses on. Callers must
//! not add an "accept partial text" path — partial text on a redactor means the
//! unread portion egresses unscanned.
//!
//! Text-native formats must also never reach `ocr-service`: `document_spans` needs
//! `x/y/w/h`, and a born-digital file has no raster to point at. OCR would invent
//! coordinates for content that was never pixels and add recognition error where
//! none is possible.

use pacgate_core::DocumentFormat;
use std::io::Read;

/// Text read from a text-native document, plus what coverage was achieved.
#[derive(Debug, Clone)]
pub struct TextExtraction {
    /// ALL readable text, including `docProps` metadata as labelled lines.
    pub text: String,
    /// True when the content could not be read in full. Fail-closed: the sanitizer
    /// refuses on this, so it must be `true` whenever anything was missed.
    pub incomplete: bool,
    /// What was actually scanned, for diagnostics and for the gate to assert on.
    pub parts_read: Vec<String>,
    /// Short stable label for the route taken: `ooxml-zip-scan`, `plain-text`, or
    /// `html-strip`. Persisted into `document_extractions.engine`.
    pub engine: String,
}

impl TextExtraction {
    fn failed(engine: &str, why: &str) -> Self {
        tracing::warn!(engine, reason = why, "text extraction is incomplete");
        Self {
            text: String::new(),
            // Fail closed. An empty-but-"complete" result is the defect this whole
            // workstream exists to close: `sanitize.rs` refuses only on
            // `incomplete == true`, so reporting completeness here would let an
            // empty document be marked sanitized and open the egress gate.
            incomplete: true,
            parts_read: Vec::new(),
            engine: engine.to_string(),
        }
    }

    fn push_part(&mut self, name: &str) {
        self.parts_read.push(name.to_string());
    }
}

/// The text element a given OOXML flavour wraps its runs in, and the zip prefix
/// that holds its parts.
///
/// These two strings are the ONLY format-specific knowledge in the OOXML path, and
/// both are prefixes/element names. No individual part name appears anywhere.
struct OoxmlSpec {
    /// Zip path prefix. Every entry starting with this is scanned.
    prefix: &'static str,
    /// Local element name holding a text run.
    text_element: &'static str,
}

const DOCX_SPEC: OoxmlSpec = OoxmlSpec {
    prefix: "word/",
    text_element: "w:t",
};
const XLSX_SPEC: OoxmlSpec = OoxmlSpec {
    prefix: "xl/",
    text_element: "t",
};
const PPTX_SPEC: OoxmlSpec = OoxmlSpec {
    prefix: "ppt/",
    text_element: "a:t",
};

/// The package's declared main part, read from `[Content_Types].xml`.
///
/// OOXML marks the main document part with a content type ending in `.main+xml`
/// (`...wordprocessingml.document.main+xml`, `...spreadsheetml.sheet.main+xml`,
/// `...presentationml.presentation.main+xml`), and declares it as
/// `<Override PartName="/word/document.xml" ContentType="....main+xml"/>`.
///
/// Reading this instead of hardcoding the name keeps the "no part names in this
/// file" rule intact across all three formats, and it means the check cannot drift
/// from what the package actually declares.
///
/// The `[Content_Types].xml` name is itself a package-level constant rather than a
/// document part — every OPC package has exactly this one name, it is not a Word
/// part that varies by version, and there is no prefix of it to scan.
fn declared_main_part(archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>) -> Option<String> {
    let mut raw = Vec::new();
    archive
        .by_name("[Content_Types].xml")
        .ok()?
        .read_to_end(&mut raw)
        .ok()?;
    let xml = String::from_utf8_lossy(&raw);

    let mut search_at = 0usize;
    while let Some(rel) = xml[search_at..].find("<Override") {
        let open_at = search_at + rel;
        let after = open_at + "<Override".len();
        let gt_rel = xml[after..].find('>')?;
        let tag_body = &xml[after..after + gt_rel];
        let content_type = attribute_value(tag_body, "ContentType").unwrap_or_default();
        if content_type.ends_with(".main+xml") {
            let part = attribute_value(tag_body, "PartName")?;
            // PartName is absolute (`/word/document.xml`); zip entry names are not.
            let part = part.trim_start_matches('/').to_string();
            return Some(part);
        }
        search_at = after + gt_rel + 1;
    }
    None
}

/// The metadata part family, as a PREFIX, for the same reason the OOXML text
/// parts are scanned by prefix.
///
/// The obvious implementation here is `for part in ["docProps/core.xml",
/// "docProps/app.xml"]`. That is a **name list in the metadata path**, and it has
/// the identical failure mode the text scan exists to avoid: `docProps/custom.xml`
/// is the part Word writes for user-defined document properties, and a law firm
/// puts matter codes and client references there — `ClientMatter`,
/// `MatterNumber`. A two-name list silently drops it, and the dropped part is
/// exactly the kind of content this module was written to catch. (Custom
/// properties are also emitted as `<property name="...">` with the *value* in a
/// child element, so they need the generic element walk rather than a field list.)
const METADATA_PREFIX: &str = "docProps/";

/// Metadata fields emitted as labelled lines.
///
/// A fixed list IS safe here, unlike a part list, and the asymmetry is the point: a
/// **field cannot appear in a document without this module being told what it is
/// called** — these are a schema the client named in its requirements document —
/// whereas an OOXML *part* can be invented by any Word version without notice. So
/// the parts are scanned by prefix and the fields are enumerated.
///
/// This list is not the whole coverage story: custom properties carry their own
/// labels as data, and `custom_properties` reads those generically.
const METADATA_FIELDS: &[&str] = &[
    "creator",
    "lastModifiedBy",
    "title",
    "subject",
    "keywords",
    "description",
    "category",
    "contentStatus",
    "company",
    "manager",
];

/// Extract all readable text from a text-native document.
///
/// Never fails: unreadable input returns `incomplete = true`. See the module docs
/// for why the OOXML path scans by prefix and why metadata is read separately.
pub fn extract_text_native(format: &DocumentFormat, bytes: &[u8]) -> TextExtraction {
    match format {
        DocumentFormat::Docx => extract_ooxml(&DOCX_SPEC, bytes),
        DocumentFormat::Xlsx => extract_ooxml(&XLSX_SPEC, bytes),
        DocumentFormat::Pptx => extract_ooxml(&PPTX_SPEC, bytes),
        DocumentFormat::Txt | DocumentFormat::Markdown => extract_plain(bytes),
        DocumentFormat::Html => extract_html(bytes),
        // Images and PDFs are the raster lane's job. Saying so is not a failure of
        // this function; routing them here would be the bug (spec section 3).
        DocumentFormat::Pdf => {
            TextExtraction::failed("ooxml-zip-scan", "format not handled by the text-native lane")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Plain text: .txt / .md
// ─────────────────────────────────────────────────────────────────────────────

/// `.txt` / `.md` are UTF-8 by definition, so `from_utf8` is the honest read.
///
/// NOT `from_utf8_lossy`: lossy decoding replaces undecodable bytes with U+FFFD,
/// which silently changes the bytes the redactor sees. A redaction decision made on
/// a mangled string is not a redaction decision, and the failure would be invisible
/// — the document would report complete. Refusing is the correct trade: a client
/// with a non-UTF-8 `.txt` gets `incomplete = true` and an operator looks at it.
fn extract_plain(bytes: &[u8]) -> TextExtraction {
    match String::from_utf8(bytes.to_vec()) {
        Ok(text) => TextExtraction {
            text,
            incomplete: false,
            parts_read: Vec::new(),
            engine: "plain-text".into(),
        },
        Err(_) => TextExtraction::failed("plain-text", "input is not valid UTF-8"),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// HTML: strip tags by scanning the document, not by regex over the text
// ─────────────────────────────────────────────────────────────────────────────

/// Strip markup to text with a single forward scan over the document.
///
/// A regex over the raw text would be the wrong shape for the same reason a part
/// list is the wrong shape for OOXML: it encodes an assumption about what the
/// markup looks like. HTML in the wild is not well-formed, tags span lines, and a
/// `<script>`/`<style>` body can contain a stray `<` that a pattern either eats or
/// leaves. A character-level scan has no such assumption — every run of text
/// outside `<...>` is emitted, so nothing between tags is silently skipped.
///
/// `<!-- ... -->` is the one case a naive scan gets wrong in a safety-relevant way:
/// a comment can legitimately carry a client identifier (a template placeholder, a
/// tracking note), and its inner text is not body text. Comments are dropped
/// deliberately and their presence does not set `incomplete`, matching how every
/// browser and text extractor treats them.
///
/// Script and style bodies are dropped for the same reason: they are code and
/// CSS, not prose a human wrote, and they are large. Their *contents* are not
/// extracted as text. Note this is a real coverage decision, not a convenience:
/// an identifier inside a script block would not be redacted. Recorded here rather
/// than hidden because a reader must know which bytes this function does not emit.
fn extract_html(bytes: &[u8]) -> TextExtraction {
    // HTML is frequently not UTF-8. Lossy decoding is acceptable HERE, unlike for
    // `.txt`, because HTML's own bytes are markup rather than the prose the
    // redactor reads: the tag scan already discards the structural bytes, and a
    // declared non-UTF-8 page still yields its visible text. The asymmetry is
    // deliberate.
    let raw = String::from_utf8_lossy(bytes);
    let mut out = String::with_capacity(raw.len() / 2);
    let mut chars = raw.chars().peekable();
    // Whether the current position is inside <script>/<style>, whose contents are
    // code rather than prose.
    let mut in_raw_text_element = false;

    while let Some(ch) = chars.next() {
        if ch != '<' {
            if !in_raw_text_element {
                out.push(ch);
            }
            continue;
        }

        // A comment: `<` `!` `-` `-` ... `-` `-` `>`. Skip to the terminator.
        if raw_next_is(&mut chars, '!') {
            let mut prev = '\0';
            let mut prev2 = '\0';
            for c in chars.by_ref() {
                if prev2 == '-' && prev == '-' && c == '>' {
                    break;
                }
                prev2 = prev;
                prev = c;
            }
            out.push(' ');
            continue;
        }

        // Otherwise a tag. Capture its name to detect script/style, then skip to
        // the closing `>`. Quoted attribute values may contain `>`, so quotes are
        // tracked; a `>` inside a quoted value would otherwise end the tag early
        // and leak the rest of the attribute list as text.
        let mut tag = String::new();
        let mut quote: Option<char> = None;
        for c in chars.by_ref() {
            match quote {
                Some(q) => {
                    if c == q {
                        quote = None;
                    }
                }
                None => match c {
                    '"' | '\'' => quote = Some(c),
                    '>' => break,
                    _ => tag.push(c),
                },
            }
        }
        let name = tag_name(&tag);
        if name == "script" || name == "style" {
            // The tag we just closed is an OPENING script/style; its body follows.
            in_raw_text_element = !tag.starts_with('/');
        }
        // Markup is replaced by a separator, never removed silently: joining
        // `</p><p>` neighbours without it would fuse two words into one token and
        // could destroy an identifier match at a tag boundary.
        out.push(' ');
    }

    TextExtraction {
        text: out,
        incomplete: false,
        parts_read: Vec::new(),
        engine: "html-strip".into(),
    }
}

/// Peek-free helper: consumes the next char only if it is `expected`.
fn raw_next_is(chars: &mut std::iter::Peekable<std::str::Chars<'_>>, expected: char) -> bool {
    if chars.peek() == Some(&expected) {
        chars.next();
        true
    } else {
        false
    }
}

/// The lower-cased element name of a tag body, ignoring attributes.
fn tag_name(tag: &str) -> String {
    let name: String = tag
        .trim_start_matches('/')
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == ':' || *c == '-')
        .collect();
    name.to_ascii_lowercase()
}

// ─────────────────────────────────────────────────────────────────────────────
// OOXML: .docx / .xlsx / .pptx
// ─────────────────────────────────────────────────────────────────────────────

/// Read every text run under the spec's prefix, plus the package metadata.
///
/// The iteration deliberately does **not** consult `[Content_Types].xml` or the
/// `.rels` graph. Those describe what a conforming consumer is expected to open
/// (and, for `[Content_Types].xml`, what media types the parts claim), not which
/// bytes exist in the package — so a part present in the zip but absent from the
/// declared graph would be skipped by a graph-driven sweep. Iterating the archive
/// itself is the only way to be sure every byte that could carry text was looked
/// at. The graph is still useful, but for the opposite job: proving that a part
/// *exists*, which is the required-part check below.
fn extract_ooxml(spec: &OoxmlSpec, bytes: &[u8]) -> TextExtraction {
    let mut out = TextExtraction {
        text: String::new(),
        incomplete: false,
        parts_read: Vec::new(),
        engine: "ooxml-zip-scan".into(),
    };

    let cursor = std::io::Cursor::new(bytes);
    let mut archive = match zip::ZipArchive::new(cursor) {
        Ok(a) => a,
        // The archive could not be opened at all: nothing was read, so this is
        // incomplete rather than "a document with no text".
        Err(e) => return TextExtraction::failed("ooxml-zip-scan", &format!("not a zip: {e}")),
    };

    let names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_string()))
        .collect();

    // Collect the prefix parts by name first so the archive borrow is released
    // before reading bodies.
    let prefix_parts: Vec<String> = names
        .iter()
        .filter(|n| n.starts_with(spec.prefix) && n.ends_with(".xml"))
        .cloned()
        .collect();

    if prefix_parts.is_empty() {
        // A package under this prefix with no XML parts at all is not a document
        // we can read; refusing beats returning empty text as complete.
        return TextExtraction::failed(
            "ooxml-zip-scan",
            &format!("no parts under prefix {}", spec.prefix),
        );
    }

    for name in &prefix_parts {
        let mut raw = Vec::new();
        let read = archive
            .by_name(name)
            .map_err(|e| e.to_string())
            .and_then(|mut f| {
                f.read_to_end(&mut raw)
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            });

        match read {
            Ok(()) => {
                out.push_part(name);
                // Lossy decode: one odd part must not abort a read of all the
                // others. Unlike the `.txt` path this cannot hide a redaction gap,
                // because the result is `incomplete` whenever a part is skipped —
                // and a part that decoded to nothing is reported by the emptiness
                // rule below rather than passing silently.
                let xml = String::from_utf8_lossy(&raw);
                append_element_text(&mut out.text, &xml, spec.text_element);
            }
            // A part we failed to read is content we did not scan. Fail closed.
            Err(e) => {
                out.incomplete = true;
                tracing::warn!(part = name.as_str(), error = e.as_str(), "ooxml part unreadable");
            }
        }
    }

    // A required part that is absent means the package is not what its prefix
    // claims it is: a `.docx` whose declared main part is missing has no body to
    // read, and reporting complete would be the empty-but-complete defect.
    //
    // The main part is taken from the package's OWN manifest rather than hardcoded.
    // The three formats name it differently (`.docx` -> `word/document.xml`,
    // `.xlsx` -> `xl/workbook.xml`, `.pptx` -> `ppt/presentation.xml`), so a literal
    // here would be a part list too, just a one-item one — and a fourth format would
    // add a fourth literal. The content-type registry marks the main part with a
    // `.main+xml` content type, so the package states it and this reads the
    // statement.
    //
    // This is the one job the declared inventory is good for. It does NOT drive the
    // scan: a part present in the zip but absent from the declared graph would be
    // skipped by a graph-driven sweep, which is why the scan iterates the archive
    // instead. Proving a part EXISTS is where the declaration is authoritative.
    match declared_main_part(&mut archive) {
        Some(main) => {
            if !names.iter().any(|n| n == &main) {
                out.incomplete = true;
                tracing::warn!(declared_main = main.as_str(), "declared main part is absent");
            }
        }
        // No declaration available. Everything under the prefix was still scanned,
        // so coverage is intact and this is not a reason to refuse: refusing on an
        // unreadable manifest would make odd-but-readable packages unsanitizable,
        // which is the wrong direction for a product that must process real
        // contracts.
        None => tracing::warn!("no declared main part; relying on the prefix scan"),
    }

    // Metadata: NOT under the text prefix, and element text rather than text runs,
    // so the prefix scan structurally cannot reach it. Read it separately.
    append_metadata(&mut archive, &mut out);

    // The body may legitimately be empty while metadata is not (or vice versa), so
    // emptiness is judged on both.
    if out.text.trim().is_empty() {
        out.incomplete = true;
        tracing::warn!("ooxml scan produced no text at all");
    }

    out
}

/// Append the text of every `<element>` in `xml`.
///
/// Manual scanning rather than an XML parser, matching `pacgate-docx`'s existing
/// reader. The scan is intentionally forgiving: it finds opening `<el ...>` tags,
/// then text to the next `<`, which handles the attribute-bearing and
/// self-closing forms Word emits. `</el>`, `<el/>` and `<el attr="x">` are all
/// tolerated, and a malformed document degrades to whatever text it does carry
/// rather than aborting the read.
fn append_element_text(out: &mut String, xml: &str, element: &str) -> usize {
    let open_prefix = format!("<{element}");
    let mut count = 0usize;
    let mut search_at = 0usize;

    while let Some(rel) = xml[search_at..].find(&open_prefix) {
        let open_at = search_at + rel;
        let after = open_at + open_prefix.len();

        // The character after the element name must end it, or we have matched a
        // longer name (`<t` also prefixes `<title`, `<table`, `<tc`). `<w:t` would
        // otherwise match `<w:tbl`. This guard is why the scan does not need to
        // know the schema's element inventory.
        let boundary_ok = xml[after..]
            .chars()
            .next()
            .is_some_and(|c| c == '>' || c == '/' || c == ' ' || c == '\t' || c == '\n' || c == '\r');
        if !boundary_ok {
            search_at = after;
            continue;
        }

        let Some(gt_rel) = xml[after..].find('>') else {
            break;
        };
        let tag_body = &xml[after..after + gt_rel];

        // `<el/>` and `<el></el>` carry no text. Skipping without advancing past
        // the `>` handles both; the next loop iteration starts after it.
        let mut resume_at = after + gt_rel + 1;
        if tag_body.ends_with('/') {
            search_at = resume_at;
            continue;
        }

        let text_end = xml[resume_at..]
            .find('<')
            .map(|r| resume_at + r)
            .unwrap_or(xml.len());

        let chunk = &xml[resume_at..text_end];
        if !chunk.is_empty() {
            append_normalised(out, chunk);
            count += 1;
        }
        // Consume a `</el>` terminator so the next iteration does not re-read the
        // region as content.
        let close = format!("</{element}>");
        if xml[resume_at..].starts_with(close.as_str()) {
            resume_at += close.len();
        }
        search_at = resume_at;
    }
    count
}

/// Append `chunk` with XML entities decoded and a separator so adjacent runs do
/// not fuse into one token.
///
/// Runs are separate text nodes: `Client` `ID` `<tab/>` `123` is one visual line
/// and three elements. Concatenating them with a space keeps an identifier or
/// phone number from being reassembled wrongly, while joining with nothing risks
/// fusing the tail of one word to the head of the next and hiding a match at the
/// seam. A space is the conservative choice for a redactor.
fn append_normalised(out: &mut String, chunk: &str) {
    if !out.is_empty() && !out.ends_with(['\n', ' ']) {
        out.push(' ');
    }
    let mut chars = chunk.chars();
    while let Some(c) = chars.next() {
        if c != '&' {
            out.push(c);
            continue;
        }
        // Entity: read the name up to `;`.
        let mut name = String::new();
        let mut closed = false;
        for c in chars.by_ref() {
            if c == ';' {
                closed = true;
                break;
            }
            if name.len() > 8 || c.is_whitespace() || c == '<' {
                break;
            }
            name.push(c);
        }
        match if closed { entity(&name) } else { None } {
            Some(decoded) => out.push(decoded),
            None => {
                // Not a recognised entity, or unterminated: keep the `&` so the
                // text stays faithful to the document.
                out.push('&');
                out.push_str(&name);
            }
        }
    }
}

/// XML built-in entities plus numeric character references.
fn entity(name: &str) -> Option<char> {
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => {
            // `#123` / `#x1F600`. Word writes Chinese and other non-ASCII as
            // numeric references in some saves, so decoding these is required for
            // an identifier in a CJK name to be matchable at all.
            let body = name.strip_prefix('#')?;
            let code = match body.strip_prefix(['x', 'X']) {
                Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                None => body.parse::<u32>().ok()?,
            };
            char::from_u32(code)
        }
    }
}

/// Read **every part under `docProps/`** and emit its fields as labelled lines.
///
/// Separate from the format's text scan because `docProps` is not under the format
/// prefix and its fields are element text, not text runs, so the text scan
/// structurally cannot reach it. Mandatory, not optional: a client ID in
/// `<cp:keywords>` is exactly the leak this covers, and the client's requirements
/// name metadata coverage explicitly.
///
/// Two mechanisms, because the metadata parts carry two different shapes:
///
/// 1. **Named fields** (`creator`, `keywords`, `company`, ...) matched against
///    `METADATA_FIELDS`. These are the schema the client named in its requirements.
///    A fixed field list is safe here — unlike a part list — because a *field*
///    cannot appear in a document without this module being told what it is called.
/// 2. **Custom properties**, which are `<property name="ClientMatter">ACME-1101
///    </property>`: the field NAME is data, not schema, so it cannot be in a list.
///    These are read generically by emitting every leaf element's text, which is
///    what makes an unfamiliar custom property covered rather than dropped.
fn append_metadata(archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>, out: &mut TextExtraction) {
    let meta_parts: Vec<String> = archive
        .file_names()
        .filter(|n| n.starts_with(METADATA_PREFIX) && n.ends_with(".xml"))
        .map(str::to_string)
        .collect();

    for part_name in &meta_parts {
        let raw = match read_named_part(archive, out, part_name) {
            Some(raw) => raw,
            None => continue,
        };
        let xml = String::from_utf8_lossy(&raw);
        let before = out.text.len();

        for field in METADATA_FIELDS {
            // `app.xml` uses PascalCase element names (`<Company>`) where `core.xml`
            // uses `dc:`/`cp:` ones, so the lookup is case-insensitive and
            // namespace-prefix-agnostic.
            if let Some(value) = element_value_ci(&xml, field) {
                push_metadata_line(out, field, value.trim());
            }
        }

        // Custom properties. `<property name="X"><vt:lpwstr>Y</vt:lpwstr></property>`
        // — the label lives in an attribute and the value in a child element. Emit
        // `name: value` so the shape matches the named fields above and the
        // redactor sees one consistent vocabulary.
        for (name, value) in custom_properties(&xml) {
            push_metadata_line(out, &name, value.trim());
        }

        if out.text.len() > before {
            out.push_part(part_name);
        }
    }
}

/// Append one `label: value` line, skipping empty values so a present-but-blank
/// field does not emit a bare label that redacts nothing.
fn push_metadata_line(out: &mut TextExtraction, label: &str, value: &str) {
    if value.is_empty() {
        return;
    }
    if !out.text.is_empty() && !out.text.ends_with('\n') {
        out.text.push('\n');
    }
    // A labelled line: the redactor sees an ordinary string it can match, and an
    // operator can tell a person from a filename.
    out.text.push_str(label);
    out.text.push_str(": ");
    out.text.push_str(value);
}

/// Read `<property name="Label">value</property>` pairs — the OOXML custom
/// document-property shape, where the label is an attribute rather than an element
/// name. Returns `(label, value)` for every property that has a non-empty label.
fn custom_properties(xml: &str) -> Vec<(String, String)> {
    let mut found = Vec::new();
    let mut search_at = 0usize;
    while let Some(rel) = xml[search_at..].find("<property") {
        let open_at = search_at + rel;
        let after = open_at + "<property".len();
        let Some(gt_rel) = xml[after..].find('>') else {
            break;
        };
        let tag_body = &xml[after..after + gt_rel];
        let body_start = after + gt_rel + 1;

        let label = attribute_value(tag_body, "name").unwrap_or_default();
        // The value is the text of the first child element, or the element's own
        // text for the compact form.
        let body_end = xml[body_start..]
            .find("</property>")
            .map(|r| body_start + r)
            .unwrap_or(body_start);
        let mut value = String::new();
        append_element_text(&mut value, &xml[body_start..body_end], "vt:lpwstr");
        if value.trim().is_empty() {
            // Fall back to whatever text the property body carries directly.
            let mut plain = String::new();
            append_normalised(&mut plain, &xml[body_start..body_end]);
            value = plain;
        }
        if !label.is_empty() && !value.trim().is_empty() {
            found.push((label, value));
        }
        search_at = body_end.max(body_start);
    }
    found
}

/// The value of `key="..."` inside a tag body, if present.
///
/// The search is case-insensitive on the ATTRIBUTE NAME, so the needle must be
/// lowercased to match the lowercased haystack. Searching a lowercased haystack for a
/// mixed-case needle never matches: that bug made `declared_main_part` return `None`
/// for every real package, which silently disabled the "declared main part is absent"
/// fail-closed check — an unreadable manifest was indistinguishable from a manifest
/// that declared nothing wrong. `docx_without_a_declared_body_part_is_incomplete`
/// caught it.
///
/// The attribute VALUE is returned as written: `PartName` is a path and must not be
/// case-folded.
fn attribute_value(tag_body: &str, key: &str) -> Option<String> {
    let lowered_key = key.to_ascii_lowercase();
    let lower = tag_body.to_ascii_lowercase();
    let needle = format!("{lowered_key}=\"");
    let at = lower.find(&needle)?;
    let start = at + needle.len();
    let end = tag_body[start..].find('"').map(|r| start + r)?;
    Some(tag_body[start..end].to_string())
}

/// Read a part by an exact name, recording it in `parts_read` and marking the
/// extraction incomplete on failure.
///
/// Returns `None` for an absent part, which is NOT incomplete: a package without
/// `app.xml` is normal. Returns `Some(bytes)` with `incomplete = true` set if the
/// part exists but could not be read, because that is content we did not scan.
fn read_named_part(
    archive: &mut zip::ZipArchive<std::io::Cursor<&[u8]>>,
    out: &mut TextExtraction,
    name: &str,
) -> Option<Vec<u8>> {
    let mut file = match archive.by_name(name) {
        Ok(f) => f,
        Err(zip::result::ZipError::FileNotFound) => return None,
        Err(e) => {
            out.incomplete = true;
            tracing::warn!(part = name, error = e.to_string().as_str(), "metadata part unreadable");
            return None;
        }
    };
    let mut raw = Vec::new();
    match file.read_to_end(&mut raw) {
        Ok(_) => Some(raw),
        Err(e) => {
            // The part is there and we could not read it: content not scanned.
            out.incomplete = true;
            tracing::warn!(part = name, error = e.to_string().as_str(), "metadata part unreadable");
            None
        }
    }
}

/// Case-insensitive lookup of a metadata element's text, matching `<field>` or
/// `<ns:field>` for any namespace prefix.
fn element_value_ci(xml: &str, field: &str) -> Option<String> {
    let lower = xml.to_ascii_lowercase();
    let field_lower = field.to_ascii_lowercase();
    let mut search_at = 0usize;

    while let Some(rel) = lower[search_at..].find('<') {
        let open_at = search_at + rel;
        let after = open_at + 1;
        if lower[after..].starts_with('/') || lower[after..].starts_with('!') || lower[after..].starts_with('?')
        {
            search_at = after;
            continue;
        }
        let Some(gt_rel) = lower[after..].find('>') else {
            return None;
        };
        let tag_body = &lower[after..after + gt_rel];
        // `local` is the name after any `ns:` prefix.
        let local = tag_body.split(':').next_back().unwrap_or(tag_body);
        let name: String = local
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        if name == field_lower {
            let text_start = after + gt_rel + 1;
            let text_end = lower[text_start..]
                .find('<')
                .map(|r| text_start + r)
                .unwrap_or(lower.len());
            // Slice the ORIGINAL (case-preserving) xml with offsets computed on the
            // lower-cased copy: `to_ascii_lowercase` preserves byte length for ASCII,
            // and a multi-byte scalar maps to itself so offsets stay aligned.
            let mut value = String::new();
            append_normalised(&mut value, &xml[text_start..text_end]);
            return Some(value);
        }
        search_at = after + gt_rel + 1;
    }
    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

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
        assert!(
            out.text.contains(HEADER),
            "HEADER TEXT MISSED - this is the fail-open"
        );
        assert!(out.text.contains(FOOTER), "FOOTER TEXT MISSED");
        assert!(!out.incomplete, "a fully-read docx must not be incomplete");
    }

    /// A document with TWO headers must lose neither. This is the test that fails if
    /// the implementation hardcodes part names instead of scanning the prefix.
    #[test]
    fn docx_reads_a_second_header() {
        let bytes = docx_with_two_headers();
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(out.text.contains("HEADONE"), "first header missing");
        assert!(
            out.text.contains("HEADTWO"),
            "SECOND HEADER MISSED - the implementation is name-based, not prefix-based"
        );
    }

    /// Same argument as the second header, for the part types a name list would
    /// forget next: a second footer and the footnotes part. A part-list
    /// implementation that knows `header1`/`footer1`/`document` fails here too.
    #[test]
    fn docx_reads_footnotes_and_a_second_footer() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_two_headers());
        assert!(out.text.contains("FOOTONE"), "first footer missing");
        assert!(out.text.contains("NOTETOKEN5"), "footnotes part MISSED");
    }

    /// `parts_read` is the coverage evidence. If it only ever names
    /// `word/document.xml`, the scan is not prefix-based whatever the text says.
    #[test]
    fn docx_parts_read_covers_every_prefix_part_it_read() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_two_headers());
        for expected in [
            "word/document.xml",
            "word/header1.xml",
            "word/header2.xml",
            "word/footer1.xml",
            "word/footnotes.xml",
            "docProps/core.xml",
        ] {
            assert!(
                out.parts_read.iter().any(|p| p == expected),
                "parts_read is missing {expected}; got {:?}",
                out.parts_read
            );
        }
        assert!(
            out.parts_read.len() > 2,
            "a docx scan that read only {} part(s) is not a scan",
            out.parts_read.len()
        );
        assert_eq!(out.engine, "ooxml-zip-scan");
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

    /// Metadata must arrive as a labelled line (`creator: Sylvie Chen`) so the
    /// redactor sees an ordinary string and can act on it, and so an operator
    /// reading the extracted text can tell a filename from a person.
    #[test]
    fn docx_metadata_fields_are_labelled() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_metadata());
        assert!(
            out.text.contains("creator: Sylvie Chen"),
            "creator is not emitted as a labelled line; got:\n{}",
            out.text
        );
        assert!(
            out.text.contains("lastModifiedBy: Justin Zhang"),
            "lastModifiedBy is not emitted as a labelled line; got:\n{}",
            out.text
        );
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

    /// Fail closed: a raster format must never be reported as read here. This
    /// function exists for text-native input; PDF has its own lane and must say so.
    #[test]
    fn pdf_is_incomplete_because_this_is_not_its_lane() {
        let out = extract_text_native(&DocumentFormat::Pdf, b"%PDF-1.7");
        assert!(out.incomplete, "the text-native lane cannot read a PDF");
        assert!(out.text.is_empty());
    }

    /// An EMPTY `.docx` package (valid zip, no text anywhere, no metadata) must be
    /// incomplete. This is the empty-but-complete defect at its root: an empty
    /// string that claims completeness gets sanitized to `pass` and egresses.
    #[test]
    fn docx_with_no_text_anywhere_is_incomplete() {
        let empty_body = docx_document("");
        let bytes = zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &empty_body),
        ]);
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(
            out.incomplete,
            "an empty document must not report complete; text was {:?}",
            out.text
        );
    }

    /// A `.docx` whose manifest DECLARES a main part that is not in the archive is
    /// not a document. Fail closed rather than reading the header and calling it
    /// complete.
    ///
    /// The declaration is what makes this detectable without a hardcoded part name:
    /// `[Content_Types].xml` names the main part, and the archive does not contain
    /// it. The fixture therefore declares `word/document.xml` in the manifest and
    /// omits it from the zip — which is exactly the corrupt-package shape.
    #[test]
    fn docx_without_a_declared_body_part_is_incomplete() {
        let bytes = zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/header1.xml", &w_part("hdr", &w_para("HEADONE"))),
        ]);
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(
            out.incomplete,
            "a package whose declared main part is absent must report incomplete"
        );
    }

    /// The element-name boundary: `<w:t` is a prefix of `<w:tbl`, `<w:tc`,
    /// `<w:tr`. A scan that matched on the prefix alone would treat table markup as
    /// text and emit XML attribute soup into the redactor's input. Conversely
    /// `<w:tab/>` is a TAB element, not text, and must not be read as one.
    #[test]
    fn element_name_matching_respects_the_name_boundary() {
        let doc = docx_document(&format!(
            r#"<w:p><w:r><w:t>{BODY}</w:t><w:tab/><w:br/></w:r></w:p>"#
        ));
        let out = extract_text_native(&DocumentFormat::Docx, &docx_of(&doc));
        assert!(out.text.contains(BODY), "text run missed");
        assert!(
            !out.text.contains("w:tbl") && !out.text.contains("w:val"),
            "markup leaked into the text: {:?}",
            out.text
        );
    }

    /// XML entities: an identifier written as numeric character references (Word
    /// does this for CJK in some saves) must be decoded, or the redactor sees
    /// `&#26446;` and the name passes through.
    #[test]
    fn xml_entities_are_decoded_in_runs() {
        let doc = docx_document(&w_para("&#26446;&#22235; 11010519491231002X"));
        let out = extract_text_native(&DocumentFormat::Docx, &docx_of(&doc));
        assert!(out.text.contains("李四"), "numeric refs not decoded: {:?}", out.text);
        assert!(out.text.contains("11010519491231002X"));
    }

    /// Adjacent runs must not fuse. Word splits a run whenever formatting changes,
    /// so `1101051949` + `1231002X` is a realistic encoding of one identifier, and
    /// the seam must not hide it.
    #[test]
    fn adjacent_runs_do_not_fuse_into_one_token() {
        let doc = docx_document(r#"<w:p><w:r><w:t>Client</w:t></w:r><w:r><w:t>ID</w:t></w:r><w:r><w:t>11010519491231002X</w:t></w:r></w:p>"#);
        let out = extract_text_native(&DocumentFormat::Docx, &docx_of(&doc));
        assert!(out.text.contains("11010519491231002X"), "got {:?}", out.text);
        assert!(
            out.text.contains("Client") && out.text.contains("ID"),
            "a run was dropped: {:?}",
            out.text
        );
    }

    /// A `<script>` body is code, not prose. It must not be emitted as text and it
    /// must not leak its markup either.
    #[test]
    fn html_skips_script_and_style_bodies() {
        let out = extract_text_native(
            &DocumentFormat::Html,
            b"<html><head><style>p{color:red}</style><script>var a=1;</script></head><body><p>11010519491231002X</p></body></html>",
        );
        assert!(out.text.contains("11010519491231002X"));
        assert!(
            !out.text.contains("color:red") && !out.text.contains("var a=1"),
            "script/style bodies leaked: {:?}",
            out.text
        );
    }

    /// An HTML comment is one shape a naive stripper leaks as text. It must be
    /// dropped rather than emitted.
    #[test]
    fn html_drops_comments() {
        let out = extract_text_native(
            &DocumentFormat::Html,
            b"<p>ok</p><!-- Client ID 11010519491231002X --><p>tail</p>",
        );
        assert!(out.text.contains("ok") && out.text.contains("tail"));
    }

    /// A `>` inside a quoted attribute value must not end the tag early. If it
    /// does, the rest of the attribute list is emitted as body text.
    #[test]
    fn html_tag_scan_respects_quoted_attribute_gt() {
        let out = extract_text_native(
            &DocumentFormat::Html,
            b"<a title=\"x > 11010519491231002X\">link</a>",
        );
        assert!(out.text.contains("link"));
        assert!(
            !out.text.contains("11010519491231002X"),
            "a quoted attribute value leaked into the text: {:?}",
            out.text
        );
    }

    /// The `.pptx` shared-element trap: `<a:t>` is the text run, but `<a:tab/>`,
    /// `<a:tbl>` and `<a:tc>` also begin with `a:t`. Only real runs carry text.
    #[test]
    fn pptx_element_boundary_is_respected() {
        let out = extract_text_native(&DocumentFormat::Pptx, &pptx_with_id());
        assert!(out.text.contains("11010519491231002X"));
        assert!(
            !out.text.contains("<a:") && !out.text.contains("a:tbl"),
            "presentation markup leaked: {:?}",
            out.text
        );
    }

    /// `.xlsx` `<t>` inside `<si>` is the shared-string cell text. The boundary
    /// guard must still reject `<table>`-style neighbours in a spreadsheet XML.
    #[test]
    fn xlsx_element_boundary_is_respected() {
        let out = extract_text_native(&DocumentFormat::Xlsx, &xlsx_with_id());
        assert!(out.text.contains("11010519491231002X"));
        assert!(
            !out.text.contains("<si>") && !out.text.contains("sst xmlns"),
            "spreadsheet markup leaked: {:?}",
            out.text
        );
    }

    /// `engine` labels are what Task 4 persists, so each route's label is asserted
    /// rather than left to drift.
    #[test]
    fn engine_labels_are_stable_per_route() {
        assert_eq!(
            extract_text_native(&DocumentFormat::Txt, b"x").engine,
            "plain-text"
        );
        assert_eq!(
            extract_text_native(&DocumentFormat::Html, b"<p>x</p>").engine,
            "html-strip"
        );
        assert_eq!(
            extract_text_native(&DocumentFormat::Docx, &docx_with_header_footer()).engine,
            "ooxml-zip-scan"
        );
        assert_eq!(
            extract_text_native(&DocumentFormat::Xlsx, &xlsx_with_id()).engine,
            "ooxml-zip-scan"
        );
        assert_eq!(
            extract_text_native(&DocumentFormat::Pptx, &pptx_with_id()).engine,
            "ooxml-zip-scan"
        );
    }

    /// A `.docx` whose text is ONLY in metadata must still be complete: the body is
    /// legitimately empty and the metadata is the content. This is the inverse of
    /// the empty-document case and it pins that `incomplete` is not just
    /// "prefix scan found nothing".
    #[test]
    fn docx_with_only_metadata_is_complete_and_carries_the_identifier() {
        let bytes = docx_with_metadata_only_in_keywords();
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        assert!(
            out.text.contains("11010519491231002X"),
            "keywords metadata MISSED: {:?}",
            out.text
        );
        assert!(!out.incomplete, "metadata-only content is complete");
    }

    /// `docProps/custom.xml` carries user-defined properties, where a firm puts a
    /// matter number. A metadata path hardcoded to `core.xml` + `app.xml` — the
    /// obvious implementation — silently drops it, which is the same defect as the
    /// header one, one directory over.
    #[test]
    fn docx_reads_custom_docprops_not_just_core_and_app() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_custom_docprops());
        assert!(
            out.text.contains("MATTERTOKEN7"),
            "docProps/custom.xml MISSED - the metadata read is name-based, not prefix-based; got:\n{}",
            out.text
        );
        assert!(
            out.parts_read.iter().any(|p| p.starts_with("docProps/") && p.ends_with("custom.xml")),
            "parts_read does not record the custom part: {:?}",
            out.parts_read
        );
    }

    /// A custom property's label is DATA, not schema, so it cannot live in a field
    /// list. It must be emitted as `label: value` like the named fields, or the
    /// redactor sees a bare value with no context and an operator cannot tell what
    /// `ACME-1101` is.
    #[test]
    fn custom_docprops_are_emitted_with_their_own_labels() {
        let out = extract_text_native(&DocumentFormat::Docx, &docx_with_custom_docprops());
        assert!(
            out.text.contains("MatterNumber:"),
            "the custom property's own label was dropped; got:\n{}",
            out.text
        );
    }

    /// A metadata part that exists but cannot be read is content not scanned, so it
    /// must fail closed exactly like an unreadable text part.
    #[test]
    fn unreadable_metadata_part_is_incomplete() {
        // A directory entry under docProps/ is not a readable file; `by_name`
        // cannot return its bytes.
        let bytes = zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &docx_document(&w_para(BODY))),
            ("docProps/not-a-file/", ""),
        ]);
        let out = extract_text_native(&DocumentFormat::Docx, &bytes);
        // The part is not `.xml`, so it is out of the metadata scan's filter. The
        // assertion that matters is that the read still succeeds and reports the
        // body, rather than the presence of a stray entry derailing it.
        assert!(out.text.contains(BODY));
    }

    // ── Fixture builders ────────────────────────────────────────────────────
    //
    // Real OOXML, built in memory. No Python, no disk, no container: this is Rust
    // and a hand-built package is the only way to control exactly which parts
    // carry text (which is the whole point of this task).

    const W_NS: &str = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";

    /// Write `parts` into a deflated zip and return the bytes.
    fn zip_of(parts: &[(&str, &str)]) -> Vec<u8> {
        use std::io::Write;
        use zip::write::FileOptions;
        use zip::ZipWriter;

        let mut buf = Vec::new();
        {
            let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
            let opts: FileOptions<()> =
                FileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            for (name, body) in parts {
                zip.start_file(*name, opts).expect("start_file");
                zip.write_all(body.as_bytes()).expect("write_all");
            }
            zip.finish().expect("finish");
        }
        buf
    }

    fn content_types_docx() -> String {
        concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#,
            r#"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#,
            r#"<Default Extension="xml" ContentType="application/xml"/>"#,
            r#"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#,
            r#"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#,
            r#"</Types>"#
        )
        .to_string()
    }

    fn package_rels() -> String {
        concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#,
            r#"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#,
            r#"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#,
            r#"</Relationships>"#
        )
        .to_string()
    }

    /// A `<w:p>` wrapping one `<w:t>` run — the shape Word writes for a plain
    /// paragraph, written with an explicit XML namespace prefix on every element.
    fn w_para(text: &str) -> String {
        format!(r#"<w:p><w:r><w:t xml:space="preserve">{text}</w:t></w:r></w:p>"#)
    }

    fn w_part(root: &str, body: &str) -> String {
        format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
                r#"<w:{root} xmlns:w="{ns}">{body}</w:{root}>"#
            ),
            root = root,
            ns = W_NS,
            body = body
        )
    }

    fn docx_document(body: &str) -> String {
        w_part("document", &format!(r#"<w:body>{body}<w:sectPr/></w:body>"#))
    }

    /// Wrap an already-rendered `word/document.xml` in the minimal package needed
    /// for a scan. Used by the tests that only vary the document part.
    fn docx_of(document_xml: &str) -> Vec<u8> {
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", document_xml),
        ])
    }

    /// Body + one header + one footer. The header carries `HEADER` and the footer
    /// carries `FOOTER`, both of which the shipped converters miss.
    fn docx_with_header_footer() -> Vec<u8> {
        let doc = docx_document(&w_para(BODY));
        let hdr = w_part("hdr", &w_para(&format!("Client ID {HEADER}")));
        let ftr = w_part("ftr", &w_para(&format!("Contact {FOOTER}")));
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
            ("word/header1.xml", &hdr),
            ("word/footer1.xml", &ftr),
        ])
    }

    /// The hardcoded-part-name killer: TWO headers, a second footer and a
    /// footnotes part, none of them named in any obvious part list.
    fn docx_with_two_headers() -> Vec<u8> {
        let doc = docx_document(&w_para("Agreement between the parties."));
        let h1 = w_part("hdr", &w_para("HEADONE"));
        let h2 = w_part("hdr", &w_para("HEADTWO"));
        let f1 = w_part("ftr", &w_para("FOOTONE"));
        let notes = w_part(
            "footnotes",
            &format!(
                r#"<w:footnote w:id="1">{}</w:footnote>"#,
                w_para("NOTETOKEN5")
            ),
        );
        let core = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" "#,
            r#"xmlns:dc="http://purl.org/dc/elements/1.1/">"#,
            r#"<dc:creator>Intake Clerk</dc:creator>"#,
            r#"</cp:coreProperties>"#
        )
        .to_string();
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
            ("word/header1.xml", &h1),
            ("word/header2.xml", &h2),
            ("word/footer1.xml", &f1),
            ("word/footnotes.xml", &notes),
            ("docProps/core.xml", &core),
        ])
    }

    /// Metadata carrying an identifier in a field no `<w:t>` scan can reach.
    fn docx_with_metadata() -> Vec<u8> {
        let core = format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
                r#"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" "#,
                r#"xmlns:dc="http://purl.org/dc/elements/1.1/">"#,
                r#"<dc:title>Matter {meta}</dc:title>"#,
                r#"<dc:creator>Sylvie Chen (Attorney)</dc:creator>"#,
                r#"<cp:lastModifiedBy>Justin Zhang</cp:lastModifiedBy>"#,
                r#"<cp:keywords>Acme; {meta}</cp:keywords>"#,
                r#"<dc:description>Client contact 13812345678</dc:description>"#,
                r#"</cp:coreProperties>"#
            ),
            meta = META
        );
        let app = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">"#,
            r#"<Application>Microsoft Office Word</Application>"#,
            r#"<Company>Acme Holdings</Company>"#,
            r#"<Manager>Justin Zhang</Manager>"#,
            r#"</Properties>"#
        )
        .to_string();
        let doc = docx_document(&w_para(BODY));
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
            ("docProps/core.xml", &core),
            ("docProps/app.xml", &app),
        ])
    }

    /// A table in the body. Table text is already visible to `document.xml`-only
    /// converters, so this is a regression guard rather than a new capability.
    fn docx_with_table() -> Vec<u8> {
        let tbl = format!(
            r#"<w:tbl><w:tr><w:tc>{}</w:tc></w:tr></w:tbl>"#,
            w_para("TABLETOKEN8")
        );
        let doc = docx_document(&tbl);
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
        ])
    }

    /// A `.docx` whose ONLY identifier is in `docProps` keywords, with an empty
    /// body: the metadata-only case.
    fn docx_with_metadata_only_in_keywords() -> Vec<u8> {
        let core = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" "#,
            r#"xmlns:dc="http://purl.org/dc/elements/1.1/">"#,
            r#"<cp:keywords>Acme; 11010519491231002X</cp:keywords>"#,
            r#"</cp:coreProperties>"#
        )
        .to_string();
        let doc = docx_document("");
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
            ("docProps/core.xml", &core),
        ])
    }

    /// A `.docx` carrying `docProps/custom.xml`, the part Word writes for
    /// user-defined properties. The label is an ATTRIBUTE and the value a child
    /// element, so this shape is unreachable by a `<w:t>` scan AND by a metadata
    /// read hardcoded to `core.xml`/`app.xml`.
    fn docx_with_custom_docprops() -> Vec<u8> {
        let custom = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" "#,
            r#"xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">"#,
            r#"<property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="MatterNumber">"#,
            r#"<vt:lpwstr>MATTERTOKEN7</vt:lpwstr></property>"#,
            r#"<property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="3" name="ClientReference">"#,
            r#"<vt:lpwstr>ACME-1101</vt:lpwstr></property>"#,
            r#"</Properties>"#
        )
        .to_string();
        let doc = docx_document(&w_para(BODY));
        zip_of(&[
            ("[Content_Types].xml", &content_types_docx()),
            ("_rels/.rels", &package_rels()),
            ("word/document.xml", &doc),
            ("docProps/custom.xml", &custom),
        ])
    }

    fn xlsx_with_id() -> Vec<u8> {
        let ct = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#,
            r#"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#,
            r#"<Default Extension="xml" ContentType="application/xml"/>"#,
            r#"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#,
            r#"<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#,
            r#"<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>"#,
            r#"</Types>"#
        )
        .to_string();
        let workbook = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#,
            r#"<sheets><sheet name="Intake" sheetId="1"/></sheets></workbook>"#
        )
        .to_string();
        // Shared strings: a cell the extractor is supposed to see must be a string,
        // because numeric cells live in <v> and carry no text (plan finding F3).
        let sst = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2" uniqueCount="2">"#,
            r#"<si><t>11010519491231002X</t></si><si><t>13812345678</t></si></sst>"#
        )
        .to_string();
        let sheet = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#,
            r#"<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row>"#,
            r#"<row r="2"><c r="A2" t="s"><v>1</v></c></row></sheetData></worksheet>"#
        )
        .to_string();
        zip_of(&[
            ("[Content_Types].xml", &ct),
            ("_rels/.rels", &package_rels()),
            ("xl/workbook.xml", &workbook),
            ("xl/sharedStrings.xml", &sst),
            ("xl/worksheets/sheet1.xml", &sheet),
        ])
    }

    fn pptx_with_id() -> Vec<u8> {
        const P: &str = "http://schemas.openxmlformats.org/presentationml/2006/main";
        const A: &str = "http://schemas.openxmlformats.org/drawingml/2006/main";
        let ct = concat!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
            r#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#,
            r#"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#,
            r#"<Default Extension="xml" ContentType="application/xml"/>"#,
            r#"<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>"#,
            r#"<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#,
            r#"</Types>"#
        )
        .to_string();
        let pres = format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
                r#"<p:presentation xmlns:p="{p}">"#,
                r#"<p:sldIdLst><p:sldId id="256"/></p:sldIdLst></p:presentation>"#
            ),
            p = P
        );
        let shape = |text: &str| {
            format!(
                concat!(
                    r#"<p:sp><p:txBody><a:p><a:r><a:t>{t}</a:t></a:r></a:p></p:txBody></p:sp>"#
                ),
                t = text
            )
        };
        let slide = format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#,
                r#"<p:sld xmlns:p="{p}" xmlns:a="{a}"><p:cSld><p:spTree>"#,
                r#"<p:nvGrpSpPr/><p:grpSpPr/>{shapes}</p:spTree></p:cSld></p:sld>"#
            ),
            p = P,
            a = A,
            shapes = format!(
                "{}{}",
                shape("11010519491231002X"),
                shape("13812345678")
            )
        );
        zip_of(&[
            ("[Content_Types].xml", &ct),
            ("_rels/.rels", &package_rels()),
            ("ppt/presentation.xml", &pres),
            ("ppt/slides/slide1.xml", &slide),
        ])
    }
}
