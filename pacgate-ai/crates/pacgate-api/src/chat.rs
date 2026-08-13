use axum::{
    extract::State,
    response::{
        sse::{Event, Sse},
        IntoResponse,
    },
    Json,
};
use futures::stream;
use pacgate_core::AgentMessage;
use serde::{Deserialize, Serialize};
use std::convert::Infallible;

use crate::{error::ApiError, state::AppState};

// ─────────────────────────────────────────────────────────────────────────────
// Request / response
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ChatRequest {
    pub matter_id:   String,
    pub message:     String,
    pub persona_id:  Option<String>,
    /// Client-provided conversation history (without system message)
    #[serde(default)]
    pub history:     Vec<AgentMessage>,
}

#[derive(Debug, Serialize)]
pub struct ChatResponse {
    pub message_id: String,
    pub content:    Option<String>,
    pub citations:  Vec<pacgate_core::CitationRef>,
    pub tools_used: Vec<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-streaming handler
// ─────────────────────────────────────────────────────────────────────────────

pub async fn chat_handler(
    State(state): State<AppState>,
    Json(req):    Json<ChatRequest>,
) -> Result<Json<ChatResponse>, ApiError> {
    let persona_prompt = None; // TODO: resolve from persona_id via pacgate-persona

    let result = state
        .agent_loop
        .run(req.history, &req.message, persona_prompt)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(ChatResponse {
        message_id: result.message_id.to_string(),
        content:    result.content,
        citations:  result.citations,
        tools_used: result.tool_calls_made,
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// SSE streaming handler
// ─────────────────────────────────────────────────────────────────────────────

/// SSE event types sent to the client.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SsePayload {
    TextDelta    { text: String },
    ToolStart    { name: String },
    ToolEnd      { name: String, is_error: bool },
    CitationBlock { citations: Vec<pacgate_core::CitationRef> },
    Done         { message_id: String },
    Error        { message: String },
}

pub async fn chat_stream_handler(
    State(state): State<AppState>,
    Json(req):    Json<ChatRequest>,
) -> impl IntoResponse {
    // For now, delegate to non-streaming and emit the full response as a single SSE event.
    // Phase 4 will wire up proper streaming via LlmRouter::stream().
    let persona_prompt = None;

    let event_stream: std::pin::Pin<Box<dyn futures::Stream<Item = Result<Event, Infallible>> + Send>> = {
        match state.agent_loop.run(req.history, &req.message, persona_prompt).await {
            Ok(result) => {
                let events: Vec<_> = {
                    let mut v = Vec::new();

                    if let Some(text) = result.content {
                        let payload = SsePayload::TextDelta { text };
                        if let Ok(json) = serde_json::to_string(&payload) {
                            v.push(Ok(Event::default().data(json)));
                        }
                    }

                    if !result.citations.is_empty() {
                        let payload = SsePayload::CitationBlock { citations: result.citations };
                        if let Ok(json) = serde_json::to_string(&payload) {
                            v.push(Ok(Event::default().data(json)));
                        }
                    }

                    let done = SsePayload::Done { message_id: result.message_id.to_string() };
                    if let Ok(json) = serde_json::to_string(&done) {
                        v.push(Ok(Event::default().data(json)));
                    }

                    v
                };
                Box::pin(stream::iter(events))
            }
            Err(e) => {
                let payload = SsePayload::Error { message: e.to_string() };
                let event = serde_json::to_string(&payload)
                    .map(|json| Ok(Event::default().data(json)))
                    .unwrap_or_else(|_| Ok(Event::default().data("internal error")));
                Box::pin(stream::iter(vec![event]))
            }
        }
    };

    Sse::new(event_stream)
}
