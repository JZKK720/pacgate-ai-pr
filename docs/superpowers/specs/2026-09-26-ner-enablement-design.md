# NER enablement: windowed inference, distribution, and per-tier recall

**Status:** PROPOSED (2026-09-26)
**Supersedes:** plan 019 Part 3b Task 6 as written (see section 2)
**Depends on:** plan 017 (crate, DONE), plan 019 3a (ocr-service, DONE), plan 020 (sanitize jobs, DONE)
**Blocking:** client deployment to AIPC 1 and 2

---

## 1. The problem, measured

`pacgate-redact` can detect **five** identifier classes in production. `EntityType`
defines **fifteen**. Production runs `tier_one_detectors()`, which is a single
rule-based detector covering:

| Detected today (rules) | Not detected |
|---|---|
| `CnResidentId` 身份证 | `PersonName` 人名 |
| `Uscc` 统一社会信用代码 | `OrgName` 机构名 |
| `CnMobile` 手机号 | `Location` 地点 |
| `BankCard` 银行卡 | `Landline` 座机 |
| `Email` | `PostalAddress` 地址 |
| | `CaseNumber` 案号 |
| | `RegistrationNumber` 注册号 |
| | `BankAccount` 银行账户 |
| | `Credential` 凭据 |
| | `IpAddress` |

This is not a cosmetic gap, because of how the pipeline is built:

- `verify()` replays **the same detector set** that drove redaction
  (`pipeline.rs:1-5`, contractual stage order).
- A class with no detector cannot be found as **residue** by that replay either.
- So the verdict is `Pass`, and `Pass` is what marks the document `sanitized` and
  opens the egress gate.

The practical consequence: a contract containing party names, addresses and bank
account numbers currently sanitizes to a **`Pass` verdict with all of them
intact**, and is downloadable. The system looks like it is working.

This is the documented dangerous profile for a redactor (see
`/memories/repo/sanitizer-agent-research.md`): **high precision, low recall**. A
redactor that appears accurate is useless if it misses most of the identifiers.

### 1.1 What the NER model actually adds

The model is `shibing624/bert4ner-base-chinese` (Apache-2.0, pinned revision
`5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a`, verified 2026-09-26). Its label set is:

```
O, B-PER, I-PER, B-ORG, I-ORG, B-LOC, I-LOC, B-TIME, I-TIME
```

`ner.rs:40-42` maps PER -> `PersonName`, ORG -> `OrgName`, LOC -> `Location`.
`B-TIME`/`I-TIME` are deliberately unmapped (dates are out of scope by design,
client spec section 3 forbids shifting dates), so they add no `EntityType`.

**So NER closes three classes, not ten.** Coverage becomes **8 of 15**:

| | Count |
|---|---|
| `EntityType` variants | **15** |
| Detected by rules today | **5** |
| Added by NER (PER/ORG/LOC) | **3** |
| **Covered after workstreams 1-3** | **8** |
| Added by section 11 (Landline, IpAddress) | **2** |
| **Covered after step 1 as well** | **10** |
| Still uncovered after that | **5** |

Arithmetic: 15 - 5 - 3 = 7 uncovered after NER; 7 - 2 = 5 uncovered after
section 11. (An earlier draft said "six remain undetected" while listing seven;
the list was right and the total was wrong. Stating every count together is what
makes it checkable. A later draft said 11/15 by counting `CaseNumber` in step 1 -
see section 11.1, which was withdrawn.) Separately, section 10.5 fixes a *silent
miss inside* the five "detected" classes, so "5 detected" overstated real-world
recall before step 0.

The five that remain after both workstreams have **no detector source at all**:

`CaseNumber`, `BankAccount`, `RegistrationNumber`, `PostalAddress`, `Credential`

Their shape of work is measured in sections 11.1, 12 and 13, not estimated.

That split must be reported honestly to the client (section 8), because the client
spec section 9 requires a covered/uncovered formats and identifiers list.

## 2. The blocker that changes the plan: the 512-token wall

`ner.rs:224-231`:

```rust
if ids.len() > MAX_TOKENS + 2 {
    // Simple sliding window over the first window for now; full
    // windowed inference is a Task 7 follow-up (plan 019 T7 harness
    // measures recall, not throughput).
    return Err(RedactError::Internal(
        "document exceeds NER context window (512 tokens); windowed inference not yet wired".to_string(),
    ));
}
```

`pipeline.rs:68` propagates it:

```rust
candidates.extend(d.detect(text)?);
```

BERT's context is 512 tokens. For Chinese that is roughly **700-800 characters**,
about one page. So enabling NER as-is means **any document longer than about a page
cannot be sanitized at all** - not degraded, refused. The job fails with an internal
error.

**This is why windowed inference is workstream 1 and a precondition, not an
enhancement.** Enabling NER without it would trade a silent low-recall problem for
a loud total-failure problem on realistic documents, which is worse for the user
and no better for the client.

## 3. Workstream 1 - windowed inference (precondition)

### 3.1 What must be preserved

Offsets are subtle and currently correct. `ner.rs:284-308`:

- `encode_char_offsets` returns **CHAR** offsets (verified: CJK yields `(i, i+1)`).
- `Match` offsets are **BYTE** offsets.
- Conversion uses a char-index -> byte-index table built from **the whole text**.

Windowing must therefore not simply slice strings and concatenate results. Each
window needs its own char->byte table, plus the window's base offset applied.

### 3.2 Chunking rules

| Rule | Value | Why |
|---|---|---|
| Split unit | **characters, not bytes** | Chinese is 3 bytes/char; a byte split corrupts the string |
| Window size | 500 tokens | `512` minus `[CLS]`/`[SEP]` as today |
| Stride | overlapping, target ~50 token overlap | an entity straddling a boundary must appear whole in at least one window |
| Window start | never inside a character | char-boundary only |

### 3.3 Boundary handling - the part that must not fail open

Naive non-overlapping windows silently drop an entity split across the cut. That is
the same fail-open shape this workstream exists to remove, so:

- Spans are collected per window, translated to absolute byte offsets, then
  **deduplicated and merged**.
- Two spans of the same `EntityType` whose byte ranges **touch or overlap** are
  merged into one. This is what reassembles a name split across windows.
- The existing `Redactor` already rejects overlapping matches as a **fatal error**
  (plan 017 decision). So merge-before-replace is required, not optional.
- `verify()` runs the same windowed detector over the text, so a merged span is
  re-findable as residue. The matcher identity between detect and verify must hold
  across the windowing change, or verification loses its meaning.

### 3.4 Failure policy

- A window that fails to tokenise or predict: **fail the document** (do not skip
  it). Skipping a window means a region was never scanned, and the surrounding
  windows would still produce a `Pass`.
- Token counts stay bounded per window, so memory is bounded by window size, not
  document size.

### 3.5 Acceptance

- A synthetic document longer than one window containing a person name **in the
  middle** (not near an edge) is detected.
- A person name **straddling a window boundary** is detected as ONE span, not two
  fragments and not zero.
- A name appearing in the first and last window is detected in both.
- `verify()` on a sanitized long document finds no residue and returns `Pass`; on
  a long document with a name deliberately left in, returns `Block`.
- Offsets remain valid UTF-8 boundaries (a byte offset landing mid-character is a
  hard error today and must stay one).

## 4. Workstream 2 - model distribution

### 4.1 Decision: bake into the `pacgate-api` image

Approved 2026-09-26. Rationale: this is a client deployment where distribution
reliability outweighs image size, and the project already ships large images
(deer-flow, PaddleOCR 1.5 GB). The rejected alternative - download at install -
introduces a `huggingface.co` dependency on a client network, and its failure mode
is a machine that installs "successfully" and then runs Tier-1 only. That is
exactly the invisible degradation this design removes.

**Cost, stated plainly:** the `pacgate-api` image grows by ~388 MB, pulled by every
machine including ones that never sanitize.

### 4.2 Artifact

| File | Bytes | Verified |
|---|---|---|
| `config.json` | 1,133 | HEAD 200 at pinned sha |
| `model.safetensors` | 406,763,404 | HEAD 200 at pinned sha |
| `vocab.txt` | 109,540 | HEAD 200 at pinned sha |
| **Total** | **~388 MB** | |

Three files only - exactly what `NerDetector::load` requires (`ner.rs` MODEL_FILES).

### 4.3 Build

A dedicated stage, pinned by revision, failing the build on any problem:

```dockerfile
FROM debian:bookworm-slim AS ner-model
ARG NER_MODEL_REV=5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && mkdir -p /ner \
 && for f in config.json model.safetensors vocab.txt; do \
      curl -fsSL "https://huggingface.co/shibing624/bert4ner-base-chinese/resolve/${NER_MODEL_REV}/${f}" -o "/ner/${f}"; \
    done \
 && test -s /ner/model.safetensors \
 && test -s /ner/config.json \
 && test -s /ner/vocab.txt
```

then in the runtime stage:

```dockerfile
COPY --from=ner-model /ner /app/models/ner
```

`-fsSL` plus the three `test -s` assertions mean a failed or truncated download
**fails the build**, at release time, instead of becoming a runtime mystery on a
client machine. Pinning `NER_MODEL_REV` keeps the image reproducible and is the
same discipline we apply to the deer-flow base digest.

### 4.4 Wiring

Both compose files gain one line:

```yaml
PACGATE_NER_MODEL_DIR: /app/models/ner
```

No volume, no cross-container ordering, no runtime download. `model_overrides`
already flows this way, so the pattern is established.

## 5. Workstream 3 - per-tier recall harness

The client spec section 9 requires results reported **separately per layer**
(rules / local model / full chain / actual cloud boundary) - 不能相互替代. One
end-to-end pass figure does not satisfy it.

**CORRECTION (2026-09-26, found while writing the implementation plan):
this already exists.** `pacgate-ai/crates/pacgate-redact/tests/recall.rs`, 65 lines,
with exactly the required shape:

- `rule_layer_tier_one_recall` - Tier-1 fixtures via `tier_one_detectors()`, no
  model required.
- A model-layer row using `full_detectors(dir)` that **skips loudly** when
  `PACGATE_NER_MODEL_DIR` is unset or the directory is missing, so CI without the
  388 MB bundle stays green.
- Its own header cites the contract: "Per-tier recall reporting (spec section 9:
  不能相互替代)".

An earlier draft of this section described it as unbuilt (plan 019 Task 7). That
was wrong - plan 019 shipped more of 3b than the plan file's checkboxes indicate.
Recorded because the mistake points the other way from the usual one: the plan was
stale, not the code.

**So workstream 3 is not new construction; it is extension.** What remains:

- Add rule-layer rows for the step-1 classes (`CaseNumber`, `Landline`,
  `IpAddress`) once section 11 lands.
- Add the long-document and boundary-straddling fixtures from section 3.5, which
  are what would have caught the 512-token wall.
- Report the **counts** per layer rather than only asserting no-miss, so the
  numbers that go to the client come from the harness that proves them.

The harness remains the reason the 512-token wall is a finding worth recording: it
measures recall on realistic fixtures, whereas the existing unit tests assert
*load* success and *short-sentence* detection. A load-time check is not a run-time
check.

## 6. Fail-closed semantics

Current behaviour is already correct and is kept:

| State | Behaviour | Rationale |
|---|---|---|
| `PACGATE_NER_MODEL_DIR` unset | warn, run Tier-1 | keeps tests without weights green |
| set but model broken | **hard error**, job fails | an intended NER deployment must not silently degrade |
| window fails | **hard error** (new) | a region that was never scanned must not yield `Pass` |

The remaining hole is that nothing **forces** production to set the variable. Fix
with a gate (`scripts/test-ner-enabled.ps1`) asserting the shipped compose files
set `PACGATE_NER_MODEL_DIR`, so a client build cannot ship Tier-1-only silently.

## 7. Testing

| Test | Proves |
|---|---|
| Rust unit: window boundary | a straddling name is ONE span |
| Rust unit: offsets | char->byte translation correct with a window base offset |
| Rust unit: long document | >1 window with a mid-document name is detected |
| Rust unit: fail-closed | a failing window fails the document |
| Rust unit: CJK adjacency (step 0) | `手机13812345678` is caught, `ABC13812345678` is not |
| `tests/recall.rs` | per-tier recall, separate rows |
| `verify()` replay | sanitized output re-scans clean; deliberate residue returns `Block` |
| Live E2E | a real upload with a name sanitizes with the name redacted out |
| Gate: NER enabled | compose sets the variable |
| Gate: image contains weights | built image has all three files at `/app/models/ner` |

## 8. Honest limitations to report to the client

These must appear in the section 9 deliverables, not be implied away:

1. **Coverage is 11 of 15 classes** once section 11 lands with workstreams 1-3,
   not all. Rules cover 5; NER adds 3; section 11 adds 3. The four still
   uncovered are `BankAccount`, `RegistrationNumber`, `PostalAddress`,
   `Credential` - and section 10 requires the gate that counts them to agree with
   the enum.
2. **Weights are 388 MB in the API image** - a deployment constraint worth stating.
3. **Recall is measured, not promised.** The harness reports per-tier recall; the
   research baseline for Chinese PII NER is F1 ~0.76 (OpenMed-PII-Chinese), so
   0.95-class recall must not be claimed.
4. **Pseudonymized, not anonymized.** A restorable mapping is 去标识化, not
   匿名化 (client spec section 10). Never conflate them in client-facing copy.
5. **`B-TIME` is deliberately unmapped** - dates are not shifted, per spec
   section 3.

## 9. Sequencing

0. **Step 0: boundary recall fix + the Rust gate** (sections 10.5, 10.6) -
   repairs a silent miss in the four boundary-anchored classes we already report
   as covered, and adds the gate whose absence let it ship. Lands first because it
   is a defect in production, not a gap, and it is the only item whose omission
   can be mistaken for working behaviour.
1. **Windowed inference** (workstream 1) - precondition; without it NER refuses
   long documents.
2. **Recall harness** (workstream 3) - must exist before enabling, so the
   enablement is measured rather than assumed. (Extended, not built - see
   section 5's correction.)
3. **Step 1 detectors** (section 11) - `Landline`, `IpAddress`. Rule-shaped,
   cheap. Independent of NER, so it can land before or with it.
   (`CaseNumber` is **not** here - see section 11.1; it needs the section 12
   design pass first.)
4. **Distribution** (workstream 2) - image + compose wiring + gate.
5. **Enable and verify** - live E2E on the dev box, then release 0.1.19.
6. **AIPC 1, then AIPC 2** - with the recall numbers recorded per machine.

Steps 1-5 are all local and testable on this dev box. Nothing here needs a
client machine until step 6.

**Then, as separate work:** the overlap strategy (section 12) BEFORE
`BankAccount` / `RegistrationNumber` / `Credential`, and the sub-span plus
cross-chunk mechanisms (section 13.1) before `PostalAddress` and `Credential`.

## 10. Success criteria

- Every boundary-anchored class is caught when a CJK character is directly
  adjacent (`手机13812345678`), not only when separated by a space (step 0).
- A document longer than one BERT window sanitizes successfully, with a
  mid-document person name redacted.
- Per-tier recall is reported as separate rule-layer and model-layer rows.
- The published `pacgate-api` image contains all three model files and the API
  logs the full detector set at startup (no `Tier-1 rules only` warning).
- The five uncovered classes are stated in the client deliverables, with
  `BankAccount` named as the highest-value remaining follow-up, `CaseNumber`
  flagged as needing a context signal before it can be correct (section 11.1),
  and `Credential` flagged as needing cross-chunk design (section 13).
- A gate asserts the coverage counts in this document still match `EntityType`
  and the registered detector set, so the numbers reported to the client cannot
  drift from the code.
- `run-all-checks.ps1` remains green, with the new gates added (**including a
  Rust gate**, which did not previously exist - see section 10.6).

## 10.5. Step 0 - a recall hole in the five classes we already ship

Found 2026-09-26 while writing the step-1 plan, by probing the shipped detector
rather than reading it. **This precedes section 11**, because it is a defect in
production today, not a coverage gap.

Every Tier-1 candidate pattern is anchored with `\b`:

```rust
RE_CN_ID_CANDIDATE  \b\d{17}[\dXx]\b
RE_USCC_CANDIDATE   \b[0-9A-HJ-NPQRTUWXY]{18}\b
RE_MOBILE_CANDIDATE \b1[3-9]\d{9}\b
RE_DIGIT_RUN        \b\d{12,19}\b     (BankCard, via Luhn)
```

Rust's `regex` crate is Unicode-aware by default, so `\w` includes CJK. A CJK
character is therefore a *word* character, and **`\b` does not exist between a
CJK character and a digit**. Measured on this box with a throwaway Rust probe:

| input | matched |
|---|---|
| `手机 13812345678` (space) | `13812345678` |
| `手机13812345678` (no space) | **none** |
| `手机：13812345678` (full-width colon) | `13812345678` |
| `身份证 11010519491231002X` (space) | `11010519491231002X` |
| `身份证11010519491231002X` (no space) | **none** |
| `（11010519491231002X）` (brackets) | `11010519491231002X` |

All four boundary-anchored classes fail the same way: `CnResidentId`, `Uscc`,
`CnMobile`, `BankCard`. `Email` is unaffected (it has no `\b`).

**Why this is worse than the missing classes in section 1.** A missing class is
an acknowledged gap. This is a *silent* failure inside the classes we report as
covered, and it is the form a Chinese lawyer actually writes - `手机：138...`
with no space, in a table cell or after a label - because Chinese text does not
use inter-word spaces. Combined with section 1's replay property, the document
gets a `Pass` verdict with the mobile number intact.

**The fix is not `\b` -> `[^\w]`.** The correct predicate is "not flanked by an
*ASCII alphanumeric*", which accepts CJK/punctuation/whitespace adjacency while
still rejecting a longer token. Verified with the same probe:

| input | fix result | correct? |
|---|---|---|
| `手机13812345678` | matches | yes - was a miss |
| `手机13812345678号` | matches (trailing CJK) | yes |
| `ABC13812345678` | no match | yes - longer token |
| `138123456789` | no match | yes - 12 digits |
| `11010519491231002XX` | no match | yes - longer token |

**Also measured, and deliberately NOT in step 0:** Rust `\d` is Unicode-aware, so
it matches full-width digits U+FF10-FF19. Verified: `１３８１２３４５６７８` (full-width
mobile) does **not** match today, because the literal ASCII `1` in
`RE_MOBILE_CANDIDATE` anchors the match and the remainder is rejected by `[3-9]`.
So this is a **recall** gap, not the false-positive risk it resembles.

It is deferred rather than bundled, for a concrete reason: accepting full-width
digits means normalising the input, and every `Match` offset is a byte offset into
the *original* text. Normalising before matching shifts offsets and would break
redaction; normalising inside the validators means each candidate pattern must
carry both widths (`[1１]`, `[3-9３-９]`, ...), and `validate_cn_resident_id`,
`validate_uscc` and `validate_luhn` would each need a width-normalising entry
point. That is a design task with its own offset-preservation questions, not a
patch - and folding it into step 0 would obscure the adjacency fix, which is a
defect in shipped behaviour.

Trigger to pick it up: any measured full-width occurrence in the client corpus.
Until then it is recorded here rather than silently assumed absent.

**Scope note:** step 0 is a *detection* change, so it must land under the
`tests/recall.rs` harness (section 5) with adjacency fixtures, and it must not
regress the existing five classes' tests. Step 0 comes before section 11 because
it repairs shipped behaviour; section 11 adds new classes.

## 10.6. The reason none of this was caught: Rust tests are gated nowhere

Measured 2026-09-26. This is why step 0's defect survived, and why it must be
fixed alongside the detectors rather than after them.

| Check | Runs today? |
|---|---|
| `run-all-checks.ps1` gates | 21 PowerShell gates |
| Any gate invoking `cargo test` / `cargo clippy` | **none** |
| `bootstrap-integration-postgres.ps1:158` references `cargo` | yes, but it is not in the gate list and does not run the crate suite |
| CI (`build-ghcr.yml`) | build + push + manifest verify; **no `cargo test`, no `cargo clippy`** |

So every Rust assertion in this repository - the checksum validators, the recall
harness, the pipeline tests - is run only when a human types the command. The
PowerShell layer is genuinely gated; the Rust layer is not gated at all.

That is the structural reason a silent recall miss could sit in four shipped
detectors: **there was no mechanism whose job was to notice.**

**The gate to add**, as part of step 0:

```powershell
# scripts/test-rust-workspace.ps1
# Gates the Rust layer, which nothing previously did. Measured 2026-09-26:
# run-all-checks.ps1 is 21 PowerShell gates and CI runs no cargo command, so
# every Rust assertion in this repo ran only when a human typed it.
#
# Scoped to -D warnings for the crate this plan touches: the workspace has
# pre-existing clippy warnings (pacgate-core 1, pacgate-search 2,
# pacgate-agent 1, pacgate-api 3), so a workspace-wide -D warnings gate would be
# red on arrival and would be disabled within a week. pacgate-redact is clean
# today (verified), so this is a ratchet, not a new burden.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
if (-not (Test-Path $cargo)) {
    Write-Host '  exit 2 - cargo not found; cannot check' -ForegroundColor Yellow
    exit 2
}

& $cargo test -p pacgate-redact --all-targets
if ($LASTEXITCODE -ne 0) { Write-Host '  FAIL cargo test (pacgate-redact)' -ForegroundColor Red; exit 1 }

& $cargo clippy -p pacgate-redact --all-targets -- -D warnings
if ($LASTEXITCODE -ne 0) { Write-Host '  FAIL cargo clippy -D warnings (pacgate-redact)' -ForegroundColor Red; exit 1 }

Write-Host '  PASS pacgate-redact test + clippy' -ForegroundColor Green
exit 0
```

**Why `-p pacgate-redact` and not `--workspace`:** measured on this box, the
workspace currently emits 7 clippy warnings across `pacgate-core`, `pacgate-search`,
`pacgate-agent` and `pacgate-api`, while `pacgate-redact` alone is clean under
`-D warnings`. A gate that is red on arrival teaches people to ignore gates.
Widening it to `--workspace` is a separate cleanup task, deliberately not folded in
here.

**Note the exit-2 convention.** Per the established gate contract (`0` pass, `1`
real failure, `2` cannot check), a machine without cargo reports *cannot check*,
never a pass. And per the existing runner's warning, a gate that needs a running
stack belongs in `$liveStackGates`, not `$gates` - this one needs only cargo, so it
is safe in `$gates`.

## 11. Follow-up workstream - step 1: rule-shaped classes

Added 2026-09-26 after measuring what the seven uncovered classes actually take.

**AMENDED 2026-09-26, while writing the step-1 plan: `CaseNumber` was NOT
"nearly free" and has been moved out of step 1.** Section 11.1 below is retained
with its error marked, because the mistake is instructive. What step 1 actually
ships is two classes, not three. Coverage goes **8/15 -> 10/15**.

### 11.1 `CaseNumber` 案号 - WITHDRAWN from step 1 (was: "nearly free")

This section previously argued the work was "New regex + detector method + the
existing filter wired in". **That is wrong, and the existing filter is the
reason.** Measured with the real regex:

```python
RE_CITATION = r"[(（]\d{4}[)）][^\s]{1,12}?号"

is_public_case_number("参见(2023)京0105民初12345号判决", "(2023)京0105民初12345号") -> True
is_public_case_number("本案案号(2023)京0105民初12345号",   "(2023)京0105民初12345号") -> True
is_public_case_number("(2023)京0105民初12345号",           "(2023)京0105民初12345号") -> True
```

`is_public_case_number` is a pure *shape* test: it asks whether the text contains
a `RE_CITATION` match containing the candidate. If the detector's candidate
pattern **is** that shape - as this section proposed - then every candidate is
trivially contained in its own shape, and the function returns `True`
unconditionally. It is not a filter that would be "wired in"; it is a filter that
would **silently exempt the entire class it was meant to protect**.

Activating it as written would therefore produce a `CaseNumber` detector that
redacts nothing, which is worse than the current no-detector state: it would move
`CaseNumber` from the "not detected" column into the "detected" column while
detecting nothing - the exact failure mode section 1 is about.

**Both of the spec's taxonomy branches are required and neither is implemented:**
本案案号 (replace) and 公开参考案例案号 (preserve). Separating them needs a real
discrimination signal - whether the number appears in a case-reference context -
which is a label/context detector, not a shape match. That is genuinely new design
work.

**Deferred to section 12's design pass**, because it shares its shape: a conflict
resolution question (here, which branch wins) that must be settled before the
detector can be correct. Do NOT implement `CaseNumber` by reusing this filter.

### 11.2 `Landline` 座机 - trivial

`0` + area code + subscriber number, optionally hyphenated (`010-12345678`).
Chinese area codes are the 2-3 digit set (10, 21, 2x), subscriber 7-8 digits.

Candidate: `0\d{2,3}-?\d{7,8}`, plus the step-0 boundary predicate (section 10.5).

Measured, with the boundary predicate:

| input | result | correct? |
|---|---|---|
| `座机010-12345678` | matches | yes |
| `座机01012345678` | matches | yes |
| `座机0755-12345678` | matches | yes |
| `手机13812345678` | no match | yes - not a landline |
| `编号123456789012` | no match | yes - no leading 0 |
| `座机010-123456789` | no match | yes - subscriber too long |
| `A010-12345678` | no match | yes - ASCII-alnum flanked |

Two attributions in that table are worth stating, because both were wrong in an
earlier draft:

1. The mobile is rejected because the pattern starts with `0` and
   `1[3-9]\d{9}` starts with `1` - the patterns never collide. Measured:
   `138123456789` yields `landline=[]`, `digit_run=["138123456789"]`.
2. The over-long form is rejected by **`is_bounded`, not by the pattern shape.**
   Measured directly: `座机010-123456789` matches `010-12345678` in the regex
   alone, ending on the digit `9`; the predicate is what rejects it. **So the
   boundary predicate is load-bearing for `Landline` precision, not only for the
   CJK recall fix** - without it this detector would emit a truncated span,
   redact a prefix, and leave the remainder of the number visible. A truncated
   redaction is worse than a miss, because it looks sanitized.

Both detectors use `MatchSource::Pattern`. `MatchSource::Context` was considered
and rejected: the codebase defines it as "a pattern plus a label or surrounding
context" (`lib.rs:58-59`), whereas `Landline`'s `0` head is structural rather than
a label. `Pattern` is documented as "a regex pattern matched, but no checksum was
available", which is the honest description for both.

Note also: **every row above only behaves correctly if the boundary predicate is
in place.** `座机010-12345678` has a CJK character immediately before the `0`, so
with `\b`-based anchoring this detector would miss the common form and catch only
the space-separated one.

- Validation: the shape plus the boundary predicate. **No area-code table is
  needed** - `0\d{2,3}` already keeps this clear of the 11-digit mobile, measured
  above. An earlier draft said "area-code set membership"; that would be a table
  of ~350 codes guarding against a collision that measurement shows does not
  exist. The real guard is `is_bounded`.
- Policy: already `Tier::Two`, placeholder `LANDLINE`.
- Effort: **S**.

### 11.3 `IpAddress` - trivial, lowest priority

IPv4 octet-range validated.

Candidate: `\d{1,3}(?:\.\d{1,3}){3}`, validated by `str::parse::<Ipv4Addr>()`, plus
the boundary predicate and a **fifth-dot-group guard**.

Measured:

| input | result | correct? |
|---|---|---|
| `服务器192.168.1.1` | matches | yes |
| `访问10.0.0.1:8080` | matches | yes |
| `内网172.16.0.254` | matches | yes |
| `版本1.2.3.400` | no match | yes - octet > 255 |
| `日期2026.09.26` | no match | yes - only 3 groups |
| `地址1.2.3.4.5` | no match | yes - fifth group |
| `版本v1.2.3` | no match | yes - only 3 groups |
| `999.1.1.1` | no match | yes - octet > 255 |

Two implementation notes the probe established, so they are not rediscovered:

1. **Use `str::parse::<Ipv4Addr>()` for the octet check, not a hand-rolled one.**
   It also rejects leading zeros (`00.1.1.1` fails), which a hand-rolled
   `split('.').all(|p| p.parse::<u8>().is_ok())` would wrongly accept. `u8::parse`
   is strict here, so the standard library gives the stricter answer for free.
2. **The fifth-dot-group guard is required.** Without it, `1.2.3.4.5` matches the
   first four groups. Check `!text[end..].starts_with('.')`.

- Policy: already `Tier::Four`, placeholder `IP`.
- Effort: **S**. Lowest legal relevance of the seven; include because it is
  cheap, not because it is urgent.

### 11.4 Acceptance for step 1

- A landline with and without a hyphen is caught; a mobile and a 12-digit run are
  not misread as one. **Fixtures must include the CJK-adjacent form** (`座机010-...`)
  as well as the spaced form, because only the former proves step 0 landed.
- An IP is caught; `1.2.3.400`, `2026.09.26`, `1.2.3.4.5` and `v1.2.3` are not.
- The step-0 adjacency fix holds for all four existing boundary-anchored classes:
  `手机13812345678`, `身份证11010519491231002X`, `代码91350100M000100Y43`,
  `卡号4111111111111111` are each caught with no separating space.
- None of the changes regress the existing five classes' tests.
- The per-tier recall harness (section 5) gains rule-layer rows for both new
  classes and for the adjacency cases.
- `pacgate-redact` passes `cargo clippy -p pacgate-redact --all-targets -- -D warnings`
  (verified clean today, so this is a ratchet and not a new burden).

## 12. Follow-up workstream - step 2: the overlap strategy (a precondition)

`replace.rs:77` makes overlapping matches a **fatal error**:

```rust
if pair[0].overlaps(pair[1]) {
    return Err(RedactError::Internal(format!(
        "overlapping matches at [{}, {}) and [{}, {}) - run NoiseFilter first",
```

The client spec **requires** an overlap strategy - section 5 (L164):

> **处理重叠及长内容。**身份证与银行卡候选重叠、账号与金额混淆、凭证内部数字误识别、
> 跨行及跨分块私钥均应有明确策略。

That names four distinct cases, all of which our architecture currently turns
into a hard failure rather than a strategy:

| Spec case | Our situation |
|---|---|
| 身份证与银行卡候选重叠 | `RE_CN_ID_CANDIDATE` and `RE_DIGIT_RUN` can both fire on one run |
| 账号与金额混淆 | **arrives with `BankAccount`** - no checksum/length to separate them |
| 凭证内部数字误识别 | a key containing digit runs also matches `RE_DIGIT_RUN` |
| 跨行及跨分块私钥 | spans lines **and** chunk boundaries; policy is `Remove` |

**So this must be designed BEFORE `BankAccount`, `RegistrationNumber` or
`Credential` ship.** Adding those detectors without it can *break* sanitization on
realistic documents - a worse outcome than the current silent miss, because the
failure mode flips from "missed a class" to "cannot sanitize at all".

Same shape of blocker as the 512-token wall: a precondition discoverable only by
reasoning about real input rather than the happy path.

Design questions to settle (not answered here):
- Precedence when two classes claim the same span (身份证 vs 银行卡).
- Whether the loser is dropped, or both are merged into one redaction.
- How the verifier treats a span that was suppressed as a lower-priority
  duplicate - suppressing it must not let residue through.
- Whether overlap resolution belongs in `NoiseFilter` (where the invariant
  currently lives) or in `Redactor`.

## 13. Follow-up workstream - step 3: remaining classes

In priority order, with the reasons:

| class | approach | effort | why this order |
|---|---|---|---|
| `BankAccount` 收款账户 | label-anchored rule + NER assist | **M** | Highest severity remaining. **No checksum or fixed length** in Chinese account numbers, so a naked-digit match would eat amounts and dates (exactly 账号与金额混淆). Needs the step-2 overlap strategy first. |
| `PostalAddress` 地址 | rule + NER, **sub-span** | **M** | Spec L28 requires partial replacement - `对可定位部分进行替换` while KEEPING 国家/省市/法域 for jurisdiction analysis. Our `Match` is whole-span, so this needs a sub-span mechanism, not a detector. |
| `RegistrationNumber` 产权证/商标/专利号 | rule, per document family | **M** | Multiple unrelated formats (不动产权证号, 商标注册号, 专利号); each needs its own pattern. No single rule covers them. |
| `Credential` 密码/私钥/令牌 | pattern + entropy | **M-L** | PEM blocks are easy; generic tokens need entropy or provider-prefix heuristics. Spec L30 requires **removal** (policy already `Remove`), and L164 requires **cross-line AND cross-chunk** support - a design task, not a detector task. |

### 13.1 Two mechanisms we have no answer for at all

Beyond needing detectors, two spec requirements have no implementation:

1. **Sub-span replacement** (L28) - replace the locatable part of an address,
   keep the jurisdiction. `Match` carries a single whole span.
2. **Cross-line, cross-chunk spans** (L164) - a private key spanning lines and
   chunk boundaries. `Credential`'s `Remove` policy is incompatible with
   chunk-scoped processing until designed.

Both are design work, not pattern work, and both are already required by the
client spec rather than newly requested.

## 14. Explicitly out of scope

- Everything in sections 12 and 13 beyond `CaseNumber`, `Landline`, `IpAddress`.
- GPU acceleration. Candle CPU inference is the target; per-document cost is
  bounded by window count and should be measured in the harness output.
- Upstream deer-flow 2.1 (plan 023) - separate track, blocked on a tag that does
  not exist yet.
