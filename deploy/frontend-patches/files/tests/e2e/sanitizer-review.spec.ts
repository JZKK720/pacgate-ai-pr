import { expect, test } from "@playwright/test";

import { mockLangGraphAPI } from "./utils/mock-api";

const MOCK_AGENTS = [
  {
    name: "sanitizer",
    description: "Client-identity sanitizer",
    system_prompt: "You are the sanitizer agent.",
  },
];

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
});
