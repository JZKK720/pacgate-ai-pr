import type { NextRequest } from "next/server";

// Pacgate fix (2026-10-07): the upstream file proxies to
// NEXT_PUBLIC_BACKEND_BASE_URL, which is the BROWSER-facing URL
// (http://localhost:8089 in compose.bundle.yaml). A server-side fetch to that
// URL from inside the frontend container hits nothing (nginx :8089 is
// published on the host, not on the container loopback) -> ECONNREFUSED ->
// HTTP 500 on every /api/memory call from the UI memory page.
//
// The server-side proxy must target the gateway on the compose network, the
// same way the [...path] catch-all effectively does via the next.config
// rewrite (DEER_FLOW_INTERNAL_GATEWAY_BASE_URL -> http://deer-flow:8001).
// Browser code is unaffected: getBackendBaseURL() still reads
// NEXT_PUBLIC_BACKEND_BASE_URL for client-side calls.
const BACKEND_BASE_URL =
  process.env.DEER_FLOW_INTERNAL_GATEWAY_BASE_URL ??
  process.env.NEXT_PUBLIC_BACKEND_BASE_URL ??
  "http://127.0.0.1:8001";

function buildBackendUrl(pathname: string) {
  return new URL(pathname, BACKEND_BASE_URL);
}

async function proxyRequest(request: NextRequest, pathname: string) {
  const headers = new Headers(request.headers);
  headers.delete("host");
  headers.delete("connection");
  headers.delete("content-length");

  const hasBody = !["GET", "HEAD"].includes(request.method);
  const response = await fetch(buildBackendUrl(pathname), {
    method: request.method,
    headers,
    body: hasBody ? await request.arrayBuffer() : undefined,
  });

  return new Response(await response.arrayBuffer(), {
    status: response.status,
    headers: response.headers,
  });
}

export async function GET(request: NextRequest) {
  return proxyRequest(request, "/api/memory");
}

export async function DELETE(request: NextRequest) {
  return proxyRequest(request, "/api/memory");
}
