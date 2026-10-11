# DEFECT: tracked edits are spliced inside a `<w:t>` text node, truncating the rest of the paragraph

**Found:** 2026-10-09, during the 0.1.26 release validation (CJK end-to-end probe).
**Severity:** HIGH — silent data loss on any Chinese-language edit. Not an outage:
the request returns 200 and the response looks well-formed.
**Status:** FIXED in source, tested, and proven against a live stack. Ships in **0.1.27**.
**Blast radius:** every tracked edit (`PUT /api/documents/:id/edit`) whose document
already contains a run boundary before or after the matched text — which is
effectively every real DOCX. Worst on Chinese, Japanese and Korean prose.

## The symptom

Edit a Chinese contract, then read the result back. The API returns `200` and the
text you asked for is there — but **everything after the last tracked change is gone**:

| read-back | shipped 0.1.26 | fixed |
|---|---|---|
| edited version, chars | **28** (expected 74) | 74 |
| accepted version, chars | **18** (expected 76) | 76 |
| accepted version, bytes | **50** (expected 228) | 228 |

The missing text is the tail of the paragraph:

```
本合同项下的 顾问服务费 伍拾万元整            <- 28 chars, what 0.1.26 returns
本合同项下的 顾问服务费 为人民币 伍拾万元整 ，乙方应在收到发票后三十日内付清全部款项。
甲方应提供常年法律顾问支持，包含合同审查、合规咨询以及争议解决等事项。   <- 76 chars, correct
```

This is a **redaction-relevant** failure. A reviewer accepts a tracked change, is
shown a short paragraph, and signs off on a document whose real tail — the payment
term, the liability clause — was never displayed.

## Reproduction

Fixture: one paragraph, one `<w:r><w:t>`, two sequential edits
(`服务费用`→`顾问服务费`, `伍万元整`→`伍拾万元整`), then `POST /accept`.
No fixture-side trickery: the probe builds a deliberately single-run DOCX, which is
the *simplest* thing that fails.

### What 0.1.26 writes (`word/document.xml`, 953 bytes)

```xml
<w:p><w:r><w:t>本合同项下的<w:del w:id="1" ...><w:r><w:delText xml:space="preserve">服务费用</w:delText></w:r></w:del><w:ins w:id="2" ...><w:r><w:t xml:space="preserve">顾问服务费</w:t></w:r></w:ins>为人民币<w:del w:id="1" ...><w:r><w:delText xml:space="preserve">伍万元整</w:delText></w:r></w:del><w:ins w:id="2" ...><w:r><w:t xml:space="preserve">伍拾万元整</w:t></w:r></w:ins>，乙方应在收到发票后三十日内付清全部款项。甲方应提供常年法律顾问支持，包含合同审查、合规咨询以及争议解决等事项。</w:t></w:r></w:p>
```

Two things are wrong:

1. `<w:del>` and `<w:ins>` are **nested inside the still-open outer `<w:t>`**. In
   OOXML a revision mark is only valid as a **peer run of `<w:r>`, inside `<w:p>`**.
   This is well-formed *XML* and invalid *OOXML*.
2. Both edits reuse `w:id="1"` and `w:id="2"`. `w:id` identifies a revision **within
   the part**, so the second edit's marks collide with the first edit's.

### What 0.1.26 writes after `/accept` (515 bytes)

```xml
<w:p><w:r><w:t>本合同项下的<w:r><w:t xml:space="preserve">顾问服务费</w:t></w:r>为人民币<w:r><w:t xml:space="preserve">伍拾万元整</w:t></w:r>，乙方应在收到发票后三十日内付清全部款项。甲方应提供常年法律顾问支持，包含合同审查、合规咨询以及争议解决等事项。</w:t></w:r></w:p>
```

Accepting dropped the `<w:ins>` wrapper but left the inner `<w:r><w:t>` **still nested
inside the outer `<w:t>`**, so accept cannot repair a document the writer broke.

### What 0.1.27 writes (1039 bytes / 601 bytes accepted)

Marks are peers of `<w:r>`, ids are unique, and the accepted part is fully flat:

```xml
<w:p><w:r><w:t>本合同项下的</w:t></w:r><w:del w:id="1" ...><w:r><w:delText>服务费用</w:delText></w:r></w:del><w:ins w:id="2" ...><w:r><w:t>顾问服务费</w:t></w:r></w:ins><w:r><w:t xml:space="preserve">为人民币</w:t></w:r><w:del w:id="3" ...>...伍万元整...</w:del><w:ins w:id="4" ...>...伍拾万元整...</w:ins><w:r><w:t>，乙方应...</w:t></w:r></w:p>
```

## Root cause — a write-side bug that only shows up on the read side

### 1. The writer spliced into a text node

`crates/pacgate-docx/src/diff.rs`, `replace_first_in_xml`. The old implementation
located the match by byte offset and raw-spliced the revision markup in:

```rust
format!("{}{}{}", &xml[..start], revision_xml, &xml[end..])
```

It had **no awareness of the enclosing `<w:t>` or `<w:r>`**. Its own comment admitted
the scope: *"In production this should parse the XML properly; for now use string
replace."*

### 2. The reader stops at the first `<`

`crates/pacgate-api/src/text_extract.rs`, `extract_ooxml`. Read the text-node body to
the next `<`, then consume the matching `</w:t>`. Because the loop runs **once per
element name per part**, a nested `<w:t>` is visited twice — and on the first descent
the *outer* element terminator is consumed, so everything after the last nested run is
never read.

`crates/pacgate-docx/src/parser.rs` has the mirror-image behaviour: its char-wise
`strip_xml_tags` drops tags at any depth, so *it* returns the full paragraph. The two
readers disagree about the same bytes.

### Why Chinese is where it bites

A tracked edit splits one sentence into **head / marked / tail** runs. In English the
seam usually lands on a word boundary; in Chinese, a run boundary regularly falls
**mid-sentence**, so the surviving prefix is a fragment and the dropped tail is the
rest of the clause. Short ASCII fixtures hide it completely.

## The fix (three parts)

**1. `diff.rs` — write revision marks as peer runs.** `replace_first_in_xml` is now
run-aware. It finds the enclosing run (`enclosing_run` → `RunSpan { run_open, text_open,
text_open_end }`), closes the head run, emits the marks, and reopens a tail run:

```
<head runs>…</w:t></w:r>  <w:del>…</w:del><w:ins>…</w:ins>  <w:r><w:t xml:space="preserve">…tail…
```

If the match starts at the run's first character, no empty `<w:t/>` is emitted. A match
that **straddles a run boundary is refused with an error** rather than silently
corrupting the part — revision marks cannot span runs.

**2. `diff.rs` — allocate unique revision ids.** New `next_revision_id` scans existing
`<w:del`/`<w:ins` (skipping `<w:delText`/`<w:delInstrText`) and returns `max(id) + 1`;
`wrap_del`/`wrap_ins` now take an `id: u32`.

**3. `diff.rs` + `text_extract.rs` — repair and read correctly.**

- New `flatten_nested_text_nodes`, wired into `accept_document_xml`. Accepting a part
  written by the **old** writer now collapses `<w:t>x<w:r><w:t>y</w:t></w:r>z</w:t>`
  to `<w:t>xyz</w:t>`. A well-formed part is copied through byte-for-byte.
- `append_normalised` no longer inserts a space at **every** run seam. The separator is
  now conditional (`seam_needs_separator`): it is emitted only when the character on
  both sides of the seam is ASCII alphanumeric — the `11010519491231002` + `X` case the
  old unconditional space existed for. The space was never text the document contained,
  and injecting it into Chinese prose corrupts the sentence.

The reader change is a **strict no-op on both other call sites**: the `custom_properties`
lane joins on `\n` + `": "` and trims, and the `element_value_ci` lane feeds a single
chunk into an empty accumulator. Only the DOCX body lane is affected.

## Verification

| check | result |
|---|---|
| `cargo test -p pacgate-docx --lib` | **18 passed, 0 failed** (was 7; the module had **zero** tests) |
| `cargo test -p pacgate-api --lib` | **87 passed, 0 failed** (was 85) |
| live CJK probe, shipped 0.1.26 | **23 PASS / 3 FAIL**, exit 1 — reproduces |
| live CJK probe, fixed build | **26 PASS / 0 FAIL**, exit 0, `"failures": []` |
| `e2e-audit.py` on the fixed build | 5/5 PASS |
| `smoke-deer-flow-outputs.ps1` on the fixed build | PASS |
| panic scan across 4 containers | clean |

The three probe failures on 0.1.26 are `edited_tip_is_running_text`,
`edited_tip_context_preserved` and `accepted_text_is_exact`; all three are `ok: true`
on the fixed build, with `roundtrip_bytes_match: true` (228 bytes in, 228 bytes out).
The raw 953-byte and 515-byte parts above were dumped from the running 0.1.26 container.

## Why it was not caught

- **`diff.rs` had no tests at all** — no `mod tests`, no `#[test]`, in a 368-line
  module that performs byte surgery on OOXML. The 11 tests added here are the first.
- **Every existing DOCX fixture was ASCII**, so no test ever put a multi-byte character
  next to a run seam. `text_extract.rs` had a regression test
  (`adjacent_runs_do_not_fuse_into_one_token`) that pinned the *unconditional* space —
  the test was correct about the risk and wrong about the remedy.
- **The two read paths are independent.** `parser.rs` (char-wise, tag-dropping) returns
  the full paragraph for these bytes, so the bug is invisible to `pacgate-docx`'s own
  reader and to `/extract`.

## Residual gap — clients already on 0.1.26 or earlier

The writer fix only applies to **new** edits. Documents already written by 0.1.26 carry
nested runs on disk, and accepting one of them is exactly where `flatten_nested_text_nodes`
matters — that is the accept-path repair, and it also byte-verifiably leaves healthy
parts untouched. But:

- **No migration exists** for parts that were written broken *and* already accepted
  without the flattener. Those files have already lost their tail on disk; the bytes are
  gone and no reader change can recover them.
- **There is no CI gate that exercises a long agent run through deer-flow's MCP client.**
  This defect was found by an operator-authored probe, not by the pipeline.
- **`diff.rs` still hardcodes `word/document.xml`** while `text_extract.rs` resolves the
  declared main part. A DOCX whose main part is not `word/document.xml` would be read
  correctly and edited in the wrong place.

## Follow-ups (not part of this fix)

1. Add the CJK probe to CI as a release gate — it is the only check that caught this.
2. Refuse a tracked edit with a 4xx when the match straddles a run boundary, and say so
   in the response, instead of relying on the internal error string.
3. Drop the unused `quick-xml` dependency (`pacgate-ai/Cargo.toml:80`,
   `crates/pacgate-docx/Cargo.toml:12`) — it was declared for exactly the XML parsing
   this fix needed and never used.
4. `apply_tracked_edit` wraps the patch step with `.context("patch document.xml")`, which
   masks the inner error message. The tests here had to assert on `format!("{err:#}")`.
   Flatten it for real diagnostics.

## Files

- `pacgate-ai/crates/pacgate-docx/src/diff.rs` — writer fix, unique ids, `flatten_nested_text_nodes`, 11 tests
- `pacgate-ai/crates/pacgate-api/src/text_extract.rs` — conditional seam separator, 2 tests
