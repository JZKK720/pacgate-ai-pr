# Regression report — 0.1.27 → 0.1.29

**Date:** 2026-10-14
**Host:** `LAPTOP-HH9V75MK` (dev box, WSL2 Docker, **one** Ollama runner slot)
**Sources:** `BENCHMARK-REPORT-2026-10-13-v0.1.27.md`,
`BENCHMARK-REPORT-2026-10-13-v0.1.28.md`,
`BENCHMARK-REPORT-2026-10-14-v0.1.29.md` (all produced by `scripts/run-benchmark.ps1`)

> **Read this first.** A latency table cannot show the regression that actually
> mattered in this range. The 0.1.28 defect was a **request that failed**, not one
> that ran slowly: `POST /api/workflows/:id/execute` returned HTTP 500 on 1 run in 3
> while the document was written anyway. None of the numbers below would have
> changed. The regression evidence for that lives in §4.

---

## 1. The delivery lane — the one number worth trusting

This is the lane the 0.1.27 `proxyTimeout` defect broke, so it is the one with a
causal link to a fix.

| release | deer-flow generation via nginx | |
| --- | --- | --- |
| 0.1.27 | **79.7 s** | the stacked-timeout defect present |
| 0.1.28 | **26.1 s** | `proxyTimeout` 30 s → 3600 s, nginx 300 s → 3600 s |
| 0.1.29 | **26.4 s** | unchanged |

**Regression vs 0.1.28: none** (+0.3 s, inside noise). The fix held across the
0.1.29 rebuild, which is the property that matters — a fix that does not survive the
next release is not a fix.

## 2. The LLM lanes — and why their numbers must not be read as a trend

| lane | 0.1.27 | 0.1.28 | 0.1.29 |
| --- | --- | --- | --- |
| `nomic-embed-text` embedding (cold) | 3487 ms | 3190 ms | **2119 ms** |
| `gemma4:12b` local chat (short, warm) | 12478 ms | **2804 ms** | **15509 ms** |

**`gemma4:12b` moved 2804 ms → 15509 ms and this is NOT a regression.** Nothing in
0.1.29 touches inference. All three runs share a **single** Ollama runner slot on a
box running 21 containers including the qm stack, Hermes and OpenViking; the lanes
are measured sequentially precisely because a concurrent chat starves them. The
0.1.28 figure of 2804 ms for an 8-token reply is the outlier here, not the 0.1.29
figure — and the 0.1.27 figure (12478 ms) was itself taken under contention, which
that report already says.

The honest statement: **this lane cannot detect a 5x difference on this box, so it
must not be used to claim either an improvement or a regression.** It is reported
because dropping it would hide that fact.

The embedding lane's 3487 → 3190 → 2119 ms movement is likewise unattributable:
it is a cold-cache lane, and "cold" depends on what ran before it.

## 3. HTTP edge latencies — no regression

| endpoint | 0.1.27 min/max | 0.1.28 min/max | 0.1.29 min/max |
| --- | --- | --- | --- |
| `GET /version` | 4 / 49 | 5 / 95 | 4 / 92 |
| `GET /setup` | 22 / 31 | 23 / 120 | 37 / 187 |
| `GET /pacgate/health` | 4 / 8 | 4 / 6 | 5 / 18 |
| `GET /` (frontend) | 27 / 39 | 27 / 39 | 24 / 52 |

Every status is 200. The `GET /setup` maximum rose (31 → 120 → 187 ms) but that is
the **first of three samples** in each run and it is a Next.js server-render of the
setup page: it measures cold render, and the box's load at the time, not the
release. Sub-200 ms on a cold server render is not a client-visible problem.

## 4. The regression that mattered — measured as a failure rate, not a latency

| | 0.1.28 and earlier | 0.1.29 |
| --- | --- | --- |
| `POST /api/workflows/:id/execute`, 8 consecutive runs | **3 of 8 returned HTTP 500** | **8 of 8 returned HTTP 200** |
| same, 6 consecutive runs on the *published* image | — | **6 of 6 returned HTTP 200** |
| runs where the agent round cap fired | every one was a 500 | **2 of those 6, all delivered** |

This is the number a benchmark table structurally cannot show. `run-benchmark.ps1`
samples endpoints that are expected to succeed; it has no notion of "the same call,
N times, count the failures". The evidence comes from the document-generation gate
(`scripts/test-document-generation-e2e.ps1`, 19/19) and from driving the endpoint
directly 14 times across both the local build and the published tag.

**That gap is real and is not fixed here**: there is no committed script that
measures the *failure rate* of a route under repetition. The gate catches a
regression only when it happens to hit it in a single run, and the 0.1.28 defect was
1-in-3, so a single-run gate has a ~67% chance of passing the broken build.

## 5. Container footprint — one number moved a lot, and it is not comparable

| container | 0.1.27 | 0.1.28 | 0.1.29 |
| --- | --- | --- | --- |
| `ocr-service` | 745.4 MiB | 484.5 MiB | **1.398 GiB** |
| `pacgate-api` | 1.213 GiB | 1.542 GiB | 1.641 GiB |
| `deer-flow` | 227 MiB | 262 MiB | 295.6 MiB |
| `deer-flow-frontend` | 99.3 MiB | 172 MiB | 184.7 MiB |
| `openviking` | 546.7 MiB | 567.2 MiB | 697.3 MiB |

`ocr-service` at **1.398 GiB** versus 484.5 MiB on 0.1.28 is a 2.9x jump and it is
**not** a regression: this snapshot was taken minutes after the OCR probes ran, so
PaddleOCR has its models resident. `docker stats --no-stream` reports the state at
that instant, so the OCR figure means "post-use" in this run and "idle" in the
previous one. Comparing them is meaningless.

The slow drift on `pacgate-api` (1.213 → 1.542 → 1.641 GiB) and `openviking`
(546.7 → 567.2 → 697.3 MiB) is more likely cumulative state — 23 matters now versus
8 at 0.1.27 — than a code change. Neither is near its 4 GiB limit.

## 6. Data plane

| | 0.1.27 | 0.1.28 | 0.1.29 |
| --- | --- | --- | --- |
| matters | 8 | 17 | 23 |
| documents | 6 | 15 | 21 |

Growth is gate and audit debris, not product behaviour. A clean run was performed
afterwards: audit-created matters deleted, 0 remaining.

---

## Verdict

| claim | verdict |
| --- | --- |
| The 0.1.27 delivery fix held through 0.1.29 | **YES** — 26.1 s → 26.4 s |
| The 0.1.29 round-cap fix is a real regression fix | **YES** — 3/8 failures → 0/14 |
| HTTP edge performance regressed | **NO** |
| LLM lanes regressed | **UNKNOWN on this box** — the measurement cannot resolve a 5x swing |
| Memory footprint regressed | **NO evidence either way** — the snapshots are not comparable |

### Residuals

1. **No automated baseline comparison.** `run-benchmark.ps1` prints numbers and its
   own header says regressions against a previous run are the useful part, but it
   does not load a stored baseline or fail on a delta. Every comparison above was
   assembled by hand from three files, which is exactly the manual step that let
   0.1.27 ship with no current report at all.
2. **No failure-rate measurement.** See §4. The 0.1.28 defect was 1-in-3 and no
   committed script would reliably have caught it.
3. **The LLM lanes are not usable as a trend** on a single-runner box (§2) and should
   either be given a quiet-box precondition or dropped from the report.
