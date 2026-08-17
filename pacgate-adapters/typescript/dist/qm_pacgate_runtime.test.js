import test from "node:test";
import assert from "node:assert/strict";
import { QmPacgateRuntime, buildMatterDescription, deriveMatterName, deriveScopeBinding, } from "./qm_pacgate_runtime.js";
class FakeGateway {
    matters = [];
    createdMatterRequests = [];
    executeCalls = [];
    async login() {
        throw new Error("not used");
    }
    async me() {
        throw new Error("not used");
    }
    async createMatter(_token, input) {
        this.createdMatterRequests.push(input);
        const matter = {
            id: `matter-${this.createdMatterRequests.length}`,
            tenant_id: "tenant-1",
            name: input.name,
            description: input.description ?? null,
            external_key: input.external_key ?? null,
            persona_id: input.persona_id ?? null,
            created_by: "user-1",
            created_at: "2026-08-15T00:00:00Z",
            updated_at: "2026-08-15T00:00:00Z",
        };
        this.matters.push(matter);
        return matter;
    }
    async listMatters() {
        return this.matters;
    }
    async getMatterMemory() {
        throw new Error("not used");
    }
    async saveMatterMemory() {
        throw new Error("not used");
    }
    async listWorkflows() {
        throw new Error("not used");
    }
    async listWorkflowCategories() {
        throw new Error("not used");
    }
    async getWorkflow() {
        throw new Error("not used");
    }
    async executeWorkflow(_token, workflowId, input) {
        const call = {
            workflowId,
            matterId: input.matter_id,
        };
        if (input.persona_id) {
            call.personaId = input.persona_id;
        }
        this.executeCalls.push(call);
        return {
            workflow_name: "Workflow",
            steps: [],
            final_content: `executed:${workflowId}:${input.matter_id}`,
        };
    }
}
test("deriveScopeBinding maps QM scope keys into pacgate bridge keys", () => {
    const scope = {
        orgId: "org-1",
        channelId: "channel-1",
        channelName: "M&A Matter",
        teamId: "team-1",
        personalEmail: "lawyer@example.com",
    };
    assert.deepEqual(deriveScopeBinding(scope), {
        tenantExternalKey: "org-1",
        matterExternalKey: "channel-1",
        practiceGroupExternalKey: "team-1",
        actorExternalKey: "lawyer@example.com",
        matterName: "M&A Matter",
    });
});
test("ensureMatterForScope reuses existing matter linked by QM channel id", async () => {
    const gateway = new FakeGateway();
    gateway.matters = [
        {
            id: "matter-existing",
            tenant_id: "tenant-1",
            name: "Existing Matter",
            description: "Linked QM scope\nqm.orgId=org-1\nqm.channelId=channel-1",
            external_key: "channel-1",
            persona_id: null,
            created_by: "user-1",
            created_at: "2026-08-15T00:00:00Z",
            updated_at: "2026-08-15T00:00:00Z",
        },
    ];
    const runtime = new QmPacgateRuntime(gateway);
    const matter = await runtime.ensureMatterForScope("token", {
        orgId: "org-1",
        channelId: "channel-1",
        channelName: "Should Not Create",
    });
    assert.equal(matter.id, "matter-existing");
    assert.equal(gateway.createdMatterRequests.length, 0);
});
test("ensureMatterForScope creates a new matter when no mapping exists", async () => {
    const gateway = new FakeGateway();
    const runtime = new QmPacgateRuntime(gateway);
    const matter = await runtime.ensureMatterForScope("token", {
        orgId: "org-1",
        channelId: "channel-22",
        channelName: "Acquisition Review",
        teamId: "team-legal",
        personalUserId: "attorney-7",
    }, {
        description: "Created from qm runtime",
        personaId: "persona-1",
    });
    assert.equal(matter.name, "Acquisition Review");
    assert.equal(gateway.createdMatterRequests.length, 1);
    assert.equal(gateway.createdMatterRequests[0]?.external_key, "channel-22");
    assert.equal(gateway.createdMatterRequests[0]?.persona_id, "persona-1");
    assert.match(gateway.createdMatterRequests[0]?.description ?? "", /qm\.channelId=channel-22/);
    assert.match(gateway.createdMatterRequests[0]?.description ?? "", /Created from qm runtime/);
});
test("executeWorkflowForScope resolves matter before execution", async () => {
    const gateway = new FakeGateway();
    const runtime = new QmPacgateRuntime(gateway);
    const result = await runtime.executeWorkflowForScope("token", {
        orgId: "org-2",
        channelId: "channel-77",
    }, {
        workflowId: "workflow-9",
        personaId: "persona-9",
    });
    assert.equal(result.final_content, "executed:workflow-9:matter-1");
    assert.deepEqual(gateway.executeCalls[0], {
        workflowId: "workflow-9",
        matterId: "matter-1",
        personaId: "persona-9",
    });
});
test("helper functions build stable QM matter metadata", () => {
    assert.equal(deriveMatterName({ orgId: "org", channelId: "42" }), "QM Channel 42");
    assert.match(buildMatterDescription({ orgId: "org", channelId: "chan", personalEmail: "a@b.com" }), /qm\.channelId=chan/);
});
