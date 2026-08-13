//! pacgate-core — Shared types, traits, and error definitions for the Pacgate Legal AI platform.
//!
//! Every other crate in the workspace depends on this crate. Keep it dependency-light.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────────────────
// Identifier new-types
// ─────────────────────────────────────────────────────────────────────────────

macro_rules! typed_id {
    ($name:ident) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub struct $name(pub Uuid);

        impl $name {
            pub fn new() -> Self {
                Self(Uuid::new_v4())
            }
            pub fn as_str(&self) -> String {
                self.0.to_string()
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "{}", self.0)
            }
        }

        impl std::str::FromStr for $name {
            type Err = uuid::Error;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Ok(Self(s.parse()?))
            }
        }
    };
}

typed_id!(DocumentId);
typed_id!(MatterId);
typed_id!(PersonaId);
typed_id!(WorkflowId);
typed_id!(TenantId);
typed_id!(UserId);
typed_id!(TemplateId);
typed_id!(MessageId);
typed_id!(ConversationId);
typed_id!(KbItemId);

// ─────────────────────────────────────────────────────────────────────────────
// LLM types
// ─────────────────────────────────────────────────────────────────────────────

/// The three-tier model strategy (Main / Mid / Low) mapping to different
/// capability/cost trade-offs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmTier {
    /// High-capability model — deep analysis, contract review, complex reasoning.
    Main,
    /// Mid-capability model — tabular review, batch extraction, structured output.
    Mid,
    /// Low-capability model — title generation, short summaries, labelling.
    Low,
}

/// Supported LLM providers with OpenAI-compatible chat completion APIs.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LlmProvider {
    /// Local Ollama endpoint (zero token cost, AMD NPU/GPU accelerated)
    Ollama { base_url: String },
    /// Anthropic Claude Sonnet 4.6 via API
    Anthropic,
    /// OpenAI GPT-5.4 via API
    OpenAI,
    /// Alibaba Qwen3.6 via DashScope (OpenAI-compatible)
    Qwen,
    /// DeepSeek-V4 via API
    DeepSeek,
    /// MiniMax-2.7 (abab7.5s) via API — China domestic LLM
    MiniMax,
    /// Custom OpenAI-compatible endpoint
    Custom { base_url: String, name: String },
}

/// A model config entry binding a tier to a concrete model name and provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    pub tier:       LlmTier,
    pub provider:   LlmProvider,
    pub model_name: String,
    /// Maximum tokens to request in a completion
    pub max_tokens: u32,
    /// Temperature (0.0–1.0)
    pub temperature: f32,
}

impl ModelConfig {
    /// Returns the default three-tier config using local Ollama.
    ///
    /// | Tier | Model          | Use case                                          |
    /// |------|----------------|---------------------------------------------------|
    /// | Main | nemotron3:33b  | Deep-think · contract review · generative agents  |
    /// | Mid  | qwen3.6:27b    | Agent automation · tabular review · core tasks    |
    /// | Low  | qwen3.5:9b     | Fast labels · short summaries · routing           |
    pub fn default_local() -> Vec<Self> {
        vec![
            ModelConfig {
                tier: LlmTier::Main,
                provider: LlmProvider::Ollama {
                    base_url: "http://localhost:11434".into(),
                },
                model_name: "nemotron3:33b".into(),
                max_tokens: 16384,
                temperature: 0.1,
            },
            ModelConfig {
                tier: LlmTier::Mid,
                provider: LlmProvider::Ollama {
                    base_url: "http://localhost:11434".into(),
                },
                model_name: "qwen3.6:27b".into(),
                max_tokens: 8192,
                temperature: 0.1,
            },
            ModelConfig {
                tier: LlmTier::Low,
                provider: LlmProvider::Ollama {
                    base_url: "http://localhost:11434".into(),
                },
                model_name: "qwen3.5:9b".into(),
                max_tokens: 4096,
                temperature: 0.2,
            },
        ]
    }

    /// Full local model roster available for per-tenant assignment via `TenantConfig::model_overrides`.
    ///
    /// Returns `(ollama_tag, description)` pairs.
    pub fn local_model_roster() -> &'static [(&'static str, &'static str)] {
        &[
            ("nemotron3:33b",  "Deep-think · generative AI agents · complex contract review"),
            ("gemma4:26b",     "Efficient reasoning · document analysis · structured output"),
            ("gemma4:e2b",     "Efficient variant · fast structured extraction"),
            ("qwen3.5:35b",    "Strong general · multilingual ZH/EN · cross-border matters"),
            ("qwen3.5:9b",     "Mid-weight general · fast turnaround · Low-tier default"),
            ("qwen3.6:27b",    "Agent automation · OpenClaw pipelines · Mid-tier default"),
            ("qwen3.6:25b",    "Agent variant · workflow execution · Hermes scheduled tasks"),
        ]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent / tool types
// ─────────────────────────────────────────────────────────────────────────────

/// A structured tool call as emitted by the LLM in its response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id:        String,
    pub tool_name: String,
    pub arguments: serde_json::Value,
}

/// Result of executing a tool, returned back to the LLM as a tool result message.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResult {
    pub tool_call_id: String,
    pub content:      serde_json::Value,
    pub is_error:     bool,
}

/// A single message in an agent conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "role", rename_all = "snake_case")]
pub enum AgentMessage {
    System {
        content: String,
    },
    User {
        id:      MessageId,
        content: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attachments: Vec<DocumentId>,
    },
    Assistant {
        id:         MessageId,
        content:    Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        tool_calls: Vec<ToolCall>,
    },
    Tool {
        tool_call_id: String,
        content:      serde_json::Value,
        is_error:     bool,
    },
}

// ─────────────────────────────────────────────────────────────────────────────
// Citation types (inline references from agent responses)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CitationRef {
    /// Inline marker index (e.g. [1], [2])
    pub ref_num:       u32,
    pub document_id:   DocumentId,
    /// 1-based page number
    pub page:          Option<u32>,
    /// Verbatim quote ≤ 25 words
    pub verbatim:      String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Document model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DocumentFormat {
    Docx,
    Pdf,
    Txt,
    Markdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Document {
    pub id:          DocumentId,
    pub matter_id:   MatterId,
    pub tenant_id:   TenantId,
    pub name:        String,
    pub format:      DocumentFormat,
    /// Monotonically increasing version number starting at 1
    pub version:     u32,
    /// Storage path relative to tenant root (e.g. "matters/{id}/docs/{name}_v1.docx")
    pub storage_path: String,
    pub created_at:  DateTime<Utc>,
    pub updated_at:  DateTime<Utc>,
    /// User who uploaded / created the document
    pub owner_id:    UserId,
}

// ─────────────────────────────────────────────────────────────────────────────
// Matter model
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Matter {
    pub id:          MatterId,
    pub tenant_id:   TenantId,
    pub name:        String,
    pub description: Option<String>,
    pub persona_id:  Option<PersonaId>,
    pub created_by:  UserId,
    pub created_at:  DateTime<Utc>,
    pub updated_at:  DateTime<Utc>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Legal jurisdiction
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Jurisdiction {
    // China & Greater China
    ChinaMainland,
    HongKong,
    Macau,
    Taiwan,
    // Common Law
    UnitedStates,
    UnitedKingdom,
    Australia,
    Canada,
    Singapore,
    India,
    Ireland,
    // Civil Law
    Germany,
    France,
    Spain,
    Italy,
    Netherlands,
    Austria,
    Switzerland,
    Belgium,
    // LATAM
    Brazil,
    Mexico,
    Argentina,
    // Asia
    Japan,
    // International
    EuropeanUnion,
    International,
}

impl Jurisdiction {
    /// ISO 3166-1 alpha-2 or region code for display
    pub fn code(&self) -> &'static str {
        match self {
            Self::ChinaMainland => "CN",
            Self::HongKong      => "HK",
            Self::Macau         => "MO",
            Self::Taiwan        => "TW",
            Self::UnitedStates  => "US",
            Self::UnitedKingdom => "GB",
            Self::Australia     => "AU",
            Self::Canada        => "CA",
            Self::Singapore     => "SG",
            Self::India         => "IN",
            Self::Ireland       => "IE",
            Self::Germany       => "DE",
            Self::France        => "FR",
            Self::Spain         => "ES",
            Self::Italy         => "IT",
            Self::Netherlands   => "NL",
            Self::Austria       => "AT",
            Self::Switzerland   => "CH",
            Self::Belgium       => "BE",
            Self::Brazil        => "BR",
            Self::Mexico        => "MX",
            Self::Argentina     => "AR",
            Self::Japan         => "JP",
            Self::EuropeanUnion => "EU",
            Self::International => "INTL",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Practice area (persona type)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PracticeArea {
    // International (from Suzie Law)
    Antitrust,
    Arbitration,
    BusinessOfLaw,
    CapitalMarkets,
    Employment,
    IntellectualProperty,
    Litigation,
    MergersAndAcquisitions,
    PrivacyData,
    RealEstate,
    Tax,
    Transactional,
    // China-specific
    ChinaLitigationArbitration,
    ChinaCorporateMA,
    ChinaLabor,
    ChinaIP,
    ChinaComplianceRegulatory,
    ChinaRealEstateConstruction,
    ChinaTax,
    CrossBorderLegal,
    // Custom
    Custom(String),
}

// ─────────────────────────────────────────────────────────────────────────────
// Tenant model
// ─────────────────────────────────────────────────────────────────────────────

/// A law firm (the tenant boundary). All matters, users, and documents
/// belong to a tenant. Per-tenant model config and security posture live
/// in `config_json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tenant {
    pub id:          TenantId,
    pub name:        String,
    /// URL-safe slug for the tenant (e.g., "baisheng-law-firm")
    pub slug:        String,
    /// Per-tenant configuration: model_overrides, security posture, branding, etc.
    #[serde(default)]
    pub config:      TenantConfig,
    pub created_at:  DateTime<Utc>,
    pub updated_at:  DateTime<Utc>,
}

/// Per-tenant configuration stored as JSONB in the tenants table.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TenantConfig {
    /// Override model assignments per LLM tier (Main/Mid/Low).
    /// If empty, the system defaults from `ModelConfig::default_local()` are used.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub model_overrides: Vec<ModelConfig>,

    /// Whether this tenant requires approval for all tool actions (ethical wall).
    #[serde(default)]
    pub strict_security_posture: bool,

    /// Allowed egress hosts for research (empty = no external access).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_egress_hosts: Vec<String>,

    /// Firm branding (name, logo URL, color scheme).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branding: Option<Branding>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Branding {
    pub display_name: Option<String>,
    pub logo_url:     Option<String>,
    pub primary_color: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Store traits (shared between pacgate-agent and pacgate-docx)
// ─────────────────────────────────────────────────────────────────────────────

use async_trait::async_trait;

/// Document storage trait — implemented by `FsDocumentStore` in `pacgate-docx`.
#[async_trait]
pub trait DocumentStore: Send + Sync {
    async fn read(&self, id: &DocumentId) -> Result<String>;
    async fn read_version(&self, id: &DocumentId, version: u32) -> Result<String>;
    async fn list_for_matter(&self, matter_id: &MatterId) -> Result<Vec<Document>>;
    async fn find_in(&self, id: &DocumentId, query: &str) -> Result<Vec<FindResult>>;
    async fn create_from_structure(
        &self,
        matter_id: &MatterId,
        filename: &str,
        structure: &serde_json::Value,
    ) -> Result<Document>;
    async fn apply_edit(
        &self,
        id: &DocumentId,
        find: &str,
        replace: &str,
        ctx_before: Option<&str>,
        ctx_after: Option<&str>,
    ) -> Result<Document>;
    async fn replicate(&self, id: &DocumentId, count: u32) -> Result<Vec<Document>>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FindResult {
    pub page: u32,
    pub context: String,
    pub match_start: usize,
    pub match_len: usize,
}

/// Workflow store trait.
#[async_trait]
pub trait WorkflowStore: Send + Sync {
    async fn get_prompt(&self, workflow_id: &str) -> Result<String>;
}

/// KB store trait.
#[async_trait]
pub trait KbStore: Send + Sync {
    async fn search(&self, matter_id: &MatterId, query: &str, top_k: u32) -> Result<Vec<KbChunk>>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KbChunk {
    pub score: f32,
    pub document_id: DocumentId,
    pub page: u32,
    pub text: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Error types
// ─────────────────────────────────────────────────────────────────────────────

use thiserror::Error;

#[derive(Debug, Error)]
pub enum PacgateError {
    #[error("document not found: {id}")]
    DocumentNotFound { id: String },

    #[error("matter not found: {id}")]
    MatterNotFound { id: String },

    #[error("tool not found: {name}")]
    ToolNotFound { name: String },

    #[error("LLM error: {0}")]
    LlmError(String),

    #[error("DOCX error: {0}")]
    DocxError(String),

    #[error("storage error: {0}")]
    StorageError(String),

    #[error("auth error: {0}")]
    AuthError(String),

    #[error("tenant error: {0}")]
    TenantError(String),

    #[error("search error: {0}")]
    SearchError(String),

    #[error("validation error: {0}")]
    ValidationError(String),

    #[error("serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),

    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

pub type Result<T, E = PacgateError> = std::result::Result<T, E>;
