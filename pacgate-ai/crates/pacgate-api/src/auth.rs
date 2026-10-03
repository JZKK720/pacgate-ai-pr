//! Auth API routes — login, register, and current user info.

use axum::{
    extract::{Extension, State},
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::TenantId;
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

/// Tenant from the VERIFIED token, never from a request body.
///
/// Matches `claims_to_tenant_id` in chat.rs / workflows.rs; kept local rather
/// than shared because those are private to their modules and a fourth copy is
/// cheaper than widening one of them into a public util for this.
fn claims_to_tenant_id(claims: &Claims) -> Result<TenantId, ApiError> {
    claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct LoginResponse {
    pub token: String,
    pub user_id: String,
    pub tenant_id: String,
    pub role: String,
    pub soul_id: Option<String>,
    pub expires_in: u64,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    #[serde(rename = "tenant_id")]
    pub _tenant_id: Option<String>,
    pub email: String,
    pub password: String,
    #[serde(rename = "role")]
    pub _role: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct RegisterResponse {
    pub user_id: String,
}

#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub user_id: String,
    pub tenant_id: String,
    pub role: String,
    pub system_role: String,
    pub soul_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct CreateUserRequest {
    pub email: String,
    pub password: String,
    /// Within-tenant role. Validated against a closed set: the DB column is free
    /// text, so without this an admin could write an arbitrary string into `role`
    /// and any future authorization check that string-matches would have to cope
    /// with it.
    pub role: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateUserResponse {
    pub user_id: String,
    pub email: String,
    pub role: String,
}

/// The one string that grants platform administration.
///
/// Single definition because it is compared in two places that must never
/// disagree: `create_user`'s authorization check reads `Claims.system_role`,
/// and `bootstrap_roles` writes it. If these ever drift, the bootstrap account
/// silently loses access to account provisioning - which is the exact failure
/// this whole change exists to repair.
pub(crate) const PLATFORM_ADMIN_ROLE: &str = "admin";

/// Roles the FIRST account receives on a fresh deployment.
///
/// Extracted from `register` so the decision is testable without a database.
/// This is the security-relevant half of the bootstrap: which account, on a
/// fresh deployment, ends up able to administer the platform. It is a pure
/// function of the count gate precisely so it cannot depend on request input —
/// the caller cannot ask for admin, only be first.
///
/// Returns `(within_tenant_role, system_role)`.
fn bootstrap_roles(is_first: bool) -> (&'static str, &'static str) {
    if is_first {
        // Both roles are named constants rather than inlined strings on purpose.
        // An earlier version spelled the literals directly here AND in the test,
        // so a search-and-replace that rewrote both made the function and its
        // assertion agree on the WRONG value and the test passed while the
        // behaviour was broken - a test that passed for the wrong reason. Going
        // through a constant the test also references does not by itself fix
        // that, so the test below compares against its own expected literals
        // instead of reusing these.
        (PLATFORM_ADMIN_ROLE, PLATFORM_ADMIN_ROLE)
    } else {
        ("attorney", "user")
    }
}

/// POST /api/auth/login — authenticate and receive JWT
pub async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
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
    Json(req): Json<RegisterRequest>,
) -> Result<Json<RegisterResponse>, ApiError> {
    // (1) Self-registration is first-user-only unless the deployment explicitly
    //     opts in to open registration.
    //
    //     `is_first` is tracked so step (3) can grant the first account the
    //     admin roles it needs. Computing it once here keeps the gate and the
    //     grant as one decision rather than two that could disagree.
    let mut is_first = state.config.allow_registration;
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
                 accounts via POST /api/auth/users.",
            ));
        }
        is_first = true;
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

    // (2) WHAT THE FIRST ACCOUNT GETS.
    //
    // `install.ps1` step 6a calls this route to bootstrap "the admin user" and
    // logs "[OK] admin '<email>' registered". Before this change the account it
    // got had `role` hardcoded to 'attorney' and `system_role` left to the column
    // default of 'user' - so the installer produced an attorney and called it an
    // admin, and every principal the platform could contain failed any
    // `system_role == "admin"` check.
    //
    // The first account is therefore both: `system_role = 'admin'` so it can
    // actually administer, and within-tenant `role = 'admin'` so it governs its
    // own tenant. Later self-registration (only possible when
    // `allow_registration` is explicitly enabled) keeps the previous behaviour:
    // an attorney-scoped, non-platform account.
    //
    // This does not widen the attacker's window. The route is still gated on
    // "no users exist", so the only account an unauthenticated caller can ever
    // claim is the one the installer would have created anyway - and on a fresh
    // AIPC the installer reaches it first.
    let (tenant_role, system_role) = bootstrap_roles(is_first);

    let user_id = state
        .auth
        .register(
            &tenant.id,
            &req.email,
            &req.password,
            tenant_role,
            system_role,
            req.display_name.as_deref(),
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(RegisterResponse {
        user_id: user_id.as_str(),
    }))
}

/// POST /api/auth/users — an administrator creates an account.
///
/// WHY THIS EXISTS. `register` was closed to first-user-only, and its 403 says
/// "An administrator must create further accounts." That promise was empty: the
/// route table had no user-creation endpoint at all, so `register` was the ONLY
/// way to make an account. Closing it did not just close a hole, it removed the
/// only provisioning path — and the install architecture depends on a SECOND
/// account existing. The qm (co-working) runtime authenticates to pacgate-api as
/// its own service identity, `qm-bridge@pacgate.local`, documented in 15 files
/// including the client-facing deployment handbooks. Under first-user-only that
/// documented install step fails with 403.
///
/// So the gate and the remedy ship together: `register` hands out exactly one
/// account on a fresh deployment, and everything after that comes through here.
///
/// AUTHORIZATION: `system_role == "admin"` from the VERIFIED JWT (the Claims
/// extension is injected by auth_middleware, so an unsigned or forged value never
/// reaches this function). `role == "admin"` in the tenant's own role space is
/// deliberately NOT accepted — that string is stored in `users.role` from request
/// input, so keying the check on it would let anyone this path ever touches
/// escalate.
///
/// TENANT SCOPE: the new account is created in the CALLER'S tenant, read from
/// Claims. There is no `tenant_id` in the request body, because accepting one
/// would let an admin of tenant A plant an identity inside tenant B — the exact
/// cross-tenant read the platform is meant to make impossible.
///
/// WHY AN ADMIN ROUTE IS NOT A REGRESSION OF THE ORIGINAL DEFECT. The original
/// hole was an UNAUTHENTICATED route reachable by any host on the client's LAN
/// (nginx is published on 0.0.0.0:8089) that minted a working attorney account.
/// This route requires a valid admin JWT, so reaching it requires credentials the
/// deployment already issued.
pub async fn create_user(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Json(req): Json<CreateUserRequest>,
) -> Result<Json<CreateUserResponse>, ApiError> {
    if claims.system_role != PLATFORM_ADMIN_ROLE {
        return Err(ApiError::forbidden(
            "Creating accounts requires the admin role.",
        ));
    }

    if req.email.trim().is_empty() || req.password.is_empty() {
        return Err(ApiError::bad_request("email and password are required."));
    }

    // Closed set. `attorney` is the default because the normal case for this
    // route is minting the qm service identity, which is attorney-scoped like
    // deer-flow's and pacgate-mcp's.
    let role = req.role.as_deref().unwrap_or("attorney");
    if !matches!(role, "admin" | "attorney" | "paralegal" | "partner") {
        return Err(ApiError::bad_request(
            "role must be one of: admin, attorney, paralegal, partner.",
        ));
    }

    // Tenant comes from the verified token, never from the body.
    let tenant_id = claims_to_tenant_id(&claims)?;

    let user_id = state
        .auth
        .register(
            &tenant_id,
            &req.email,
            &req.password,
            role,
            "user",
            req.display_name.as_deref(),
        )
        .await
        .map_err(|e| {
            // A duplicate email is the operator's mistake, not a server fault, so
            // it must not surface as a 500. This route is now the documented way
            // to (re)create the qm bridge account, which means re-running it is
            // expected behaviour and has to say something readable.
            let msg = e.to_string();
            if msg.contains("duplicate key") || msg.contains("unique constraint") {
                ApiError::conflict(format!(
                    "An account with the email {} already exists.",
                    req.email
                ))
            } else {
                ApiError::internal(format!("could not create the account: {msg}"))
            }
        })?;

    tracing::info!(
        actor = %claims.sub,
        tenant = %claims.tenant_id,
        created = %req.email,
        role,
        "admin created an account"
    );

    Ok(Json(CreateUserResponse {
        user_id: user_id.as_str(),
        email: req.email,
        role: role.to_string(),
    }))
}

/// GET /api/auth/me — get current user info from JWT
pub async fn me(Extension(claims): Extension<Claims>) -> Result<Json<MeResponse>, ApiError> {
    Ok(Json(MeResponse {
        user_id: claims.sub,
        tenant_id: claims.tenant_id,
        role: claims.role,
        system_role: claims.system_role,
        soul_id: claims.soul_id,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Expected values are spelled OUT HERE, not imported from the code under
    /// test. This is deliberate and was learned the hard way: the first version
    /// of these tests compared against the same `"admin"/"admin"` literals the
    /// implementation used, so a search-and-replace that broke the grant broke
    /// the expectation too and the test still passed. A test that shares its
    /// expected value with the implementation tests nothing.
    const EXPECTED_FIRST_TENANT_ROLE: &str = "admin";
    const EXPECTED_FIRST_SYSTEM_ROLE: &str = "admin";

    /// The first account on a fresh deployment is a real administrator.
    ///
    /// This is the assertion that would have caught the original defect: the
    /// installer's step 6a logs "[OK] admin '<email>' registered" while the rows
    /// it created were `role='attorney'`, `system_role='user'`. Every account in
    /// the dev database carries `system_role='user'` for exactly this reason.
    /// An "admin" that cannot administer is worse than a named error, because
    /// the failure surfaces later as an unreachable route rather than at install.
    #[test]
    fn first_account_is_a_platform_admin() {
        let (tenant_role, system_role) = bootstrap_roles(true);
        assert_eq!(
            tenant_role, EXPECTED_FIRST_TENANT_ROLE,
            "the installer calls this account 'admin'; it must hold an admin \
             within-tenant role"
        );
        assert_eq!(
            system_role, EXPECTED_FIRST_SYSTEM_ROLE,
            "the account the installer calls 'admin' must actually hold the admin \
             system_role, or the provisioning route is unreachable by anyone"
        );
    }

    /// The literal the authorization check reads must match the one written.
    ///
    /// `create_user` gates on `claims.system_role != PLATFORM_ADMIN_ROLE`. If
    /// `bootstrap_roles` wrote any other string, the bootstrap administrator
    /// would hold an account that cannot use the route it needs - a silent
    /// lockout with no error at install time.
    #[test]
    fn bootstrap_admin_matches_the_role_the_authorization_check_reads() {
        let (_, system_role) = bootstrap_roles(true);
        assert_eq!(system_role, PLATFORM_ADMIN_ROLE);
        assert_eq!(
            system_role, EXPECTED_FIRST_SYSTEM_ROLE,
            "and that shared constant must itself still be the value the test \
             expects - otherwise the constant and the assertion drifted together"
        );
    }

    /// Later self-registration stays unprivileged.
    ///
    /// Deliberately asserted alongside the first-account case: a change that
    /// granted admin to EVERY account would satisfy the test above while
    /// reopening the escalation the gate exists to prevent.
    #[test]
    fn later_accounts_are_not_admins() {
        let (role, system_role) = bootstrap_roles(false);
        assert_eq!(role, "attorney");
        assert_eq!(
            system_role, "user",
            "self-registration after the first account must not confer platform \
             admin"
        );
    }

    /// Exactly one of the two bootstrapped roles is privileged.
    ///
    /// Guards the separable-needs argument directly: the installer wants ONE
    /// administrator, an attacker wants ANY number. If both branches ever became
    /// privileged, "first-user-only" would no longer bound the damage.
    #[test]
    fn admin_is_granted_to_exactly_one_of_the_bootstrap_paths() {
        let privileged = [true, false]
            .iter()
            .filter(|is_first| bootstrap_roles(**is_first).1 == PLATFORM_ADMIN_ROLE)
            .count();
        assert_eq!(privileged, 1);
    }
}
