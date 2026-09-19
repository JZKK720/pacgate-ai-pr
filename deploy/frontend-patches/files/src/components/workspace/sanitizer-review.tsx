"use client";

import {
  FileWarningIcon,
  Loader2Icon,
  ShieldAlertIcon,
  ShieldCheckIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { useDocumentMeta, useSanitizeStatus } from "@/core/sanitizer";
import type { LastJobSummary } from "@/core/sanitizer";
import { useI18n } from "@/core/i18n/hooks";

/**
 * Trivial `{placeholder}` interpolation. Translations may reorder or repeat
 * placeholders, so every occurrence is replaced independently - a plain
 * string replace, no ICU dependency (plan 022).
 */
function fill(
  template: string,
  vars: Record<string, string | number>,
): string {
  return template.replace(/\{(\w+)\}/g, (match: string, key: string) =>
    key in vars ? String(vars[key]) : match,
  );
}

function StateBadge({ state, label }: { state: string; label: string }) {
  const variant =
    state === "sanitized"
      ? "default"
      : state === "blocked"
        ? "destructive"
        : "secondary";
  return (
    <Badge variant={variant} className="text-xs">
      {label}
    </Badge>
  );
}

/**
 * Read-only sanitizer review surface (DESIGN.md review-panel). Document
 * identity and the last job's outcome arrive as props from the workspace
 * shell; the panel fetches only document metadata and sanitize status.
 */
export function SanitizerReviewPanel({
  className,
  documentId,
  lastJob,
}: {
  className?: string;
  documentId: string | null;
  lastJob: LastJobSummary | null;
}) {
  const { t } = useI18n();
  const { status, isLoading, error: loadError } = useSanitizeStatus(documentId);
  const { doc } = useDocumentMeta(documentId);

  return (
    <Card className={className}>
      <CardHeader className="pb-2">
        <CardTitle className="flex items-center gap-2 text-sm font-medium">
          <ShieldCheckIcon className="text-primary size-4" />
          {t.sanitizer.title}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        {isLoading && (
          <div className="text-muted-foreground flex items-center gap-2">
            <Loader2Icon className="size-4 animate-spin" />
            {t.common.loading}
          </div>
        )}

        {!isLoading && !documentId && (
          <div className="text-muted-foreground flex items-start gap-2">
            <FileWarningIcon className="text-muted-foreground size-4 shrink-0" />
            <span>{t.sanitizer.noDocument}</span>
          </div>
        )}

        {!isLoading && documentId && loadError && !status && (
          <div className="text-destructive flex items-start gap-2">
            <FileWarningIcon className="size-4 shrink-0" />
            <span>{t.sanitizer.loadFailed}</span>
          </div>
        )}

        {!isLoading && documentId && !status && !loadError && (
          <div className="text-muted-foreground flex items-start gap-2">
            <FileWarningIcon className="text-muted-foreground size-4 shrink-0" />
            <span>{t.sanitizer.notSanitized}</span>
          </div>
        )}

        {!isLoading && status && (
          <>
            <div className="space-y-1">
              <div className="text-sm font-medium">
                {doc?.name ?? t.sanitizer.docHeader}
              </div>
              {doc && (
                <div className="text-xs text-muted-foreground">
                  {fill(t.sanitizer.docMetaLine, {
                    format: doc.format,
                    version: doc.version,
                  })}
                </div>
              )}
            </div>
            <Separator />
            <div className="flex items-center justify-between gap-2">
              <span className="text-muted-foreground">
                {t.sanitizer.egressState}
              </span>
              <StateBadge
                state={status.document_state}
                label={t.sanitizer.states[status.document_state as keyof typeof t.sanitizer.states] ?? status.document_state}
              />
            </div>
            {lastJob && (
              <div className="space-y-1">
                {status.document_state !== "blocked" && (
                  <p
                    className={
                      lastJob.verdict === "block"
                        ? "text-destructive"
                        : undefined
                    }
                  >
                    {lastJob.verdict === "pass"
                      ? t.sanitizer.verdictPass
                      : t.sanitizer.verdictBlock}
                  </p>
                )}
                <p className="text-muted-foreground">
                  {fill(t.sanitizer.redacted, {
                    count: lastJob.redactionCount,
                  })}
                </p>
                <p className="text-muted-foreground">
                  {t.sanitizer.mappingSealed}
                </p>
                {lastJob.requireHumanReview && (
                  <p className="text-muted-foreground">
                    {t.sanitizer.humanReviewFlag}
                  </p>
                )}
              </div>
            )}
            {status.document_state === "blocked" && (
              <div className="text-destructive-foreground bg-destructive/10 flex items-start gap-2 rounded-md p-2">
                <ShieldAlertIcon className="size-4 shrink-0" />
                <span>{t.sanitizer.verdictBlock}</span>
              </div>
            )}
            {status.chunk_states.length > 0 && (
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">
                  {t.sanitizer.chunkStates}
                </span>
                <span className="flex flex-wrap justify-end gap-1">
                  {status.chunk_states.map((s, i) => (
                    <Badge key={`${s}-${i}`} variant="outline" className="text-xs">
                      {t.sanitizer.states[s as keyof typeof t.sanitizer.states] ?? s}
                    </Badge>
                  ))}
                </span>
              </div>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}
