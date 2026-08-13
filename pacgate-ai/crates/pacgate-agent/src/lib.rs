//! pacgate-agent — Agent loop and tool dispatcher.
//!
//! Implements the 10-tool agent architecture (inspired by Mike's chatTools.ts),
//! rewritten in Rust with type-safe tool definitions, async execution,
//! and a citation extraction pass on assistant messages.

use std::sync::Arc;

use pacgate_core::{
    AgentMessage, CitationRef, DocumentId, LlmTier, MatterId, MessageId,
    PacgateError, Result, ToolCall, ToolResult,
};
use pacgate_llm::{ChatMessage, LlmRouter, OaiTool, OaiFunctionDef};
use serde::{Deserialize, Serialize};
use tracing::{info, instrument, warn};

// ─────────────────────────────────────────────────────────────────────────────
// Tool argument / result schemas
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ReadDocumentArgs {
    pub document_id: String,
    /// Optional version; defaults to latest
    pub version: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct FindInDocumentArgs {
    pub document_id: String,
    pub query:       String,
}

#[derive(Debug, Deserialize)]
pub struct FetchDocumentsArgs {
    pub document_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ListDocumentsArgs {
    pub matter_id: String,
}

#[derive(Debug, Deserialize)]
pub struct GenerateDocxArgs {
    pub matter_id: String,
    pub filename:  String,
    pub structure: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct EditDocumentArgs {
    pub document_id:    String,
    pub find:           String,
    pub replace:        String,
    pub context_before: Option<String>,
    pub context_after:  Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReplicateDocumentArgs {
    pub document_id: String,
    /// 1–20
    pub count: u32,
}

#[derive(Debug, Deserialize)]
pub struct ReadWorkflowArgs {
    pub workflow_id: String,
}

#[derive(Debug, Deserialize)]
pub struct ReadTableCellsArgs {
    pub matter_id:    String,
    pub document_ids: Vec<String>,
    pub columns:      Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct KbSearchArgs {
    pub matter_id: String,
    pub query:     String,
    pub top_k:     Option<u32>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Document store trait (re-exported from pacgate-core)
// ─────────────────────────────────────────────────────────────────────────────
// The trait now lives in pacgate-core to avoid cyclic dependencies
// (pacgate-docx implements DocumentStore, pacgate-agent uses it).
pub use pacgate_core::{DocumentStore, FindResult, KbChunk, KbStore, WorkflowStore};

// ─────────────────────────────────────────────────────────────────────────────
// Tool dispatcher
// ─────────────────────────────────────────────────────────────────────────────

pub struct ToolDispatcher {
    pub docs:      Arc<dyn DocumentStore>,
    pub workflows: Arc<dyn WorkflowStore>,
    pub kb:        Arc<dyn KbStore>,
}

impl ToolDispatcher {
    pub fn new(
        docs:      Arc<dyn DocumentStore>,
        workflows: Arc<dyn WorkflowStore>,
        kb:        Arc<dyn KbStore>,
    ) -> Self {
        Self { docs, workflows, kb }
    }

    #[instrument(skip(self), fields(tool = %call.tool_name))]
    pub async fn dispatch(&self, call: &ToolCall) -> ToolResult {
        let result = match call.tool_name.as_str() {
            "read_document"    => self.read_document(call).await,
            "find_in_document" => self.find_in_document(call).await,
            "fetch_documents"  => self.fetch_documents(call).await,
            "list_documents"   => self.list_documents(call).await,
            "generate_docx"    => self.generate_docx(call).await,
            "edit_document"    => self.edit_document(call).await,
            "replicate_document" => self.replicate_document(call).await,
            "read_workflow"    => self.read_workflow(call).await,
            "read_table_cells" => self.read_table_cells(call).await,
            "kb_search"        => self.kb_search(call).await,
            unknown => Err(PacgateError::ToolNotFound { name: unknown.to_string() }),
        };

        match result {
            Ok(value) => ToolResult {
                tool_call_id: call.id.clone(),
                content:      value,
                is_error:     false,
            },
            Err(e) => {
                warn!(tool = %call.tool_name, error = %e, "tool execution failed");
                ToolResult {
                    tool_call_id: call.id.clone(),
                    content:      serde_json::json!({ "error": e.to_string() }),
                    is_error:     true,
                }
            }
        }
    }

    async fn read_document(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: ReadDocumentArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let id: DocumentId = args.document_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid document_id: {e}")))?;

        let text = match args.version {
            Some(v) => self.docs.read_version(&id, v).await?,
            None    => self.docs.read(&id).await?,
        };
        Ok(serde_json::json!({ "document_id": args.document_id, "content": text }))
    }

    async fn find_in_document(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: FindInDocumentArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let id: DocumentId = args.document_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid document_id: {e}")))?;

        let results = self.docs.find_in(&id, &args.query).await?;
        Ok(serde_json::json!({ "document_id": args.document_id, "results": results }))
    }

    async fn fetch_documents(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: FetchDocumentsArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;

        let mut docs = Vec::new();
        for raw_id in &args.document_ids {
            let id: DocumentId = raw_id.parse()
                .map_err(|e| PacgateError::ValidationError(format!("invalid document_id: {e}")))?;
            let content = self.docs.read(&id).await?;
            docs.push(serde_json::json!({ "document_id": raw_id, "content": content }));
        }
        Ok(serde_json::json!({ "documents": docs }))
    }

    async fn list_documents(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: ListDocumentsArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let matter_id: MatterId = args.matter_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid matter_id: {e}")))?;

        let docs = self.docs.list_for_matter(&matter_id).await?;
        Ok(serde_json::json!({ "documents": docs }))
    }

    async fn generate_docx(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: GenerateDocxArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let matter_id: MatterId = args.matter_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid matter_id: {e}")))?;

        let doc = self.docs.create_from_structure(&matter_id, &args.filename, &args.structure).await?;
        Ok(serde_json::json!({
            "document_id": doc.id,
            "name": doc.name,
            "version": doc.version,
            "message": "Document generated. Run read_document to verify content."
        }))
    }

    async fn edit_document(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: EditDocumentArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let id: DocumentId = args.document_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid document_id: {e}")))?;

        let doc = self.docs.apply_edit(
            &id,
            &args.find,
            &args.replace,
            args.context_before.as_deref(),
            args.context_after.as_deref(),
        ).await?;

        Ok(serde_json::json!({
            "document_id": doc.id,
            "name":        doc.name,
            "new_version": doc.version,
            "message":     "Edit applied with tracked changes. Run read_document to verify."
        }))
    }

    async fn replicate_document(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: ReplicateDocumentArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;

        if args.count == 0 || args.count > 20 {
            return Err(PacgateError::ValidationError(
                "count must be between 1 and 20".into(),
            ));
        }

        let id: DocumentId = args.document_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid document_id: {e}")))?;

        let copies = self.docs.replicate(&id, args.count).await?;
        Ok(serde_json::json!({ "copies": copies }))
    }

    async fn read_workflow(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: ReadWorkflowArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let prompt = self.workflows.get_prompt(&args.workflow_id).await?;
        Ok(serde_json::json!({ "workflow_id": args.workflow_id, "prompt": prompt }))
    }

    async fn read_table_cells(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: ReadTableCellsArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        // Implementation will delegate to the tabular review engine
        Ok(serde_json::json!({
            "matter_id":    args.matter_id,
            "document_ids": args.document_ids,
            "columns":      args.columns,
            "status":       "pending"
        }))
    }

    async fn kb_search(&self, call: &ToolCall) -> Result<serde_json::Value> {
        let args: KbSearchArgs = serde_json::from_value(call.arguments.clone())
            .map_err(PacgateError::SerializationError)?;
        let matter_id: MatterId = args.matter_id.parse()
            .map_err(|e| PacgateError::ValidationError(format!("invalid matter_id: {e}")))?;

        let chunks = self.kb.search(&matter_id, &args.query, args.top_k.unwrap_or(5)).await?;
        Ok(serde_json::json!({ "chunks": chunks }))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool definitions (OpenAI function-calling schema)
// ─────────────────────────────────────────────────────────────────────────────

pub fn tool_definitions() -> Vec<OaiTool> {
    vec![
        oai_tool(
            "read_document",
            "Read the full text content of a document. Always reads the latest accepted version unless a specific version is requested.",
            serde_json::json!({
                "type": "object",
                "required": ["document_id"],
                "properties": {
                    "document_id": { "type": "string", "description": "UUID of the document" },
                    "version":     { "type": "integer", "description": "Optional version number; defaults to latest" }
                }
            }),
        ),
        oai_tool(
            "find_in_document",
            "Search for text within a document. Case-insensitive. Returns matching context snippets with page numbers.",
            serde_json::json!({
                "type": "object",
                "required": ["document_id", "query"],
                "properties": {
                    "document_id": { "type": "string" },
                    "query":       { "type": "string", "description": "Text to search for" }
                }
            }),
        ),
        oai_tool(
            "fetch_documents",
            "Fetch multiple documents at once to avoid repeated read_document calls.",
            serde_json::json!({
                "type": "object",
                "required": ["document_ids"],
                "properties": {
                    "document_ids": {
                        "type": "array",
                        "items": { "type": "string" },
                        "maxItems": 10
                    }
                }
            }),
        ),
        oai_tool(
            "list_documents",
            "List all documents in a matter so the agent can discover available resources.",
            serde_json::json!({
                "type": "object",
                "required": ["matter_id"],
                "properties": {
                    "matter_id": { "type": "string" }
                }
            }),
        ),
        oai_tool(
            "generate_docx",
            "Generate a new DOCX document from a structured JSON description. Supports heading hierarchy, legal numbering, tables, landscape pages, and signature pages.",
            serde_json::json!({
                "type": "object",
                "required": ["matter_id", "filename", "structure"],
                "properties": {
                    "matter_id": { "type": "string" },
                    "filename":  { "type": "string" },
                    "structure": { "type": "object", "description": "Document structure JSON" }
                }
            }),
        ),
        oai_tool(
            "edit_document",
            "Apply a tracked-change edit to a DOCX document. Generates Accept/Reject cards. Automatically increments version.",
            serde_json::json!({
                "type": "object",
                "required": ["document_id", "find", "replace"],
                "properties": {
                    "document_id":    { "type": "string" },
                    "find":           { "type": "string", "description": "Exact text to find" },
                    "replace":        { "type": "string", "description": "Replacement text" },
                    "context_before": { "type": "string", "description": "Up to 50 chars before the match to disambiguate" },
                    "context_after":  { "type": "string", "description": "Up to 50 chars after the match to disambiguate" }
                }
            }),
        ),
        oai_tool(
            "replicate_document",
            "Create 1–20 copies of a document (e.g. to replicate a template for multiple parties).",
            serde_json::json!({
                "type": "object",
                "required": ["document_id", "count"],
                "properties": {
                    "document_id": { "type": "string" },
                    "count": { "type": "integer", "minimum": 1, "maximum": 20 }
                }
            }),
        ),
        oai_tool(
            "read_workflow",
            "Load and execute a workflow by ID. Returns the workflow prompt to be used as additional instructions.",
            serde_json::json!({
                "type": "object",
                "required": ["workflow_id"],
                "properties": {
                    "workflow_id": { "type": "string" }
                }
            }),
        ),
        oai_tool(
            "read_table_cells",
            "Read extracted cell values from a tabular review. Each cell represents an agent answer for a document-column pair.",
            serde_json::json!({
                "type": "object",
                "required": ["matter_id", "document_ids", "columns"],
                "properties": {
                    "matter_id":    { "type": "string" },
                    "document_ids": { "type": "array", "items": { "type": "string" } },
                    "columns":      { "type": "array", "items": { "type": "string" }, "description": "Questions / column headers" }
                }
            }),
        ),
        oai_tool(
            "kb_search",
            "Search the matter's knowledge base for relevant document chunks using semantic similarity.",
            serde_json::json!({
                "type": "object",
                "required": ["matter_id", "query"],
                "properties": {
                    "matter_id": { "type": "string" },
                    "query":     { "type": "string" },
                    "top_k":     { "type": "integer", "minimum": 1, "maximum": 20, "default": 5 }
                }
            }),
        ),
    ]
}

fn oai_tool(name: &str, description: &str, parameters: serde_json::Value) -> OaiTool {
    OaiTool {
        kind: "function".into(),
        function: OaiFunctionDef {
            name:        name.into(),
            description: description.into(),
            parameters,
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// System prompt builder
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the Pacgate agent system prompt. Inspired by Mike's ~3,000 token prompt
/// with the four core modules: CITATIONS, DOCX generation rules, edit rules, context management.
pub fn build_system_prompt(persona_prompt: Option<&str>) -> String {
    let base = include_str!("system_prompt_base.txt");
    match persona_prompt {
        Some(persona) => format!("{base}\n\n## PRACTICE AREA INSTRUCTIONS\n\n{persona}"),
        None          => base.to_string(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Agent loop
// ─────────────────────────────────────────────────────────────────────────────

/// Result of one agent turn: assistant text + citations + any tool execution log.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentTurnResult {
    pub message_id:       MessageId,
    pub content:          Option<String>,
    pub citations:        Vec<CitationRef>,
    pub tool_calls_made:  Vec<String>,
}

pub struct AgentLoop {
    pub router:     Arc<LlmRouter>,
    pub dispatcher: Arc<ToolDispatcher>,
    pub tier:       LlmTier,
    /// Maximum tool-call rounds before aborting (prevents infinite loops)
    pub max_rounds: u32,
}

impl AgentLoop {
    pub fn new(router: Arc<LlmRouter>, dispatcher: Arc<ToolDispatcher>) -> Self {
        Self {
            router,
            dispatcher,
            tier:       LlmTier::Main,
            max_rounds: 10,
        }
    }

    #[instrument(skip(self, history, persona_prompt))]
    pub async fn run(
        &self,
        history:       Vec<AgentMessage>,
        user_message:  &str,
        persona_prompt: Option<&str>,
    ) -> Result<AgentTurnResult> {
        let llm = self.router.get(self.tier)?;
        let tools = tool_definitions();

        let mut messages = self.convert_history(&history);

        // Inject system prompt at the beginning
        let system_prompt = build_system_prompt(persona_prompt);
        messages.insert(0, ChatMessage {
            role:         "system".into(),
            content:      Some(serde_json::Value::String(system_prompt)),
            tool_calls:   None,
            tool_call_id: None,
            name:         None,
        });

        messages.push(ChatMessage {
            role:         "user".into(),
            content:      Some(serde_json::Value::String(user_message.to_string())),
            tool_calls:   None,
            tool_call_id: None,
            name:         None,
        });

        let mut tool_calls_made = Vec::new();

        for round in 0..self.max_rounds {
            let (content, tool_calls) = llm.complete(messages.clone(), tools.clone()).await?;

            if tool_calls.is_empty() {
                // Final answer
                let citations = extract_citations(content.as_deref().unwrap_or(""));
                return Ok(AgentTurnResult {
                    message_id:      MessageId::new(),
                    content,
                    citations,
                    tool_calls_made,
                });
            }

            info!(round, n_tools = tool_calls.len(), "executing tool calls");
            tool_calls_made.extend(tool_calls.iter().map(|tc| tc.tool_name.clone()));

            // Push assistant message with tool calls
            messages.push(ChatMessage {
                role:         "assistant".into(),
                content:      content.map(serde_json::Value::String),
                tool_calls:   Some(
                    tool_calls
                        .iter()
                        .map(|tc| pacgate_llm::OaiToolCall {
                            id:   tc.id.clone(),
                            kind: "function".into(),
                            function: pacgate_llm::OaiFunctionCall {
                                name:      tc.tool_name.clone(),
                                arguments: tc.arguments.to_string(),
                            },
                        })
                        .collect(),
                ),
                tool_call_id: None,
                name:         None,
            });

            // Execute each tool and push results
            for tc in &tool_calls {
                let result = self.dispatcher.dispatch(tc).await;
                messages.push(ChatMessage {
                    role:         "tool".into(),
                    content:      Some(result.content.clone()),
                    tool_calls:   None,
                    tool_call_id: Some(result.tool_call_id.clone()),
                    name:         None,
                });
            }
        }

        Err(PacgateError::LlmError(format!(
            "agent loop exceeded max_rounds={}", self.max_rounds
        )))
    }

    fn convert_history(&self, history: &[AgentMessage]) -> Vec<ChatMessage> {
        history
            .iter()
            .filter_map(|msg| match msg {
                AgentMessage::System { content } => Some(ChatMessage {
                    role: "system".into(),
                    content: Some(serde_json::Value::String(content.clone())),
                    tool_calls: None, tool_call_id: None, name: None,
                }),
                AgentMessage::User { content, .. } => Some(ChatMessage {
                    role: "user".into(),
                    content: Some(serde_json::Value::String(content.clone())),
                    tool_calls: None, tool_call_id: None, name: None,
                }),
                AgentMessage::Assistant { content, tool_calls, .. } => Some(ChatMessage {
                    role: "assistant".into(),
                    content: content.clone().map(serde_json::Value::String),
                    tool_calls: if tool_calls.is_empty() { None } else {
                        Some(tool_calls.iter().map(|tc| pacgate_llm::OaiToolCall {
                            id: tc.id.clone(),
                            kind: "function".into(),
                            function: pacgate_llm::OaiFunctionCall {
                                name: tc.tool_name.clone(),
                                arguments: tc.arguments.to_string(),
                            },
                        }).collect())
                    },
                    tool_call_id: None, name: None,
                }),
                AgentMessage::Tool { tool_call_id, content, .. } => Some(ChatMessage {
                    role: "tool".into(),
                    content: Some(content.clone()),
                    tool_calls: None,
                    tool_call_id: Some(tool_call_id.clone()),
                    name: None,
                }),
            })
            .collect()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Citation extraction from assistant response text
// ─────────────────────────────────────────────────────────────────────────────

/// Parses the `<CITATIONS>` JSON block that the agent appends to its responses.
///
/// Expected format:
/// ```text
/// <CITATIONS>
/// [{ "ref": 1, "document_id": "...", "page": 5, "verbatim": "..." }]
/// </CITATIONS>
/// ```
fn extract_citations(text: &str) -> Vec<CitationRef> {
    let start = match text.find("<CITATIONS>") {
        Some(i) => i + "<CITATIONS>".len(),
        None    => return Vec::new(),
    };
    let end = match text[start..].find("</CITATIONS>") {
        Some(i) => start + i,
        None    => return Vec::new(),
    };
    let json_str = text[start..end].trim();

    #[derive(Deserialize)]
    struct Raw {
        #[serde(rename = "ref")]
        ref_num:     u32,
        document_id: String,
        page:        Option<u32>,
        verbatim:    String,
    }

    let raws: Vec<Raw> = match serde_json::from_str(json_str) {
        Ok(v)  => v,
        Err(e) => { warn!(error = %e, "citation parse failed"); return Vec::new(); }
    };

    raws.into_iter()
        .filter_map(|r| {
            r.document_id.parse().ok().map(|doc_id| CitationRef {
                ref_num:     r.ref_num,
                document_id: doc_id,
                page:        r.page,
                verbatim:    r.verbatim,
            })
        })
        .collect()
}
