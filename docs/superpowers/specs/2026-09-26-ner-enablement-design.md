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
| **Covered after this work** | **8** |
| **Still uncovered** | **7** |

Arithmetic: 15 - 5 - 3 = 7. (An earlier draft of this section said "six remain
undetected" while listing seven names; the list was right and the total was wrong.
Stating all five counts together is what makes that checkable.)

The seven remaining have **no detector source at all** - neither rule nor model:

`CaseNumber`, `RegistrationNumber`, `BankAccount`, `Credential`, `IpAddress`,
`Landline`, `PostalAddress`

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

`tests/recall.rs` (plan 019 Task 7, unbuilt) must assert, per tier:

- **Rules-only row:** every Tier-1 fixture is caught by `tier_one_detectors()`.
- **Model-layer row:** every Tier-2 fixture (person / org / location) is caught by
  `full_detectors(model_dir)` and **not** by rules alone.
- The two rows are **separate assertions**; one does not substitute the other.
- The harness skips cleanly when the model directory is absent, so CI without
  weights stays green.

**This harness is part of the fix, not an extra.** It measures recall on realistic
fixtures, which is precisely what would have caught the 512-token wall: the
existing tests assert *load* success and *short-sentence* detection, and a
load-time check is not a run-time check.

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
| `tests/recall.rs` | per-tier recall, separate rows |
| `verify()` replay | sanitized output re-scans clean; deliberate residue returns `Block` |
| Live E2E | a real upload with a name sanitizes with the name redacted out |
| Gate: NER enabled | compose sets the variable |
| Gate: image contains weights | built image has all three files at `/app/models/ner` |

## 8. Honest limitations to report to the client

These must appear in the section 9 deliverables, not be implied away:

1. **Coverage is 8 of 15 classes**, not all. Rules cover 5; NER adds 3
   (person, org, location). The seven listed in section 1.1 remain uncovered -
   and section 10 requires the gate that counts them to agree with the enum.
2. **Weights are 388 MB in the API image** - a deployment constraint worth stating.
3. **Recall is measured, not promised.** The harness reports per-tier recall; the
   research baseline for Chinese PII NER is F1 ~0.76 (OpenMed-PII-Chinese), so
   0.95-class recall must not be claimed.
4. **Pseudonymized, not anonymized.** A restorable mapping is 去标识化, not
   匿名化 (client spec section 10). Never conflate them in client-facing copy.
5. **`B-TIME` is deliberately unmapped** - dates are not shifted, per spec
   section 3.

## 9. Sequencing

1. **Windowed inference** (workstream 1) - precondition; without it NER refuses
   long documents.
2. **Recall harness** (workstream 3) - must exist before enabling, so the
   enablement is measured rather than assumed.
3. **Distribution** (workstream 2) - image + compose wiring + gate.
4. **Enable and verify** - live E2E on the dev box, then release 0.1.19.
5. **AIPC 1, then AIPC 2** - with the recall numbers recorded per machine.

Steps 1-3 are all local and testable on this dev box. Nothing here needs a
client machine until step 5.

## 10. Success criteria

- A document longer than one BERT window sanitizes successfully, with a
  mid-document person name redacted.
- Per-tier recall is reported as separate rule-layer and model-layer rows.
- The published `pacgate-api` image contains all three model files and the API
  logs the full detector set at startup (no `Tier-1 rules only` warning).
- The seven uncovered classes are stated in the client deliverables, with
  `CaseNumber` and `BankAccount` named as the highest-value follow-ups.
- A gate asserts the coverage counts in this document still match `EntityType`
  and the registered detector set, so the numbers reported to the client cannot
  drift from the code.
- `run-all-checks.ps1` remains green, with the two new gates added.

## 11. Explicitly out of scope

- Detectors for `CaseNumber`, `RegistrationNumber`, `BankAccount`, `Credential`,
  `IpAddress`, `Landline`, `PostalAddress`. These need their own design; two are
  strongly worth it (`CaseNumber` is high-signal and rule-shaped; `BankAccount` is
  high blast radius).
- GPU acceleration. Candle CPU inference is the target; per-document cost is
  bounded by window count and should be measured in the harness output.
- Upstream deer-flow 2.1 (plan 023) - separate track, blocked on a tag that does
  not exist yet.
