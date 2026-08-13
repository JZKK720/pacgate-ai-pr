//! pacgate-tenant — Tenant and matter storage backed by Postgres.
//!
//! Provides `TenantStore` and `MatterStore` for CRUD operations on tenants
//! and matters. All queries are scoped by `tenant_id` to enforce isolation.
//!
//! File layout convention (managed by the caller, typically `FsDocumentStore`):
//!   {DATA_DIR}/tenants/{tenant_id}/matters/{matter_id}/docs/{name}_v{n}.docx

use std::path::PathBuf;

use pacgate_core::{Matter, MatterId, TenantId, UserId};
use sqlx::{PgPool, Row};
use tracing::instrument;
use uuid::Uuid;

pub mod error;
pub mod tenant_store;

pub use error::TenantError;
pub use tenant_store::{MatterStore, TenantStore};

/// Helper: compute the on-disk directory for a tenant.
pub fn tenant_dir(data_dir: &PathBuf, tenant_id: &TenantId) -> PathBuf {
    data_dir.join("tenants").join(tenant_id.as_str())
}

/// Helper: compute the on-disk directory for a matter within a tenant.
pub fn matter_dir(data_dir: &PathBuf, tenant_id: &TenantId, matter_id: &MatterId) -> PathBuf {
    tenant_dir(data_dir, tenant_id)
        .join("matters")
        .join(matter_id.as_str())
}

/// Helper: compute the docs directory for a matter.
pub fn docs_dir(data_dir: &PathBuf, tenant_id: &TenantId, matter_id: &MatterId) -> PathBuf {
    matter_dir(data_dir, tenant_id, matter_id).join("docs")
}

/// Helper: compute the full path for a versioned document file.
pub fn doc_path(
    data_dir: &PathBuf,
    tenant_id: &TenantId,
    matter_id: &MatterId,
    name: &str,
    version: u32,
    format: &str,
) -> PathBuf {
    let ext = match format {
        "docx" => "docx",
        "pdf" => "pdf",
        "txt" => "txt",
        "markdown" => "md",
        _ => "bin",
    };
    docs_dir(data_dir, tenant_id, matter_id).join(format!("{}_v{}.{}", name, version, ext))
}

/// Run the initial SQL migration on the given pool.
/// In production, use `sqlx-cli` or `refinery` for migration management.
/// This is a convenience for dev/test setups.
#[instrument(skip(pool))]
pub async fn run_migrations(pool: &PgPool) -> Result<(), TenantError> {
    let migration_sql = include_str!("../../../migrations/001_initial_schema.sql");
    sqlx::query(migration_sql)
        .execute(pool)
        .await
        .map_err(|e| TenantError::Migration(e.to_string()))?;
    tracing::info!("database migrations applied");
    Ok(())
}

/// Ensure the on-disk directory structure exists for a tenant + matter.
pub fn ensure_dirs(
    data_dir: &PathBuf,
    tenant_id: &TenantId,
    matter_id: &MatterId,
) -> Result<(), TenantError> {
    let docs = docs_dir(data_dir, tenant_id, matter_id);
    std::fs::create_dir_all(&docs)
        .map_err(|e| TenantError::Io(e.to_string()))?;
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────────────
// Row → Domain type conversions
// ─────────────────────────────────────────────────────────────────────────────

fn row_to_matter(row: &sqlx::postgres::PgRow) -> Matter {
    Matter {
        id: MatterId(row.get::<Uuid, _>("id")),
        tenant_id: TenantId(row.get::<Uuid, _>("tenant_id")),
        name: row.get("name"),
        description: row.get("description"),
        persona_id: row.get::<Option<Uuid>, _>("persona_id").map(|u| pacgate_core::PersonaId(u)),
        created_by: UserId(row.get::<Uuid, _>("created_by")),
        created_at: row.get("created_at"),
        updated_at: row.get("updated_at"),
    }
}