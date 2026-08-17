# Graph Report - crates  (2026-08-18)

## Corpus Check
- 39 files · ~38,422 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 918 nodes · 2153 edges · 49 communities (42 shown, 7 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 24 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `637334be`
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
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]

## God Nodes (most connected - your core abstractions)
1. `Self` - 27 edges
2. `FsDocumentStore` - 25 edges
3. `String` - 24 edges
4. `ToolDispatcher` - 23 edges
5. `SearchQuery` - 22 edges
6. `String` - 20 edges
7. `Option` - 20 edges
8. `Vec` - 20 edges
9. `Result` - 18 edges
10. `execute_workflow()` - 17 edges

## Surprising Connections (you probably didn't know these)
- `dd_config_for_domain_lookup()` --calls--> `dd_config_for_domain()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-core/src/lib.rs
- `doc_path_helper()` --calls--> `doc_path()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `tenant_path_helpers()` --calls--> `docs_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `tenant_path_helpers()` --calls--> `matter_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs
- `tenant_path_helpers()` --calls--> `tenant_dir()`  [INFERRED]
  pacgate-api/tests/smoke.rs → pacgate-tenant/src/lib.rs

## Import Cycles
- 1-file cycle: `pacgate-agent/src/lib.rs -> pacgate-agent/src/lib.rs`
- 1-file cycle: `pacgate-agent/src/workflow_executor.rs -> pacgate-agent/src/workflow_executor.rs`
- 1-file cycle: `pacgate-api/src/auth.rs -> pacgate-api/src/auth.rs`
- 1-file cycle: `pacgate-api/src/chat.rs -> pacgate-api/src/chat.rs`
- 1-file cycle: `pacgate-api/src/documents.rs -> pacgate-api/src/documents.rs`
- 1-file cycle: `pacgate-api/src/state.rs -> pacgate-api/src/state.rs`
- 1-file cycle: `pacgate-api/src/matters.rs -> pacgate-api/src/matters.rs`
- 1-file cycle: `pacgate-api/src/workflows.rs -> pacgate-api/src/workflows.rs`
- 1-file cycle: `pacgate-auth/src/error.rs -> pacgate-auth/src/error.rs`
- 1-file cycle: `pacgate-auth/src/lib.rs -> pacgate-auth/src/lib.rs`
- 1-file cycle: `pacgate-tenant/src/lib.rs -> pacgate-tenant/src/lib.rs`
- 1-file cycle: `pacgate-docx/src/store.rs -> pacgate-docx/src/store.rs`
- 1-file cycle: `pacgate-tenant/src/tenant_store.rs -> pacgate-tenant/src/tenant_store.rs`
- 1-file cycle: `pacgate-docx/src/error.rs -> pacgate-docx/src/error.rs`
- 1-file cycle: `pacgate-docx/src/parser.rs -> pacgate-docx/src/parser.rs`
- 1-file cycle: `pacgate-llm/src/lib.rs -> pacgate-llm/src/lib.rs`
- 1-file cycle: `pacgate-rag/src/lib.rs -> pacgate-rag/src/lib.rs`
- 1-file cycle: `pacgate-rag/src/embed.rs -> pacgate-rag/src/embed.rs`
- 1-file cycle: `pacgate-rag/src/ingest.rs -> pacgate-rag/src/ingest.rs`
- 1-file cycle: `pacgate-search/src/lib.rs -> pacgate-search/src/lib.rs`

## Communities (49 total, 7 thin omitted)

### Community 0 - "LLM Provider & Tool Calling"
Cohesion: 0.13
Nodes (17): Send, Sync, AgentMessage, DocumentStore, EnforcementPoint, Jurisdiction, KbStore, OutputFormat (+9 more)

### Community 1 - "Agent Message Routing"
Cohesion: 0.09
Nodes (41): ChatMessage, KbStore, MessageId, OaiTool, AgentMessage, Arc, CitationRef, DocumentStore (+33 more)

### Community 2 - "Matter & Document System"
Cohesion: 0.09
Nodes (38): Box, Choice, ChoiceMessage, HashMap, LlmProvider, LlmStream, ModelConfig, OaiFunctionCall (+30 more)

### Community 3 - "Document Versioning API"
Cohesion: 0.06
Nodes (36): AppConfig, FsDocumentStore, MatterStore, AppState, Result, AgentLoop, Arc, AuthService (+28 more)

### Community 4 - "DOCX Document Builder"
Cohesion: 0.20
Nodes (20): FindResult, Document, DocumentId, DocumentStore, Into, MatterId, Option, PathBuf (+12 more)

### Community 5 - "Matter & Document State"
Cohesion: 0.08
Nodes (18): Matter, MatterId, PathBuf, PgPool, PgRow, Result, TenantError, TenantId (+10 more)

### Community 6 - "XML Document Patching"
Cohesion: 0.21
Nodes (36): Multipart, ApiError, AppState, Claims, Document, DocumentId, Extension, Json (+28 more)

### Community 7 - "Application Error Handling"
Cohesion: 0.24
Nodes (10): Error, From, Into, IntoResponse, PacgateError, Response, Self, StatusCode (+2 more)

### Community 8 - "Chat Application State"
Cohesion: 0.23
Nodes (29): ApiError, AppState, Claims, Document, Extension, Json, Matter, MatterId (+21 more)

### Community 9 - "Tool Dispatcher & Operations"
Cohesion: 0.14
Nodes (20): DataLevel, EmbeddingService, Error, From, Jurisdiction, MatterId, Option, PacgateError (+12 more)

### Community 10 - "Agent Loop Configuration"
Cohesion: 0.20
Nodes (14): Matter, MatterId, Option, PersonaId, PgPool, Result, Self, TenantError (+6 more)

### Community 11 - "Workflow Management API"
Cohesion: 0.17
Nodes (16): Option, Result, Self, String, Value, Vec, String, build_from_structure() (+8 more)

### Community 12 - "Text Generation & Editing"
Cohesion: 0.13
Nodes (23): AuthError, Next, Claims, Into, Option, PgPool, Result, Self (+15 more)

### Community 13 - "Pacgate AI Legal Assistant"
Cohesion: 0.24
Nodes (17): ApiError, AppState, Claims, Extension, Json, Option, Result, State (+9 more)

### Community 14 - "Application Router Setup"
Cohesion: 0.21
Nodes (12): EmbedData, Client, Into, RagError, Result, Self, String, Vec (+4 more)

### Community 15 - "Document Styles Module"
Cohesion: 0.16
Nodes (25): AgentMessage, ApiError, AppState, CitationRef, Claims, Extension, Into, IntoResponse (+17 more)

### Community 16 - "Community 16"
Cohesion: 0.20
Nodes (14): DataLevel, DocumentId, EmbeddingService, Jurisdiction, MatterId, PgPool, RagError, Result (+6 more)

### Community 17 - "Community 17"
Cohesion: 0.28
Nodes (17): Into, Option, Result, Self, String, Vec, accept_document_xml(), accept_tracked_changes() (+9 more)

### Community 18 - "Community 18"
Cohesion: 0.31
Nodes (14): Option, PersonaId, SoulPersona, String, Vec, PracticeArea, built_in_personas(), built_in_souls() (+6 more)

### Community 19 - "Community 19"
Cohesion: 0.20
Nodes (21): Option, Path, Result, String, Value, Vec, WorkflowStep, built_in_workflows() (+13 more)

### Community 20 - "Community 20"
Cohesion: 0.16
Nodes (31): ExecuteStepResult, ApiError, AppState, CitationRef, Claims, Extension, Json, Option (+23 more)

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

### Community 27 - "Community 27"
Cohesion: 0.13
Nodes (23): AgentLoop, CitationRef, DdAgentConfig, MatterId, Option, PacgateError, Result, Self (+15 more)

### Community 28 - "Community 28"
Cohesion: 0.33
Nodes (6): Arc, Send, Sync, DataSourceConnector, default_router(), SearchRouter

### Community 30 - "Community 30"
Cohesion: 0.19
Nodes (8): Duration, Into, Option, Self, String, build_timeout_connector_client(), FyOpenConnector, SearchQuery

### Community 31 - "Community 31"
Cohesion: 0.11
Nodes (6): Client, Default, build_connector_client(), EurLexConnector, GleifConnector, SecEdgarConnector

### Community 32 - "Community 32"
Cohesion: 0.25
Nodes (22): ConnectorMetadata, ApiError, AppState, DdAgentConfig, Json, Option, Query, Result (+14 more)

### Community 33 - "Community 33"
Cohesion: 0.27
Nodes (5): Vec, ConnectorMetadata, ConnectorPriority, ConnectorRegion, ConnectorRegistry

### Community 34 - "Community 34"
Cohesion: 0.16
Nodes (6): Display, Formatter, Result, ArchiveDirectory, DataLevel, FileDirectoryEntry

### Community 36 - "Community 36"
Cohesion: 0.18
Nodes (9): Branding, Option, Self, Branding, dd_domain_from_str(), LlmProvider, LlmTier, ModelConfig (+1 more)

### Community 37 - "Community 37"
Cohesion: 0.20
Nodes (12): EnforcementPoint, DocumentId, String, Value, BoundaryRule, CitationRef, EscalationRule, FindResult (+4 more)

### Community 38 - "Community 38"
Cohesion: 0.29
Nodes (8): Vec, dd_agent_configs(), dd_config_for_domain(), DdAgentConfig, DdAgentDomain, DdFocusArea, DdSeverity, FocusAreaAction

### Community 39 - "Community 39"
Cohesion: 0.29
Nodes (11): DateTime, MatterId, PersonaId, TenantId, UserId, Document, DocumentFormat, Matter (+3 more)

### Community 40 - "Community 40"
Cohesion: 0.29
Nodes (4): Value, OpenCorporatesConnector, SearchResult, source_level_priority()

### Community 41 - "Community 41"
Cohesion: 0.48
Nodes (6): PgPool, String, full_api_flow(), run_rag_migrations_if_available(), test_db_url(), unauthenticated_request_returns_401()

### Community 42 - "Community 42"
Cohesion: 0.33
Nodes (6): BoundaryRule, EscalationRule, IdentityMode, OutputFormat, SecurityLevel, SoulPersona

## Knowledge Gaps
- **144 isolated node(s):** `ToolResult`, `MessageId`, `LlmTier`, `ChatMessage`, `CitationRef` (+139 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Utc` connect `Community 39` to `Agent Loop Configuration`, `DOCX Document Builder`, `Matter & Document State`?**
  _High betweenness centrality (0.050) - this node is a cross-community bridge._
- **Why does `build_router()` connect `Document Versioning API` to `Agent Loop Configuration`?**
  _High betweenness centrality (0.039) - this node is a cross-community bridge._
- **What connects `ToolResult`, `MessageId`, `LlmTier` to the rest of the system?**
  _144 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `LLM Provider & Tool Calling` be split into smaller, more focused modules?**
  _Cohesion score 0.13450292397660818 - nodes in this community are weakly interconnected._
- **Should `Agent Message Routing` be split into smaller, more focused modules?**
  _Cohesion score 0.09409701928696669 - nodes in this community are weakly interconnected._
- **Should `Matter & Document System` be split into smaller, more focused modules?**
  _Cohesion score 0.08953900709219859 - nodes in this community are weakly interconnected._
- **Should `Document Versioning API` be split into smaller, more focused modules?**
  _Cohesion score 0.0627177700348432 - nodes in this community are weakly interconnected._