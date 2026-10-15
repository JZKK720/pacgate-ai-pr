# Pacgate full-stack benchmark - v0.1.27 (2026-10-13 10:44)

Measured by `scripts/run-benchmark.ps1` on **LAPTOP-HH9V75MK**, revision `39175ca`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 4 | 49 | 49 / 6 / 4 |
| GET /setup (browser first-admin surface) | 200 | 22 | 31 | 31 / 24 / 22 |
| GET /pacgate/health (public API health) | 200 | 4 | 8 | 8 / 4 / 4 |
| GET / (deer-flow frontend via nginx) | 200 | 27 | 39 | 39 / 27 / 39 |
| POST /pacgate/api/auth/login | auth | 26 | 26 | 26 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 3487 |
| gemma4:12b local chat (short, warm) | 12478 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | 79.7 s (HTTP 200) |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| deer-flow-frontend | 0.00% | 99.26MiB / 15.44GiB |
| deer-flow | 0.22% | 227MiB / 15.44GiB |
| pacgate-mcp | 0.26% | 53.58MiB / 15.44GiB |
| pacgate-api | 0.00% | 1.213GiB / 4GiB |
| ocr-service | 0.20% | 745.4MiB / 15.44GiB |
| pacgate-nginx | 0.00% | 29.03MiB / 15.44GiB |
| pacgate-db | 0.00% | 60.81MiB / 15.44GiB |
| openviking | 2.02% | 546.7MiB / 15.44GiB |

## 4. Data plane

    tenants=1 users=3 matters=8 documents=6

## Verdict

All measured lanes responded. No lane errored.
