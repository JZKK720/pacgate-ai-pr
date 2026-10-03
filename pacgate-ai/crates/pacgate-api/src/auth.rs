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
    pub soul_id:    Option<String>,
    pub expires_in: u64,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    #[serde(rename = "tenant_id")]
    pub _tenant_id:  Option<String>,
    pub email:       String,
    pub password:    String,
    #[serde(rename = "role")]
    pub _role:       Option<String>,
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
    pub system_role: String,    pub soul_id:     Option<String>,}

/// POST /api/auth/login — authenticate and receive JWT
pub async fn login(
    State(state): State<AppState>,
    Json(req):    Json<LoginRequest>,
) -> Result<Json<LoginResponse>, ApiError> {
    let (token, user_id, tenant_id, role, soul_id) = state
        .auth
        .login(&req.email, &req.password)
        .await
        .map_err(|e| ApiError::unauthorized(e.to_string()))?;

    Ok(Json(LoginResponse {
        token,
        user_id: user_id.as_str(),
        tenant_id: tenant_id.as_str(),
        role,
        soul_id,
        expires_in: 86400,
    }))
}

/// POST /api/auth/register — create a new user within the configured default tenant
///
/// Pacgate: self-registration may create **the first account only**.
///
/// WHY. This route previously had no auth extractor and no gate, so any host that
/// could reach the API created a working `attorney` account in the default tenant,
/// and `GET /api/matters` then returned that tenant's matter list. The AIPC
/// publishes nginx on 0.0.0.0:8089 and the user manual tells attorneys to browse to
/// the machine's LAN IP, so "reachable" meant "anyone on the client's network",
/// against client-identifying matter data. Found 2026-10-01; see
/// deploy/DEFECT-pacgate-api-open-registration.md.
///
/// WHY FIRST-USER-ONLY RATHER THAN A CONFIG FLAG. The install path genuinely needs
/// this route: `install.ps1` step 6a creates the first admin with it, and without
/// an admin a fresh install has no login, matter provisioning fails, and
/// deer-flow silently falls back to writing UNSANITIZED memory to disk. A
/// configuration flag makes an operator choose between "installable" and "safe",
/// and the failure mode of choosing wrong is a permanently open door on a
/// legal-matter system.
///
/// The two needs are separable: the installer wants ONE account, the attacker
/// wants ANY number. Allowing exactly one satisfies the first and defeats the
/// second — there is nothing left to claim on a running deployment.
///
/// This is also the shape a reviewer can verify by reading: the guard is a COUNT,
/// not a boolean somebody must remember to set. It mirrors deer-flow's
/// `/initialize`, which gates on `admin_count > 0`.
///
/// The explicit flag is kept as an escape hatch for a deployment that legitimately
/// wants open registration (a demo, or an onboarding window). Closed by default:
/// anything other than an explicit true/1/yes is treated as disabled.
pub async fn register(
    State(state): State<AppState>,
    Json(req):    Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
    // (1) Self-registration is first-user-only unless the deployment explicitly
    //     opts in to open registration.
    if !state.config.allow_registration {
        let existing = state
            .auth
            .count_users()
            .await
            .map_err(|e| ApiError::internal(format!("could not count users: {e}")))?;
        if existing > 0 {
            return Err(ApiError::forbidden(
                "Self-registration is disabled on this deployment: the first \
                 account already exists. An administrator must create further \
                 accounts.",
            ));
        }
        tracing::warn!(
            email = %req.email,
            "bootstrap: creating the FIRST account via the public register route; \
             every later self-registration will be refused"
        );
    }

    let tenant = state
        .tenant_store
        .get_by_slug(&state.config.default_tenant)
        .await
        .map_err(|e| ApiError::internal(format!("default tenant not found: {e}")))?;

    let user_id = state
        .auth
        .register(
            &tenant.id,
            &req.email,
            &req.password,
            "attorney",
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
        soul_id:     claims.soul_id,
    }))
}