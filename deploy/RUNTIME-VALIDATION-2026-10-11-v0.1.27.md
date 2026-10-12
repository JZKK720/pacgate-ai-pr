# Runtime validation - v0.1.27 (2026-10-11)

Full-stack audit and end-to-end smoke of the Pacgate AI client bundle on this
machine, following the release of 0.1.27.

Release under test: **0.1.27** (`Cargo.toml` workspace version `0.1.27`, tag
`v0.1.27` -> commit `32171f4`).

> **STATUS: COMPLETE.**
>
> CI run `38140030085` finished **success** on `headBranch v0.1.27`. All five
> images were built, pushed, and passed the workflow's own anonymous-HEAD
> manifest check. The published `0.1.27` tag was then pulled onto this stack
> and probed; the results are recorded in section 6.4.

Why 0.1.27 was cut: validating 0.1.26 with a Chinese-language end-to-end probe
found a release-blocking defect in the DOCX tracked-edit path. The defect, its
raw-byte proof, and the four-part fix are documented separately in
`DEFECT-docx-tracked-edit-nesting.md`. This file records the runtime evidence
around the fix.

## 1. Verdict

| Area | Result |
| --- | --- |
| Container runtime refreshed and healthy | PASS - on the published 0.1.27 contract |
| Rust regression suites | PASS - 18/18 and 87/87 |
| End-to-end smoke (deer-flow output pipeline) | PASS - on published 0.1.27 |
| End-to-end audit (`e2e-audit.py`) | PASS - 5/5 on published 0.1.27 |
| CJK DOCX end-to-end probe on 0.1.26 | **FAIL - 23/26** (the reason for this release) |
| CJK DOCX end-to-end probe on the fixed build | PASS - 26/26, zero failures |
| CJK DOCX end-to-end probe on published 0.1.27 | **PASS - 26/26, zero failures** |
| UTF-8 / CJK integrity (the client requirement) | PASS |
| Published 0.1.27 artifact pulled onto this stack | **PASS** - `revision 32171f4`, `version 0.1.27` |
| Full local gate sweep (`run-all-checks.ps1`) | **PASS** - all 34 gates, 4 live-stack gates separately |

The only failing area in the whole pass is the behaviour on 0.1.26, which is the
defect this release corrects. Everything measured against 0.1.27 is green, on
the shipped artifact. The first sweep reported 4 gate failures; all four are
root-caused in section 10, and three of them were real defects - including a
stale client-facing handbook PDF that the mtime-based gate had passed.

### 1.1 Publication and visibility

| Check | Result |
| --- | --- |
| CI run `38140030085` (`headBranch v0.1.27`) | **completed / success** |
| Workflow steps | all 15 substantive steps success; `Confirm GHCR login` skipped as designed |
| Workflow's own `Verify image manifest (anonymous HEAD)` | success |
| `verify-delivery-state.ps1` | **ALL CHECKS PASSED**, exit 0 |
| Anonymous pull of all five `0.1.27` tags | **200** for `pacgate-api`, `pacgate-mcp`, `ocr-service`, `deer-flow-pacgate`, `deer-flow-frontend-pacgate` |

All five packages already existed from earlier releases, so no
private-to-public flip was needed.

**Visibility gotcha, recorded because it cost time.** A credential-less
`HEAD /v2/<owner>/<repo>/manifests/<tag>` returns **401 for public and private
packages alike** - the registry always issues a `WWW-Authenticate: Bearer`
challenge first. It is not a privacy signal. A credential-less call to
`https://ghcr.io/token?scope=repository:<owner>/<repo>:pull&service=ghcr.io`
does not discriminate either: in this session it returned `403` for all five
real packages *and* for a deliberately non-existent control package.

The two trustworthy methods are:

1. whether the token endpoint issues an anonymous token at all, and
2. `verify-delivery-state.ps1`, which fetches an anonymous token first and only
   then HEADs the manifest with it.

Both agree: **all five 0.1.27 packages are publicly pullable.**

## 2. Environment

| Item | Value |
| --- | --- |
| Host | Windows, PowerShell |
| Repo | `JZKK720/pacgate-ai-pr` |
| Rust workspace root | `pacgate-ai/` |
| Docker server | 29.8.2 |
| Python (host probes) | 3.13.14, httpx 0.28.1 |
| Compose project | `client-bundle` (volume identity preserved) |

The stack runs from `deploy/client-bundle/compose.prod.yaml`. Containers report
`project=client-bundle`; `pacgate-db` data lives in the named volume
`client-bundle_pacgate-db-data` and survived a forced recreate.

## 3. Stack refresh

The stack was restored to the pinned client contract
`ghcr.io/jzkk720/pacgate-api:0.1.26` at the end of the pre-release work, and
the 0.1.26 stack was the one exercised for the pre-release measurements in
sections 4 and 5. The 0.1.27 images were then pulled and the stack moved onto
them; section 6.4 records the post-swap state.

All seven stack services are pinned to the 0.1.27 release images, and
`pacgate-api` - the service that carries the DOCX fix - is running the published
0.1.27 artifact for every measurement in section 6.4.

| Service | Image | Running |
| --- | --- | --- |
| `pacgate-api` | `ghcr.io/jzkk720/pacgate-api:0.1.27` | 0.1.27 |
| `pacgate-mcp` | `ghcr.io/jzkk720/pacgate-mcp:0.1.27` | 0.1.27 |
| `ocr-service` | `ghcr.io/jzkk720/ocr-service:0.1.27` | 0.1.27 |
| `pacgate-db` | postgres (volume `client-bundle_pacgate-db-data`) | n/a |
| `deer-flow` | `ghcr.io/jzkk720/deer-flow-pacgate:0.1.27` | 0.1.27 |
| `deer-flow-frontend` | `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.27` | 0.1.27 |
| `nginx` | local conf, `/pacgate/` prefix rewrite | n/a |

All five release images report `org.opencontainers.image.revision` =
`32171f4fce3ea31f43b9662366be429772a5bef5`, the commit the `v0.1.27` tag points
at, so every running service is the built revision and not a stale local tag.

> **Pull note.** This host's Docker Desktop resolves `ghcr.io` through a direct
> connection with no HTTPS proxy, and several pulls of the larger layers
> (~500 MB) died mid-stream with `unexpected EOF` / `lookup ghcr.io: no such
> host`. The pulls were retried until they landed; the registry is fine, the
> link is not stable. `pacgate-api` is 956 MB and pulled clean on the second
> attempt. No code or contract change is implied by this - the pins were already
> correct.

`pacgate-db` was force-recreated after an earlier compose-ownership conflict
left it attached to a different project. Data survived; no re-initialisation
was needed.

Health after refresh:

- `GET /pacgate/health` -> `ok`
- `GET /pacgate/build-info` -> `{"revision":"32171f4fce3ea31f43b9662366be429772a5bef5","version":"0.1.27"}`

Note for operators: the revision marker is at **`/pacgate/build-info`**, not
`/pacgate/version` (that route does not exist - 401 without a token, 404 with
one). This has cost time before.

## 4. Rust regression suites

Run from the workspace root `pacgate-ai/`.

| Command | Result |
| --- | --- |
| `cargo test -p pacgate-docx --lib` | **18 passed; 0 failed** |
| `cargo test -p pacgate-api --lib` | **87 passed; 0 failed** |

Both suites were re-run after the version bump to 0.1.27 and stayed green.

The 18 in `pacgate-docx` are 7 pre-existing `store::tests` plus 11 new
`diff::tests` covering the tracked-edit writer and the accept-path flattener.
The `pacgate-api` count rose from 85 to 87 with the two new seam tests in
`text_extract.rs`.

### Protected regressions

These existing tests all still pass, which is what rules out a fix that trades
one defect for another:

- `store.rs` CJK char-boundary fix (7 tests)
- `adjacent_runs_do_not_fuse_into_one_token` - the reason the run-separator
  change had to be conditional rather than a blanket removal
- `element_name_matching_respects_the_name_boundary`
- `xml_entities_are_decoded_in_runs`
- `docx_without_a_declared_body_part_is_incomplete`
- `docx_reads_tracked_deletion_text`
- `docx_reads_deleted_field_code_text`
- `docx_reads_instr_text_field_code`
- `docx_reads_core_metadata`
- `docx_metadata_fields_are_labelled`

## 5. End-to-end smoke and audit

Both were run against the locally built fixed image, and re-run against the
published 0.1.27 stack after the swap (section 6.4). Both are green there too.

| Suite | Command | Result on published 0.1.27 |
| --- | --- | --- |
| deer-flow smoke | `deploy/client-bundle/smoke-deer-flow-outputs.ps1 -BaseUrl http://localhost:8090 -ThreadId <uuid>` | `RESULT: PASS`, exit 0 - all five steps `[OK]` |
| stack audit | `python .\deploy\client-bundle\e2e-audit.py` | 5/5 PASS, exit 0 |

Both pass on the fixed image built from the 0.1.27 source.

Operational notes discovered while running these:

- `smoke-deer-flow-outputs.ps1` cannot provision its own thread. A thread must
  exist first (`POST /api/threads`), and the gateway requires `X-CSRF-Token`
  on mutating `/api/*` calls or it returns 403. Neither is documented.
- The deer-flow gateway and `pacgate-api` use **different** auth stacks. The
  gateway takes OAuth2 form-encoded login and sets an `access_token` cookie
  plus a `csrf_token` cookie; `pacgate-api` takes JSON login and a Bearer token
  and has no CSRF layer. Sending JSON to the gateway yields 422.
- A 401 with `Content-Length: 0` from `pacgate-api` means the request never
  reached the handler - check the nginx `/pacgate/` prefix rewrite rather than
  the credentials.

## 6. The CJK end-to-end probe - the actual gate

The probe (`scripts/cjk-live-probe.py`, 28 assertions) exercises the real
production path against the running stack: upload a Chinese DOCX, apply two
anchored tracked edits, read the text back, accept the changes, read again,
then delete what it created. It asserts byte-exact round trips and scans
container logs for char-boundary panics.

All Chinese text in the probe source is written as `\uXXXX` escapes so the
probe itself cannot be corrupted by a console code page.

**It cleans up after itself.** Each run creates its own matter and document
family, and deletes both on the way out - documents first, because
`delete_document_family` drops the files and every version row for that
document name while `MatterStore::delete` is a bare `DELETE FROM matters` with
no cascade. The deletion is registered with `atexit`, so a failed assertion, an
early `sys.exit` and an unhandled exception all still clean up; that safety net
is verified by falsification (see 6.5), not assumed.

### 6.1 On shipped 0.1.26 - FAIL

```
EXIT=1   TOTAL=26  PASS=23  FAIL=3
failures: ["edited_tip_is_running_text", "edited_tip_context_preserved", "accepted_text_is_exact"]
```

| Assertion | Detail |
| --- | --- |
| `edited_tip_is_running_text` | `{"text_len_chars":28,"roundtrip_bytes_match":false}` |
| `edited_tip_context_preserved` | `{"has_ctx_before":false,"has_ctx_after":false,"has_head":true,"has_tail":false,"has_tail2":false}` |
| `accepted_text_is_exact` | `{"text_len_chars":18,"expected_chars":76,"expected_bytes":228,"actual_bytes":50,"roundtrip_bytes_match":false}` |

A 76-character Chinese paragraph came back as 18 characters. Everything after
the second tracked edit was gone.

### 6.2 Root cause, proven from raw bytes

The probe's own output files were pulled out of the container with `docker cp`
and unzipped.

| File | `document.xml` size | Structure |
| --- | --- | --- |
| `pin_v3.docx` (after edits, 0.1.26) | 953 bytes | `<w:del>`/`<w:ins>` nested **inside** an open `<w:t>`; also reused `w:id="1"` and `w:id="2"` |
| `pin_v4.docx` (after accept, 0.1.26) | 515 bytes | inner `<w:r><w:t>` still nested inside the outer `<w:t>` |

`diff.rs::replace_first_in_xml` was splicing the revision markup straight into
the middle of a `<w:t>` character-data node. The result is well-formed XML but
invalid OOXML - `<w:del>` and `<w:ins>` are only legal as peer runs of `<w:r>`
inside `<w:p>`. `text_extract.rs` then treated the inner elements as literal
text of the outer run and consumed the outer terminator, dropping the tail.

The code carried its own admission:

```rust
// In production this should parse the XML properly; for now use string replace.
```

Short ASCII fixtures never expose it. Chinese prose does, because a whole
paragraph is one long text node with no spaces to break it up.

### 6.3 On the fixed build - PASS

```
EXIT=0   TOTAL=26  PASS=26  FAIL=0
failures: []
```

The three previously failing assertions, and the new ones:

| Assertion | Detail |
| --- | --- |
| `edited_tip_is_running_text` | 84 chars, `roundtrip_bytes_match: false` (expected - the tip still carries the `w:delText` of the deleted spans, by design, until `/accept`) |
| `edited_tip_context_preserved` | all of `has_ctx_before`, `has_ctx_after`, `has_head`, `has_tail`, `has_tail2` true |
| `accepted_text_is_exact` | `{"text_len_chars":76,"expected_chars":76,"expected_bytes":228,"actual_bytes":228,"roundtrip_bytes_match":true}` |
| `accepted_deleted_cjk_removed` | ok |
| `accepted_cjk_survives_intact` | ok |
| `accepted_not_incomplete` | ok |
| `no_char_boundary_panics_in_logs` | ok - all four containers `"clean"` |

Structural proof of the repair, from the same raw-byte method:

| File | Before | After |
| --- | --- | --- |
| `v3.docx` (after edits) | 953 B, nested, ids `1`,`2` reused | **1039 B**, `<w:del>`/`<w:ins>` are peer runs of `<w:r>`, ids unique `1,2,3,4` |
| `v4.docx` (after accept) | 515 B, nested, tail lost | **601 B**, fully flat - five sibling `<w:r><w:t>` runs, entire paragraph tail present |

### 6.4 On published 0.1.27 - PASS

Run against the artifact pulled from the registry, not a local build.

```
docker pull ghcr.io/jzkk720/pacgate-api:0.1.27   -> sha256:cd9ca7025ac9...
docker inspect pacgate-api                       -> ghcr.io/jzkk720/pacgate-api:0.1.27
                                                    revision 32171f4fce3ea31f43b9662366be429772a5bef5
                                                    version  0.1.27
GET /pacgate/build-info   (Bearer)               -> {"revision":"32171f4fce3a...","version":"0.1.27"}

python scripts/cjk-live-probe.py
EXIT=0   TOTAL=28  PASS=28  FAIL=0
failures: []
matters 12 -> 12, documents 46 -> 46   (no leak)
```

The image label and the running process agree, and both resolve to `32171f4`
- the exact commit that carries the four source fixes. This closes the gap
between "fixed in a local build" and "fixed in the artifact a client installs".

The three assertions that failed on 0.1.26, now measured on the published
artifact:

| Assertion | On 0.1.26 | On published 0.1.27 |
| --- | --- | --- |
| `edited_tip_is_running_text` | FAIL - 28 chars | **PASS - 84 chars** |
| `edited_tip_context_preserved` | FAIL - `has_tail:false`, `has_tail2:false` | **PASS - all five true** |
| `accepted_text_is_exact` | FAIL - 18 vs 76 chars | **PASS - 76/76, 228/228 bytes** |

The other 25 assertions passed on both, including `login_json_token`,
`versions_after_two_edits`, `edited_tip_retains_original_until_accept`,
`accepted_deleted_cjk_removed`, `accepted_cjk_survives_intact`,
`accepted_not_incomplete`, and `no_char_boundary_panics_in_logs` (all four
containers `clean`). The 0.1.26 run predates `cleanup_document_deleted` and
`cleanup_matter_deleted`, which is why that column reads 23 passed of 26.

**Structural proof from the published artifact.** Fresh `docker cp` of the two
versions this run produced, then a raw `word/document.xml` comparison against
the local-build capture:

| File | Published 0.1.27 | Local build | `document.xml` byte-identical |
| --- | --- | --- | --- |
| `pub_v3.docx` (after two edits) | 1254 B | 1254 B | **yes** - 1039 B both |
| `pub_v4.docx` (after `/accept`) | 1147 B | 1147 B | **yes** - 601 B both |

Not merely the same size - the decompressed part is byte-for-byte equal, so the
published binary executes the same path as the build that was tested.

| Part | Structure |
| --- | --- |
| `pub_v3` `document.xml` | `<w:del>`/`<w:ins>` are **peer runs** of the surrounding `<w:r>`; revision ids **unique** (`1`,`2`,`3`,`4`) |
| `pub_v4` `document.xml` | fully flat - five sibling `<w:r><w:t>` runs, entire paragraph tail present |

For contrast, the same two files on 0.1.26 were 953 B and 515 B, with the
revision marks nested inside a still-open `<w:t>` and the tail lost.

The rest of the stack was exercised on the published pins as well:

| Suite | Result |
| --- | --- |
| `smoke-deer-flow-outputs.ps1` | **PASS**, exit 0 - listing `200`, enrichment present, download `200` (62 bytes) |
| `e2e-audit.py` | **PASS**, exit 0 - 5/5 (`login`, `create_thread`, `upload_docx`, `auto_convert_md_present`, `converted_md_readable`) |
| `GET /pacgate/health` | `ok` |

### 6.5 The probe's own cleanup, verified by falsification

A probe that claims to clean up and does not is worse than one that never
claimed it, so the deletion path is tested rather than trusted. The signal is
the row count - assertions can pass while a leaked matter sits in the database.

| Case | Trigger | Result |
| --- | --- | --- |
| Happy path | normal run, cleanup at step 9b | `28/28`, exit 0, `matters 12 -> 12`, `documents 46 -> 46` |
| Abort before document | injected `raise` after the matter exists | exit 1; `matters 12 -> 12`, `documents 46 -> 46` |
| Abort after document | injected `raise` at step 9b, matter **and** document live | exit 1; `matters 12 -> 12`, `documents 46 -> 46` |

Both abort cases exit non-zero and still leave the database at its baseline, so
the `atexit` net covers the two orders that matter: matter-only, and
matter-plus-document. The net is idempotent - the happy path clears each id as
it deletes it, so the later `atexit` pass is a no-op.

This replaced a header line that asserted the probe "removes the matter and
documents it creates" while no DELETE call existed anywhere in the file. The
claim was false for the whole 0.1.26 and 0.1.27 validation runs; those runs left
their matters behind, which is why the cleanup baseline is not zero.

### 6.6 The residue those false claims left, and its removal

Fixing the claims does not remove what the old runs already wrote. A read of the
database before the purge found **12 matters / 46 documents**: the two legitimate
working matters (`Default Working Matter`, 1 doc; `Original Working Matter
(pre-reset)`, 21 docs) plus **10 orphan matter rows** carrying 24 documents
between them.

The three sweep gates that create matters - `test-legal-journey.ps1` (L424/L426),
`test-empty-extraction-gate.ps1` (L406/L408) and `test-text-native-sanitize.ps1`
(L823/L825) - all delete theirs, so the 10 orphans are not current sweep leaks.
They are residue from before L327's "cannot bind Headers" delete bug was fixed,
plus the two probes above. Recorded rather than assumed: it is worth knowing
which leaks are live and which are historic, because only the live ones need a
code fix.

Removal used an explicit name-pattern scope, not `DELETE FROM matters`:
`\u5c65\u7ea6\u6d4b\u8bd5` (the CJK probe's matter name), `probe-*`, `journey-*`,
`txtnative-*`, and `emptygate-<8hex>`. Dry run matched 10 of 12, leaving both
named working matters untouched. Applied: **12 matters / 46 documents -> 2 matters
/ 22 documents**, every delete returning 200, and **0 orphan document rows**
(a document row whose matter no longer exists). Documents were deleted before
their matter in every case, because `MatterStore::delete` has no cascade and
would otherwise have stranded the rows.

The purge is also what surfaced O23 - see below.

Deleting 10 matter rows with 24 documents removed the files and the rows, but
left **26 matter directories on disk against 2 live matters**, every one with 0
files. `delete_document_family` (`store.rs:307-334`) only calls
`std::fs::remove_file` for each version and then runs the SQL DELETE; nothing
calls `remove_dir_all`, and `ensure_docs_dir` (`store.rs:375`) creates the tree
without anyone owning its teardown. The matter route compounds it: a bare
`DELETE FROM matters` leaves the docs directories under it with no owner at all.
This is live behaviour, not historic residue - matter
`d695282b-8f0d-4b6d-b33f-7b20b39130e5` was created and deleted minutes earlier and
left its shell. Recorded as O23.

The empty shells turned out to be the visible half of a worse defect. `MatterStore::delete`
ran a bare `DELETE FROM matters`; `documents.matter_id` cascades, so the document ROWS
went while the FILES stayed on disk - unreachable copies of client documents inside a
directory whose matter no longer existed. The 26 directories were empty only because the
purge had deleted each document family first; a matter deleted with documents still
attached would have stranded the bytes too.

Fixed at the matter level, which is the only scope that is safe: `docs/` is shared by every
family in a matter (`ensure_docs_dir`, `store.rs:375-382`), so a per-family `remove_dir_all`
would delete a directory other families are still writing into. `MatterStore` now takes an
optional `data_dir` (`with_data_dir`) and removes the matter's whole tree after the DELETE
commits - commit-then-remove, so a failed DELETE cannot have already destroyed the bytes.
`MatterStore::new` is unchanged and stays database-only for callers with no filesystem
layout. Regression test `matter_delete_removes_the_directory_and_its_document_files`
asserts the directory and file exist BEFORE the delete, then that both are gone, that the
row is gone, and that a second delete is still `MatterNotFound`. Red-green verified: with
the cleanup block removed the test fails with `the matter directory survived the delete ...
this is the O23 orphan`; restored, it passes.

### 6.7 A doc claim the repo contradicted about itself

Closing out the open-findings table turned up a defect that no gate covers: four
documents described `pacgate-mcp` as exposing **10 MCP tools** while the live
bridge enumerates **19**. The AIPC handbook already published 19, so the repo
disagreed with itself - the same image was described two ways depending on which
file a reader happened to open.

Measured rather than inferred, because a tool count is exactly the kind of number
that drifts silently. `scripts/mcp-probe.py` against the running container lists
19, consistent with the `0.1.27` build-info revision the stack reports:

| Source | Claimed |
| --- | --- |
| `scripts/mcp-probe.py` (live, in-container) | **19** |
| `AIPC-DEPLOYMENT-HANDBOOK.md` / `-ZH.md` | 19 - already correct |
| `README.md` (L18, L85) | ~~10~~ -> 19 |
| `README-ZH.md` (L18, L87) | ~~10~~ -> 19 |
| `SETUP-AND-OPERATIONS.md` (L387) | ~~10~~ -> 19 |
| `SETUP-AND-OPERATIONS-ZH.md` (L384) | ~~10~~ -> 19 |

All six sites corrected with English/Chinese parity preserved. Dated records that
report the count as it was at their time of writing (`BENCHMARK-REPORT-2026-10-09-v0.1.25.md`
says 15, `AUDIT-E2E-2026-10-01.md` says 16) are historical evidence, not live
guidance, and are deliberately left alone.

**No gate caught this, and none should be expected to.** A doc claim about a
runtime count is not something a text-based gate can verify without becoming a
live-stack gate. The honest mitigation is the same one that found it: fold a
tool-count assertion into the MCP probe, which already runs against the live
stack. That is a proposal, not a change made here.

## 7. The fix, as shipped

Four source changes, all in this release.

1. **`pacgate-docx/src/diff.rs` - run-aware splice.** `replace_first_in_xml`
   now locates the enclosing `<w:r>`/`<w:t>`, closes the text node before the
   edit, emits the revision run as a peer, then reopens the tail run. A match
   that begins at the run's first character does not emit an empty `<w:t>`.
2. **`pacgate-docx/src/diff.rs` - unique revision ids.** `next_revision_id`
   scans existing `<w:del`/`<w:ins` (skipping `<w:delText`/`<w:delInstrText`)
   and returns `max+1`, so successive edits no longer collide on `w:id="1"`.
3. **`pacgate-docx/src/diff.rs` - accept-path flattener.**
   `flatten_nested_text_nodes` un-nests text nodes during `accept`. This matters
   for documents written by the **old** writer: they are already on client
   disks, and dropping the wrapper tags alone does not un-nest them, so accept
   would keep truncating them forever.
4. **`pacgate-api/src/text_extract.rs` - conditional seam separator.**
   `append_normalised` inserted a space between every pair of adjacent runs.
   In Chinese prose, where a paragraph is many runs, that injected a space at
   every seam. The separator is now emitted only when both sides of the seam
   are ASCII alphanumeric - the case where joining two tokens would change the
   meaning.

The seam change is deliberately narrow. `append_normalised` has three call
sites; two of them feed metadata lines that are trimmed and joined on newlines,
so they are strict no-ops. Only the DOCX body lane is affected.

## 8. Findings from this pass

Ordered by what would bite a client first.

### Fixed in 0.1.27

| # | Severity | Finding |
| --- | --- | --- |
| 1 | HIGH | Tracked edits spliced `<w:del>`/`<w:ins>` inside `<w:t>`, truncating Chinese paragraph tails. |
| 2 | HIGH | Documents already written by the old writer stayed nested after accept. Fixed by the flattener. |
| 3 | MEDIUM | A space was injected at every run seam, corrupting Chinese text. |
| 4 | MEDIUM | Revision ids were hardcoded to `1`/`2`, colliding across successive edits. |
| 5 | MEDIUM | The 0.1.26 image reported `version 0.1.25` - the workspace manifest was never bumped. Fixed by the 0.1.27 bump. |
| 6 | LOW | `diff.rs` had no test coverage at all. Now 11 tests. |
| 7 | MEDIUM | Both AIPC-DEPLOYMENT-HANDBOOK PDFs were stale, and the `client-delivery` copies shipped pre-0.1.27 content. The Chinese one had been stale since 0.1.23 without the mtime-based gate noticing. Re-rendered. See 10.2. |
| 8 | MEDIUM | `safe_markdown_to_pdf.py --sync-delivery` compared hashes after overwriting the target, so it could never refresh a copy and reported "different document revision" for every genuine copy pair. This is why defect 7 was never fixable by the tool. See 10.3. |
| 9 | MEDIUM | `test-version-marker.ps1` aborted before reporting a single assertion on Windows PowerShell 5.1: native stderr writes are terminating under `$ErrorActionPreference='Stop'`, including inside `finally`. Invisible on PowerShell 7. See 10.3. |
| 10 | LOW | `test-workflow-namespace.ps1` read its answer out of a whole output blob, so container noise could surface as a bogus NAMESPACE failure. See 10.4. |
| 11 | MEDIUM | `report-ghcr-digests.ps1` hardcoded the retired `pacgate-ai` mirror namespace, so every version tag returned 404 while `:latest` resolved to a 0.1.14-era build - the output still looked half-healthy. It also omitted `ocr-service` from the release set. See 10.6. |
| 12 | LOW | `identify-deerflow-image.ps1` defaulted to `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.10` - a mirror-only tag two releases old - so its fingerprint described an image no release produces. See 10.6. |
| 13 | MEDIUM | The namespace guard scanned only two hardcoded build scripts, so the digest script's wrong namespace could not be caught by the gate that exists to catch exactly that. Now a property scan. See 10.6. |
| 14 | LOW | The CJK probe's header claimed it "removes the matter and documents it creates" while the file contained no DELETE call at all. Every validation run through 0.1.27 leaked its matter. Cleanup is now real and the safety net is falsified in both abort orders. See 6.5. |
| 15 | LOW | `probe-format-lanes.py` caught every fixture failure per format and continued, so a missing `python-docx` printed "fixture FAILED", skipped the whole `.docx` lane, and the probe still exited 0. `ImportError` now exits 2. See 10.7. |
| 16 | LOW | `probe-format-lanes.py` deleted its matter only on the success path, so any early `die()` stranded the row - the origin of the orphan `probe-<id>` matters. Cleanup is now on `atexit` and falsified. See 10.7. |

### Open

| # | Severity | Finding |
| --- | --- | --- |
| O1 | HIGH | `DEFECT-initialize-bootstrap-token.md` - the `/initialize` guard is inert by default, and it **cannot be armed by config alone**. Proven this pass from the shipped bundle, not from source: the first-run wizard in the built frontend posts `{"email":...,"password":...}` with **no token field** (`fetch("/api/v1/auth/initialize",{method:"POST",...,body:JSON.stringify({email:v,password:b})})`, identical in all three chunks that carry it), and `grep -rl -i -e setup_token -e setuptoken -e PACGATE_SETUP /app/frontend/.next` returns **nothing**. So setting `PACGATE_SETUP_TOKEN` makes the wizard get 403 and the first admin can never be created through the UI - arming it alone is strictly worse than leaving it inert. Exposure window is narrow (fresh install, LAN, before an admin exists; the endpoint answers 409 once one does - verified live, `/api/v1/auth/setup-status` returns `{"needs_setup":false}`). Fix requires two coordinated changes: provision the token in both compose files and print it from `install.ps1`, **and** teach the wizard to send it, which means rebuilding the frontend image. Left open deliberately. |
| O2 | ~~HIGH~~ LOW | ~~`install.ps1` bootstraps `pacgate-api` only. It never provisions the deer-flow admin, so a fresh AIPC cannot use deer-flow until someone runs a manual `POST /api/v1/auth/initialize` with credentials matching `.env`.~~ **The second sentence was wrong and is retracted - see Retracted below.** What is true: `install.ps1` bootstraps `pacgate-api`'s admin (against Postgres, via the `/pacgate/` prefix) and leaves deer-flow's own admin to the upstream first-run wizard, which is present, reachable and self-driving: `/app/frontend/.next/server/app/(auth)/setup/page.js` is in the built image, `GET /api/v1/auth/setup-status` answers 200 on the live stack through both ports, `/setup` serves 200 through nginx, and the frontend redirects there on its own (`fetch("/api/v1/auth/setup-status").then(e=>e.json()).then(t=>{!e&&t.needs_setup&&d.push("/setup")})`). Residual gap is documentation only: `install.ps1`'s closing output lists `/`, `/api/` and `/research/` but never says the research lane starts with a one-time browser setup. Not worth fixing by pre-seeding - that would couple the installer to deer-flow's upstream SQLite schema (`/app/backend/.deer-flow/data/deerflow.db`, `SQLiteUserRepository`), which the `deer-flow-auth.py` patch already exists to avoid. |
| O3 | MEDIUM | The release path is a manual two-phase commit. The version bump and the image pins cannot land together, because a pin can only reference an image that already exists. `verify-delivery-state.ps1` is necessarily RED in between. Nothing enforces that phase 2 happens. |
| O4 | MEDIUM | Storage paths are double-nested. Root cause proven this pass: `compose.prod.yaml` sets `DATA_DIR: /data/tenants`, but `tenant_dir` (`pacgate-tenant/src/lib.rs:23`) and `rel_path` (`store.rs:360`) already prefix `tenants/`, so both sides agree and the result is `/data/tenants/tenants/<tenant>/...`. Self-consistent, so nothing breaks - but the fix requires migrating every existing client's directory tree, which is why it is left open rather than folded into a patch release. |
| O5 | MEDIUM | ~~`README-BUILD.md` still shows `ghcr.io/pacgate-ai/<image>` and `git push fork` in its Option A example.~~ **FIXED this pass - see 10.6.** The live-guidance sections now name `jzkk720`; the clearly-labelled "Historical / superseded" sections are left as record. |
| O6 | MEDIUM | ~~8 doc files still publish the 0.1.25 version table two releases later.~~ **FIXED this pass.** Re-measured before closing: `git grep -l 0.1.25 -- '*.md'` now returns **exactly two** files - this report, and `BENCHMARK-REPORT-2026-10-09-v0.1.25.md`, a dated record whose own filename carries the version. Zero live-guidance docs name 0.1.25. The same four files also described `pacgate-mcp` as exposing "10 MCP tools" against a live count of 19; corrected this pass - see 6.7. |
| O7 | MEDIUM | `test-pdf-freshness.ps1` section 1 compares mtimes, not content, so it cannot detect a content-stale PDF whose mtime is newer - which is how the Chinese handbook stayed stale for two releases. See 10.5. |
| O8 | LOW | `compose.prod.yaml:10-13` documents the `name: pacgate-ai-bundle` project pin with "Do NOT remove", but nothing enforces it. Composing with `-p` under a different name orphans the volumes. |
| O9 | LOW | No unique DB constraint on `(matter_id, name, version)`. |
| O10 | LOW | `store.rs::apply_edit` uses `doc.version + 1` while `apply_edit_to_family` uses `latest_version(...) + 1`. Editing a non-tip id can collide. |
| O11 | LOW | `diff.rs` hardcodes `word/document.xml`; `text_extract.rs` uses `declared_main_part()`. A DOCX with a nonstandard main part would be written and read through different paths. |
| O12 | LOW | `find_in_document` is agent-internal with no HTTP route or MCP tool, so it cannot be probed directly. |
| O13 | LOW | Workflow templates pass `queries` while the tool expects `query`. |
| O14 | LOW | `parser.rs` joins runs with no separator; `text_extract.rs` now joins conditionally. Divergent policies on the same file format. |
| O15 | LOW | `apply_tracked_edit` wraps errors with `.context("patch document.xml")`, which masks the inner cause in `err.to_string()`. Use `{err:#}` when debugging. |
| O16 | LOW | The `quick-xml` workspace dependency has zero use sites. |
| O17 | LOW | `/pacgate/version` does not exist; the revision marker is `/pacgate/build-info`. Worth an alias. |
| O18 | LOW | `smoke-deer-flow-outputs.ps1` cannot self-provision a thread. |
| O19 | LOW | The `X-CSRF-Token` requirement on gateway mutations is undocumented. |
| O20 | LOW | A stale legacy deer-flow store remains at `/data/data/deer-flow/` from before the bind mount. |
| O21 | LOW | `hermes-gateway` reports unhealthy; the `qm-*` services are up. Unclear whether these are in scope for "all pipelines". |
| O22 | LOW | ~~`DEPLOYMENT-GUIDE.md:191` publishes a `qm-pacgate:0.1.25` image that `build-ghcr.yml` does not produce.~~ **FIXED this pass.** The stanza is a deliberate record of an abandoned approach, but its `0.1.25` tag sat directly between two live `0.1.27` pins, so it read as a real pin. Now deliberately untagged. |
| O23 | LOW | ~~`delete_document_family` (`pacgate-docx/src/store.rs:307`) removes each version's file and its rows but never the containing directories, so every document family leaves a permanent empty `matters/<matter>/docs/` shell behind. Measured live: 26 matter directories on disk against 2 live matters, all 0 files. Compounded by the matter route having no cascade, so deleting a matter strands its docs' directories too.~~ **FIXED this pass.** The per-family half is cosmetic and was deliberately NOT changed: `docs/` is shared by every family in a matter (`ensure_docs_dir`, `store.rs:375-382`), so removing it per-family would delete a directory other families are still writing into. The real defect was the matter route, and it was worse than the empty shells suggested: `MatterStore::delete` ran a bare `DELETE FROM matters`, and `documents.matter_id` cascades, so the document ROWS went while the FILES stayed - unreachable copies of client documents inside a directory whose matter no longer existed. `MatterStore` now takes an optional `data_dir` (`with_data_dir`) and removes the matter's whole tree after the DELETE commits, in that order so a failed DELETE cannot have already destroyed the bytes. `MatterStore::new` is unchanged and stays database-only for callers with no filesystem layout. Regression test `matter_delete_removes_the_directory_and_its_document_files` asserts the directory and file exist BEFORE the delete, then that both are gone, that the row is gone, and that a second delete is still `MatterNotFound`. Red-green verified: with the cleanup block removed the test fails with `the matter directory survived the delete ... this is the O23 orphan`; restored, it passes. |

### Retracted

An earlier read of this session claimed that tag `v0.1.26` did not identify the
built revision. That was wrong - it came from a polluted shell read.

`git for-each-ref`, `git rev-list -n 1 v0.1.26` and `git ls-remote --tags`
all agree: annotated tag object `e0fa924` -> commit `9914b83`, which is exactly
the revision baked into the shipped image and its OCI
`org.opencontainers.image.revision` label. **The tag is correct.**

The only surviving observation is weaker: `PAC_SOURCE_REVISION` is set to
`${{ github.sha }}`, so the image records the **build commit** rather than the
tag name. For 0.1.26 those coincided.

Lesson recorded for next time: do not trust a single `git rev-parse` through
this shell - cross-check with `git for-each-ref`, `git rev-list -n 1` and
`git ls-remote`.


**O2's original framing - RETRACTED 2026-10-11.** The row asserted that "a fresh AIPC
cannot use deer-flow until someone runs a manual `POST /api/v1/auth/initialize`". That
is not what the shipped system does. Measured counter-evidence:

- deer-flow's users live in deer-flow's **own SQLite** store, not in `pacgate-api`'s
  Postgres. In the running container, `/app/backend/.deer-flow/data/deerflow.db` holds
  table `users` with the `admin@pacgate-law.com` row, written through
  `SQLiteUserRepository` via `get_local_provider()`. The installer's
  `/pacgate/api/auth/register` writes to Postgres - a different database.
- The upstream first-run wizard **is** in the built frontend:
  `/app/frontend/.next/server/app/(auth)/setup/page.js` exists, and the login page
  redirects to it by itself when `needs_setup` is true.
- It answers on the live stack: `GET /api/v1/auth/setup-status` -> 200
  `{"needs_setup":false}` on both `:8090` and `:8089`, and `/setup` -> 200 through nginx.
- So the browser wizard is the designed first-admin path for deer-flow, and it works.
  `AIPC-DEPLOYMENT-HANDBOOK.md:33-37` already documents it ("then re-run `/setup`").

`install.ps1` deliberately bootstraps **pacgate-api's** admin and leaves deer-flow's to
the wizard. The real, much smaller gap is that the installer's closing output never
mentions the one-time browser setup for the research lane. Downgraded to LOW, see O2
above.

## 9. Untouched behaviour verified

These are the properties the fix must not have broken, checked explicitly.

- A document **not** edited round-trips byte-exactly: 74 chars / 222 bytes.
- The Chinese filename and on-disk stem are preserved literally
  (`\u5408\u7ea6\u6d4b\u8bd5_v1.docx` ... `_v4.docx`).
- The anchored-context edit branch is CJK-safe.
- `pacgate-mcp` container file md5 equals the host
  `deploy/pacgate-mcp/server.py` - no drift.
- Zero char-boundary panics in any container log.
- Tracked edits are non-destructive until `/accept`: text marked deleted is
  still present in the file. This is deliberate, and it is why any "the find
  text is gone" assertion is only valid after accept.
- Every version-producing operation inserts a **new** document row with a new
  id. The original id keeps pointing at the original bytes. Version numbering
  is keyed on `(matter_id, doc.name)`.
- `/extract` and the agent's `find_matches` use different implementations
  (`text_extract::extract_text_native` vs `pacgate-docx`), so a probe of one
  does not cover the other.

## 10. Full local gate sweep

`scripts/run-all-checks.ps1` was run to completion on the fully-0.1.27 stack,
after the fixes below landed.

```
ALL 34 GATES PASSED (4 live-stack gate(s) checked separately)
```

Measurements from the same run: `audit-aipc-update-coverage.ps1` complete
(11 of 11 covered, 0 needing a human), `test-workflow-library-served.ps1` - no
open work. The four live-stack gates also passed: `test-empty-extraction-gate`
(15/15), `test-text-native-sanitize` (59/59), `smoke-full-stack` ("every
reachable lane passed"), `test-auth-provisioning-gate` (8/8).

Several suites sit outside that runner and were run by hand. Three pass and are
recorded in 10.6: `report-ghcr-digests.ps1` (exit 0, five images),
`probe-mcp-workflow-count.py` (in-container, exit 0, 222 workflows),
`test-legal-journey.ps1` (`full legal journey PASSED`, 19 assertions, exit 0).
`test-legal-journey.ps1`'s first failure is recorded there too: it was my
scratch compose copy's nested `workflows/workflows/` layout, not a repo defect.
The repo tree serves 222 workflows. Three further diagnostic probes are
recorded in 10.7, and all three pass.

### 10.1 What the first sweep found

The same sweep was run before these fixes and reported **36 pass / 4 fail out of
40**. The failures are the interesting part: three were real defects, one was a
known flake, and one of the three was hiding a second defect underneath it.

| Gate | What it actually was |
| --- | --- |
| `test-pdf-freshness.ps1` (+ `-mutations`) | **Real.** A client-facing document was stale - see 10.2. |
| `test-version-marker.ps1` | **Real, in the gate itself.** It crashed on Windows PowerShell 5.1 before reporting a single assertion - see 10.3. |
| `test-workflow-namespace.ps1` | **Known flake, now fixed.** 41/1 under load, 42/0 standalone - see 10.4. |

The suite runner prefers `pwsh` and falls back to `powershell`. The reason that
matters: this script hardcoded `pwsh` once and consequently "passed" 34 suites
it never ran, because each invocation failed with "command not found" and the
stale `$LASTEXITCODE` read as 0. Gate scripts must therefore be correct on both
editions, not just the one the author used.

### 10.2 The stale AIPC handbook PDFs (client-facing)

Both handbooks' markdown was bumped to 0.1.27 by the release, but their PDFs
were never re-rendered, so the `deploy/client-delivery/docs/` copies shipped
pre-0.1.27 content. The gate caught the English pair by mtime.

The Chinese PDF was worse, and the gate could **not** see it: it passed on
mtime while carrying 0.1.23-era content, because its last commit (`6b38de1`,
2026-10-06) predates three later edits to the markdown (`f950c09` and
`b3ba91e` for 0.1.25, `2565018` for 0.1.27). A content-based audit over all 22
tracked md/pdf pairs - `git log -1 --format=%ct` per file, comparing markdown
commit time against PDF commit time - confirms these two handbooks are the only
stale pairs; the other 20 are fine.

Both are now re-rendered, and both `client-delivery` copies refreshed.

### 10.3 Two defects in the tooling that was supposed to catch this

**`safe_markdown_to_pdf.py --sync-delivery` could never refresh a copy.** It
decided copy identity *after* `convert_markdown_to_pdf()` had already
overwritten the target, so `_sha256(target) == _sha256(delivery_copy)` was
unsatisfiable for a genuine copy pair: a fresh render carries a new random PDF
`/ID` and a new timestamp, so the bytes never match the copy. The flag always
reported "different document revision" and silently left the copy untouched.

This is why the stale handbooks had never been refreshable. Renders are **not
byte-deterministic**: two runs over identical markdown give the same length but
different SHA256, differing only in the `/ID` array and
`/CreationDate`+`/ModDate`. Any byte-identity check on a rendered PDF must
compare against a **pre-render** copy, never a fresh render - which is what the
fix does. Had this not been found, the handbook staleness would have recurred
at every release.

**`test-version-marker.ps1` aborted before reporting anything on PowerShell
5.1.** Windows PowerShell 5.1 promotes **any** native stderr write to a
**terminating** error while `$ErrorActionPreference` is `'Stop'` - even with
`2>&1 | Out-Null` or `2>$null`. PowerShell 7 does not. This script deliberately
probes things that fail at first (a Python traceback until the stub binds,
`nginx -t` warnings, and `wget -S`, which prints response headers to stderr),
and its `Cleanup` removes networks that may legitimately be absent. On 5.1 the
throw escaped from `finally`, so the run ended "0 passed, 1 failed" with an
unexplained `harness error: Traceback ...` instead of an assertion result.

`docker network rm <missing>` reproduces it; `docker rm -f <missing>` does not.
The fix adds an `Invoke-Native` helper that saves and restores
`$ErrorActionPreference`, forces `'Continue'`, and returns `{Exit, Text}`, then
routes every native call through it. Verified 6/6 exit 0 on **both** PowerShell
7.6.6 and 5.1.26100.9549, with no container or network left behind.

### 10.4 The namespace flake

`test-workflow-namespace.ps1` read its answer out of a whole output blob, so a
line of container-start noise could reach `$parts[0]` and surface as a bogus
NAMESPACE assertion failure - the same misleading signature already documented
in the script from 2026-10-03. The answer is now the last line shaped like the
script's five pipe-separated fields. Dropping noise cannot hide a real
regression: the probe always echoes the same five fields, so a logic break
still changes the values the assertions check.

Verified 42/0 exit 0 three times standalone, **and 42/0 inside the full sweep
under load** - which is precisely where it used to break.

### 10.5 Remaining gate weakness

`test-pdf-freshness.ps1` section 1 compares **mtimes**, not content, so it
cannot detect a content-stale PDF whose mtime is newer - exactly the Chinese
handbook's case, which passed while stale. Section 2 is stronger: it compares
`git ls-tree -r HEAD` blob SHAs, so a pair byte-identical at HEAD is "meant to
be identical" and any drift fails.

Promoting the content check into section 1 is a separate change; the ad-hoc
version used here is `git log -1 --format=%ct -- <path>` per file, comparing
markdown against PDF commit time.

### 10.6 The GHCR namespace drift - found by extending the sweep

Two suites outside `run-all-checks.ps1` disagreed about whether 0.1.27 was
published: `probe-mcp-workflow-count.py` failed with `ConnectError [WinError
10061]` and `report-ghcr-digests.ps1` reported `4 image(s) NOT pullable at
0.1.27` with **HTTP 404** on the version tag.

**Both were invocation artefacts, not release failures.**

`probe-mcp-workflow-count.py` binds `127.0.0.1:8000` and must run inside
`pacgate-mcp`; run from the host it cannot connect by construction. Re-run
in-container it passes: **222 workflows, 46 categories, 220 of 222 carrying
non-ASCII names** - independent confirmation that the UTF-8 workflow library is
being served, which is the client-locale property this release cares about.

`report-ghcr-digests.ps1` was a **real defect, in the tooling.** Line 45 built
its URL as `"$Repo = pacgate-ai/$img"` - the retired read-only mirror. The
mirror is **frozen at 0.1.14** and has received no push since the namespace
inversion in plan 016:

| namespace | 0.1.14 | 0.1.17 | 0.1.25 | 0.1.26 | 0.1.27 | latest |
| --- | --- | --- | --- | --- | --- | --- |
| `pacgate-ai` (mirror) | 200 | 404 | 404 | 404 | 404 | 200 |
| `jzkk720` (authority) | - | - | - | 200 | 200 | 200 |

That table is the trap: the mirror's `:latest` still resolves, to a stale
0.1.14-era build, so the script's output looked *half healthy* - `latest` rows
green, version rows 404 - instead of obviously broken. And **404 cannot be
distinguished** from "this tag was never built", which is why this read as a
failed release rather than a wrong URL.

The fix adds a `-Namespace` parameter and resolves `GHCR_NAMESPACE` from
`.github/workflows/build-ghcr.yml` with the same fallback and warning as
`deploy/build-images.ps1` - the build script had this identical defect fixed on
2026-09-18; the digest script was missed. It also adds the missing fifth image
(`ocr-service`) and `-UseBasicParsing`, without which `-Method Head` throws a
`NullReferenceException` on Windows PowerShell 5.1 and the `catch` printed a
**blank** status.

Verified on both hosts, `EXIT=0`:

```
=== GHCR state for 0.1.27 (namespace jzkk720) ===

  image                            0.1.27       latest       sync
  -------------------------------- ------------ ------------ ----
  pacgate-api                      sha256:cd9ca sha256:cd9ca yes
  pacgate-mcp                      sha256:79199 sha256:79199 yes
  ocr-service                      sha256:d67e8 sha256:d67e8 yes
  deer-flow-pacgate                sha256:9fbe5 sha256:9fbe5 yes
  deer-flow-frontend-pacgate       sha256:6f55b sha256:6f55b yes
```

**Why the gate did not catch it.** `test-workflow-namespace.ps1` - the gate that
exists to protect exactly this invariant - scanned a hardcoded list of two
scripts, `deploy/build-images.ps1` and `deploy/build-frontend.ps1`. Both were
correct; the digest script was simply not on the list. **A list can only catch
what someone remembered to add.** It is now a property scan: every `.ps1`,
`.psm1`, `.py` and `.sh` under `scripts/` and `deploy/`, comments stripped, with
`ghcr.io/v2/` removed first so the registry API path cannot masquerade as a
namespace.

Nine scripts match `ghcr.io/<ns>/` only as that API path - the segment after
`v2` is interpolated, so they are namespace-agnostic by construction and must be
excluded structurally rather than by allowlist. Two genuine offenders remained:

- `scripts/report-ghcr-digests.ps1` - fixed above.
- `scripts/identify-deerflow-image.ps1` - defaulted to
  `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.10`. Probed: `jzkk720/...:0.1.10`
  is 404 and `:0.1.27` is 200, while the mirror's `:0.1.10` is 200. The tool was
  fingerprinting a mirror-only image two releases old. It now resolves
  `ghcr.io/<GHCR_NAMESPACE>/deer-flow-pacgate:latest` at runtime; verified on
  both hosts, resolving and pulling `sha256:9fbe527...`.

`scripts/test-workflow-mutations.ps1` stays exempt: it holds the deliberate
mutation whose *anchor* had to be inverted when the authority moved, because
anchoring on the old value made the mutation unable to apply - and a mutation
that cannot apply is indistinguishable from a defect that cannot be detected.

Assertion count moves 42 -> 41 (two per-file namespace assertions become one
aggregate), verified **41 passed / 0 failed, exit 0** on PowerShell 7.6.6 and
Windows PowerShell 5.1.

The new assertion carries its own mutation, because this codebase's standard is
that an assertion nothing can fail is decoration. `test-workflow-mutations.ps1`
now rewrites a real default-image literal in `scripts/test-initialize-gate.ps1`
from `jzkk720` to `pacgate-ai` and requires the scan to go red by name. Result:
**11 passed / 0 failed** in the namespace section (was 10), and the suite exits 0.

> **Operational note - the mutation harness is not concurrency-safe.** Two
> mutation runs were started against the same working tree and clobbered each
> other: the harness mutates files **in place** and restores from a byte
> snapshot, with no lock. The result was a spurious `3 passed, 1 failed` on
> `restored files pass the full suite` - a green suite reported red because
> another process was mid-mutation. The serial re-run passed 4/4. Nothing was
> left mutated (verified: workflow, compose, `install.ps1` and
> `test-initialize-gate.ps1` all hold their correct values), but a failure from
> this harness should be re-run serially before it is believed.

Residual fragility worth naming: the exemption list is now one entry instead of
the two-file allowlist being the gap, but it is still a list. A future script
whose namespace is *intentionally* different needs an exemption, and each
exemption re-opens the original hole a little. The per-file diagnostic loop
still prints which file is which, so attribution survives the aggregate
assertion.

Also fixed in this pass: `deploy/README-BUILD.md` (O5) - the live-guidance
sections still instructed readers to expect `ghcr.io/pacgate-ai/<image>`, said
the GHCR owner override "resolves to the pinned `pacgate-ai` namespace", listed
four images rather than five, and gave a verification snippet against the
mirror at tag `0.1.3`. Those now name `jzkk720`, and the snippet documents that
the OCI `Accept` header is required and that `-UseBasicParsing` is required on
PowerShell 5.1. The sections explicitly headed "Historical / superseded" are
left untouched - they are the record of the model this one replaced, and
rewriting them would destroy the evidence of the inversion.

### 10.7 The three diagnostic probes outside the sweep

`run-all-checks.ps1` deliberately does not run these - each needs a live stack,
and one needs warm OCR weights. They were run by hand against the 0.1.27 stack
and all three pass.

| Probe | Result | Exit |
|---|---|---|
| `scripts\probe-format-lanes.py` | every supported format passes the sanitize gate | 0 |
| `scripts\test-ocr-extraction.ps1` | PNG is OCR'd with coordinates; `incomplete == false` | 0 |
| `scripts\mcp-probe.py` | MCP initializes and lists 19 tools | 0 |

**The format-lanes probe disproves a claim in an earlier report.** That report
asserted the sanitizer lane is "PDF only" and that `.docx`/`.txt` fail through a
"text path in `extract.rs`". The probe carries a mechanism, so the mechanism is
falsifiable, and it is false:

| Format | Upload | Extract | `incomplete` | Sanitize | Redactions |
|---|---|---|---|---|---|
| `.pdf` | 200 | 200 | `false` | 200 | 2 |
| `.docx` | 200 | 200 | `false` | 200 | 2 |
| `.txt` | 200 | 200 | `false` | 200 | 2 |
| `.md` | 200 | 200 | `false` | 200 | 2 |
| `.png` | **400** | - | - | - | - |

Only `.png` fails, and it fails at the **upload allowlist with an explicit 400**
naming the supported set - not silently, and not through any text path. There is
no PDF-only lane and no `extract.rs` defect here. The `pacgate_sanitize_text`
MCP wire path independently returns `pass` with 2 redactions.

This is the second belief in this file that a probe overturned by measuring
instead of inferring (the first being the tag-provenance finding, retracted in
§8). Both had a plausible mechanism and were wrong. The lesson is recorded
rather than the conclusion alone: **a mechanism attached to a claim is what
makes the claim testable - attach one, then run it before writing it down.**

The OCR gate builds its fixture PNG inside the container because Pillow is
there, and confirms `engine=paddleocr`, one span at `page=1`, and non-negative
span coordinates. `mcp-probe.py` must run **inside `pacgate-mcp`** - it binds
`127.0.0.1:8000`, which does not exist on the host. Its 19-tool list is the
current MCP surface; `probe-mcp-workflow-count.py` measures the workflow
library the same way on the same lane.

**A fourth probe left the sweep for a different reason.** `cjk-live-probe.py`
also needs a live stack, but unlike the three above it is the regression gate
for the release-blocking defect, so it is tracked in `scripts/` rather than
kept as a session artifact. It gained two assertions in this pass
(`cleanup_document_deleted`, `cleanup_matter_deleted`) - not to test the product
but to make its own claim about cleanup testable. Its cleanup path was then
falsified in both abort orders; see §6.5. A probe that adds an assertion about
its own side effects should also add a mutation that fails it, and here the
mutation was the leak itself.

**`probe-format-lanes.py` had the same defect, found by its own evidence.**
Its `api.delete(f"/api/matters/{matter_id}")` sat on the success path only, so
every early `die()` - unreachable stack, missing credentials, failed matter
create - exited 2 and stranded the matter. Orphan `probe-<id>` rows in the
database are that bug's fingerprint. Cleanup is now registered with `atexit`
and falsified the same way: an injected abort after matter creation exits 2 and
still returns the matter count to baseline.

## 11. How to re-run

```powershell
# from the repo root
cd pacgate-ai
cargo test -p pacgate-docx --lib
cargo test -p pacgate-api --lib

# stack
docker compose -f deploy\client-bundle\compose.prod.yaml up -d --force-recreate pacgate-api

# gates
pwsh -File .\deploy\client-bundle\smoke-deer-flow-outputs.ps1 -BaseUrl http://localhost:8090 -ThreadId <uuid>
python .\deploy\client-bundle\e2e-audit.py
pwsh -File .\scripts\verify-delivery-state.ps1

# gate coverage - run the mutation suites SERIALLY. They mutate files in place
# and restore from a snapshot with no lock, so two concurrent runs clobber each
# other and report a green suite as red.
pwsh -File .\scripts\test-workflow-namespace.ps1     # 41 assertions
pwsh -File .\scripts\test-workflow-mutations.ps1     # 11 + 4 + 4 mutations
pwsh -File .\scripts\report-ghcr-digests.ps1 -Version 0.1.27
```

Suites outside `run-all-checks.ps1`, all verified on the 0.1.27 stack:

```powershell
pwsh -File .\scripts\test-legal-journey.ps1           # 19 assertions
pwsh -File .\scripts\report-ghcr-digests.ps1          # 5 images, tag == latest
pwsh -File .\scripts\test-ocr-extraction.ps1          # OCR, needs Docker

# needs the repo venv plus `pip install requests python-docx` (python-docx is
# how every fixture builder in this repo makes a real .docx)
.\.venv\Scripts\python.exe .\scripts\probe-format-lanes.py

# these two must run INSIDE pacgate-mcp - they bind 127.0.0.1:8000 there, which
# does not exist on the host, so a host invocation fails with WinError 10061
docker cp scripts\mcp-probe.py pacgate-mcp:/tmp/
docker exec pacgate-mcp python3 /tmp/mcp-probe.py
docker cp scripts\probe-mcp-workflow-count.py pacgate-mcp:/tmp/
docker exec pacgate-mcp python3 /tmp/probe-mcp-workflow-count.py

# the CJK release gate - needs the live stack. Self-cleaning: it deletes the
# matter and document family it creates, including on an aborted run.
.\.venv\Scripts\python.exe .\scripts\cjk-live-probe.py    # 28 assertions
```

The CJK probe now lives in the repo at `scripts/cjk-live-probe.py` and cleans up
after itself. It is a release gate, not a shipped artifact, but it is tracked so
it cannot be lost to temp cleanup. It is deliberately **not** in
`run-all-checks.ps1`: it needs a live stack, and that suite's contract is that
every member runs with no stack up. The honest CI proposal is a separate job
that brings the compose file up and then runs the probe - see the residual gap
in `DEFECT-docx-tracked-edit-nesting.md`.
