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
}

impl From<sqlx::Error> for TenantError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => TenantError::MatterNotFound("row not found".into()),
            other => TenantError::Database(other.to_string()),
        }
    }
}

impl From<pacgate_core::PacgateError> for TenantError {
    fn from(e: pacgate_core::PacgateError) -> Self {
        TenantError::Validation(e.to_string())
    }
}