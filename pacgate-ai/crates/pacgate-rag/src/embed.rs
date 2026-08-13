//! Embedding service — generates text embeddings via Ollama's nomic-embed-text model.
//!
//! Uses Ollama's OpenAI-compatible /v1/embeddings endpoint.
//! The nomic-embed-text model produces 768-dimensional vectors.

use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::instrument;

use crate::RagError;

pub struct EmbeddingService {
    client: Client,
    base_url: String,
    model: String,
}

#[derive(Serialize)]
struct EmbedRequest {
    model: String,
    input: String,
}

#[derive(Deserialize)]
struct EmbedResponse {
    data: Vec<EmbedData>,
}

#[derive(Deserialize)]
struct EmbedData {
    embedding: Vec<f32>,
}

impl EmbeddingService {
    pub fn new(base_url: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(60))
                .build()
                .expect("reqwest client"),
            base_url: base_url.into(),
            model: model.into(),
        }
    }

    /// Create with default Ollama config.
    pub fn with_defaults() -> Self {
        let base_url = std::env::var("OLLAMA_BASE_URL")
            .unwrap_or_else(|_| "http://localhost:11434".to_string());
        Self::new(
            base_url,
            "nomic-embed-text:latest",
        )
    }

    /// Generate an embedding for a single text input.
    #[instrument(skip(self, text), fields(model = %self.model, text_len = text.len()))]
    pub async fn embed(&self, text: &str) -> Result<Vec<f32>, RagError> {
        let url = format!("{}/v1/embeddings", self.base_url.trim_end_matches('/'));

        let req = EmbedRequest {
            model: self.model.clone(),
            input: text.to_string(),
        };

        let resp = self
            .client
            .post(&url)
            .json(&req)
            .send()
            .await
            .map_err(|e| RagError::Embedding(format!("request failed: {e}")))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(RagError::Embedding(format!(
                "embedding API returned {status}: {body}"
            )));
        }

        let embed_resp: EmbedResponse = resp
            .json()
            .await
            .map_err(|e| RagError::Embedding(format!("parse failed: {e}")))?;

        embed_resp
            .data
            .into_iter()
            .next()
            .map(|d| d.embedding)
            .ok_or_else(|| RagError::Embedding("no embedding in response".into()))
    }

    /// Generate embeddings for multiple texts in a batch.
    pub async fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, RagError> {
        // Ollama supports batch input, but we do it one at a time for reliability
        let mut embeddings = Vec::with_capacity(texts.len());
        for text in texts {
            embeddings.push(self.embed(text).await?);
        }
        Ok(embeddings)
    }
}