//! Embedding service — generates text embeddings via Ollama's nomic-embed-text model.
//!
//! Uses Ollama's OpenAI-compatible /v1/embeddings endpoint.
//! The nomic-embed-text model produces 768-dimensional vectors.

use reqwest::Client;
use serde::{Deserialize, Serialize};
use tracing::instrument;

use crate::RagError;

#[derive(Clone)]
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

/// Batched form. `input` is an ARRAY so one HTTP request embeds many chunks.
#[derive(Serialize)]
struct EmbedBatchRequest {
    model: String,
    input: Vec<String>,
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
            // Same loopback rule as the LLM client: an embedding request to a local
            // Ollama that is sent to the machine proxy fails, and every RAG write
            // silently loses its vector.
            client: pacgate_core::http::local_service_client(Some(
                std::time::Duration::from_secs(60),
            )),
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
    ///
    /// MEASURED 2026-11-04 on the live Ollama endpoint (`nomic-embed-text`):
    ///
    /// | request                    | wall     | per chunk |
    /// |----------------------------|----------|-----------|
    /// | 1 chunk, per call          | 2,070 ms | 2,070 ms  |
    /// | 32 chunks, ONE batched call| 2,380 ms |    74 ms  |
    ///
    /// The ~2 s is fixed per-HTTP-request overhead, not compute - a 137M model
    /// does not take two seconds to embed one clause. The previous implementation
    /// looped `self.embed()` per text behind the comment "we do it one at a time
    /// for reliability", so ingesting a 300-chunk contract paid 300 round trips:
    /// about 10 minutes of pure overhead instead of ~22 seconds.
    ///
    /// Batch input is the documented Ollama behavior and it is one request, so
    /// "reliability" was buying nothing. Order is preserved: the response
    /// `data[i]` corresponds to `input[i]`.
    pub async fn embed_batch(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, RagError> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }

        let url = format!("{}/v1/embeddings", self.base_url.trim_end_matches('/'));
        let req = EmbedBatchRequest {
            model: self.model.clone(),
            input: texts.to_vec(),
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
                "HTTP {status} from {url}: {body}"
            )));
        }

        let embed_resp: EmbedResponse = resp
            .json()
            .await
            .map_err(|e| RagError::Embedding(format!("parse failed: {e}")))?;

        let out: Vec<Vec<f32>> = embed_resp.data.into_iter().map(|d| d.embedding).collect();

        // A short read would silently desynchronise chunks from vectors, which is
        // far worse than a loud error: every later chunk would carry the previous
        // chunk's embedding and retrieval would return confident nonsense.
        if out.len() != texts.len() {
            return Err(RagError::Embedding(format!(
                "expected {} embeddings, got {}",
                texts.len(),
                out.len()
            )));
        }

        Ok(out)
    }
}
