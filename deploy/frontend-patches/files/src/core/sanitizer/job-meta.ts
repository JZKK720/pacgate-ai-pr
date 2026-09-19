/**
 * The sanitizer agent records each job's outcome into thread metadata under
 * this key as a JSON string. The panel parses it tolerantly: the agent's
 * metadata is untrusted input, and a malformed entry must degrade to "no job
 * shown", never break the panel. Counts only - never mapping contents.
 */
export const PACGATE_LAST_JOB_KEY = "pacgate_last_job";

import type { LastJobSummary } from "./types";

/**
 * Parse the `pacgate_last_job` thread-metadata entry into a LastJobSummary.
 *
 * Every failure mode - missing key, non-string value, malformed JSON, or a
 * field outside its contract - resolves to `null` rather than throwing.
 * Fields arrive in snake_case from the agent's metadata JSON and are mapped
 * to the camelCase panel shape.
 */
export function readLastJobFromMetadata(
  metadata: Record<string, unknown> | undefined,
): LastJobSummary | null {
  if (!metadata) {
    return null;
  }
  const raw = metadata[PACGATE_LAST_JOB_KEY];
  if (typeof raw !== "string") {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) {
    return null;
  }
  const record = parsed as Record<string, unknown>;

  const jobId = record.job_id;
  if (typeof jobId !== "string" || jobId.length === 0) {
    return null;
  }
  const verdict = record.verdict;
  if (verdict !== "pass" && verdict !== "block") {
    return null;
  }
  const redactionCount = record.redaction_count;
  if (
    typeof redactionCount !== "number" ||
    !Number.isInteger(redactionCount) ||
    redactionCount < 0
  ) {
    return null;
  }
  const mappingCount = record.mapping_count;
  if (
    typeof mappingCount !== "number" ||
    !Number.isInteger(mappingCount) ||
    mappingCount < 0
  ) {
    return null;
  }
  const dataLevel = record.data_level;
  if (typeof dataLevel !== "string" || dataLevel.length === 0) {
    return null;
  }
  const requireHumanReview = record.require_human_review;
  if (typeof requireHumanReview !== "boolean") {
    return null;
  }
  const reason = record.reason;
  if (typeof reason !== "string") {
    return null;
  }

  return {
    jobId,
    verdict,
    redactionCount,
    mappingCount,
    dataLevel,
    requireHumanReview,
    reason,
  };
}