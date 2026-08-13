use thiserror::Error;

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("invalid token: {0}")]
    InvalidToken(String),

    #[error("authentication failed: {0}")]
    AuthenticationFailed(String),

    #[error("password hashing error: {0}")]
    PasswordHash(String),

    #[error("validation error: {0}")]
    Validation(String),

    #[error("database error: {0}")]
    Database(String),
}

impl From<sqlx::Error> for AuthError {
    fn from(e: sqlx::Error) -> Self {
        AuthError::Database(e.to_string())
    }
}