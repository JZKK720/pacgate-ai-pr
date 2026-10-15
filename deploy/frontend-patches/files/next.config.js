/**
 * Run `build` or `dev` with `SKIP_ENV_VALIDATION` to skip env validation. This is especially useful
 * for Docker builds.
 */
import "./src/env.js";

function getInternalServiceURL(envKey, fallbackURL) {
  const configured = process.env[envKey]?.trim();
  return configured && configured.length > 0
    ? configured.replace(/\/+$/, "")
    : fallbackURL;
}
import nextra from "nextra";

const withNextra = nextra({});

/** @type {import("next").NextConfig} */
const config = {
  output:
    process.env.NEXT_CONFIG_BUILD_OUTPUT === "standalone"
      ? "standalone"
      : undefined,
  i18n: {
    locales: ["en", "zh"],
    defaultLocale: "en",
  },
  devIndicators: false,

  // ── Pacgate patch: stop Next.js killing long agent runs ────────────────────
  //
  // THE DEFECT (measured on the dev box, 2026-10-13, deer-flow-frontend 0.1.27):
  // Next.js proxies the `rewrites()` destinations below, and its
  // `experimental.proxyTimeout` DEFAULTS TO 30000 ms. Every gateway call that
  // runs longer than 30 s therefore had its socket torn down mid-flight, and the
  // browser/server-to-server caller got an error WHILE THE RUN KEPT EXECUTING
  // server-side. The frontend logged the exact shape:
  //
  //     Failed to proxy http://deer-flow:8001/api/threads/<id>/runs/wait
  //     Error: socket hang up  { code: 'ECONNRESET' }
  //
  // Isolated by comparing the same request on three paths:
  //     nginx :8089  -> HTTP 500 at 30.1 s   (FAILED)
  //     frontend :8090 -> HTTP 200 at 23.8 s  REPLY=PONG   (under the cap)
  //     gateway :8001  -> HTTP 200 at 27.0 s               (no proxy involved)
  //
  // WHY THIS MATTERS. The deer-flow run record for the failed request read
  // `status=success` with the model's answer stored, and the LLM call to Ollama
  // returned 200: the generation was never broken. Only the DELIVERY was. Any
  // real legal-research or document task (minutes, not seconds) hit this on the
  // client's primary path, which is why it presented as "the model cannot
  // generate" and "pacgate-api / deer-flow frontend lost connection".
  //
  // WHY 3600000 AND NOT SOMETHING TIGHTER. Next.js is the INNER proxy, and the
  // observed worst case on this box is a real run at 2495 s (41 min), so a
  // 300 s-class value is simply too short:
  //   browser -> nginx (/ and /research/) -> Next.js -> gateway
  // Every layer caps the request INDEPENDENTLY, and the first one to give up
  // wins. Measured progression while fixing this:
  //   Next.js default 30 s   -> HTTP 500 at  30.1 s
  //   nginx / 300 s          -> HTTP 504 at 300.1 s   (with the line below set)
  // 3600 s (1 h) gives the inner proxy headroom above any run we have actually
  // seen, and nginx is set ABOVE this so the outer boundary is the last to
  // fail rather than the first.
  experimental: {
    proxyTimeout: 3600000,
  },

  async rewrites() {
    const rewrites = [];
    const gatewayURL = getInternalServiceURL(
      "DEER_FLOW_INTERNAL_GATEWAY_BASE_URL",
      "http://127.0.0.1:8001",
    );

    if (!process.env.NEXT_PUBLIC_LANGGRAPH_BASE_URL) {
      rewrites.push({
        source: "/api/langgraph",
        destination: `${gatewayURL}/api`,
      });
      rewrites.push({
        source: "/api/langgraph/:path*",
        destination: `${gatewayURL}/api/:path*`,
      });
    }

    if (!process.env.NEXT_PUBLIC_BACKEND_BASE_URL) {
      rewrites.push({
        source: "/api/agents",
        destination: `${gatewayURL}/api/agents`,
      });
      rewrites.push({
        source: "/api/agents/:path*",
        destination: `${gatewayURL}/api/agents/:path*`,
      });
      rewrites.push({
        source: "/api/skills",
        destination: `${gatewayURL}/api/skills`,
      });
      rewrites.push({
        source: "/api/skills/:path*",
        destination: `${gatewayURL}/api/skills/:path*`,
      });

      // Catch-all for remaining gateway API routes (models, threads, memory,
      // mcp, artifacts, uploads, suggestions, runs, etc.) that don't have
      // their own NEXT_PUBLIC_* env var toggle.
      //
      // NOTE: this must come AFTER the /api/langgraph rewrite above so that
      // LangGraph-compatible routes keep their public prefix while Gateway
      // receives its native /api/* paths.
      rewrites.push({
        source: "/api/:path*",
        destination: `${gatewayURL}/api/:path*`,
      });
    }

    return rewrites;
  },
};

export default withNextra(config);
