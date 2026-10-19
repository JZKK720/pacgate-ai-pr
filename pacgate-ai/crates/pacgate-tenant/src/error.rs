use thiserror::Error;

#[derive(Debug, Error)]
pub enum TenantError {
    #[error("tenant not found: {0}")]
    TenantNotFound(String),

    #[error("matter not found: {0}")]
    MatterNotFound(String),

    #[error("database error: {0}")]
    Database(String),

    #[error("migration error: {0}")]
    Migration(String),

    #[error("IO error: {0}")]
    Io(String),

    #[error("validation error: {0}")]
    Validation(String),

    /// A matter in this tenant already owns that external key.
    ///
    /// Distinct from `Database` on purpose: the partial unique index
    /// `idx_matters_tenant_external_key` is a USER mistake (two matters claiming
    /// one identity), not a server fault, so the API must answer 409 rather than
    /// 500. Without this variant a duplicate key looked like a broken database.
    #[error("external key already in use: {0}")]
    ExternalKeyConflict(String),
}

impl From<sqlx::Error> for TenantError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => TenantError::MatterNotFound("row not found".into()),
            // The partial unique index idx_matters_tenant_external_key enforces
            // (tenant_id, external_key) WHERE external_key IS NOT NULL. Without
            // this arm the caller sees a generic database error and the API
            // answers 500, which reads as "the server is broken" rather than
            // "that key is taken".
            sqlx::Error::Database(ref db)
                if db.constraint() == Some("idx_matters_tenant_external_key") =>
            {
                TenantError::ExternalKeyConflict("external_key already used in this tenant".into())
            }
            other => TenantError::Database(other.to_string()),
        }
    }
}

impl From<pacgate_core::PacgateError> for TenantError {
    fn from(e: pacgate_core::PacgateError) -> Self {
        TenantError::Validation(e.to_string())
    }
}