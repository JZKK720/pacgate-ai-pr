# P2: Windowed NER Inference - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make NER work on documents longer than one BERT window instead of refusing them, so a document over roughly one page can be sanitized at all.

**Architecture:** The model call stays as it is. What changes is that the text is split into windows that each fit the 512-token context, inference runs per window, and the matches are merged. The splitting logic is extracted behind a `measure` closure so the whole algorithm is testable with no model weights — the current `ner.rs` has **zero** tests that run without the 388 MB bundle, which is why this wall was never caught.

**Tech Stack:** Rust (crate `pacgate-redact`). No new dependencies — `candle`, `tokenizers` and `regex` are already in the tree.

**Spec:** `docs/superpowers/specs/2026-09-26-ner-enablement-design.md` - this implements **workstream 1** (§4, §9 step 1). Read §6 (fail-closed semantics) and §7 (testing) before starting.

## Global Constraints

- **`cargo` is NOT on PATH.** Use `& "$env:USERPROFILE\.cargo\bin\cargo.exe"`. Run from `pacgate-ai/`.
- **Fail closed, and this is not negotiable.** Spec §6: a window that fails must fail the *document*, never be skipped. A region that was never scanned must not produce `Pass`. Do NOT add a "skip the bad window and continue" path, and do NOT catch a per-window error and continue.
- **Do NOT change the model, the head, or the tokenisation.** `NerDetector::load` and the classifier-head wiring (lines 195-205) are measured-working; this plan only changes how text is fed in.
- **Do NOT change `MAX_TOKENS = 500`.** It is 512 minus `[CLS]`/`[SEP]`. Changing it invalidates the measured bound.
- **Do NOT touch `safe_slice`.** It already handles non-char-boundary offsets by returning `""` rather than panicking, and it is load-bearing.
- **`Match` offsets are BYTE offsets into the ORIGINAL text.** Char offsets are only an internal stepping stone. Every conversion must go through a table built from the whole original text, never from a window, or offsets shift by the window base.
- **`pipeline.rs:68` propagates detector errors as fatal.** That is what makes fail-closed work. Do not soften it.
- **`tests/recall.rs` model-layer rows skip when `PACGATE_NER_MODEL_DIR` is unset.** That skip is contractual (spec §5). Do not turn it into a failure, and do not remove it.
- **Any new test must pass with the weights ABSENT.** That is the point of the `measure` closure. If a test needs the model, it belongs behind the existing skip.
- **Clippy must stay clean:** `cargo clippy -p pacgate-redact --all-targets -- -D warnings`. The gate at `scripts/test-rust-workspace.ps1` enforces this.
- **Line-based PowerShell execution mangles nested `$`.** Write any multi-line script to a file and run the file.

---

## The problem, measured

`ner.rs:224-231`, verbatim:

```rust
let ids: Vec<u32> = encoding.get_ids().to_vec();
if ids.len() > MAX_TOKENS + 2 {
    return Err(RedactError::Internal(
        "document exceeds NER context window (512 tokens); windowed inference not yet wired".to_string(),
    ));
}
```

Three consequences, and the second is the one that matters:

1. The tokenizer runs once on the **whole** text, so the length check is only possible after tokenising everything.
2. `pipeline.rs:68` propagates this error, so for any document over ~500 tokens **the entire sanitize job fails**. NER does not degrade to rules-only; it takes the job down. A one-page contract is enough to trigger it.
3. `verify()` replays the same detector set, so it hits the same wall — which means the failure is symmetric and the verdict can never be `Pass` either. The document simply cannot be sanitized.

**Why this was never caught:** every test in `ner.rs` either needs the weights (`fails_closed_when_model_dir_missing` asserts the *missing* case; the rest need a real directory) or an empty string. `tests/recall.rs` model-layer fixtures are two short sentences. Nothing in the suite ever passes a long document to the model, so **a load-time check was mistaken for a run-time check** (spec §5).

## Design

### D1 - the split must be measured, not assumed

A character budget cannot be converted into a token budget:

- CJK: roughly 1 token per character.
- ASCII words: WordPiece splits a long English word into several subword tokens, so a *fewer-characters* chunk can need *more* tokens.

So a fixed `max_chars` is wrong in one direction or the other. The split is done by **measuring**: tokenise, and if the result exceeds `MAX_TOKENS`, halve the segment and retry. This always converges and is correct for any script mix.

### D2 - a `measure` closure makes the algorithm testable without weights

The splitting logic takes `measure: impl Fn(&str) -> usize`. Production passes the real tokenizer's token count; tests pass a fake (character count, or a fixed function). This is the whole reason the wall survived: with the model baked in, the algorithm cannot be tested without 388 MB.

### D3 - overlap, then dedupe, so a straddling name is ONE span

A name crossing a window boundary is seen partially by one window and fully by another, and the model may tag the partial piece. Windows therefore overlap, and matches are merged: for the same entity, overlapping spans collapse to the longest. Spec §7 requires this as an explicit test.

### D4 - per-window failure fails the document

No `?`-swallowing, no `filter_map`, no "best effort". This is the same class of defect as the OOXML fail-open fixed in `324144c`: a `filter_map(...ok())` that silently dropped unreadable entries. Do not reintroduce that shape here.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-redact/src/detect/window.rs` | Pure window planning + cross-window match merging. No model, no tokenizer. | Create |
| `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs` | Module list | Modify (add `pub mod window;`) |
| `pacgate-ai/crates/pacgate-redact/src/detect/ner.rs` | Wire windowed inference; delete the hard error | Modify |
| `pacgate-ai/crates/pacgate-redact/tests/recall.rs` | Long-document and boundary-straddling rows | Modify |

`window.rs` is a separate file rather than more of `ner.rs` because it has no model dependency at all, and because it must be unit-testable on a machine without the weights. That is the design's point.

---

### Task 1: Pure window planning

**Files:**
- Create: `pacgate-ai/crates/pacgate-redact/src/detect/window.rs`
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/mod.rs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `pub struct Window { pub start: usize, pub end: usize }` - **CHAR** offsets, half-open.
  - `pub fn plan_windows<F>(text: &str, max_units: usize, measure: F) -> Vec<Window> where F: Fn(&str) -> usize` - non-overlapping core windows covering the whole text.
  - `pub fn expand_with_overlap(text: &str, windows: &[Window], overlap_chars: usize) -> Vec<Window>` - each core window extended backwards, clipped to the text.
  - `pub fn merge_matches(matches: Vec<Match>) -> Vec<Match>` - collapses overlapping same-entity spans to the longest, sorted by `(start, end)`.

- [ ] **Step 1: Write the failing test**

Create `window.rs` containing only the test module:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{EntityType, MatchSource};

    fn m(start: usize, end: usize, entity: EntityType) -> Match {
        Match {
            start,
            end,
            entity,
            text: String::new(),
            confidence: 0.85,
            source: MatchSource::Model,
        }
    }

    #[test]
    fn short_text_is_one_window_covering_everything() {
        let plan = plan_windows("张伟是代理人。", 500, |s| s.chars().count());
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].start, 0);
        assert_eq!(plan[0].end, 7);
    }

    #[test]
    fn long_text_splits_into_windows_each_within_the_budget() {
        let text: String = "张伟是本案的委托代理人。".repeat(200); // 2400 chars
        let plan = plan_windows(&text, 500, |s| s.chars().count());
        assert!(plan.len() > 1, "must split, got {} window(s)", plan.len());
        for w in &plan {
            let slice: String = text.chars().skip(w.start).take(w.end - w.start).collect();
            assert!(
                slice.chars().count() <= 500,
                "window [{}, {}) holds {} chars, over budget",
                w.start, w.end, slice.chars().count()
            );
        }
    }

    #[test]
    fn windows_cover_the_text_without_gaps_or_overlap() {
        let text: String = "甲乙丙丁戊己庚辛壬癸".repeat(300);
        let plan = plan_windows(&text, 100, |s| s.chars().count());
        assert_eq!(plan[0].start, 0, "first window starts at 0");
        assert_eq!(plan[plan.len() - 1].end, text.chars().count(), "last window ends at the end");
        for pair in plan.windows(2) {
            assert_eq!(pair[0].end, pair[1].start, "gap or overlap between core windows");
        }
    }

    #[test]
    fn a_measure_that_overestimates_still_converges() {
        // Every char costs 10 units: a 5000-char text needs ~10 windows.
        // Proves the split follows `measure`, not a hardcoded char count.
        let text: String = "x".repeat(5000);
        let plan = plan_windows(&text, 500, |s| s.chars().count() * 10);
        assert!(plan.len() >= 10, "expected >=10 windows, got {}", plan.len());
        for w in &plan {
            assert!((w.end - w.start) * 10 <= 500);
        }
    }

    #[test]
    fn a_single_character_over_budget_is_emitted_rather_than_looping_forever() {
        // A measure that never fits cannot be satisfied by splitting a 1-char
        // segment, so the segment must be emitted or this recurses forever.
        let plan = plan_windows("ab", 1, |_| 999);
        assert!(plan.len() >= 2, "one char per window when nothing fits");
        let covered: usize = plan.iter().map(|w| w.end - w.start).sum();
        assert_eq!(covered, 2, "every character must appear in exactly one window");
    }

    #[test]
    fn empty_text_plans_no_windows() {
        assert!(plan_windows("", 500, |s| s.chars().count()).is_empty());
    }

    #[test]
    fn overlap_extends_starts_backwards_and_clips_at_zero() {
        let text: String = "a".repeat(100);
        let core = vec![Window { start: 0, end: 50 }, Window { start: 50, end: 100 }];
        let out = expand_with_overlap(&text, &core, 10);
        assert_eq!(out[0].start, 0, "first window clips at 0, never underflows");
        assert_eq!(out[0].end, 50);
        assert_eq!(out[1].start, 40, "second window reaches back into the first");
        assert_eq!(out[1].end, 100);
    }

    #[test]
    fn merge_collapses_a_straddling_span_to_the_longest_one() {
        // The same person, seen partially by one window and fully by the next.
        let merged = merge_matches(vec![
            m(10, 14, EntityType::PersonName),
            m(10, 18, EntityType::PersonName),
        ]);
        assert_eq!(merged.len(), 1, "a straddling name must be ONE span");
        assert_eq!((merged[0].start, merged[0].end), (10, 18), "the longest span wins");
    }

    #[test]
    fn merge_keeps_different_entities_that_overlap() {
        // A person name inside an organisation name is not a duplicate.
        let merged = merge_matches(vec![
            m(0, 20, EntityType::OrgName),
            m(4, 10, EntityType::PersonName),
        ]);
        assert_eq!(merged.len(), 2, "different entities must both survive");
    }

    #[test]
    fn merge_leaves_disjoint_matches_alone_and_sorts_them() {
        let merged = merge_matches(vec![
            m(50, 54, EntityType::PersonName),
            m(0, 4, EntityType::PersonName),
        ]);
        assert_eq!(merged.len(), 2);
        assert!(merged[0].start < merged[1].start, "output must be sorted");
    }

    #[test]
    fn merge_is_idempotent() {
        let once = merge_matches(vec![
            m(10, 14, EntityType::PersonName),
            m(10, 18, EntityType::PersonName),
            m(30, 34, EntityType::Location),
        ]);
        let twice = merge_matches(once.clone());
        assert_eq!(once, twice, "merging twice must change nothing");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib window 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find function 'plan_windows' in this scope`. Note this is a new module: without `pub mod window;` in `detect/mod.rs` the file is not compiled at all and you get no test output, not a failure.

- [ ] **Step 3: Implement**

Add above the test module in `window.rs`, and add `pub mod window;` to `detect/mod.rs`:

```rust
//! Window planning for long-document NER, with no model dependency.
//!
//! The split is driven by a `measure` closure rather than a character count,
//! because characters do not convert to BERT tokens at a fixed rate: CJK is
//! roughly 1 token per character, while a long ASCII word splits into several
//! WordPiece subwords. A fixed character budget is therefore wrong in one
//! direction or the other depending on the script mix.
//!
//! Taking `measure` as a parameter is also what makes this testable without the
//! 388 MB model bundle. `ner.rs` has no test that runs without the weights,
//! which is why the 512-token wall went unnoticed until a document was actually
//! fed to it.

use crate::{EntityType, Match};

/// A half-open CHAR range `[start, end)` into the original text.
///
/// Char offsets, not bytes: splitting must never land mid-character, and the
/// caller converts to bytes once, against the whole original text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Window {
    pub start: usize,
    pub end: usize,
}

impl Window {
    fn len(&self) -> usize {
        self.end.saturating_sub(self.start)
    }
}

/// Split `text` into windows that each satisfy `measure <= max_units`.
///
/// Bisection rather than a fixed stride: a segment that does not fit is halved
/// and retried, so the result is correct for any `measure` that is
/// non-increasing as the slice shrinks. A single character that still does not
/// fit is emitted as its own window - there is nothing left to split, and
/// recursing would not terminate.
pub fn plan_windows<F>(text: &str, max_units: usize, measure: F) -> Vec<Window>
where
    F: Fn(&str) -> usize,
{
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }

    let mut windows: Vec<Window> = Vec::new();
    // Explicit stack of char ranges still to be resolved, so a pathological
    // input cannot blow the call stack.
    let mut pending: Vec<(usize, usize)> = vec![(0, chars.len())];

    while let Some((start, end)) = pending.pop() {
        let len = end - start;
        if len == 0 {
            continue;
        }

        let slice: String = chars[start..end].iter().collect();
        if measure(&slice) <= max_units || len == 1 {
            windows.push(Window { start, end });
            continue;
        }

        let mid = start + len / 2;
        // Push the RIGHT half first so the LEFT half is popped first, which
        // keeps the output in ascending order without a sort.
        pending.push((mid, end));
        pending.push((start, mid));
    }

    windows.sort_by_key(|w| w.start);
    windows
}

/// Extend each window's start backwards by `overlap_chars`, clipped to 0.
///
/// A name straddling a boundary is seen partially by one window and fully by
/// the next. The overlap gives the following window the whole name so the model
/// can tag it properly; `merge_matches` then collapses the duplicate.
pub fn expand_with_overlap(text: &str, windows: &[Window], overlap_chars: usize) -> Vec<Window> {
    let total = text.chars().count();
    windows
        .iter()
        .map(|w| Window {
            start: w.start.saturating_sub(overlap_chars),
            end: w.end.min(total),
        })
        .collect()
}

/// Collapse overlapping spans of the SAME entity to the longest, then sort.
///
/// Overlapping spans of *different* entities are both kept: a person name
/// inside an organisation name is two findings, not a duplicate.
///
/// Idempotent, so a caller that merges per-window and then across windows
/// cannot corrupt the result.
pub fn merge_matches(matches: Vec<Match>) -> Vec<Match> {
    // Longest first, so the survivor of each overlapping group is chosen before
    // its shorter duplicates are considered. Ties break on the earlier start,
    // then on the entity code, so the outcome is deterministic regardless of the
    // order windows happened to produce matches in.
    let mut ordered = matches;
    ordered.sort_by(|a, b| {
        b.len()
            .cmp(&a.len())
            .then(a.start.cmp(&b.start))
            .then(a.entity.code().cmp(b.entity.code()))
    });

    let mut kept: Vec<Match> = Vec::with_capacity(ordered.len());
    for candidate in ordered {
        let duplicate = kept
            .iter()
            .any(|k| k.entity == candidate.entity && k.overlaps(&candidate));
        if !duplicate {
            kept.push(candidate);
        }
    }

    kept.sort_by_key(|m| (m.start, m.end, m.entity.code()));
    kept
}

/// Unused-import guard: `EntityType` is referenced by the tests and by callers
/// of `merge_matches`; keep the import honest for the compiler.
#[allow(dead_code)]
fn _entity_type_is_used(e: EntityType) -> EntityType {
    e
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib window 2>&1 | Out-String
```

Expected: `test result: ok. 11 passed`.

If `a_single_character_over_budget_is_emitted_rather_than_looping_forever` hangs, the `len == 1` guard is missing or `mid` can equal `start`.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/window.rs pacgate-ai/crates/pacgate-redact/src/detect/mod.rs
git commit -m "feat(redact): pure window planning for long-document NER

Splitting is driven by a measure closure, not a character budget, because
characters do not convert to BERT tokens at a fixed rate - CJK is roughly 1
token per character while a long ASCII word splits into several subwords, so a
fixed budget is wrong in one direction or the other.

The closure is also what makes this testable without the 388MB model bundle.
ner.rs has no test that runs without the weights, which is why the 512-token
wall went unnoticed."
```

---

### Task 2: Wire windowed inference into the detector

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/ner.rs:210-370` (the `detect` body)

**Interfaces:**
- Consumes: `plan_windows`, `expand_with_overlap`, `merge_matches` (Task 1).
- Produces: `NerDetector::detect` no longer errors on long input. Same signature, same return type.

**Read this before editing.** The existing body does, in order: tokenise whole text, length check, build tensors, forward, head, argmax, char->byte table, BIO decode, flush. Only the outer structure changes. Extract the existing per-window work into a private method and call it per window, so the tensor/head/BIO code is **moved, not rewritten**. If the tensor code has to change shape to fit, stop and report `DONE_WITH_CONCERNS` rather than improvising: it is measured-working against a pinned checkpoint.

- [ ] **Step 1: Write the failing test**

Add to `ner.rs`'s `mod tests`. This must pass with the weights absent, so it tests the *plan* the detector would use, not the model:

```rust
    /// The wall this plan removes: a document longer than one window must be
    /// split, not refused. `MAX_TOKENS` is 500, so a 1200-token document needs
    /// at least 3 windows.
    ///
    /// Runs without the weights: it asserts the split, not model output.
    #[test]
    fn a_long_document_is_split_rather_than_refused() {
        let text: String = "张伟是本案的委托代理人。".repeat(200);
        let units = |s: &str| super::super::window::estimated_tokens(s);
        let plan = super::super::window::plan_windows(&text, MAX_TOKENS, units);
        assert!(
            plan.len() >= 2,
            "a 2400-char CJK document must need more than one window, got {}",
            plan.len()
        );
        for w in &plan {
            let slice: String = text.chars().skip(w.start).take(w.end - w.start).collect();
            assert!(
                super::super::window::estimated_tokens(&slice) <= MAX_TOKENS,
                "window [{}, {}) exceeds the token budget",
                w.start,
                w.end
            );
        }
    }

    /// Every window boundary must fall on a char boundary, or the byte
    /// conversion downstream slices a CJK character in half.
    #[test]
    fn window_boundaries_are_char_boundaries_in_bytes() {
        let text: String = "华信律师事务所位于北京市朝阳区。".repeat(100);
        let units = |s: &str| super::super::window::estimated_tokens(s);
        let plan = super::super::window::plan_windows(&text, MAX_TOKENS, units);
        for w in &plan {
            let byte_start: usize = text.chars().take(w.start).map(|c| c.len_utf8()).sum();
            let byte_end: usize = text.chars().take(w.end).map(|c| c.len_utf8()).sum();
            assert!(text.is_char_boundary(byte_start), "start of window {w:?} splits a character");
            assert!(text.is_char_boundary(byte_end), "end of window {w:?} splits a character");
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib a_long_document_is_split 2>&1 | Out-String
```

Expected: FAIL to compile - `cannot find function 'estimated_tokens' in module 'super::super::window'`. Add it in Step 3.

- [ ] **Step 3: Implement**

First add to `window.rs`, so the tests have a real measure to call (a CJK-aware *estimate*, deliberately conservative, used only by tests and as a safety bound — production measures with the real tokenizer):

```rust
/// A conservative token-count ESTIMATE for planning and for tests.
///
/// Deliberately an over-estimate: one token per character is the worst case for
/// CJK, and for ASCII it over-counts rather than under-counts because a WordPiece
/// word can split into several tokens. Over-estimating splits into more windows
/// than strictly necessary, which is safe; under-estimating would produce an
/// over-long window that the model then rejects.
///
/// Production still MEASURES with the real tokenizer before inference - this is
/// a plan bound, not a substitute for the check.
pub fn estimated_tokens(text: &str) -> usize {
    text.chars().count()
}
```

Then restructure `NerDetector::detect`. Replace the whole-text tokenise + hard error with: plan windows, expand with overlap, run the existing per-window logic on each, merge. The exact body:

```rust
    fn detect(&self, text: &str) -> RedactResult<Vec<Match>> {
        if text.is_empty() {
            return Ok(Vec::new());
        }

        // Split before tokenising. The previous code tokenised the whole text
        // first and only then found it did not fit, which meant every long
        // document failed the whole job at pipeline.rs:68 - NER did not degrade
        // to rules-only, it took the document down.
        let core = window::plan_windows(text, MAX_TOKENS, window::estimated_tokens);
        let windows = window::expand_with_overlap(text, &core, OVERLAP_CHARS);

        let mut all: Vec<Match> = Vec::new();
        for w in &windows {
            // Fail closed: a failing window fails the DOCUMENT. No `if let Ok`,
            // no `filter_map`, no best-effort. A region that was never scanned
            // must not produce a Pass verdict.
            let found = self.detect_window(text, *w)?;
            all.extend(found);
        }

        Ok(window::merge_matches(all))
    }
```

And the extracted per-window method, which is the **existing** body with three changes marked. `detect_window` takes the window's char range and returns matches with BYTE offsets into the whole `text`:

```rust
    /// Run the model over one window of `text` and return matches whose offsets
    /// are BYTE offsets into the WHOLE `text`.
    ///
    /// Extracted from the previous single-shot `detect` body. The tensor, head,
    /// argmax and BIO-decode code is unchanged; only the slice it operates on
    /// and the offset conversion are new.
    fn detect_window(&self, text: &str, w: window::Window) -> RedactResult<Vec<Match>> {
        // CHANGE 1: operate on the window, not the whole text.
        let slice: String = text
            .chars()
            .skip(w.start)
            .take(w.end - w.start)
            .collect();
        if slice.is_empty() {
            return Ok(Vec::new());
        }

        // add_special_tokens=true is REQUIRED: BERT expects [CLS] text [SEP].
        let encoding = self
            .tokenizer
            .encode_char_offsets(&slice, true)
            .map_err(|e| RedactError::Internal(format!("tokenization failed: {e}")))?;
        let ids: Vec<u32> = encoding.get_ids().to_vec();

        // Fail closed rather than truncate: `estimated_tokens` is an
        // over-estimate, so reaching this branch means the estimate was wrong
        // and silently truncating would drop unscanned text.
        if ids.len() > MAX_TOKENS + 2 {
            return Err(RedactError::Internal(format!(
                "window [{}, {}) produced {} tokens, over the {MAX_TOKENS} limit - \
                 the plan bound was wrong, refusing rather than truncating",
                w.start,
                w.end,
                ids.len()
            )));
        }
        if ids.len() < 2 {
            return Ok(Vec::new());
        }

        // ... UNCHANGED tensor build, forward, head, argmax, preds ...

        // CHANGE 2: the char->byte table is built from the WINDOW slice, so it
        // is local to the window; the base is added in CHANGE 3.
        let char_to_byte: Vec<usize> = {
            let mut t = Vec::with_capacity(slice.chars().count() + 1);
            let mut b = 0usize;
            t.push(0);
            for ch in slice.chars() {
                b += ch.len_utf8();
                t.push(b);
            }
            t
        };

        // CHANGE 3: every offset the model produces is a CHAR offset into the
        // window. Convert to a byte offset in the window, then add the window's
        // BYTE base to get a byte offset in the whole `text`. Getting this wrong
        // is the highest-risk part of this task: it would silently redact the
        // wrong span, which looks like success.
        let byte_base: usize = text.chars().take(w.start).map(|c| c.len_utf8()).sum();
        let to_byte = |idx: usize| -> usize {
            let local = char_to_byte
                .get(idx)
                .copied()
                .unwrap_or_else(|| char_to_byte[char_to_byte.len() - 1]);
            byte_base + local
        };
        // ... the BIO decode loop is then unchanged, using the new `to_byte` ...
        // NOTE: `flush` and the decode loop call `safe_slice(text, start, end)`
        // with the NEW absolute offsets against the WHOLE text, which is correct
        // and must not be changed to slice the window.

        Ok(matches)
    }
```

Also add next to `MAX_TOKENS`:

```rust
/// Characters of overlap between consecutive windows. A name straddling a
/// boundary is seen partially by one window and fully by the next; the overlap
/// lets the next window see the whole name, and `merge_matches` collapses the
/// duplicate. 64 characters is comfortably more than the longest Chinese
/// organisation name this model is likely to tag.
const OVERLAP_CHARS: usize = 64;
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib 2>&1 | Select-String -Pattern 'test result|FAILED|panicked' | Out-String
```

Expected: `test result: ok.`, 0 failed, and the count is up by 2.

Then confirm the wall is gone and nothing else broke:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" clippy -p pacgate-redact --all-targets -- -D warnings 2>&1 | Select-String -Pattern 'error|warning: unused|Finished' | Out-String
```

Expected: `Finished`, no errors.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/ner.rs pacgate-ai/crates/pacgate-redact/src/detect/window.rs
git commit -m "fix(redact): window long documents instead of refusing them

ner.rs:224 returned a hard error above 502 tokens, and pipeline.rs:68 propagates
it, so ANY document over roughly one page failed the entire sanitize job - NER
did not degrade to rules-only, it took the document down. verify() hit the same
wall, so no verdict could be Pass either: the document simply could not be
sanitized.

The model, head and BIO-decode code are moved, not rewritten. What changed is
that the text is planned into windows and each window is inferred separately,
with the window's byte base added to every offset. Per-window failure still
fails the document."
```

---

### Task 3: Prove it against the real model

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/tests/recall.rs`

**Interfaces:**
- Consumes: `full_detectors(dir)`, `run(detectors, text)` (both already in `recall.rs`).
- Produces: model-layer rows for long documents and boundary straddling.

**This task cannot verify itself on a machine without the weights.** The rows skip, and a skip is a pass. Follow Step 3 to obtain the weights, or report `DONE_WITH_CONCERNS` naming exactly what was skipped. Do not report this task complete on the strength of a skip.

- [ ] **Step 1: Add the rows**

Add to `tests/recall.rs`:

```rust
/// A document longer than one BERT window must sanitize, with a name that sits
/// PAST the first window redacted. Before the fix this whole call returned an
/// error, so the document could not be sanitized at all.
#[test]
fn model_layer_long_document() {
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!("SKIP model_layer_long_document: PACGATE_NER_MODEL_DIR not set or missing");
        return;
    }

    // Filler pushes the interesting name well past the first 500-token window.
    let filler = "本所同意上述条款并遵照执行。".repeat(120);
    let text = format!("{filler}张伟是本案的委托代理人。");
    let detectors = full_detectors(&model_dir).expect("model dir present; load must succeed");
    let out = run(detectors, &text);
    assert!(
        !out.contains("张伟"),
        "a name past the first window survived sanitization (windowed inference broken)"
    );
}

/// A name straddling a window boundary must come out as ONE span, not two
/// fragments. Spec 7 lists this as an explicit test.
#[test]
fn model_layer_boundary_straddling_name() {
    let model_dir = std::env::var("PACGATE_NER_MODEL_DIR").unwrap_or_default();
    if model_dir.is_empty() || !std::path::Path::new(&model_dir).exists() {
        eprintln!(
            "SKIP model_layer_boundary_straddling_name: PACGATE_NER_MODEL_DIR not set or missing"
        );
        return;
    }

    // Place a name so it is likely to sit across a planned boundary.
    let filler = "本所同意上述条款并遵照执行。".repeat(60);
    let text = format!("{filler}华信律师事务所{}{}", "及", filler);
    let detectors = full_detectors(&model_dir).expect("model dir present; load must succeed");
    let out = run(detectors, &text);
    assert!(
        !out.contains("华信律师事务所"),
        "a boundary-straddling org name survived sanitization"
    );
}
```

- [ ] **Step 2: Run with the weights absent, to confirm the skips are loud**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall -- --nocapture 2>&1 | Select-String -Pattern 'SKIP|test result' | Out-String
```

Expected: the two new `SKIP` lines plus the two existing ones, and `test result: ok`. The skips are contractual; do not remove them.

- [ ] **Step 3: Obtain the weights and run the rows for real**

The pinned revision is `5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a` (`shibing624/bert4ner-base-chinese`, Apache-2.0). Three files are required: `config.json`, `model.safetensors`, `vocab.txt` (about 388 MB total).

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$rev = '5d660ed2aa9da482bf2d99c6bc8cf2ce66758f6a'
$dir = Join-Path $env:TEMP 'ner-model-zh'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
foreach ($f in 'config.json','model.safetensors','vocab.txt') {
    $url = "https://huggingface.co/shibing624/bert4ner-base-chinese/resolve/$rev/$f"
    Write-Host "fetching $f"
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $dir $f)
}
Get-ChildItem $dir | Select-Object Name, Length
```

Then:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
$env:PACGATE_NER_MODEL_DIR = Join-Path $env:TEMP 'ner-model-zh'
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall -- --nocapture 2>&1 | Select-String -Pattern 'SKIP|test result|miss|FAILED' | Out-String
```

Expected: **no `SKIP` lines** (all four model rows run) and `test result: ok`. If a model row fails, that is a real finding about the windowing, not a flaky test — record the exact failure text.

**Set the env var for the gate too**, or the gate silently skips these rows: `$env:PACGATE_NER_MODEL_DIR` must be set in the session that runs `scripts/test-rust-workspace.ps1`.

- [ ] **Step 4: Record the outcome honestly**

If the weights could not be obtained (no network, or the pinned revision is gone), do NOT report success. Report:

- Which rows skipped.
- The exact command that would run them.
- That the long-document path is therefore verified only by the Task 1/2 plan-level tests, which prove the split and the offsets but NOT the model's behaviour across a boundary.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/tests/recall.rs
git commit -m "test(redact): model-layer rows for long documents and boundary straddling

Both skip loudly without the weights, per the plan 019 T7 contract. They are the
rows that would have caught the 512-token wall: the previous model-layer fixtures
were two short sentences, so nothing ever passed a long document to the model."
```

---

## Self-Review

**1. Spec coverage**

| Spec item | Task |
|---|---|
| §4 / §9 step 1: windowed inference | Tasks 1-2 |
| §6: per-window failure fails the document | Task 2 Step 3 (`?`, with the comment forbidding `filter_map`) |
| §7: window boundary - a straddling name is ONE span | Task 1 (`merge_collapses_a_straddling_span_to_the_longest_one`), Task 3 Step 1 |
| §7: offsets - char->byte correct with a window base | Task 2 Step 3 CHANGE 3; Task 2 Step 1 boundary test |
| §7: long document - >1 window with a mid-document name | Task 3 Step 1 |
| §7: fail-closed - a failing window fails the document | Task 2 Step 3 |
| §7: `tests/recall.rs` per-tier rows | Task 3 |
| §8: honest limitations | Task 3 Step 4 |

**Not covered by this plan, deliberately:** distribution (workstream 2, spec §9 step 4) and enabling NER in production (§9 step 5). This plan makes windowed inference *correct*; it does not ship the weights. P3 carries the Dockerfile stage, the compose wiring and `scripts/test-ner-enabled.ps1`.

**2. Placeholder scan**

One deliberate omission, disclosed in place: Task 2 Step 3 elides the tensor/forward/head/argmax/BIO block with `// ... UNCHANGED ...`. That is not a placeholder — it is an instruction to MOVE existing measured-working code, and the plan says so explicitly, including the instruction to report `DONE_WITH_CONCERNS` rather than improvise if the shapes have to change. Every new line is given literally.

**3. Type consistency**

- `Window { start: usize, end: usize }` — char offsets; used consistently in `plan_windows`, `expand_with_overlap`, and `detect_window`.
- `plan_windows<F: Fn(&str) -> usize>(text, max_units, measure) -> Vec<Window>` — defined Task 1, called in Task 2 with `window::estimated_tokens`, and in Task 1's tests with closures.
- `expand_with_overlap(text: &str, windows: &[Window], overlap_chars: usize) -> Vec<Window>` — defined Task 1, called Task 2.
- `merge_matches(Vec<Match>) -> Vec<Match>` — defined Task 1, called Task 2.
- `estimated_tokens(&str) -> usize` — added in Task 2 Step 3, referenced by Task 2 Step 1's tests. **Dependency note:** Task 2's tests reference it before Step 3 adds it, which is intentional (Step 2 must fail first) and is stated in Step 2's expected output.
- `MAX_TOKENS` — existing, unchanged at 500. `OVERLAP_CHARS` — new, Task 2 Step 3.
- `Match::len()` and `Match::overlaps(&Match)` — both confirmed to exist on `lib.rs:74-88`; `merge_matches` uses exactly those.
- `EntityType::code()` — confirmed on `entity.rs:83`.
- `window::Window` is `Copy`, so `*w` in `detect_window(text, *w)` is valid.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-26-ner-p2-windowed-inference.md`.

**Dependency ordering:** Task 1 → Task 2 (Task 2 calls Task 1's functions). Task 3 depends on Task 2 but its rows only truly run with the weights.

**The one thing that must not slip:** Task 3 Step 3. A model-layer row that skips is a pass, and this plan exists because a skipped check was mistaken for a working one.
