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

    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Equal  => {
                revision_xml.push_str(&wrap_run(&xml_escape(change.value())));
            }
            ChangeTag::Delete => {
                revision_xml.push_str(&wrap_del(&xml_escape(change.value())));
            }
            ChangeTag::Insert => {
                revision_xml.push_str(&wrap_ins(&xml_escape(change.value())));
            }
        }
    }

    // Replace only the FIRST occurrence that matches context constraints
    let patched = replace_first_in_xml(xml, &find_escaped, &revision_xml, edit)?;
    Ok(patched)
}

fn replace_first_in_xml(
    xml:            &str,
    find_escaped:   &str,
    revision_xml:   &str,
    edit:           &TrackedEdit,
) -> Result<String> {
    // Simple text replacement within <w:t> run text.
    // In production this should parse the XML properly; for now use string replace.
    let position = if let (Some(cb), Some(ca)) = (&edit.context_before, &edit.context_after) {
        let anchor = format!("{}{}{}", xml_escape(cb), find_escaped, xml_escape(ca));
        xml.find(&anchor).map(|i| i + xml_escape(cb).len())
    } else {
        xml.find(find_escaped)
    };

    match position {
        Some(start) => {
            let end = start + find_escaped.len();
            Ok(format!("{}{}{}", &xml[..start], revision_xml, &xml[end..]))
        }
        None => bail!("find text not found with given context constraints"),
    }
}

fn wrap_run(text: &str) -> String {
    format!(r#"<w:r><w:t xml:space="preserve">{text}</w:t></w:r>"#)
}

fn wrap_del(text: &str) -> String {
    format!(
        r#"<w:del w:id="1" w:author="Pacgate AI" w:date="2025-01-01T00:00:00Z"><w:r><w:delText xml:space="preserve">{text}</w:delText></w:r></w:del>"#
    )
}

fn wrap_ins(text: &str) -> String {
    format!(
        r#"<w:ins w:id="2" w:author="Pacgate AI" w:date="2025-01-01T00:00:00Z"><w:r><w:t xml:space="preserve">{text}</w:t></w:r></w:ins>"#
    )
}
