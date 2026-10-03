//! Auth API routes — login, register, and current user info.

use axum::{
    extract::{Extension, State},
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::TenantId;
use serde::{Deserialize, Serialize};

use crate::{error::ApiError, state::AppState};

/// The only roles an administrator may assign.
///
/// A closed set because the `users.role` column is free text AND load-bearing:
/// `sanitize.rs` reads it as an ACL (`role_may_restore` accepts `admin|partner`),
/// so an arbitrary string written here would sit in an authorization decision.
///
/// `partner` is deliberately ABSENT. It is the broader of the two restore-capable
/// roles, and nothing in the deployment needs it through this route: the only
/// documented consumer is the qm bridge, which is attorney-scoped, and a firm's
/// partner accounts are a business decision an operator makes directly rather
/// than something a service-provisioning endpoint should hand out. `admin` IS
/// included because a tenant may legitimately have several administrators, and
/// it is a tenant scope - not the platform role that gates this very route.
const ASSIGNABLE_ROLES: [&str; 3] = ["admin", "attorney", "paralegal"];

/// The default role for a created account.
///
/// `attorney` because the normal case for this route is minting the qm service
/// identity, which is attorney-scoped like deer-flow's and pacgate-mcp's.
const DEFAULT_CREATED_ROLE: &str = "attorney";

/// Validate the role an administrator asked to assign.
///
/// Split out from the handler so the rule is testable without a database or a
/// running server - the handler cannot be exercised until 0.1.22 is deployed,
/// and an untested authorization boundary is exactly the kind that ships broken.
fn resolve_assignable_role(requested: Option<&str>) -> Result<&'static str, ApiError> {
    let role = requested.unwrap_or(DEFAULT_CREATED_ROLE);
    ASSIGNABLE_ROLES
        .iter()
        .find(|allowed| **allowed == role)
        .copied()
        .ok_or_else(|| {
            ApiError::bad_request(format!(
                "role must be one of: {}.",
                ASSIGNABLE_ROLES.join(", ")
            ))
        })
}

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
        // Reuses `create_user`'s default rather than spelling "attorney" again,
        // so the two provisioning paths cannot disagree about what a non-first
        // account is. Previously these were independent literals and a change to
        // one would have silently left the other behind.
        (DEFAULT_CREATED_ROLE, "user")
    }
}

/// What the public register route should do for a caller, given the state.
///
/// A named enum rather than loose booleans so the three outcomes cannot be
/// conflated - the original defect was precisely a conflation, where "open
/// registration is enabled" was read as "this caller is the first user".
#[derive(Debug, PartialEq, Eq)]
enum RegistrationDecision {
    /// No users exist: create the account, and grant it the bootstrap admin roles.
    CreateFirstAccount,
    /// Users exist and open registration is enabled: create it WITHOUT admin.
    CreateNonFirstAccount,
    /// Users exist and registration is closed: refuse.
    Refuse,
}

/// Decide whether a self-registration is the bootstrap, an ordinary open
/// registration, or a refusal.
///
/// `existing_users` MUST be the observed count, never a configuration flag, and
/// `allow_registration` MUST NOT be able to make a non-first caller look first.
/// That is the whole point of extracting this: the first implementation derived
/// `is_first` from `allow_registration`, so with the escape hatch enabled every
/// anonymous registrant was treated as the first user and received
/// `admin`/`admin`. A documented demo switch became a mass platform-admin grant,
/// and because the logic lived inside an async handler nothing caught it.
///
/// Invariants this function exists to hold:
///   * `CreateFirstAccount` is returned ONLY when no users exist. Turning
///     `allow_registration` on can never produce it for a later caller.
///   * `allow_registration` only ever converts `Refuse` into
///     `CreateNonFirstAccount`. It cannot escalate privilege.
fn registration_decision(existing_users: i64, allow_registration: bool) -> RegistrationDecision {
    if existing_users == 0 {
        RegistrationDecision::CreateFirstAccount
    }
    else if allow_registration {
        RegistrationDecision::CreateNonFirstAccount
    }
    else {
        RegistrationDecision::Refuse
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
    //     `is_first` is derived from the OBSERVED user count, never from the
    //     flag. This distinction is load-bearing and was got wrong once already:
    //     deriving it from `allow_registration` made the escape hatch grant
    //     `admin`/`admin` to EVERY anonymous registrant, because the flag is true
    //     for every caller. The flag answers "may anyone register"; only the
    //     count answers "is this the first account". Conflating them turned a
    //     documented demo switch into a mass platform-admin grant.
    //
    //     Counting unconditionally also removes an asymmetry: previously the
    //     count was only consulted when registration was closed, so the open
    //     path never verified the "first user" premise it then acted on.
    let existing = state
        .auth
        .count_users()
        .await
        .map_err(|e| ApiError::internal(format!("could not count users: {e}")))?;

    let decision = registration_decision(existing, state.config.allow_registration);

    if decision == RegistrationDecision::Refuse {
        return Err(ApiError::forbidden(
            "Self-registration is disabled on this deployment: the first \
             account already exists. An administrator must create further \
             accounts via POST /api/auth/users.",
        ));
    }

    let is_first = decision == RegistrationDecision::CreateFirstAccount;

    let is_first = existing == 0;
    if is_first {
        tracing::warn!(
            email = %req.email,
            "bootstrap: creating the FIRST account via the public register route; \
             every later self-registration will be refused"
        );
    }
    else {
        tracing::info!(
            email = %req.email,
            "open registration is enabled; creating a NON-FIRST account, which \
             does not receive platform admin"
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
    // own tenant. Every LATER account - whether permitted by the open-registration
    // flag or created by an administrator - is attorney-scoped and non-platform.
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

    // Closed set, validated by a function that is unit-tested below.
    let role = resolve_assignable_role(req.role.as_deref())?;

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
            //
            // Matches the TYPED variant, never the message text. The first version
            // of this looked for `"duplicate key"` / `"unique constraint"` in the
            // error string - which is the SERVER's localized text, so a deployment
            // with a non-English `lc_messages` (or a different Postgres major)
            // would have reported an operator's typo as a 500. AuthError::from_sqlx
            // classifies on SQLSTATE 23505, which no locale changes.
            match e {
                pacgate_auth::AuthError::Duplicate(_) => ApiError::conflict(format!(
                    "An account with the email {} already exists.",
                    req.email
                )),
                other => ApiError::internal(format!("could not create the account: {other}")),
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

    // ── register's gate ──
    //
    // These exist because the M1 defect lived inside the async handler where no
    // test could reach it, and it was found by an external review rather than by
    // the suite.

    #[test]
    fn the_first_account_is_created_even_when_registration_is_closed() {
        // The installer's bootstrap path. Must not depend on the flag.
        assert_eq!(
            registration_decision(0, false),
            RegistrationDecision::CreateFirstAccount
        );
    }

    #[test]
    fn open_registration_does_not_make_a_later_caller_the_first_user() {
        // THE M1 REGRESSION TEST. With the flag on and users already present, the
        // decision must be CreateNonFirstAccount - never CreateFirstAccount, which
        // is what would hand out admin/admin to every anonymous registrant.
        for existing in [1, 2, 100] {
            assert_eq!(
                registration_decision(existing, true),
                RegistrationDecision::CreateNonFirstAccount,
                "with {existing} existing user(s) and open registration, the caller \
                 is NOT the first user and must not be granted bootstrap admin"
            );
        }
    }

    #[test]
    fn closing_registration_refuses_only_once_a_user_exists() {
        assert_eq!(registration_decision(0, false), RegistrationDecision::CreateFirstAccount);
        assert_eq!(registration_decision(1, false), RegistrationDecision::Refuse);
    }

    #[test]
    fn the_flag_can_only_relax_refusal_and_never_grant_the_bootstrap() {
        // Enumerate the whole input space. The property: CreateFirstAccount
        // appears for exactly the zero-user cases, and toggling the flag with
        // users present can only turn Refuse into CreateNonFirstAccount.
        let mut first_account_cases = 0;
        for existing in [0, 1, 5] {
            for allow in [true, false] {
                let d = registration_decision(existing, allow);
                if d == RegistrationDecision::CreateFirstAccount {
                    first_account_cases += 1;
                    assert_eq!(existing, 0, "bootstrap admin granted with users present");
                }
            }
            if existing > 0 {
                assert_eq!(registration_decision(existing, true), RegistrationDecision::CreateNonFirstAccount);
                assert_eq!(registration_decision(existing, false), RegistrationDecision::Refuse);
            }
        }
        assert_eq!(first_account_cases, 2, "only the two zero-user cases are bootstrap");
    }

    // ── create_user's role handling ──
    //
    // These run without a database, which matters because the route itself
    // cannot be exercised until 0.1.22 is deployed. An authorization boundary
    // that shipped untested because "we'll verify it live" is how the original
    // open-registration defect got in.

    #[test]
    fn omitting_the_role_defaults_to_the_least_privileged_service_role() {
        assert_eq!(
            resolve_assignable_role(None).unwrap(),
            "attorney",
            "the default must not be admin - the common case is a service \
             account, and a defaulted admin is a privilege escalation by \
             omission"
        );
    }

    #[test]
    fn every_documented_role_is_accepted() {
        for role in ["admin", "attorney", "paralegal"] {
            assert_eq!(
                resolve_assignable_role(Some(role)).unwrap(),
                role,
                "{role} is part of the documented set"
            );
        }
    }

    #[test]
    fn restore_capable_partner_role_cannot_be_minted_through_this_route() {
        // `sanitize.rs`'s role_may_restore accepts admin|partner, so `partner` is
        // an authorization-bearing value. It is excluded from this route on
        // purpose: nothing here needs it, and the narrowest set that serves the
        // documented consumer (the attorney-scoped qm bridge) is the safest one.
        // Asserted explicitly so a future widening has to delete a named test.
        let err = resolve_assignable_role(Some("partner")).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::BAD_REQUEST);
    }

    #[test]
    fn an_arbitrary_role_is_rejected() {
        // The column is free text, so this is the guard that keeps it from
        // becoming a privilege sink.
        let err = resolve_assignable_role(Some("superuser")).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::BAD_REQUEST);
    }

    #[test]
    fn role_matching_is_exact_not_case_or_prefix_insensitive() {
        // "Admin", " admin", and "administrator" must not sneak through a
        // case-insensitive or prefix comparison. PowerShell's -match/-replace
        // being case-insensitive has already caused one bug in this codebase;
        // role comparisons are the same class of trap.
        for attempt in ["Admin", "ADMIN", " admin", "admin ", "administrator", "adm"] {
            assert!(
                resolve_assignable_role(Some(attempt)).is_err(),
                "{attempt:?} must not be accepted as a role"
            );
        }
    }
}
