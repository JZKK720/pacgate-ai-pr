# 0.2.36 end-to-end audit — upgrade, smoke, and what it found

Date: 2026-11-22 · Machine: HX370 dev box (local AIPC-equivalent)
Release under test: **v0.2.36**, tag `v0.2.36` → `4bfda8b66da4`, GHCR run `44998397994`

This records the local upgrade to 0.2.36 and what verification actually showed,
including one defect in the shipped feature that only end-to-end testing could
expose. Every claim below was executed on this machine; nothing is inferred from
the release notes.

---

## 1. Upgrade: before → after

| | before | after |
|---|---|---|
| `pacgate-api` | 0.2.35 · rev `2924798` | **0.2.36** · rev `4bfda8b66da4` |
| `pacgate-mcp` | 0.2.35 · rev `2924798` | **0.2.36** · rev `4bfda8b66da4` |
| `deer-flow` | 0.2.35 · rev `2924798` | **0.2.36** · rev `4bfda8b66da4` |
| `deer-flow-frontend` | 0.2.35 · rev `2924798` | **0.2.36** · rev `4bfda8b66da4` |
| `ocr-service` | 0.2.35 · rev `2924798` | **0.2.36** · rev `4bfda8b66da4` |
| `openviking` | digest `46f9e34c…` | unchanged (not part of the release) |
| `pacgate-db`, `pacgate-nginx` | pgvector:pg16, nginx:1.27-alpine | unchanged |

Procedure: `compose pull` → `compose up -d`. Compose recreated exactly the five
release services; the database, nginx and openviking were left running. All eight
containers report `healthy`, and `/version` reports
`{"revision":"4bfda8b66da445c427c8e39492aea02b22356536","version":"0.2.36"}`.

**Gate that was red before the upgrade and is green after:**

| gate | on 0.2.35 | on 0.2.36 |
|---|---|---|
| `test-stack-version-coherence.ps1` | 9 passed, **5 failed** (MIXED STACK) | **14 passed, 0 failed** |
| `test-mcp-tool-surface.ps1` | 5 passed, **1 failed** (26 vs source 29) | **6 passed, 0 failed** (29 = 29) |
| `test-docx-redline.ps1` | exit 2 (engine absent) | **8 passed, 0 failed** |

---

## 2. The new features, verified end to end

### 2.1 DOCX redline engine — PASS

`test-docx-redline.ps1`, run against the live upgraded stack: **8/8**.

Real `<w:ins>`/`<w:del>` on a Chinese clause, with accept/reject round-tripping
exactly, and revisions attributed to `PacGate Legal Review` rather than the engine
default `Docxodus`.

### 2.2 Actionable failures (`repair_hint`) — PASS

`test-mcp-repair-hints.ps1`: **26/26**, mutation-verified.

### 2.3 Smoke suite — PASS (20/0)

`smoke-full-stack.ps1`: **20 passed, 0 failed, 1 skipped**. The skip is the
agent→MCP tool-loop lane, which is exercised separately by
`test-agent-mcp-e2e.ps1` — that also passes (9/0) in the full suite.

### 2.4 Post-deploy audit — PASS (18/18 stages)

`audit-post-deploy.ps1`: **18 passed, 0 failed, 0 cannot-check, 0 blocked, 0
skipped**. Highlights measured inside it:

- format coverage: **48 assertions**, every accepted format survives
  upload → extract → sanitize → convert
- legal journey: full multi-lane journey, **20 assertions**
- document generation: **19 passed, 0 failed**
- NER enabled across both base compose files

### 2.5 Full gate suite — PASS after three fixes

`run-all-checks.ps1` initially reported **4 failing gates**. All four were
diagnosed, and none was caused by the release code:

| gate | cause | class |
|---|---|---|
| `check-workflow-validity.ps1` | no YAML parser available: `powershell-yaml` absent **and** PyYAML missing from the host `python` the gate shells out to | environmental |
| `test-workflow-validity-mutations.ps1` | same parser dependency | environmental |
| `test-pdf-freshness.ps1` | **my omission** — see §3.1 | real, mine |
| `test-pdf-freshness-mutations.ps1` | depends on the above | real, mine |

After installing PyYAML and re-rendering the PDFs, all four pass:
5/0, 3/0, "23/23 PDFs current", and "every mutation rejected and every file
restored".

---

## 3. Defects this audit found

### 3.1 A release omission in my own commit (fixed)

`4bfda8b` bumped the version inside `deploy/AIPC-DEPLOYMENT-HANDBOOK.md` and its
Chinese counterpart but **did not re-render their PDFs**, so the rendered artifacts
still said 0.2.35 while their source said 0.2.36. `test-pdf-freshness` caught both
the stale renders and the diverged `client-delivery` copies. Fixed in `8bc7b14` by
re-rendering and syncing the delivery copies byte-identically.

### 3.2 A false failure in the smoke gate (fixed)

The openviking MCP lane reported `400 (a key IS configured, so this is a real
failure)`. It was not a failure. PowerShell re-quotes a JSON literal passed as a
native argument, so `curl` delivered `{jsonrpc:2.0,…}` and the server correctly
replied `Parse error: Expecting property name enclosed in double quotes`.

Measured: the **identical** command returned `200` from an interactive shell and
`400` from inside the script, with the same 64-character key. The lane now retries a
400 with the body supplied via `--data-binary @file`; a rejected key returns 401, so
this cannot mask an auth failure, and a missing key is still a SKIP.

### 3.3 The redline tools cannot reach a `.docx` through pacgate-api (OPEN)

**This is the significant finding, and it invalidates the end-to-end usefulness of
the feature as shipped.**

`pacgate_redline_compare` reads its inputs by calling
`GET /api/documents/:id/download`. That endpoint's body decision
(`documents.rs::download_body_for`) is:

```
("sanitized", text_like = false) => RefusedBinary     <-- a .docx
("sanitized", text_like = true ) => SanitisedText
("never",     _                ) => OriginalBinary
_                                => RefusedBinary
```

So for a `.docx` there are exactly two reachable states:

- **`pending`** → `409`: *"document is 'pending'; reading its body requires
  sanitization (or an explicit 'never' decision)"* — observed.
- **`sanitized`** → the download serves **redacted plain text**, not the binary
  package. Observed: `read_document` returned 112 characters of Chinese text ending
  in `creator: OfficeCLI lastModifiedBy: OfficeCLI`, i.e. the text rendering, not a
  zip. `docx-scalpel` then rejects it with `File contains corrupted data`.
- **`never`** → would return the `OriginalBinary`, **but no HTTP route sets that
  state.** Searched the Rust tree: `'never'` appears only as a *read* case in
  `documents.rs` and `egress.rs`; there is no `SET sanitize_state = 'never'`.

**Consequence.** In every state the product can actually reach, a binary `.docx`
cannot be fetched through the API, so the three redline tools cannot perform the job
they were built for. The engine is correct — the gate proves it 8/8 on bytes
already in memory — but the **transport** contradicts it.

This is not a sanitizer bug. The sanitizer is right: after redaction the artifact *is*
text, and serving the original binary would contradict the whole egress design. The
defect is in the feature I added: it assumes a body source the platform does not
offer.

**Options, not yet chosen** (this needs a decision, not a patch):

1. **A redaction-preserving binary lane.** Redaction would have to rewrite the
   `.docx` package itself (replace runs in `word/document.xml`), so a "sanitized"
   binary is genuinely redacted. Correct, and the largest change.
2. **A dedicated compare endpoint** that takes two document IDs and returns a
   redline built from the *original* package under an explicit, audited purpose —
   conceptually the `never` decision, but scoped to a named operation rather than a
   document state.
3. **Remove the tools.** They cannot be used as shipped; shipping an unusable tool
   is worse than not shipping it.

Option 2 is the smallest change that keeps the audit trail honest, and it reuses the
`ReadPurpose` mechanism that already exists. It is still a design decision about
egress, so it is recorded here rather than implemented unilaterally.

**What remains proven about the feature:** the engine, the contract assertion, the
CJK granularity, the author stamping, and the MCP surface (29 tools, correct schemas)
all work. What is *not* proven is a real client workflow, because no client workflow
can exist until the transport question above is settled.

---

## 4. Pre-existing conditions observed (not caused by 0.2.36)

- `openviking` was healthy throughout and its digest is unchanged; it was not
  recreated by this upgrade and started the day before.
- Two `client-delivery` PDFs (`deer-flow-openviking-pacgate-handbook.zh.pdf`,
  `qm-openviking-pacgate-handbook.zh.pdf`) legitimately differ from same-named files
  elsewhere; the freshness gate classifies them as separate documents and passes.
- `test-baked-patch-parity.ps1` skips the drift comparison because
  `deer-flow-pacgate:0.2.8` is not present locally. It passes 16/0 on everything it
  can check.
- `preflight-docker-egress.ps1` reports `CANNOT CHECK - no probe image`.

---

## 5. Verdict

The **upgrade is sound**: all five release images run the tagged revision, every
coherence and surface gate is green, the smoke suite passes 20/0, and the post-deploy
audit passes 18/18 stages including a full legal journey and 48 format-coverage
assertions.

The **redline feature is not usable end to end**, for the transport reason in §3.3.
That must be decided before the feature is described as shipped to a client.

Two smaller self-inflicted items were found and fixed during the audit (§3.1, §3.2).
