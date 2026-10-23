# Pacgate v0.2.3 - full-stack audit, smoke test and benchmark

**Date:** 2026-10-23
**Host:** PACGATE-AI02 (29.6 GB RAM, WSL2 Docker)
**Revision:** `0e9a8a68` (v0.2.3 + the four gate fixes from the sync)
**Produced by:** `scripts/run-benchmark.ps1`, `scripts/smoke-full-stack.ps1`,
`scripts/test-legal-journey.ps1`, `scripts/measure-deerflow-lanes.ps1`, plus the
per-service probes recorded below.

> **Scope.** This is a dev box, not a client AIPC. The absolute numbers are not a
> specification; the shape and the pass/fail state are what they are useful for.
> Every number below was produced on this machine on 2026-10-23. Nothing is
> carried over from an earlier report.

---

## 1. Verdict

| Surface | State | Evidence |
| --- | --- | --- |
| `pacgate-api` | **PASS** | `/build-info` -> `0.2.3` @ `d33553e`; legal journey 19/19 |
| `pacgate-mcp` | **PASS** | 19 tools, source == advertised, 2 tools actually invoked |
| `deer-flow-pacgate` | **PASS** | generation HTTP 200 in 13.8 s; agent sees 35 tools |
| `deer-flow-frontend` | **PASS** | 200 on :8090, branded |
| `ocr-service` | **PASS** | imports clean, baked weights present |
| `qm-pacgate` | **PASS** | 4 surfaces reachable, admin grant correct, current |
| `openviking` | **PASS** | 15 tools; 401/401/200 auth matrix; write->recall roundtrip |

**All five release services run `0.2.3`**, created 2026-10-23 03:08-03:20 UTC - a
coherent full deploy, not the partial recreate that plan 030 found on the other box.

```
scripts/run-all-checks.ps1   -> ALL 48 GATES PASSED (14 live-stack gates)
scripts/smoke-full-stack.ps1 -> 19 passed, 0 failed, 2 skipped
scripts/test-legal-journey.ps1 -> 19 assertions passed
```

---

## 2. A defect found and fixed during this audit

`scripts/run-benchmark.ps1` could not log in to deer-flow, so its most important
lane was permanently red.

Commit `a9ea06b4` ("stop the verdict certifying a run it never inspected")
correctly converted the login from JSON to form-encoding, but wrote the body as:

```powershell
-Body "username=$DfEmail&******"
```

The password was replaced by a literal `******`. `$DfPassword` was resolved
from `.deer-flow-credentials` and then never sent, so the lane returned ERR 401
against a healthy deer-flow on every run - and the script's own closing note
("an ERR here has been a STALE CREDENTIAL every time") would have sent the next
reader to check the credential file, which was correct all along.

Fixed to send the resolved value, URL-encoded so a password containing `&` or
`+` cannot corrupt the form:

```powershell
-Body "username=$([uri]::EscapeDataString($DfEmail))&password=$([uri]::EscapeDataString($DfPassword))"
```

**Measured after the fix:** deer-flow generation lane `13.8 s (HTTP 200)`, and
the verdict reads "All measured lanes responded. No lane errored."

This is the same class as the four gate defects fixed in the sync: a check that
reports a failure it caused itself, which trains the reader to ignore it.

---

## 3. Per-service audit

### 3.1 pacgate-api

| Check | Result |
| --- | --- |
| `/health` | 200 `ok` |
| `/build-info` | `{"revision":"d33553e...","version":"0.2.3"}` |
| `/version` unauthenticated | 401 (correct - protected) |
| `/pacgate/` ingress | 401 for anon (correct) |
| memory limit | 4 GiB (`4294967296`) |
| data plane | tenants=2 users=8 matters=15 documents=33 |

Legal journey, end to end through the real API:

| Step | Result |
| --- | --- |
| workflow library | 222 workflows served |
| upload | document created |
| OCR / extract | 30 chars, `incomplete=False` |
| sanitize | `verdict=pass`, 2 redactions, 2 mappings |
| review gate | `state=sanitized`, egress gate opened correctly |
| internal KB search | 1 chunk, scoped to the matter |
| external search | 130 results |
| connectors | 9 of 10 available |

### 3.2 pacgate-mcp

| Check | Result |
| --- | --- |
| source declares | 19 tools |
| server advertises | 19 tools |
| set equality | exact match, no missing, no extra |
| descriptions | all 19 present |
| input schemas | all 19 present |
| `pacgate_list_matters` invoked | `isError=False`, 3281 bytes of real data |
| `pacgate_list_connectors` invoked | `isError=False`, 981 bytes |

Listing tools is not the same as calling them, so two were actually invoked over
the wire and returned real payloads.

### 3.3 deer-flow-pacgate

| Check | Result |
| --- | --- |
| container | healthy, `0.2.3` |
| MCP servers configured | 3 (openviking, pacgate, officecli) |
| **agent -> MCP aggregation** | **35 tools: 19 pacgate + 15 openviking + 1 officecli** |
| generation through nginx | 13.8 s, HTTP 200 |
| auth gate | wrong password -> 401 `invalid_credentials` |

The agent->MCP lane is the one `smoke-full-stack.ps1` skips ("no committed
agent-run E2E"). It was closed here by driving deer-flow's own
`MultiServerMCPClient` with its own rendered config, which is the same code path
the agent uses. Result: 35 tools, of which 19 are pacgate's.

### 3.4 deer-flow-frontend

| Check | Result |
| --- | --- |
| `:8090` | 200 |
| branding | 47 files reference pacgate |
| via nginx `/` | 200, 169-296 ms |

### 3.5 ocr-service

| Check | Result |
| --- | --- |
| module import | clean |
| volume shadows on `/root/.paddleocr` | none |
| baked weights | det + rec + cls present |
| `_page_spans` (the 0.2.2 fix) | present |

### 3.6 qm-pacgate

| Surface | Result |
| --- | --- |
| core `:8180` | 401 (auth required - correct) |
| portal `:8181` | 401 (auth required - correct) |
| web-ui `:8182` | 200 |
| admin `:8183` | 200 |
| `admin_grants` | `admin@pacgate-law.com` -> `org:pacgate` / `org_admin` |
| currentness gate | current, 0 warnings |

The `ADMIN_GRANTS` row is the fix from `07e5b0b9` (a bare email seeded zero
admins); it now carries the `principal:scope:role` shape the schema expects.

### 3.7 openviking

| Check | Result |
| --- | --- |
| `/health` | 200 |
| MCP, no key | **401** |
| MCP, wrong key | **401** |
| MCP, valid key | **200** |
| tools | 15 |
| write -> recall roundtrip | passed (`remember` -> `find`) |

The auth matrix is the point: a 200 with no key would mean the key is decorative.

---

### 4. Benchmark

#### Pacgate full-stack benchmark - v0.2.3 (2026-10-23 18:30)

Measured by `scripts/run-benchmark.ps1` on **PACGATE-AI02**, revision `0e9a8a68`.

> **Scope.** This is a dev box (WSL2 Docker, one Ollama runner slot). The
> absolute numbers are not a client-AIPC specification; use the shape and any
> regression against a previous run. LLM lanes run sequentially because a
> concurrent chat starves embeddings on a single runner slot.

#### 1. HTTP latency through nginx (the client-facing edge)

| Endpoint | Status | Min ms | Max ms | Samples |
| --- | --- | --- | --- | --- |
| GET /version (nginx root, staleness probe) | 200 | 22 | 84 | 84 / 22 / 22 |
| GET /setup (browser first-admin surface) | 200 | 60 | 128 | 128 / 61 / 60 |
| GET /pacgate/health (public API health) | 200 | 20 | 22 | 21 / 20 / 22 |
| GET / (deer-flow frontend via nginx) | 200 | 169 | 296 | 169 / 171 / 296 |
| POST /pacgate/api/auth/login | auth | 276 | 276 | 276 |

#### 2. LLM / RAG lanes (one runner slot, sequential)

| Lane | ms |
| --- | --- |
| nomic-embed-text embedding (first call, cold) | 3992 |
| gemma4:12b local chat (short, warm) | 12446 |
| deer-flow generation delivered through nginx (gemma4-12b-local) | 13.8 s (HTTP 200) |

#### 3. Container footprint (idle, snapshot)

| Container | CPU % | Mem usage |
| --- | --- | --- |
| deer-flow | 0.15% | 242.9MiB / 14.44GiB |
| pacgate-mcp | 0.17% | 95.73MiB / 14.44GiB |
| deer-flow-frontend | 0.01% | 567MiB / 14.44GiB |
| pacgate-api | 0.00% | 1.303GiB / 4GiB |
| ocr-service | 0.16% | 912MiB / 14.44GiB |
| pacgate-nginx | 0.00% | 29.54MiB / 14.44GiB |
| pacgate-db | 0.01% | 44.55MiB / 14.44GiB |
| openviking | 2.02% | 582.6MiB / 14.44GiB |

#### 4. Data plane

    tenants=2 users=8 matters=15 documents=33

#### Benchmark verdict

All measured lanes responded. No lane errored.


---

### 5. Lane timing detail (deer-flow)

From `scripts/measure-deerflow-lanes.ps1`:

| Signal | Value | Reading |
| --- | --- | --- |
| prompt cache (host) | 595.91 MiB of 8192 MiB | not the constraint |
| llama-server starts | 10 | churn |
| evictions | 4 | churn |
| forced re-processing | 8 | churn |
| SWA shift unsupported | 10 | prompt cache invalidated by SWA checkpoints |
| 3-message thread input | 6012 tokens | the floor is bound surface, not history |

The 6012-token floor for a 3-message thread is the number worth carrying forward:
it is the bound tool surface, not conversation history, and it is why prefill
dominates. That is a config property, not a hardware one.

---

## 6. What this audit does not prove

- **Not a client AIPC.** 29.6 GB host, one Ollama runner slot. A 16 GB client card
  will behave differently, and `test-aipc-capacity-fit.ps1` is the gate for that,
  not this report.
- **No concurrent-load measurement.** Every lane ran sequentially because a
  concurrent chat starves embeddings on a single runner slot.
- **The resident model was `gemma4:12b-it-q8_0` (13 GB), not the configured
  `gemma4:12b-it-qat` (7.2 GB).** `q8_0` is the OpenViking VLM
  (`OPENVIKING_CONF_CONTENT` in `.env`), so the two are both legitimately in
  play - but it means the 13.8 s generation figure was measured with the larger
  model resident, and a run where `qat` is resident should be faster. Not a
  defect; a caveat on the number.
- **`qm` images are local build IDs, not semver tags.** They are not part of the
  five-service release pin, so `test-stack-version-coherence.ps1` correctly does
  not assert them. Their currentness is asserted by `test-qm-currentness.ps1`
  instead.
