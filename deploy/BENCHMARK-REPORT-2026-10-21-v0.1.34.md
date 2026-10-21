# Pacgate full-stack benchmark — v0.1.34 (2026-10-21 13:04)

Measured by `scripts/run-benchmark.ps1` on **CUBECLOUD01**, revision `a43d87c`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The absolute
> numbers are not a client-AIPC specification; use the shape and any regression
> against a previous run. LLM lanes run sequentially because a concurrent chat
> starves embeddings on a single runner slot.

**Run status:** `RC=0`, "All measured lanes responded. No lane errored."

> ⚠ **There is no valid same-machine baseline.** The previous report
> (`BENCHMARK-REPORT-2026-10-14-v0.1.29.md`) was measured on **`LAPTOP-HH9V75MK`**
> with a **15.44 GiB** Docker VM ceiling. This run is on **`CUBECLOUD01`** with
> **30.17 GiB**. They are *different machines*, so the table in §5 is a
> cross-machine comparison and must not be read as a version-over-version
> regression. It is included only because both used the same script and the same
> lane definitions.

---

## 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 33 | 92 | 92 / 33 / 34 |
| GET /setup (browser first-admin surface) | 200 | 82 | 102 | 102 / 89 / 82 |
| GET /pacgate/health (public API health) | 200 | 21 | 43 | 43 / 41 / 21 |
| GET / (deer-flow frontend via nginx) | 200 | 154 | 179 | 179 / 154 / 177 |
| POST /pacgate/api/auth/login | auth | 134 | 134 | 134 |

## 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| `nomic-embed-text` embedding (first call, cold) | 10804 |
| `gemma4:12b` local chat (short, warm) | 4243 |
| deer-flow generation delivered through nginx (`gemma4-12b-local`) | **1.9 s (HTTP 200)** |

## 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| pacgate-api | 0.00% | 55.36MiB / 4GiB |
| deer-flow-frontend | 0.00% | 187.9MiB / 30.17GiB |
| deer-flow | 0.19% | 741.4MiB / 30.17GiB |
| pacgate-mcp | 0.22% | 57.25MiB / 30.17GiB |
| ocr-service | 0.17% | 924.1MiB / 30.17GiB |
| pacgate-nginx | 0.00% | 21.37MiB / 30.17GiB |
| pacgate-db | 4.52% | 43.67MiB / 30.17GiB |
| openviking | 2.32% | 557.7MiB / 30.17GiB |

## 4. Data plane

```
tenants=1 users=4 matters=2 documents=0
```

## Verdict

All measured lanes responded. No lane errored.

---

## Comparison against 0.1.29 — CROSS-MACHINE, not a regression

| lane | 0.1.29 on `LAPTOP-HH9V75MK` | **0.1.34 on `CUBECLOUD01`** | read |
| --- | --- | --- | --- |
| deer-flow generation via nginx | 26.4 s | **1.9 s** | different machine — not attributable to the version |
| `nomic-embed-text` embedding (cold) | 2119 ms | 10804 ms | different machine + live contention |
| `gemma4:12b` local chat (warm) | 15509 ms | 4243 ms | different machine |
| GET /version | 4 / 92 ms | 33 / 92 ms | comparable shape |
| GET / | 24 / 52 ms | 154 / 179 ms | frontend freshly re-pulled |
| POST auth/login | 31 ms | 134 ms | cold JWT/bcrypt path |

**Why this table proves nothing about the version.** The two runs differ in at
least five ways that all move these numbers:

| | 0.1.29 | 0.1.34 (this run) |
| --- | --- | --- |
| Machine | `LAPTOP-HH9V75MK` | **`CUBECLOUD01`** |
| Docker VM memory ceiling | 15.44 GiB | **30.17 GiB** |
| Ollama residency | stock defaults | `NUM_PARALLEL=2`, `MAX_LOADED=2`, `KEEP_ALIVE=15m` |
| Context | machine-wide | **per-model pins at 32768** (`pacgate-mid`, `pacgate-low`) |
| deer-flow credential | absent (lane skipped) | **present (lane measured)** |

The deer-flow lane is **newly measurable** in this report — the 0.1.29 run had no
credential and skipped it, so 1.9 s has no counterpart in that report's LLM table
at all. 0.1.34 also touches no inference path relative to 0.1.29.

**What can legitimately be said:** every lane on this machine responded, and the
*shape* is sane — the public edge answers in tens of milliseconds, the local 12B
model answers in low single-digit seconds once warm, and generation delivered
through nginx landed in 1.9 s. Nothing here should be cited as an improvement or a
regression versus 0.1.29. A real version comparison needs both releases measured
on **one** box, back to back.

---

## Caveats specific to this run

1. **One runner slot.** Lanes run sequentially by design; any other Ollama
   consumer on the box distorts the LLM rows. This box shares Ollama with 14
   unrelated containers.
2. **`docs=0`.** The data plane holds no documents, so no lane exercised RAG over
   real content. Embedding latency is a cold-call number only.
3. **Cloud model not exercised here.** `PACGATE_MODEL_MAIN` is unset, so compose
   falls back to `deepseek-v4.1-flash:cloud`. The benchmark's generation lane
   drives `gemma4-12b-local`, not the cloud default. The two are not
   interchangeable for document workflows — see `.env.example`.
4. **Absolute numbers are not a client-AIPC spec.** Use the shape, and only
   compare against runs on this same box.
