use axum::{
    extract::{Extension, State},
    response::{
        sse::{Event, Sse},
        IntoResponse,
    },
    Json,
};
use futures::stream;
use pacgate_core::{AgentMessage, SoulPersona};
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
// SOUL persona prompt composition
// ─────────────────────────────────────────────────────────────────────────────

/// Build the persona prompt string from a resolved SOUL persona and an optional
/// explicit persona_id override.
///
/// The layered prompt structure is:
/// 1. SOUL system_preamble (identity overlay — who the agent is)
/// 2. SOUL boundary_rules (red lines — what the agent must not do)
/// 3. SOUL output_format instructions (how to format responses)
/// 4. Practice-area persona prompt (from pacgate-persona, if persona_id is provided)
///
/// If no SOUL is resolved and no persona_id is given, returns None (default agent behavior).
fn compose_persona_prompt(
    soul: Option<&SoulPersona>,
    persona_id: Option<&str>,
) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();

    // Layer 1: SOUL system preamble
    if let Some(s) = soul {
        if !s.system_preamble.is_empty() {
            parts.push(format!("## IDENTITY OVERLAY\n\n{}", s.system_preamble));
        }

        // Layer 2: Boundary rules (red lines)
        if !s.boundary_rules.is_empty() {
            let rules: Vec<String> = s.boundary_rules
                .iter()
                .map(|r| format!("- {}", r.rule))
                .collect();
            parts.push(format!("## BOUNDARY RULES (red lines)\n\n{}", rules.join("\n")));
        }

        // Layer 3: Output format
        match s.output_format {
            pacgate_core::OutputFormat::Decision3Part => {
                parts.push("## OUTPUT FORMAT\n\nStructure your response in 3 parts: (1) conclusion, (2) options, (3) recommendation.".to_string());
            }
            pacgate_core::OutputFormat::LegalOpinion3Part => {
                parts.push("## OUTPUT FORMAT\n\nStructure your response in 3 parts: (1) 结论/结论建议 (conclusion), (2) 依据 (legal basis with citations), (3) 待确认事项 (open questions).".to_string());
            }
            pacgate_core::OutputFormat::Standard => {}
        }
    }

    // Layer 4: Practice-area persona (from pacgate-persona crate)
    if let Some(pid) = persona_id {
        if let Ok(uuid) = uuid::Uuid::parse_str(pid) {
            let pid_typed = pacgate_core::PersonaId(uuid);
            // Try SOUL personas first (identity overlays), then practice-area personas
            if let Some(soul_persona) = pacgate_persona::get_soul(&pid_typed) {
                // If the SOUL was not already resolved via middleware, use its preamble
                if soul.is_none() && !soul_persona.system_preamble.is_empty() {
                    parts.push(format!("## IDENTITY OVERLAY\n\n{}", soul_persona.system_preamble));
                }
            } else if let Some(practice_persona) = pacgate_persona::list_personas()
                .iter()
                .find(|p| p.id.0 == uuid)
            {
                parts.push(format!("## PRACTICE AREA INSTRUCTIONS\n\n{}", practice_persona.system_prompt));
            }
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n\n"))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-streaming handler
// ─────────────────────────────────────────────────────────────────────────────

pub async fn chat_handler(
    State(state): State<AppState>,
    Extension(soul): Extension<Option<SoulPersona>>,
    Json(req):    Json<ChatRequest>,
) -> Result<Json<ChatResponse>, ApiError> {
    let persona_prompt = compose_persona_prompt(soul.as_ref(), req.persona_id.as_deref());

    let result = state
        .agent_loop
        .run(req.history, &req.message, persona_prompt.as_deref())
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
    Extension(soul): Extension<Option<SoulPersona>>,
    Json(req):    Json<ChatRequest>,
) -> impl IntoResponse {
    // For now, delegate to non-streaming and emit the full response as a single SSE event.
    // Phase 4 will wire up proper streaming via LlmRouter::stream().
    let persona_prompt = compose_persona_prompt(soul.as_ref(), req.persona_id.as_deref());

    let event_stream: std::pin::Pin<Box<dyn futures::Stream<Item = Result<Event, Infallible>> + Send>> = {
        match state.agent_loop.run(req.history, &req.message, persona_prompt.as_deref()).await {
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
