/*
 * QM <-> Pacgate API contract (Phase 2 collaboration runtime).
 *
 * Source of truth for endpoint alignment:
 * - pacgate-ai/crates/pacgate-api/src/lib.rs
 * - pacgate-ai/crates/pacgate-api/src/workflows.rs
 * - pacgate-ai/crates/pacgate-api/src/auth.rs
 * - pacgate-ai/crates/pacgate-api/src/matters.rs
 */
export class PacgateHttpError extends Error {
    status;
    body;
    constructor(status, body, message = "Pacgate API request failed") {
        super(message);
        this.status = status;
        this.body = body;
    }
}
function buildQuery(query) {
    if (!query)
        return "";
    const params = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) {
        if (v && v.trim() !== "")
            params.set(k, v);
    }
    const text = params.toString();
    return text ? `?${text}` : "";
}
export class HttpQmPacgateGateway {
    baseUrl;
    fetchImpl;
    constructor(baseUrl, fetchImpl = fetch) {
        this.baseUrl = baseUrl;
        this.fetchImpl = fetchImpl;
    }
    async request(path, init, token) {
        const headers = new Headers(init.headers ?? {});
        headers.set("Content-Type", "application/json");
        if (token)
            headers.set("Authorization", `Bearer ${token}`);
        const res = await this.fetchImpl(`${this.baseUrl}${path}`, {
            ...init,
            headers,
        });
        const json = await res.json().catch(() => undefined);
        if (!res.ok) {
            throw new PacgateHttpError(res.status, json, `HTTP ${res.status} ${path}`);
        }
        return json;
    }
    login(input) {
        return this.request("/api/auth/login", {
            method: "POST",
            body: JSON.stringify(input),
        });
    }
    me(token) {
        return this.request("/api/auth/me", { method: "GET" }, token);
    }
    createMatter(token, input) {
        return this.request("/api/matters", { method: "POST", body: JSON.stringify(input) }, token);
    }
    listMatters(token) {
        return this.request("/api/matters", { method: "GET" }, token);
    }
    getMatterMemory(token, matterId) {
        return this.request(`/api/matters/${matterId}/memory`, { method: "GET" }, token);
    }
    saveMatterMemory(token, matterId, memory) {
        return this.request(`/api/matters/${matterId}/memory`, { method: "POST", body: JSON.stringify(memory) }, token);
    }
    listWorkflows(token, query) {
        return this.request(`/api/workflows${buildQuery({ category: query?.category, search: query?.search })}`, { method: "GET" }, token);
    }
    listWorkflowCategories(token) {
        return this.request("/api/workflows/categories", { method: "GET" }, token);
    }
    getWorkflow(token, workflowId) {
        return this.request(`/api/workflows/${workflowId}`, { method: "GET" }, token);
    }
    executeWorkflow(token, workflowId, input) {
        return this.request(`/api/workflows/${workflowId}/execute`, { method: "POST", body: JSON.stringify(input) }, token);
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
};
