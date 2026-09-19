/**
 * Tests for the sanitizer review client (plan 021).
 *
 * The client must classify three states correctly: a 200 payload, a 404
 * (document not yet sanitized or nonexistent), and a gateway failure. It
 * must NEVER parse a mapping: the response shape has no mapping field, and
 * if one ever appears the client must ignore it (vault isolation, design 3.4).
 */
import { beforeEach, describe, expect, test, rs } from "@rstest/core";

rs.mock("@/core/api/fetcher", () => ({
  fetch: rs.fn(),
}));

rs.mock("@/core/config", () => ({
  getBackendBaseURL: () => "",
}));

import { fetchSanitizeStatus } from "@/core/sanitizer/api";
import { fetch as fetcher } from "@/core/api/fetcher";

const mockedFetch = rs.mocked(fetcher);

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

beforeEach(() => {
  mockedFetch.mockReset();
});

describe("fetchSanitizeStatus", () => {
  test("returns the status payload on 200", async () => {
    mockedFetch.mockResolvedValueOnce(
      jsonResponse(200, {
        document_state: "sanitized",
        chunk_states: ["sanitized"],
        latest_job: "abc-123",
      }),
    );
    const status = await fetchSanitizeStatus("doc-1");
    expect(status).toEqual({
      document_state: "sanitized",
      chunk_states: ["sanitized"],
      latest_job: "abc-123",
    });
    // The path must target the pacgate proxy, not the deer-flow gateway.
    expect(mockedFetch.mock.calls[0]![0]).toContain(
      "/api/pacgate/documents/doc-1/sanitize-status",
    );
  });

  test("returns null on 404 rather than throwing (not-yet-sanitized is normal)", async () => {
    mockedFetch.mockResolvedValueOnce(jsonResponse(404, { detail: "not found" }));
    const status = await fetchSanitizeStatus("doc-1");
    expect(status).toBeNull();
  });

  test("throws on 500 (a silent failure would hide a gate problem)", async () => {
    mockedFetch.mockResolvedValueOnce(jsonResponse(500, { detail: "boom" }));
    await expect(fetchSanitizeStatus("doc-1")).rejects.toThrow();
  });
});
