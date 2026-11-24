# External-repo integration audit + pacgate-ai stack round trip

**Date:** 2026-11-23 / 24
**Scope:** the eight integration repos the owner listed, then the full pacgate-ai
bundle (deer-flow, qm, pacgate-api, pacgate-mcp, openviking)
**Verdict: 5 of 8 repos are real code and every one of those round-trips live.
The pacgate stack has no regression, and four gates were reporting a healthy
stack as broken.**

---

## 0. The premise, corrected first

The eight names are **not in this repo**. Measured, not assumed:

| Search | Result |
| --- | --- |
| `pacgate-ai-pr/**` for `deepseek-harness`, `kitesurf`, `astryx` | **0 files** |
| `pacgate-ai-pr/**` for the other five | prose in `plans/035` only |
| `pacgate-ai-pr/deploy` compose + configs for all eight | **0 hits** |
| `pacgate-ai-pr` for `cubecloud` | **0 hits** |
| `cubecloud-agentic-os` for `pacgate` | **0 hits** |

They live in the sibling repo `cubecloud-agentic-os` and the coupling is **zero
in both directions**. So "the pacgate-ai bundle ... if regression fully inference
end to end" is two separate audits, and both were run. Anyone reading the eight
names as part of the client bundle would be auditing the wrong product.

---

## 1. The eight repos: code, then a live round trip

A unit test proves an adapter matches *my* understanding of a protocol. It cannot
prove the understanding matches the shipped runtime. Where a real runtime existed,
it was run.

| # | Repo | Code today | Live round trip |
| --- | --- | --- | --- |
| 1 | deepseek-harness | `harnesses/deepseek-harness.ts` 574 ln + `dsh-jsonrpc-client.ts`, `dsh-provider-config.ts`, `dsh-mcp-bridge.ts` | **PASS** |
| 2 | ag-ui | `packages/platform-core/src/ag-ui.ts` 626 ln, `POST /api/ag-ui/run` | **PASS** |
| 3 | A2UI | `shared/a2ui.ts` + `A2uiBlock.tsx` + fence producer in `AgentMarkdown.tsx` | **PASS** (render path, red-green) |
| 4 | DataFlow | `managed-apps/dataflow.ts` on `probeSse` | **PASS** (transport) |
| 5 | omnara | none | correctly absent, 0 references |
| 6 | univer | none | correctly absent |
| 7 | kitesurf | `managed-apps/kitesurf.ts` + `kitesurf-probe.ts` | **PASS** |
| 8 | astryx | none | correctly absent, 0 references |

### 1.1 deepseek-harness — against the real published runtime

Installed `@deepseek-ai/dsh@0.2.2-rc.5` (it is published), built the adapter
bundle, and ran `scripts/dsh-real-smoke.cjs`:

```
dsh: .../@deepseek-ai/dsh/lib/bin.js
── A. failure path (dead loopback route) ──
PASS  error: Connection error.: bad port
── B. success path (loopback OpenAI-compatible, no cloud) ──
PASS  "pong from real runtime", 30 tools, loopback only
✅ real-runtime smoke passed
```

Both halves matter. The success path proves a real turn; the failure path proves
the adapter reports a dead route instead of a clean empty turn — which the smoke's
own header records as bug 4, the one that shipped broken once.

`[skip]` in that script is not a pass: without `DSH_PACKAGE_DIR` plus a built
`adapter.cjs` it exits 0 having tested nothing. Both were supplied here.

### 1.2 ag-ui — a real model answer over SSE

The console backend was already up on `:6770` with `dataflowHealth` and
`kitesurfHealth` in its 314-route table. Driving `POST /api/ag-ui/run`:

```
data: {"type":"RUN_STARTED","threadId":"local-verify-4","protocolVersion":"1.0"}
data: {"type":"TEXT_MESSAGE_CONTENT","delta":"P"} ... "AC" "G" "ATE" "-A" "GUI" "-" "OK"
data: {"type":"RUN_FINISHED","outcome":{"type":"success"}}
```

`PACGATE-AGUI-OK` arrived as 8 deltas and the run finished `success`. Two traps
worth recording:

- The token is `CONSOLE_KERNEL_TOKEN`, read from the container — `ci-smoke-token`
  from `ci.yml` is a CI-only fixture and returns `{"success":false,"error":"invalid
  console token"}`.
- The body must be posted from a file. Hand-quoting the JSON through PowerShell
  produced `{"success":false,"error":"invalid JSON body"}` twice.

### 1.3 A2UI — the producer is what the tests guard

15 tests pass. Red-green, because a passing suite proves nothing about whether it
can fail: renaming the fence dispatch `if (language === "a2ui")` disabled the
producer and produced **1 failed / 14 passed**; restoring it produced **15
passed**. The producer wiring is genuinely covered.

### 1.4 DataFlow — the REAL application, not a fixture (superseded 2026-11-24)

`opendcai/dataflow-webui` has **no published image**: the anonymous GHCR token
flow issued no token for it, `/v2/` answered `401`, and `docker manifest inspect`
returned `manifest unknown`.

**The repo the owner supplied is not the MCP surface.** `OpenDCAI/DataFlow`'s
Dockerfile ends in `CMD ["/bin/bash"]` — an interactive shell, not a server — and
contains **zero** `fastapi_mcp` / `/mcp` references. The 20-tool MCP server lives
in the sibling **`OpenDCAI/DataFlow-WebUI`**, at `backend/app/mcp_server.py`, and
its `.mcp.json` declares exactly the shape the adapter assumes:

```json
{ "mcpServers": { "dataflow": { "type": "sse", "url": "http://localhost:8000/mcp" } } }
```

So it was run for real. Cloned `DataFlow-WebUI`, installed
`backend/requirements.txt` on a **uv-managed CPython 3.12.13**, started
`uvicorn app.main:app`, and drove the SSE handshake end to end:

```
app.mcp_server:create_mcp_server - MCP Server mounted at /mcp
GET  /mcp                    -> 200  event: endpoint
POST <endpoint> initialize   -> 202
POST <endpoint> tools/list   -> 202
tools returned: 20
```

The 20 names match both `DATAFLOW_EXPECTED_TOOL_COUNT` and the `include_operations`
whitelist verbatim (`list_pipelines`, `create_pipeline`, `execute_pipeline`,
`recommend_operator_categories`, `render_pipeline_in_editor`, …). The real adapter
reports `state: "found"` against it.

Two traps worth recording:

- **Python 3.12.10 on this box cannot create a venv** — it is missing
  `Lib\encodings`, so `python -m venv` dies with `ModuleNotFoundError: No module
  named 'encodings'`. `uv venv --python 3.12` provisions a clean 3.12.13 instead.
  The 3.10/3.12 requirement is real: `pyproject.toml` declares `>=3.7, <4`, and
  the system default here is 3.15.
- `probeSse` reads **only the first chunk** to learn the endpoint, so it returns
  `tools: null` and never enumerates. The adapter rendered that as "0 tools
  advertised" — a claim it had no evidence for, contradicting the 20 measured
  above. It now says "tool catalog not enumerated over SSE". Fixed in
  cubecloud `49370c1`.

Note the probe path detail: the adapter treats the configured URL **itself** as
the SSE stream (DataFlow's `/mcp` *is* the stream), which the real server
confirms — it answers `200 text/event-stream` with an `endpoint` event.

### 1.5 kitesurf — real container, real CDP handshake

`ghcr.io/cloudflare/kitesurf:latest` pulled and run on `127.0.0.1:8787`:

```
PROBE={"reachable":true,"baseUrl":"http://127.0.0.1:8787",
       "browser":"Kitesurf/0.0.1","protocolVersion":"1.3",
       "detail":"CDP target Kitesurf/0.0.1 speaking protocol 1.3","error":null}
```

Container removed after the measurement.

### 1.6 The three refusals are real absences, not missing work

`omnara`, `astryx`, and `univer` have **zero** source references. The single
`univer` hit was the word "universal" in a comment, and `astryx`/`omnara` had
none at all. Recorded refusals with reasons in
`cubecloud-agentic-os/docs/plans/2026-11-22-open-items-implementation-plan.md`;
the container framing did **not** change the astryx verdict.

### 1.7 What "functional" does and does not mean here

- **Proven:** the adapters, transports, and render paths work against the **real
  runtimes** — deepseek-harness (`@deepseek-ai/dsh@0.2.2-rc.5`), ag-ui (live SSE
  turn), kitesurf (real container), and DataFlow (the real `DataFlow-WebUI`
  backend with its real `fastapi-mcp` surface). Measured: **192 tests across 11
  files** (172 in `agent-desktop`, 20 in `packages/platform-core`).
- **Proven from the container, not just the host.** A host-process probe is the
  wrong vantage point for this stack. Measured inside `cc-console-backend-1`
  against the live backend: `localhost:8000/mcp` and `127.0.0.1:8000/mcp` both
  failed, `host.docker.internal:8000/mcp` answered `200` with an `endpoint`
  event. The deployed kernel now reports `dataflow: {"state":"found"}` naming
  that alias. See §7.
- **Not proven:** durability or multi-tenant behaviour under load — these were
  single round trips against one local deployment.
- **Operator decision, not a gap:** kitesurf and DataFlow are **opt-in roster
  entries**, not always-on lanes. Neither runs as part of the client bundle.
  kitesurf stays off because upstream says it is "not a hardened sandbox" and a
  CDP target executes page JavaScript — that must be an explicit choice, and the
  adapter keeps its off state honest (`capabilities: ["config"]`, `lifecycle:
  null`, `inventory: "unsupported"`).
- **Not applicable:** A2UI is a render path, exercised in-process; it emits no
  network round trip to prove.

---

## 2. pacgate-ai stack: no regression

| Gate | Result |
| --- | --- |
| `run-all-checks.ps1` | **ALL 70 GATES PASSED, exit 0** (25 live-stack gates) |
| `test-agent-mcp-e2e.ps1` | **9 passed** — real run, real tool call, record returned |
| `test-lane-connectivity.ps1` | **11 passed, 0 not reachable** |
| `test-mcp-tool-surface.ps1` | **6 passed** — 29 tools, source == advertised |
| `test-legal-journey.ps1` | **20 assertions, all lanes verified** |
| `test-docx-redline.ps1` | **11 passed** |
| `test-stack-version-coherence.ps1` | **16 passed** |

Full inference chain, proven end to end rather than inferred:

```
[PASS] E1b the DEFAULT picker model 'deepseek-v4.1-flash:cloud' is installed
[PASS] E2  an agent run completes (the KeyError-class defect)
[PASS] E2b the run produced an answer, not an LLM error fallback
[PASS] E3  the run invoked at least one real MCP tool
       called: pacgate_pacgate_list_connectors
[PASS] E4  a tool-call record came back
```

Independent lanes: openviking `tools/list` = **15 tools** and a real
`tools/call health` returned `"OpenViking is healthy (..., storage: VikingFS)"`;
qm 0.1.18 `readyz {"ok":true}` at core `988ce509…` with `Restarts=0`; pacgate-api
health `ok`; 222 workflows served.

---

## 3. Accelerated round trips

`benchmark-round-trips.ps1 -IncludeAgent -Runs 3`, this host. Compared against
the 0.2.37 report because it is the only prior table with the same probe set.

| Layer | Probe | Now (median) | Spread | 0.2.37 | Change |
| --- | --- | --- | --- | --- | --- |
| L0 | nginx → api `/version` | **16.1 ms** | 86% | 23.8 | **-32%** |
| L0 | api `/pacgate/health` | **5.5 ms** | 72% | 19.8 | **-72%** |
| L0 | deer-flow-frontend `/` | **25.6 ms** | 86% | 222.9 | **-89%** |
| L0 | qm core `/readyz` | 13.6 ms | 194% | n/a (was portal `/`) | different endpoint |
| L1 | `POST /auth/login/local` | 275.0 ms | **5%** | 302.3 | -9% |
| L1 | `POST /api/threads` | **41.1 ms** | **11%** | 61.8 | **-33%** |
| L2 | MCP handshake + `tools/list` (cold) | **314.7 ms** | **6%** | 371.2 | **-15%** |
| L4 | agent `/runs/wait` (tool loop) | **4,592.8 ms** | 29% | 4,767.1 | -4% |

One pass of every probe: **5,284 ms**.

Read this as a shape, not a spec: it is one dev box with one Ollama runner slot.
The interesting part is the spread collapse on the auth and MCP lanes (17%→5%,
18%→6%), which says those paths stopped being noisy — not that the hardware
changed. The L4 spread also fell from **187%** to 29%, so the agent lane is far
more stable than at 0.2.37 even though its median barely moved.

The qm row is **not comparable**: 0.2.37 timed a portal `/` that no longer exists
(hence its absurd 2388% spread on a 1.5–86.4 ms range); this times core
`/readyz`.

---

## 4. The defect this audit found — in our own gates

Four gates were probing the **qm portal port that the 0.1.18 migration deleted**
(`:8181`, `:8180`). Core serves `{"ok":true}` on `:8182`; the portal is gone. Each
gate produced a confident verdict about a dead service:

| Gate | Verdict it produced | Truth |
| --- | --- | --- |
| `benchmark-round-trips.ps1` | `[FAIL] no-response` | stack healthy |
| `smoke-full-stack.ps1` | `[SKIP] qm not running (000)` | stack healthy |
| `test-lane-connectivity.ps1` | E5/E6/E7 unreachable | stack healthy |
| `test-legal-journey.ps1` | "portal not reachable" | stack healthy |

This is plan 035 §7.2's stale-literal class on the port axis. Patching
`8181 → 8182` would reproduce it at the next topology change, so all four now
derive from config via `scripts/lib/QmEndpoint.ps1` (staged `.env` → tracked
`qm.config.jsonc` → the 0.1.18 default), and the health path is discovered
(`/readyz` then `/healthz`) so a route rename cannot report a healthy core as
down either.

**The fix was not cosmetic.** `test-legal-journey` went from

```
journey PASSED on every step that ran; some lanes were NOT verified
```

to

```
assertions passed: 20
RESULT: full legal journey PASSED, all lanes verified.
```

The retired-port skip had been silently hiding a real lane. A gate that reports a
deleted service as a broken product is worse than no gate: it spends the
reader's attention on a fault that does not exist, which is how a suite loses
authority.

### 4.1 The guard earned its place immediately

`scripts/test-stale-literal-guard.ps1` was added and registered, asserting
(A1) no qm port literal outside the resolver, (A2) no released image-tag literal
outside an explicit fixture, (A3) the resolver answers.

On its first run it found **two more literals a manual sweep had missed** —
`test-lane-connectivity.ps1:65` and `test-legal-journey.ps1:39`. Both were fixed.
Mutation-verified: injecting `http://localhost:8181/healthz` into a scratch repo
fails A1 with exit 1.

Shipped in `5d2c7b7`. Red-green held too: a dead qm endpoint still fails the
benchmark (`exit 1`, `no-response`), so the fix did not simply stop asserting.

---

## 5. Hazards recorded while doing this

1. **A mutation gate left a product file modified.** After a full suite run,
   `deploy/client-bundle/install.ps1` had
   `--untracked-files=no` stripped from a `git status` call. This is the exact
   hazard plan 027 documented. It was reverted with `git checkout --` and the
   gate was **not** touched. Always `git status` after a suite run.
2. **`ci.yml`'s AG-UI token is a fixture.** `x-console-token: ci-smoke-token` only
   works inside CI. Locally the token is `CONSOLE_KERNEL_TOKEN` from the
   container.
3. **The console backend is not in the pacgate stack.** It is a separate product
   on `:6770`. Auditing "the bundle" must not silently include it, and equally
   must not silently exclude it when the question is about the eight repos.

---

## 6. Open items, stated rather than implied

**All three limits recorded in the first version of this document are now closed
(2026-11-24), and each closure is proven rather than asserted.**

| Was | Now | Proof |
| --- | --- | --- |
| "DataFlow has no runnable upstream" | Resolved. The MCP surface is in **`DataFlow-WebUI`**, not `DataFlow`; it runs from source on CPython 3.12.13 | `MCP Server mounted at /mcp`, handshake 202/202, **exactly 20 tools** measured, adapter `state: found` |
| "`dsh-real-smoke.cjs` skips green" | Fixed. Exit codes are three-valued | absent → **exit 2**; real runtime → **exit 0** with both paths passing; `tests/dsh-real-smoke.test.ts` pins it (4 tests, red-green verified) |
| "kitesurf off by default" | Unchanged and **correct** — kept off, but its off state is now honest | `capabilities ["config"]`, `lifecycle null`, `inventory "unsupported"`; the card names the endpoint instead of a bare `fetch failed` |

Shipped in cubecloud `49370c1` (the three limit fixes) and `2c6d71d` (the
reachability defect in §7): 173 test files, **1851 passed**, 3 skipped, 0 failed;
`typecheck:node` clean; `check-mojibake` and `check-doc-pair` green.

What remains genuinely open, and is not a code defect:

- **kitesurf enabling is an operator decision.** Upstream says it is "not a
  hardened sandbox" and a CDP target executes page JavaScript. Making it
  always-on would be a policy change, not a fix.
- **DataFlow has no published image and no Dockerfile-driven compose.** Running
  it means building from source as done here. If it is ever wanted in the client
  bundle, that packaging work does not exist yet.
- **Nothing here was tested under load or multi-tenant.** These are single round
  trips against one local deployment.

---

## 7. The reachability defect that a host-side test could not see

My first round of verification ran the adapters from **this host process**, which
is the wrong vantage point for a containerised kernel. Running the same probes
from **inside `cc-console-backend-1`** exposed two independent blockers:

| # | Blocker | Consequence |
| --- | --- | --- |
| 1 | `normalizeMcpEndpoint` allowed plain http only on `localhost`/`127.0.0.1`/`::1` | `http://host.docker.internal:8000/mcp` returned `null` — refused before any socket opened |
| 2 | the DataFlow adapter had one fixed endpoint, no candidate list | even a correctly configured alias was never tried |

Measured inside the container, against the real backend:

```
http://localhost:8000/mcp             -> fetch failed
http://127.0.0.1:8000/mcp             -> fetch failed
http://host.docker.internal:8000/mcp  -> 200  "event: endpoint\r\ndata: /mcp/messages/?session_id=..."
```

A container's `127.0.0.1` is its own, so the gateway alias is the *only* route to
a host-run service. kitesurf had already solved this (`isLoopbackCdpUrl` includes
the alias, and `probeWithCandidates` tries it); the shared probe and the DataFlow
adapter had not.

**A unit test alone would not have found this either.** The deployed image
carried the defect — `POST /api/console/dataflowHealth` returned
`{"ok":false,"detail":"fetch failed"}` while every test was green, because the
tests mocked the probe. The fix was proven by rebuilding the image and asking the
live kernel:

```
POST /api/console/dataflowHealth
  -> {"ok":true,"detail":"reachable at http://host.docker.internal:8000/mcp
      (tool catalog not enumerated over SSE) — ..."}
listManagedApps
  -> dataflow {"state":"found","detail":"DataFlow reachable at http://host.docker.internal:8000/mcp — ..."}
  -> kitesurf {"state":"not-found","detail":"no CDP endpoint at http://127.0.0.1:8787"}
```

Fixed in cubecloud `2c6d71d`. The alias is matched exactly, so
`host.docker.internal.evil.com` and a plain-http `10.0.0.5` are still rejected —
a test pins both. The adapter reports the endpoint that **answered**, not the one
configured, and does not append the alias when the operator named a non-loopback
host.

**Lesson for the next audit:** for anything the kernel reaches, probe from inside
the kernel container. Host-side success is not evidence about the deployed path.
