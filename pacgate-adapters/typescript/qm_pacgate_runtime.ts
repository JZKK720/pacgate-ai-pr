import {
  HttpQmPacgateGateway,
  type CreateMatterRequest,
  type ExecuteWorkflowResponse,
  type Matter,
  type QmPacgateGateway,
  type UuidString,
  type WorkflowCategoryInfo,
  type WorkflowDetail,
  type WorkflowSummary,
} from "./qm_pacgate_contract.js";

export interface QmScopeContext {
  orgId: string;
  orgName?: string;
  channelId?: string;
  channelName?: string;
  teamId?: string;
  teamName?: string;
  personalUserId?: string;
  personalEmail?: string;
  pacgateMatterId?: UuidString;
}

export interface PacgateScopeBinding {
  tenantExternalKey: string;
  matterExternalKey?: string;
  practiceGroupExternalKey?: string;
  actorExternalKey?: string;
  matterName?: string;
}

export interface EnsureMatterOptions {
  personaId?: UuidString;
  description?: string;
}

export interface ExecuteWorkflowForScopeOptions extends EnsureMatterOptions {
  workflowId: UuidString;
}

export function deriveScopeBinding(scope: QmScopeContext): PacgateScopeBinding {
  const binding: PacgateScopeBinding = {
    tenantExternalKey: scope.orgId,
  };

  if (scope.channelId) {
    binding.matterExternalKey = scope.channelId;
  }
  if (scope.teamId) {
    binding.practiceGroupExternalKey = scope.teamId;
  }
  const actorExternalKey = scope.personalUserId ?? scope.personalEmail;
  if (actorExternalKey) {
    binding.actorExternalKey = actorExternalKey;
  }
  if (scope.channelName?.trim()) {
    binding.matterName = scope.channelName.trim();
  }

  return binding;
}

export function deriveMatterName(scope: QmScopeContext): string {
  if (scope.channelName?.trim()) {
    return scope.channelName.trim();
  }
  if (scope.channelId?.trim()) {
    return `QM Channel ${scope.channelId.trim()}`;
  }
  throw new Error("QM scope needs channelName or channelId to map to a pacgate matter");
}

export function buildMatterDescription(
  scope: QmScopeContext,
  extraDescription?: string
): string {
  const lines = [
    "Linked QM scope",
    `qm.orgId=${scope.orgId}`,
    `qm.channelId=${scope.channelId ?? ""}`,
    `qm.teamId=${scope.teamId ?? ""}`,
    `qm.personalUserId=${scope.personalUserId ?? ""}`,
    `qm.personalEmail=${scope.personalEmail ?? ""}`,
  ];

  if (extraDescription?.trim()) {
    lines.push("", extraDescription.trim());
  }

  return lines.join("\n");
}

function matchesExistingMatter(matter: Matter, scope: QmScopeContext): boolean {
  if (scope.pacgateMatterId && matter.id === scope.pacgateMatterId) {
    return true;
  }

  if (scope.channelId && matter.external_key === scope.channelId) {
    return true;
  }

  if (!scope.channelId && scope.channelName?.trim() && matter.name === scope.channelName.trim()) {
    return true;
  }

  return false;
}

export class QmPacgateRuntime {
  constructor(private readonly gateway: QmPacgateGateway) {}

  static fromBaseUrl(baseUrl: string, fetchImpl?: typeof fetch): QmPacgateRuntime {
    return new QmPacgateRuntime(new HttpQmPacgateGateway(baseUrl, fetchImpl));
  }

  async listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]> {
    return this.gateway.listWorkflowCategories(token);
  }

  async listWorkflows(
    token: string,
    category?: string,
    search?: string
  ): Promise<WorkflowSummary[]> {
    const query: Record<string, string> = {};
    if (category) {
      query.category = category;
    }
    if (search) {
      query.search = search;
    }
    return this.gateway.listWorkflows(token, query);
  }

  async getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail> {
    return this.gateway.getWorkflow(token, workflowId);
  }

  async ensureMatterForScope(
    token: string,
    scope: QmScopeContext,
    options: EnsureMatterOptions = {}
  ): Promise<Matter> {
    const matters = await this.gateway.listMatters(token);
    const existing = matters.find((matter) => matchesExistingMatter(matter, scope));
    if (existing) {
      return existing;
    }

    const request: CreateMatterRequest = {
      name: deriveMatterName(scope),
      description: buildMatterDescription(scope, options.description),
    };

    if (scope.channelId?.trim()) {
      request.external_key = scope.channelId.trim();
    }

    if (options.personaId) {
      request.persona_id = options.personaId;
    }

    return this.gateway.createMatter(token, request);
  }

  async executeWorkflowForScope(
    token: string,
    scope: QmScopeContext,
    options: ExecuteWorkflowForScopeOptions
  ): Promise<ExecuteWorkflowResponse> {
    const matter = await this.ensureMatterForScope(token, scope, options);
    const request = {
      matter_id: matter.id,
    } as { matter_id: UuidString; persona_id?: UuidString };

    if (options.personaId) {
      request.persona_id = options.personaId;
    }

    return this.gateway.executeWorkflow(token, options.workflowId, request);
  }
}