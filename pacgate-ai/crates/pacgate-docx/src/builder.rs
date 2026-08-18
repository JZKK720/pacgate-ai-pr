//! DOCX XML builder — converts structured JSON into `document.xml` bodies.

use crate::ooxml::xml_escape;
use anyhow::{Context, Result};
use serde::Deserialize;

// ─────────────────────────────────────────────────────────────────────────────
// Section types
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DocxSection {
    Heading        { level: u8, text: String },
    Paragraph      { text: String },
    /// Legal numbered list using 1. / 1.1 / (a) / (i) / (A) style
    NumberedList   { items: Vec<String>, #[serde(default)] depth: u8 },
    BulletList     { items: Vec<String> },
    Table          { headers: Vec<String>, rows: Vec<Vec<String>> },
    PageBreak,
    /// Recital paragraphs (WHEREAS) — not numbered
    Recital        { text: String },
    SignaturePage  { parties: Vec<SignatureParty> },
}

#[derive(Debug, Deserialize)]
pub struct SignatureParty {
    pub name: String,
    pub role: String,
    #[serde(default)]
    pub title: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// DocxBuilder
// ─────────────────────────────────────────────────────────────────────────────

pub struct DocxBuilder {
    title:     String,
    landscape: bool,
    sections:  Vec<DocxSection>,
}

impl DocxBuilder {
    pub fn from_json(structure: &serde_json::Value) -> Result<Self> {
        let title = structure
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("Untitled")
            .to_string();
        let landscape = structure
            .get("landscape")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        let sections_val = structure
            .get("sections")
            .context("structure must have 'sections' array")?;

        let sections: Vec<DocxSection> = serde_json::from_value(sections_val.clone())
            .context("failed to parse sections")?;

        Ok(Self { title, landscape, sections })
    }

    /// Render the full DOCX ZIP archive as bytes.
    pub fn build(self) -> Result<Vec<u8>> {
        use crate::{
            ooxml::{CONTENT_TYPES_XML, RELS_XML, SETTINGS_XML, WORD_RELS_XML},
            styles::STYLES_XML,
        };
        use std::io::Write;
        use zip::{write::FileOptions, ZipWriter};

        let mut buf = Vec::new();
        let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));
        let opts: FileOptions<()> = FileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        zip.start_file("[Content_Types].xml", opts)?;
        zip.write_all(CONTENT_TYPES_XML.as_bytes())?;

        zip.start_file("_rels/.rels", opts)?;
        zip.write_all(RELS_XML.as_bytes())?;

        zip.start_file("word/_rels/document.xml.rels", opts)?;
        zip.write_all(WORD_RELS_XML.as_bytes())?;

        zip.start_file("word/styles.xml", opts)?;
        zip.write_all(STYLES_XML.as_bytes())?;

        zip.start_file("word/settings.xml", opts)?;
        zip.write_all(SETTINGS_XML.as_bytes())?;

        let doc_xml = self.render_document_xml()?;
        zip.start_file("word/document.xml", opts)?;
        zip.write_all(doc_xml.as_bytes())?;

        zip.finish()?;
        Ok(buf)
    }

    fn render_document_xml(&self) -> Result<String> {
        let mut body = String::new();

        // Emit the document title (if set) as a top-level heading.
        if !self.title.is_empty() && self.title != "Untitled" {
            body.push_str(&para_with_style("Heading1", &xml_escape(&self.title)));
        }

        for section in &self.sections {
            match section {
                DocxSection::Heading { level, text } => {
                    let style = match level {
                        1 => "Heading1",
                        2 => "Heading2",
                        3 => "Heading3",
                        _ => "Heading3",
                    };
                    body.push_str(&para_with_style(style, &xml_escape(text)));
                }

                DocxSection::Paragraph { text } | DocxSection::Recital { text } => {
                    body.push_str(&para_with_style("Normal", &xml_escape(text)));
                }

                DocxSection::NumberedList { items, depth } => {
                    for (i, item) in items.iter().enumerate() {
                        let prefix = legal_number_prefix(*depth, i + 1);
                        body.push_str(&para_with_style(
                            "Normal",
                            &format!("{}{}", xml_escape(&prefix), xml_escape(item)),
                        ));
                    }
                }

                DocxSection::BulletList { items } => {
                    for item in items {
                        body.push_str(&para_with_style(
                            "Normal",
                            &format!("• {}", xml_escape(item)),
                        ));
                    }
                }

                DocxSection::Table { headers, rows } => {
                    body.push_str(&render_table(headers, rows));
                }

                DocxSection::PageBreak => {
                    body.push_str(
                        r#"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#,
                    );
                }

                DocxSection::SignaturePage { parties } => {
                    body.push_str(
                        r#"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#,
                    );
                    body.push_str(&para_with_style("Heading1", "SIGNATURE PAGE"));
                    for party in parties {
                        body.push_str(&render_signature_block(party));
                    }
                }
            }
        }

        let orientation = if self.landscape {
            r#"<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>"#
        } else {
            r#"<w:pgSz w:w="12240" w:h="15840"/>"#
        };

        Ok(format!(
            r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml">
  <w:body>
    {body}
    <w:sectPr>
      {orientation}
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1800"/>
    </w:sectPr>
  </w:body>
</w:document>
"#
        ))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn para_with_style(style_id: &str, run_text: &str) -> String {
    format!(
        r#"<w:p><w:pPr><w:pStyle w:val="{style_id}"/></w:pPr><w:r><w:t xml:space="preserve">{run_text}</w:t></w:r></w:p>"#
    )
}

/// Legal numbering: depth 0 → "1.", depth 1 → "1.1", depth 2 → "(a)", depth 3 → "(i)", depth 4 → "(A)"
fn legal_number_prefix(depth: u8, n: usize) -> String {
    match depth {
        0 => format!("{}. ", n),
        1 => format!("{}.{}  ", n / 10 + 1, n),
        2 => format!("({})  ", alpha_lower(n)),
        3 => format!("({})  ", roman_lower(n)),
        _ => format!("({})  ", alpha_upper(n)),
    }
}

fn alpha_lower(n: usize) -> char {
    char::from_u32('a' as u32 + (n - 1) as u32 % 26).unwrap_or('a')
}
fn alpha_upper(n: usize) -> char {
    char::from_u32('A' as u32 + (n - 1) as u32 % 26).unwrap_or('A')
}
fn roman_lower(n: usize) -> &'static str {
    match n {
        1 => "i", 2 => "ii", 3 => "iii", 4 => "iv", 5 => "v",
        6 => "vi", 7 => "vii", 8 => "viii", 9 => "ix", 10 => "x",
        _ => "xi",
    }
}

fn render_table(headers: &[String], rows: &[Vec<String>]) -> String {
    let mut out = String::from(
        r#"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>"#,
    );

    // Header row (bold)
    out.push_str("<w:tr>");
    for h in headers {
        out.push_str(&format!(
            r#"<w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">{}</w:t></w:r></w:p></w:tc>"#,
            xml_escape(h)
        ));
    }
    out.push_str("</w:tr>");

    // Data rows
    for row in rows {
        out.push_str("<w:tr>");
        for cell in row {
            out.push_str(&format!(
                r#"<w:tc><w:p><w:r><w:t xml:space="preserve">{}</w:t></w:r></w:p></w:tc>"#,
                xml_escape(cell)
            ));
        }
        out.push_str("</w:tr>");
    }

    out.push_str("</w:tbl>");
    out
}

fn render_signature_block(party: &SignatureParty) -> String {
    let title_line = party
        .title
        .as_deref()
        .map(|t| format!("\nTitle: {t}"))
        .unwrap_or_default();

    let text = format!(
        "By: _______________________________\nName: {}\nRole: {}{}",
        party.name, party.role, title_line
    );

    para_with_style("Normal", &xml_escape(&text))
}

/// Convenience: build a DOCX from a JSON structure in one call.
/// Returns the ZIP archive as bytes ready to write to disk.
pub fn build_from_structure(structure: &serde_json::Value) -> Result<Vec<u8>> {
    DocxBuilder::from_json(structure)?.build()
}
