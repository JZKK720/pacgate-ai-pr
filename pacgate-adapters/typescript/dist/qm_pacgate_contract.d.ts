export type UuidString = string;
export interface ApiErrorBody {
    error: {
        code: "bad_request" | "not_found" | "internal_error" | "unauthorized" | string;
        message: string;
    };
}
export declare class PacgateHttpError extends Error {
    readonly status: number;
    readonly body: ApiErrorBody | unknown;
    constructor(status: number, body: ApiErrorBody | unknown, message?: string);
}
export interface LoginRequest {
    email: string;
    password: string;
}
export interface LoginResponse {
    token: string;
    user_id: string;
    tenant_id: string;
    role: string;
    soul_id: string | null;
    expires_in: number;
}
export interface MeResponse {
    user_id: string;
    tenant_id: string;
    role: string;
    system_role: string;
    soul_id: string | null;
}
export interface CreateMatterRequest {
    name: string;
    description?: string;
    external_key?: string;
    persona_id?: UuidString;
}
export interface Matter {
    id: UuidString;
    tenant_id: UuidString;
    name: string;
    description: string | null;
    external_key: string | null;
    persona_id: UuidString | null;
    created_by: UuidString;
    created_at: string;
    updated_at: string;
}
export type MatterMemoryRecord = Record<string, unknown>;
export interface WorkflowSummary {
    id: UuidString;
    name: string;
    description: string;
    category: string;
    step_count: number;
}
export interface WorkflowStepDetail {
    name: string;
    description: string;
    tool: string;
}
export interface WorkflowDetail {
    id: UuidString;
    name: string;
    description: string;
    category: string;
    steps: WorkflowStepDetail[];
}
export interface WorkflowCategoryInfo {
    category: string;
    workflow_count: number;
}
export interface ExecuteWorkflowRequest {
    matter_id: UuidString;
    persona_id?: UuidString;
}
export interface CitationRef {
    source_id: string;
    source_type: string;
    quote: string;
    location?: string;
    confidence?: number;
}
export interface ExecuteStepResult {
    step_name: string;
    tool: string;
    content: string | null;
    citations: CitationRef[];
    tools_used: string[];
}
export interface ExecuteWorkflowResponse {
    workflow_name: string;
    steps: ExecuteStepResult[];
    final_content: string | null;
}
export interface ListWorkflowsQuery {
    category?: string;
    search?: string;
}
export interface QmPacgateGateway {
    login(input: LoginRequest): Promise<LoginResponse>;
    me(token: string): Promise<MeResponse>;
    createMatter(token: string, input: CreateMatterRequest): Promise<Matter>;
    listMatters(token: string): Promise<Matter[]>;
    getMatterMemory(token: string, matterId: UuidString): Promise<MatterMemoryRecord>;
    saveMatterMemory(token: string, matterId: UuidString, memory: MatterMemoryRecord): Promise<MatterMemoryRecord>;
    listWorkflows(token: string, query?: ListWorkflowsQuery): Promise<WorkflowSummary[]>;
    listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]>;
    getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail>;
    executeWorkflow(token: string, workflowId: UuidString, input: ExecuteWorkflowRequest): Promise<ExecuteWorkflowResponse>;
}
export declare class HttpQmPacgateGateway implements QmPacgateGateway {
    private readonly baseUrl;
    private readonly fetchImpl;
    constructor(baseUrl: string, fetchImpl?: typeof fetch);
    private request;
    login(input: LoginRequest): Promise<LoginResponse>;
    me(token: string): Promise<MeResponse>;
    createMatter(token: string, input: CreateMatterRequest): Promise<Matter>;
    listMatters(token: string): Promise<Matter[]>;
    getMatterMemory(token: string, matterId: UuidString): Promise<MatterMemoryRecord>;
    saveMatterMemory(token: string, matterId: UuidString, memory: MatterMemoryRecord): Promise<MatterMemoryRecord>;
    listWorkflows(token: string, query?: ListWorkflowsQuery): Promise<WorkflowSummary[]>;
    listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]>;
    getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail>;
    executeWorkflow(token: string, workflowId: UuidString, input: ExecuteWorkflowRequest): Promise<ExecuteWorkflowResponse>;
}
export declare const QM_PACGATE_MINIMUM_SURFACE: {
    readonly auth: readonly ["POST /api/auth/login", "GET /api/auth/me"];
    readonly matters: readonly ["POST /api/matters", "GET /api/matters", "GET /api/matters/:id/memory", "POST /api/matters/:id/memory"];
    readonly workflows: readonly ["GET /api/workflows", "GET /api/workflows/categories", "GET /api/workflows/:id", "POST /api/workflows/:id/execute"];
};
