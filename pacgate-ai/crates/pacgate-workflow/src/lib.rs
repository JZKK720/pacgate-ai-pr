//! pacgate-workflow — Legal workflow templates.
//!
//! Seed templates covering common legal workflows. The full Suzie Law
//! library (160+ templates, MIT) can be loaded from YAML files at runtime.
//! These built-in templates cover the most common workflows for a law firm.

use pacgate_core::WorkflowId;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Workflow {
    pub id:          WorkflowId,
    pub name:        String,
    pub description: String,
    pub category:    String,
    pub steps:       Vec<WorkflowStep>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WorkflowStep {
    pub name:        String,
    pub description: String,
    pub tool:        String,  // which agent tool to call
    pub parameters:  serde_json::Value,
}

/// List all built-in workflows.
pub fn list_workflows() -> Vec<Workflow> {
    built_in_workflows()
}

/// Get a workflow by ID.
pub fn get_workflow(id: &WorkflowId) -> Option<Workflow> {
    built_in_workflows().iter().find(|w| &w.id == id).cloned()
}

/// Get workflows by category.
pub fn workflows_by_category(category: &str) -> Vec<Workflow> {
    built_in_workflows()
        .iter()
        .filter(|w| w.category == category)
        .cloned()
        .collect()
}

fn built_in_workflows() -> Vec<Workflow> {
    vec![
        // ─── Contract Review ─────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000101)),
            name: "Contract Review".to_string(),
            description: "Review a contract for risks, unfavorable clauses, and missing provisions".to_string(),
            category: "contract_review".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Read document".to_string(),
                    description: "Read the contract document".to_string(),
                    tool: "read_document".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Identify risks".to_string(),
                    description: "Identify unfavorable clauses and risk areas".to_string(),
                    tool: "find_in_document".to_string(),
                    parameters: serde_json::json!({"queries": ["indemnification", "limitation of liability", "termination", "governing law"]}),
                },
                WorkflowStep {
                    name: "Generate review memo".to_string(),
                    description: "Generate a contract review memo with findings".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "contract_review_memo"}),
                },
            ],
        },
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000102)),
            name: "Contract Comparison".to_string(),
            description: "Compare two contract versions and highlight changes".to_string(),
            category: "contract_review".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Read both versions".to_string(),
                    description: "Read both contract versions".to_string(),
                    tool: "fetch_documents".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Generate diff report".to_string(),
                    description: "Generate a comparison report with tracked changes".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "contract_diff_report"}),
                },
            ],
        },
        // ─── Due Diligence ───────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000201)),
            name: "Due Diligence Review".to_string(),
            description: "Systematic due diligence review of a document portfolio".to_string(),
            category: "due_diligence".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "List all documents".to_string(),
                    description: "List all documents in the matter".to_string(),
                    tool: "list_documents".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Extract key terms".to_string(),
                    description: "Extract key terms from each document into a table".to_string(),
                    tool: "read_table_cells".to_string(),
                    parameters: serde_json::json!({"columns": ["party", "effective_date", "term", "governing_law", "termination"]}),
                },
                WorkflowStep {
                    name: "Generate DD report".to_string(),
                    description: "Generate a due diligence report with findings summary".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "due_diligence_report"}),
                },
            ],
        },
        // ─── Legal Research ──────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000301)),
            name: "Legal Research Memo".to_string(),
            description: "Research a legal question and produce a cited memo".to_string(),
            category: "legal_research".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Search knowledge base".to_string(),
                    description: "Search the firm's knowledge base for relevant precedent".to_string(),
                    tool: "kb_search".to_string(),
                    parameters: serde_json::json!({"top_k": 10}),
                },
                WorkflowStep {
                    name: "Read relevant documents".to_string(),
                    description: "Read the most relevant documents identified by the search".to_string(),
                    tool: "read_document".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Generate research memo".to_string(),
                    description: "Generate a research memo with citations".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "research_memo"}),
                },
            ],
        },
        // ─── Tabular Review ──────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000401)),
            name: "Tabular Document Review".to_string(),
            description: "Extract structured data from multiple documents into a comparison table".to_string(),
            category: "tabular_review".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "List documents".to_string(),
                    description: "List all documents to review".to_string(),
                    tool: "list_documents".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Extract data".to_string(),
                    description: "Extract specified columns from each document".to_string(),
                    tool: "read_table_cells".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Generate table".to_string(),
                    description: "Generate a comparison table document".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "comparison_table"}),
                },
            ],
        },
        // ─── Document Generation ─────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000501)),
            name: "Contract Drafting".to_string(),
            description: "Draft a new contract from a template structure".to_string(),
            category: "document_generation".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Read workflow template".to_string(),
                    description: "Read the contract template structure".to_string(),
                    tool: "read_workflow".to_string(),
                    parameters: serde_json::json!({"workflow_id": "contract_template"}),
                },
                WorkflowStep {
                    name: "Generate contract".to_string(),
                    description: "Generate the contract document".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "contract_draft"}),
                },
            ],
        },
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000502)),
            name: "Legal Opinion".to_string(),
            description: "Draft a formal legal opinion on a specific question".to_string(),
            category: "document_generation".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Research the question".to_string(),
                    description: "Search knowledge base for relevant authority".to_string(),
                    tool: "kb_search".to_string(),
                    parameters: serde_json::json!({"top_k": 5}),
                },
                WorkflowStep {
                    name: "Generate opinion".to_string(),
                    description: "Generate the legal opinion document".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "legal_opinion"}),
                },
            ],
        },
        // ─── Compliance ──────────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000601)),
            name: "Compliance Check".to_string(),
            description: "Check a document or process for regulatory compliance issues".to_string(),
            category: "compliance".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Read document".to_string(),
                    description: "Read the document to check".to_string(),
                    tool: "read_document".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Search compliance rules".to_string(),
                    description: "Search the knowledge base for applicable compliance rules".to_string(),
                    tool: "kb_search".to_string(),
                    parameters: serde_json::json!({"top_k": 5}),
                },
                WorkflowStep {
                    name: "Generate compliance report".to_string(),
                    description: "Generate a compliance check report".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "compliance_report"}),
                },
            ],
        },
        // ─── M&A ─────────────────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000701)),
            name: "SPA Review".to_string(),
            description: "Review a Share Purchase Agreement for M&A transaction".to_string(),
            category: "ma".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "Read SPA".to_string(),
                    description: "Read the Share Purchase Agreement".to_string(),
                    tool: "read_document".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Check key provisions".to_string(),
                    description: "Check representations, warranties, indemnities, and conditions".to_string(),
                    tool: "find_in_document".to_string(),
                    parameters: serde_json::json!({"queries": ["representations and warranties", "indemnification", "conditions precedent", "termination rights", "non-compete"]}),
                },
                WorkflowStep {
                    name: "Generate SPA review".to_string(),
                    description: "Generate an SPA review report".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "spa_review"}),
                },
            ],
        },
        // ─── Litigation ──────────────────────────────────────────────────
        Workflow {
            id: WorkflowId(uuid::Uuid::from_u128(0x00000000_0000_0000_0000_000000000801)),
            name: "Discovery Review".to_string(),
            description: "Review discovery documents and identify relevant evidence".to_string(),
            category: "litigation".to_string(),
            steps: vec![
                WorkflowStep {
                    name: "List discovery documents".to_string(),
                    description: "List all documents in the discovery production".to_string(),
                    tool: "list_documents".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Search for evidence".to_string(),
                    description: "Search for key terms and evidence in the documents".to_string(),
                    tool: "find_in_document".to_string(),
                    parameters: serde_json::json!({}),
                },
                WorkflowStep {
                    name: "Generate discovery summary".to_string(),
                    description: "Generate a discovery review summary".to_string(),
                    tool: "generate_docx".to_string(),
                    parameters: serde_json::json!({"template": "discovery_summary"}),
                },
            ],
        },
    ]
}