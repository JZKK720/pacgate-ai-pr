//! pacgate-api — Axum HTTP server with SSE streaming, REST endpoints, and middleware.

mod auth;
mod chat;
mod documents;
mod error;
mod matters;
mod state;
mod workflows;

pub use error::ApiError;
pub use state::{AppConfig, AppState};

use axum::{
    middleware,
    routing::{delete, get, post, put},
    Router,
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

    // Protected routes — require JWT auth + SOUL resolver
    let protected = Router::new()
        // Chat / agent
        .route("/api/chat", post(chat::chat_handler))
        .route("/api/chat/stream", post(chat::chat_stream_handler))
        // Documents
        .route("/api/documents", post(documents::upload_document))
        .route("/api/documents/:id", get(documents::get_document))
        .route("/api/documents/:id", delete(documents::delete_document))
        .route("/api/documents/:id/versions", get(documents::list_versions))
        .route(
            "/api/documents/:id/download",
            get(documents::download_document),
        )
        .route("/api/documents/:id/edit", put(documents::edit_document))
        .route("/api/documents/:id/accept", post(documents::accept_changes))
        // Matters
        .route("/api/matters", post(matters::create_matter))
        .route("/api/matters", get(matters::list_matters))
        .route("/api/matters/:id", get(matters::get_matter))
        .route("/api/matters/:id", delete(matters::delete_matter))
        .route(
            "/api/matters/:id/documents",
            get(matters::list_matter_documents),
        )
        // Workflows
        .route("/api/workflows", get(workflows::list_workflows))
        .route(
            "/api/workflows/categories",
            get(workflows::list_workflow_categories),
        )
        .route("/api/workflows/:id", get(workflows::get_workflow))
        .route(
            "/api/workflows/:id/execute",
            post(workflows::execute_workflow),
        )
        // Tabular review
        .route("/api/tabular", post(documents::start_tabular_review))
        .route("/api/tabular/:id", get(documents::get_tabular_results))
        // Auth-protected user info
        .route("/api/auth/me", get(auth::me))
        // Apply auth middleware (verifies JWT, injects Claims)
        // then SOUL resolver (resolves soul_id → SoulPersona, injects into extensions)
        .layer(middleware::from_fn_with_state(
            (*state.auth).clone(),
            pacgate_auth::auth_middleware,
        ))
        .layer(middleware::from_fn(pacgate_auth::soul_resolver_middleware));

    Router::new()
        // Health (no auth)
        .route("/health", get(|| async { "ok" }))
        // Auth endpoints (no auth required for login/register)
        .route("/api/auth/login", post(auth::login))
        .route("/api/auth/register", post(auth::register))
        // Merge protected routes
        .merge(protected)
        .layer(
            ServiceBuilder::new()
                .layer(TraceLayer::new_for_http())
                .layer(cors),
        )
        .with_state(state)
}
