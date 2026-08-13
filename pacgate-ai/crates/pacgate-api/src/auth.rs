//! Auth API routes — login, register, and current user info.

use axum::{
    extract::{Extension, State},
    Json,
};
use pacgate_auth::Claims;
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email:    String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct LoginResponse {
    pub token:      String,
    pub user_id:    String,
    pub tenant_id:  String,
    pub role:       String,
    pub expires_in: u64,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub tenant_id:   String,
    pub email:       String,
    pub password:    String,
    pub role:        String,
    pub display_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct RegisterResponse {
    pub user_id: String,
}

#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub user_id:   String,
    pub tenant_id: String,
    pub role:      String,
    pub system_role: String,
}

/// POST /api/auth/login — authenticate and receive JWT
pub async fn login(
    State(state): State<AppState>,
    Json(req):    Json<LoginRequest>,
) -> Result<Json<LoginResponse>, ApiError> {
    let (token, user_id, tenant_id) = state
        .auth
        .login(&req.email, &req.password)
        .await
        .map_err(|e| ApiError::unauthorized(e.to_string()))?;

    Ok(Json(LoginResponse {
        token,
        user_id: user_id.as_str(),
        tenant_id: tenant_id.as_str(),
        role: "attorney".to_string(), // TODO: get actual role from login
        expires_in: 86400,
    }))
}

/// POST /api/auth/register — create a new user within a tenant
pub async fn register(
    State(state): State<AppState>,
    Json(req):    Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
    let tenant_id: pacgate_core::TenantId = req
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant id: {e}")))?;

    let user_id = state
        .auth
        .register(
            &tenant_id,
            &req.email,
            &req.password,
            &req.role,
            req.display_name.as_deref(),
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(RegisterResponse {
        user_id: user_id.as_str(),
    }))
}

/// GET /api/auth/me — get current user info from JWT
pub async fn me(
    Extension(claims): Extension<Claims>,
) -> Result<Json<MeResponse>, ApiError> {
    Ok(Json(MeResponse {
        user_id:     claims.sub,
        tenant_id:   claims.tenant_id,
        role:        claims.role,
        system_role: claims.system_role,
    }))
}