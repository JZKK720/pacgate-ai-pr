"""Typed error definitions for auth module.

AuthErrorCode: exhaustive enum of all auth failure conditions.
TokenError: exhaustive enum of JWT decode failures.
AuthErrorResponse: structured error payload for HTTP responses.
"""

from enum import StrEnum

from pydantic import BaseModel


class AuthErrorCode(StrEnum):
    """Exhaustive list of auth error conditions."""

    INVALID_CREDENTIALS = "invalid_credentials"
    TOKEN_EXPIRED = "token_expired"
    TOKEN_INVALID = "token_invalid"
    USER_NOT_FOUND = "user_not_found"
    EMAIL_ALREADY_EXISTS = "email_already_exists"
    PROVIDER_NOT_FOUND = "provider_not_found"
    NOT_AUTHENTICATED = "not_authenticated"
    SYSTEM_ALREADY_INITIALIZED = "system_already_initialized"
    # Pacgate: added to mirror upstream 2.1.0, which introduces this code together
    # with the auth.local.allow_registration gate (#4311). Keep the value string
    # identical to upstream's so the 2.1.0 upgrade can drop this whole patch.
    REGISTRATION_DISABLED = "registration_disabled"
    # Pacgate: no upstream equivalent. Returned by POST /initialize when the
    # opt-in PACGATE_SETUP_TOKEN gate is armed and the caller's token is missing
    # or wrong. See the _current_setup_token block in deer-flow-auth.py.
    SETUP_TOKEN_REQUIRED = "setup_token_required"


class TokenError(StrEnum):
    """Exhaustive list of JWT decode failure reasons."""

    EXPIRED = "expired"
    INVALID_SIGNATURE = "invalid_signature"
    MALFORMED = "malformed"


class AuthErrorResponse(BaseModel):
    """Structured error response — replaces bare `detail` strings."""

    code: AuthErrorCode
    message: str


def token_error_to_code(err: TokenError) -> AuthErrorCode:
    """Map TokenError to AuthErrorCode — single source of truth."""
    if err == TokenError.EXPIRED:
        return AuthErrorCode.TOKEN_EXPIRED
    return AuthErrorCode.TOKEN_INVALID
