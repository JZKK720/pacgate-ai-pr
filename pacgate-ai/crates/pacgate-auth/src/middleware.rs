//! Axum middleware for JWT authentication.
//!
//! Extracts the `Authorization: Bearer <token>` header, verifies the JWT,
//! and injects `Claims` into request extensions for downstream handlers.

use axum::{
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::Response,
};
use tracing::debug;

use crate::AuthService;

/// Auth middleware — verifies JWT and injects Claims into request extensions.
///
/// Skips auth for health check and auth endpoints (login/register).
pub async fn auth_middleware(
    auth: AuthService,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let path = request.uri().path();

    // Skip auth for health check and auth endpoints
    if path == "/health" || path == "/api/auth/login" || path == "/api/auth/register" {
        return Ok(next.run(request).await);
    }

    // Extract Authorization header
    let auth_header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok());

    let token = match auth_header.and_then(AuthService::extract_bearer) {
        Some(t) => t,
        None => {
            debug!("auth middleware: no bearer token for {}", path);
            return Err(StatusCode::UNAUTHORIZED);
        }
    };

    // Verify token
    match auth.verify_token(token) {
        Ok(claims) => {
            debug!(
                "auth middleware: verified user={} tenant={} role={}",
                claims.sub, claims.tenant_id, claims.role
            );
            // Inject claims into request extensions
            let mut request = request;
            request.extensions_mut().insert(claims);
            Ok(next.run(request).await)
        }
        Err(e) => {
            debug!("auth middleware: token verification failed: {}", e);
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}