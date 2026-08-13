//! Axum middleware for JWT authentication.
//!
//! Extracts the `Authorization: Bearer <token>` header, verifies the JWT,
//! and injects `Claims` into request extensions for downstream handlers.

use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::Next,
    response::Response,
};
use tracing::debug;

use crate::{resolve_soul, AuthService, Claims};

/// Auth middleware — verifies JWT and injects Claims into request extensions.
///
/// Skips auth for health check and auth endpoints (login/register).
pub async fn auth_middleware(
    State(auth): State<AuthService>,
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

/// SOUL resolver middleware — runs after `auth_middleware`.
///
/// Reads `Claims` from request extensions (injected by `auth_middleware`),
/// resolves the `soul_id` to a `SoulPersona` via `pacgate_persona::get_soul()`,
/// and injects the resolved `SoulPersona` into request extensions.
///
/// If no `Claims` are present (unauthenticated route), the middleware passes through.
/// If `soul_id` is `None` or unresolvable, the middleware passes through without
/// injecting a `SoulPersona` — downstream handlers treat `None` as "default identity".
pub async fn soul_resolver_middleware(
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    // Try to get Claims from extensions (injected by auth_middleware)
    let soul = request.extensions().get::<Claims>()
        .and_then(|claims| resolve_soul(claims));

    if let Some(ref s) = soul {
        debug!(
            "soul resolver: resolved soul_id={} -> persona={}",
            request.extensions().get::<Claims>()
                .and_then(|c| c.soul_id.as_deref())
                .unwrap_or("none"),
            s.name
        );
    }

    // Always inject Option<SoulPersona> so downstream Extension extractors work.
    // None means "no SOUL bound to this user" — handlers use default agent behavior.
    let mut request = request;
    request.extensions_mut().insert(soul);
    Ok(next.run(request).await)
}
