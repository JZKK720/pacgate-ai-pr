//! DOCX text extraction — reads text content from a .docx file.

use anyhow::Result;
use std::io::Read;
use zip::ZipArchive;

/// Extract plain text from a .docx file's bytes.
pub fn extract_text(docx_bytes: &[u8]) -> Result<String> {
    let reader = std::io::Cursor::new(docx_bytes);
    let mut archive = ZipArchive::new(reader)?;

    let mut content = String::new();
    for i in 0..archive.len() {
        let mut file = archive.by_index(i)?;
        let name = file.name().to_string();
        if name == "word/document.xml" {
            let mut xml = String::new();
            file.read_to_string(&mut xml)?;
            // Strip XML tags to get plain text
            content = strip_xml_tags(&xml);
            break;
        }
    }
    Ok(content)
}

fn strip_xml_tags(xml: &str) -> String {
    let mut result = String::new();
    let mut in_tag = false;
    for ch in xml.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => result.push(ch),
            _ => {}
        }
    }
    result
}