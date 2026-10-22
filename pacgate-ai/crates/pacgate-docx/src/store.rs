//! FsDocumentStore — Filesystem-backed document storage with Postgres metadata.
//!
//! Stores document content on disk at:
//!   {DATA_DIR}/tenants/{tenant_id}/matters/{matter_id}/docs/{name}_v{n}.{ext}
//!
//! Stores document metadata (id, matter_id, tenant_id, name, version, storage_path,
//! owner_id, timestamps) in Postgres via `sqlx`.
//!
//! Implements the `DocumentStore` trait from `pacgate-agent`.

use std::path::PathBuf;

use async_trait::async_trait;
use pacgate_core::{
    Document, DocumentFormat, DocumentId, DocumentStore, FindResult, MatterId, TenantId, UserId,
};
use sqlx::{PgPool, Row};
use tracing::{debug, instrument};
use uuid::Uuid;

use crate::error::StoreError;

/// Filesystem + Postgres document store.
///
/// Content lives on disk; metadata lives in Postgres. The `storage_path` column
/// in the `documents` table holds the path relative to `data_dir`.
pub struct FsDocumentStore {
    db: PgPool,
    data_dir: PathBuf,
}

impl FsDocumentStore {
    pub fn new(db: PgPool, data_dir: impl Into<PathBuf>) -> Self {
        Self {
            db,
            data_dir: data_dir.into(),
        }
    }

    pub async fn upload_bytes(
        &self,
        matter_id: &MatterId,
        filename: &str,
        bytes: &[u8],
        owner_id: &UserId,
    ) -> pacgate_core::Result<Document> {
        let matter_row = sqlx::query("SELECT tenant_id FROM matters WHERE id = $1")
            .bind(matter_id.0)
            .fetch_one(&self.db)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        let tenant_id = TenantId(matter_row.get::<Uuid, _>("tenant_id"));
        self.ensure_docs_dir(&tenant_id, matter_id)
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        let file_path = std::path::Path::new(filename);
        let stem = file_path
            .file_stem()
            .and_then(|value| value.to_str())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                pacgate_core::PacgateError::ValidationError(
                    "filename must include a non-empty stem".into(),
                )
            })?;

        let format = match file_path
            .extension()
            .and_then(|value| value.to_str())
            .map(|value| value.to_ascii_lowercase())
            .as_deref()
        {
            Some("docx") => "docx",
            Some("pdf") => "pdf",
            Some("txt") => "txt",
            Some("md") | Some("markdown") => "markdown",
            Some("xlsx") => "xlsx",
            Some("pptx") => "pptx",
            Some("html") | Some("htm") => "html",
            // Raster images. These are NOT text-native: they carry no extractable
            // text in the file, so `pacgate-api/src/extract.rs` routes them to
            // ocr-service, which already returns images "as-is" (see
            // `_prepare_pages` in deploy/ocr-service/app.py). Accepting them here
            // is what gives a client a path to the OCR lane at all - until
            // 2026-10-21 the only way in was a PDF, so a photo or a scan could not
            // be submitted even though the OCR service handled it correctly.
            Some("png") => "png",
            Some("jpg") | Some("jpeg") => "jpeg",
            Some("tif") | Some("tiff") => "tiff",
            Some("bmp") => "bmp",
            Some("webp") => "webp",
            _ => {
                // Name what was rejected and what is accepted. The legacy binary
                // formats are called out with a specific remedy because clients do
                // send them and "unsupported" alone tells an operator nothing.
                let ext = file_path
                    .extension()
                    .and_then(|value| value.to_str())
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
                         .docx .xlsx .pptx .pdf .txt .md .html \
                         .png .jpg .jpeg .tif .tiff .bmp .webp (images go to OCR)"
                    ),
                };
                return Err(pacgate_core::PacgateError::ValidationError(msg));
            }
        };

        let version = self
            .latest_version(matter_id, stem)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
            + 1;

        let rel_path = Self::rel_path(&tenant_id, matter_id, stem, version, format);
        let abs_path = self.abs_path(&rel_path);

        std::fs::write(&abs_path, bytes).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!(
                "failed to write {}: {}",
                abs_path.display(),
                e
            ))
        })?;

        self.insert_doc_row(
            matter_id, &tenant_id, stem, format, version, &rel_path, owner_id,
        )
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))
    }

    pub async fn download_bytes(
        &self,
        id: &DocumentId,
        version: Option<u32>,
    ) -> pacgate_core::Result<(Document, Vec<u8>)> {
        let doc = if let Some(requested_version) = version {
            let base_doc = self.fetch_doc(id, None).await.map_err(|e| match e {
                StoreError::DocumentNotFound(_) => {
                    pacgate_core::PacgateError::DocumentNotFound { id: id.as_str() }
                }
                other => pacgate_core::PacgateError::StorageError(other.to_string()),
            })?;

            let row = sqlx::query(
                "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
                 FROM documents WHERE matter_id = $1 AND name = $2 AND version = $3 LIMIT 1",
            )
            .bind(base_doc.matter_id.0)
            .bind(&base_doc.name)
            .bind(requested_version as i32)
            .fetch_one(&self.db)
            .await
            .map_err(|e| match e {
                sqlx::Error::RowNotFound => pacgate_core::PacgateError::DocumentNotFound {
                    id: format!("{}@v{}", id.as_str(), requested_version),
                },
                other => pacgate_core::PacgateError::StorageError(other.to_string()),
            })?;
            row_to_document(&row)
        } else {
            self.latest_doc_in_family(id).await?
        };

        let path = self.abs_path(&doc.storage_path);
        let bytes = std::fs::read(&path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!(
                "failed to read {}: {}",
                path.display(),
                e
            ))
        })?;

        Ok((doc, bytes))
    }

    pub async fn list_versions_for_document(
        &self,
        id: &DocumentId,
    ) -> pacgate_core::Result<Vec<Document>> {
        let base_doc = self.fetch_doc(id, None).await.map_err(|e| match e {
            StoreError::DocumentNotFound(_) => {
                pacgate_core::PacgateError::DocumentNotFound { id: id.as_str() }
            }
            other => pacgate_core::PacgateError::StorageError(other.to_string()),
        })?;

        let rows = sqlx::query(
            "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
             FROM documents WHERE matter_id = $1 AND name = $2 ORDER BY version DESC",
        )
        .bind(base_doc.matter_id.0)
        .bind(&base_doc.name)
        .fetch_all(&self.db)
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        Ok(rows.iter().map(row_to_document).collect())
    }

    async fn latest_doc_in_family(&self, id: &DocumentId) -> pacgate_core::Result<Document> {
        let base_doc = self.fetch_doc(id, None).await.map_err(|e| match e {
            StoreError::DocumentNotFound(_) => {
                pacgate_core::PacgateError::DocumentNotFound { id: id.as_str() }
            }
            other => pacgate_core::PacgateError::StorageError(other.to_string()),
        })?;

        let row = sqlx::query(
            "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
             FROM documents WHERE matter_id = $1 AND name = $2 ORDER BY version DESC LIMIT 1",
        )
        .bind(base_doc.matter_id.0)
        .bind(&base_doc.name)
        .fetch_one(&self.db)
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        Ok(row_to_document(&row))
    }

    pub async fn apply_edit_to_family(
        &self,
        id: &DocumentId,
        find: &str,
        replace: &str,
        ctx_before: Option<&str>,
        ctx_after: Option<&str>,
    ) -> pacgate_core::Result<Document> {
        let doc = self.latest_doc_in_family(id).await?;
        if doc.format != DocumentFormat::Docx {
            return Err(pacgate_core::PacgateError::ValidationError(
                "tracked edits are currently only supported for .docx documents".into(),
            ));
        }

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path)
            .map_err(|e| pacgate_core::PacgateError::StorageError(format!("read failed: {}", e)))?;

        let edit = crate::diff::TrackedEdit::new(find, replace, ctx_before, ctx_after);
        let edited = crate::diff::apply_tracked_edit(&content, &edit)
            .map_err(|e| pacgate_core::PacgateError::DocxError(e.to_string()))?;

        let version = self
            .latest_version(&doc.matter_id, &doc.name)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
            + 1;
        let rel_path = Self::rel_path(&doc.tenant_id, &doc.matter_id, &doc.name, version, "docx");
        let new_abs = self.abs_path(&rel_path);

        std::fs::write(&new_abs, &edited).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("write failed: {}", e))
        })?;

        self.insert_doc_row(
            &doc.matter_id,
            &doc.tenant_id,
            &doc.name,
            "docx",
            version,
            &rel_path,
            &doc.owner_id,
        )
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))
    }

    pub async fn accept_latest_changes(&self, id: &DocumentId) -> pacgate_core::Result<Document> {
        let doc = self.latest_doc_in_family(id).await?;
        if doc.format != DocumentFormat::Docx {
            return Err(pacgate_core::PacgateError::ValidationError(
                "accept_changes is currently only supported for .docx documents".into(),
            ));
        }

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path)
            .map_err(|e| pacgate_core::PacgateError::StorageError(format!("read failed: {}", e)))?;
        let accepted = crate::diff::accept_tracked_changes(&content)
            .map_err(|e| pacgate_core::PacgateError::DocxError(e.to_string()))?;

        let version = self
            .latest_version(&doc.matter_id, &doc.name)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
            + 1;
        let rel_path = Self::rel_path(&doc.tenant_id, &doc.matter_id, &doc.name, version, "docx");
        let new_abs = self.abs_path(&rel_path);

        std::fs::write(&new_abs, &accepted).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("write failed: {}", e))
        })?;

        self.insert_doc_row(
            &doc.matter_id,
            &doc.tenant_id,
            &doc.name,
            "docx",
            version,
            &rel_path,
            &doc.owner_id,
        )
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))
    }

    pub async fn delete_document_family(&self, id: &DocumentId) -> pacgate_core::Result<()> {
        let documents = self.list_versions_for_document(id).await?;
        let Some(latest_doc) = documents.first() else {
            return Err(pacgate_core::PacgateError::DocumentNotFound { id: id.as_str() });
        };

        for document in &documents {
            let path = self.abs_path(&document.storage_path);
            if path.exists() {
                std::fs::remove_file(&path).map_err(|e| {
                    pacgate_core::PacgateError::StorageError(format!(
                        "delete failed for {}: {}",
                        path.display(),
                        e
                    ))
                })?;
            }
        }

        sqlx::query("DELETE FROM documents WHERE matter_id = $1 AND name = $2")
            .bind(latest_doc.matter_id.0)
            .bind(&latest_doc.name)
            .execute(&self.db)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        Ok(())
    }

    /// Resolve the absolute filesystem path for a document.
    fn abs_path(&self, storage_path: &str) -> PathBuf {
        self.data_dir.join(storage_path)
    }

    /// Build the relative storage path for a new document version.
    fn rel_path(
        tenant_id: &TenantId,
        matter_id: &MatterId,
        name: &str,
        version: u32,
        format: &str,
    ) -> String {
        let ext = match format {
            "docx" => "docx",
            "pdf" => "pdf",
            "txt" => "txt",
            "markdown" => "md",
            "xlsx" => "xlsx",
            "pptx" => "pptx",
            "html" => "html",
            "png" => "png",
            "jpeg" => "jpg",
            "tiff" => "tif",
            "bmp" => "bmp",
            "webp" => "webp",
            _ => "bin",
        };
        format!(
            "tenants/{}/matters/{}/docs/{}_v{}.{}",
            tenant_id.as_str(),
            matter_id.as_str(),
            name,
            version,
            ext
        )
    }

    /// Ensure the docs directory exists for a matter.
    fn ensure_docs_dir(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
    ) -> Result<(), StoreError> {
        let dir = self
            .data_dir
            .join("tenants")
            .join(tenant_id.as_str())
            .join("matters")
            .join(matter_id.as_str())
            .join("docs");
        std::fs::create_dir_all(&dir).map_err(|e| StoreError::Io(e.to_string()))?;
        Ok(())
    }

    /// Get the latest version number for a (matter_id, name) pair.
    async fn latest_version(&self, matter_id: &MatterId, name: &str) -> Result<u32, StoreError> {
        let row = sqlx::query(
            "SELECT COALESCE(MAX(version), 0) as max_ver FROM documents WHERE matter_id = $1 AND name = $2",
        )
        .bind(matter_id.0)
        .bind(name)
        .fetch_one(&self.db)
        .await?;

        Ok(row.get::<i32, _>("max_ver") as u32)
    }

    /// Insert a document metadata row and return the constructed `Document`.
    #[allow(clippy::too_many_arguments)]
    async fn insert_doc_row(
        &self,
        matter_id: &MatterId,
        tenant_id: &TenantId,
        name: &str,
        format: &str,
        version: u32,
        storage_path: &str,
        owner_id: &UserId,
    ) -> Result<Document, StoreError> {
        let row = sqlx::query(
            "INSERT INTO documents (matter_id, tenant_id, name, format, version, storage_path, owner_id)
             VALUES ($1, $2, $3, $4, $5, $6, $7)
             RETURNING id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at",
        )
        .bind(matter_id.0)
        .bind(tenant_id.0)
        .bind(name)
        .bind(format)
        .bind(version as i32)
        .bind(storage_path)
        .bind(owner_id.0)
        .fetch_one(&self.db)
        .await?;

        Ok(row_to_document(&row))
    }

    /// Fetch a document metadata row by id (latest version or specific version).
    async fn fetch_doc(
        &self,
        id: &DocumentId,
        version: Option<u32>,
    ) -> Result<Document, StoreError> {
        let row = if let Some(ver) = version {
            sqlx::query(
                "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
                 FROM documents WHERE id = $1 AND version = $2",
            )
            .bind(id.0)
            .bind(ver as i32)
            .fetch_one(&self.db)
            .await?
        } else {
            // Latest version = highest version for this id
            sqlx::query(
                "SELECT id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
                 FROM documents WHERE id = $1 ORDER BY version DESC LIMIT 1",
            )
            .bind(id.0)
            .fetch_one(&self.db)
            .await?
        };
        Ok(row_to_document(&row))
    }
}

fn row_to_document(row: &sqlx::postgres::PgRow) -> Document {
    let format_str: String = row.get("format");
    let format = DocumentFormat::from_storage_key(&format_str);
    Document {
        id: DocumentId(row.get::<Uuid, _>("id")),
        matter_id: MatterId(row.get::<Uuid, _>("matter_id")),
        tenant_id: TenantId(row.get::<Uuid, _>("tenant_id")),
        name: row.get("name"),
        format,
        version: row.get::<i32, _>("version") as u32,
        storage_path: row.get("storage_path"),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
        owner_id: UserId(row.get::<Uuid, _>("owner_id")),
    }
}

impl FsDocumentStore {
    /// Read a stored document as text, honouring the format.
    ///
    /// `std::fs::read_to_string` treats every byte in the file as UTF-8, so a
    /// DOCX (a ZIP archive) fails with "stream did not contain valid UTF-8" -
    /// measured 2026-10-08 on the Firm KB research memo: the agent lane's
    /// read_document tool surfaced `StorageError` for every binary document
    /// even though extraction (OOXML zip scan) handles the same file fine.
    /// The failure was invisible at upload time because downloads go through
    /// `download_bytes`, which is binary-safe; only the text-read path broke.
    ///
    /// Text-native formats keep the strict `from_utf8` read (a `.txt` that is
    /// not UTF-8 SHOULD error - see pacgate-api text_extract.rs for the same
    /// reasoning). Binary formats route through this crate's extractor so the
    /// agent's `read_document`/`find_in_document` see extracted text rather
    /// than an error or raw base64.
    fn read_text(
        path: &std::path::Path,
        format: pacgate_core::DocumentFormat,
    ) -> pacgate_core::Result<String> {
        let bytes = std::fs::read(path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!(
                "failed to read {}: {}",
                path.display(),
                e
            ))
        })?;

        use pacgate_core::DocumentFormat;
        match format {
            DocumentFormat::Docx | DocumentFormat::Xlsx | DocumentFormat::Pptx => {
                // The OOXML zip-scan text reader this crate ships. A package
                // that is NOT actually a zip (corrupt upload) still errors -
                // StorageError keeps the fail-closed contract.
                let text = crate::parser::extract_text(&bytes).map_err(|e| {
                    pacgate_core::PacgateError::StorageError(format!(
                        "binary text extraction failed for {}: {}",
                        path.display(),
                        e
                    ))
                })?;
                if text.trim().is_empty() {
                    // An empty extraction IS a finding, not silence: the agent
                    // would otherwise read "" and conclude the document is empty.
                    tracing::warn!(
                        path = %path.display(),
                        "binary document extracted to empty text; review panel should confirm"
                    );
                }
                Ok(text)
            }
            DocumentFormat::Pdf => Err(pacgate_core::PacgateError::StorageError(
                "PDF has no native text layer in this store; use the OCR/convert lane for text"
                    .to_string(),
            )),
            // Same reasoning as PDF: a raster carries no text layer to read. Saying
            // so names the right lane instead of surfacing "stream did not contain
            // valid UTF-8" from the UTF-8 arm below, which reads as corruption.
            DocumentFormat::ImagePng
            | DocumentFormat::ImageJpeg
            | DocumentFormat::ImageTiff
            | DocumentFormat::ImageBmp
            | DocumentFormat::ImageWebp => Err(pacgate_core::PacgateError::StorageError(
                "image has no native text layer; use the OCR lane for text".to_string(),
            )),
            // Txt / Markdown / Html are UTF-8 by definition.
            _ => String::from_utf8(bytes).map_err(|e| {
                pacgate_core::PacgateError::StorageError(format!(
                    "failed to read {}: {}",
                    path.display(),
                    e
                ))
            }),
        }
    }
}

/// Largest index `<= i` that is a char boundary of `s`, for safe slicing.
fn floor_char_boundary(s: &str, i: usize) -> usize {
    let mut i = i.min(s.len());
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Smallest index `>= i` that is a char boundary of `s`, for safe slicing.
fn ceil_char_boundary(s: &str, i: usize) -> usize {
    let mut i = i.min(s.len());
    while i < s.len() && !s.is_char_boundary(i) {
        i += 1;
    }
    i
}

/// Byte offset where each page (`lines_per_page` lines) starts, counted by
/// newline bytes. Page 1 always starts at 0; every start is a char boundary.
fn page_starts(content: &str, lines_per_page: usize) -> Vec<usize> {
    let mut starts = vec![0usize];
    if lines_per_page == 0 {
        return starts;
    }
    let mut line_count = 0usize;
    for (idx, b) in content.bytes().enumerate() {
        if b == b'\n' {
            line_count += 1;
            if line_count % lines_per_page == 0 {
                starts.push(idx + 1);
            }
        }
    }
    starts
}

/// Case-insensitive text scan behind `find_in`.
///
/// Two properties the previous implementation lacked:
/// - one result per MATCH. The old loop re-ran `content_lower.find` (first
///   match only) once per page chunk, so a 3-page document reported the same
///   hit three times under three different page numbers.
/// - char-boundary-safe context slicing. The old `pos - 100` /
///   `pos + len + 100` byte arithmetic panicked with "byte index is not a
///   char boundary" on Chinese text, where the 3-byte-per-character stride
///   makes a blind 100-byte window land mid-character about two times in
///   three.
///
/// Matching lowercases ASCII only (`to_ascii_lowercase`): byte offsets stay
/// identical to the original text for every input, CJK included, so slices
/// taken from the original are always valid. Full Unicode case-folding would
/// break that alignment (e.g. U+0130 changes length) and is deliberately not
/// attempted - the same trade-off text_extract.rs already documents.
fn find_matches(content: &str, query: &str, lines_per_page: usize) -> Vec<FindResult> {
    let query_lower = query.to_ascii_lowercase();
    if query_lower.is_empty() {
        return Vec::new();
    }
    let content_lower = content.to_ascii_lowercase();

    // Ceiling on results, mirroring the redact detectors' MAX_MATCHES stance:
    // a pathological input becomes a truncated answer, not unbounded memory.
    const MAX_RESULTS: usize = 4096;

    let starts = page_starts(content, lines_per_page);
    let mut results = Vec::new();

    for (page_idx, &page_start) in starts.iter().enumerate() {
        let page_end = starts.get(page_idx + 1).copied().unwrap_or(content.len());
        let hay = &content_lower[page_start..page_end];
        let mut from = 0usize;
        while let Some(rel) = hay[from..].find(&query_lower) {
            let match_start = page_start + from + rel;
            let match_end = match_start + query_lower.len();
            let ctx_start =
                floor_char_boundary(content, match_start.saturating_sub(100)).max(page_start);
            let ctx_end = ceil_char_boundary(content, (match_end + 100).min(page_end));
            results.push(FindResult {
                page: (page_idx + 1) as u32,
                context: content[ctx_start..ctx_end].to_string(),
                match_start,
                match_len: query_lower.len(),
            });
            if results.len() >= MAX_RESULTS {
                return results;
            }
            from += rel + query_lower.len();
        }
    }
    results
}

#[async_trait]
impl DocumentStore for FsDocumentStore {
    #[instrument(skip(self))]
    async fn read(&self, id: &DocumentId) -> pacgate_core::Result<String> {
        let doc = self
            .fetch_doc(id, None)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;
        let path = self.abs_path(&doc.storage_path);
        debug!(path = %path.display(), format = ?doc.format, "reading document");
        Self::read_text(&path, doc.format)
    }

    #[instrument(skip(self))]
    async fn read_version(&self, id: &DocumentId, version: u32) -> pacgate_core::Result<String> {
        let doc = self
            .fetch_doc(id, Some(version))
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;
        let path = self.abs_path(&doc.storage_path);
        Self::read_text(&path, doc.format)
    }

    #[instrument(skip(self))]
    async fn list_for_matter(&self, matter_id: &MatterId) -> pacgate_core::Result<Vec<Document>> {
        // Return only the latest version of each document name
        let rows = sqlx::query(
            "SELECT DISTINCT ON (name) id, matter_id, tenant_id, name, format, version, storage_path, owner_id, created_at, updated_at
             FROM documents WHERE matter_id = $1
             ORDER BY name, version DESC",
        )
        .bind(matter_id.0)
        .fetch_all(&self.db)
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        Ok(rows.iter().map(row_to_document).collect())
    }

    #[instrument(skip(self))]
    async fn find_in(&self, id: &DocumentId, query: &str) -> pacgate_core::Result<Vec<FindResult>> {
        let content = self.read(id).await?;
        Ok(find_matches(&content, query, 40))
    }

    #[instrument(skip(self, structure))]
    async fn create_from_structure(
        &self,
        matter_id: &MatterId,
        filename: &str,
        structure: &serde_json::Value,
    ) -> pacgate_core::Result<Document> {
        // Determine tenant_id from the matter
        let matter_row = sqlx::query("SELECT tenant_id FROM matters WHERE id = $1")
            .bind(matter_id.0)
            .fetch_one(&self.db)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        let tenant_id = TenantId(matter_row.get::<Uuid, _>("tenant_id"));

        self.ensure_docs_dir(&tenant_id, matter_id)
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        // Get next version number
        let version = self
            .latest_version(matter_id, filename)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
            + 1;

        let format = "docx";
        let rel_path = Self::rel_path(&tenant_id, matter_id, filename, version, format);
        let abs_path = self.abs_path(&rel_path);

        // Generate DOCX content from structure using the builder
        let docx_bytes = crate::builder::build_from_structure(structure)
            .map_err(|e| pacgate_core::PacgateError::DocxError(e.to_string()))?;

        std::fs::write(&abs_path, &docx_bytes).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!(
                "failed to write {}: {}",
                abs_path.display(),
                e
            ))
        })?;

        debug!(path = %abs_path.display(), version, "document created");

        // Attribute the document to the matter's creator (the agent tools do
        // not carry the requesting user's identity yet; the matter creator is
        // a valid owner that satisfies the FK constraint).
        let owner_row = sqlx::query("SELECT created_by FROM matters WHERE id = $1")
            .bind(matter_id.0)
            .fetch_one(&self.db)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;
        let owner_id = UserId(owner_row.get::<Uuid, _>("created_by"));

        self.insert_doc_row(
            matter_id, &tenant_id, filename, format, version, &rel_path, &owner_id,
        )
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))
    }

    #[instrument(skip(self))]
    async fn apply_edit(
        &self,
        id: &DocumentId,
        find: &str,
        replace: &str,
        ctx_before: Option<&str>,
        ctx_after: Option<&str>,
    ) -> pacgate_core::Result<Document> {
        let doc = self
            .fetch_doc(id, None)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path)
            .map_err(|e| pacgate_core::PacgateError::StorageError(format!("read failed: {}", e)))?;

        // Apply the edit using the DOCX diff engine
        let edit = crate::diff::TrackedEdit::new(find, replace, ctx_before, ctx_after);
        let edited = crate::diff::apply_tracked_edit(&content, &edit)
            .map_err(|e| pacgate_core::PacgateError::DocxError(e.to_string()))?;

        // Write as a new version
        let version = doc.version + 1;
        let rel_path = Self::rel_path(&doc.tenant_id, &doc.matter_id, &doc.name, version, "docx");
        let new_abs = self.abs_path(&rel_path);

        std::fs::write(&new_abs, &edited).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("write failed: {}", e))
        })?;

        self.insert_doc_row(
            &doc.matter_id,
            &doc.tenant_id,
            &doc.name,
            "docx",
            version,
            &rel_path,
            &doc.owner_id,
        )
        .await
        .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))
    }

    #[instrument(skip(self))]
    async fn replicate(&self, id: &DocumentId, count: u32) -> pacgate_core::Result<Vec<Document>> {
        if count == 0 || count > 20 {
            return Err(pacgate_core::PacgateError::ValidationError(
                "replicate count must be 1-20".into(),
            ));
        }

        let doc = self
            .fetch_doc(id, None)
            .await
            .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path)
            .map_err(|e| pacgate_core::PacgateError::StorageError(format!("read failed: {}", e)))?;

        let mut docs = Vec::with_capacity(count as usize);
        for i in 0..count {
            let version = self
                .latest_version(&doc.matter_id, &doc.name)
                .await
                .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
                + 1;

            let copy_name = format!("{}_copy_{}", doc.name, i + 1);
            let rel_path =
                Self::rel_path(&doc.tenant_id, &doc.matter_id, &copy_name, version, "docx");
            let new_abs = self.abs_path(&rel_path);

            std::fs::write(&new_abs, &content).map_err(|e| {
                pacgate_core::PacgateError::StorageError(format!("write failed: {}", e))
            })?;

            let new_doc = self
                .insert_doc_row(
                    &doc.matter_id,
                    &doc.tenant_id,
                    &copy_name,
                    "docx",
                    version,
                    &rel_path,
                    &doc.owner_id,
                )
                .await
                .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?;

            docs.push(new_doc);
        }
        Ok(docs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pacgate_core::DocumentFormat;

    /// The regression this fixes: `read_to_string` on a DOCX (a ZIP) fails
    /// with "stream did not contain valid UTF-8" - the exact error the client
    /// healthcheck saw on 研究备忘录_先例检索结果_v1.0.docx. read_text must
    /// extract the text instead of treating the archive as UTF-8 text.
    #[test]
    fn read_text_extracts_ooxml_instead_of_erroring_on_binary() {
        // A real DOCX-shaped zip: word/document.xml with a text run, built
        // through the same entry point create_from_structure uses.
        let structure = serde_json::json!({
            "title": "研究备忘录",
            "sections": [
                { "type": "heading", "level": 1, "text": "一、研究问题" },
                { "type": "paragraph", "text": "先例检索结果：合同受阻（force majeure）条款分析。" }
            ]
        });
        let docx = crate::builder::build_from_structure(&structure).expect("docx builds");

        let dir = std::env::temp_dir().join(format!("pacgate-read-text-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("memo.docx");
        std::fs::write(&path, &docx).expect("write docx");

        let out = FsDocumentStore::read_text(&path, DocumentFormat::Docx);
        std::fs::remove_dir_all(&dir).ok();

        let text = out.expect("docx read must extract, not error on binary");
        assert!(
            text.contains("研究备忘录") || text.contains("先例检索"),
            "extracted text must carry the document content; got {text:?}"
        );
    }

    /// Text-native formats must keep the strict UTF-8 contract: a .txt with
    /// invalid UTF-8 errors (fail closed), it is not silently lossy.
    #[test]
    fn read_text_txt_still_requires_utf8() {
        let dir = std::env::temp_dir().join(format!("pacgate-read-txt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("bad.txt");
        std::fs::write(&path, [0xff, 0xfe, 0x01]).expect("write txt");

        let out = FsDocumentStore::read_text(&path, DocumentFormat::Txt);
        std::fs::remove_dir_all(&dir).ok();
        assert!(out.is_err(), "invalid-UTF-8 txt must error, not go lossy");
    }

    /// A PDF has no in-store text extractor; the honest answer is an error
    /// that names the right lane, not empty text and not raw binary.
    #[test]
    fn read_text_pdf_names_the_ocr_lane() {
        let dir = std::env::temp_dir().join(format!("pacgate-read-pdf-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("scan.pdf");
        std::fs::write(&path, b"%PDF-1.7 minimal").expect("write pdf");

        let out = FsDocumentStore::read_text(&path, DocumentFormat::Pdf);
        std::fs::remove_dir_all(&dir).ok();
        let err = out.expect_err("pdf text read must direct to the OCR lane");
        assert!(
            err.to_string().contains("OCR"),
            "error should point at the OCR/convert lane; got {err}"
        );
    }

    /// An image must name the OCR lane the same way a PDF does. Left to the
    /// UTF-8 arm it would report "stream did not contain valid UTF-8", which
    /// reads as a corrupt file rather than "this belongs on a different lane".
    #[test]
    fn read_text_image_names_the_ocr_lane() {
        let dir = std::env::temp_dir().join(format!("pacgate-read-img-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("scan.png");
        std::fs::write(&path, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).expect("write png");

        let out = FsDocumentStore::read_text(&path, DocumentFormat::ImagePng);
        std::fs::remove_dir_all(&dir).ok();
        let err = out.expect_err("an image has no in-store text layer; it must direct to OCR");
        assert!(
            err.to_string().contains("OCR"),
            "error should point at the OCR lane, not report invalid UTF-8; got {err}"
        );
    }

    /// The regression: 3-byte CJK stride made `pos - 100` land mid-character
    /// and panic with "byte index is not a char boundary" on Chinese text.
    /// CJK literals are written as \u{...} escapes so the patch travels
    /// encoding-safe; the byte-length asserts pin them as real 3-byte
    /// scalars at runtime (he-tong-shou-zu-tiao-kuan-fen-xi / jie-wei).
    #[test]
    fn find_matches_cjk_context_never_panics() {
        assert_eq!(
            "\u{53d7}\u{963b}".len(),
            6,
            "escapes must decode to two 3-byte scalars"
        );
        let content = format!(
            "{}{}",
            "\u{5408}\u{540c}\u{53d7}\u{963b}\u{6761}\u{6b3e}\u{5206}\u{6790}\u{3002}".repeat(30),
            "\u{7ed3}\u{5c3e}\u{3002}"
        );
        let results = find_matches(&content, "\u{53d7}\u{963b}", 40);
        assert!(!results.is_empty(), "CJK query must match CJK content");
        assert!(
            results[0].context.contains("\u{53d7}\u{963b}"),
            "context must carry the match; got {:?}",
            results[0].context
        );
    }

    /// The old loop re-reported the first match once per page chunk: a
    /// 3-page document returned the same hit three times under three page
    /// numbers. One match must yield one result with the right page.
    #[test]
    fn find_matches_reports_one_result_per_match() {
        let mut single = String::from("force majeure anchor\n");
        for i in 0..100 {
            single.push_str(&format!("line {i} ordinary text\n"));
        }
        let results = find_matches(&single, "FORCE MAJEURE", 40);
        assert_eq!(results.len(), 1, "one match, not one per page");
        assert_eq!(results[0].page, 1);

        let mut spread = String::from("force majeure page one\n");
        for i in 0..39 {
            spread.push_str(&format!("filler {i}\n"));
        }
        spread.push_str("force majeure page two\n");
        let results = find_matches(&spread, "force majeure", 40);
        assert_eq!(results.len(), 2, "one result per match across pages");
        assert_eq!(results[0].page, 1);
        assert_eq!(results[1].page, 2);
    }

    /// ASCII case-insensitivity is preserved AND the context is sliced from
    /// the original text, so original casing survives in the reported context.
    #[test]
    fn find_matches_ascii_case_insensitive_context_original() {
        let content = "The contract is governed by Force Majeure clauses.\n".repeat(5);
        let hits = find_matches(&content, "force majeure", 40);
        assert_eq!(hits.len(), 5);
        assert!(
            hits[0].context.contains("Force Majeure"),
            "context must preserve original casing; got {:?}",
            hits[0].context
        );
        assert!(find_matches(&content, "\u{4e0d}\u{5b58}\u{5728}", 40).is_empty());
        assert!(
            find_matches(&content, "", 40).is_empty(),
            "empty query matches nothing"
        );
    }

    /// A match deep inside multi-byte runs: the 100-byte context window must
    /// snap to char boundaries on both sides instead of panicking, and the
    /// reported byte offset must be exact. (jia = U+7532, yi = U+4E59.)
    #[test]
    fn find_matches_context_snaps_to_char_boundaries() {
        assert_eq!("\u{7532}".len(), 3, "jia must be one 3-byte scalar");
        let content = format!(
            "{}needle{}",
            "\u{7532}".repeat(200),
            "\u{4e59}".repeat(200)
        );
        let results = find_matches(&content, "needle", 40);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].match_start, 600, "200 CJK chars x 3 bytes");
        assert!(results[0].context.contains("needle"));
    }
}
