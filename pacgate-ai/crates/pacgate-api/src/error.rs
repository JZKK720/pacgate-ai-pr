use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

/// Unified API error type that converts to HTTP responses.
#[derive(Debug)]
pub struct ApiError {
    pub status:  StatusCode,
    pub code:    &'static str,
    pub message: String,
}

impl ApiError {
    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::BAD_REQUEST, code: "bad_request", message: msg.into() }
    }
    pub fn not_found(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::NOT_FOUND, code: "not_found", message: msg.into() }
    }
    pub fn internal(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::INTERNAL_SERVER_ERROR, code: "internal_error", message: msg.into() }
    }
    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::UNAUTHORIZED, code: "unauthorized", message: msg.into() }
    }

    /// 409 Conflict - the caller view of the resource is stale.
    ///
    /// Used for optimistic concurrency on matter memory: the caller presents
    /// the revision it read, and a mismatch means somebody else wrote first.
    pub fn conflict(msg: impl Into<String>) -> Self {
        Self { status: StatusCode::CONFLICT, code: "conflict", message: msg.into() }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = json!({ "error": { "code": self.code, "message": self.message } });
        (self.status, Json(body)).into_response()
    }
}

impl From<pacgate_core::PacgateError> for ApiError {
    fn from(e: pacgate_core::PacgateError) -> Self {
        use pacgate_core::PacgateError::*;
        match e {
            DocumentNotFound { id } => Self::not_found(format!("document not found: {id}")),
            MatterNotFound   { id } => Self::not_found(format!("matter not found: {id}")),
            ToolNotFound     { name } => Self::bad_request(format!("tool not found: {name}")),
            AuthError(msg)  => Self::unauthorized(msg),
            ValidationError(msg) => Self::bad_request(msg),
            _ => Self::internal(e.to_string()),
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        Self::internal(e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflict_is_409_with_a_stable_code() {
        let e = ApiError::conflict("revision mismatch");
        assert_eq!(e.status, StatusCode::CONFLICT);
        assert_eq!(e.code, "conflict");
        assert_eq!(e.message, "revision mismatch");
    }

    #[test]
    fn existing_constructors_keep_their_codes() {
        assert_eq!(ApiError::bad_request("x").code, "bad_request");
        assert_eq!(ApiError::not_found("x").code, "not_found");
        assert_eq!(ApiError::internal("x").code, "internal_error");
        assert_eq!(ApiError::unauthorized("x").code, "unauthorized");
    }
}
