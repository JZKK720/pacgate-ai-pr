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

    /// A UNIQUE constraint was violated - e.g. the email is already taken.
    ///
    /// A distinct variant rather than `Database`, because callers must be able
    /// to answer it as a 409 rather than a 500, and the only reliable way to
    /// detect it is the SQLSTATE code. Matching the human-readable message is
    /// not safe: those strings come from the SERVER and are localised by
    /// `lc_messages`, so a deployment with a non-English locale (or a different
    /// Postgres major) would report an operator's duplicate email as a server
    /// error. `create_user` in pacgate-api did exactly that until 2026-10-03.
    #[error("duplicate: {0}")]
    Duplicate(String),

    #[error("database error: {0}")]
    Database(String),
}

/// SQLSTATE for `unique_violation`. Postgres-defined and locale-independent.
const SQLSTATE_UNIQUE_VIOLATION: &str = "23505";

impl AuthError {
    /// Classify a sqlx error, preserving the duplicate case as its own variant.
    ///
    /// Shared by every insert path so the classification cannot drift between
    /// them - two call sites each doing their own `contains("duplicate")` is how
    /// one of them ends up subtly wrong.
    pub fn from_sqlx(e: sqlx::Error) -> Self {
        if let sqlx::Error::Database(db) = &e {
            if db.code().as_deref() == Some(SQLSTATE_UNIQUE_VIOLATION) {
                return AuthError::Duplicate(db.message().to_string());
            }
        }
        AuthError::Database(e.to_string())
    }
}

impl From<sqlx::Error> for AuthError {
    fn from(e: sqlx::Error) -> Self {
        AuthError::from_sqlx(e)
    }
}