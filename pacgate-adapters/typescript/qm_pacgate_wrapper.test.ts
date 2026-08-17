import test from "node:test";
import assert from "node:assert/strict";

import { createQmPacgateWrapper } from "./qm_pacgate_wrapper.js";

function createFetchStub() {
  const calls: Array<{ url: string; init?: RequestInit }> = [];

  const fetchStub: typeof fetch = async (input, init) => {
    const url = String(input);
    if (init) {
      calls.push({ url, init });
    } else {
      calls.push({ url });
    }

    if (url.endsWith("/api/matters") && init?.method === "GET") {
      return new Response(JSON.stringify([]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (url.endsWith("/api/matters") && init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      return new Response(
        JSON.stringify({
          id: "matter-1",
          tenant_id: "tenant-1",
          name: body.name,
          description: body.description ?? null,
          external_key: body.external_key ?? null,
          persona_id: body.persona_id ?? null,
          created_by: "user-1",
          created_at: "2026-08-15T00:00:00Z",
          updated_at: "2026-08-15T00:00:00Z",
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    if (url.endsWith("/api/matters/matter-1/memory") && init?.method === "GET") {
      return new Response(JSON.stringify({ revision: 3, facts: ["remember"] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (url.endsWith("/api/matters/matter-1/memory") && init?.method === "POST") {
      return new Response(String(init.body), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (url.endsWith("/api/workflows/workflow-1/execute") && init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      return new Response(
        JSON.stringify({
          workflow_name: "Workflow",
          steps: [],
          final_content: `executed:${body.matter_id}`,
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    throw new Error(`unexpected request: ${init?.method ?? "GET"} ${url}`);
  };

  return { fetchStub, calls };
}

test("wrapper scaffold builds a stable workspace binding", async () => {
  const { fetchStub } = createFetchStub();
  const wrapper = createQmPacgateWrapper({
    baseUrl: "http://pacgate-api:8080",
    token: "token",
    fetchImpl: fetchStub,
  });

  const binding = await wrapper.buildWorkspaceBinding({
    orgId: "Org 1",
    channelId: "Channel 77",
    channelName: "M&A Review",
    teamId: "Team Legal",
  });

  assert.equal(binding.matter.id, "matter-1");
  assert.equal(binding.scopeBinding.matterExternalKey, "Channel 77");
  assert.equal(binding.workspaceSlug, "org-1__channel-77");
});

test("wrapper scaffold routes matter memory through pacgate APIs", async () => {
  const { fetchStub, calls } = createFetchStub();
  const wrapper = createQmPacgateWrapper({
    baseUrl: "http://pacgate-api:8080",
    token: "token",
    fetchImpl: fetchStub,
  });

  const scope = {
    orgId: "org-1",
    channelId: "channel-9",
  };

  const memory = await wrapper.loadMatterMemory(scope);
  assert.deepEqual(memory, { revision: 3, facts: ["remember"] });

  const saved = await wrapper.saveMatterMemory(scope, { revision: 4, facts: ["persist"] });
  assert.deepEqual(saved, { revision: 4, facts: ["persist"] });

  const methods = calls.map((call) => `${call.init?.method ?? "GET"} ${call.url}`);
  assert.ok(methods.includes("GET http://pacgate-api:8080/api/matters/matter-1/memory"));
  assert.ok(methods.includes("POST http://pacgate-api:8080/api/matters/matter-1/memory"));
});

test("wrapper scaffold executes workflows through the resolved matter", async () => {
  const { fetchStub } = createFetchStub();
  const wrapper = createQmPacgateWrapper({
    baseUrl: "http://pacgate-api:8080",
    token: "token",
    fetchImpl: fetchStub,
  });

  const result = await wrapper.executeWorkflowForScope(
    { orgId: "org-1", channelId: "channel-2" },
    { workflowId: "workflow-1" }
  );

  assert.equal(result.final_content, "executed:matter-1");
});