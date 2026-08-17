/*
 * QM <-> Pacgate API contract (Phase 2 collaboration runtime).
 *
 * Source of truth for endpoint alignment:
 * - pacgate-ai/crates/pacgate-api/src/lib.rs
 * - pacgate-ai/crates/pacgate-api/src/workflows.rs
 * - pacgate-ai/crates/pacgate-api/src/auth.rs
 * - pacgate-ai/crates/pacgate-api/src/matters.rs
 */

export type UuidString = string;

export interface ApiErrorBody {
  error: {
    code: "bad_request" | "not_found" | "internal_error" | "unauthorized" | string;
    message: string;
  };
}

export class PacgateHttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: ApiErrorBody | unknown,
    message = "Pacgate API request failed"
  ) {
    super(message);
  }
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
  saveMatterMemory(
    token: string,
    matterId: UuidString,
    memory: MatterMemoryRecord
  ): Promise<MatterMemoryRecord>;

  listWorkflows(token: string, query?: ListWorkflowsQuery): Promise<WorkflowSummary[]>;
  listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]>;
  getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail>;
  executeWorkflow(
    token: string,
    workflowId: UuidString,
    input: ExecuteWorkflowRequest
  ): Promise<ExecuteWorkflowResponse>;
}

function buildQuery(query?: Record<string, string | undefined>): string {
  if (!query) return "";
  const params = new URLSearchParams();
  for (const [k, v] of Object.entries(query)) {
    if (v && v.trim() !== "") params.set(k, v);
  }
  const text = params.toString();
  return text ? `?${text}` : "";
}

export class HttpQmPacgateGateway implements QmPacgateGateway {
  constructor(private readonly baseUrl: string, private readonly fetchImpl: typeof fetch = fetch) {}

  private async request<T>(
    path: string,
    init: RequestInit,
    token?: string
  ): Promise<T> {
    const headers = new Headers(init.headers ?? {});
    headers.set("Content-Type", "application/json");
    if (token) headers.set("Authorization", `Bearer ${token}`);

    const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
      ...init,
      headers,
    });

    const json = await res.json().catch(() => undefined);
    if (!res.ok) {
      throw new PacgateHttpError(res.status, json, `HTTP ${res.status} ${path}`);
    }
    return json as T;
  }

  login(input: LoginRequest): Promise<LoginResponse> {
    return this.request<LoginResponse>("/api/auth/login", {
      method: "POST",
      body: JSON.stringify(input),
    });
  }

  me(token: string): Promise<MeResponse> {
    return this.request<MeResponse>("/api/auth/me", { method: "GET" }, token);
  }

  createMatter(token: string, input: CreateMatterRequest): Promise<Matter> {
    return this.request<Matter>(
      "/api/matters",
      { method: "POST", body: JSON.stringify(input) },
      token
    );
  }

  listMatters(token: string): Promise<Matter[]> {
    return this.request<Matter[]>("/api/matters", { method: "GET" }, token);
  }

  getMatterMemory(token: string, matterId: UuidString): Promise<MatterMemoryRecord> {
    return this.request<MatterMemoryRecord>(
      `/api/matters/${matterId}/memory`,
      { method: "GET" },
      token
    );
  }

  saveMatterMemory(
    token: string,
    matterId: UuidString,
    memory: MatterMemoryRecord
  ): Promise<MatterMemoryRecord> {
    return this.request<MatterMemoryRecord>(
      `/api/matters/${matterId}/memory`,
      { method: "POST", body: JSON.stringify(memory) },
      token
    );
  }

  listWorkflows(token: string, query?: ListWorkflowsQuery): Promise<WorkflowSummary[]> {
    return this.request<WorkflowSummary[]>(
      `/api/workflows${buildQuery({ category: query?.category, search: query?.search })}`,
      { method: "GET" },
      token
    );
  }

  listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]> {
    return this.request<WorkflowCategoryInfo[]>("/api/workflows/categories", { method: "GET" }, token);
  }

  getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail> {
    return this.request<WorkflowDetail>(`/api/workflows/${workflowId}`, { method: "GET" }, token);
  }

  executeWorkflow(
    token: string,
    workflowId: UuidString,
    input: ExecuteWorkflowRequest
  ): Promise<ExecuteWorkflowResponse> {
    return this.request<ExecuteWorkflowResponse>(
      `/api/workflows/${workflowId}/execute`,
      { method: "POST", body: JSON.stringify(input) },
      token
    );
  }
}

export const QM_PACGATE_MINIMUM_SURFACE = {
  auth: ["POST /api/auth/login", "GET /api/auth/me"],
  matters: [
    "POST /api/matters",
    "GET /api/matters",
    "GET /api/matters/:id/memory",
    "POST /api/matters/:id/memory",
  ],
  workflows: [
    "GET /api/workflows",
    "GET /api/workflows/categories",
    "GET /api/workflows/:id",
    "POST /api/workflows/:id/execute",
  ],
} as const;
