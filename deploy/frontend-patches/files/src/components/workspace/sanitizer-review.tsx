"use client";

import { FileCheck2Icon, FileWarningIcon, Loader2Icon, ShieldAlertIcon, ShieldCheckIcon } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { useSanitizeStatus } from "@/core/sanitizer";
import { useI18n } from "@/core/i18n/hooks";

/** i18n keys live under t.sanitizer (added in Task 4). */
export const PACGATE_DOC_METADATA_KEY = "pacgate_document_id";

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

export function SanitizerReviewPanel({
  className,
  documentId,
}: {
  className?: string;
  documentId: string | null;
}) {
  const { t } = useI18n();
  const { status, isLoading, error } = useSanitizeStatus(documentId);

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

        {!isLoading && documentId && !status && (
          <div className="text-muted-foreground flex items-start gap-2">
            <FileWarningIcon className="text-muted-foreground size-4 shrink-0" />
            <span>{t.sanitizer.notSanitized}</span>
          </div>
        )}

        {!isLoading && status && (
          <>
            <div className="flex items-center justify-between gap-2">
              <span className="text-muted-foreground">
                {t.sanitizer.egressState}
              </span>
              <StateBadge
                state={status.document_state}
                label={t.sanitizer.states[status.document_state as keyof typeof t.sanitizer.states] ?? status.document_state}
              />
            </div>
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
            {status.latest_job && (
              <div className="text-muted-foreground truncate text-xs">
                {t.sanitizer.latestJob}: {status.latest_job}
              </div>
            )}
            {status.document_state === "blocked" && (
              <div className="text-destructive-foreground bg-destructive/10 flex items-start gap-2 rounded-md p-2">
                <ShieldAlertIcon className="size-4 shrink-0" />
                <span>{t.sanitizer.blockedNote}</span>
              </div>
            )}
            <p className="text-muted-foreground/80 text-xs">
              {t.sanitizer.reviewNote}
            </p>
          </>
        )}
      </CardContent>
    </Card>
  );
}
