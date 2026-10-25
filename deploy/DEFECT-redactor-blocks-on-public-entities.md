# DEFECT (HIGH): the redactor blocked 5 of 13 firm documents on false positives

**Found:** 2026-10-24, while ingesting the firm's own material into "Firm Knowledge Base".

**Status:** FIXED. Three independent bugs, all in `pacgate-redact`.
Gated by 16 tests in `detect/noise.rs` and `detect/window.rs`.

## The observation

Ingesting 13 firm documents produced **5 blocks / 284 unsearchable chunks**.
Once the ledger started recording the residue (see
`DEFECT-block-verdict-has-no-reason.md`), every single survivor turned out to be
a **false positive**:

| residue | what it actually is |
|---|---|
| `国家网信办` | CAC - a government regulator |
| `华宇元典`, `华宇元典数`, `华宇元典数据库` | a legal database vendor |
| `欧洲`, `美国`, `中港`, `开曼`, `香港法院` | public geography and a court |
| `杰`, `证`, `欧`, `美` | single-character tokenizer fragments |

Not one was client identity. The redactor was refusing to release the firm's own
published methodology because it contained the word "Europe".

## Three independent root causes

### 1. No concept of a public entity

`NoiseFilter` suppressed overlapping spans and public case citations, and
nothing else. The NER model tags `国家网信办` as `B-ORG` and `欧洲` as `B-LOC`,
and both went straight into the redaction set.

`EntityType::Location` is Tier 3 ("quasi-identifiers"), which is right for a
street address and wrong for a continent. There was no way to express the
difference.

### 2. Single-character fragments were treated as identities

The tokenizer emits one CJK character at span edges, and the model labels that
lone character `B-ORG` or `B-LOC`. Measured survivors: `证`, `欧`, `美`.

Redacting one character of `欧洲` produces `[LOCATION]洲`, which is worse than
leaving it alone: the text is destroyed and nobody is protected.

### 3. The window planner overflowed its own token budget

This one is the most serious, because it made a document **permanently
unsanitizable**:

```
ner-zh: detector failed (internal error: window [829, 1339) produced 506
tokens, over the 500 limit - the planning bound was wrong, refusing rather
than truncating)
```

The message was right that the bound was wrong, but wrong about where.
`plan_windows` budgets `MAX_TOKENS` (500) for the **core** window.
`expand_with_overlap` then moves `start` backwards by `OVERLAP_CHARS` (64) and
**never shrinks `end`**. So the window that actually reaches the tokenizer is
`500 + 64 = 564` characters wide, while `detect_window` refuses anything over
`MAX_TOKENS + 2 = 502` tokens.

Any document whose windows land at the budget fails closed. And because
`verify` replays the same detector, no verdict can be `Pass` either - the
document can never be sanitized at all, by any path.

## The fix

### `detect/noise.rs`

- `PUBLIC_ENTITIES`: a suppression list of Chinese regulators, public bodies,
  arbitration commissions, legal-data vendors, countries, continents, provinces
  and offshore jurisdictions.
- `is_public_entity`: exact match after trimming, **except** vendors, which
  match by prefix because the model emits them with ragged tails
  (`华宇元典` / `华宇元典数` / `华宇元典数据库`).
- `drop_public_entities`: drops public entities, and drops single-character
  `PersonName` / `OrgName` / `Location` spans.

Applied in **both** places, which is the part that matters:

```rust
// pipeline.rs - redaction
matches = crate::detect::noise::drop_public_entities(text, matches);

// pipeline.rs - verification replay
crate::detect::noise::drop_public_entities(&redaction.text, ...)
```

If only the verifier suppressed them, the redactor would still remove a
regulator's name and the document would still block. Both sides must agree on
what is deliberate - the same rule `drop_public_citations` already followed.

### `detect/ner.rs`

```rust
let core = window::plan_windows(text, MAX_TOKENS - OVERLAP_CHARS, window::estimated_tokens);
```

Plan the core small enough that core + overlap fits the token ceiling.

### `detect/ner.rs` - real confidence, not a hardcoded 0.85

`flush` used to stamp every span with a literal `0.85` and **nothing downstream
ever read it**. The detector had no way to express doubt, so the only defence
against a bad guess was the public-entity list - which treats the symptom.

The detector now computes a softmax over the same logits (f32, row-max
subtracted for stability) and reports the **minimum** token probability across
each span. Minimum, not mean: a span is only as trustworthy as its weakest
token, and averaging would hide a confident `B-ORG` followed by a marginal
`I-ORG`.

`MIN_MODEL_CONFIDENCE = 0.60` in `noise.rs` consumes it. Only
`MatchSource::Model` spans are gated - a Luhn-valid card number is evidence, not
a guess, and is never suppressed by a model threshold.

## Why this is a suppression list, not a redaction list

The list can only ever **remove** a match, never add one. A private company name
or a street address is still redacted - asserted directly:

- `a_real_client_organisation_still_gets_redacted`
- `a_real_client_address_still_gets_redacted`
- `a_client_whose_name_starts_with_a_place_is_still_redacted`
  (`北京某某科技有限公司` must survive the `北京` entry)
- `a_two_character_name_is_still_redacted` (`张三`)

The exact-match rule is what makes this safe: a substring test would let `北京`
suppress `北京市朝阳区建国路88号`, which is a real address.

## Verification

| | before | after |
|---|---|---|
| documents sanitized | 8 / 13 | **13 / 13** |
| chunks searchable | 76 | **361** |
| blocked | 5 | **0** |

- `cargo test -p pacgate-redact`: 169 passed, 0 failed.
- `cargo test --workspace`: 42 suites, 0 failures.
- Verified live: rebuilt `pacgate-api:0.2.3` from this commit, recreated it
  through `compose.prod.yaml`, re-sanitized all 13 documents, all
  `verdict: pass`.
- Real PII still redacted, verified end-to-end with a probe document: a
  checksum-valid ID, a mobile number, an email and a person name were all
  replaced; the probe was then deleted.

## Residual risk

- **The suppression list is a judgement call, and it is finite.** A regulator or
  jurisdiction not on the list will still block. The list is the right shape
  (it can only suppress, never redact) but it will need additions. The ledger
  now records the residue, so the next gap is visible instead of silent.
- **The NER confidence gate is now real, but the threshold is a judgement.**
  `ner.rs` computes the per-token softmax probability and reports the WEAKEST
  token in each span; `MIN_MODEL_CONFIDENCE = 0.60` consumes it. Only
  `MatchSource::Model` spans are gated - a checksum-backed card number or a
  pattern-matched email carries its own evidence and is never suppressed by a
  model threshold. 0.60 was chosen from the measured distribution (the false
  positives were all marginal; genuine identities are long spans whose weakest
  token stays well above it), not from a labelled corpus. A future calibration
  run against real firm documents should revisit it.
- **The deployed image is now correct.** `pacgate-api:0.2.3` was rebuilt from
  this commit and recreated through `compose.prod.yaml`, so the fix survives
  `docker compose up`. The published GHCR tag still needs a CI run to match;
  until then a `docker pull` would overwrite the local tag.
- **A synthetic fixture ID is not redacted, and that is correct.** The OCR
  sample's `110105199003074512` has an invalid check digit (expected `6`, got
  `2`), so `validate_cn_resident_id` rejects it and the rule layer never fires.
  Pinned by `tests/id_checksum.rs`: a checksum-valid ID is redacted, an invalid
  one is not. This is pre-existing behaviour, not a regression from the
  confidence gate.
