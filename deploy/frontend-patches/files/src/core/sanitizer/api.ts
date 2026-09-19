import { fetch } from "@/core/api/fetcher";
import { getBackendBaseURL } from "@/core/config";

import type { SanitizeStatusResponse } from "./types";

/**
 * Read one document's sanitization status through the pacgate proxy route.
 *
 * 404 is a normal state for an un-sanitized document, so it resolves to
 * `null` rather than an error - the panel renders "not sanitized yet" and
 * must not toast. 5xx is a real failure and must surface.
 */
export async function fetchSanitizeStatus(
  documentId: string,
): Promise<SanitizeStatusResponse | null> {
  const response = await fetch(
    `${getBackendBaseURL()}/api/pacgate/documents/${encodeURIComponent(documentId)}/sanitize-status`,
  );
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(
      `Failed to load sanitize status: ${response.statusText}`,
    );
  }
  return response.json() as Promise<SanitizeStatusResponse>;
}
