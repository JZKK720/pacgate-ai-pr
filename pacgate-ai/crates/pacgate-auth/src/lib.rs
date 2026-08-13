//! pacgate-auth — Authentication and authorization for Pacgate-ai.
//!
//! JWT-based auth with per-tenant identity. Implements:
//! - Password hashing (argon2)
//! - JWT token creation and verification
//! - Per-tenant user management via Postgres
//! - Axum middleware for extracting Claims from requests

use chrono::{Duration, Utc};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use pacgate_core::{TenantId, UserId};
use sqlx::{PgPool, Row};
use tracing::instrument;
use uuid::Uuid;

pub mod error;
pub mod middleware;

pub use error::AuthError;
pub use middleware::auth_middleware;

/// JWT claims extracted from a verified token.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Claims {
    /// User ID (UUID string)
    pub sub: String,
    /// Tenant ID (UUID string)
    pub tenant_id: String,
    /// User role within the tenant: admin | attorney | paralegal | partner
    pub role: String,
    /// Platform-level role: admin | user
    pub system_role: String,
    /// Expiration time (Unix timestamp seconds)
    pub exp: usize,
}

/// Authentication service — JWT creation/verification + user management.
pub struct AuthService {
    jwt_secret: String,
    db: PgPool,
}

impl AuthService {
    pub fn new(jwt_secret: impl Into<String>, db: PgPool) -> Self {
        Self {
            jwt_secret: jwt_secret.into(),
            db,
        }
    }

    /// Verify a JWT token and return the claims.
    #[instrument(skip(self, token))]
    pub fn verify_token(&self, token: &str) -> Result<Claims, AuthError> {
        let key = DecodingKey::from_secret(self.jwt_secret.as_bytes());
        let mut validation = Validation::new(Algorithm::HS256);
        validation.validate_exp = true;

        let token_data = decode::<Claims>(token, &key, &validation)
            .map_err(|e| AuthError::InvalidToken(e.to_string()))?;

        Ok(token_data.claims)
    }

    /// Create a JWT token for a user. Token expires in 24 hours.
    #[instrument(skip(self), fields(user_id = %user_id.as_str(), tenant_id = %tenant_id.as_str()))]
    pub fn create_token(
        &self,
        user_id: &UserId,
        tenant_id: &TenantId,
        role: &str,
        system_role: &str,
    ) -> Result<String, AuthError> {
        let exp = (Utc::now() + Duration::hours(24)).timestamp() as usize;

        let claims = Claims {
            sub: user_id.as_str(),
            tenant_id: tenant_id.as_str(),
            role: role.to_string(),
            system_role: system_role.to_string(),
            exp,
        };

        let key = EncodingKey::from_secret(self.jwt_secret.as_bytes());
        let token = encode(&Header::new(Algorithm::HS256), &claims, &key)
            .map_err(|e| AuthError::InvalidToken(e.to_string()))?;

        Ok(token)
    }

    /// Authenticate a user with email + password, return JWT token.
    #[instrument(skip(self, password), fields(email = %email))]
    pub async fn login(
        &self,
        email: &str,
        password: &str,
    ) -> Result<(String, UserId, TenantId), AuthError> {
        let row = sqlx::query(
            "SELECT id, tenant_id, password_hash, role, system_role FROM users WHERE email = $1",
        )
        .bind(email)
        .fetch_one(&self.db)
        .await
        .map_err(|_| AuthError::AuthenticationFailed("invalid email or password".into()))?;

        let user_id = UserId(row.get::<Uuid, _>("id"));
        let tenant_id = TenantId(row.get::<Uuid, _>("tenant_id"));
        let password_hash: Option<String> = row.get("password_hash");
        let role: String = row.get("role");
        let system_role: String = row.get("system_role");

        // Verify password
        let stored_hash = password_hash
            .ok_or_else(|| AuthError::AuthenticationFailed("no password set".into()))?;

        Self::verify_password(password, &stored_hash)?;

        let token = self.create_token(&user_id, &tenant_id, &role, &system_role)?;
        Ok((token, user_id, tenant_id))
    }

    /// Register a new user within a tenant.
    #[instrument(skip(self, password), fields(email = %email, tenant_id = %tenant_id.as_str()))]
    pub async fn register(
        &self,
        tenant_id: &TenantId,
        email: &str,
        password: &str,
        role: &str,
        display_name: Option<&str>,
    ) -> Result<UserId, AuthError> {
        if email.trim().is_empty() || password.is_empty() {
            return Err(AuthError::Validation("email and password required".into()));
        }

        let password_hash = Self::hash_password(password)?;

        let row = sqlx::query(
            "INSERT INTO users (tenant_id, email, password_hash, role, display_name)
             VALUES ($1, $2, $3, $4, $5)
             RETURNING id",
        )
        .bind(tenant_id.0)
        .bind(email)
        .bind(&password_hash)
        .bind(role)
        .bind(display_name)
        .fetch_one(&self.db)
        .await
        .map_err(|e| AuthError::Database(e.to_string()))?;

        Ok(UserId(row.get::<Uuid, _>("id")))
    }

    /// Hash a password using argon2.
    fn hash_password(password: &str) -> Result<String, AuthError> {
        use argon2::{
            password_hash::{rand_core::OsRng, PasswordHasher, SaltString},
            Argon2,
        };

        let salt = SaltString::generate(&mut OsRng);
        let argon2 = Argon2::default();
        let hash = argon2
            .hash_password(password.as_bytes(), &salt)
            .map_err(|e| AuthError::PasswordHash(e.to_string()))?
            .to_string();

        Ok(hash)
    }

    /// Verify a password against a stored argon2 hash.
    fn verify_password(password: &str, stored_hash: &str) -> Result<(), AuthError> {
        use argon2::{
            password_hash::{PasswordHash, PasswordVerifier},
            Argon2,
        };

        let parsed = PasswordHash::new(stored_hash)
            .map_err(|e| AuthError::PasswordHash(e.to_string()))?;

        Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .map_err(|_| AuthError::AuthenticationFailed("invalid email or password".into()))
    }

    /// Extract the bearer token from an Authorization header.
    pub fn extract_bearer(auth_header: &str) -> Option<&str> {
        if auth_header.starts_with("Bearer ") {
            Some(&auth_header[7..])
        } else {
            None
        }
    }
}