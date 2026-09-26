# Step 0 + Step 1: Boundary Recall Fix, Rust Gate, and Two Rule Detectors - Implementation Plan (P1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close a silent recall hole in the four identifier classes we already ship, gate the Rust layer that has never been gated, and add the two rule-shaped detectors (`Landline`, `IpAddress`) that are genuinely cheap.

**Architecture:** All changes are inside the one crate that owns detection, `pacgate-redact`. A single shared boundary predicate replaces `\b` on the four candidate patterns; two new candidate patterns plus validators extend `TierOneDetector`; one new PowerShell gate puts `cargo test` and `cargo clippy -D warnings` for this crate into `run-all-checks.ps1`, where 21 PowerShell gates already live and no Rust check ever has.

**Tech Stack:** Rust (crate `pacgate-redact`, deps already present: `regex`, `once_cell`, std), PowerShell 5.1-compatible gate script. **No new dependencies.** `std::net::Ipv4Addr` is std.

**Spec:** `docs/superpowers/specs/2026-09-26-ner-enablement-design.md` - this implements **§10.5** (the boundary recall fix), **§10.6** (the Rust gate), and **§11.2-11.4** (`Landline`, `IpAddress`). Read §11.1 before starting: it explains why `CaseNumber` is deliberately **not** in this plan.

## Global Constraints

- **`cargo` is NOT on PATH.** Use `& "$env:USERPROFILE\.cargo\bin\cargo.exe"`. Every command below assumes CWD is `pacgate-ai/` (the Rust workspace root, where `Cargo.toml` lives) unless stated otherwise.
- **Do NOT implement `CaseNumber`.** Spec §11.1: the only available filter, `is_public_case_number`, is a pure shape test that returns `True` for every candidate a shape-based detector could emit. A `CaseNumber` detector built on it would redact nothing while appearing to cover the class. It needs the §12 design pass.
- **Do NOT widen `\b` to `[^\w]`.** The correct predicate is "not flanked by an ASCII alphanumeric" (spec §10.5). `[^\w]` would also reject the required trailing-CJK case `手机13812345678号`.
- **Offsets are byte offsets into the ORIGINAL text.** `Match.start`/`Match.end` are half-open byte offsets (`lib.rs:66-72`). No transformation may shift them. This is why full-width digit normalisation is deferred (§10.5) and why `is_bounded` slices `&text[..start]` / `&text[end..]` directly.
- **`is_bounded` must not slice on a non-boundary.** All call sites pass offsets produced by `regex::Match` on the same `text`, so they are char boundaries by construction. Do not add a code path that computes offsets differently.
- **Fail closed.** No detector may return `Ok` with fewer matches on error. Every new validator is a *filter* (fewer matches), never a fallback.
- **`MAX_MATCHES = 4096` ceiling stays.** New detectors add candidates; the existing ceiling check in `detect()` must remain after all loops.
- **Gate exit codes:** `0` pass, `1` real failure, `2` cannot check. A "cannot check" is NEVER reported as a pass. Do not add a workspace-wide `-D warnings` gate: measured 2026-09-26 it is red on arrival (7 pre-existing warnings in `pacgate-core`, `pacgate-search`, `pacgate-agent`, `pacgate-api`). `pacgate-redact` alone is clean under `-D warnings`.
- **Run compose from `deploy/client-bundle/`**, not the repo root. Not needed for this plan's tasks, but note it if you reach for a stack check.
- **Credential safety:** to test `.env` presence use ONLY `[bool](Select-String -Path '<file>' -Pattern '<KEY>=' -Quiet)`. NEVER `Get-Content` a `.env`, NEVER `Select-String` without `-Quiet`, NEVER print a matched line. A non-`-Quiet` grep leaked a password earlier in this work.
- **After any script that mutates files, run `git status --short`** and `git checkout --` whatever it left.
- **PowerShell is case-INSENSITIVE for variables.** Use named variables only; never rely on `$a` and `$A` being distinct.
- **Line-based command execution in this environment corrupts nested/dollar-heavy scripts.** For the multi-line PowerShell probe in Task 6, write the script to a file first, then run the file. Do not paste a heredoc with nested `$` onto one line.

---

## Measured findings this plan is built on

All measured on this box 2026-09-26 with temporary Rust probes (`tests/zz_probe_tmp.rs`, created, run, deleted - working tree verified clean afterwards). Re-measure rather than trust if anything looks off.

### F1 - `\b` does not exist between a CJK character and a digit, so four shipped classes miss the common written form

Rust's `regex` crate is Unicode-aware by default, so `\w` includes CJK. A CJK character is therefore a word character, and `\b` does not exist between it and a digit. Measured against the real `tier_one_detectors()`:

```
id spaced        -> ["11010519491231002X"]     ok
id adjacent      -> []                          MISS  身份证11010519491231002X
uscc spaced      -> ["91350100M000100Y43"]     ok
uscc adjacent    -> []                          MISS  代码91350100M000100Y43
mobile spaced    -> ["13812345678"]            ok
mobile adjacent  -> []                          MISS  手机13812345678
card spaced      -> ["4111111111111111"]       ok
card adjacent    -> []                          MISS  卡号4111111111111111
email adjacent   -> ["zhang.san@example.com"]  ok (no \b in RE_EMAIL)
```

Four of five classes affected: `CnResidentId`, `Uscc`, `CnMobile`, `BankCard`. `手机：13812345678` (full-width colon) and `（11010519491231002X）` (brackets) DO match - only a CJK *character* directly adjacent breaks it. Chinese text does not use inter-word spaces, so the failing form is the one a lawyer writes.

### F2 - the fix, validated

`is_bounded` rejecting only ASCII-alphanumeric flanking. Measured:

```
mobile adjacent CJK   -> ["13812345678"]   fixed
mobile trailing CJK   -> ["13812345678"]   fixed (手机13812345678号)
mobile longer token   -> []                still rejected (ABC13812345678)
mobile longer token2  -> []                still rejected (A13812345678)
mobile extra digit    -> []                still rejected (138123456789)
id     trailing X     -> []                still rejected (11010519491231002XX)
```

### F3 - `Landline` and `IpAddress` patterns behave as required, and only behave correctly with `is_bounded`

`Landline` candidate `0\d{2,3}-?\d{7,8}` + `is_bounded`:

```
座机010-12345678    -> ["010-12345678"]   ok
座机01012345678     -> ["01012345678"]    ok
座机0755-12345678   -> ["0755-12345678"]  ok
手机13812345678     -> []                 ok
编号123456789012    -> []                 ok (no leading 0)
座机010-123456789   -> []                 ok - see note below
A010-12345678       -> []                 ok (ASCII-alnum flanked)
```

**Two of these rows are rejected by `is_bounded`, not by the pattern shape.** Measured directly:

```
座机010-123456789 :  regex alone -> ["010-12345678"]   WITH is_bounded -> []
                     candidate "010-12345678" ends at a digit ('9'), so bounded=false
```

So the pattern is not the guard for the over-long case - the predicate is. This matters because it means **`is_bounded` is load-bearing for `Landline` precision, not only for the mobile/landline distinction.** If the predicate were dropped, `座机010-123456789` would yield a truncated `010-12345678` span, which is worse than a miss: it would redact a prefix and leave the rest, producing a partially-masked number that looks sanitized.

Likewise the mobile rejection is not `is_bounded`'s doing: `座机010-...` starts with `0`, so `1[3-9]\d{9}` never matches it at all. Measured: `138123456789` produces `landline=[] digit_run=["138123456789"]`.

`IpAddress` candidate `\d{1,3}(?:\.\d{1,3}){3}` + `Ipv4Addr::parse` + fifth-dot guard + `is_bounded`:

```
服务器192.168.1.1   -> ["192.168.1.1"]   ok
访问10.0.0.1:8080   -> ["10.0.0.1"]      ok
内网172.16.0.254    -> ["172.16.0.254"]  ok
版本1.2.3.400       -> []                ok (octet > 255)
日期2026.09.26      -> []                ok (3 groups)
地址1.2.3.4.5       -> []                ok (fifth group)
版本v1.2.3          -> []                ok (3 groups)
999.1.1.1           -> []                ok (octet > 255)
```

Here the octet guard is the pattern-independent one: `str::parse::<Ipv4Addr>()` also rejects leading zeros (`00.1.1.1` fails), which a hand-rolled `split('.').all(|p| p.parse::<u8>().is_ok())` would wrongly accept.

**A `MatchSource::Context` option was considered and rejected.** The codebase documents `MatchSource::Context` as "a pattern plus a label or surrounding context" (`lib.rs:58-59`), and `Landline`'s `010` head is structural rather than a label. Using `Context` would overstate the evidence. Both new detectors use `MatchSource::Pattern`, which is documented as "a regex pattern matched, but no checksum was available" - the honest description for both.

### F4 - the Rust layer is gated nowhere

| Check | Runs today? |
|---|---|
| `run-all-checks.ps1` | 21 PowerShell gates |
| Any gate invoking `cargo test` / `cargo clippy` | **none** |
| CI (`build-ghcr.yml`) | build, push, manifest verify - no `cargo test`, no `cargo clippy` |

This is why F1 shipped. `pacgate-redact` passes `clippy --all-targets -- -D warnings` today (verified).

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs` | The Tier-1 rule detector: candidate patterns, validators, `Detector` impl | Modify - 4 patterns lose `\b`, 2 patterns added, 3 loops added, `is_bounded` added, tests added |
| `pacgate-ai/crates/pacgate-redact/tests/recall.rs` | Per-tier recall harness (spec §5) | Modify - rule-layer rows for adjacency and both new classes |
| `scripts/test-rust-workspace.ps1` | Gates `cargo test` + `cargo clippy -D warnings` for `pacgate-redact` | Create |
| `scripts/run-all-checks.ps1` | The gate list | Modify - add one entry |

`is_bounded` lives in `rules.rs` rather than `noise.rs`: `noise.rs` is post-detection reduction, while this is a candidate-acceptance predicate that the detector itself must apply. Keeping it beside the patterns it serves means a future detector author sees it in the same file.

---

### Task 1: The shared boundary predicate

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`
- Test: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs` (in-file `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: nothing.
- Produces: `fn is_bounded(text: &str, start: usize, end: usize) -> bool` - module-private (`fn`, not `pub fn`). Accepts when the character immediately before `start` and immediately after `end` is not an ASCII alphanumeric. Returns `true` at either edge of the text.

- [ ] **Step 1: Write the failing test**

Add to the existing `mod tests` in `rules.rs` (after the last test, before the closing brace):

```rust
    /// A CJK character is a word character for Unicode-aware `\b`, so `\b` does
    /// not exist between it and a digit. These are the forms a Chinese contract
    /// actually contains - no inter-word spaces.
    #[test]
    fn is_bounded_accepts_cjk_adjacency_and_rejects_longer_tokens() {
        let text = "手机13812345678";
        let start = 6; // "手机" is 6 bytes (2 chars x 3 bytes)
        assert_eq!(&text[start..start + 11], "13812345678");
        assert!(is_bounded(text, start, start + 11), "CJK adjacency must be accepted");

        // Trailing CJK too: the number is followed by a unit character.
        let trailing = "手机13812345678号";
        assert!(is_bounded(trailing, start, start + 11));

        // A longer ASCII token must still be rejected: this is the reason not to
        // simply drop the anchors.
        assert!(!is_bounded("ABC13812345678", 3, 14));
        assert!(!is_bounded("A13812345678", 1, 12));
        assert!(!is_bounded("138123456789", 0, 11));

        // Text edges are unconstrained.
        assert!(is_bounded("13812345678", 0, 11));
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib is_bounded_accepts_cjk 2>&1 | Out-String
```

Expected: FAIL to compile with `error[E0425]: cannot find function 'is_bounded' in this scope`.

- [ ] **Step 3: Write minimal implementation**

Add to `rules.rs`, immediately after the `MAX_MATCHES` const and before `pub struct TierOneDetector`:

```rust
/// True when the span `[start, end)` is not flanked by an ASCII alphanumeric.
///
/// Replaces `\b` on the candidate patterns. `\b` is wrong here because the
/// `regex` crate is Unicode-aware by default, so `\w` includes CJK - which means
/// `\b` does not exist between a CJK character and a digit, and
/// `手机13812345678` (no space) is silently missed. Chinese text does not use
/// inter-word spaces, so that is the common form, not an edge case.
///
/// The test is deliberately "not ASCII-alphanumeric" rather than "non-word":
/// trailing CJK (`手机13812345678号`) must be accepted, while a longer token
/// (`ABC13812345678`) must not. `[^\w]` would reject both.
///
/// Offsets come from `regex::Match` on the same `text`, so they are char
/// boundaries by construction.
fn is_bounded(text: &str, start: usize, end: usize) -> bool {
    let before_ok = text[..start]
        .chars()
        .next_back()
        .map_or(true, |c| !c.is_ascii_alphanumeric());
    let after_ok = text[end..]
        .chars()
        .next()
        .map_or(true, |c| !c.is_ascii_alphanumeric());
    before_ok && after_ok
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib is_bounded_accepts_cjk 2>&1 | Out-String
```

Expected: `test result: ok. 1 passed`.

Note: at this step `is_bounded` is unused by non-test code, so `cargo build` emits `warning: function 'is_bounded' is never used`. That is expected and disappears in Task 2. Do not add `#[allow(dead_code)]` - it would hide a real "forgot to wire it up" mistake in Task 2.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/rules.rs
git commit -m "fix(redact): add ASCII-alnum boundary predicate for Tier-1 candidates

\b is Unicode-aware so it does not exist between a CJK character and a digit,
which silently misses 手机13812345678 (no space) - the form Chinese contracts
actually use. Predicate is not wired to any pattern yet."
```

---

### Task 2: Apply the predicate to the four shipped patterns (closes the recall hole)

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`
- Test: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`

**Interfaces:**
- Consumes: `is_bounded(text, start, end) -> bool` from Task 1.
- Produces: no new names. Behavioural contract for later tasks: **every boundary-anchored candidate pattern in `rules.rs` is unanchored in the regex and filtered by `is_bounded`.** New detectors in Tasks 3-4 follow the same shape.

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `rules.rs`:

```rust
    /// The four boundary-anchored classes must be caught with a CJK character
    /// directly adjacent, not only when separated by a space. Measured before
    /// the fix: all four adjacent forms returned no matches at all.
    #[test]
    fn finds_boundary_anchored_classes_when_cjk_is_adjacent() {
        let cases = [
            ("身份证11010519491231002X", "11010519491231002X", EntityType::CnResidentId),
            ("代码91350100M000100Y43", "91350100M000100Y43", EntityType::Uscc),
            ("手机13812345678", "13812345678", EntityType::CnMobile),
            ("卡号4111111111111111", "4111111111111111", EntityType::BankCard),
        ];
        for (text, value, entity) in cases {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == entity && m.text == value),
                "adjacency miss ({entity:?}): {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The fix must not become "match any digit run": a longer ASCII token still
    /// has to be rejected, or the recall fix becomes a precision regression.
    #[test]
    fn still_rejects_longer_ascii_tokens() {
        // 11-digit mobile shape embedded in a longer alphanumeric token.
        let embedded = TierOneDetector::new().detect("ABC13812345678").unwrap();
        assert!(embedded.is_empty(), "must not extract a mobile from a longer token");

        // 19 digits: matches RE_DIGIT_RUN's 12-19 range, and 4111111111111111111
        // is not a Luhn-valid card, so nothing should be reported.
        let extra = TierOneDetector::new().detect("138123456789").unwrap();
        assert!(
            !extra.iter().any(|m| m.entity == EntityType::CnMobile),
            "a 12-digit run must not be read as a mobile"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib finds_boundary_anchored_classes_when_cjk_is_adjacent 2>&1 | Out-String
```

Expected: FAIL with `adjacency miss (CnResidentId): 11010519491231002X not found in 身份证11010519491231002X`. This is the defect being fixed - confirm it fails for all four, not just one.

- [ ] **Step 3: Write minimal implementation**

Replace the four candidate pattern definitions (`RE_CN_ID_CANDIDATE`, `RE_USCC_CANDIDATE`, `RE_MOBILE_CANDIDATE`, `RE_DIGIT_RUN`) with unanchored versions:

```rust
/// 18-char resident ID shape. Validity is decided by the checksum, not this.
/// Unanchored on purpose - `is_bounded` is the boundary test, because `\b`
/// fails between a CJK character and a digit.
static RE_CN_ID_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{17}[\dXx]").expect("id candidate regex is valid"));

/// 18-char USCC shape: digits plus uppercase letters, excluding I O S V Z.
static RE_USCC_CANDIDATE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"[0-9A-HJ-NPQRTUWXY]{18}").expect("uscc candidate regex is valid")
});

static RE_MOBILE_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"1[3-9]\d{9}").expect("mobile regex is valid"));

static RE_DIGIT_RUN: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{12,19}").expect("digit run regex is valid"));
```

Then apply `is_bounded` at each of the four call sites. Replace the body of the five existing loops in `detect()` with:

```rust
        for m in RE_CN_ID_CANDIDATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if validate_cn_resident_id(m.as_str()) {
                self.push(&mut out, m, EntityType::CnResidentId, MatchSource::Checksum);
            }
        }

        for m in RE_USCC_CANDIDATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if validate_uscc(m.as_str()) {
                self.push(&mut out, m, EntityType::Uscc, MatchSource::Checksum);
            }
        }

        for m in RE_MOBILE_CANDIDATE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::CnMobile, MatchSource::Checksum);
        }

        for m in RE_DIGIT_RUN.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if validate_luhn(m.as_str()) {
                self.push(&mut out, m, EntityType::BankCard, MatchSource::Checksum);
            }
        }
```

`RE_EMAIL` is unchanged: it has no `\b` and F1 measured it as unaffected.

- [ ] **Step 4: Run the full crate suite to verify both new tests pass and nothing regressed**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact 2>&1 | Select-String -Pattern 'test result|FAILED|panicked|adjacency miss' | Out-String
```

Expected: every `test result: ok.` line, 0 failed. The two new tests pass; the six pre-existing tests in `rules.rs`, the `verify.rs` tests, the `pipeline.rs` tests and `tests/recall.rs` still pass. In particular `finds_mobile_only_with_a_valid_operator_prefix` still rejects `12812345678`.

If a pre-existing test now fails, the cause is almost certainly that a pattern change widened matching rather than narrowed it - check that you did not remove a validator call.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/rules.rs
git commit -m "fix(redact): catch identifiers adjacent to CJK, not just space-separated

Measured before: 手机13812345678, 身份证11010519491231002X, 代码91350100M000100Y43
and 卡号4111111111111111 all returned zero matches, because Unicode-aware \b does
not exist between a CJK character and a digit. Chinese text has no inter-word
spaces, so this missed the common written form in four shipped classes while
verify() replayed the same detectors and returned Pass.

is_bounded replaces the anchors: rejects ASCII-alphanumeric flanking, accepts
CJK/punctuation/whitespace, so 手机13812345678号 is caught and ABC13812345678 is
not."
```

---

### Task 3: `Landline` detector

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`
- Test: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`

**Interfaces:**
- Consumes: `is_bounded` (Task 1), the "unanchored pattern + predicate" shape (Task 2).
- Produces: `EntityType::Landline` matches from `TierOneDetector::detect`. `EntityType::Landline` already exists (`entity.rs:49`), is already `Tier::Two`, and already has code `"LANDLINE"` and an `Opaque` policy. **No change to `entity.rs` is required or permitted in this task.**

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `rules.rs`:

```rust
    /// Two separate claims, both measured. The `0\d{2,3}` head means a mobile
    /// never matches at all (it starts with 1). The over-long form is rejected by
    /// `is_bounded`, not by the pattern - `010-12345678` inside a longer digit run
    /// is a shape match, and only the trailing-digit check stops it producing a
    /// truncated span that would leave part of the number in the clear.
    #[test]
    fn finds_landline_with_and_without_hyphen() {
        for (text, value) in [
            ("座机010-12345678", "010-12345678"),
            ("座机01012345678", "01012345678"),
            ("座机0755-12345678", "0755-12345678"),
            ("座机075512345678", "075512345678"),
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == EntityType::Landline && m.text == value),
                "landline miss: {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// The false-positive side. A mobile, a bare digit run, and a landline-shaped
    /// run with too many subscriber digits must all be rejected.
    #[test]
    fn does_not_read_a_mobile_or_digit_run_as_a_landline() {
        for text in ["手机13812345678", "编号123456789012", "座机010-123456789"] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                !found.iter().any(|m| m.entity == EntityType::Landline),
                "false positive: {text} produced a Landline"
            );
        }
        // And the ASCII-flanked form, which is what is_bounded exists to reject.
        let flanked = TierOneDetector::new().detect("A010-12345678").unwrap();
        assert!(
            !flanked.iter().any(|m| m.entity == EntityType::Landline),
            "must not extract a landline from a longer ASCII token"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib finds_landline_with_and_without_hyphen 2>&1 | Out-String
```

Expected: FAIL with `landline miss: 010-12345678 not found in 座机010-12345678`.

- [ ] **Step 3: Write minimal implementation**

Add the pattern after `RE_DIGIT_RUN`:

```rust
/// Chinese landline: `0` + 2-3 digit area code + 7-8 digit subscriber,
/// optionally hyphenated.
///
/// The `0` head is what keeps this clear of the mobile rule - `1[3-9]\d{9}`
/// never matches a number starting with 0 (measured).
///
/// Note this pattern is NOT self-guarding for the over-long case: in
/// `010-123456789` it happily matches the first 11 characters. `is_bounded`
/// rejects it, because the span then ends on a digit. That check is therefore
/// load-bearing for precision here, not just for the CJK fix - without it we
/// would emit a truncated span, redact a prefix, and leave the rest visible.
static RE_LANDLINE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"0\d{2,3}-?\d{7,8}").expect("landline regex is valid"));
```

Add the loop in `detect()` after the `RE_DIGIT_RUN` loop and before the `RE_EMAIL` block:

```rust
        for m in RE_LANDLINE.find_iter(text) {
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            self.push(&mut out, m, EntityType::Landline, MatchSource::Pattern);
        }
```

`MatchSource::Pattern`, not `Checksum`: this is shape plus boundary, and `MatchSource::Pattern` is documented as "a regex pattern matched, but no checksum was available" (`lib.rs:56-57`).

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib 2>&1 | Select-String -Pattern 'test result|FAILED|panicked' | Out-String
```

Expected: `test result: ok.`, 0 failed.

Also confirm `Landline` reaches a placeholder end-to-end, since a detector whose entity has no policy would surface here rather than in unit tests:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib credentials_are_removed_never_placeholdered 2>&1 | Select-String -Pattern 'test result' | Out-String
```

Expected: `ok` - this proves the `entity.rs` policy match is exhaustive and compiles. Do NOT edit `entity.rs`.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/rules.rs
git commit -m "feat(redact): detect Chinese landline numbers

0 + 2-3 digit area code + 7-8 digit subscriber, optionally hyphenated. The
0\d{2,3} head excludes the mobile shape and bare digit runs, so no separate
area-code table is needed. EntityType::Landline already existed with Tier::Two
and an Opaque policy; this is the detector that was missing."
```

---

### Task 4: `IpAddress` detector

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`
- Test: `pacgate-ai/crates/pacgate-redact/src/detect/rules.rs`

**Interfaces:**
- Consumes: `is_bounded` (Task 1), the "unanchored pattern + predicate" shape (Task 2).
- Produces: `EntityType::IpAddress` matches from `TierOneDetector::detect`. `EntityType::IpAddress` already exists (`entity.rs:58`), already `Tier::Four`, code `"IP"`. **No change to `entity.rs`.**

- [ ] **Step 1: Write the failing test**

Add to `mod tests` in `rules.rs`:

```rust
    /// The octet check comes from std's parser, not a hand-rolled one: it also
    /// rejects leading zeros like 00.1.1.1, which `u8::parse` accepts.
    #[test]
    fn finds_ipv4_and_rejects_non_addresses() {
        for (text, value) in [
            ("服务器192.168.1.1", "192.168.1.1"),
            ("访问10.0.0.1:8080", "10.0.0.1"),
            ("内网172.16.0.254", "172.16.0.254"),
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                found.iter().any(|m| m.entity == EntityType::IpAddress && m.text == value),
                "ipv4 miss: {value} not found in {text}; got {:?}",
                found.iter().map(|m| (m.entity, m.text.as_str())).collect::<Vec<_>>()
            );
        }
    }

    /// Without the fifth-dot guard, `1.2.3.4.5` matches its first four groups.
    /// Without the octet check, version strings and dates match.
    #[test]
    fn does_not_read_versions_dates_or_longer_runs_as_ipv4() {
        for text in [
            "版本1.2.3.400",   // octet > 255
            "日期2026.09.26",  // only 3 groups
            "地址1.2.3.4.5",   // fifth group
            "版本v1.2.3",      // only 3 groups
            "999.1.1.1",       // octet > 255
            "00.1.1.1",        // leading zero
        ] {
            let found = TierOneDetector::new().detect(text).unwrap();
            assert!(
                !found.iter().any(|m| m.entity == EntityType::IpAddress),
                "false positive: {text} produced an IpAddress"
            );
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib finds_ipv4_and_rejects_non_addresses 2>&1 | Out-String
```

Expected: FAIL with `ipv4 miss: 192.168.1.1 not found in 服务器192.168.1.1`.

- [ ] **Step 3: Write minimal implementation**

Add the pattern after `RE_LANDLINE`:

```rust
/// IPv4 shape. The shape alone is not enough - `1.2.3.400` and `2026.09.26`
/// fit it - so validation is `str::parse::<Ipv4Addr>()`, which bounds each
/// octet and rejects leading zeros.
static RE_IPV4_CANDIDATE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\d{1,3}(?:\.\d{1,3}){3}").expect("ipv4 regex is valid"));
```

Add `use std::net::Ipv4Addr;` to the imports at the top of `rules.rs`, after `use regex::Regex;`:

```rust
use std::net::Ipv4Addr;
```

Add the loop in `detect()` after the `RE_LANDLINE` loop and before the `RE_EMAIL` block:

```rust
        for m in RE_IPV4_CANDIDATE.find_iter(text) {
            // A fifth dot-group means this is a longer run, not an address:
            // `1.2.3.4.5` otherwise matches its first four groups.
            if text[m.end()..].starts_with('.') {
                continue;
            }
            if !is_bounded(text, m.start(), m.end()) {
                continue;
            }
            if m.as_str().parse::<Ipv4Addr>().is_ok() {
                self.push(&mut out, m, EntityType::IpAddress, MatchSource::Pattern);
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --lib 2>&1 | Select-String -Pattern 'test result|FAILED|panicked' | Out-String
```

Expected: `test result: ok.`, 0 failed.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/src/detect/rules.rs
git commit -m "feat(redact): detect IPv4 addresses

Octet validation comes from str::parse::<Ipv4Addr>() rather than a hand-rolled
range check, because std's parser also rejects leading zeros (00.1.1.1). A
fifth-dot-group guard stops 1.2.3.4.5 matching its first four groups."
```

---

### Task 5: Extend the recall harness with rule-layer rows

**Files:**
- Modify: `pacgate-ai/crates/pacgate-redact/tests/recall.rs`
- Test: the same file (it is a test target)

**Interfaces:**
- Consumes: `tier_one_detectors()`, `Sanitizer::new`, `MappingVersion::CURRENT`, `pacgate_core::DataLevel::T3ProjectSpecific` - all already used by the file's existing `run()` helper.
- Produces: no new public names. Adds two test functions and one fixture table.

**Context you need:** this file already exists (65 lines) and already has `rule_layer_tier_one_recall` and `model_layer_tier_two_recall`. Spec §5 records that an earlier draft wrongly described it as unbuilt. **Extend it; do not rewrite it.** The existing `run()` helper is at the top and must be reused.

- [ ] **Step 1: Write the failing test**

Add to `tests/recall.rs`, after the existing `rule_layer_tier_one_recall` function and before `model_layer_tier_two_recall`:

```rust
/// The forms Chinese contracts actually contain: a label immediately followed by
/// the identifier, with no separating space. This row would have failed before
/// the boundary fix - all four adjacent forms returned zero matches.
///
/// Kept as its own row rather than folded into `rule_layer_tier_one_recall`
/// because it is a different claim: that row proves the checksums work, this one
/// proves the boundaries do.
#[test]
fn rule_layer_cjk_adjacency() {
    let fixtures = [
        ("身份证11010519491231002X", "11010519491231002X"),
        ("代码91350100M000100Y43", "91350100M000100Y43"),
        ("手机13812345678", "13812345678"),
        ("卡号4111111111111111", "4111111111111111"),
        // Trailing CJK, which `[^\w]` would have rejected.
        ("手机13812345678号", "13812345678"),
    ];
    for (text, value) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(value),
            "adjacency miss: {value} survives sanitization in {text}"
        );
    }
}

/// The two classes added in step 1, sanitized end-to-end rather than only
/// detected. This is the row that reports step 1 as delivered.
#[test]
fn rule_layer_step_one_classes() {
    let fixtures = [
        ("座机010-12345678", "010-12345678", EntityType::Landline),
        ("座机01012345678", "01012345678", EntityType::Landline),
        ("服务器192.168.1.1", "192.168.1.1", EntityType::IpAddress),
    ];
    for (text, value, entity) in fixtures {
        let out = run(tier_one_detectors(), text);
        assert!(
            !out.contains(value),
            "step-1 miss ({entity:?}): {value} survives sanitization in {text}"
        );
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall 2>&1 | Out-String
```

Expected: both new tests FAIL with `adjacency miss` / `step-1 miss`. This is expected and is the point of the step: it proves the harness is measuring real behaviour. (Tasks 2-4 already made these pass, so if you are running the plan in order you will instead see them pass immediately. Either way, run the command and read the output - do not assume.)

If they pass here, that is the Tasks 2-4 fix confirming itself through a second, independent measurement path. Confirm by count: `test result: ok. 4 passed`.

- [ ] **Step 3: Run test to verify it passes**

If Step 2 showed failures, no implementation change is needed for this file - the detector changes in Tasks 2-4 are the implementation. Re-run:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall 2>&1 | Out-String
```

Expected: `test result: ok. 4 passed; 0 failed` and, on a machine without the model weights, the loud `SKIP model_layer_tier_two_recall: PACGATE_NER_MODEL_DIR not set or missing` line. The skip is contractual (spec §5) - do not turn it into a failure.

- [ ] **Step 4: Confirm the model row still skips loudly rather than silently**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr\pacgate-ai
& "$env:USERPROFILE\.cargo\bin\cargo.exe" test -p pacgate-redact --test recall -- --nocapture 2>&1 | Select-String -Pattern 'SKIP|test result' | Out-String
```

Expected: the `SKIP` line appears (weights absent on this box), and `test result: ok`.

- [ ] **Step 5: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add pacgate-ai/crates/pacgate-redact/tests/recall.rs
git commit -m "test(redact): per-tier recall rows for CJK adjacency and step-1 classes

Two new rule-layer rows in the existing harness. The adjacency row is a
different claim from the existing Tier-1 row - that one proves the checksums
work, this one proves the boundaries do - so it is kept separate rather than
folded in. The step-1 row measures Landline and IpAddress end-to-end."
```

---

### Task 6: The Rust gate, which did not previously exist

**Files:**
- Create: `scripts/test-rust-workspace.ps1`
- Test: the script's own exit code, plus a negative test that it can fail
- Modify: `scripts/run-all-checks.ps1` (gate list only)

**Interfaces:**
- Consumes: nothing from earlier tasks, but it gates them - so it is verified by running against the Task 1-5 code, then mutated to confirm it can go red.
- Produces: `scripts/test-rust-workspace.ps1`, contract `exit 0` = `pacgate-redact` tests and clippy pass, `exit 1` = a real failure, `exit 2` = cargo not found.

**Context you need:** `run-all-checks.ps1` has 21 gate entries in a `$gates` array (plus a separate `$liveStackGates` array). A gate needing a *running stack* belongs in `$liveStackGates`; one needing only a toolchain belongs in `$gates`. This one needs only cargo, so it goes in `$gates`.

- [ ] **Step 1: Write the script**

Create `scripts/test-rust-workspace.ps1`. Write it as a file (do not paste it as a one-liner - nested `$` gets mangled by line-based execution in this environment):

```powershell
# Gates the Rust layer, which nothing previously did.
#
# Measured 2026-09-26: run-all-checks.ps1 is 21 PowerShell gates, and neither it
# nor CI (build-ghcr.yml) runs any cargo command. So every Rust assertion in this
# repo - checksum validators, the recall harness, the pipeline tests - ran only
# when a human typed the command. That is why a silent recall miss sat in four
# shipped detectors: there was no mechanism whose job was to notice.
#
# Scoped to -p pacgate-redact deliberately. The workspace has pre-existing clippy
# warnings (pacgate-core 1, pacgate-search 2, pacgate-agent 1, pacgate-api 3,
# measured 2026-09-26), so a --workspace -D warnings gate would be red on arrival
# and be disabled within a week. pacgate-redact alone is clean, so this is a
# ratchet and not a new burden. Widening it is a separate cleanup task.
#
# Exit codes: 0 pass, 1 real failure, 2 cannot check. A "cannot check" is never a pass.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
if (-not (Test-Path $cargo)) {
    Write-Host '  exit 2 - cargo not found at the expected path; cannot check' -ForegroundColor Yellow
    exit 2
}

# The workspace root is pacgate-ai/, which is where Cargo.toml lives.
$workspace = Join-Path (Get-Location) 'pacgate-ai'
if (-not (Test-Path (Join-Path $workspace 'Cargo.toml'))) {
    Write-Host "  exit 2 - no Cargo.toml at $workspace; cannot check" -ForegroundColor Yellow
    exit 2
}

Push-Location $workspace
try {
    Write-Host '=== Rust gate: pacgate-redact tests ===' -ForegroundColor Cyan
    & $cargo test -p pacgate-redact --all-targets 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  FAIL cargo test -p pacgate-redact' -ForegroundColor Red
        exit 1
    }

    Write-Host '=== Rust gate: pacgate-redact clippy -D warnings ===' -ForegroundColor Cyan
    & $cargo clippy -p pacgate-redact --all-targets -- -D warnings 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  FAIL cargo clippy -D warnings -p pacgate-redact' -ForegroundColor Red
        exit 1
    }

    Write-Host '  PASS pacgate-redact: tests + clippy clean' -ForegroundColor Green
    exit 0
}
finally {
    Pop-Location
}
```

- [ ] **Step 2: Run it and confirm it passes**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/test-rust-workspace.ps1
"exit=$LASTEXITCODE"
```

Expected: exit 0, ending with `PASS pacgate-redact: tests + clippy clean`.

- [ ] **Step 3: Negative-test the gate - prove it can go RED**

A gate that has never been red is not evidence. Mutate the crate so a test fails, run the gate, then revert:

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
$f = 'pacgate-ai/crates/pacgate-redact/src/detect/rules.rs'
Copy-Item $f "$f.gatebak"

# Break the mobile pattern so finds_mobile_only_with_a_valid_operator_prefix fails.
(Get-Content $f -Raw) -replace 'r"1\[3-9\]\\d\{9\}"', 'r"1[0-9]\d{9}"' | Set-Content $f -Encoding UTF8

& pwsh -NoProfile -File scripts/test-rust-workspace.ps1
"mutated exit=$LASTEXITCODE  (expected 1)"

Move-Item "$f.gatebak" $f -Force
git status --short
```

Expected: `mutated exit=1`, and `git status --short` shows a clean tree for `rules.rs` after the restore. **If the mutated run exits 0, the gate is not wired correctly - fix it before continuing.** Check the `-replace` actually changed the file: if the pattern did not match, the file is unmodified and the run proves nothing. Confirm with `Select-String -Path $f -Pattern 'RE_MOBILE_CANDIDATE' -Context 0,2` before running the gate.

- [ ] **Step 4: Add the gate to the runner**

In `scripts/run-all-checks.ps1`, add one line to the `$gates` array. Place it next to the other self-contained gates; the array begins at line 36 with `'scripts/test-install-render.ps1'`.

Add after the `'scripts/test-version-marker-against-image.ps1'` entry (around line 93):

```powershell
    # Gates the Rust layer. Nothing did before: this runner is all PowerShell and
    # CI runs no cargo command, which is how a silent recall miss shipped in four
    # detectors. Self-contained - needs only cargo - so it belongs here, not in
    # $liveStackGates. Exits 2 on a machine without cargo.
    'scripts/test-rust-workspace.ps1'
```

- [ ] **Step 5: Run the runner and confirm 22 gates, all green**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
& pwsh -NoProfile -File scripts/run-all-checks.ps1 2>&1 | Select-String -Pattern 'test-rust-workspace|Gates|FAILURE|PASSED|gate' | Out-String
"exit=$LASTEXITCODE"
```

Expected: `test-rust-workspace.ps1` appears in the summary with a pass, gate count 22, exit 0.

If the run goes red on an unrelated gate, do NOT fold that fix into this task - check whether it was already red before your change (`git stash` is not needed; the runner is read-only apart from the mutation suites, which restore themselves). Report it separately.

- [ ] **Step 6: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add scripts/test-rust-workspace.ps1 scripts/run-all-checks.ps1
git commit -m "ci(gates): gate the Rust layer, which nothing gated before

run-all-checks.ps1 was 21 PowerShell gates and CI ran no cargo command, so every
Rust assertion in this repo ran only when a human typed it. That is the structural
reason a silent recall miss sat in four shipped detectors: nothing was watching.

Scoped to -p pacgate-redact because the workspace has 7 pre-existing clippy
warnings and a --workspace -D warnings gate would be red on arrival. Negative-
tested: mutating the mobile pattern to fail a test makes the gate exit 1."
```

---

### Task 7: Report the measured coverage to the client deliverables

**Files:**
- Modify: `deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md`
- Test: read-back of the file (documentation task - verification is a re-read, not a command)

**Interfaces:**
- Consumes: the counts from spec §1 (corrected) and §11.1.
- Produces: no code interface.

**Why this is a task and not a footnote:** spec §10 lists "the five uncovered classes are stated in the client deliverables" as a success criterion, and spec §8 requires the honest limitations to be *stated*, not implied away. A coverage claim that reaches a client without its gap is the failure this whole plan exists to prevent, in the other direction.

- [ ] **Step 1: Read the current file to find the insertion point**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
Select-String -Path 'deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md' -Pattern '^#|^##' | ForEach-Object { "  L$($_.LineNumber): $($_.Line.Trim())" }
```

- [ ] **Step 2: Add the coverage section**

Add a section stating the measured numbers, using this exact content (adjust only the heading level to match the file's existing structure):

```markdown
## Sanitizer coverage: measured, with the gaps named

Detection coverage is **10 of 15 `EntityType` classes** after step 1, not all.

| | Count |
|---|---|
| Classes defined | 15 |
| Covered before this work | 5 (rules) |
| Added by step 1 | 2 (Landline, IpAddress) |
| **Covered now** | **10** |
| Still uncovered | 5 |

Still uncovered, and not detected at all: `CaseNumber`, `BankAccount`,
`RegistrationNumber`, `PostalAddress`, `Credential`.

- `BankAccount` is the highest-value remaining follow-up.
- `CaseNumber` needs a context signal before it can be correct: the only
  available filter is a shape test that would exempt every candidate.
- `Credential` needs cross-chunk handling, because a key spans lines and
  chunk boundaries.

Also fixed in this work: four classes that were reported as covered were
**silently missing the common written form**. `手机13812345678` (no space) was
not detected, because the pattern required a word boundary that does not exist
between a Chinese character and a digit. Chinese text has no inter-word spaces,
so this was the normal case, not an edge case. Those four classes now match with
or without a separator.

**Pseudonymized, not anonymized.** Redaction is 去标识化 with a restorable
mapping, per the specification's section 10. It is not 匿名化.

**Recall is measured, not promised.** The research baseline for Chinese PII NER
is F1 ~0.76; 0.95-class recall is not claimed. The per-tier harness reports
rule-layer and model-layer recall separately.
```

- [ ] **Step 3: Verify the numbers against the code, not against memory**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
"=== EntityType variants (must be 15) ==="
(Select-String -Path 'pacgate-ai\crates\pacgate-redact\src\entity.rs' -Pattern '^\s{4}[A-Z][A-Za-z]+,\s*$' | Where-Object { $_.LineNumber -gt 35 }).Count
"=== entities TierOneDetector emits ==="
Select-String -Path 'pacgate-ai\crates\pacgate-redact\src\detect\rules.rs' -Pattern 'EntityType::(\w+)' -AllMatches |
  ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
```

Expected: **15** variants, and the emitted set is exactly `BankCard`, `CnMobile`, `CnResidentId`, `Email`, `IpAddress`, `Landline`, `Uscc` - **7** classes.

Both commands were run against the pre-change tree while writing this plan and returned `15` and `BankCard, CnMobile, CnResidentId, Email, Uscc` (the 5 before Tasks 3-4). So the 15 is a stable reading and the 5 -> 7 delta is the change this plan makes.

If the emitted list is not exactly those 7, the document is wrong - fix the document to match the code, never the reverse. The table's `5 (rules)` row is the pre-step-1 set and `2 (added)` is the delta; re-read the table against the emitted list before committing, and if the arithmetic does not close, fix the table.

- [ ] **Step 4: Commit**

```powershell
Set-Location c:\Users\cubecloud-io\github-pr\pacgate-ai-pr
git add deploy/AIPC1-SANITIZER-FINDINGS-AND-0.1.18.md
git commit -m "docs(aipc1): state measured sanitizer coverage and the four adjacency misses

10 of 15 classes after step 1, with the five uncovered ones named rather than
implied away. Records that four classes reported as covered were silently missing
the no-space form, which is the normal form in Chinese text."
```

---

## Self-Review

Run against spec §10.5, §10.6, §11.2, §11.3, §11.4.

**1. Spec coverage**

| Spec item | Task |
|---|---|
| §10.5 boundary predicate, rejects only ASCII-alnum | Task 1 |
| §10.5 applied to all four shipped classes | Task 2 (test asserts all four) |
| §10.5 trailing-CJK case (`手机13812345678号`) | Task 1 test, Task 5 fixture |
| §10.5 full-width digits | **Deliberately excluded** - §10.5 defers it with a reason (offset preservation). Not a gap. |
| §10.6 gate, exit-2 convention, `-p pacgate-redact` scope | Task 6 |
| §10.6 negative test | Task 6 Step 3 |
| §11.2 `Landline` + area-code exclusion | Task 3 |
| §11.3 `IpAddress` + `Ipv4Addr` + fifth-dot guard | Task 4 |
| §11.4 acceptance list | Tasks 2-5 (each row has a fixture) |
| §11.4 clippy ratchet | Task 6 |
| §10 success criterion: uncovered classes in client deliverables | Task 7 |
| §11.1 `CaseNumber` withdrawn | Not scheduled; plan states why in Global Constraints |

No spec requirement in scope is untasked.

**2. Placeholder scan**

No "TBD", no "add appropriate error handling", no "similar to Task N", no "write tests for the above". Every code step carries the literal code. Task 7 Step 2 carries the literal document content. The one place a step says "adjust only the heading level" is a formatting concession to the target file, not a content gap - the content itself is complete and literal.

**3. Type consistency**

- `is_bounded(text: &str, start: usize, end: usize) -> bool` - defined Task 1, called identically in Tasks 2, 3, 4.
- `Match` fields used: `start`, `end`, `entity`, `text` - all confirmed on `lib.rs:66-72`. `Match::len()` takes no argument (it uses `self`), so no call passes a length.
- `EntityType::Landline` / `EntityType::IpAddress` / `EntityType::BankCard` / `EntityType::CnMobile` / `EntityType::CnResidentId` / `EntityType::Uscc` - all confirmed present in `entity.rs`.
- `MatchSource::Pattern` and `MatchSource::Checksum` - both confirmed on `lib.rs:53-64`.
- `TierOneDetector::new()` returns `Self` with `include_email: true` - confirmed `rules.rs:51-53`. Task tests call `TierOneDetector::new().detect(...)`, matching the existing tests.
- `RE_LANDLINE` / `RE_IPV4_CANDIDATE` - new names, introduced in Tasks 3 and 4 respectively and not referenced before.
- `run(tier_one_detectors(), text)` in Task 5 - matches the existing helper signature in `tests/recall.rs`.
- `$gates` array in Task 6 - confirmed present at `run-all-checks.ps1:36`; `$liveStackGates` at line 128.
- `MAX_MATCHES` - untouched, still applied after all loops (Task 2-4 loops are inserted before the existing `if out.len() > MAX_MATCHES` check).

One inconsistency found and fixed during review: an earlier draft of Task 5 Step 2 said the new tests would fail, then Step 3 said they would pass, without explaining that both are correct depending on execution order. Resolved by stating explicitly that Tasks 2-4 have already made them pass and that the run is required reading either way.

A second, more substantive error was found and fixed by measurement rather than review: F3 originally said every `Landline` row depended on `is_bounded` only via CJK adjacency, and that the `0\d{2,3}` head rejected the over-long form. Direct measurement showed `座机010-123456789` matches `010-12345678` in the regex alone and is rejected only by `is_bounded`'s trailing-digit check. The consequence is stated in both documents: the predicate is load-bearing for `Landline` *precision*, and without it this detector would emit a truncated span that redacts a prefix and leaves the rest - worse than a miss, because it looks sanitized. The same correction was applied to spec §11.2.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-26-ner-step0-boundary-and-step1-detectors.md`.

**Two execution options:**

**1. Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration. The 7 tasks are cleanly separable: Tasks 1-4 are ordered edits to one file, Task 5 is a different file, Task 6 is a separate script, Task 7 is documentation.

**2. Inline Execution** - execute tasks in this session with checkpoints.

**Note the dependency ordering:** Task 2 requires Task 1 (the predicate). Tasks 3 and 4 each require Task 1. Task 5 requires Tasks 2-4 for its assertions to pass. Task 6 gates Tasks 1-5 but does not depend on them being complete. Task 7 requires the final counts, so it runs last.
