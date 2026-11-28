# Pacgate full-stack benchmark - v0.3.0 (2026-11-28 14:32)

Measured by `scripts/run-benchmark.ps1` on **LAPTOP-HH9V75MK**, revision `77e5a1d`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | min / median / max (ms), per sample |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 8 | 111 | 111 / 10 / 8 |
| GET /setup (browser first-admin surface) | 200 | 30 | 71 | 71 / 30 / 46 |
| GET /pacgate/health (public API health) | 200 | 6 | 18 | 18 / 6 / 6 |
| GET / (deer-flow frontend via nginx) | 200 | 12 | 30 | 30 / 12 / 14 |
| POST /pacgate/api/auth/login | auth | 282 | 282 | 282 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 2048 |
| nemotron-bolt local chat (short, warm) | 2185 |
| deer-flow generation delivered through nginx (nemotron-bolt-7b-local) | 19.4 s (HTTP 200) |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| deer-flow-frontend | 0.00% | 117.2MiB / 15.44GiB |
| deer-flow | 14.32% | 397.5MiB / 15.44GiB |
| pacgate-mcp | 0.31% | 53.87MiB / 15.44GiB |
| pacgate-api | 0.00% | 973.3MiB / 4GiB |
| ocr-service | 0.24% | 910.1MiB / 15.44GiB |
| openviking | 4.00% | 1.084GiB / 15.44GiB |
| pacgate-db | 0.00% | 72.38MiB / 15.44GiB |
| pacgate-nginx | 0.00% | 28.39MiB / 15.44GiB |

## 4. Data plane

    tenants=1 users=4 matters=11 documents=152

## Verdict

All measured lanes responded. No lane errored.
