# Sanitizer Review Panel Redesign - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sanitizer review panel answer the operator's actual questions - *which document am I looking at, what was redacted, and what is the verdict* - instead of showing only abstract state chips. The panel becomes a document-identity + job-outcome surface, still read-only, still vault-free.

**Architecture:** Three changes, all within existing data paths. (a) The sanitizer agent gains a SOUL rule to record each job's outcome into thread metadata under a new key `pacgate_last_job` (JSON: verdict, counts, level, reason - never mapping values, never sanitized text). (b) The panel fetches document identity (name, format, version, matter) via the existing `GET /api/pacgate/documents/:id` proxy path - no new backend route. (c) The panel re-renders per `deploy/frontend-patches/DESIGN.md`: document header (name + format + version + matter), egress state badge, job-outcome summary (counts in plain language), blocked note with the tint-container treatment, and bilingual copy rewritten per the impeccable-clarify message hierarchy.

**Tech Stack:** Next.js + TanStack Query + existing shadcn primitives only. Rust: none. Python: none (MCP tool responses already carry the needed fields - verified `deploy/pacgate-mcp/server.py:565-578`).

**Spec:** `deploy/frontend-patches/DESIGN.md` (Components + Do's and Don'ts sections are normative for this surface). Design doc for the workspace UI, committed at `6b66fbd`.

## Global Constraints

- **Read-only review surface.** No restore UI, no redaction triggers, no vault contents. The panel displays verdicts and COUNTS; the mapping column never leaves pacgate-api.
- **Data sources are fixed.** Thread metadata (agent-written), `GET /api/pacgate/documents/:id` (document identity), `GET /api/pacgate/documents/:id/sanitize-status` (state). No new spine endpoints, no new proxy capabilities (proxy stays GET-only).
- **DESIGN.md compliance.** Panel composes `Card`/`Badge`/`Separator` primitives; semantic tokens only; fixed rem scale (`text-sm` body, `text-xs` badges); blocked state = `bg-destructive/10` container + light foreground text; no new radii, fonts, or accent colors; 150-250 ms state transitions only.
- **Bilingual parity.** Every new string in BOTH `en-US.ts` and `zh-CN.ts` plus `types.ts`. Chinese strings carry full-width punctuation. The plan glosses Chinese in comments for the reader; comments are NOT part of file content.
- **Override mechanism.** All frontend changes are tracked files under `deploy/frontend-patches/files/` mirroring upstream paths; never edit `deploy/deer-flow-src/`.
- **Metadata key names are the seam.** `pacgate_document_id` (exists), `pacgate_last_job` (new). The SOUL and the panel both hardcode these via the shared exported constant - one definition site in `sanitizer-review.tsx`, re-used by SOUL text (documented string, not an import across the backend boundary).
- **Hyphens not em-dashes** in visible copy. English commits. The live DB is never restarted or modified.
- **pnpm on this machine:** `corepack pnpm`. Playwright E2E runs against the built image container (port 8123, `DEER_FLOW_AUTH_DISABLED=1`, base URL via temp config) - the upstream webServer flow hangs on this machine because port 3000 is taken by open-webui and the gateway is absent.

---

## Task 1: Document identity client + hook

**Files:**
- Modify: `deploy/frontend-patches/files/src/core/sanitizer/api.ts`
- Modify: `deploy/frontend-patches/files/src/core/sanitizer/types.ts`
- Modify: `deploy/frontend-patches/files/src/core/sanitizer/hooks.ts`

**Interfaces:**
- Consumes: `GET /api/pacgate/documents/:id` (the spine's existing endpoint, forwarded by the Task-1 proxy; returns the serialized `Document`: `id`, `matter_id`, `name`, `format`, `version`, `created_at`, `updated_at`).
- Produces: `fetchDocumentMeta(documentId)` -> `DocumentMeta | null` (404 -> null, mirroring `fetchSanitizeStatus`), and `useDocumentMeta(documentId)` with the same query conventions as `useSanitizeStatus` (`refetchOnWindowFocus: false`, `enabled: !!documentId`).

- [ ] **Step 1: Types** - add to `types.ts`:

```ts
/** Fields the panel reads from the spine's Document (pacgate-core lib.rs:248). */
export interface DocumentMeta {
  id: string;
  matter_id: string;
  name: string;
  format: string;
  version: number;
}
```

- [ ] **Step 2: Client** - add to `api.ts` (same 404-tolerant contract as `fetchSanitizeStatus`; 5xx throws):

```ts
export async function fetchDocumentMeta(
  documentId: string,
): Promise<DocumentMeta | null> {
  const response = await fetch(
    `${getBackendBaseURL()}/api/pacgate/documents/${encodeURIComponent(documentId)}`,
  );
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`Failed to load document metadata: ${response.statusText}`);
  }
  return response.json() as Promise<DocumentMeta>;
}
```

- [ ] **Step 3: Hook** - add to `hooks.ts`:

```ts
export function useDocumentMeta(documentId: string | null | undefined) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["pacgate", "document-meta", documentId],
    queryFn: () => fetchDocumentMeta(documentId!),
    enabled: !!documentId,
  });
  return { doc: data ?? null, isLoading, error };
}
```

- [ ] **Step 4: Unit tests** - extend `api.test.ts` with the same three-state pattern for `fetchDocumentMeta` (200 payload, 404 -> null, 500 -> throw) and a path assertion on `/api/pacgate/documents/doc-1` (no `/sanitize-status` suffix).

- [ ] **Step 5: Verify + commit**

```
corepack pnpm exec rstest run src/core/sanitizer/api.test.ts --include "src/**/*.test.ts"   # from deploy/deer-flow-src/frontend
```

Commit: `feat(frontend): document metadata client for review panel`

---

## Task 2: Job-outcome metadata contract + parser

**Files:**
- Modify: `deploy/frontend-patches/files/src/core/sanitizer/types.ts`
- Create: `deploy/frontend-patches/files/src/core/sanitizer/job-meta.ts`
- Modify: `deploy/frontend-patches/files/src/core/sanitizer/index.ts`

**Interfaces:**
- The sanitizer agent (SOUL, Task 4) writes thread metadata key `pacgate_last_job` with a JSON STRING value: `{"job_id":string,"verdict":"pass"|"block","redaction_count":number,"mapping_count":number,"data_level":string,"require_human_review":boolean,"reason":string}`.
- Produces: `readLastJobFromMetadata(metadata: Record<string, unknown> | undefined): LastJobSummary | null` - tolerant parser: missing key, non-string, or malformed JSON all return null (never throw). Export `PACGATE_LAST_JOB_KEY = "pacgate_last_job"` next to the existing `PACGATE_DOC_METADATA_KEY` (move the constant here; `sanitizer-review.tsx` re-exports for compatibility).

- [ ] **Step 1: Type** - add to `types.ts`:

```ts
/** What the panel may show about the latest sanitize job. Counts only - never mapping contents. */
export interface LastJobSummary {
  jobId: string;
  verdict: "pass" | "block";
  redactionCount: number;
  mappingCount: number;
  dataLevel: string;
  requireHumanReview: boolean;
  reason: string;
}
```

- [ ] **Step 2: Parser with failing tests first** - `job-meta.test.ts` (in `src/core/sanitizer/`, same `--include` flag as Task 1) covers: valid JSON string parses; missing key -> null; non-string value -> null; malformed JSON -> null; unknown verdict value -> null; negative counts rejected -> null. Then implement `readLastJobFromMetadata`.

- [ ] **Step 3: Barrel export** - `export * from "./job-meta";` in `index.ts`.

- [ ] **Step 4: Commit** - `feat(frontend): last-job thread metadata contract + tolerant parser`

---

## Task 3: Panel re-render (DESIGN.md compliant)

**Files:**
- Modify: `deploy/frontend-patches/files/src/components/workspace/sanitizer-review.tsx`
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/types.ts`
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/en-US.ts`
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/zh-CN.ts`

**Interfaces:**
- Consumes: `useDocumentMeta` (Task 1), `readLastJobFromMetadata` (Task 2), `useThread()` for `threadId` -> `useThreadMetadata(threadId)` already wired in `chat-box.tsx`; the panel changes its own props to `{ className?: string; documentId: string | null; lastJob: LastJobSummary | null }` - chat-box (Task 4) passes it.
- Renders, top to bottom (per DESIGN.md Components):
  1. **Document header**: `text-sm font-medium` document name + `text-xs text-muted-foreground` line with format and version ("DOCX · v3"); a `Separator` under the header.
  2. **Egress state row**: label + `StateBadge` (existing mapping: sanitized→default, pending→secondary, blocked→destructive, never→secondary).
  3. **Job outcome block** (when `lastJob` present): one line per fact in plain operator language - verdict sentence, redaction count ("N identifier(s) redacted"), mapping sealed note, review flag if set. No raw JSON.
  4. **Blocked note** when blocked: `bg-destructive/10` + light foreground text per DESIGN.md, saying what happens next.
  5. **Helper footer**: the existing reviewNote, kept short.
- States preserved: loading, no-document (teaches the flow), not-sanitized, status, error (folded into notSanitized per plan-021 parked ruling - now rendered as its own `text-destructive` line, resolving that parked item).

- [ ] **Step 1: i18n additions** - `types.ts` sanitizer section gains: `docHeader` (fallback name), `docMetaLine` (format/version template), `verdictPass`, `verdictBlock`, `redactedLine` (count template), `mappingSealed` (one line explaining mapping stays in pacgate-api - replaces the review-note's doubled explanation), `humanReviewFlag`, `loadFailed`. English drafts:

```text
docHeader:   "Document"
docMetaLine: "{format} · v{version}"
verdictPass: "Verification passed. The sanitized text is cleared for cloud analysis."
verdictBlock: "Blocked. This document cannot leave the machine until a human decides."
redacted: "{count} identifier(s) redacted"
mappingSealed: "The placeholder mapping stays sealed in pacgate-api."
humanReviewFlag: "Human review required before any egress."
loadFailed: "Could not load the review status. Check that pacgate-api is reachable."
```

Chinese mirrors (glossed here, real strings in file):

```text
docHeader:   "文档"
docMetaLine: "{format} · 第{version}版"
verdictPass: "校验通过。脱敏文本可提交云端分析。"
verdictBlock: "已拦截。在人工处理前，该文档无法离开本机。"
redacted: "已脱敏 {count} 处标识符"
mappingSealed: "占位符映射保存在 pacgate-api 中，不会外泄。"
humanReviewFlag: "任何出站操作前需人工复核。"
loadFailed: "无法加载审查状态。请检查 pacgate-api 是否可达。"
```

- [ ] **Step 2: Component** - rewrite the render per the hierarchy above; keep `PACGATE_DOC_METADATA_KEY` export; use `map((s, i) => ...)` + `key={\`${s}-${i}\`}` for chunk badges (regression guard); remove the now-dead `reviewNote`/`blockedNote`/`latestJob` keys and replace consumers (also update the E2E expectation in Task 4).
- [ ] **Step 3: Typecheck** - `SKIP_ENV_VALIDATION=1 corepack pnpm exec tsc --noEmit` in the clone after applying overrides (exit 0).
- [ ] **Step 4: Commit** - `feat(frontend): document-identity sanitizer review panel per DESIGN.md`

---

## Task 4: chat-box wiring + E2E + zh verification

**Files:**
- Modify: `deploy/frontend-patches/files/src/components/workspace/chats/chat-box.tsx`
- Modify: `deploy/frontend-patches/files/tests/e2e/sanitizer-review.spec.ts`

**Interfaces:**
- chat-box already computes `threadMeta` via `useThreadMetadata`; it additionally parses `threadMeta?.metadata` with `readLastJobFromMetadata` and passes `lastJob` to the panel. The panel's own metadata-hook usage is removed (single fetch point).
- E2E updated: existing visibility assertion stays; add a second test that injects `pacgate_last_job` metadata into the mocked thread (`mockLangGraphAPI` supports `threads` with `metadata` - verify the MockThread shape at `tests/e2e/utils/mock-api.ts`) and asserts the redaction-count string renders.

- [ ] **Step 1: chat-box** - import `readLastJobFromMetadata`; derive `lastJob` alongside `pacgateDocumentId`; pass as prop.
- [ ] **Step 2: E2E** - update spec; keep the localized-title probe coverage by asserting `"Sanitization review"` (EN) and add `"脱敏审查"` (ZH, locale cookie) in the same spec file as a second test, replacing the ad-hoc probe removed during plan-021 verification.
- [ ] **Step 3: Run against the image** - rebuild (`deploy/build-frontend.ps1 -Tag 0.1.14-rc1`), run container on `127.0.0.1:8123` with `DEER_FLOW_AUTH_DISABLED=1` + `SKIP_ENV_VALIDATION=1`, temp config with `baseURL: process.env.PW_BASE_URL`, run spec. Both tests PASS.
- [ ] **Step 4: Commit** - `test(frontend): e2e for document-identity review panel (EN + ZH)`

---

## Task 5: SOUL + agent-side metadata write

**Files:**
- Modify: `deploy/sanitizer-agent/SOUL.md`

**Interfaces:**
- New operating rule (insert as rule 11, boundaries unchanged): after each `pacgate_sanitize_document` job, record the outcome into thread metadata key `pacgate_last_job` as a JSON string with exactly: `job_id`, `verdict` (`pass`|`block`), `redaction_count`, `mapping_count`, `data_level`, `require_human_review`, `reason`. Never include mapping contents, sanitized text, or residue values - the panel shows counts and verdicts only.
- The panel (Task 3) renders this record; the operator sees job outcome without needing the agent to narrate it twice.

- [ ] **Step 1: SOUL edit** - add the rule + a one-line example payload (keys only, no values).
- [ ] **Step 2: Commit** - `docs(sanitizer-agent): SOUL records job outcome to thread metadata`

---

## Task 6: Plan index + docs

**Files:**
- Modify: `plans/README.md` (row 022)
- Create: `plans/022-review-panel-redesign.md` (one-pager)

- [ ] **Step 1: Row** after 021: `| 022 | Review panel redesign (document identity + job outcome) | P2 | DONE (2026-09-19) |`
- [ ] **Step 2: One-pager** - What shipped (DESIGN.md at `deploy/frontend-patches/DESIGN.md`, document-meta client, job-meta parser, re-rendered panel, SOUL rule, EN+ZH E2E), boundaries held (read-only, no vault, no restore), release wiring (rebuild frontend image).
- [ ] **Step 3: Commit** - `docs(plans): record plan 022 review panel redesign`

---

## Self-review notes

- Spec coverage: the operator questions (which document / what was redacted / what's the verdict) map to the three data sources above; nothing in the design requires new spine capability.
- Vault audit: `LastJobSummary` fields are counts + verdict + reason; the reason string comes from `JobOutcome.reason` (server-generated, no residue values - verified `sanitize.rs:54-66`). No mapping column access exists on any panel path.
- Known simplification: chunk-state badges remain state-only (no per-span detections) - span data has no public endpoint (plan-021 note stands; pixel-redaction spans are v2).
- i18n templates use `{count}`/`{format}`/`{version}` placeholders - translations may reorder; keep the interpolation helper trivial (string replace), no ICU dependency.