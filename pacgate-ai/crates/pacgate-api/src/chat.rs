use axum::{
    extract::{Extension, State},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    Json,
};
use futures::stream;
use futures::StreamExt;
use pacgate_agent::AgentEvent;
use pacgate_auth::Claims;
use pacgate_core::{AgentMessage, MatterId, SoulPersona, TenantId};
use serde::{Deserialize, Serialize};
use std::convert::Infallible;

use crate::{error::ApiError, state::AppState};

fn claims_to_tenant_id(claims: &Claims) -> Result<TenantId, ApiError> {
    claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))
}

fn sse_error_response(message: impl Into<String>) -> Response {
    let payload = SsePayload::Error {
        message: message.into(),
    };
    let event: Result<Event, Infallible> = serde_json::to_string(&payload)
        .map(|json| Ok(Event::default().data(json)))
        .unwrap_or_else(|_| Ok(Event::default().data("internal error")));
    let stream = Box::pin(stream::iter(vec![event]));
    Sse::new(stream).into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// Request / response
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ChatRequest {
    pub matter_id: String,
    pub message: String,
    pub persona_id: Option<String>,
    /// Client-provided conversation history (without system message)
    #[serde(default)]
    pub history: Vec<AgentMessage>,
}

#[derive(Debug, Serialize)]
pub struct ChatResponse {
    pub message_id: String,
    pub content: Option<String>,
    pub citations: Vec<pacgate_core::CitationRef>,
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
fn compose_persona_prompt(soul: Option<&SoulPersona>, persona_id: Option<&str>) -> Option<String> {
    let mut parts: Vec<String> = Vec::new();

    // Layer 1: SOUL system preamble
    if let Some(s) = soul {
        if !s.system_preamble.is_empty() {
            parts.push(format!("## IDENTITY OVERLAY\n\n{}", s.system_preamble));
        }

        // Layer 2: Boundary rules (red lines)
        if !s.boundary_rules.is_empty() {
            let rules: Vec<String> = s
                .boundary_rules
                .iter()
                .map(|r| format!("- {}", r.rule))
                .collect();
            parts.push(format!(
                "## BOUNDARY RULES (red lines)\n\n{}",
                rules.join("\n")
            ));
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
                    parts.push(format!(
                        "## IDENTITY OVERLAY\n\n{}",
                        soul_persona.system_preamble
                    ));
                }
            } else if let Some(practice_persona) = pacgate_persona::list_personas()
                .iter()
                .find(|p| p.id.0 == uuid)
            {
                parts.push(format!(
                    "## PRACTICE AREA INSTRUCTIONS\n\n{}",
                    practice_persona.system_prompt
                ));
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
    Extension(claims): Extension<Claims>,
    Extension(soul): Extension<Option<SoulPersona>>,
    Json(req): Json<ChatRequest>,
) -> Result<Json<ChatResponse>, ApiError> {
    let tenant_id = claims_to_tenant_id(&claims)?;
    let matter_id: MatterId = req
        .matter_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let persona_prompt = compose_persona_prompt(soul.as_ref(), req.persona_id.as_deref());

    let router = state
        .router_for_tenant(&tenant_id)
        .await
        .map_err(ApiError::from)?;
    let result = state
        .agent_loop
        .run_with_router(
            &router,
            req.history,
            &req.message,
            persona_prompt.as_deref(),
            Some(&matter_id),
        )
        .await
        .map_err(ApiError::from)?;

    Ok(Json(ChatResponse {
        message_id: result.message_id.to_string(),
        content: result.content,
        citations: result.citations,
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
    TextDelta {
        text: String,
    },
    ToolStart {
        name: String,
    },
    #[allow(dead_code)]
    ToolEnd {
        name: String,
        is_error: bool,
    },
    /// Which tool-call round the turn is entering. Cheap, and it is the only
    /// signal during a long model call - without it an idle spinner and a hung
    /// process look identical.
    Round {
        round: u32,
    },
    CitationBlock {
        citations: Vec<pacgate_core::CitationRef>,
    },
    Done {
        message_id: String,
    },
    Error {
        message: String,
    },
}

pub async fn chat_stream_handler(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Extension(soul): Extension<Option<SoulPersona>>,
    Json(req): Json<ChatRequest>,
) -> impl IntoResponse {
    let tenant_id = match claims_to_tenant_id(&claims) {
        Ok(value) => value,
        Err(error) => return sse_error_response(error.message),
    };

    let matter_id: MatterId = match req.matter_id.parse() {
        Ok(value) => value,
        Err(error) => return sse_error_response(format!("invalid matter id: {error}")),
    };

    if state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .is_err()
    {
        return sse_error_response("matter not found");
    }

    // Run the turn in a background task and forward every boundary over a channel,
    // so the client receives data WHILE the agent works instead of after it stops.
    //
    // The previous body awaited `run_with_router` to completion and then built the
    // event vector, which is the same as not streaming at all: a turn using 8 tools
    // sent zero bytes for minutes and the UI sat on a spinner. Reported by the user
    // as "36 steps and still no response from the LLM".
    let persona_prompt = compose_persona_prompt(soul.as_ref(), req.persona_id.as_deref());

    let event_stream: std::pin::Pin<
        Box<dyn futures::Stream<Item = Result<Event, Infallible>> + Send>,
    > = {
        let router = match state.router_for_tenant(&tenant_id).await {
            Ok(r) => r,
            Err(e) => return sse_error_response(e.to_string()),
        };

        // Bounded so a disconnected client cannot pin unbounded memory; a full
        // channel simply drops progress frames, which is the correct trade - the
        // frames are advisory and the final answer still arrives.
        let (tx, rx) = tokio::sync::mpsc::channel::<AgentEvent>(64);
        let agent_loop = state.agent_loop.clone();
        let history = req.history;
        let message = req.message;

        // The turn's own result must travel over the SAME channel as the progress
        // frames, otherwise the answer is lost: the spawned task is detached and
        // its return value is discarded. Emit the terminal frames here.
        tokio::spawn(async move {
            let event_tx = tx.clone();
            let emit = move |event: AgentEvent| {
                let _ = event_tx.try_send(event);
            };
            let outcome = agent_loop
                .run_with_router_and_progress(
                    &router,
                    history,
                    &message,
                    persona_prompt.as_deref(),
                    Some(&matter_id),
                    Some(&emit),
                )
                .await;

            // `emit` borrows a clone, so `tx` itself is still usable for the close.
            let send = |payload: SsePayload| {
                let _ = tx.try_send(AgentEvent::Final {
                    payload: serde_json::to_string(&payload).unwrap_or_else(|_| "{}".into()),
                });
            };

            match outcome {
                Ok(result) => {
                    if let Some(text) = result.content {
                        send(SsePayload::TextDelta { text });
                    }
                    if !result.citations.is_empty() {
                        send(SsePayload::CitationBlock {
                            citations: result.citations,
                        });
                    }
                    send(SsePayload::Done {
                        message_id: result.message_id.to_string(),
                    });
                }
                Err(e) => send(SsePayload::Error {
                    message: e.to_string(),
                }),
            }
        });

        let progress = tokio_stream::wrappers::ReceiverStream::new(rx).map(|event| {
            let json = match event {
                AgentEvent::ToolStart { name } => {
                    serde_json::to_string(&SsePayload::ToolStart { name })
                }
                AgentEvent::ToolEnd { name, is_error } => {
                    serde_json::to_string(&SsePayload::ToolEnd { name, is_error })
                }
                AgentEvent::RoundStart { round } => {
                    serde_json::to_string(&SsePayload::Round { round })
                }
                // Already serialised by the producer, which is where the concrete
                // payload type is known.
                AgentEvent::Final { payload } => Ok(payload),
            };
            Ok(Event::default().data(json.unwrap_or_else(|_| "{}".into())))
        });

        Box::pin(progress)
    };

    // `X-Accel-Buffering: no` is the portable half of the fix: it tells nginx (and
    // anything honouring the convention) not to buffer this response. The nginx
    // location also sets `proxy_buffering off`, because a proxy that does neither
    // turns every progress frame into one flush at the end - measured 2026-11-03,
    // 22 frames arriving simultaneously after a 6.4s stall.
    //
    // keep_alive closes the LAST gap in the "no feedback" complaint. The progress
    // frames mark every tool boundary, but between a round start and the next tool
    // the MODEL is generating and emits nothing - measured 2026-11-04, a long
    // document-check turn went 24.7s with the connection silent, which reads as a
    // hang even though work is happening. A 10s comment ping keeps the stream live
    // (and stops an idle proxy from dropping a slow turn) without touching the event
    // logic: it only fires when no real frame has gone out in the interval.
    let sse = Sse::new(event_stream).keep_alive(
        KeepAlive::new()
            .interval(std::time::Duration::from_secs(10))
            .text("keep-alive"),
    );
    let mut response = sse.into_response();
    response
        .headers_mut()
        .insert("x-accel-buffering", "no".parse().unwrap());
    response
        .headers_mut()
        .insert(axum::http::header::CACHE_CONTROL, "no-store".parse().unwrap());
    response
}
