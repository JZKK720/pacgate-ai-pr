//! pacgate-api — Axum HTTP server with SSE streaming, REST endpoints, and middleware.

mod auth;
mod chat;
mod documents;
mod error;
mod matters;
mod state;
mod workflows;

pub use state::{AppConfig, AppState};
pub use error::ApiError;

use axum::{
    Router,
    routing::{get, post, put, delete},
};
use tower::ServiceBuilder;
use tower_http::{
    cors::{Any, CorsLayer},
    trace::TraceLayer,
};

/// Build the main Axum router with all API routes.
pub fn build_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_headers(Any)
        .allow_methods(Any);

    Router::new()
        // Health
        .route("/health", get(|| async { "ok" }))

        // Auth (no middleware required for login/register)
        .route("/api/auth/login",    post(auth::login))
        .route("/api/auth/register", post(auth::register))
        .route("/api/auth/me",       get(auth::me))

        // Chat / agent
        .route("/api/chat",             post(chat::chat_handler))
        .route("/api/chat/stream",      post(chat::chat_stream_handler))

        // Documents
        .route("/api/documents",        post(documents::upload_document))
        .route("/api/documents/:id",    get(documents::get_document))
        .route("/api/documents/:id",    delete(documents::delete_document))
        .route("/api/documents/:id/versions", get(documents::list_versions))
        .route("/api/documents/:id/download", get(documents::download_document))
        .route("/api/documents/:id/edit",     put(documents::edit_document))
        .route("/api/documents/:id/accept",   post(documents::accept_changes))

        // Matters
        .route("/api/matters",          post(matters::create_matter))
        .route("/api/matters",          get(matters::list_matters))
        .route("/api/matters/:id",      get(matters::get_matter))
        .route("/api/matters/:id",      delete(matters::delete_matter))
        .route("/api/matters/:id/documents", get(matters::list_matter_documents))

        // Workflows
        .route("/api/workflows",        get(workflows::list_workflows))
        .route("/api/workflows/:id",    get(workflows::get_workflow))

        // Tabular review
        .route("/api/tabular",          post(documents::start_tabular_review))
        .route("/api/tabular/:id",      get(documents::get_tabular_results))

        .layer(
            ServiceBuilder::new()
                .layer(TraceLayer::new_for_http())
                .layer(cors),
        )
        .with_state(state)
}
