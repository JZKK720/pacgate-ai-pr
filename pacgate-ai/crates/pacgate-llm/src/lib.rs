//! pacgate-llm — Three-tier LLM router with OpenAI-compatible streaming API.
//!
//! Supports local Ollama (AMD RyzenAI NPU/GPU), Anthropic, OpenAI, Qwen (DashScope),
//! DeepSeek, and any custom OpenAI-compatible endpoint.

use std::pin::Pin;

use anyhow::Context;
use async_trait::async_trait;
use futures::Stream;
use pacgate_core::{
    LlmProvider, LlmTier, ModelConfig, PacgateError, Result, ToolCall,
};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::{debug, instrument};

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI-compatible request / response types
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role:    String,
    pub content: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<OaiToolCall>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaiToolCall {
    pub id:       String,
    #[serde(rename = "type")]
    pub kind:     String,
    pub function: OaiFunctionCall,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaiFunctionCall {
    pub name:      String,
    pub arguments: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaiTool {
    #[serde(rename = "type")]
    pub kind:     String,
    pub function: OaiFunctionDef,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OaiFunctionDef {
    pub name:        String,
    pub description: String,
    pub parameters:  serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model:       String,
    pub messages:    Vec<ChatMessage>,
    pub max_tokens:  u32,
    pub temperature: f32,
    pub stream:      bool,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub tools:       Vec<OaiTool>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChatResponse {
    pub choices: Vec<Choice>,
    pub usage:   Option<Usage>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Choice {
    pub message:       Option<ChoiceMessage>,
    pub delta:         Option<ChoiceMessage>,
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChoiceMessage {
    pub role:        Option<String>,
    pub content:     Option<String>,
    pub tool_calls:  Option<Vec<OaiToolCall>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Usage {
    pub prompt_tokens:     u32,
    pub completion_tokens: u32,
    pub total_tokens:      u32,
}

// ─────────────────────────────────────────────────────────────────────────────
// Streaming delta events
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LlmStreamEvent {
    TextDelta    { text:      String },
    ToolCallStart { id: String, name: String },
    ToolCallDelta { id: String, arguments_chunk: String },
    ToolCallEnd  { id: String },
    Done         { usage: Option<Usage> },
}

pub type LlmStream = Pin<Box<dyn Stream<Item = Result<LlmStreamEvent>> + Send>>;

// ─────────────────────────────────────────────────────────────────────────────
// LlmClient trait
// ─────────────────────────────────────────────────────────────────────────────

#[async_trait]
pub trait LlmClient: Send + Sync {
    /// Non-streaming completion (for low-tier, title generation, etc.)
    async fn complete(
        &self,
        messages: Vec<ChatMessage>,
        tools: Vec<OaiTool>,
    ) -> Result<(Option<String>, Vec<ToolCall>)>;

    /// Streaming completion — yields SSE-like events
    async fn stream(
        &self,
        messages: Vec<ChatMessage>,
        tools: Vec<OaiTool>,
    ) -> Result<LlmStream>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic OpenAI-compatible client
// ─────────────────────────────────────────────────────────────────────────────

pub struct OpenAiCompatClient {
    http:       Client,
    base_url:   String,
    api_key:    String,
    model:      String,
    max_tokens: u32,
    temperature: f32,
}

impl OpenAiCompatClient {
    pub fn new(
        base_url:    impl Into<String>,
        api_key:     impl Into<String>,
        model:       impl Into<String>,
        max_tokens:  u32,
        temperature: f32,
    ) -> Self {
        // Total-request timeout: covers the entire call including body read.
        // Long legal-document generations can take several minutes on local
        // models; 10 minutes is a hard ceiling that converts an indefinite
        // hang into a clean, diagnosable error.
        Self {
            http: Client::builder()
                .timeout(std::time::Duration::from_secs(600))
                .build()
                .expect("reqwest client"),
            base_url:    base_url.into(),
            api_key:     api_key.into(),
            model:       model.into(),
            max_tokens,
            temperature,
        }
    }

    fn chat_url(&self) -> String {
        format!("{}/v1/chat/completions", self.base_url.trim_end_matches('/'))
    }
}

#[async_trait]
impl LlmClient for OpenAiCompatClient {
    #[instrument(skip_all, fields(model = %self.model))]
    async fn complete(
        &self,
        messages: Vec<ChatMessage>,
        tools:    Vec<OaiTool>,
    ) -> Result<(Option<String>, Vec<ToolCall>)> {
        let req = ChatRequest {
            model:       self.model.clone(),
            messages,
            max_tokens:  self.max_tokens,
            temperature: self.temperature,
            stream:      false,
            tools,
        };

        debug!(url = %self.chat_url(), "LLM complete request");

        let resp = self
            .http
            .post(self.chat_url())
            .bearer_auth(&self.api_key)
            .json(&req)
            .send()
            .await
            .map_err(|e| {
                PacgateError::LlmError(format!(
                    "LLM HTTP request failed: model={} url={} error={}",
                    self.model,
                    self.chat_url(),
                    e
                ))
            })?
            .error_for_status()
            .map_err(|e| {
                PacgateError::LlmError(format!(
                    "LLM HTTP status: model={} url={} error={}",
                    self.model,
                    self.chat_url(),
                    e
                ))
            })?
            .json::<ChatResponse>()
            .await
            .map_err(|e| {
                PacgateError::LlmError(format!(
                    "LLM JSON decode failed: model={} url={} error={}",
                    self.model,
                    self.chat_url(),
                    e
                ))
            })?;

        let choice = resp.choices.into_iter().next().ok_or_else(|| {
            PacgateError::LlmError("empty choices".into())
        })?;

        let msg = choice.message.unwrap_or(ChoiceMessage {
            role:       None,
            content:    None,
            tool_calls: None,
        });

        let tool_calls = msg
            .tool_calls
            .unwrap_or_default()
            .into_iter()
            .map(|tc| ToolCall {
                id:        tc.id,
                tool_name: tc.function.name,
                arguments: serde_json::from_str(&tc.function.arguments)
                    .unwrap_or(serde_json::Value::Null),
            })
            .collect();

        Ok((msg.content, tool_calls))
    }

    #[instrument(skip_all, fields(model = %self.model))]
    async fn stream(
        &self,
        messages: Vec<ChatMessage>,
        tools:    Vec<OaiTool>,
    ) -> Result<LlmStream> {
        use futures::StreamExt;

        let req = ChatRequest {
            model:       self.model.clone(),
            messages,
            max_tokens:  self.max_tokens,
            temperature: self.temperature,
            stream:      true,
            tools,
        };

        let response = self
            .http
            .post(self.chat_url())
            .bearer_auth(&self.api_key)
            .json(&req)
            .send()
            .await
            .context("LLM stream request")?
            .error_for_status()
            .context("LLM stream status")?;

        let byte_stream = response.bytes_stream();

        let event_stream = byte_stream.map(move |chunk_result| {
            let chunk = chunk_result.map_err(|e| PacgateError::LlmError(e.to_string()))?;
            let text  = String::from_utf8_lossy(&chunk);

            // Parse SSE lines: "data: {...}" or "data: [DONE]"
            for line in text.lines() {
                let line = line.trim();
                if let Some(payload) = line.strip_prefix("data: ") {
                    if payload == "[DONE]" {
                        return Ok(LlmStreamEvent::Done { usage: None });
                    }
                    if let Ok(resp) = serde_json::from_str::<ChatResponse>(payload) {
                        if let Some(choice) = resp.choices.first() {
                            if let Some(delta) = &choice.delta {
                                if let Some(text) = &delta.content {
                                    return Ok(LlmStreamEvent::TextDelta { text: text.clone() });
                                }
                                // Tool call deltas are handled by callers accumulating chunks
                            }
                        }
                    }
                }
            }
            Ok(LlmStreamEvent::Done { usage: None })
        });

        Ok(Box::pin(event_stream))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// LLM Router — resolves tiers to concrete clients
// ─────────────────────────────────────────────────────────────────────────────

/// Builds an `OpenAiCompatClient` from a `ModelConfig` and optional API key.
pub fn client_from_config(
    config:  &ModelConfig,
    api_key: &str,
) -> Box<dyn LlmClient> {
    let (base_url, key) = match &config.provider {
        LlmProvider::Ollama { base_url } => (base_url.clone(), "ollama".to_string()),
        LlmProvider::Anthropic           => (
            "https://api.anthropic.com".into(),
            api_key.to_string(),
        ),
        LlmProvider::OpenAI              => (
            "https://api.openai.com".into(),
            api_key.to_string(),
        ),
        LlmProvider::Qwen                => (
            "https://dashscope-intl.aliyuncs.com/compatible-mode".into(),
            api_key.to_string(),
        ),
        LlmProvider::DeepSeek            => (
            "https://api.deepseek.com".into(),
            api_key.to_string(),
        ),
        LlmProvider::MiniMax             => (
            "https://api.minimaxi.chat/v1".into(),
            api_key.to_string(),
        ),
        LlmProvider::Custom { base_url, .. } => (base_url.clone(), api_key.to_string()),
    };

    Box::new(OpenAiCompatClient::new(
        base_url,
        key,
        &config.model_name,
        config.max_tokens,
        config.temperature,
    ))
}

/// Three-tier router that selects the right client based on requested tier.
pub struct LlmRouter {
    configs:  Vec<ModelConfig>,
    /// BYOK: per-provider API keys, keyed by provider name
    api_keys: std::collections::HashMap<String, String>,
}

impl LlmRouter {
    pub fn new(
        configs:  Vec<ModelConfig>,
        api_keys: std::collections::HashMap<String, String>,
    ) -> Self {
        Self { configs, api_keys }
    }

    pub fn with_defaults() -> Self {
        Self {
            configs:  ModelConfig::default_local(),
            api_keys: std::collections::HashMap::new(),
        }
    }

    fn config_for_tier(&self, tier: LlmTier) -> Option<&ModelConfig> {
        self.configs.iter().find(|c| c.tier == tier)
    }

    fn api_key_for(&self, provider: &LlmProvider) -> &str {
        let key = match provider {
            LlmProvider::Anthropic            => "anthropic",
            LlmProvider::OpenAI               => "openai",
            LlmProvider::Qwen                 => "qwen",
            LlmProvider::DeepSeek             => "deepseek",
            LlmProvider::MiniMax              => "minimax",
            LlmProvider::Custom { name, .. }  => name.as_str(),
            LlmProvider::Ollama { .. }        => return "",
        };
        self.api_keys.get(key).map(|s| s.as_str()).unwrap_or("")
    }

    /// Get a client for the requested tier, falling back to Mid then Low.
    pub fn get(&self, tier: LlmTier) -> Result<Box<dyn LlmClient>> {
        let fallback_chain = match tier {
            LlmTier::Main => vec![LlmTier::Main, LlmTier::Mid, LlmTier::Low],
            LlmTier::Mid  => vec![LlmTier::Mid, LlmTier::Low],
            LlmTier::Low  => vec![LlmTier::Low],
        };
        for t in fallback_chain {
            if let Some(cfg) = self.config_for_tier(t) {
                let key = self.api_key_for(&cfg.provider).to_string();
                return Ok(client_from_config(cfg, &key));
            }
        }
        Err(PacgateError::LlmError(format!("no model config for tier {tier:?}")))
    }
}

#[cfg(test)]
mod router_tests {
    use super::*;
    use pacgate_core::{LlmProvider, LlmTier, ModelConfig};

    fn ollama_config(tier: LlmTier, model: &str, base: &str) -> ModelConfig {
        ModelConfig {
            tier,
            provider: LlmProvider::Ollama {
                base_url: base.to_string(),
            },
            model_name: model.to_string(),
            max_tokens: 4096,
            temperature: 0.1,
        }
    }

    #[test]
    fn router_honors_override_configs() {
        let base = "http://host.docker.internal:11434";
        let configs = vec![
            ollama_config(LlmTier::Main, "gemma4:12b-it-qat", base),
            ollama_config(LlmTier::Mid, "gemma4:12b-it-qat", base),
            ollama_config(LlmTier::Low, "gemma4:12b-it-qat", base),
        ];
        let router = LlmRouter::new(configs, std::collections::HashMap::new());

        // get() builds a client from the override config — the client must
        // target the override base URL and model, not the defaults.
        let client = router.get(LlmTier::Main).expect("main tier must resolve");
        // LlmClient is a trait object; verify indirectly via complete() URL is
        // not possible without a server. Instead assert the router accepted
        // the override configs by resolving all tiers.
        let _mid = router.get(LlmTier::Mid).expect("mid tier must resolve");
        let _low = router.get(LlmTier::Low).expect("low tier must resolve");
        drop(client);
    }

    #[test]
    fn router_falls_back_from_main_to_mid_to_low() {
        let configs = vec![
            ollama_config(LlmTier::Mid, "m", "http://localhost:11434"),
            ollama_config(LlmTier::Low, "l", "http://localhost:11434"),
        ];
        let router = LlmRouter::new(configs, std::collections::HashMap::new());
        // Main missing → falls back to Mid without error.
        assert!(router.get(LlmTier::Main).is_ok());
    }

    #[test]
    fn router_errors_when_no_tiers_configured() {
        let router = LlmRouter::new(vec![], std::collections::HashMap::new());
        assert!(router.get(LlmTier::Low).is_err());
    }
}
