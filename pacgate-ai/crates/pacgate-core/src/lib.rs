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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum LlmTier {
    /// High-capability model — deep analysis, contract review, complex reasoning.
    #[default]
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
// SOUL persona types (identity overlay, not workflow component)
// ─────────────────────────────────────────────────────────────────────────────

/// A SOUL persona — defines a user's AI identity, behavioral rules, and output format.
/// This is an identity overlay that wraps the agent's system prompt.
/// Workflows stay identity-agnostic; the SOUL only affects prompt + enforcement.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SoulPersona {
    pub id:              PersonaId,
    pub name:            String,
    /// If bound to a specific user (None = reusable across users)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_id:         Option<UserId>,
    /// Identity modes — triggered by context (which workflow/matter type)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identity_modes:  Vec<IdentityMode>,
    /// Core values the persona adheres to
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub core_values:     Vec<String>,
    /// Hard boundary rules (red lines)
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub boundary_rules:  Vec<BoundaryRule>,
    /// Output format for agent responses
    #[serde(default)]
    pub output_format:   OutputFormat,
    /// Escalation rules — who to escalate to and when
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub escalation_rules: Vec<EscalationRule>,
    /// System prompt preamble — injected before the workflow's system prompt
    pub system_preamble: String,
    /// Description of this SOUL
    pub description:     String,
    /// Model tier preference for this persona (Main/Mid/Low)
    #[serde(default)]
    pub model_tier:      LlmTier,
    /// Security level (A-E from the role pyramid)
    #[serde(default)]
    pub security_level:  SecurityLevel,
}

/// An identity mode within a SOUL — e.g., Justin's triple-role switching.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityMode {
    /// Mode name (e.g., "managing_partner_assistant")
    pub name:          String,
    /// When to activate this mode (e.g., "when reviewing M&A documents")
    pub trigger:       String,
    /// Thinking mode for this identity (e.g., "analytical", "coordination")
    pub thinking_mode: String,
    /// Brief description of this mode's behavior
    pub description:   String,
}

/// A boundary rule (red line) — what the agent must not do.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BoundaryRule {
    /// The rule text (e.g., "No legal conclusion without partner review")
    pub rule:              String,
    /// Where this rule is enforced
    pub enforcement_point: EnforcementPoint,
}

/// Where a boundary rule is enforced.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum EnforcementPoint {
    /// Enforced by pacgate-auth middleware before/after API calls
    #[default]
    ApiMiddleware,
    /// Enforced via system prompt instruction to the agent
    AgentPrompt,
    /// Enforced as a workflow checkpoint/gate
    WorkflowGate,
}

/// Output format for agent responses.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum OutputFormat {
    /// Justin's format: conclusion / options / recommendation
    Decision3Part,
    /// Sylvie's format: 结论 / 依据 / 待确认事项
    LegalOpinion3Part,
    /// Standard legal output (no special formatting)
    #[default]
    Standard,
}

/// An escalation rule — when and where to escalate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EscalationRule {
    /// Condition text (e.g., "risk >= P2" or "any P0 finding")
    pub condition:  String,
    /// Target role to escalate to (e.g., "partner", "lead_lawyer")
    pub target_role: String,
    /// Whether escalation blocks the workflow or is advisory
    pub blocking:   bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Legal domain enums (from client assets)
// ─────────────────────────────────────────────────────────────────────────────

/// Source level — the 4-level source grading from the client's requirements.
/// Tags every RAG chunk and agent output with its provenance.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SourceLevel {
    /// 法规原文, 官方解读 — highest authority
    AuthorityVerified,
    /// 元典, 北大法宝 — auxiliary legal databases
    AuxiliaryDB,
    /// Firm templates, playbooks, historical samples
    InternalTemplate,
    /// AI-generated content — lowest authority
    #[default]
    ModelInference,
}

/// Review status — the 3-state labeling from the client's requirements.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStatus {
    /// 有问题 — issue found
    HasIssue,
    /// 无问题 — no issue
    NoIssue,
    /// 资料不足 — insufficient data
    #[default]
    InsufficientData,
}

/// Security level — A-E from the client's role pyramid.
/// Controls what actions a user can perform.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SecurityLevel {
    /// Partner — full access, can sign off
    LevelA,
    /// Lead lawyer — matter-level access
    LevelB,
    /// Handling lawyer — task-level access
    LevelC,
    /// Assistant — read-only
    LevelD,
    /// Intern — supervised read-only
    #[default]
    LevelE,
}

/// Risk grade — from the client's evaluation framework.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RiskGrade {
    /// No risk
    #[default]
    Green,
    /// Moderate risk
    Yellow,
    /// High risk
    Red,
}

// ─────────────────────────────────────────────────────────────────────────────
// Project archive taxonomy (from 百宸完整项目及事项档案提交目录与整理说明 v1.0)
// ─────────────────────────────────────────────────────────────────────────────

/// Data classification tier — the T1-T4 system from the client's archive standard.
///
/// Controls access scope and sharing rules for all documents and RAG chunks.
/// Maps directly to the firm's local-deployment security model.
///
/// | Tier | Name | Scope |
/// |------|------|-------|
/// | T1 | 全所共享模板 | Blank templates, standard texts — shared template zone |
/// | T2 | 所内受限种子 | Completed project deliverables — restricted, no cross-project search by default |
/// | T3 | 项目专属资料 | Active project files, client data — project space only (MatterId-scoped) |
/// | T4 | 特别敏感资料 | Major dispute strategy, internal investigations — special approval, strict isolation |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DataLevel {
    /// T1 — 全所共享模板: blank templates, standard texts, methodology.
    /// No client/project identity. Can enter shared template zone.
    T1SharedTemplate,
    /// T2 — 所内受限种子: completed project deliverables (reports, agreements, filings).
    /// Retains client context. Restricted seed zone, no default cross-project search.
    #[default]
    T2RestrictedSeed,
    /// T3 — 项目专属资料: active project files, client data, evidence, communications.
    /// Project space only (MatterId-scoped). Never enters template zone or training set.
    T3ProjectSpecific,
    /// T4 — 特别敏感资料: major dispute strategy, internal investigations, bulk PII.
    /// Special approval required. Strict isolation. National secrets excluded entirely.
    T4SpecialSensitive,
}

impl DataLevel {
    /// Returns true if this data level allows cross-project search.
    /// Only T1 is freely searchable across projects.
    pub fn allows_cross_project_search(&self) -> bool {
        matches!(self, DataLevel::T1SharedTemplate)
    }

    /// Returns true if this data level requires matter-scoped access control.
    /// T2 and above require matter-level isolation.
    pub fn requires_matter_scoping(&self) -> bool {
        !matches!(self, DataLevel::T1SharedTemplate)
    }

    /// Returns the string code (e.g., "T1", "T2") for DB storage.
    pub fn code(&self) -> &'static str {
        match self {
            DataLevel::T1SharedTemplate => "T1",
            DataLevel::T2RestrictedSeed => "T2",
            DataLevel::T3ProjectSpecific => "T3",
            DataLevel::T4SpecialSensitive => "T4",
        }
    }

    /// Parse a T-code string into a DataLevel.
    pub fn from_code(code: &str) -> Option<Self> {
        match code.trim() {
            "T1" | "t1" => Some(DataLevel::T1SharedTemplate),
            "T2" | "t2" => Some(DataLevel::T2RestrictedSeed),
            "T3" | "t3" => Some(DataLevel::T3ProjectSpecific),
            "T4" | "t4" => Some(DataLevel::T4SpecialSensitive),
            _ => None,
        }
    }
}

impl std::fmt::Display for DataLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.code())
    }
}

/// Archive directory — the 9-directory submission taxonomy (目录编号 00-08).
///
/// Each project/case archive is organized into these directories.
/// From 百宸完整项目及事项档案提交目录与整理说明 v1.0 §二.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArchiveDirectory {
    /// 00 — 项目说明及文件目录: project overview, file index, language/jurisdiction/role.
    /// 必交 (mandatory for all projects).
    Directory00Overview,
    /// 01 — 核心律师工作成果: DD reports, legal opinions, memos, litigation strategy.
    /// 必交 — the main deliverables.
    Directory01CoreWork,
    /// 02 — 主要协议及程序文书: transaction agreements, corporate docs, litigation filings.
    /// 必交 — core legal instruments.
    Directory02Agreements,
    /// 03 — 关键修改稿及工作工具: red-line drafts, issue lists, negotiation points, evidence matrices.
    /// 有则提交 — representative versions only.
    Directory03DraftsTools,
    /// 04 — 决策批准及监管文件: board/shareholder approvals, regulatory filings, hearing materials.
    /// 有则提交.
    Directory04Approvals,
    /// 05 — 签署、交割、庭审或执行文件: signing pages, closing certificates, trial outlines.
    /// 有则提交.
    Directory05Closing,
    /// 06 — 最终交付及Closing Binder: final signed versions, closing binders, judgments.
    /// 有则提交 — cannot substitute for 01-05.
    Directory06FinalDelivery,
    /// 07 — 关键事实和证据附件: supporting facts and evidence — selective, not full data room.
    Directory07Evidence,
    /// 08 — 覆盖映射及复核记录: template coverage mapping, quality review records.
    /// By reviewer/summarizer.
    Directory08CoverageReview,
}

impl ArchiveDirectory {
    /// Returns the directory number as a string (e.g., "00", "01").
    pub fn number(&self) -> &'static str {
        match self {
            ArchiveDirectory::Directory00Overview => "00",
            ArchiveDirectory::Directory01CoreWork => "01",
            ArchiveDirectory::Directory02Agreements => "02",
            ArchiveDirectory::Directory03DraftsTools => "03",
            ArchiveDirectory::Directory04Approvals => "04",
            ArchiveDirectory::Directory05Closing => "05",
            ArchiveDirectory::Directory06FinalDelivery => "06",
            ArchiveDirectory::Directory07Evidence => "07",
            ArchiveDirectory::Directory08CoverageReview => "08",
        }
    }

    /// Returns the Chinese name of this directory.
    pub fn name_zh(&self) -> &'static str {
        match self {
            ArchiveDirectory::Directory00Overview => "项目说明及文件目录",
            ArchiveDirectory::Directory01CoreWork => "核心律师工作成果",
            ArchiveDirectory::Directory02Agreements => "主要协议及程序文书",
            ArchiveDirectory::Directory03DraftsTools => "关键修改稿及工作工具",
            ArchiveDirectory::Directory04Approvals => "决策批准及监管文件",
            ArchiveDirectory::Directory05Closing => "签署、交割、庭审或执行文件",
            ArchiveDirectory::Directory06FinalDelivery => "最终交付及Closing Binder/结案卷",
            ArchiveDirectory::Directory07Evidence => "关键事实和证据附件",
            ArchiveDirectory::Directory08CoverageReview => "覆盖映射及复核记录",
        }
    }

    /// Returns whether this directory is mandatory (必交) for all projects.
    pub fn is_mandatory(&self) -> bool {
        matches!(
            self,
            ArchiveDirectory::Directory00Overview
                | ArchiveDirectory::Directory01CoreWork
                | ArchiveDirectory::Directory02Agreements
        )
    }
}

impl std::fmt::Display for ArchiveDirectory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}_{}", self.number(), self.name_zh())
    }
}

/// Project business module — the 5 practice areas from the archive standard.
///
/// From 百宸五大业务代表性项目及事项档案第一阶段认领清单 v1.0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ProjectBusinessModule {
    /// 非诉交易 — non-litigation transactions, VIE/red-chip, investment agreements.
    #[default]
    NonLitigation,
    /// 基金 — fund formation, fundraising, filing, investment, operations, dissolution.
    Fund,
    /// 律师日常通用 — daily general legal matters, client advisory.
    DailyGeneral,
    /// 合规 — compliance projects (risk identification → analysis → policy → implementation → review).
    Compliance,
    /// 诉讼/仲裁/执行 — litigation, arbitration, enforcement.
    Litigation,
}

/// Project overview metadata — the 项目概况表 from the archive standard §三.
///
/// Every project archive package must include this in directory 00.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectOverview {
    /// Project package number (PN编号 from the 认领清单).
    pub package_number: String,
    /// Short name or internal code (项目简称/内部编号).
    pub short_name: String,
    /// Business module and project type (业务模块及项目类型).
    pub business_module: ProjectBusinessModule,
    /// Primary stage: closed, completed, filed, adjudicated, liquidated, etc. (项目主要阶段).
    pub primary_stage: String,
    /// Time range of the project's main work (时间范围).
    pub time_range: String,
    /// Client and the firm's role (客户及本所角色).
    pub client_and_role: String,
    /// Jurisdiction and industry (法域和行业).
    pub jurisdiction_and_industry: String,
    /// Language(s) and which version is controlling (语言).
    pub language: String,
    /// Lead lawyer and reviewer (项目主办及复核人).
    pub lead_and_reviewer: String,
    /// Data classification level T1-T4 (资料使用等级).
    pub data_level: DataLevel,
    /// File source and usage permissions (文件来源和权限).
    pub source_and_permissions: String,
    /// Project highlights and limitations (项目亮点和限制).
    pub highlights_and_limitations: String,
}

/// File directory entry — the 文件目录表 from the archive standard §四.
///
/// Each project archive must include a file directory with these fields.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileDirectoryEntry {
    /// Sequence number (序号).
    pub seq: u32,
    /// Relative path / filename (相对路径/文件名).
    pub relative_path: String,
    /// File category (文件类别).
    pub category: String,
    /// Version and date (版本和日期).
    pub version_and_date: String,
    /// Language / jurisdiction / position (语言/法域/立场).
    pub language_jurisdiction_position: String,
    /// File source (文件来源).
    pub source: String,
    /// Data classification level (资料等级).
    pub data_level: DataLevel,
    /// Corresponding template number (对应模板编号).
    pub template_number: String,
    /// Notes (备注).
    pub notes: String,
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
