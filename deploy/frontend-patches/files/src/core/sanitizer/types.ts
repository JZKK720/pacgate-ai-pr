/** Mirror of pacgate-api's SanitizeStatusResponse (crates/pacgate-api/src/sanitize.rs). */
export interface SanitizeStatusResponse {
  document_state: string;
  chunk_states: string[];
  latest_job: string | null;
}

/** One sanitize job as the panel shows it - evidence metadata only. */
export interface SanitizeJobSummary {
  job_id: string;
  document_id: string;
  document_version: number;
  data_level: string;
  verdict: string;
  redaction_count: number;
  mapping_count: number;
  allow_auto_pass: boolean;
  require_human_review: boolean;
}

export type EgressState =
  | "pending"
  | "sanitized"
  | "blocked"
  | "never";

/** Fields the panel reads from the spine's Document (pacgate-core lib.rs:248). */
export interface DocumentMeta {
  id: string;
  matter_id: string;
  name: string;
  format: string;
  version: number;
}
