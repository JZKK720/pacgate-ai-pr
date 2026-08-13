# Graph Report - crates  (2026-08-13)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 595 nodes · 1221 edges · 30 communities (29 shown, 1 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 16 edges (avg confidence: 0.86)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `02b5af96`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_LLM Provider & Tool Calling|LLM Provider & Tool Calling]]
- [[_COMMUNITY_Agent Message Routing|Agent Message Routing]]
- [[_COMMUNITY_Matter & Document System|Matter & Document System]]
- [[_COMMUNITY_Document Versioning API|Document Versioning API]]
- [[_COMMUNITY_DOCX Document Builder|DOCX Document Builder]]
- [[_COMMUNITY_Matter & Document State|Matter & Document State]]
- [[_COMMUNITY_XML Document Patching|XML Document Patching]]
- [[_COMMUNITY_Application Error Handling|Application Error Handling]]
- [[_COMMUNITY_Chat Application State|Chat Application State]]
- [[_COMMUNITY_Tool Dispatcher & Operations|Tool Dispatcher & Operations]]
- [[_COMMUNITY_Agent Loop Configuration|Agent Loop Configuration]]
- [[_COMMUNITY_Workflow Management API|Workflow Management API]]
- [[_COMMUNITY_Text Generation & Editing|Text Generation & Editing]]
- [[_COMMUNITY_Pacgate AI Legal Assistant|Pacgate AI Legal Assistant]]
- [[_COMMUNITY_Application Router Setup|Application Router Setup]]
- [[_COMMUNITY_Document Styles Module|Document Styles Module]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]

## God Nodes (most connected - your core abstractions)
1. `ToolDispatcher` - 19 edges
2. `FsDocumentStore` - 18 edges
3. `String` - 15 edges
4. `String` - 14 edges
5. `ApiError` - 13 edges
6. `String` - 12 edges
7. `Value` - 12 edges
8. `get_matter()` - 12 edges
9. `delete_matter()` - 12 edges
10. `SoulPersona` - 12 edges

## Surprising Connections (you probably didn't know these)
- `doc_path_helper()` --calls--> `doc_path()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `auth_middleware()` --references--> `StatusCode`  [EXTRACTED]
  pacgate-auth/src/middleware.rs → pacgate-api/src/error.rs
- `tenant_path_helpers()` --calls--> `docs_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `tenant_path_helpers()` --calls--> `matter_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `tenant_path_helpers()` --calls--> `tenant_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs

## Import Cycles
- 1-file cycle: `pacgate-agent/src/lib.rs -> pacgate-agent/src/lib.rs`
- 1-file cycle: `pacgate-api/src/auth.rs -> pacgate-api/src/auth.rs`
- 1-file cycle: `pacgate-api/src/state.rs -> pacgate-api/src/state.rs`
- 1-file cycle: `pacgate-api/src/matters.rs -> pacgate-api/src/matters.rs`
- 1-file cycle: `pacgate-auth/src/error.rs -> pacgate-auth/src/error.rs`
- 1-file cycle: `pacgate-auth/src/lib.rs -> pacgate-auth/src/lib.rs`
- 1-file cycle: `pacgate-tenant/src/lib.rs -> pacgate-tenant/src/lib.rs`
- 1-file cycle: `pacgate-docx/src/store.rs -> pacgate-docx/src/store.rs`
- 1-file cycle: `pacgate-tenant/src/tenant_store.rs -> pacgate-tenant/src/tenant_store.rs`
- 1-file cycle: `pacgate-docx/src/error.rs -> pacgate-docx/src/error.rs`
- 1-file cycle: `pacgate-llm/src/lib.rs -> pacgate-llm/src/lib.rs`
- 1-file cycle: `pacgate-rag/src/lib.rs -> pacgate-rag/src/lib.rs`
- 1-file cycle: `pacgate-rag/src/embed.rs -> pacgate-rag/src/embed.rs`
- 1-file cycle: `pacgate-template/src/lib.rs -> pacgate-template/src/lib.rs`
- 1-file cycle: `pacgate-tenant/src/error.rs -> pacgate-tenant/src/error.rs`
- 1-file cycle: `pacgate-workflow/src/lib.rs -> pacgate-workflow/src/lib.rs`

## Communities (30 total, 1 thin omitted)

### Community 0 - "LLM Provider & Tool Calling"
Cohesion: 0.06
Nodes (53): BoundaryRule, Branding, DateTime, EnforcementPoint, EscalationRule, IdentityMode, OutputFormat, DocumentId (+45 more)

### Community 1 - "Agent Message Routing"
Cohesion: 0.10
Nodes (36): ChatMessage, KbStore, MessageId, OaiTool, AgentMessage, Arc, CitationRef, DocumentStore (+28 more)

### Community 2 - "Matter & Document System"
Cohesion: 0.09
Nodes (38): Box, Choice, ChoiceMessage, HashMap, LlmProvider, LlmStream, ModelConfig, OaiFunctionCall (+30 more)

### Community 3 - "Document Versioning API"
Cohesion: 0.06
Nodes (33): AgentLoop, AppConfig, Default, FsDocumentStore, MatterStore, AppState, Result, Arc (+25 more)

### Community 4 - "DOCX Document Builder"
Cohesion: 0.18
Nodes (20): FindResult, Document, DocumentId, DocumentStore, Into, MatterId, Option, PathBuf (+12 more)

### Community 5 - "Matter & Document State"
Cohesion: 0.11
Nodes (17): Matter, MatterId, PathBuf, PgPool, PgRow, Result, TenantError, TenantId (+9 more)

### Community 6 - "XML Document Patching"
Cohesion: 0.27
Nodes (25): Multipart, ApiError, AppState, Document, Json, Option, Path, Response (+17 more)

### Community 7 - "Application Error Handling"
Cohesion: 0.14
Nodes (16): Error, From, Next, Into, IntoResponse, Response, Self, String (+8 more)

### Community 8 - "Chat Application State"
Cohesion: 0.24
Nodes (23): ApiError, AppState, Claims, Document, Extension, Json, Matter, Option (+15 more)

### Community 9 - "Tool Dispatcher & Operations"
Cohesion: 0.18
Nodes (16): EmbeddingService, Error, From, MatterId, Option, PacgateError, PgPool, RagError (+8 more)

### Community 10 - "Agent Loop Configuration"
Cohesion: 0.20
Nodes (14): Matter, MatterId, Option, PersonaId, PgPool, Result, Self, TenantError (+6 more)

### Community 11 - "Workflow Management API"
Cohesion: 0.20
Nodes (14): Option, Result, Self, String, Value, Vec, build_from_structure(), DocxBuilder (+6 more)

### Community 12 - "Text Generation & Editing"
Cohesion: 0.27
Nodes (11): AuthError, Into, Option, PgPool, Result, Self, String, TenantId (+3 more)

### Community 13 - "Pacgate AI Legal Assistant"
Cohesion: 0.24
Nodes (17): ApiError, AppState, Claims, Extension, Json, Option, Result, State (+9 more)

### Community 14 - "Application Router Setup"
Cohesion: 0.21
Nodes (12): EmbedData, Client, Into, RagError, Result, Self, String, Vec (+4 more)

### Community 15 - "Document Styles Module"
Cohesion: 0.18
Nodes (16): IntoResponse, AgentMessage, ApiError, AppState, CitationRef, Json, Option, Result (+8 more)

### Community 16 - "Community 16"
Cohesion: 0.20
Nodes (11): DocumentId, EmbeddingService, MatterId, PgPool, RagError, Result, Self, String (+3 more)

### Community 17 - "Community 17"
Cohesion: 0.31
Nodes (13): Into, Option, Result, Self, String, Vec, apply_tracked_edit(), patch_document_xml() (+5 more)

### Community 18 - "Community 18"
Cohesion: 0.31
Nodes (14): Option, PersonaId, String, Vec, PracticeArea, SoulPersona, built_in_personas(), built_in_souls() (+6 more)

### Community 19 - "Community 19"
Cohesion: 0.32
Nodes (12): Option, String, Value, Vec, built_in_workflows(), get_workflow(), list_workflows(), Workflow (+4 more)

### Community 20 - "Community 20"
Cohesion: 0.29
Nodes (11): ApiError, AppState, Json, Path, Result, State, String, Vec (+3 more)

### Community 21 - "Community 21"
Cohesion: 0.25
Nodes (8): Cubecloud Local-First Agentic OS, Edit Document Function, Fetch Documents Function, Find in Document Function, Generate DOCX Function, List Documents Function, Pacgate AI Legal Assistant, Read Document Function

### Community 22 - "Community 22"
Cohesion: 0.38
Nodes (6): String, Value, Vec, list_templates(), Template, TemplateId

### Community 23 - "Community 23"
Cohesion: 0.43
Nodes (5): Error, From, PacgateError, Self, TenantError

### Community 24 - "Community 24"
Cohesion: 0.47
Nodes (4): Error, From, Self, AuthError

### Community 25 - "Community 25"
Cohesion: 0.47
Nodes (4): Error, From, Self, StoreError

### Community 26 - "Community 26"
Cohesion: 0.40
Nodes (5): String, Value, Vec, LegalDocumentTemplate, list_templates()

## Knowledge Gaps
- **129 isolated node(s):** `IntoResponse`, `Response`, `From`, `Vec`, `Path` (+124 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Utc` connect `LLM Provider & Tool Calling` to `Agent Loop Configuration`, `DOCX Document Builder`, `Matter & Document State`?**
  _High betweenness centrality (0.089) - this node is a cross-community bridge._
- **Why does `build_router()` connect `Document Versioning API` to `Agent Loop Configuration`?**
  _High betweenness centrality (0.053) - this node is a cross-community bridge._
- **What connects `IntoResponse`, `Response`, `From` to the rest of the system?**
  _129 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `LLM Provider & Tool Calling` be split into smaller, more focused modules?**
  _Cohesion score 0.06140350877192982 - nodes in this community are weakly interconnected._
- **Should `Agent Message Routing` be split into smaller, more focused modules?**
  _Cohesion score 0.1033182503770739 - nodes in this community are weakly interconnected._
- **Should `Matter & Document System` be split into smaller, more focused modules?**
  _Cohesion score 0.08953900709219859 - nodes in this community are weakly interconnected._
- **Should `Document Versioning API` be split into smaller, more focused modules?**
  _Cohesion score 0.06342780026990553 - nodes in this community are weakly interconnected._