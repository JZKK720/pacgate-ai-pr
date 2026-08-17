import { HttpQmPacgateGateway, } from "./qm_pacgate_contract.js";
export function deriveScopeBinding(scope) {
    const binding = {
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
export function deriveMatterName(scope) {
    if (scope.channelName?.trim()) {
        return scope.channelName.trim();
    }
    if (scope.channelId?.trim()) {
        return `QM Channel ${scope.channelId.trim()}`;
    }
    throw new Error("QM scope needs channelName or channelId to map to a pacgate matter");
}
export function buildMatterDescription(scope, extraDescription) {
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
function matchesExistingMatter(matter, scope) {
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
    gateway;
    constructor(gateway) {
        this.gateway = gateway;
    }
    static fromBaseUrl(baseUrl, fetchImpl) {
        return new QmPacgateRuntime(new HttpQmPacgateGateway(baseUrl, fetchImpl));
    }
    async listWorkflowCategories(token) {
        return this.gateway.listWorkflowCategories(token);
    }
    async listWorkflows(token, category, search) {
        const query = {};
        if (category) {
            query.category = category;
        }
        if (search) {
            query.search = search;
        }
        return this.gateway.listWorkflows(token, query);
    }
    async getWorkflow(token, workflowId) {
        return this.gateway.getWorkflow(token, workflowId);
    }
    async ensureMatterForScope(token, scope, options = {}) {
        const matters = await this.gateway.listMatters(token);
        const existing = matters.find((matter) => matchesExistingMatter(matter, scope));
        if (existing) {
            return existing;
        }
        const request = {
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
    async executeWorkflowForScope(token, scope, options) {
        const matter = await this.ensureMatterForScope(token, scope, options);
        const request = {
            matter_id: matter.id,
        };
        if (options.personaId) {
            request.persona_id = options.personaId;
        }
        return this.gateway.executeWorkflow(token, options.workflowId, request);
    }
}
