import { useQuery } from "@tanstack/react-query";

import { fetchSanitizeStatus } from "./api";

/**
 * Poll one document's sanitize status. Refetches on window focus so the
 * panel tracks jobs the sanitizer agent runs in other threads.
 */
export function useSanitizeStatus(documentId: string | null | undefined) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["pacgate", "sanitize-status", documentId],
    queryFn: () => fetchSanitizeStatus(documentId!),
    enabled: !!documentId,
  });
  return { status: data ?? null, isLoading, error };
}
