import { HttpQmPacgateGateway, } from "./qm_pacgate_contract.js";
import { QmPacgateRuntime, buildMatterDescription, deriveMatterName, deriveScopeBinding, } from "./qm_pacgate_runtime.js";
function normalizeSlugPart(input) {
    const slug = input
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
    return slug || "scope";
}
export function buildWorkspaceSlug(scope) {
    const org = normalizeSlugPart(scope.orgId);
    const channel = normalizeSlugPart(scope.channelId ?? scope.channelName ?? "channel");
    return `${org}__${channel}`;
}
export function createQmPacgateWrapper(config) {
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
export function buildScopedMatterDescription(scope, extraDescription) {
    return buildMatterDescription(scope, extraDescription);
}
