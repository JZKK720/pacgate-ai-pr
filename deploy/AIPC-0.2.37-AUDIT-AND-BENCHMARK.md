# 0.2.37 audit and benchmark report

**Date:** 2026-11-22
**Release under test:** `v0.2.37`, tag peels to `df1fa67d80ca`, running revision
`df1fa67d80caf5daebd8e97385699497132b927b`
**Host:** AIPC — AMD Radeon 8060S (integrated), **4 GB VRAM**, 31.6 GiB RAM
**Suite result: ALL 69 GATES PASSED** (22 live-stack gates checked separately)

---

## 1. Completion verification

The full suite was run to completion against the live 0.2.37 stack:

```
ALL 69 GATES PASSED (22 live-stack gate(s) checked separately)
```

Two gates reported `CANNOT CHECK` / `SKIP` and were reviewed individually rather
than assumed benign:

| Gate | Verdict |
| --- | --- |
| `test-ollama-gpu-residency.ps1` | exit 2. Correct: no `inference compute` line in `server.log`. This box cannot run a local model at all (see §4). |
| `test-legal-ai-reference-freshness.ps1` | exit 2, 1 assertion unevaluable. Pre-existing, unrelated to 0.2.37. |

### 1.1 Defects this audit found and fixed

Four failures came out of the runs, and every one was a harness defect rather than a
product defect. That ratio is itself the finding.

**a. `test-install-repo-pull.ps1` hung the entire suite.** `$psi.ArgumentList.Add()`
throws on Windows PowerShell 5.1, and `run-all-checks.ps1` launches gates with
`powershell.exe`. Measured: the suite sat **~40 minutes having completed two gates**,
with 1.5 CPU-seconds consumed. `deploy/DEFECT-ps51-argumentlist-null.md` has documented
this since 2026-10-14 and prescribes a runtime branch, but **only one of four call
sites had ever been changed**. Fixed all four:

- `test-install-repo-pull.ps1` (the one that hung the suite)
- `test-update-end-to-end.ps1`
- `test-qm-sandbox-fingerprint.ps1`
- `qm-sandbox-fingerprint.ps1`

Capability detection is verified, not assumed: `$psi.PSObject.Properties.Match('ArgumentList').Count`
is **0** on 5.1 and **1** on pwsh. A bare `if ($psi.ArgumentList)` would have been
wrong for a different reason — the property does not exist there either.

**b. Two PDFs stale.** `test-pdf-freshness` compares **commit history**: the `.md` was
committed while the re-rendered `.pdf` was not. Re-rendered through
`deploy/handbooks/render_handbooks.py` (headless Chrome) so all three output paths come
from one source. Both `test-pdf-freshness` and its mutation gate now PASS.

**c. `test-qm-currentness` stale.** My own new `UPSTREAM-0.1.19-VERDICT.md` was in
`deploy/qm-pacgate/` but not in the gitignored staged copy
`deploy/client-bundle/qm-pacgate/`. The gate was right. Re-staged: `qm is current.`

**d. `test-rust-workspace.ps1` red in-suite, green standalone.** Contamination, not a
defect — a second suite instance from an earlier probe was running concurrently and
mutating the same fixtures. Worth recording because I nearly reported a regression I
had not caused: the same contamination produced `32/1` on a gate that is `33/0`.

---

## 2. Karpathy-guidelines audit of my own work

Applied to the full diff since the 0.2.36 release (`4bfda8b..HEAD`): 13 files,
~1,100 insertions.

| Rule | Applied | Result |
| --- | --- | --- |
| **1. Think before coding** | Stated the boundary up front (engine vs. tool) instead of assuming a passing engine meant a working feature. | The `409` blocker was found by asserting the *construct*, not the concept. |
| **2. Simplicity first** | Audited every new symbol for a second reference. | Found and removed **one** violation: `-OllamaUrl` declared and never used in the benchmark. |
| **3. Surgical changes** | Checked every changed line traces to a request; no adjacent refactors. | `smoke-full-stack.ps1` is the one change outside the named scope — justified in §2.1. |
| **4. Goal-driven execution** | Every claim has a command behind it; every gate was mutation-tested. | See §3 and §5. |

### 2.1 The one non-surgical change, and why it stays

`smoke-full-stack.ps1` gained a 25-line retry that re-posts a mangled JSON body from a
file. PowerShell re-quotes a JSON literal passed to a native command and strips the
inner quotes, so the openviking lane answered `400` against a healthy stack.

Simplicity would say: **always** post from a file and delete the retry branch. That is
the better shape, and I am recording it as the recommended follow-up rather than doing
it inside a release-verification commit. It is not free — the lane currently reports
which path it took, and silently switching the default would remove that signal.

### 2.2 Orphan check

Every new function is referenced more than once:

| Symbol | References |
| --- | --- |
| `_try_read_binary` | 3 |
| `_read_document_text` | 3 |
| `_ensure_sanitized_text` | 3 |
| `_finish_docx_redline` | 2 |
| `redline.compare_text` | 2 |

The four new Rust helpers (`run_pending`, `deleted_run_texts`, `inserted_run_texts`,
`revision_run_texts`) are test-module private helpers at `diff.rs:560-646`, used twice
each. Not speculative API.

---

## 3. Benchmarks

New harness: `scripts/benchmark-round-trips.ps1`. No threshold is asserted — a latency
budget chosen today becomes a flaky gate tomorrow on a different GPU. It prints numbers
with a **spread** column; comparing two runs is the operator's job.

`spread = (max - min) / median`, which is deliberately not a standard deviation: on 3-5
samples a single cold-start outlier is the thing worth seeing, and it is exactly what a
mean would hide.

### 3.1 Measured baseline (3 samples, agent lane on, clean machine)

All figures below come from **one** run, the JSON written by
`-Runs 3 -IncludeAgent -Json bench2.json`. Reporting a single dataset matters: an
earlier draft of this table mixed a 5-sample run with a 3-sample run, and the two
differ by up to 25% on the same probe.

| Layer | Probe | Median | Spread | Range |
| --- | --- | ---: | ---: | --- |
| L0 | nginx → api `/version` | 23.8 ms | 681% | 23.8 – 186.3 |
| L0 | api `/pacgate/health` | 19.8 ms | 47% | 17.1 – 26.5 |
| L0 | deer-flow-frontend `/` | 222.9 ms | 32% | 197.6 – 269.2 |
| L0 | qm portal `/` | 3.6 ms | 2388% | 1.5 – 86.4 |
| L1 | deer-flow `POST /auth/login/local` | 302.3 ms | 17% | 293.7 – 343.8 |
| L1 | `POST /api/threads` | 61.8 ms | 80% | 47.7 – 97.2 |
| L2 | MCP handshake + `tools/list` (cold) | 371.2 ms | 18% | 318.0 – 386.2 |
| L4 | agent `/runs/wait` (tool loop) | 4,767.1 ms | 187% | 4085.4 – 13007.3 |

One pass of every probe: **~5.8 s**.

### 3.2 Reading the numbers honestly

**L0 is not a floor to compare against L4.** The difference between `api /version`
(23.8 ms) and the frontend (222.9 ms) is server work, not network: both are loopback.
The frontend renders; `/version` returns a JSON literal.

**The huge L0 spreads are cold-start artifacts, not instability.** `qm portal` shows a
2388% spread on a 3.6 ms median because the range is 1.5–86.4 ms: one sample paid a cold
socket/DNS path, the rest did not. The median is the right statistic here precisely
because the spread is that wide. `qm portal` returns `401` by design (auth wall) — the
round trip still happened, which is what is timed.

**L2 is start-up-dominated and says so in its own output.** Measured decomposition:
`docker exec` + `python3 -c pass` = 233 ms, `+ import server` = 791 ms, full handshake =
~371 ms in-network. The protocol exchange is small; the cost is process + import
(`docx-scalpel`, `mcp`, `httpx`). A long-lived client pays it once. **Do not read
"371 ms" as "an MCP tool call takes 371 ms".**

**L4's spread is the finding.** Range 4.09 s → 13.01 s on a 4.77 s median: the first
call pays a cold model load, later calls do not. That is the shape the spread column
exists to expose, and a mean would have hidden it.

### 3.3 Two benchmark defects I shipped, found by reading the JSON

Both were found by inspecting the output file, not the console — the console looked
fine both times.

**The L2 probe measured nothing and reported `[ok]`.** It piped JSON-RPC at
`python3 /app/server.py` and counted occurrences of the `name` key. But `server.py`
**boots an HTTP server** ("Starting pacgate MCP server on :8000"); it does not speak
stdio. The probe captured container logs, found zero tool names, and passed. Corrected
to the in-network streamable-HTTP handshake copied from
`test-mcp-tool-surface.ps1`. L2 fell from 857 ms to 371 ms — the old figure included
booting an entire server the probe never talked to.

**The spread note printed a literal double percent** in the JSON while the console
showed one. `Write-Host -f` is .NET string formatting, not `printf`.

A third, caught before commit: the credential resolver read `.env`, but the password
lives in `.deer-flow-credentials`, so every authenticated lane silently skipped. And the
default email was `admin@pacgate.local` rather than `admin@pacgate-law.com`.

---

## 4. The model-capacity constraint (reported, not worked around)

Stage 8 and the three generative stages require a loaded model. This host cannot load
any local one:

| Fact | Value |
| --- | --- |
| VRAM | 4 GB (AMD Radeon 8060S, integrated) |
| Shipped picker default | `nemotron-3.5-bolt:e4b-q8_0`, 9.09 GB |
| Smallest local chat tag | `ornith-1.5:9b`, 6.10 GB |

The machine-local override (`regen-local-model-override.py --promote`) was used to make
`glm-5.3-flash:cloud` the picker default **on this box only**; the tracked client config
is untouched. That is why stage 8 now passes 9/9. See
`deploy/AIPC-0.2.37-E2E-VERIFICATION.md` §5 and §7 for the open commercial decision.

`test-aipc-capacity-fit.ps1` now takes `-VramGB`; at `-VramGB 4` it reports **9 capacity
warnings** where it previously reported none, because it was judging a 16 GB card that
was not present.

---

## 5. What is still open

1. **The `models[0]`-by-host decision** — the only commercial call. Recommendation: fail
   the install loudly on a host that cannot run the default, with cloud promotion as an
   explicit opt-in flag. Detail in `AIPC-0.2.37-E2E-VERIFICATION.md` §7.1.
2. **`smoke-full-stack.ps1` retry branch** — replace with always-post-from-file (§2.1).
3. **A repo-wide guard against version literals in gate scripts.** Four defects this
   round were one class: `:0.2.6`, `:0.2.8`, `$AipcVramGB = 16`, and a stale staged copy.
   Worth adding when the harness is next touched, not worth a release alone.
4. **qm stays on 0.1.4** — `deploy/qm-pacgate/UPSTREAM-0.1.19-VERDICT.md`.
