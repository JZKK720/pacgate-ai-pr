# Pacgate full-stack benchmark - v0.1.31 (2026-10-15 16:16)

Measured by `scripts/run-benchmark.ps1` on **PACGATE-AI02**, revision `040f184f`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 5 | 43 | 43 / 6 / 5 |
| GET /setup (browser first-admin surface) | 200 | 16 | 23 | 23 / 17 / 16 |
| GET /pacgate/health (public API health) | 200 | 4 | 6 | 6 / 5 / 4 |
| GET / (deer-flow frontend via nginx) | 200 | 24 | 31 | 31 / 24 / 29 |
| POST /pacgate/api/auth/login | auth | 38 | 38 | 38 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 2064 |
| gemma4:12b local chat (short, warm) | 78111 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | 19.1 s (HTTP 200) |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| ocr-service | 8.90% | 991MiB / 14.44GiB |
| deer-flow-frontend | 0.00% | 1.476GiB / 14.44GiB |
| pacgate-nginx | 0.00% | 29.73MiB / 14.44GiB |
| deer-flow | 0.16% | 379.3MiB / 14.44GiB |
| pacgate-mcp | 0.17% | 253.7MiB / 14.44GiB |
| pacgate-api | 0.00% | 1.629GiB / 4GiB |
| pacgate-db | 0.01% | 53.17MiB / 14.44GiB |
| openviking | 1.48% | 560.2MiB / 14.44GiB |

## 4. Data plane

    tenants=2 users=8 matters=14 documents=32

## Verdict

All measured lanes responded. No lane errored.
