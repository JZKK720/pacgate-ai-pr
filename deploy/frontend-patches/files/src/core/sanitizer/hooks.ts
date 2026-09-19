import { useQuery } from "@tanstack/react-query";

import { fetchDocumentMeta, fetchSanitizeStatus } from "./api";

/**
 * Read one document's sanitize status. Refetches on window focus so the
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

/**
 * Read one document's identity. Shares the status hook's conventions:
 * disabled without an id, no refetch on window focus, null before it exists.
 */
export function useDocumentMeta(documentId: string | null | undefined) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["pacgate", "document-meta", documentId],
    queryFn: () => fetchDocumentMeta(documentId!),
    enabled: !!documentId,
  });
  return { doc: data ?? null, isLoading, error };
}
