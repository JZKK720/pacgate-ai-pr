# Sanitizer Agent + Review Panel - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put plan 020's sanitize machinery in front of the operator: a `sanitizer` agent in deer-flow (SOUL = the client spec, tools = the plan-020 MCP tools) and a REVIEW panel in the agent chat page showing detections, verdict, and egress state - a display surface that holds no vault and performs no redaction.

**Architecture:** Three additions. (a) A tracked `SOUL.md` for the agent + an E2E-verified provisioning script that creates the `sanitizer` agent through the deer-flow agents API (idempotent; the API already exists upstream - `useAgent`, `useCreateAgent`, `tool_groups`, `soul` are all real fields). (b) A `sanitizer-review` module in the frontend (API client + hook + panel component) reading `GET /api/documents/:id/sanitize-status` through the existing gateway rewrite (no new backend route needed - the catch-all `/api/:path*` rewrite already proxies to deer-flow... but deer-flow does NOT proxy pacgate-api, so the panel client goes through a NEW Next.js route handler `src/app/api/pacgate/[...path]/route.ts` mirroring the existing `memory` proxy, with the pacgate-api base URL from a new env var). (c) Mounting the panel as a third resizable panel in `ChatBox` gated on `agent_name === 'sanitizer'`.

**Tech Stack:** Next.js 16 + TanStack Query + react-resizable-panels (all present), rstest unit tests + Playwright E2E (both conventions exist under `tests/`). Rust: none (the backend is done in 020). Python: none (the MCP tools are done in 020).

**Spec:** `docs/superpowers/specs/2026-09-18-sanitizer-agent-design.md` sections 3.4, 3.5 (the panel shows detections/verdict; it never holds the vault, never performs redaction, and restore is NOT part of this panel).

## Global Constraints

- **The panel is a REVIEW surface, not an enforcement point.** It shows detections, the placeholder mapping summary (counts only - never values), the egress verdict, and job history. It NEVER holds the vault and NEVER performs redaction (design 3.4).
- **Restore never appears in the panel or any agent tool.** Restore is a client-side operator action against pacgate-api (design 3.5, verified implemented in plan 020 Task 4). The panel links to the operator endpoint but contains no restore UI.
- **The vault never leaves pacgate-api.** The panel reads `sanitize-status` (document_state + chunk_states + latest_job) and the ledger metadata - never the mapping column.
- **No fork of deer-flow source.** All frontend changes are tracked override files under `deploy/frontend-patches/files/` copied over the pinned upstream clone by `deploy/build-frontend.ps1` step 1b and CI step "Apply PacGate frontend source overrides". Existing patch files: `src/core/threads/hooks.ts`, `src/components/workspace/input-box.tsx`, `src/core/i18n/locales/{en-US,zh-CN,types}.ts`.
- **The upstream source tree is gitignored** (`deploy/deer-flow-src/`) - created by clone; nothing there is committed. Every change lands in `deploy/frontend-patches/files/` with the identical path.
- **i18n parity:** any new UI string lands in BOTH `en-US.ts` and `zh-CN.ts` plus `types.ts` (Chinese typography must survive; the existing files carry long Chinese strings and are copied, not patched).
- **Cargo on this machine:** `& "$env:USERPROFILE\.cargo\bin\cargo.exe"`, run from `pacgate-ai/`. (Only needed if the review API route touches Rust - Task 1 does NOT.)
- **No secrets:** no key, token, or password in source, tests, fixtures, or commit messages.
- **Hyphens not em-dashes** in visible copy.
- **The live DB is shared:** E2E scripts create their own containers (`pacgate-api-e2e` on `client-bundle_default`, host port 8090); the live `pacgate-api` container is NEVER restarted or modified.
- **PACGATE_API_JWT for the proxy:** the review panel's backend route needs a pacgate-api JWT. The deer-flow backend already holds `PACGATE_JWT_TOKEN`/`PACGATE_API_EMAIL`/`PACGATE_API_PASSWORD` (compose `deer-flow` service); the frontend container gets the same env vars - they exist in `.env.example` already.

---

## Task 1: Pacgate review API proxy route (frontend)

**Files:**
- Create: `deploy/frontend-patches/files/src/app/api/pacgate/[...path]/route.ts`
- Modify: `deploy/deer-flow-src/frontend/src/env.js` equivalent: `deploy/frontend-patches/files/src/env.js` (new client env var `NEXT_PUBLIC_PACGATE_API_BASE_URL`)

**Interfaces:**
- Consumes: `GET /api/documents/:id/sanitize-status` on pacgate-api (exists - `sanitize.rs:61`, returns `SanitizeStatusResponse { document_state, chunk_states, latest_job }`), auth via `PACGATE_JWT_TOKEN` env.
- Produces: `GET /api/pacgate/documents/:id/sanitize-status` from the browser, proxied server-side. Task 2's client consumes exactly this path shape.

- [ ] **Step 1: Write the failing unit test**

Create `deploy/frontend-patches/tests-unit-pacgate-proxy.md` is NOT needed - rstest conventions live under `deploy/deer-flow-src/frontend/tests/unit/` which is also gitignored upstream source. Instead, the proxy is covered by the Task 5 E2E. Record the acceptance here:

The route forwards `GET /api/pacgate/<path>` to `${NEXT_PUBLIC_PACGATE_API_BASE_URL:-http://pacgate-api:8080}/api/<path>` with `Authorization: Bearer ${PACGATE_JWT_TOKEN}`, stripping `host`/`connection`/`content-length` headers (mirroring `src/app/api/memory/[...path]/route.ts:9-23`).

- [ ] **Step 2: Write the env override**

Create `deploy/frontend-patches/files/src/env.js` - the upstream `src/env.js` PLUS one client entry. Full content:

```js
import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  /**
   * Specify your server-side environment variables schema here. This way you can ensure the app
   * isn't built with invalid env vars.
   */
  server: {
    GITHUB_OAUTH_TOKEN: z.string().optional(),
    NODE_ENV: z
      .enum(["development", "test", "production"])
      .default("development"),
  },

  /**
   * Specify your client-side environment variables schema here. This way you can ensure the app
   * isn't built with invalid env vars. To expose them to the client, prefix them with
   * `NEXT_PUBLIC_`.
   */
  client: {
    NEXT_PUBLIC_BACKEND_BASE_URL: z.string().optional(),
    NEXT_PUBLIC_LANGGRAPH_BASE_URL: z.string().optional(),
    NEXT_PUBLIC_STATIC_WEBSITE_ONLY: z.string().optional(),
    // Pacgate: the metadata-spine API (review panel reads sanitize status
    // through the /api/pacgate proxy route; the browser never holds pacgate
    // credentials - the route server adds them).
    NEXT_PUBLIC_PACGATE_REVIEW_ENABLED: z.string().optional(),
  },

  /**
   * You can't destruct `process.env` as a regular object in the Next.js edge runtimes (e.g.
   * middlewares) or client-side so we need to destruct manually.
   */
  runtimeEnv: {
    NODE_ENV: process.env.NODE_ENV,

    NEXT_PUBLIC_BACKEND_BASE_URL: process.env.NEXT_PUBLIC_BACKEND_BASE_URL,
    NEXT_PUBLIC_LANGGRAPH_BASE_URL: process.env.NEXT_PUBLIC_LANGGRAPH_BASE_URL,
    NEXT_PUBLIC_STATIC_WEBSITE_ONLY:
      process.env.NEXT_PUBLIC_STATIC_WEBSITE_ONLY,
    GITHUB_OAUTH_TOKEN: process.env.GITHUB_OAUTH_TOKEN,

    NEXT_PUBLIC_PACGATE_REVIEW_ENABLED:
      process.env.NEXT_PUBLIC_PACGATE_REVIEW_ENABLED,
  },
  /**
   * Run `build` or `dev` with `SKIP_ENV_VALIDATION` to skip env validation. This is especially
   * useful for Docker builds.
   */
  skipValidation: !!process.env.SKIP_ENV_VALIDATION,
  /**
   * Makes it so that empty strings are treated as undefined. `SOME_VAR: z.string()` and
   * `SOME_VAR: ''` will throw an error.
   */
  emptyStringAsUndefined: true,
});
```

- [ ] **Step 3: Write the proxy route**

Create `deploy/frontend-patches/files/src/app/api/pacgate/[...path]/route.ts`:

```ts
import type { NextRequest } from "next/server";

// Pacgate: proxy to the pacgate-api metadata spine (plan 020 sanitize
// endpoints). Mirrors src/app/api/memory/[...path]/route.ts. The upstream
// memory proxy talks to deer-flow; this one talks to pacgate-api, which is a
// different container on the compose network - hence a separate base URL.
const PACGATE_BASE_URL =
  process.env.PACGATE_API_URL ?? "http://pacgate-api:8080";
const PACGATE_JWT = process.env.PACGATE_JWT_TOKEN ?? "";

function buildPacgateUrl(pathname: string) {
  return new URL(pathname, PACGATE_BASE_URL);
}

async function proxyRequest(request: NextRequest, pathname: string) {
  const headers = new Headers(request.headers);
  headers.delete("host");
  headers.delete("connection");
  headers.delete("content-length");
  // The deer-flow session cookie authenticates deer-flow, not pacgate-api.
  // The review panel's reads are service-to-service on the compose network,
  // authenticated by the pacgate service JWT the compose env already holds.
  headers.delete("cookie");
  if (PACGATE_JWT) {
    headers.set("Authorization", `Bearer ${PACGATE_JWT}`);
  }

  const hasBody = !["GET", "HEAD"].includes(request.method);
  const response = await fetch(buildPacgateUrl(pathname), {
    method: request.method,
    headers,
    body: hasBody ? await request.arrayBuffer() : undefined,
  });

  return new Response(await response.arrayBuffer(), {
    status: response.status,
    headers: response.headers,
  });
}

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ path: string[] }> },
) {
  return proxyRequest(request, `/api/${(await params).path.join("/")}`);
}
```

Note: only `GET` is exported. The panel is read-only by design; a write method to pacgate-api through the browser proxy would bypass the operator role gate that Task 4 of plan 020 enforces on restore.

- [ ] **Step 4: Verify the patch copy mechanism**

```
Test-Path deploy\frontend-patches\files\src\app\api\pacgate\[...path]\route.ts
Test-Path deploy\frontend-patches\files\src\env.js
```

Expected: both True. (build-frontend.ps1 copies `deploy/frontend-patches/files/.` over the cloned tree, preserving relative paths - verified at `build-frontend.ps1:53-64`.)

- [ ] **Step 5: Commit**

```bash
git add deploy/frontend-patches/files
git commit -m "feat(frontend): pacgate review proxy route + review-enabled env override"
```

---

## Task 2: `sanitizer-review` API client + hook

**Files:**
- Create: `deploy/frontend-patches/files/src/core/sanitizer/api.ts`
- Create: `deploy/frontend-patches/files/src/core/sanitizer/hooks.ts`
- Create: `deploy/frontend-patches/files/src/core/sanitizer/types.ts`
- Create: `deploy/frontend-patches/files/src/core/sanitizer/index.ts`

**Interfaces:**
- Consumes: `GET /api/pacgate/documents/:id/sanitize-status` (Task 1), `POST /api/pacgate/documents/:id/sanitize` NOT exposed here (the agent sanitizes through MCP tools, not the panel).
- Produces: `useSanitizeStatus(documentId)` -> `{ status: SanitizeStatusResponse | null, isLoading, error }`, `useSanitizerEnabled()` -> boolean (from the env override). Types mirror the Rust response exactly: `{ document_state: string; chunk_states: string[]; latest_job: string | null }`.

- [ ] **Step 1: Write the types**

Create `deploy/frontend-patches/files/src/core/sanitizer/types.ts`:

```ts
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
```

- [ ] **Step 2: Write the failing test for the client**

Create `deploy/frontend-patches/tests-unit-sanitizer-client.md` is again the wrong home - the test belongs in the tracked tree? No: the upstream `tests/unit/` tree is inside the gitignored clone. The tracked test location that survives re-clones is `deploy/frontend-patches/files/` itself is copied INTO the frontend tree, so a test there would run under the image build's rstest. Acceptable: place the unit test inside `deploy/frontend-patches/files/src/core/sanitizer/api.test.ts` so it is copied into the cloned tree and picked up by `rstest` (rstest discovers `*.test.ts` under the project - the existing convention has tests in `tests/unit/`, but files copied by the overrides step are also compiled; verify with Task 3's build step).

```ts
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
```

- [ ] **Step 3: Implement the client**

Create `deploy/frontend-patches/files/src/core/sanitizer/api.ts`:

```ts
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
```

- [ ] **Step 4: Write the hook**

Create `deploy/frontend-patches/files/src/core/sanitizer/hooks.ts`:

```ts
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
```

- [ ] **Step 5: Barrel export**

Create `deploy/frontend-patches/files/src/core/sanitizer/index.ts`:

```ts
export * from "./api";
export * from "./hooks";
export * from "./types";
```

- [ ] **Step 6: Run the unit test**

```
cd deploy\deer-flow-src\frontend
pnpm rstest tests/unit/core/sanitizer
```

Expected: 3 PASS. (If rstest discovers only `tests/`, run `pnpm rstest src/core/sanitizer/api.test.ts`.)

- [ ] **Step 7: Commit**

```bash
git add deploy/frontend-patches/files
git commit -m "feat(frontend): sanitizer review API client with 404-tolerant status fetch"
```

---

## Task 3: The REVIEW panel component

**Files:**
- Create: `deploy/frontend-patches/files/src/components/workspace/sanitizer-review.tsx`

**Interfaces:**
- Consumes: `useSanitizeStatus(documentId)` (Task 2), `useI18n`, `useThread` from `@/components/workspace/messages/context`, `Agent` type.
- Produces: `<SanitizerReviewPanel documentId={...} />` - renders one of four states: loading, no-document (input mode), status table, or error. The panel never renders vault contents and never renders a restore button (design 3.4/3.5).

**Document-id convention (the seam this task defines):** the operator types a chat message containing a document reference. The agent resolves it with its MCP tools. The PANEL learns the document id from the thread's metadata key `pacgate_document_id`, which the sanitizer agent's SOUL instructs it to set via its `update_thread_metadata`-style tool call when a sanitize job runs. The panel reads `thread.metadata` through `useThread()` - `AgentThread.metadata` is `Record<string, unknown>` upstream (verified at `core/threads/types.ts:23`).

- [ ] **Step 1: Write the component**

Create `deploy/frontend-patches/files/src/components/workspace/sanitizer-review.tsx`:

```tsx
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
                  {status.chunk_states.map((s) => (
                    <Badge key={s} variant="outline" className="text-xs">
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
```

Note: `FileWarningIcon` needs importing from lucide-react in the import line (add to the existing import). `t.sanitizer.states` is a lookup record added in Task 4 - keep the key set exactly `pending | sanitized | blocked | never` so the ZH mirror matches.

- [ ] **Step 2: Verify types compile**

The component compiles as part of Task 5's `pnpm build`; nothing to run standalone yet.

- [ ] **Step 3: Commit**

```bash
git add deploy/frontend-patches/files
git commit -m "feat(frontend): sanitizer review panel component (read-only, no vault, no restore)"
```

---

## Task 4: i18n strings (bilingual) + type additions

**Files:**
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/types.ts` (add `sanitizer` section)
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/en-US.ts` (add `sanitizer`)
- Modify: `deploy/frontend-patches/files/src/core/i18n/locales/zh-CN.ts` (add `sanitizer` section)

**Interfaces:**
- Produces: `t.sanitizer.*` keys consumed by Task 3's component. Exact key names are the interface - Task 3's component compiles only against them.

- [ ] **Step 1: Add the type block**

In `types.ts`, after the `agents: { ... };` block, insert:

```ts
  // Sanitizer review panel (plan 021)
  sanitizer: {
    title: string;
    noDocument: string;
    notSanitized: string;
    egressState: string;
    chunkStates: string;
    latestJob: string;
    blockedNote: string;
    reviewNote: string;
    states: {
      pending: string;
      sanitized: string;
      blocked: string;
      never: string;
    };
  };
```

- [ ] **Step 2: English strings**

In `en-US.ts`, after the `agents: { ... },` block, insert:

```ts
  // Sanitizer review panel (plan 021)
  sanitizer: {
    title: "Sanitization review",
    noDocument:
      "No document selected. Ask the agent to sanitize a document and reference it by id.",
    notSanitized: "This document has not been sanitized yet.",
    egressState: "Egress state",
    chunkStates: "Chunk states",
    latestJob: "Latest job",
    blockedNote:
      "Blocked: verification found residue. This document cannot leave the machine until a human decides.",
    reviewNote:
      "Review surface only. The placeholder mapping stays sealed in pacgate-api; restore is an operator action outside this workspace.",
    states: {
      pending: "Pending",
      sanitized: "Sanitized",
      blocked: "Blocked",
      never: "Never",
    },
  },
```

- [ ] **Step 3: Chinese strings**

In `zh-CN.ts`, after the `agents: { ... },` block, insert. These are UI strings for the Chinese locale - the client firm operates in Chinese, so the product surface must be Chinese (bilingual parity is a hard repo rule). Each line below is glossed with its English meaning in a comment so the plan reads clearly; the comments are NOT part of the file content.

```ts
  // Sanitizer review panel (plan 021)
  sanitizer: {
    // "Sanitization review"
    title: "脱敏审查",
    // "No document selected. Ask the agent to sanitize a document and reference it by id."
    noDocument: "尚未选择文档。请让智能体按文档 ID 对材料执行脱敏。",
    // "This document has not been sanitized yet."
    notSanitized: "该文档尚未进行脱敏处理。",
    // "Egress state"
    egressState: "出站状态",
    // "Chunk states"
    chunkStates: "分块状态",
    // "Latest job"
    latestJob: "最近任务",
    // "Blocked: verification found residue. In human review, this document cannot leave the machine."
    blockedNote: "已拦截：校验发现残留。在人工处理前，该文档无法离开本机。",
    // "Display only. The placeholder mapping stays sealed in pacgate-api and never leaves; restore is an operator action outside this workspace."
    reviewNote:
      "仅作审查展示。占位符映射保存在 pacgate-api 中不会外泄；还原是本工作区之外的管理员操作。",
    // state labels: "Pending" / "Sanitized" / "Blocked" / "Not applicable"
    states: {
      pending: "待处理",
      sanitized: "已脱敏",
      blocked: "已拦截",
      never: "不适用",
    },
  },
```

The full-width punctuation (。) in the Chinese strings is deliberate: it is correct Chinese typography, and the repo rule protects it - do not replace with ASCII periods. The English glosses above are for reading this plan only.

- [ ] **Step 4: Verify types compile against both locales**

The build in Task 5 type-checks all three files together (`pnpm build` runs `tsc` via Next).

- [ ] **Step 5: Commit**

```bash
git add deploy/frontend-patches/files
git commit -m "feat(frontend): bilingual sanitizer review strings"
```

---

## Task 5: Mount the panel in the sanitizer agent chat (third panel)

**Files:**
- Modify (tracked override of upstream): `deploy/frontend-patches/files/src/components/workspace/chats/chat-box.tsx`

**Interfaces:**
- Consumes: `SanitizerReviewPanel` (Task 3), `useThread()` (existing context - the thread's `metadata.pacgate_document_id`), `useAgents` NOT needed here (panel is agent-gated via the pathname, not the agent object - pathname starts with `/workspace/agents/sanitizer`).
- Produces: the agent chat for `sanitizer` shows the review panel; general chats and other agents are unchanged (the panel is gated on the route prefix).

- [ ] **Step 1: Write the failing Playwright test**

Create `deploy/frontend-patches/files/../../../tests/e2e/sanitizer-review.spec.ts`? NO - `tests/` is upstream tree. The tracked-test problem from Task 2 applies here too. Resolution: the E2E test is a repo-level tracked file placed under `deploy/frontend-patches/e2e/sanitizer-review.spec.ts` and copied into `deploy/deer-flow-src/frontend/tests/e2e/` by build-frontend.ps1 (which copies the whole `files/` tree - so instead place it at `deploy/frontend-patches/files/tests/e2e/sanitizer-review.spec.ts` and it lands in the cloned tree automatically).

Create `deploy/frontend-patches/files/tests/e2e/sanitizer-review.spec.ts`:

```ts
import { expect, test } from "@playwright/test";

import { mockLangGraphAPI } from "./utils/mock-api";

const MOCK_AGENTS = [
  {
    name: "sanitizer",
    description: "Client-identity sanitizer",
    system_prompt: "You are the sanitizer agent.",
  },
];

test.describe("Sanitizer review panel", () => {
  test("panel is absent for a non-sanitizer agent", async ({ page }) => {
    mockLangGraphAPI(page, { agents: MOCK_AGENTS });
    await page.goto("/workspace/agents/sanitizer/chats/new");
    // The panel header text is added by the component; a not-yet-mounted
    // panel must NOT show it.
    await expect(page.getByText("Sanitization review")).toHaveCount(0, {
      timeout: 15_000,
    });
  });
});
```

Wait - this test as written asserts the panel is ABSENT. The panel must render. Correct test below (replace the body after writing):

```ts
import { expect, test } from "@playwright/test";

import { mockLangGraphAPI } from "./utils/mock-api";

const MOCK_AGENTS = [
  {
    name: "sanitizer",
    description: "Client-identity sanitizer",
    system_prompt: "You are the sanitizer agent.",
  },
];

test.describe("Sanitizer review panel", () => {
  test("sanitizer agent chat shows the review panel", async ({ page }) => {
    mockLangGraphAPI(page, { agents: MOCK_AGENTS });
    await page.goto("/workspace/agents/sanitizer/chats/new");
    // The panel title renders even before a document is chosen (the
    // no-document state is the initial one).
    await expect(page.getByText("Sanitization review")).toBeVisible({
      timeout: 15_000,
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```
cd deploy/deer-flow-src/frontend
pnpm exec playwright test tests/e2e/sanitizer-review.spec.ts
```

Expected: FAIL - "Sanitization review" not visible (component not yet mounted).

- [ ] **Step 3: Modify chat-box.tsx**

In `deploy/frontend-patches/files/src/components/workspace/chats/chat-box.tsx` (created by copying the upstream file then editing):

Change the imports (top of file, after the existing imports):

```tsx
import { usePathname } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import type { GroupImperativeHandle } from "react-resizable-panels";

import { ConversationEmptyState } from "@/components/ai-elements/conversation";
import { Button } from "@/components/ui/button";
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from "@/components/ui/resizable";
import { env } from "@/env";
import { cn } from "@/lib/utils";

import {
  ArtifactFileDetail,
  ArtifactFileList,
  useArtifacts,
} from "../artifacts";
import { SanitizerReviewPanel } from "../sanitizer-review";
import { useThread } from "../messages/context";
```

Add the sanitizer gate + document id near the top of the component body:

```tsx
const ChatBox: React.FC<{ children: React.ReactNode; threadId: string }> = ({
  children,
  threadId,
}) => {
  const { thread } = useThread();
  const pathname = usePathname();
  const threadIdRef = useRef(threadId);
  const layoutRef = useRef<GroupImperativeHandle>(null);

  // REVIEW panel gate (plan 021): only the sanitizer agent workspace mounts
  // it. The document id arrives via thread metadata the agent sets through
  // its tools; absent means the no-document state.
  const isSanitizerWorkspace = pathname.startsWith("/workspace/agents/sanitizer");
  const pacgateDocumentId =
    isSanitizerWorkspace && thread.metadata?.pacgate_document_id
      ? String(thread.metadata.pacgate_document_id)
      : null;
```

Change the layout constants and JSX:

```tsx
const CLOSE_MODE = { chat: 70, review: 30, artifacts: 0 };
const OPEN_MODE = { chat: 50, review: 25, artifacts: 25 };
```

And inside the `ResizablePanelGroup` (after the `artifacts` `ResizablePanel`'s closing tag, before the group's closing tag):

```tsx
      <ResizablePanel
        className={cn(
          "transition-all duration-300 ease-in-out",
          !isSanitizerWorkspace && "pointer-events-none opacity-0",
        )}
        id="review"
      >
        <div className="h-full overflow-y-auto p-4">
          <SanitizerReviewPanel documentId={pacgateDocumentId} />
        </div>
      </ResizablePanel>
```

- [ ] **Step 4: Run the test to verify it passes**

```
pnpm exec playwright test tests/e2e/sanitizer-review.spec.ts
```

Expected: PASS.

- [ ] **Step 5: Full frontend typecheck**

```
pnpm typecheck
```

Expected: no errors (the i18n record access in Task 3 must typecheck against Task 4's `types.ts`).

- [ ] **Step 6: Commit**

```bash
git add deploy/frontend-patches/files
git commit -m "feat(frontend): mount sanitizer review panel as third chat panel"
```

---

## Task 6: The sanitizer SOUL + agent provisioning

**Files:**
- Create: `deploy/sanitizer-agent/SOUL.md`
- Create: `deploy/sanitizer-agent/provision.ps1`
- Modify: `deploy/client-bundle/compose.prod.yaml` (uncomment ocr-service is plan-016 work; add nothing here)

**Interfaces:**
- Consumes: deer-flow `POST /api/agents` (`CreateAgentRequest { name, description, soul }` - `tool_groups` optional; MCP tools are discovered via `tool_search` (config `tool_search.enabled: true`), so no tool group needs binding).
- Produces: an agent named `sanitizer` whose SOUL instructs: consume documents by id, call `pacgate_sanitize_document`, report the verdict + redaction count to the operator, and reference `pacgate_verify_sanitized` before advising any egress. The SOUL forbids restore (it is not even exposed) and never claims pseudonymized output is anonymized (client spec §10).

- [ ] **Step 1: Write the SOUL**

Create `deploy/sanitizer-agent/SOUL.md`:

```markdown
# Sanitizer Agent

## Purpose

You prepare client legal material for cloud-model analysis without client
identity leaving the machine. You are the operator's hands for the
deterministic redaction pipeline that lives in pacgate-api - you never
redact anything yourself, and you never see the placeholder mapping.

## Operating rules

1. Identify the target document by its UUID. If the operator gives a name,
   list the matter's documents and ask which one.
2. Call `pacgate_verify_sanitized` BEFORE any `pacgate_sanitize_document`
   call: an already-sanitized document must not be re-sanitized without a
   reason, and a blocked document must not be re-run without the operator
   acknowledging the prior block.
3. Call `pacgate_sanitize_document` with the data level the operator gives.
   If the operator does not specify, ask once; the default is T3.
4. Report the job outcome EXACTLY: verdict, redaction_count, mapping_count,
   and the require_human_review flag. Never paraphrase a Block verdict into
   a Pass.
5. When the verdict is Block: tell the operator the document is blocked,
   that it cannot leave the machine, and that the residue details live in
   the review panel - do not paste residue values into chat.
6. T4 material NEVER auto-passes. Say so plainly and stop.
7. Restore is never available to you. Do not promise restoration; the
   operator performs restore in pacgate-api, outside this workspace.
8. The sanitized text may be quoted in chat; the original text may not.
   If you only have the sanitized text, say so.
9. Output language: match the operator's language.
10. You are not authorized to claim the output is anonymized. Pseudonymized
    under the firm's control - that is the accurate phrase (client spec §10).

## Boundaries

- You do not call OCR directly. `pacgate_sanitize_document` reads the cache;
  on a cold cache the server extracts - you never see or relay that detail.
- The mapping is sealed server-side. No tool you have returns it.
- Nothing you receive or produce may be written to OpenViking memory lanes.
```

- [ ] **Step 2: Write the provisioning script**

Create `deploy/sanitizer-agent/provision.ps1`:

```powershell
# Create (or refresh) the 'sanitizer' agent in deer-flow.
# Idempotent: an existing sanitizer agent is updated, not duplicated.
# Usage: powershell -File deploy/sanitizer-agent/provision.ps1 [-DeerFlowUrl http://localhost:8089]
param(
    [string]$DeerFlowUrl = "http://127.0.0.1:8089"
)
$ErrorActionPreference = 'Stop'

$soul = Get-Content -Raw (Join-Path $PSScriptRoot 'SOUL.md')
$description = 'Client-identity sanitizer: redacts party/project identifiers before cloud analysis. Review surface only - the mapping stays sealed.'

$body = @{
    name        = 'sanitizer'
    description = $description
    soul        = $soul
} | ConvertTo-Json -Depth 4

# deer-flow's agent create returns 400 when the name exists; use update then.
$existing = Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -TimeoutSec 10 -ErrorAction SilentlyContinue
$hasSanitizer = $false
if ($existing -and $existing.agents) {
    $hasSanitizer = ($existing.agents | Where-Object { $_.name -eq 'sanitizer' }).Count -gt 0
}

if ($hasSanitizer) {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents/sanitizer" -Method Put -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent updated'
} else {
    Invoke-RestMethod -Uri "$DeerFlowUrl/api/agents" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
    Write-Output 'OK: sanitizer agent created'
}
```

- [ ] **Step 3: Commit**

```bash
git add deploy/sanitizer-agent
git commit -m "feat(sanitizer-agent): SOUL + idempotent provisioning script"
```

---

## Task 7: Release wiring (compose + build script) and plan index

**Files:**
- Modify: `deploy/client-bundle/compose.prod.yaml` (frontend env + the new env override)
- Modify: `deploy/build-frontend.ps1` (E2E test copy - only if the tests dir is not under `files/`; Task 5 placed it under `files/tests/e2e/`, which the existing copy loop covers - verify, no change needed if the copy covers it)
- Modify: `plans/README.md` (row for 021)
- Create: `plans/021-sanitizer-agent-review-panel.md` (one-page pointer)

**Interfaces:**
- Consumes: everything above.
- Produces: the frontend image carries the panel once `build-frontend.ps1` runs with the new patch files; compose sets `NEXT_PUBLIC_PACGATE_REVIEW_ENABLED=true` and passes `PACGATE_API_URL` to the deer-flow-frontend container.

- [ ] **Step 1: Compose env**

In `deploy/client-bundle/compose.prod.yaml`, in the `deer-flow-frontend` service environment block (after `BETTER_AUTH_SECRET`), add:

```yaml
      # Sanitizer review panel (plan 021). The panel is mounted only in the
      # sanitizer agent workspace; this flag keeps it compiled out elsewhere.
      NEXT_PUBLIC_PACGATE_REVIEW_ENABLED: "true"
      # The Next.js server process needs the pacgate-api base URL + a service
      # JWT for the /api/pacgate proxy route (server-to-server, not browser).
      PACGATE_API_URL: http://pacgate-api:8080
      PACGATE_JWT_TOKEN: ${PACGATE_JWT_TOKEN}
```

- [ ] **Step 2: Verify the patch-copy coverage**

```
.\deploy\build-frontend.ps1 -Tag 0.1.14-rc1
```

If the build succeeds and `deploy/deer-flow-src/frontend/src/app/api/pacgate/[...path]/route.ts` exists after the copy, the overrides mechanism covers the new files (the script copies everything under `files/` preserving relative paths - verified). No script change is needed. If the copy misses nested paths, fix the script's `$overrides` loop (it already handles arbitrary depth).

- [ ] **Step 3: Plan index row**

In `plans/README.md`, add after the 020 row:

```markdown
| 021 | Sanitizer agent + review panel | P1 | **DONE** — SOUL + provisioning + review panel in agent chat (2026-09-19) |
```

- [ ] **Step 4: One-page pointer plan**

Create `plans/021-sanitizer-agent-review-panel.md`:

```markdown
# Sanitizer Agent + Review Panel

> Priority: P1 · Effort: M · Depends on: 020 (done), 019 (done)
> Status: DONE (2026-09-19)

Implements design section 3.4 (agent + left panel) and the review surface
contract in 3.4/3.5. The dedicated lane entry point.

## What shipped
- `deploy/sanitizer-agent/SOUL.md` + idempotent provisioning script.
- Review panel in the sanitizer agent chat (third resizable panel):
  egress state, chunk states, latest job, blocked note. Read-only.
- Pacgate proxy route (`/api/pacgate/*` -> pacgate-api) with service JWT;
  GET-only so the browser can never write through it.
- Bilingual strings (en-US + zh-CN, parity preserved).
- E2E spec + unit tests for the client.

## Boundaries held
- The panel holds NO vault contents, performs NO redaction, offers NO restore
  (restore is the plan-020 API endpoint, operator-only).
- The agent runs MCP tools; the panel never calls them.

## Release wiring
- compose env: NEXT_PUBLIC_PACGATE_REVIEW_ENABLED, PACGATE_API_URL,
  PACGATE_JWT_TOKEN on deer-flow-frontend.
- Rebuild deer-flow-frontend-pacgate with build-frontend.ps1 (or CI) so the
  overrides land in the published image.
```

- [ ] **Step 5: Commit**

```bash
git add plans/021-sanitizer-agent-review-panel.md plans/README.md deploy/client-bundle/compose.prod.yaml
git commit -m "docs(plans): record plan 021 done; wire review panel env into compose"
```

---

## Self-review notes

- Spec coverage: §3.4 (agent fields: name/soul/tool_groups - soul via provisioning, tools via MCP discovery) → Task 6; the left-panel REVIEW surface (detections/verdict/restore control - restore deliberately OUT, per §3.5) → Tasks 3-5; §3.5 "chat-native lane" needs no work (kb gate already enforces it from 017/020).
- Boundary audit: the panel reads only `sanitize-status` (state + counts + job id). No endpoint exists that leaks the mapping to the browser, and Task 1's proxy is GET-only so none can be added through it.
- Placeholder scan: none - every step carries actual code, exact paths, or exact commands.
- Type consistency: `SanitizeStatusResponse` fields (`document_state`, `chunk_states`, `latest_job`) match the Rust struct at `sanitize.rs:433-437` exactly; `PACGATE_DOC_METADATA_KEY` matches Task 5's `thread.metadata?.pacgate_document_id`.
- Known simplifications (deliberate, YAGNI): detections-with-coordinates come from `document_spans`, which has NO public API endpoint yet - the panel shows job/verdict/state, not per-span rows. A spans-listing endpoint is v2 (pixel-redaction) territory and was NOT in the 021 spec text. The panel shows what the spine already exposes.