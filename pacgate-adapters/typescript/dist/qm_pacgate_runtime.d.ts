import { type ExecuteWorkflowResponse, type Matter, type QmPacgateGateway, type UuidString, type WorkflowCategoryInfo, type WorkflowDetail, type WorkflowSummary } from "./qm_pacgate_contract.js";
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
export declare function deriveScopeBinding(scope: QmScopeContext): PacgateScopeBinding;
export declare function deriveMatterName(scope: QmScopeContext): string;
export declare function buildMatterDescription(scope: QmScopeContext, extraDescription?: string): string;
export declare class QmPacgateRuntime {
    private readonly gateway;
    constructor(gateway: QmPacgateGateway);
    static fromBaseUrl(baseUrl: string, fetchImpl?: typeof fetch): QmPacgateRuntime;
    listWorkflowCategories(token: string): Promise<WorkflowCategoryInfo[]>;
    listWorkflows(token: string, category?: string, search?: string): Promise<WorkflowSummary[]>;
    getWorkflow(token: string, workflowId: UuidString): Promise<WorkflowDetail>;
    ensureMatterForScope(token: string, scope: QmScopeContext, options?: EnsureMatterOptions): Promise<Matter>;
    executeWorkflowForScope(token: string, scope: QmScopeContext, options: ExecuteWorkflowForScopeOptions): Promise<ExecuteWorkflowResponse>;
}
