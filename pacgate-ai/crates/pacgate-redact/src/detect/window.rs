//! Window planning for long-document NER, with no model dependency.
//!
//! The split is driven by a `measure` closure rather than a character count,
//! because characters do not convert to BERT tokens at a fixed rate: CJK is
//! roughly 1 token per character, while a long ASCII word splits into several
//! WordPiece subwords. A fixed character budget is therefore wrong in one
//! direction or the other depending on the script mix.
//!
//! Taking `measure` as a parameter is also what makes this testable without the
//! 388 MB model bundle. `ner.rs` had no test that ran without the weights, which
//! is why the 512-token wall went unnoticed until a document was fed to it.

use crate::Match;

/// A half-open CHAR range `[start, end)` into the original text.
///
/// Char offsets, not bytes: splitting must never land mid-character, and the
/// caller converts to bytes once, against the whole original text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Window {
    pub start: usize,
    pub end: usize,
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
        // `len == 1` is the termination guarantee: splitting a single character
        // is impossible, so it is emitted even if it exceeds the budget.
        if measure(&slice) <= max_units || len == 1 {
            windows.push(Window { start, end });
            continue;
        }

        let mid = start + len / 2;
        // Push the RIGHT half first so the LEFT half is popped first, which
        // keeps the output in ascending order without needing a sort at the end.
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
    // order the windows happened to produce matches in.
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

/// A conservative token-count ESTIMATE for planning.
///
/// Deliberately an over-estimate: one token per character is the worst case for
/// CJK, and for ASCII it over-counts rather than under-counts because a WordPiece
/// word can split into several tokens. Over-estimating splits into more windows
/// than strictly necessary, which is safe. Under-estimating would produce an
/// over-long window that the model then rejects.
///
/// Production still MEASURES with the real tokenizer before inference - this is
/// a planning bound, not a substitute for the check.
pub fn estimated_tokens(text: &str) -> usize {
    text.chars().count()
}

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
                w.start,
                w.end,
                slice.chars().count()
            );
        }
    }

    #[test]
    fn windows_cover_the_text_without_gaps_or_overlap() {
        let text: String = "甲乙丙丁戊己庚辛壬癸".repeat(300);
        let plan = plan_windows(&text, 100, |s| s.chars().count());
        assert_eq!(plan[0].start, 0, "first window starts at 0");
        assert_eq!(
            plan[plan.len() - 1].end,
            text.chars().count(),
            "last window ends at the end"
        );
        for pair in plan.windows(2) {
            assert_eq!(
                pair[0].end, pair[1].start,
                "gap or overlap between core windows"
            );
        }
    }

    #[test]
    fn a_measure_that_overestimates_still_converges() {
        // Every char costs 10 units: a 5000-char text needs at least 10 windows.
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
        let core = vec![
            Window { start: 0, end: 50 },
            Window { start: 50, end: 100 },
        ];
        let out = expand_with_overlap(&text, &core, 10);
        assert_eq!(out[0].start, 0, "first window clips at 0, never underflows");
        assert_eq!(out[0].end, 50);
        assert_eq!(out[1].start, 40, "second window reaches back into the first");
        assert_eq!(out[1].end, 100);
    }

    #[test]
    fn overlap_is_clipped_to_the_text_end() {
        let text: String = "a".repeat(10);
        let core = vec![Window { start: 0, end: 10 }];
        let out = expand_with_overlap(&text, &core, 5);
        assert_eq!(out[0].end, 10, "end must never exceed the text");
    }

    #[test]
    fn merge_collapses_a_straddling_span_to_the_longest_one() {
        // The same person, seen partially by one window and fully by the next.
        let merged = merge_matches(vec![
            m(10, 14, EntityType::PersonName),
            m(10, 18, EntityType::PersonName),
        ]);
        assert_eq!(merged.len(), 1, "a straddling name must be ONE span");
        assert_eq!(
            (merged[0].start, merged[0].end),
            (10, 18),
            "the longest span wins"
        );
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

    #[test]
    fn merge_of_nothing_is_nothing() {
        assert!(merge_matches(Vec::new()).is_empty());
    }

    #[test]
    fn estimated_tokens_is_an_over_estimate_for_cjk() {
        // One token per character: the worst case, so windows come out smaller
        // than strictly needed rather than too large.
        assert_eq!(estimated_tokens("张伟是代理人"), 6);
        assert_eq!(estimated_tokens("hello"), 5);
        assert_eq!(estimated_tokens(""), 0);
    }
}
