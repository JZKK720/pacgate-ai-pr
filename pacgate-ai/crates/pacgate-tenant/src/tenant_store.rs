//! TenantStore and MatterStore — Postgres-backed CRUD for tenants and matters.

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
}

impl MatterStore {
    pub fn new(db: PgPool) -> Self {
        Self { db }
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

    #[instrument(skip(self), fields(tenant_id = %tenant_id.as_str(), matter_id = %matter_id.as_str()))]
    pub async fn delete(
        &self,
        tenant_id: &TenantId,
        matter_id: &MatterId,
    ) -> Result<(), TenantError> {
        let result = sqlx::query("DELETE FROM matters WHERE id = $1 AND tenant_id = $2")
            .bind(matter_id.0)
            .bind(tenant_id.0)
            .execute(&self.db)
            .await?;

        if result.rows_affected() == 0 {
            return Err(TenantError::MatterNotFound(matter_id.as_str()));
        }
        Ok(())
    }
}
