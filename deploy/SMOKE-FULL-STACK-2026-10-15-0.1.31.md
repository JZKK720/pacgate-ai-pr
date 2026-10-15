# Pacgate full-stack smoke test - v0.1.31 (2026-10-15 16:10)

Measured by `scripts/smoke-full-stack.ps1` on **PACGATE-AI02**, revision `788bbc9c`.
Image revision under test: `9d3193666bb28c2751503647b8495c38267866f4`.

> **Scope.** Lane-by-lane reachability and wiring verdict over the RUNNING stack.
> A lane reported `SKIP (cannot-check)` is NOT verified - do not read it as passing.
> Companion artifacts: `BENCHMARK-REPORT-2026-10-15-0.1.31.md` (timings),
> `scripts/run-all-checks.ps1` (gates).

## Raw output

```
=== FULL STACK SMOKE — 0.1.31 ===

== pacgate-api (pai) ==
    /version -> {"revision":"9d3193666bb28c2751503647b8495c38267866f4","version":"0.1.31"}
    [PASS] /version reports 0.1.31
    [PASS] /version carries a real revision
    [PASS] pacgate-api /health -> 200 (probed on the compose network)
    [PASS] /pacgate/ ingress reachable (401)
    [PASS] protected route refuses anon (401)

== pacgate-mcp ==
    [PASS] 19 MCP tool definitions present (image == source, >= 16 baseline)
    [PASS] the 0.1.21 401-retry fix is present in the RUNNING image
    [PASS] MCP serves 19 pacgate tools (19 total in tools/list, matches source)

== deer-flow-pacgate ==
    [PASS] deer-flow is configured with the pacgate MCP server
    [PASS] 3 MCP servers enabled (openviking + pacgate + officecli)
    [PASS] deer-flow auth gateway reachable (setup-status 200)
    [SKIP] agent->MCP invocation NOT exercised: it needs a deer-flow session, and there is no committed agent-run E2E. Do not read this lane as fully verified.

== deer-flow-frontend ==
    [PASS] frontend serves 200 on :8090
    [PASS] frontend is BRANDED (47 files reference pacgate)

== openviking ==
    [PASS] openviking /health -> 200
    [PASS] container health = healthy
    [SKIP] openviking MCP -> 401 (needs the root key in env; covered by test-legal-journey lane 10)

== ocr-service ==
    [PASS] ocr-service module imports cleanly
    [PASS] no volume shadows /root/.paddleocr (baked weights are the tree)
    [PASS] baked weights present: det + rec + cls

== qm-pacgate ==
    [PASS] qm portal reachable (200)

=== RESULT ===
  passed: 19   failed: 0   skipped(cannot-check): 2
RESULT: every reachable lane passed
```

## Verdict

19 passed, 0 failed, 2 cannot-check. Every reachable lane passed.

Two lanes are NOT covered by this script and must be read separately:

- **agent -> MCP invocation** was not exercised (needs a deer-flow session). Covered
  instead by `test-legal-journey.ps1` lane 10 and the MCP `tools/call` sweep.
- **openviking MCP** returned 401 on the unauthenticated probe. Covered by
  `test-legal-journey.ps1` lane 10 (write -> recall round trip, PASS).
