# Pacgate full-stack benchmark - v0.1.29 (2026-10-14 03:12)

Measured by `scripts/run-benchmark.ps1` on **LAPTOP-HH9V75MK**, revision `be48c98`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 4 | 92 | 92 / 6 / 4 |
| GET /setup (browser first-admin surface) | 200 | 37 | 187 | 187 / 43 / 37 |
| GET /pacgate/health (public API health) | 200 | 5 | 18 | 6 / 18 / 5 |
| GET / (deer-flow frontend via nginx) | 200 | 24 | 52 | 52 / 30 / 24 |
| POST /pacgate/api/auth/login | auth | 31 | 31 | 31 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 2119 |
| gemma4:12b local chat (short, warm) | 15509 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | 26.4 s (HTTP 200) |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| deer-flow-frontend | 0.00% | 184.7MiB / 15.44GiB |
| ocr-service | 0.24% | 1.398GiB / 15.44GiB |
| deer-flow | 0.22% | 295.6MiB / 15.44GiB |
| pacgate-mcp | 0.25% | 61.97MiB / 15.44GiB |
| pacgate-api | 0.00% | 1.641GiB / 4GiB |
| pacgate-nginx | 0.00% | 33.27MiB / 15.44GiB |
| pacgate-db | 0.00% | 68.79MiB / 15.44GiB |
| openviking | 1.88% | 697.3MiB / 15.44GiB |

## 4. Data plane

    tenants=1 users=3 matters=23 documents=21

## Verdict

All measured lanes responded. No lane errored.

---

## Regression against the previous release

A full comparison across 0.1.27, 0.1.28 and 0.1.29 - including why the LLM lanes are
not usable as a trend on this box and which number moved for reasons unrelated to
code - is in `deploy/REGRESSION-REPORT-2026-10-14-v0.1.29.md`. The short version:

| lane | 0.1.27 | 0.1.28 | 0.1.29 |
| --- | --- | --- | --- |
| deer-flow generation via nginx | 79.7 s | 26.1 s | **26.4 s** (held) |
| `nomic-embed-text` embedding (cold) | 3487 ms | 3190 ms | 2119 ms |
| `gemma4:12b` local chat (warm) | 12478 ms | 2804 ms | **15509 ms - NOT a regression** |

The `gemma4:12b` swing is contention on a single Ollama runner slot, not a code
change: 0.1.29 touches nothing in the inference path. The lane cannot resolve a 5x
difference on this box and must not be cited as either an improvement or a
regression.

**The regression that actually mattered in this range is not in this table.** The
0.1.28 defect returned HTTP 500 on 1 run in 3 for a document that had already been
written; it is measured as a failure rate (3/8 -> 0/14), which a latency report
cannot show. See `deploy/DEFECT-agent-loop-max-rounds.md`.