"""Authentication endpoints."""

import asyncio
import hmac
import logging
import os
import secrets
import time
from ipaddress import ip_address, ip_network

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel, EmailStr, Field, field_validator

from app.gateway.auth import (
    UserResponse,
    create_access_token,
)
from app.gateway.auth.config import get_auth_config
from app.gateway.auth.errors import AuthErrorCode, AuthErrorResponse
from app.gateway.csrf_middleware import is_secure_request
from app.gateway.deps import get_current_user_from_request, get_local_provider

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


# ── Pacgate: registration gate ────────────────────────────────────────────
#
# WHY: at v2.0.0 `/register` has NO gate. It creates a `user` account for anyone
# who reaches the URL and then sets the session cookie, auto-logging them in.
# `auth/config.py` at this version models only jwt_secret, token_expiry_days and
# GitHub OAuth, so there is no field to turn it off. Upstream added the
# `auth.local.allow_registration` key in 2.1.0 (#4311); this mirrors that KEY NAME
# and its semantics deliberately, so the patch can be deleted at the 2.1.0 upgrade
# rather than becoming permanent drift.
#
# SEMANTICS (identical to upstream, including the default):
#   absent config file      -> ALLOW  (upstream: FileNotFoundError -> True, so a
#                              bare-app/test context that never loads config.yaml
#                              keeps working rather than becoming a hard dependency)
#   key absent              -> ALLOW  (preserves pre-gate behaviour; deployments
#                              opt IN to closing registration)
#   allow_registration false-> REFUSE
#   malformed config        -> ALLOW, but logged loudly. NOTE: this differs from
#                              upstream, which lets a malformed config propagate so
#                              it cannot silently re-open a closed deployment. This
#                              module is mounted read-only into a running container
#                              and a raise here would take the whole auth router
#                              down, so we log an error instead and say so here.
#
# Read fresh per request: get_app_config() reloads when the file content changes,
# so an operator can re-render the config and restart deer-flow without a rebuild.
def _local_registration_enabled() -> bool:
    """Whether visitors may self-register a local account."""
    try:
        from deerflow.config.app_config import get_app_config

        cfg = get_app_config()
        # AppConfig declares ConfigDict(extra="allow"), so an unknown `auth` key
        # survives validation and surfaces as a plain dict. Verified against
        # pydantic 2.12.5: attribute access works, nested access is dict-style.
        auth = getattr(cfg, "auth", None)
        if auth is None:
            return True
        local = auth.get("local") if isinstance(auth, dict) else getattr(auth, "local", None)
        if local is None:
            return True
        value = (
            local.get("allow_registration")
            if isinstance(local, dict)
            else getattr(local, "allow_registration", None)
        )
        if value is None:
            return True
        return bool(value)
    except FileNotFoundError:
        # No config.yaml in this context - same default as upstream.
        return True
    except Exception:
        # Never break the auth router over a config problem. Fail OPEN to preserve
        # current behaviour, but make it visible in the logs.
        logger.error(
            "pacgate: could not read auth.local.allow_registration; "
            "treating self-registration as ENABLED. Fix the config to close it.",
            exc_info=True,
        )
        return True


# ── Pacgate: first-admin bootstrap token ──────────────────────────────────
#
# WHY: `/initialize` creates the FIRST admin and is necessarily PUBLIC — it has
# to work before any account exists. Its only guard was `admin_count > 0`. On an
# already-initialised box that is sufficient (409). On a FRESHLY INSTALLED AIPC
# it is not: no admin exists yet, so whoever reaches the URL first becomes admin.
# Gating `/register` did NOT close this; they are separate endpoints.
#
# WHY NOT reuse auth.local.allow_registration: that key is the REGISTRATION
# policy. Reusing it would make a fresh install un-initialisable (no admin, and
# no way to create one) whenever registration is closed — which is exactly the
# configuration we ship. Bootstrap and registration need separate controls.
#
# DESIGN: OPT-IN, switched by the PACGATE_SETUP_TOKEN environment variable.
#
#   PACGATE_SETUP_TOKEN set   -> /initialize requires it (403 without).
#   PACGATE_SETUP_TOKEN unset -> behaviour is UNCHANGED (public initialize).
#
# WHY OPT-IN RATHER THAN ALWAYS-ON:
# The first-run setup wizard that calls /initialize lives in the UPSTREAM
# frontend, which this repo does not vendor (deploy/frontend-patches/files/ holds
# only 16 overlay files and none of them touch auth). Verified against the built
# image: `grep -rl 'auth/initialize' /app/frontend/.next` DOES match. So a
# frontend that cannot send a token would be unable to create the first admin on
# a fresh install — trading one bootstrap failure for another.
#
# Enabling this properly needs a matching frontend field, i.e. a frontend image
# rebuild. Until then this ships OFF by default, so nothing regresses, and the
# operator can turn it on for a deployment where the wizard is not in use.
#
# HOW TO ENABLE (no image rebuild needed):
#   1. set PACGATE_SETUP_TOKEN in the deer-flow environment, e.g. in .env:
#        PACGATE_SETUP_TOKEN=$(openssl rand -hex 16)
#   2. create the first admin by calling the API directly, passing the token:
#        curl -X POST .../api/v1/auth/initialize \
#          -H 'Content-Type: application/json' \
#          -d '{"email":"...","password":"...","setup_token":"<token>"}'
#      (or send it as the X-Pacgate-Setup-Token header)
#   The token is NEVER returned by /setup-status — exposing it there would hand it
#   to the same anonymous caller it is meant to exclude.
#
# FAIL-CLOSED once enabled: a missing/wrong token is 403. This deliberately
# differs from `_local_registration_enabled`, which fails OPEN on a malformed
# config. Failing open there preserves an existing deployment's behaviour;
# failing open HERE would leave the admin account claimable, which is the bug.
_SETUP_TOKEN_LOGGED: set[str] = set()


def _current_setup_token() -> str | None:
    """The token /initialize requires, or None when the gate is disabled."""
    configured = os.environ.get("PACGATE_SETUP_TOKEN", "").strip()
    if configured:
        return configured

    # No explicit token and the opt-in switch is off -> gate disabled.
    # PACGATE_GENERATE_SETUP_TOKEN=1 generates one and logs it, for an operator
    # who wants the gate without inventing a value themselves. It is a separate
    # switch so that merely having the variable unset never silently arms it.
    if os.environ.get("PACGATE_GENERATE_SETUP_TOKEN", "").strip() not in ("1", "true", "yes"):
        return None

    token = _GENERATED_SETUP_TOKEN
    if token not in _SETUP_TOKEN_LOGGED:
        _SETUP_TOKEN_LOGGED.add(token)
        # warning, not info: this is operator-actionable and must survive a
        # default log level. Printed once per process to avoid log spam.
        logger.warning(
            "PACGATE SETUP TOKEN: %s  -- required by POST /api/v1/auth/initialize "
            "to create the first admin. Read it from the container logs.",
            token,
        )
    return token


_GENERATED_SETUP_TOKEN = secrets.token_urlsafe(24)


# ── Request/Response Models ──────────────────────────────────────────────


class LoginResponse(BaseModel):
    """Response model for login — token only lives in HttpOnly cookie."""

    expires_in: int  # seconds
    needs_setup: bool = False


# Top common-password blocklist. Drawn from the public SecLists "10k worst
# passwords" set, lowercased + length>=8 only (shorter ones already fail
# the min_length check). Kept tight on purpose: this is the **lower bound**
# defense, not a full HIBP / passlib check, and runs in-process per request.
_COMMON_PASSWORDS: frozenset[str] = frozenset(
    {
        "password",
        "password1",
        "password12",
        "password123",
        "password1234",
        "12345678",
        "123456789",
        "1234567890",
        "qwerty12",
        "qwertyui",
        "qwerty123",
        "abc12345",
        "abcd1234",
        "iloveyou",
        "letmein1",
        "welcome1",
        "welcome123",
        "admin123",
        "administrator",
        "passw0rd",
        "p@ssw0rd",
        "monkey12",
        "trustno1",
        "sunshine",
        "princess",
        "football",
        "baseball",
        "superman",
        "batman123",
        "starwars",
        "dragon123",
        "master123",
        "shadow12",
        "michael1",
        "jennifer",
        "computer",
    }
)


def _password_is_common(password: str) -> bool:
    """Case-insensitive blocklist check.

    Lowercases the input so trivial mutations like ``Password`` /
    ``PASSWORD`` are also rejected. Does not normalize digit substitutions
    (``p@ssw0rd`` is included as a literal entry instead) — keeping the
    rule cheap and predictable.
    """
    return password.lower() in _COMMON_PASSWORDS


def _validate_strong_password(value: str) -> str:
    """Pydantic field-validator body shared by Register + ChangePassword.

    Constraint = function, not type-level mixin. The two request models
    have no "is-a" relationship; they only share the password-strength
    rule. Lifting it into a free function lets each model bind it via
    ``@field_validator(field_name)`` without inheritance gymnastics.
    """
    if _password_is_common(value):
        raise ValueError("Password is too common; choose a stronger password.")
    return value


class RegisterRequest(BaseModel):
    """Request model for user registration."""

    email: EmailStr
    password: str = Field(..., min_length=8)

    _strong_password = field_validator("password")(classmethod(lambda cls, v: _validate_strong_password(v)))


class ChangePasswordRequest(BaseModel):
    """Request model for password change (also handles setup flow)."""

    current_password: str
    new_password: str = Field(..., min_length=8)
    new_email: EmailStr | None = None

    _strong_password = field_validator("new_password")(classmethod(lambda cls, v: _validate_strong_password(v)))


class MessageResponse(BaseModel):
    """Generic message response."""

    message: str


# ── Helpers ───────────────────────────────────────────────────────────────


def _set_session_cookie(response: Response, token: str, request: Request) -> None:
    """Set the access_token HttpOnly cookie on the response."""
    config = get_auth_config()
    is_https = is_secure_request(request)
    response.set_cookie(
        key="access_token",
        value=token,
        httponly=True,
        secure=is_https,
        samesite="lax",
        max_age=config.token_expiry_days * 24 * 3600 if is_https else None,
    )


# ── Rate Limiting ────────────────────────────────────────────────────────
# In-process dict — not shared across workers.
#
# **Limitation**: with multi-worker deployments (e.g., gunicorn -w N), each
# worker maintains its own lockout table, so an attacker effectively gets
# N × _MAX_LOGIN_ATTEMPTS guesses before being locked out everywhere. For
# production multi-worker setups, replace this with a shared store (Redis,
# database-backed counter) to enforce a true per-IP limit.

_MAX_LOGIN_ATTEMPTS = 5
_LOCKOUT_SECONDS = 300  # 5 minutes

# ip → (fail_count, lock_until_timestamp)
_login_attempts: dict[str, tuple[int, float]] = {}


def _trusted_proxies() -> list:
    """Parse ``AUTH_TRUSTED_PROXIES`` env var into a list of ip_network objects.

    Comma-separated CIDR or single-IP entries. Empty / unset = no proxy is
    trusted (direct mode). Invalid entries are skipped with a logger warning.
    Read live so env-var overrides take effect immediately and tests can
    ``monkeypatch.setenv`` without poking a module-level cache.
    """
    raw = os.getenv("AUTH_TRUSTED_PROXIES", "").strip()
    if not raw:
        return []
    nets = []
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        try:
            nets.append(ip_network(entry, strict=False))
        except ValueError:
            logger.warning("AUTH_TRUSTED_PROXIES: ignoring invalid entry %r", entry)
    return nets


def _get_client_ip(request: Request) -> str:
    """Extract the real client IP for rate limiting.

    Trust model:

    - The TCP peer (``request.client.host``) is always the baseline. It is
      whatever the kernel reports as the connecting socket — unforgeable
      by the client itself.
    - ``X-Real-IP`` is **only** honored if the TCP peer is in the
      ``AUTH_TRUSTED_PROXIES`` allowlist (set via env var, comma-separated
      CIDR or single IPs). When set, the gateway is assumed to be behind a
      reverse proxy (nginx, Cloudflare, ALB, …) that overwrites
      ``X-Real-IP`` with the original client address.
    - With no ``AUTH_TRUSTED_PROXIES`` set, ``X-Real-IP`` is silently
      ignored — closing the bypass where any client could rotate the
      header to dodge per-IP rate limits in dev / direct-gateway mode.

    ``X-Forwarded-For`` is intentionally NOT used because it is naturally
    client-controlled at the *first* hop and the trust chain is harder to
    audit per-request.
    """
    peer_host = request.client.host if request.client else None

    trusted = _trusted_proxies()
    if trusted and peer_host:
        try:
            peer_ip = ip_address(peer_host)
            if any(peer_ip in net for net in trusted):
                real_ip = request.headers.get("x-real-ip", "").strip()
                if real_ip:
                    return real_ip
        except ValueError:
            # peer_host wasn't a parseable IP (e.g. "unknown") — fall through
            pass

    return peer_host or "unknown"


def _check_rate_limit(ip: str) -> None:
    """Raise 429 if the IP is currently locked out."""
    record = _login_attempts.get(ip)
    if record is None:
        return
    fail_count, lock_until = record
    if fail_count >= _MAX_LOGIN_ATTEMPTS:
        if time.time() < lock_until:
            raise HTTPException(
                status_code=429,
                detail="Too many login attempts. Try again later.",
            )
        del _login_attempts[ip]


_MAX_TRACKED_IPS = 10000


def _record_login_failure(ip: str) -> None:
    """Record a failed login attempt for the given IP."""
    # Evict expired lockouts when dict grows too large
    if len(_login_attempts) >= _MAX_TRACKED_IPS:
        now = time.time()
        expired = [k for k, (c, t) in _login_attempts.items() if c >= _MAX_LOGIN_ATTEMPTS and now >= t]
        for k in expired:
            del _login_attempts[k]
        # If still too large, evict cheapest-to-lose half: below-threshold
        # IPs (lock_until=0.0) sort first, then earliest-expiring lockouts.
        if len(_login_attempts) >= _MAX_TRACKED_IPS:
            by_time = sorted(_login_attempts.items(), key=lambda kv: kv[1][1])
            for k, _ in by_time[: len(by_time) // 2]:
                del _login_attempts[k]

    record = _login_attempts.get(ip)
    if record is None:
        _login_attempts[ip] = (1, 0.0)
    else:
        new_count = record[0] + 1
        lock_until = time.time() + _LOCKOUT_SECONDS if new_count >= _MAX_LOGIN_ATTEMPTS else 0.0
        _login_attempts[ip] = (new_count, lock_until)


def _record_login_success(ip: str) -> None:
    """Clear failure counter for the given IP on successful login."""
    _login_attempts.pop(ip, None)


# ── Endpoints ─────────────────────────────────────────────────────────────


@router.post("/login/local", response_model=LoginResponse)
async def login_local(
    request: Request,
    response: Response,
    form_data: OAuth2PasswordRequestForm = Depends(),
):
    """Local email/password login."""
    client_ip = _get_client_ip(request)
    _check_rate_limit(client_ip)

    user = await get_local_provider().authenticate({"email": form_data.username, "password": form_data.password})

    if user is None:
        _record_login_failure(client_ip)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=AuthErrorResponse(code=AuthErrorCode.INVALID_CREDENTIALS, message="Incorrect email or password").model_dump(),
        )

    _record_login_success(client_ip)
    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)

    return LoginResponse(
        expires_in=get_auth_config().token_expiry_days * 24 * 3600,
        needs_setup=user.needs_setup,
    )


@router.post("/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def register(request: Request, response: Response, body: RegisterRequest):
    """Register a new user account (always 'user' role).

    The first admin is created explicitly through /initialize. This endpoint creates regular users.
    Auto-login by setting the session cookie.

    Pacgate: returns 403 when ``auth.local.allow_registration`` is false.
    """
    if not _local_registration_enabled():
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=AuthErrorResponse(
                code=AuthErrorCode.REGISTRATION_DISABLED,
                message="Self-registration is disabled on this deployment",
            ).model_dump(),
        )

    try:
        user = await get_local_provider().create_user(email=body.email, password=body.password, system_role="user")
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=AuthErrorResponse(code=AuthErrorCode.EMAIL_ALREADY_EXISTS, message="Email already registered").model_dump(),
        )

    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)

    return UserResponse(id=str(user.id), email=user.email, system_role=user.system_role)


@router.post("/logout", response_model=MessageResponse)
async def logout(request: Request, response: Response):
    """Logout current user by clearing the cookie."""
    response.delete_cookie(key="access_token", secure=is_secure_request(request), samesite="lax")
    return MessageResponse(message="Successfully logged out")


@router.post("/change-password", response_model=MessageResponse)
async def change_password(request: Request, response: Response, body: ChangePasswordRequest):
    """Change password for the currently authenticated user.

    Also handles the first-boot setup flow:
    - If new_email is provided, updates email (checks uniqueness)
    - If user.needs_setup is True and new_email is given, clears needs_setup
    - Always increments token_version to invalidate old sessions
    - Re-issues session cookie with new token_version
    """
    from app.gateway.auth.password import hash_password_async, verify_password_async
    from app.gateway.auth_disabled import AUTH_SOURCE_AUTH_DISABLED

    user = await get_current_user_from_request(request)

    if getattr(request.state, "auth_source", None) == AUTH_SOURCE_AUTH_DISABLED:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=AuthErrorResponse(
                code=AuthErrorCode.INVALID_CREDENTIALS,
                message="Password changes are not available when DEER_FLOW_AUTH_DISABLED=1.",
            ).model_dump(),
        )

    if user.password_hash is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=AuthErrorResponse(code=AuthErrorCode.INVALID_CREDENTIALS, message="OAuth users cannot change password").model_dump())

    if not await verify_password_async(body.current_password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=AuthErrorResponse(code=AuthErrorCode.INVALID_CREDENTIALS, message="Current password is incorrect").model_dump())

    provider = get_local_provider()

    # Update email if provided
    if body.new_email is not None:
        existing = await provider.get_user_by_email(body.new_email)
        if existing and str(existing.id) != str(user.id):
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=AuthErrorResponse(code=AuthErrorCode.EMAIL_ALREADY_EXISTS, message="Email already in use").model_dump())
        user.email = body.new_email

    # Update password + bump version
    user.password_hash = await hash_password_async(body.new_password)
    user.token_version += 1

    # Clear setup flag if this is the setup flow
    if user.needs_setup and body.new_email is not None:
        user.needs_setup = False

    await provider.update_user(user)

    # Re-issue cookie with new token_version
    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)

    return MessageResponse(message="Password changed successfully")


@router.get("/me", response_model=UserResponse)
async def get_me(request: Request):
    """Get current authenticated user info."""
    user = await get_current_user_from_request(request)
    return UserResponse(id=str(user.id), email=user.email, system_role=user.system_role, needs_setup=user.needs_setup)


# Per-IP cache: ip → (timestamp, result_dict).
# Returns the cached result within the TTL instead of 429, because
# the answer (whether an admin exists) rarely changes and returning
# 429 breaks multi-tab / post-restart reconnection storms.
_SETUP_STATUS_CACHE: dict[str, tuple[float, dict]] = {}
_SETUP_STATUS_CACHE_TTL_SECONDS = 60
_MAX_TRACKED_SETUP_STATUS_IPS = 10000
_SETUP_STATUS_INFLIGHT: dict[str, asyncio.Task[dict]] = {}
_SETUP_STATUS_INFLIGHT_GUARD = asyncio.Lock()


@router.get("/setup-status")
async def setup_status(request: Request):
    """Check if an admin account exists. Returns needs_setup=True when no admin exists."""
    client_ip = _get_client_ip(request)
    now = time.time()

    # Return cached result when within TTL — avoids 429 on multi-tab reconnection.
    cached = _SETUP_STATUS_CACHE.get(client_ip)
    if cached is not None:
        cached_time, cached_result = cached
        if now - cached_time < _SETUP_STATUS_CACHE_TTL_SECONDS:
            return cached_result

    async with _SETUP_STATUS_INFLIGHT_GUARD:
        # Recheck cache after waiting for the inflight guard.
        now = time.time()
        cached = _SETUP_STATUS_CACHE.get(client_ip)
        if cached is not None:
            cached_time, cached_result = cached
            if now - cached_time < _SETUP_STATUS_CACHE_TTL_SECONDS:
                return cached_result

        task = _SETUP_STATUS_INFLIGHT.get(client_ip)
        if task is None:
            # Evict stale entries when dict grows too large to bound memory usage.
            if len(_SETUP_STATUS_CACHE) >= _MAX_TRACKED_SETUP_STATUS_IPS:
                cutoff = now - _SETUP_STATUS_CACHE_TTL_SECONDS
                stale = [k for k, (t, _) in _SETUP_STATUS_CACHE.items() if t < cutoff]
                for k in stale:
                    del _SETUP_STATUS_CACHE[k]
                if len(_SETUP_STATUS_CACHE) >= _MAX_TRACKED_SETUP_STATUS_IPS:
                    by_time = sorted(_SETUP_STATUS_CACHE.items(), key=lambda entry: entry[1][0])
                    for k, _ in by_time[: len(by_time) // 2]:
                        del _SETUP_STATUS_CACHE[k]

            async def _compute_setup_status() -> dict:
                admin_count = await get_local_provider().count_admin_users()
                return {"needs_setup": admin_count == 0}

            task = asyncio.create_task(_compute_setup_status())
            _SETUP_STATUS_INFLIGHT[client_ip] = task

    try:
        result = await task
    finally:
        async with _SETUP_STATUS_INFLIGHT_GUARD:
            if _SETUP_STATUS_INFLIGHT.get(client_ip) is task:
                del _SETUP_STATUS_INFLIGHT[client_ip]

    # Cache only the stable "initialized" result to avoid stale setup redirects.
    if result["needs_setup"] is False:
        _SETUP_STATUS_CACHE[client_ip] = (time.time(), result)
    else:
        _SETUP_STATUS_CACHE.pop(client_ip, None)
    return result


class InitializeAdminRequest(BaseModel):
    """Request model for first-boot admin account creation."""

    email: EmailStr
    password: str = Field(..., min_length=8)
    # Required: the one-time bootstrap token (see _current_setup_token).
    # Optional in the SCHEMA so a missing token reaches the handler and gets a
    # clear 403 rather than a generic 422 validation error — the operator sees
    # "token required" instead of guessing which field is malformed.
    setup_token: str | None = None

    _strong_password = field_validator("password")(classmethod(lambda cls, v: _validate_strong_password(v)))


@router.post("/initialize", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
async def initialize_admin(request: Request, response: Response, body: InitializeAdminRequest):
    """Create the first admin account on initial system setup.

    Only callable when no admin exists. Returns 409 Conflict if an admin
    already exists.

    Pacgate: requires the one-time bootstrap token. Without this, a freshly
    installed AIPC could be claimed by whoever reached this URL first — see the
    _current_setup_token block above for why this is separate from
    auth.local.allow_registration.

    On success, the admin account is created with ``needs_setup=False`` and
    the session cookie is set.
    """
    # 403 BEFORE the admin_count probe, so an already-initialised deployment
    # does not leak "there is/is not an admin" to an unauthenticated caller that
    # has no token. The token is the cheaper and more fundamental check.
    #
    # When the gate is disabled (_current_setup_token() is None) behaviour is
    # byte-for-byte the pre-patch behaviour: the endpoint stays public and the
    # admin_count check below is the only guard.
    required_token = _current_setup_token()
    if required_token is not None:
        supplied = body.setup_token or request.headers.get("X-Pacgate-Setup-Token", "")
        if not supplied or not hmac.compare_digest(supplied, required_token):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=AuthErrorResponse(
                    code=AuthErrorCode.SETUP_TOKEN_REQUIRED,
                    message=(
                        "A valid setup token is required to create the first admin. "
                        "Read it from the deer-flow container log (search for "
                        "'PACGATE SETUP TOKEN'), or use the PACGATE_SETUP_TOKEN value."
                    ),
                ).model_dump(),
            )

    admin_count = await get_local_provider().count_admin_users()
    if admin_count > 0:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=AuthErrorResponse(code=AuthErrorCode.SYSTEM_ALREADY_INITIALIZED, message="System already initialized").model_dump(),
        )

    try:
        user = await get_local_provider().create_user(email=body.email, password=body.password, system_role="admin", needs_setup=False)
    except ValueError:
        # DB unique-constraint race: another concurrent request beat us.
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=AuthErrorResponse(code=AuthErrorCode.SYSTEM_ALREADY_INITIALIZED, message="System already initialized").model_dump(),
        )

    token = create_access_token(str(user.id), token_version=user.token_version)
    _set_session_cookie(response, token, request)

    return UserResponse(id=str(user.id), email=user.email, system_role=user.system_role)


# ── OAuth Endpoints (Future/Placeholder) ─────────────────────────────────


@router.get("/oauth/{provider}")
async def oauth_login(provider: str):
    """Initiate OAuth login flow.

    Redirects to the OAuth provider's authorization URL.
    Currently a placeholder - requires OAuth provider implementation.
    """
    if provider not in ["github", "google"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported OAuth provider: {provider}",
        )

    raise HTTPException(
        status_code=status.HTTP_501_NOT_IMPLEMENTED,
        detail="OAuth login not yet implemented",
    )


@router.get("/callback/{provider}")
async def oauth_callback(provider: str, code: str, state: str):
    """OAuth callback endpoint.

    Handles the OAuth provider's callback after user authorization.
    Currently a placeholder.
    """
    raise HTTPException(
        status_code=status.HTTP_501_NOT_IMPLEMENTED,
        detail="OAuth callback not yet implemented",
    )
