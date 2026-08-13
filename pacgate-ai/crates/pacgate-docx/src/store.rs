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
use pacgate_core::{Document, DocumentFormat, DocumentId, DocumentStore, FindResult, MatterId, TenantId, UserId};
use sqlx::{PgPool, Row};
use tracing::{debug, instrument};
use uuid::Uuid;

use crate::error::StoreError;

/// Filesystem + Postgres document store.
///
/// Content lives on disk; metadata lives in Postgres. The `storage_path` column
/// in the `documents` table holds the path relative to `data_dir`.
pub struct FsDocumentStore {
    db:       PgPool,
    data_dir: PathBuf,
}

impl FsDocumentStore {
    pub fn new(db: PgPool, data_dir: impl Into<PathBuf>) -> Self {
        Self {
            db,
            data_dir: data_dir.into(),
        }
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
    async fn latest_version(
        &self,
        matter_id: &MatterId,
        name: &str,
    ) -> Result<u32, StoreError> {
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
    async fn fetch_doc(&self, id: &DocumentId, version: Option<u32>) -> Result<Document, StoreError> {
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
    let format = match format_str.as_str() {
        "docx" => DocumentFormat::Docx,
        "pdf" => DocumentFormat::Pdf,
        "txt" => DocumentFormat::Txt,
        "markdown" => DocumentFormat::Markdown,
        _ => DocumentFormat::Txt,
    };
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

#[async_trait]
impl DocumentStore for FsDocumentStore {
    #[instrument(skip(self))]
    async fn read(&self, id: &DocumentId) -> pacgate_core::Result<String> {
        let doc = self.fetch_doc(id, None).await.map_err(|e| {
            pacgate_core::PacgateError::StorageError(e.to_string())
        })?;
        let path = self.abs_path(&doc.storage_path);
        debug!(path = %path.display(), "reading document");
        std::fs::read_to_string(&path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("failed to read {}: {}", path.display(), e))
        })
    }

    #[instrument(skip(self))]
    async fn read_version(&self, id: &DocumentId, version: u32) -> pacgate_core::Result<String> {
        let doc = self.fetch_doc(id, Some(version)).await.map_err(|e| {
            pacgate_core::PacgateError::StorageError(e.to_string())
        })?;
        let path = self.abs_path(&doc.storage_path);
        std::fs::read_to_string(&path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("failed to read {}: {}", path.display(), e))
        })
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
        let query_lower = query.to_lowercase();
        let content_lower = content.to_lowercase();

        let mut results = Vec::new();
        let lines: Vec<&str> = content.lines().collect();
        let lines_per_page = 40;

        for (i, chunk) in lines.chunks(lines_per_page).enumerate() {
            let page = (i + 1) as u32;
            if let Some(pos) = content_lower.find(&query_lower) {
                let match_start = pos;
                let context_start = pos.saturating_sub(100);
                let context_end = (pos + query.len() + 100).min(content.len());
                let context = content[context_start..context_end].to_string();
                results.push(FindResult {
                    page,
                    context,
                    match_start,
                    match_len: query.len(),
                });
            }
        }
        Ok(results)
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
            pacgate_core::PacgateError::StorageError(format!("failed to write {}: {}", abs_path.display(), e))
        })?;

        debug!(path = %abs_path.display(), version, "document created");

        // Insert metadata row — owner_id is a placeholder until auth is wired
        let owner_id = UserId::new();
        self.insert_doc_row(matter_id, &tenant_id, filename, format, version, &rel_path, &owner_id)
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
        let doc = self.fetch_doc(id, None).await.map_err(|e| {
            pacgate_core::PacgateError::StorageError(e.to_string())
        })?;

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("read failed: {}", e))
        })?;

        // Apply the edit using the DOCX diff engine
        let edit = crate::diff::TrackedEdit::new(
            find,
            replace,
            ctx_before,
            ctx_after,
        );
        let edited = crate::diff::apply_tracked_edit(&content, &edit)
            .map_err(|e| pacgate_core::PacgateError::DocxError(e.to_string()))?;

        // Write as a new version
        let version = doc.version + 1;
        let rel_path = Self::rel_path(
            &doc.tenant_id,
            &doc.matter_id,
            &doc.name,
            version,
            "docx",
        );
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
    async fn replicate(
        &self,
        id: &DocumentId,
        count: u32,
    ) -> pacgate_core::Result<Vec<Document>> {
        if count == 0 || count > 20 {
            return Err(pacgate_core::PacgateError::ValidationError(
                "replicate count must be 1-20".into(),
            ));
        }

        let doc = self.fetch_doc(id, None).await.map_err(|e| {
            pacgate_core::PacgateError::StorageError(e.to_string())
        })?;

        let abs_path = self.abs_path(&doc.storage_path);
        let content = std::fs::read(&abs_path).map_err(|e| {
            pacgate_core::PacgateError::StorageError(format!("read failed: {}", e))
        })?;

        let mut docs = Vec::with_capacity(count as usize);
        for i in 0..count {
            let version = self
                .latest_version(&doc.matter_id, &doc.name)
                .await
                .map_err(|e| pacgate_core::PacgateError::StorageError(e.to_string()))?
                + 1;

            let copy_name = format!("{}_copy_{}", doc.name, i + 1);
            let rel_path = Self::rel_path(
                &doc.tenant_id,
                &doc.matter_id,
                &copy_name,
                version,
                "docx",
            );
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