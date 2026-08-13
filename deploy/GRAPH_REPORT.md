# Graph Report - pacgate-ai\crates  (2026-08-13)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 297 nodes · 621 edges · 16 communities
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 11 edges (avg confidence: 0.88)
- Token cost: 0 input · 0 output

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

## God Nodes (most connected - your core abstractions)
1. `ToolDispatcher` - 19 edges
2. `String` - 14 edges
3. `String` - 14 edges
4. `ApiError` - 13 edges
5. `Value` - 12 edges
6. `ToolCall` - 11 edges
7. `Result` - 11 edges
8. `patch_document_xml()` - 11 edges
9. `String` - 10 edges
10. `list_versions()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `render_signature_block()` --calls--> `xml_escape()`  [INFERRED]
  pacgate-docx/src/builder.rs → pacgate-docx/src/ooxml.rs
- `apply_edit()` --calls--> `apply_tracked_edit()`  [INFERRED]
  pacgate-docx/src/lib.rs → pacgate-docx/src/diff.rs
- `patch_document_xml()` --calls--> `xml_escape()`  [INFERRED]
  pacgate-docx/src/diff.rs → pacgate-docx/src/ooxml.rs
- `replace_first_in_xml()` --calls--> `xml_escape()`  [INFERRED]
  pacgate-docx/src/diff.rs → pacgate-docx/src/ooxml.rs

## Import Cycles
- 1-file cycle: `pacgate-agent/src/lib.rs -> pacgate-agent/src/lib.rs`
- 1-file cycle: `pacgate-api/src/lib.rs -> pacgate-api/src/lib.rs`
- 1-file cycle: `pacgate-api/src/state.rs -> pacgate-api/src/state.rs`
- 1-file cycle: `pacgate-llm/src/lib.rs -> pacgate-llm/src/lib.rs`

## Communities (16 total, 0 thin omitted)

### Community 0 - "LLM Provider & Tool Calling"
Cohesion: 0.09
Nodes (38): Box, Choice, ChoiceMessage, Client, HashMap, LlmProvider, LlmStream, ModelConfig (+30 more)

### Community 1 - "Agent Message Routing"
Cohesion: 0.10
Nodes (36): ChatMessage, MessageId, OaiTool, AgentMessage, Arc, CitationRef, DocumentId, LlmRouter (+28 more)

### Community 2 - "Matter & Document System"
Cohesion: 0.11
Nodes (25): DateTime, MatterId, DocumentId, Option, Self, String, Value, Vec (+17 more)

### Community 3 - "Document Versioning API"
Cohesion: 0.27
Nodes (25): Multipart, ApiError, AppState, Document, Json, Option, Path, Response (+17 more)

### Community 4 - "DOCX Document Builder"
Cohesion: 0.19
Nodes (13): Option, Result, Self, String, Value, Vec, DocxBuilder, DocxSection (+5 more)

### Community 5 - "Matter & Document State"
Cohesion: 0.27
Nodes (18): Matter, ApiError, AppState, Document, Json, Option, Path, Result (+10 more)

### Community 6 - "XML Document Patching"
Cohesion: 0.24
Nodes (15): Into, Option, Result, Self, String, Vec, String, apply_tracked_edit() (+7 more)

### Community 7 - "Application Error Handling"
Cohesion: 0.24
Nodes (10): Error, From, Into, IntoResponse, Response, Self, String, PacgateError (+2 more)

### Community 8 - "Chat Application State"
Cohesion: 0.18
Nodes (16): AgentMessage, ApiError, AppState, CitationRef, IntoResponse, Json, Option, Result (+8 more)

### Community 9 - "Tool Dispatcher & Operations"
Cohesion: 0.44
Nodes (5): Result, ToolCall, Value, ToolDispatcher, ToolResult

### Community 10 - "Agent Loop Configuration"
Cohesion: 0.20
Nodes (10): AgentLoop, AppConfig, Default, Arc, LlmRouter, Self, PathBuf, AppConfig (+2 more)

### Community 11 - "Workflow Management API"
Cohesion: 0.29
Nodes (11): ApiError, AppState, Json, Path, Result, State, String, Vec (+3 more)

### Community 12 - "Text Generation & Editing"
Cohesion: 0.31
Nodes (8): Option, Result, String, Value, Vec, apply_edit(), generate_from_structure(), read_text()

### Community 13 - "Pacgate AI Legal Assistant"
Cohesion: 0.25
Nodes (8): Cubecloud Local-First Agentic OS, Edit Document Function, Fetch Documents Function, Find in Document Function, Generate DOCX Function, List Documents Function, Pacgate AI Legal Assistant, Read Document Function

### Community 14 - "Application Router Setup"
Cohesion: 0.67
Nodes (3): AppState, Router, build_router()

## Knowledge Gaps
- **67 isolated node(s):** `DocumentId`, `ToolResult`, `MessageId`, `LlmTier`, `ChatMessage` (+62 more)
  These have ≤1 connection - possible missing edges or undocumented components.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `xml_escape()` connect `XML Document Patching` to `DOCX Document Builder`?**
  _High betweenness centrality (0.013) - this node is a cross-community bridge._
- **Why does `Error` connect `Application Error Handling` to `Matter & Document System`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **What connects `DocumentId`, `ToolResult`, `MessageId` to the rest of the system?**
  _67 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `LLM Provider & Tool Calling` be split into smaller, more focused modules?**
  _Cohesion score 0.08953900709219859 - nodes in this community are weakly interconnected._
- **Should `Agent Message Routing` be split into smaller, more focused modules?**
  _Cohesion score 0.10365853658536585 - nodes in this community are weakly interconnected._
- **Should `Matter & Document System` be split into smaller, more focused modules?**
  _Cohesion score 0.10837438423645321 - nodes in this community are weakly interconnected._