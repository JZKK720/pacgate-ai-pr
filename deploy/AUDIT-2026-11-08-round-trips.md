# Round-trip audit, 2026-11-08

Audit of every Pacgate round trip against the live `0.2.32` stack, plus the
remediation of what it found. This is an evidence record, not a plan.

## Verdict

The stack is sound. Every lane connects and every gate passes. The one real
defect was in the knowledge base, and it was a verdict bug in the redactor, not
a broken pipeline: two substantive firm documents were permanently unqueryable
because a model-layer guess was allowed to be the decisive evidence.

## Evidence

### Full gate suite

`scripts/run-all-checks.ps1` against the live stack:

| Result | Count |
| --- | --- |
| PASS | 76 |
| FAIL | 0 |
| SKIP (CANNOT CHECK) | 1 |

`ALL 66 GATES PASSED (18 live-stack gate(s) checked separately)`.

The single skip was `test-chat-artifact-durability.ps1`, and it was a false
skip caused by the credential bug below. After the fix it passes 7/7.

### Live lanes verified

- **legal journey** - `full legal journey PASSED, all lanes verified`
- **lane connectivity** - 11 passed, 0 not reachable
- **MCP tool surface** - 6/6; **MCP argument paths** - 21/21
- **document generation** - 19/19; **format coverage** - every accepted format survived upload to extract to sanitize to convert
- **sanitizer E2E** - PASS; **text-native sanitize** - 59/59
- **OCR extraction** - PASS
- **officecli MCP** - 13/13
- **model picker** - 13/13
- **qm currentness** - clean, 0 warnings
- **stack version coherence** - 14/14; **origin coherence** - 14/14
- **agent MCP E2E** - 5/5

### Data and vector

- pgvector 0.8.6, `kb_chunks.embedding` is `vector(768)`, **1021 of 1021 chunks
  embedded**, `ivfflat` index with `lists=100`.
- CJK full-text works: `cjk_tsquery()` present, GIN index present, generated
  `content_tsv` splits CJK per character.
- Live KB search on `8a3a08ea` (`Firm Knowledge Base`): `合规` 4 hits,
  `质保金` 1, `违约` 4, `不可抗力` 5, `prompts` 5.
- 15 workflow templates served under `/app/workflows`.

## Defect 1: a model guess alone blocked a document

**Severity: high. It made real firm knowledge permanently unqueryable.**

`pacgate-redact`'s `verify()` treated any residue as `Block`:

```rust
let verdict = if residue.is_empty() { Verdict::Pass } else { Verdict::Block };
```

but `residue` is `structural` concatenated with `model_kept`. A
`MatchSource::Model` span is a guess, and `verify()` makes that guess about text
that has **already been through the redactor**. `VerifyScope::inside_placeholder`
only excludes a span wholly inside one placeholder, so a model detector can
re-fire on the token it just wrote - or on a fragment beside it - and that became
the reason the document was refused.

### Measured

Re-sanitizing reproduced the block exactly, so this was not stale state:

| Document | Chunks | Verdict | Promoted |
| --- | --- | --- | --- |
| `合规律师实用Prompts指南` | 144 | block | 0 |
| `基金律师实用Prompts指南` | 108 | block | 0 |
| `presented-pacgate-ai-平台实战教程` (docx) | 73 | block | 0 |
| `presented-pacgate-ai-平台实战教程` (pdf) | 70 | block | 0 |

The `sanitizer_jobs` ledger named the surviving spans:

```json
{"entity": "ORG",    "original": "黄山市人民政府"}
{"entity": "ORG",    "original": "保定市国资委"}
{"entity": "ORG",    "original": "平潭综合实验区国有资产管理局"}
{"entity": "PERSON", "original": "张三"}
{"entity": "PERSON", "original": "yuandian "}
```

None of that is client identity. `张三` is the textbook Chinese placeholder name.
`yuandian` is a registered connector name (`search.rs`), not a person. The three
orgs are public bodies in a published tutorial chapter that quotes them as
retrieval noise. An independent rescan of all 417 blocked chunks found **0
structural residue** (`chunks_offending=0`).

### Fix

Split the verdict by evidence, the same way the module already splits
suppression. Only structural evidence (checksum, pattern, context) may refuse a
document on its own. Model spans stay in `residue` and `notes` so a reviewer
still sees them; they just cannot be decisive.

Structural survivors still block unconditionally - covered by
`a_structural_survivor_still_blocks_beside_a_model_guess`, so the relaxation
cannot become a hole.

Tests: `a_model_guess_alone_does_not_block_a_document` (fails before the fix
with `left: Block, right: Pass`), the structural counterpart, and
`a_published_tutorial_naming_public_bodies_is_not_blocked` which runs the exact
production string. 178 pass in the crate, workspace 0 failures.

Commit `9f0e0c8`.

**The running `0.2.32` images still carry the old rule.** They are pinned
published artifacts and were not rebuilt. Blocked documents will stay blocked
until the fix ships in a new image or the affected documents are re-sanitized
against it.

## Defect 2: three gates were silently skipping

**Severity: high. Real coverage disappeared on exactly the provisioned machines.**

`test-agent-mcp-e2e.ps1`, `test-chat-artifact-durability.ps1` and
`clean-thread-workspaces.ps1` resolved the deer-flow password from only
`PACGATE_DEERFLOW_PASSWORD`, while machines provisioned before 2026-10-15 write
`DEER_FLOW_PASSWORD`. The lookup returned `$null`, the script took its
credentials-unavailable branch, and exited 2.

Exit 2 means CANNOT CHECK, and `run-all-checks.ps1` treats CANNOT CHECK as a skip,
not a failure. So the gate silently vanished from the suite.

After accepting both key names: `test-agent-mcp-e2e` 5/5,
`test-chat-artifact-durability` 7/7, `clean-thread-workspaces` authenticates and
enumerates 59 threads. Commit `81068a6`.

## Defect 3: seven gates are never run by the suite

**Severity: medium.**

`test-auth-registration-gate`, `test-host-memory-budget`, `test-initialize-gate`,
`test-laya-tools`, `test-ocr-extraction`, `test-sanitization-gate` and
`test-upload-symlink-guard` are not referenced by `run-all-checks.ps1`. All seven
were run by hand during this audit and all exit 0, so nothing is currently
broken - but they provide no ongoing protection.

Four `audit-*.ps1` scripts are likewise unrun: `audit-false-sanitized`,
`audit-doc-freshness`, `audit-plan-drift`, `audit-fork-divergence`. All exit 0.

`test-ci-verify-step.ps1` and `test-handbook-verify.ps1` are diagnostics, not
gates, and correctly stay out of the suite.

## Remediation applied

`scripts/process-pending-documents.ps1` drained the pending queue: 29 documents
through extract and sanitize. An interrupted first pass plus a resume left 38
documents `sanitized`.

Knowledge-base retrievability, admin tenant `9fc20614`:

| | Before | After |
| --- | --- | --- |
| Retrievable chunks | 86 of 360 (23.9%) | 473 of 868 (54.5%) |

The remaining 397 blocked chunks are the four documents above. They need the
redactor fix to be rebuilt into an image before they can be recovered.

Five documents remain `pending` in the seed tenant `d0bf26df` and cannot be
processed by the admin token - they belong to a different tenant, which is
correct isolation, not a defect.

## Known, not defects

- `PATCH /api/matters/:id` accepts only `external_key`; other fields are
  silently ignored. `PatchMatterRequest` has one field.
- Memory GET leaves `lastUpdated` empty after a write; the revision increments
  correctly.
- `test-baked-patch-parity.ps1` defaults `-Image` to `deer-flow-pacgate:0.2.8`, so
  it permanently skips unless the tag is passed.
- `audit-deer-flow-patches.ps1` and `audit-recursion-regressions.ps1` report
  CANNOT CHECK - the first needs a deer-flow clone on disk.
- `KB search` requires `matter_id`; omitting it returns a deserialize error
  rather than a validation message.

## Environment note

Docker Desktop's engine stopped mid-audit (`0xC0000142` / `STATUS_DLL_INIT_FAILED`
in every shell, then no engine at all). It was restarted and all 15 containers
came back healthy on their existing images. No data was lost. Worth knowing that
a long sanitizer batch on this box can exhaust the engine.

Upstream has **no** fix for this. Its sanitizer-related changes since `0.2.32`
are documentation plus a `PACGATE_SANITIZER_KEY` presence gate
(`audit-e2e-credentials.ps1`), not a batching or engine-pressure fix.

## Upstream merge: 4b4d72e

Merged 26 upstream commits (`17a498e..4b4d72e`) on `sync/upstream-4b4d72e`.

**Upstream does not contain the redactor verdict fix.** Verified directly:
`git show upstream/main:pacgate-ai/crates/pacgate-redact/src/verify.rs` still
reads `let verdict = if residue.is_empty() { ... } else { Verdict::Block }`, and
upstream touches no Rust crate at all in these 26 commits. The fix in `9f0e0c8`
is ours and stands.

Two content conflicts, both the same shape - each side added a different
deer-flow patch mount at the same anchor in `compose.bundle.yaml` and
`compose.prod.yaml`. Kept **both**, because they are independent interceptors on
different modules:

| Patch | Target module | Origin |
| --- | --- | --- |
| `deer-flow-mcp-client.py` | `harness/deerflow/mcp/client.py` | local-only, 900s read + per-server headers |
| `deer-flow-summarization-recovery.py` | `agents/middlewares/summarization_middleware.py` | upstream, replaces an INERT patch |

Taking either side alone would have silently disabled a fix. Both compose files
pass `docker compose config`, and no `image:` pin changed versus `17a498e` - the
summarization recovery is a mounted patch, so it needs no image bump.

`deer-flow` was recreated to pick up the new mount. Verified the patch is live
inside the container and both summarization gates pass against it:
`test-summarization-recovery` 22/22, `test-summarization-treadmill` 6/6.

### Suite after the merge

**85 PASS, 1 FAIL.** The failure is `test-release-provenance.ps1`, and it is a
**true positive**, not a false alarm:

```
FAIL  2 file(s) that CAN reach a built image changed after the published revision was built:
        pacgate-ai/crates/pacgate-redact/src/pipeline.rs
        pacgate-ai/crates/pacgate-redact/src/verify.rs
```

The gate compares the tag commit against `HEAD`. `v0.2.32` peels to `7a6dd73`,
which is exactly the revision the published images report, so the tag is
internally consistent - but our redactor fix landed after it. A rebuild from
`v0.2.32` would therefore not reproduce what clients pull. That is precisely the
defect this gate exists to catch, and it is correct to fail.

It clears when the fix ships in a new release. It is not something to suppress.

**This failure is accepted, not open.** Cutting a release is upstream's job, not this box's - see
`docs/superpowers/decisions/2026-11-08-no-local-release-cut.md`. Do not bump the version locally,
move `v0.2.32`, or add a skip to the gate to make it green. The gate is telling the truth: this
branch carries an unreleased change to a shipped artifact, and it stays red until upstream cuts a
release that includes it.
