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