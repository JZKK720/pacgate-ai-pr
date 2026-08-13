use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("document not found: {0}")]
    DocumentNotFound(String),

    #[error("database error: {0}")]
    Database(String),

    #[error("IO error: {0}")]
    Io(String),

    #[error("DOCX error: {0}")]
    Docx(String),
}

impl From<sqlx::Error> for StoreError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => StoreError::DocumentNotFound("row not found".into()),
            other => StoreError::Database(other.to_string()),
        }
    }
}