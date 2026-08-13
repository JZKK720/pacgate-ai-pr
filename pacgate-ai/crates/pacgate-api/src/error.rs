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
