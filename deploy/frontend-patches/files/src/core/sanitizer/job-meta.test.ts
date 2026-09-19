/**
 * Tests for the tolerant last-job metadata parser (plan 022 Task 2).
 *
 * The sanitizer agent writes `pacgate_last_job` into thread metadata; the
 * panel must treat it as untrusted input. Every malformed shape resolves to
 * null - the parser never throws, and the panel degrades to "no job shown".
 */
import { describe, expect, test } from "@rstest/core";

import {
  PACGATE_LAST_JOB_KEY,
  readLastJobFromMetadata,
} from "@/core/sanitizer/job-meta";

const VALID_JOB = {
  job_id: "job-1",
  verdict: "pass",
  redaction_count: 4,
  mapping_count: 7,
  data_level: "internal",
  require_human_review: false,
  reason: "4 identifiers redacted",
};

function metadataWith(value: unknown): Record<string, unknown> {
  return { [PACGATE_LAST_JOB_KEY]: value };
}

describe("readLastJobFromMetadata", () => {
  test("parses a valid JSON string into the full summary", () => {
    const job = readLastJobFromMetadata(
      metadataWith(JSON.stringify(VALID_JOB)),
    );
    expect(job).toEqual({
      jobId: "job-1",
      verdict: "pass",
      redactionCount: 4,
      mappingCount: 7,
      dataLevel: "internal",
      requireHumanReview: false,
      reason: "4 identifiers redacted",
    });
  });

  test("returns null when the metadata key is missing", () => {
    expect(readLastJobFromMetadata({})).toBeNull();
  });

  test("returns null when the value is a number rather than a string", () => {
    expect(readLastJobFromMetadata(metadataWith(42))).toBeNull();
  });

  test("returns null when the value is an object rather than a string", () => {
    expect(readLastJobFromMetadata(metadataWith(VALID_JOB))).toBeNull();
  });

  test("returns null on malformed JSON", () => {
    expect(readLastJobFromMetadata(metadataWith("{not json"))).toBeNull();
  });

  test("returns null when JSON parses to a non-object (string payload)", () => {
    expect(
      readLastJobFromMetadata(metadataWith('"just a string"')),
    ).toBeNull();
  });

  test("returns null on an unknown verdict value", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, verdict: "blocked" })),
      ),
    ).toBeNull();
  });

  test("returns null on a negative redaction count", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, redaction_count: -1 })),
      ),
    ).toBeNull();
  });

  test("returns null on a non-integer mapping count", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, mapping_count: 1.5 })),
      ),
    ).toBeNull();
  });

  test("returns null on a non-boolean require_human_review", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(
          JSON.stringify({ ...VALID_JOB, require_human_review: "no" }),
        ),
      ),
    ).toBeNull();
  });

  test("returns null on an empty jobId", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, job_id: "" })),
      ),
    ).toBeNull();
  });

  test("returns null on a non-string data_level", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, data_level: 3 })),
      ),
    ).toBeNull();
  });

  test("returns null on a non-string reason", () => {
    expect(
      readLastJobFromMetadata(
        metadataWith(JSON.stringify({ ...VALID_JOB, reason: 99 })),
      ),
    ).toBeNull();
  });

  test("accepts an empty reason string (reason may be empty)", () => {
    const job = readLastJobFromMetadata(
      metadataWith(JSON.stringify({ ...VALID_JOB, reason: "" })),
    );
    expect(job?.reason).toBe("");
  });

  test("returns null when the metadata argument is undefined", () => {
    expect(readLastJobFromMetadata(undefined)).toBeNull();
  });

  test("exports the shared metadata key constant", () => {
    expect(PACGATE_LAST_JOB_KEY).toBe("pacgate_last_job");
  });
});