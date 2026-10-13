# Pacgate full-stack benchmark - v0.1.28 (2026-10-13 18:47)
Measured by `scripts/run-benchmark.ps1` on **LAPTOP-HH9V75MK**, revision `b5ef2b1`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 5 | 95 | 95 / 7 / 5 |
| GET /setup (browser first-admin surface) | 200 | 23 | 120 | 120 / 23 / 23 |
| GET /pacgate/health (public API health) | 200 | 4 | 6 | 6 / 4 / 4 |
| GET / (deer-flow frontend via nginx) | 200 | 27 | 39 | 39 / 27 / 29 |
| POST /pacgate/api/auth/login | auth | 56 | 56 | 56 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 3190 |
| gemma4:12b local chat (short, warm) | 2804 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | 26.1 s (HTTP 200) |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| ocr-service | 0.20% | 484.5MiB / 15.44GiB |
| deer-flow-frontend | 0.00% | 172MiB / 15.44GiB |
| deer-flow | 0.21% | 262MiB / 15.44GiB |
| pacgate-mcp | 0.25% | 64.48MiB / 15.44GiB |
| pacgate-api | 0.00% | 1.542GiB / 4GiB |
| pacgate-nginx | 0.00% | 31.86MiB / 15.44GiB |
| pacgate-db | 0.00% | 78.67MiB / 15.44GiB |
| openviking | 2.10% | 567.2MiB / 15.44GiB |

## 4. Data plane

    tenants=1 users=3 matters=17 documents=15

## Verdict

All measured lanes responded. No lane errored.

---

## Regression against v0.1.27 (same box, same runner slot, ~8 h apart)

| Lane | 0.1.27 | 0.1.28 | change |
| --- | --- | --- | --- |
| deer-flow generation via nginx | 79.7 s | **26.1 s** | **-53%** |
| gemma4:12b local chat (warm) | 12478 ms | **2804 ms** | -78% |
| nomic-embed-text embedding (cold) | 3487 ms | 3190 ms | -9% |
| `GET /version` (min) | 4 ms | 5 ms | flat |
| `GET /setup` (max) | 31 ms | 120 ms | +89 ms, first-sample noise |
| `GET /` frontend via nginx | 27 / 39 ms | 27 / 39 ms | identical |

**Read this carefully: the LLM numbers are NOT a claim that 0.1.28 made the
model faster.** Nothing in 0.1.28 touches inference. Both runs use the same
single Ollama runner slot on the same box, and the earlier 0.1.27 numbers were
taken while other work was running (`gemma4:12b` at 12.5 s for an 8-token reply
is contention, not compute). The useful signal is direction and shape, not the
magnitude: the delivery lane is in the same order of magnitude on both, and the
proxyTimeout defect that showed up as a hard 500 would appear here as `ERR 500`
or a 30 s cutoff, not as a slow-but-successful run.

The lanes that DO have a 0.1.28-specific explanation, and are worth trusting:

- **Container footprint, `ocr-service`**: 745.4 MiB -> 484.5 MiB. The weights are
  baked into the image instead of being downloaded into a writable volume layer,
  and no volume is mounted over `/root/.paddleocr` any more.
- **Data plane growth** (matters 8 -> 17, documents 6 -> 15) is test debris from
  the gate suite, not a product change.

Not measured here, and stated so the report is not read as broader than it is:
per-page OCR throughput on a real scan, concurrent-user behaviour (one runner
slot makes that meaningless on this box), and anything on client AIPC hardware.
See `deploy/DEFECT-ocr-weights-not-baked.md` for the OCR cold/warm measurements
(269.9 s cold vs 3.4 s warm) which this HTTP-latency table does not capture.
