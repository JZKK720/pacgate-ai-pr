import { expect, test } from "@playwright/test";

import { MOCK_THREAD_ID, mockLangGraphAPI } from "./utils/mock-api";

const MOCK_AGENTS = [
  {
    name: "sanitizer",
    description: "Client-identity sanitizer",
    system_prompt: "You are the sanitizer agent.",
  },
];

// Thread metadata keys written by the sanitizer agent. The single
// definition site is src/core/sanitizer/job-meta.ts; the spec keeps local
// literals so the Playwright process never imports application code.
const DOC_METADATA_KEY = "pacgate_document_id";
const LAST_JOB_METADATA_KEY = "pacgate_last_job";

// An existing thread whose metadata carries the document identity and the
// last job's outcome - the shape the sanitizer agent writes (plan 022).
const SANITIZED_THREAD = {
  thread_id: MOCK_THREAD_ID,
  title: "Sanitized matter",
  agent_name: "sanitizer",
  metadata: {
    [DOC_METADATA_KEY]: "doc-e2e",
    [LAST_JOB_METADATA_KEY]: JSON.stringify({
      job_id: "job-e2e",
      verdict: "pass",
      redaction_count: 7,
      mapping_count: 7,
      data_level: "T3",
      require_human_review: false,
      reason: "ok",
    }),
  },
};

test.describe("Sanitizer review panel", () => {
  test("sanitizer agent chat shows the review panel", async ({ page }) => {
    mockLangGraphAPI(page, { agents: MOCK_AGENTS });
    await page.goto("/workspace/agents/sanitizer/chats/new");
    // The panel title renders even before a document is chosen (the
    // no-document state is the initial one).
    await expect(page.getByText("Sanitization review")).toBeVisible({
      timeout: 15_000,
    });
  });

  test("review panel title localizes to Chinese", async ({ page }) => {
    mockLangGraphAPI(page, { agents: MOCK_AGENTS });
    await page.goto("/workspace/agents/sanitizer/chats/new");
    // The locale is resolved server-side from the `locale` cookie, so set it
    // in the browser and reload for the SSR pass to pick it up.
    await page.evaluate(() => {
      document.cookie = "locale=zh-CN; path=/; max-age=31536000";
    });
    await page.reload();
    await expect(page.getByText("脱敏审查")).toBeVisible({
      timeout: 15_000,
    });
  });

  test("shows document identity and last-job outcome from thread metadata", async ({
    page,
  }) => {
    mockLangGraphAPI(page, {
      agents: MOCK_AGENTS,
      threads: [SANITIZED_THREAD],
    });
    // The panel reads document identity and sanitize status through the
    // pacgate proxy routes; both must answer for the job-outcome block to
    // render.
    void page.route("**/api/pacgate/documents/doc-e2e", (route) =>
      route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          id: "doc-e2e",
          matter_id: "matter-e2e",
          name: "settlement-agreement.docx",
          format: "docx",
          version: 3,
        }),
      }),
    );
    void page.route(
      "**/api/pacgate/documents/doc-e2e/sanitize-status",
      (route) =>
        route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            document_state: "sanitized",
            chunk_states: [],
            latest_job: "job-e2e",
          }),
        }),
    );

    // An existing thread (not /new) so the workspace shell reads its
    // metadata through the thread GET endpoint mocked by mockLangGraphAPI.
    await page.goto(`/workspace/agents/sanitizer/chats/${MOCK_THREAD_ID}`);

    await expect(page.getByText("settlement-agreement.docx")).toBeVisible({
      timeout: 15_000,
    });
    await expect(page.getByText("7 identifier(s) redacted")).toBeVisible();
  });
});
