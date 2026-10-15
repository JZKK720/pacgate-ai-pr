# Pacgate full-stack benchmark - v0.1.31 (2026-10-15 15:56)

Measured by `scripts/run-benchmark.ps1` on **PACGATE-AI02**, revision `788bbc9c`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 7 | 49 | 49 / 7 / 11 |
| GET /setup (browser first-admin surface) | 200 | 20 | 83 | 83 / 22 / 20 |
| GET /pacgate/health (public API health) | 200 | 4 | 6 | 6 / 4 / 5 |
| GET / (deer-flow frontend via nginx) | 200 | 22 | 40 | 40 / 22 / 22 |
| POST /pacgate/api/auth/login | auth | 29 | 29 | 29 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 3172 |
| gemma4:12b local chat (short, warm) | 3256 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | ERR 401 |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| ocr-service | 0.18% | 969.6MiB / 14.44GiB |
| deer-flow-frontend | 0.00% | 1.397GiB / 14.44GiB |
| pacgate-nginx | 0.00% | 29.84MiB / 14.44GiB |
| deer-flow | 0.17% | 177.5MiB / 14.44GiB |
| pacgate-mcp | 0.18% | 201.6MiB / 14.44GiB |
| pacgate-api | 2.59% | 1.648GiB / 4GiB |
| pacgate-db | 0.00% | 60.04MiB / 14.44GiB |
| openviking | 2.58% | 534.1MiB / 14.44GiB |

## 4. Data plane

    tenants=2 users=8 matters=16 documents=32

## Verdict

All measured HTTP and local-LLM lanes responded. **One lane errored and is NOT
a stack fault:** the deer-flow generation row above reports `ERR 401`, because
`run-benchmark.ps1` logs into deer-flow with a stale hardcoded password. The
same endpoint returns 200 with the current credential from
`deploy/client-bundle/.deer-flow-credentials` sent as form-data. See
`SMOKE-FULL-STACK-2026-10-15-0.1.31.md` and
`scripts/test-model-picker-e2e.ps1` for the two harness defects behind it.

Do not read this report's deer-flow row as a deer-flow failure, and do not read
the original "no lane errored" line as accurate - it was written by the script
without inspecting that row's own status.
