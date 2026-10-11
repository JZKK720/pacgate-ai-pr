//! Word-level diff → OOXML tracked changes (`<w:ins>` / `<w:del>`).

use crate::ooxml::xml_escape;
use anyhow::{bail, Context, Result};
use similar::{ChangeTag, TextDiff};

pub struct TrackedEdit {
    pub find:           String,
    pub replace:        String,
    pub context_before: Option<String>,
    pub context_after:  Option<String>,
}

impl TrackedEdit {
    pub fn new(
        find:           impl Into<String>,
        replace:        impl Into<String>,
        context_before: Option<&str>,
        context_after:  Option<&str>,
    ) -> Self {
        Self {
            find:           find.into(),
            replace:        replace.into(),
            context_before: context_before.map(|s| s.to_string()),
            context_after:  context_after.map(|s| s.to_string()),
        }
    }
}

/// Apply a tracked-change edit to a DOCX byte buffer.
/// Returns a new DOCX byte buffer with `<w:ins>` / `<w:del>` revision marks.
pub fn apply_tracked_edit(docx_bytes: &[u8], edit: &TrackedEdit) -> Result<Vec<u8>> {
    use std::io::{Read, Write};
    use zip::{write::FileOptions, ZipArchive, ZipWriter};

    let cursor = std::io::Cursor::new(docx_bytes);
    let mut archive = ZipArchive::new(cursor).context("open docx zip")?;

    // Read document.xml
    let document_xml = {
        let mut entry = archive
            .by_name("word/document.xml")
            .context("word/document.xml not found")?;
        let mut s = String::new();
        entry.read_to_string(&mut s)?;
        s
    };

    let patched = patch_document_xml(&document_xml, edit)
        .context("patch document.xml")?;

    // Rebuild the ZIP, replacing document.xml
    let mut out_buf = Vec::new();
    let mut writer = ZipWriter::new(std::io::Cursor::new(&mut out_buf));
    let opts: FileOptions<()> = FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        writer.start_file(&name, opts)?;
        if name == "word/document.xml" {
            writer.write_all(patched.as_bytes())?;
        } else {
            let mut buf = Vec::new();
            file.read_to_end(&mut buf)?;
            writer.write_all(&buf)?;
        }
    }
    writer.finish()?;
    Ok(out_buf)
}

/// Accept tracked changes in a DOCX produced by `apply_tracked_edit`.
///
/// This keeps inserted runs and removes deleted runs for the controlled
/// `<w:ins>` / `<w:del>` shapes emitted by this crate.
pub fn accept_tracked_changes(docx_bytes: &[u8]) -> Result<Vec<u8>> {
    use std::io::{Read, Write};
    use zip::{write::FileOptions, ZipArchive, ZipWriter};

    let cursor = std::io::Cursor::new(docx_bytes);
    let mut archive = ZipArchive::new(cursor).context("open docx zip")?;

    let document_xml = {
        let mut entry = archive
            .by_name("word/document.xml")
            .context("word/document.xml not found")?;
        let mut s = String::new();
        entry.read_to_string(&mut s)?;
        s
    };

    let accepted = accept_document_xml(&document_xml);

    let mut out_buf = Vec::new();
    let mut writer = ZipWriter::new(std::io::Cursor::new(&mut out_buf));
    let opts: FileOptions<()> = FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        writer.start_file(&name, opts)?;
        if name == "word/document.xml" {
            writer.write_all(accepted.as_bytes())?;
        } else {
            let mut buf = Vec::new();
            file.read_to_end(&mut buf)?;
            writer.write_all(&buf)?;
        }
    }

    writer.finish()?;
    Ok(out_buf)
}

/// Locate `edit.find` in the raw XML text content and produce revision-marked XML.
fn patch_document_xml(xml: &str, edit: &TrackedEdit) -> Result<String> {
    // Find the plain text within <w:t> elements
    let find_escaped = xml_escape(&edit.find);

    if !xml.contains(&find_escaped) {
        bail!(
            "text {:?} not found in document (escaped: {:?})",
            edit.find,
            find_escaped
        );
    }

    // Build word-level diff between `find` and `replace`
    let diff = TextDiff::from_words(&edit.find, &edit.replace);
    let mut revision_xml = String::new();

    // `w:id` identifies a revision inside the part, so it must not be reused.
    // Continue past whatever the document already carries: hardcoded ids made the
    // second edit in a document collide with the first.
    let del_id = next_revision_id(xml);
    let ins_id = del_id + 1;

    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Equal  => {
                revision_xml.push_str(&wrap_run(&xml_escape(change.value())));
            }
            ChangeTag::Delete => {
                revision_xml.push_str(&wrap_del(&xml_escape(change.value()), del_id));
            }
            ChangeTag::Insert => {
                revision_xml.push_str(&wrap_ins(&xml_escape(change.value()), ins_id));
            }
        }
    }

    // Replace only the FIRST occurrence that matches context constraints
    let patched = replace_first_in_xml(xml, &find_escaped, &revision_xml, edit)?;
    Ok(patched)
}

/// The `<w:r>` run and `<w:t>` text node a match sits in.
#[derive(Debug)]
struct RunSpan {
    /// Offset of the enclosing `<w:r` start tag.
    run_open:      usize,
    /// Offset of the enclosing `<w:t` start tag.
    text_open:     usize,
    /// Offset just past the `>` of that `<w:t …>` start tag.
    text_open_end: usize,
}

fn replace_first_in_xml(
    xml:            &str,
    find_escaped:   &str,
    revision_xml:   &str,
    edit:           &TrackedEdit,
) -> Result<String> {
    let position = if let (Some(cb), Some(ca)) = (&edit.context_before, &edit.context_after) {
        let anchor = format!("{}{}{}", xml_escape(cb), find_escaped, xml_escape(ca));
        xml.find(&anchor).map(|i| i + xml_escape(cb).len())
    } else {
        xml.find(find_escaped)
    };

    let Some(start) = position else {
        bail!("find text not found with given context constraints");
    };
    let end = start + find_escaped.len();

    // `<w:del>` and `<w:ins>` are only valid as PEER runs of `<w:r>` inside
    // `<w:p>`. Splicing the marked-up text straight into the middle of a `<w:t>`
    // character-data node is well-formed XML but invalid OOXML, and it also breaks
    // the read path: a scanner looking for the next `<` stops at the first nested
    // element, so the text node ends early and the rest of the run is lost. That
    // is invisible in short ASCII fixtures and destroys a whole paragraph tail in
    // Chinese prose, where a run boundary regularly falls mid-sentence.
    //
    // So split the run around the match and emit the revision marks as siblings:
    // close the head run, write the marked-up runs, reopen the run for the tail.
    let span = enclosing_run(xml, start, end)?;

    let mut out = String::with_capacity(xml.len() + revision_xml.len() + 64);
    if start > span.text_open_end {
        // The head keeps text, so keep its run and text node open and close them.
        out.push_str(&xml[..start]);
        out.push_str("</w:t></w:r>");
    } else {
        // Nothing before the match: drop the empty head run rather than emit
        // `<w:t …></w:t>`.
        out.push_str(&xml[..span.run_open]);
    }
    out.push_str(revision_xml);
    // Reopen for the tail, carrying the run's own content (`<w:rPr>` and friends)
    // so a styled run stays styled. The run's original `</w:t>` and `</w:r>` close
    // it, which is why the tail is copied from `end` to the end of the part.
    out.push_str(&xml[span.run_open..span.text_open]);
    out.push_str(r#"<w:t xml:space="preserve">"#);
    out.push_str(&xml[end..]);
    Ok(out)
}

/// The run and text node enclosing `start..end`, or an error if the match is not
/// wholly inside one text node.
fn enclosing_run(xml: &str, start: usize, end: usize) -> Result<RunSpan> {
    let text_open = last_start_tag_before(xml, "<w:t", start).context(
        "tracked edit: the find text is not inside a <w:t> text node, so it cannot be \
         revision-marked",
    )?;
    let text_open_end = text_open
        + xml[text_open..]
            .find('>')
            .context("tracked edit: unterminated <w:t> start tag")?
        + 1;
    let text_close = xml[text_open_end..]
        .find("</w:t>")
        .map(|r| text_open_end + r)
        .context("tracked edit: unterminated <w:t> text node")?;

    if start < text_open_end || end > text_close {
        bail!(
            "tracked edit: the find text (bytes {start}..{end}) does not sit inside a single \
             <w:t> run (text node body {text_open_end}..{text_close}); revision marks cannot \
             span a run boundary"
        );
    }

    let run_open = last_start_tag_before(xml, "<w:r", text_open)
        .context("tracked edit: <w:t> is not inside a <w:r> run")?;
    Ok(RunSpan { run_open, text_open, text_open_end })
}

/// Offset of the last `<name` start tag beginning before `before`.
///
/// The name boundary matters: `<w:t` is a prefix of `<w:tbl`, `<w:tc` and `<w:tr`,
/// and `<w:r` is a prefix of `<w:rPr` and `<w:rFonts`, so a bare `rfind` would
/// happily return the wrong element.
fn last_start_tag_before(xml: &str, name: &str, before: usize) -> Option<usize> {
    let mut limit = before.min(xml.len());
    while let Some(at) = xml[..limit].rfind(name) {
        let next = xml[at + name.len()..].chars().next();
        if matches!(next, Some(c) if c == '>' || c == '/' || c.is_whitespace()) {
            return Some(at);
        }
        limit = at;
    }
    None
}

/// The next `w:id` free for a revision element.
fn next_revision_id(xml: &str) -> u32 {
    let mut next = 1u32;
    for prefix in ["<w:del", "<w:ins"] {
        let mut from = 0;
        while let Some(relative) = xml[from..].find(prefix) {
            let at = from + relative;
            let after = at + prefix.len();
            // `<w:delText` and `<w:delInstrText` carry text; they are not revisions.
            let boundary = xml[after..]
                .chars()
                .next()
                .is_some_and(|c| c == '>' || c == '/' || c.is_whitespace());
            if !boundary {
                from = after;
                continue;
            }
            let tag_end = xml[after..]
                .find('>')
                .map(|r| after + r)
                .unwrap_or(xml.len());
            if let Some(id) = revision_tag_id(&xml[after..tag_end]) {
                next = next.max(id + 1);
            }
            from = tag_end;
        }
    }
    next
}

/// `w:id` from the body of a `<w:del …>` or `<w:ins …>` start tag.
fn revision_tag_id(tag_body: &str) -> Option<u32> {
    let at = tag_body.find("w:id=\"")? + "w:id=\"".len();
    let rest = &tag_body[at..];
    let end = rest.find('"')?;
    rest[..end].parse().ok()
}

fn wrap_run(text: &str) -> String {
    format!(r#"<w:r><w:t xml:space="preserve">{text}</w:t></w:r>"#)
}

fn wrap_del(text: &str, id: u32) -> String {
    format!(
        r#"<w:del w:id="{id}" w:author="Pacgate AI" w:date="2025-01-01T00:00:00Z"><w:r><w:delText xml:space="preserve">{text}</w:delText></w:r></w:del>"#
    )
}

fn wrap_ins(text: &str, id: u32) -> String {
    format!(
        r#"<w:ins w:id="{id}" w:author="Pacgate AI" w:date="2025-01-01T00:00:00Z"><w:r><w:t xml:space="preserve">{text}</w:t></w:r></w:ins>"#
    )
}

fn accept_document_xml(xml: &str) -> String {
    let without_deletions = remove_tag_blocks(xml, "w:del");
    let without_wrappers = strip_tag_wrappers(&without_deletions, "w:ins");
    // A part written before the writer was fixed still carries runs nested inside
    // an open `<w:t>`; dropping the wrapper tags alone does not un-nest them.
    flatten_nested_text_nodes(&without_wrappers)
}

fn remove_tag_blocks(xml: &str, tag_name: &str) -> String {
    let open_tag = format!("<{tag_name}");
    let close_tag = format!("</{tag_name}>");
    let mut output = String::new();
    let mut cursor = 0;

    while let Some(relative_start) = xml[cursor..].find(&open_tag) {
        let start = cursor + relative_start;
        output.push_str(&xml[cursor..start]);

        if let Some(relative_end) = xml[start..].find(&close_tag) {
            cursor = start + relative_end + close_tag.len();
        } else {
            cursor = start;
            break;
        }
    }

    output.push_str(&xml[cursor..]);
    output
}

fn strip_tag_wrappers(xml: &str, tag_name: &str) -> String {
    let open_tag = format!("<{tag_name}");
    let close_tag = format!("</{tag_name}>");
    let mut output = String::new();
    let mut cursor = 0;

    while let Some(relative_start) = xml[cursor..].find(&open_tag) {
        let start = cursor + relative_start;
        output.push_str(&xml[cursor..start]);

        if let Some(relative_end) = xml[start..].find('>') {
            cursor = start + relative_end + 1;
        } else {
            cursor = start;
            break;
        }
    }

    output.push_str(&xml[cursor..]);
    output.replace(&close_tag, "")
}

/// Collapse a `<w:t>` text node that has element markup nested inside it.
///
/// Tracked edits written before the writer was fixed spliced `<w:del>`/`<w:ins>`
/// straight into the middle of a `<w:t>` text node. Accepting one of those parts
/// removes the revision wrappers but leaves the marked-up runs still nested inside
/// the open text node, and a reader that stops at the first `<` drops everything
/// after the last nested run - the whole tail of a paragraph, in Chinese prose.
///
/// The nested markup held nothing but the run's own text, so flattening is the
/// repair: the text node becomes the concatenation it always meant to be. A
/// well-formed text node has no `<` in its body and is copied through untouched.
fn flatten_nested_text_nodes(xml: &str) -> String {
    let mut output = String::with_capacity(xml.len());
    let mut cursor = 0;

    while let Some(relative) = xml[cursor..].find("<w:t") {
        let at = cursor + relative;
        let after = at + "<w:t".len();
        // `<w:t` prefixes `<w:tbl`, `<w:tc` and `<w:tr`.
        if !xml[after..]
            .chars()
            .next()
            .is_some_and(|c| c == '>' || c == '/' || c.is_whitespace())
        {
            output.push_str(&xml[cursor..after]);
            cursor = after;
            continue;
        }
        output.push_str(&xml[cursor..at]);

        let Some(gt) = xml[at..].find('>') else {
            output.push_str(&xml[at..]);
            return output;
        };
        let body_start = at + gt + 1;
        if xml[at..body_start - 1].ends_with('/') {
            output.push_str(&xml[at..body_start]);
            cursor = body_start;
            continue;
        }

        // Walk to the matching `</w:t>`, counting any nested text nodes.
        let mut depth = 1usize;
        let mut scan = body_start;
        let mut close_at = None;
        while let Some(relative) = xml[scan..].find('<') {
            let tag_at = scan + relative;
            if xml[tag_at..].starts_with("</w:t>") {
                depth -= 1;
                if depth == 0 {
                    close_at = Some(tag_at);
                    break;
                }
                scan = tag_at + "</w:t>".len();
                continue;
            }
            if xml[tag_at..].starts_with("<w:t") {
                let nested_after = tag_at + "<w:t".len();
                let is_text_node = xml[nested_after..]
                    .chars()
                    .next()
                    .is_some_and(|c| c == '>' || c == '/' || c.is_whitespace());
                if is_text_node {
                    if let Some(gt) = xml[tag_at..].find('>') {
                        if !xml[tag_at..tag_at + gt].ends_with('/') {
                            depth += 1;
                        }
                        scan = tag_at + gt + 1;
                        continue;
                    }
                }
            }
            scan = tag_at + 1;
        }

        let Some(close_at) = close_at else {
            output.push_str(&xml[at..]);
            return output;
        };
        let body = &xml[body_start..close_at];

        output.push_str(&xml[at..body_start]);
        if body.contains('<') {
            let mut in_tag = false;
            for c in body.chars() {
                match c {
                    '<' => in_tag = true,
                    '>' => in_tag = false,
                    _ if !in_tag => output.push(c),
                    _ => {}
                }
            }
        } else {
            output.push_str(body);
        }
        output.push_str("</w:t>");
        cursor = close_at + "</w:t>".len();
    }

    output.push_str(&xml[cursor..]);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    // Chinese fixture text, written as \u{...} escapes so the patch travels
    // encoding-safe. Every scalar here is 3 bytes in UTF-8 - exactly the stride
    // that made the old byte-slicing reader panic, and exactly why a run
    // boundary that falls mid-sentence is the normal case, not the edge case.
    const P_A: &str = "\u{672c}\u{5408}\u{540c}\u{9879}\u{4e0b}\u{7684}";
    const FIND1: &str = "\u{670d}\u{52a1}\u{8d39}\u{7528}";
    const REPL1: &str = "\u{987e}\u{95ee}\u{670d}\u{52a1}\u{8d39}";
    const P_B: &str = "\u{4e3a}";
    const CTX_BEFORE: &str = "\u{4eba}\u{6c11}\u{5e01}";
    const FIND2: &str = "\u{4f0d}\u{4e07}\u{5143}\u{6574}";
    const REPL2: &str = "\u{4f0d}\u{62fe}\u{4e07}\u{5143}\u{6574}";
    const CTX_AFTER: &str = "\u{ff0c}\u{4e59}\u{65b9}";
    const TAIL: &str = "\u{5e94}\u{5728}\u{6536}\u{5230}\u{53d1}\u{7968}\u{540e}\u{4e09}\u{5341}\u{65e5}\u{5185}\u{4ed8}\u{6e05}\u{5168}\u{90e8}\u{6b3e}\u{9879}\u{3002}";

    fn run_before() -> String {
        format!("{P_A}{FIND1}{P_B}{CTX_BEFORE}{FIND2}{CTX_AFTER}{TAIL}")
    }

    fn run_after() -> String {
        format!("{P_A}{REPL1}{P_B}{CTX_BEFORE}{REPL2}{CTX_AFTER}{TAIL}")
    }

    /// A minimal DOCX whose body is exactly `body_xml`, so a test can pin the run
    /// shape it depends on rather than inheriting whatever the builder emits.
    fn docx_with_body(body_xml: &str) -> Vec<u8> {
        use std::io::Write;
        use zip::{write::FileOptions, ZipWriter};

        let document = format!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{body_xml}<w:sectPr/></w:body></w:document>"#
        );

        let mut buf = Vec::new();
        let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
        let opts: FileOptions<()> =
            FileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, content) in [
            ("[Content_Types].xml", crate::ooxml::CONTENT_TYPES_XML),
            ("_rels/.rels", crate::ooxml::RELS_XML),
            ("word/document.xml", document.as_str()),
        ] {
            zip.start_file(name, opts).expect("start_file");
            zip.write_all(content.as_bytes()).expect("write entry");
        }
        zip.finish().expect("finish zip");
        buf
    }

    /// The part as it was written back, not the part we asked to write.
    fn document_xml(docx: &[u8]) -> String {
        use std::io::Read;

        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(docx)).expect("open zip");
        let mut entry = archive.by_name("word/document.xml").expect("word/document.xml");
        let mut xml = String::new();
        entry.read_to_string(&mut xml).expect("read document.xml");
        xml
    }

    /// The body of every `<w:t>` element. A `<` in here means markup was nested
    /// inside a text node, which is well-formed XML but invalid OOXML.
    fn text_node_bodies(xml: &str) -> Vec<String> {
        let mut bodies = Vec::new();
        let mut cursor = 0;

        while let Some(relative) = xml[cursor..].find("<w:t") {
            let at = cursor + relative;
            let after = &xml[at + "<w:t".len()..];
            // `<w:t` prefixes `<w:tbl`, `<w:tc` and `<w:tr`.
            let is_start_tag = after
                .chars()
                .next()
                .is_some_and(|c| c == '>' || c.is_whitespace());
            if !is_start_tag {
                cursor = at + "<w:t".len();
                continue;
            }
            let Some(gt) = xml[at..].find('>') else { break };
            let body_at = at + gt + 1;
            let Some(close) = xml[body_at..].find("</w:t>") else { break };
            bodies.push(xml[body_at..body_at + close].to_string());
            cursor = body_at + close + "</w:t>".len();
        }

        bodies
    }

    /// Every `w:id` on a `<w:del>` or `<w:ins>` element.
    fn revision_ids(xml: &str) -> Vec<u32> {
        let mut ids = Vec::new();
        for prefix in ["<w:del", "<w:ins"] {
            let mut from = 0;
            while let Some(relative) = xml[from..].find(prefix) {
                let at = from + relative;
                let after = at + prefix.len();
                let boundary = xml[after..]
                    .chars()
                    .next()
                    .is_some_and(|c| c == '>' || c == '/' || c.is_whitespace());
                if !boundary {
                    from = after;
                    continue;
                }
                let Some(gt) = xml[after..].find('>') else { break };
                if let Some(id) = revision_tag_id(&xml[after..after + gt]) {
                    ids.push(id);
                }
                from = after + gt;
            }
        }
        ids
    }

    #[test]
    fn the_fixture_text_really_is_three_byte_cjk() {
        assert_eq!(run_before().chars().count(), 39);
        assert_eq!(
            run_before().len(),
            117,
            "39 scalars at 3 bytes each; a 2-byte fixture would not exercise the stride"
        );
    }

    /// The release-blocking regression: the marked-up text was spliced straight
    /// into the middle of `<w:t>`, so a scanner reading text up to the next `<`
    /// stopped at the first nested element and every character after it was lost.
    /// In a short ASCII fixture that truncation is invisible; in Chinese prose it
    /// drops the rest of the paragraph.
    #[test]
    fn revision_marks_never_nest_inside_a_text_node() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p>"#,
            run_before()
        ));

        let edited = apply_tracked_edit(
            &docx,
            &TrackedEdit::new(FIND1, REPL1, None, None),
        )
        .expect("edit applies");
        let xml = document_xml(&edited);

        let bodies = text_node_bodies(&xml);
        assert!(
            bodies.len() >= 3,
            "fixture precondition: the split must leave head, marks and tail runs; got {bodies:?}"
        );
        for body in &bodies {
            assert!(
                !body.contains('<'),
                "element markup nested inside a <w:t> text node: {body:?}"
            );
        }
    }

    /// The whole paragraph must survive the edit, in one piece, with no character
    /// invented at the seams the edit creates.
    #[test]
    fn a_cjk_edit_keeps_the_whole_paragraph_and_invents_nothing() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p>"#,
            run_before()
        ));

        let edited = apply_tracked_edit(
            &docx,
            &TrackedEdit::new(FIND1, REPL1, None, None),
        )
        .expect("edit applies");
        let text = crate::parser::extract_text(&edited).expect("read back");

        // The tracked insertion and the tracked deletion are both still present:
        // a redactor must see text the author only *marked* as deleted.
        let expected = format!("{P_A}{FIND1}{REPL1}{P_B}{CTX_BEFORE}{FIND2}{CTX_AFTER}{TAIL}");
        assert_eq!(
            text, expected,
            "the tail of the paragraph was dropped, or a seam gained a character"
        );
    }

    /// Accepting must drop the deleted text and leave a flat, complete paragraph.
    #[test]
    fn accepting_a_cjk_edit_leaves_flat_complete_text() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p>"#,
            run_before()
        ));

        // Accept is only meaningful after both edits, because accepting the first
        // one alone correctly leaves the second `find` in place.
        let first = apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
            .expect("first edit applies");
        let second = apply_tracked_edit(
            &first,
            &TrackedEdit::new(FIND2, REPL2, Some(CTX_BEFORE), Some(CTX_AFTER)),
        )
        .expect("second edit applies");
        let accepted = accept_tracked_changes(&second).expect("accept applies");
        let xml = document_xml(&accepted);

        for body in text_node_bodies(&xml) {
            assert!(
                !body.contains('<'),
                "accept left markup nested inside a <w:t> text node: {body:?}"
            );
        }
        assert!(
            !xml.contains("<w:del") && !xml.contains("<w:ins"),
            "accept left revision markup behind: {xml}"
        );

        let text = crate::parser::extract_text(&accepted).expect("read back");
        assert_eq!(text, run_after(), "the accepted text is not the document text");
    }

    /// `w:id` names a revision *within the part*. Reusing `1` and `2` for every
    /// edit made the second edit in a document collide with the first, so a reader
    /// resolving ids could not tell the revisions apart.
    #[test]
    fn revision_ids_are_unique_across_successive_edits() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p>"#,
            run_before()
        ));

        let first =
            apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
                .expect("first edit applies");
        // The anchored branch: context pins which occurrence is meant.
        let second = apply_tracked_edit(
            &first,
            &TrackedEdit::new(FIND2, REPL2, Some(CTX_BEFORE), Some(CTX_AFTER)),
        )
        .expect("second edit applies");

        let ids = revision_ids(&document_xml(&second));
        assert_eq!(ids.len(), 4, "two edits must leave four revision elements: {ids:?}");

        let mut unique = ids.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), ids.len(), "a revision id was reused: {ids:?}");

        let text = crate::parser::extract_text(&second).expect("read back");
        assert!(
            text.contains(REPL1) && text.contains(REPL2),
            "both replacements must be present: {text:?}"
        );
    }

    /// An empty head run is worse than no head run: `<w:t></w:t>` renders as an
    /// empty run in Word. When the match starts the text node, drop it.
    #[test]
    fn a_match_at_the_start_of_a_run_does_not_leave_an_empty_text_node() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:t xml:space="preserve">{FIND1}{TAIL}</w:t></w:r></w:p>"#
        ));

        let edited = apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
            .expect("edit applies");
        let xml = document_xml(&edited);

        assert!(
            !xml.contains("></w:t>"),
            "an empty text node was emitted: {xml}"
        );
        assert!(
            crate::parser::extract_text(&edited)
                .expect("read back")
                .contains(TAIL),
            "the tail after a leading match was dropped"
        );
    }

    /// A styled run must stay styled. The tail run is reopened from the original
    /// `<w:r>` prefix precisely so `<w:rPr>` survives the split.
    #[test]
    fn the_reopened_tail_run_keeps_its_run_properties() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">{P_A}{FIND1}{P_B}</w:t></w:r></w:p>"#
        ));

        let edited = apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
            .expect("edit applies");
        let xml = document_xml(&edited);

        assert_eq!(
            xml.matches("<w:rPr>").count(),
            2,
            "the head and the reopened tail must both keep the run's properties: {xml}"
        );
    }

    /// The match must lie wholly inside one text node. A range that crosses
    /// `</w:t>` cannot be revision-marked without corrupting the part, so it is
    /// refused with a hard error rather than spliced.
    #[test]
    fn a_match_that_crosses_a_run_boundary_is_refused() {
        let xml = r#"<w:p><w:r><w:t>AB</w:t></w:r><w:r><w:t>CD</w:t></w:r></w:p>"#;
        // `AB` sits at 15..17; 21 reaches past `</w:t>` at 17..24.
        let start = xml.find("AB").expect("fixture");
        assert_eq!(start, 15, "fixture precondition");

        let err = enclosing_run(xml, start, start + "AB</w:".len())
            .expect_err("a match crossing a run boundary must be refused");
        assert!(
            err.to_string().contains("single"),
            "the error must name the run boundary it violated; got {err}"
        );
    }

    /// Text in a carrier that is not a `<w:t>` run (a field code, say) cannot be
    /// revision-marked either, and must fail loudly instead of writing garbage.
    #[test]
    fn a_match_outside_a_text_run_is_refused() {
        let docx = docx_with_body(&format!(
            r#"<w:p><w:r><w:instrText>{FIND1}</w:instrText></w:r></w:p>"#
        ));

        let err = apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
            .expect_err("a field code is not a text run");
        // `apply_tracked_edit` adds its own context, so read the whole chain.
        assert!(
            format!("{err:#}").contains("w:t"),
            "the error must name the missing text node; got {err:#}"
        );
    }

    /// The exact shape the old writer left behind, captured from a live document:
    /// the marked-up runs sit nested inside the still-open outer `<w:t>`. Accepting
    /// it removed the `<w:ins>` wrapper and left the inner `<w:r><w:t>` in place, so
    /// the reader stopped at the first nested `<` and lost the paragraph tail.
    #[test]
    fn accepting_a_part_written_by_the_old_writer_unnests_the_text_nodes() {
        let run = format!(
            r#"<w:r><w:t xml:space="preserve">{REPL1}</w:t></w:r>"#
        );
        let run2 = format!(
            r#"<w:r><w:t xml:space="preserve">{REPL2}</w:t></w:r>"#
        );
        let body = format!(
            r#"<w:p><w:r><w:t>{P_A}{run}{P_B}{CTX_BEFORE}{run2}{CTX_AFTER}{TAIL}</w:t></w:r></w:p>"#
        );
        let docx = docx_with_body(&body);

        let accepted = accept_tracked_changes(&docx).expect("accept legacy part");
        let xml = document_xml(&accepted);

        let bodies = text_node_bodies(&xml);
        assert_eq!(bodies.len(), 1, "the legacy part must flatten to one text node");
        assert!(
            !bodies[0].contains('<'),
            "a text node still has markup nested inside it: {:?}",
            bodies[0]
        );
        // Nothing the document contained may be dropped or reordered.
        assert_eq!(
            bodies[0],
            run_after(),
            "flattening must keep every run's text in order"
        );
        assert_eq!(
            crate::parser::extract_text(&accepted).expect("read back"),
            run_after()
        );
    }

    /// Flattening is a repair for already-broken parts, so it must be invisible on
    /// a part the fixed writer produced - and accepting twice must not keep changing
    /// the file.
    #[test]
    fn a_well_formed_part_survives_the_flattener_byte_for_byte() {
        let clean = docx_with_body(&format!(r#"<w:p><w:r><w:t>{}</w:t></w:r></w:p>"#, run_before()));
        let accepted = accept_tracked_changes(&clean).expect("accept a flat part");
        assert_eq!(
            document_xml(&accepted),
            document_xml(&clean),
            "a well-formed part must pass through untouched"
        );

        let mut docx = docx_with_body(&format!(r#"<w:p><w:r><w:t>{}</w:t></w:r></w:p>"#, run_before()));
        docx = apply_tracked_edit(&docx, &TrackedEdit::new(FIND1, REPL1, None, None))
            .expect("first edit");
        docx = apply_tracked_edit(
            &docx,
            &TrackedEdit::new(FIND2, REPL2, Some(CTX_BEFORE), Some(CTX_AFTER)),
        )
        .expect("second edit");

        let once = accept_tracked_changes(&docx).expect("accept");
        let twice = accept_tracked_changes(&once).expect("accept again");
        assert_eq!(
            document_xml(&once),
            document_xml(&twice),
            "accepting an already-accepted part must be a no-op"
        );
        assert_eq!(
            crate::parser::extract_text(&once).expect("read back"),
            run_after()
        );
    }
}
