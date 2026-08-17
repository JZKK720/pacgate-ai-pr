import { type ExecuteWorkflowResponse, type Matter, type MatterMemoryRecord, type QmPacgateGateway } from "./qm_pacgate_contract.js";
import { QmPacgateRuntime, type EnsureMatterOptions, type ExecuteWorkflowForScopeOptions, type PacgateScopeBinding, type QmScopeContext } from "./qm_pacgate_runtime.js";
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
    buildWorkspaceBinding(scope: QmScopeContext, options?: EnsureMatterOptions): Promise<QmPacgateWorkspaceBinding>;
    loadMatterMemory(scope: QmScopeContext, options?: EnsureMatterOptions): Promise<MatterMemoryRecord>;
    saveMatterMemory(scope: QmScopeContext, memory: MatterMemoryRecord, options?: EnsureMatterOptions): Promise<MatterMemoryRecord>;
    executeWorkflowForScope(scope: QmScopeContext, options: ExecuteWorkflowForScopeOptions): Promise<ExecuteWorkflowResponse>;
}
export declare function buildWorkspaceSlug(scope: QmScopeContext): string;
export declare function createQmPacgateWrapper(config: QmPacgateWrapperConfig): QmPacgateWrapper;
export declare function buildScopedMatterDescription(scope: QmScopeContext, extraDescription?: string): string;
