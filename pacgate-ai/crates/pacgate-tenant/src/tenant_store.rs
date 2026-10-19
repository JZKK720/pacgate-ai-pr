//! TenantStore and MatterStore — Postgres-backed CRUD for tenants and matters.

use std::path::PathBuf;

use pacgate_core::{Matter, MatterId, TenantId, UserId};
use sqlx::{PgPool, Row};
use tracing::instrument;
use uuid::Uuid;

use crate::error::TenantError;
use crate::row_to_matter;

// ─────────────────────────────────────────────────────────────────────────────
// TenantStore
// ─────────────────────────────────────────────────────────────────────────────

pub struct TenantStore {
    db: PgPool,
}

impl TenantStore {
    pub fn new(db: PgPool) -> Self {
        Self { db }
    }

    #[instrument(skip(self), fields(name = %name))]
    pub async fn create(
        &self,
        name: &str,
        slug: &str,
    ) -> Result<pacgate_core::Tenant, TenantError> {
        let row = sqlx::query(
            "INSERT INTO tenants (name, slug) VALUES ($1, $2) RETURNING id, name, slug, config_json, created_at, updated_at",
        )
        .bind(name)
        .bind(slug)
        .fetch_one(&self.db)
        .await?;

        Ok(pacgate_core::Tenant {
            id: TenantId(row.get::<Uuid, _>("id")),
            name: row.get("name"),
            slug: row.get("slug"),
            config: serde_json::from_value(row.get("config_json")).unwrap_or_default(),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        })
    }

    #[instrument(skip(self), fields(tenant_id = %id.as_str()))]
    pub async fn get(&self, id: &TenantId) -> Result<pacgate_core::Tenant, TenantError> {
        let row = sqlx::query(
            "SELECT id, name, slug, config_json, created_at, updated_at FROM tenants WHERE id = $1",
        )
        .bind(id.0)
        .fetch_one(&self.db)
        .await?;

        Ok(pacgate_core::Tenant {
            id: TenantId(row.get::<Uuid, _>("id")),
            name: row.get("name"),
            slug: row.get("slug"),
            config: serde_json::from_value(row.get("config_json")).unwrap_or_default(),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        })
    }

    #[instrument(skip(self), fields(slug = %slug))]
    pub async fn get_by_slug(&self, slug: &str) -> Result<pacgate_core::Tenant, TenantError> {
        let row = sqlx::query(
            "SELECT id, name, slug, config_json, created_at, updated_at FROM tenants WHERE slug = $1",
        )
        .bind(slug)
        .fetch_one(&self.db)
        .await?;

        Ok(pacgate_core::Tenant {
            id: TenantId(row.get::<Uuid, _>("id")),
            name: row.get("name"),
            slug: row.get("slug"),
            config: serde_json::from_value(row.get("config_json")).unwrap_or_default(),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        })
    }

    pub async fn list(&self) -> Result<Vec<pacgate_core::Tenant>, TenantError> {
        let rows = sqlx::query(
            "SELECT id, name, slug, config_json, created_at, updated_at FROM tenants ORDER BY created_at DESC",
        )
        .fetch_all(&self.db)
        .await?;

        Ok(rows
            .into_iter()
            .map(|row| pacgate_core::Tenant {
                id: TenantId(row.get::<Uuid, _>("id")),
                name: row.get("name"),
                slug: row.get("slug"),
                config: serde_json::from_value(row.get("config_json")).unwrap_or_default(),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            })
            .collect())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MatterStore
// ─────────────────────────────────────────────────────────────────────────────

pub struct MatterStore {
    db: PgPool,
    /// Root directory holding the `tenants/<t>/matters/<m>/` tree. `None` keeps
    /// the store database-only, which is what unit tests that only exercise the
    /// SQL want: they have no filesystem layout to clean up.
    ///
    /// This is needed because deleting a matter has to tear down its directory
    /// too. The `documents` table cascades on `matter_id`, so the DELETE removes
    /// the document ROWS; the files they pointed at are not in the database and
    /// nothing else references them, so without this they survive on disk as
    /// unreachable copies of client documents, inside a directory whose matter
    /// no longer exists. Measured on the dev stack: every matter delete left both
    /// the bytes and the directory behind, which is how the tree reached 26
    /// matter directories against 2 live matters, all 0 files.
    data_dir: Option<PathBuf>,
}

impl MatterStore {
    pub fn new(db: PgPool) -> Self {
        Self { db, data_dir: None }
    }

    /// Same as [`MatterStore::new`], but also able to remove a matter's on-disk
    /// directory when the matter is deleted.
    pub fn with_data_dir(db: PgPool, data_dir: impl Into<PathBuf>) -> Self {
        Self { db, data_dir: Some(data_dir.into()) }
    }

    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str(), name = %name))]
    pub async fn create(
        &self,
        tenant_id: &TenantId,
        name: &str,
        description: Option<&str>,
        external_key: Option<&str>,
        persona_id: Option<&pacgate_core::PersonaId>,
        created_by: &UserId,
    ) -> Result<Matter, TenantError> {
        if name.trim().is_empty() {
            return Err(TenantError::Validation(
                "matter name must not be empty".into(),
            ));
        }

        let row = sqlx::query(
              "INSERT INTO matters (tenant_id, name, description, external_key, persona_id, created_by)
               VALUES ($1, $2, $3, $4, $5, $6)
               RETURNING id, tenant_id, name, description, external_key, persona_id, created_by, created_at, updated_at",
        )
        .bind(tenant_id.0)
        .bind(name)
        .bind(description)
           .bind(external_key)
        .bind(persona_id.map(|p| p.0))
        .bind(created_by.0)
        .fetch_one(&self.db)
        .await?;

        Ok(row_to_matter(&row))
    }

    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str()))]
    pub async fn list(&self, tenant_id: &TenantId) -> Result<Vec<Matter>, TenantError> {
        let rows = sqlx::query(
            "SELECT id, tenant_id, name, description, external_key, persona_id, created_by, created_at, updated_at
             FROM matters WHERE tenant_id = $1 ORDER BY created_at DESC",
        )
        .bind(tenant_id.0)
        .fetch_all(&self.db)
        .await?;

        Ok(rows.iter().map(row_to_matter).collect())
    }

    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str(), matter_id = %matter_id.as_str()))]
    pub async fn get(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
    ) -> Result<Matter, TenantError> {
        let row = sqlx::query(
            "SELECT id, tenant_id, name, description, external_key, persona_id, created_by, created_at, updated_at
             FROM matters WHERE id = $1 AND tenant_id = $2",
        )
        .bind(matter_id.0)
        .bind(tenant_id.0)
        .fetch_one(&self.db)
        .await?;

        Ok(row_to_matter(&row))
    }

    /// Set or clear a matter's external key.
    ///
    /// WHY (2026-10-19). `POST /api/matters` accepts external_key, but no route
    /// could change it afterwards, so a matter created before the column existed
    /// was permanently NULL-keyed. Cross-machine import then had to match on
    /// `name`, which is not unique (50 matters shared one name on the dev box),
    /// so documents could attach to the wrong matter. A write-once identity field
    /// is not an identity field.
    ///
    /// Scoped by tenant in the WHERE clause rather than by a prior read: a matter
    /// belonging to another tenant matches zero rows and reports NotFound, so a
    /// caller cannot probe for ids outside their tenant by watching for a
    /// different error.
    ///
    /// A duplicate key arrives as ExternalKeyConflict (see `From<sqlx::Error>`)
    /// so the API can answer 409 instead of 500.
    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str(), matter_id = %matter_id.as_str()))]
    pub async fn update_external_key(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
        key: Option<&str>,
    ) -> Result<Matter, TenantError> {
        let row = sqlx::query(
            "UPDATE matters SET external_key = $1, updated_at = NOW()
             WHERE id = $2 AND tenant_id = $3
             RETURNING id, tenant_id, name, description, external_key, persona_id, created_by, created_at, updated_at",
        )
        .bind(key)
        .bind(matter_id.0)
        .bind(tenant_id.0)
        .fetch_one(&self.db)
        .await?;

        Ok(row_to_matter(&row))
    }

    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str(), matter_id = %matter_id.as_str()))]
    pub async fn delete(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
    ) -> Result<(), TenantError> {        let result = sqlx::query("DELETE FROM matters WHERE id = $1 AND tenant_id = $2")
            .bind(matter_id.0)
            .bind(tenant_id.0)
            .execute(&self.db)
            .await?;

        if result.rows_affected() == 0 {
            return Err(TenantError::MatterNotFound(matter_id.as_str()));
        }

        // The row is gone, so this matter no longer exists and nothing can write
        // into its directory again: `documents.matter_id` is a foreign key, so an
        // insert naming this matter now fails rather than recreating the tree.
        // That is what makes removing the directory safe *after* the commit, and
        // it is why the order is commit-then-remove rather than remove-then-commit
        // - a failed DELETE must not have already destroyed the bytes.
        if let Some(data_dir) = &self.data_dir {
            let dir = crate::matter_dir(data_dir, tenant_id, matter_id);
            if dir.exists() {
                if let Err(e) = std::fs::remove_dir_all(&dir) {
                    // Deliberately a warning, not an error. The matter row is
                    // already gone, so the request succeeded; failing it here
                    // would report a failure the caller cannot act on and would
                    // invite a retry that now 404s. The residue is an orphan
                    // directory, which is exactly what this cleanup exists to
                    // prevent, so it is worth surfacing loudly in the log.
                    tracing::warn!(
                        matter_id = %matter_id.as_str(),
                        dir = %dir.display(),
                        error = %e,
                        "matter deleted but its directory could not be removed"
                    );
                }
            }
        }
        Ok(())
    }
}
