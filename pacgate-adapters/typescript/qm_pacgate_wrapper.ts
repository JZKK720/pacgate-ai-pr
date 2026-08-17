import {
  HttpQmPacgateGateway,
  type ExecuteWorkflowResponse,
  type Matter,
  type MatterMemoryRecord,
  type QmPacgateGateway,
  type UuidString,
} from "./qm_pacgate_contract.js";
import {
  QmPacgateRuntime,
  buildMatterDescription,
  deriveMatterName,
  deriveScopeBinding,
  type EnsureMatterOptions,
  type ExecuteWorkflowForScopeOptions,
  type PacgateScopeBinding,
  type QmScopeContext,
} from "./qm_pacgate_runtime.js";

export interface QmPacgateWrapperConfig {
  baseUrl: string;
  token: string;
  fetchImpl?: typeof fetch;
}

export interface QmPacgateWorkspaceBinding {
  matter: Matter;
  matterName: string;
  scopeBinding: PacgateScopeBinding;
  workspaceSlug: string;
}

export interface QmPacgateWrapper {
  gateway: QmPacgateGateway;
  runtime: QmPacgateRuntime;
  deriveScopeBinding(scope: QmScopeContext): PacgateScopeBinding;
  buildWorkspaceSlug(scope: QmScopeContext): string;
  ensureMatterForScope(scope: QmScopeContext, options?: EnsureMatterOptions): Promise<Matter>;
  buildWorkspaceBinding(
    scope: QmScopeContext,
    options?: EnsureMatterOptions
  ): Promise<QmPacgateWorkspaceBinding>;
  loadMatterMemory(scope: QmScopeContext, options?: EnsureMatterOptions): Promise<MatterMemoryRecord>;
  saveMatterMemory(
    scope: QmScopeContext,
    memory: MatterMemoryRecord,
    options?: EnsureMatterOptions
  ): Promise<MatterMemoryRecord>;
  executeWorkflowForScope(
    scope: QmScopeContext,
    options: ExecuteWorkflowForScopeOptions
  ): Promise<ExecuteWorkflowResponse>;
}

function normalizeSlugPart(input: string): string {
  const slug = input
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return slug || "scope";
}

export function buildWorkspaceSlug(scope: QmScopeContext): string {
  const org = normalizeSlugPart(scope.orgId);
  const channel = normalizeSlugPart(scope.channelId ?? scope.channelName ?? "channel");
  return `${org}__${channel}`;
}

export function createQmPacgateWrapper(config: QmPacgateWrapperConfig): QmPacgateWrapper {
  const gateway = new HttpQmPacgateGateway(config.baseUrl, config.fetchImpl);
  const runtime = new QmPacgateRuntime(gateway);

  return {
    gateway,
    runtime,
    deriveScopeBinding,
    buildWorkspaceSlug,
    async ensureMatterForScope(scope, options = {}) {
      return runtime.ensureMatterForScope(config.token, scope, options);
    },
    async buildWorkspaceBinding(scope, options = {}) {
      const matter = await runtime.ensureMatterForScope(config.token, scope, options);
      return {
        matter,
        matterName: deriveMatterName(scope),
        scopeBinding: deriveScopeBinding(scope),
        workspaceSlug: buildWorkspaceSlug(scope),
      };
    },
    async loadMatterMemory(scope, options = {}) {
      const matter = await runtime.ensureMatterForScope(config.token, scope, options);
      return gateway.getMatterMemory(config.token, matter.id);
    },
    async saveMatterMemory(scope, memory, options = {}) {
      const matter = await runtime.ensureMatterForScope(config.token, scope, options);
      return gateway.saveMatterMemory(config.token, matter.id, memory);
    },
    async executeWorkflowForScope(scope, options) {
      return runtime.executeWorkflowForScope(config.token, scope, options);
    },
  };
}

export function buildScopedMatterDescription(
  scope: QmScopeContext,
  extraDescription?: string
): string {
  return buildMatterDescription(scope, extraDescription);
}