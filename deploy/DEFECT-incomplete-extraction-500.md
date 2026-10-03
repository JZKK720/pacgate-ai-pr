# DEFECT (LOW): "extraction incomplete" refuses with 500, not a 4xx

**Found:** 2026-10-03, while verifying that the local stack was alive. Not
introduced by 0.1.22; the line dates to `97a4350` (2026-09-19).

**Status:** OPEN, deliberately NOT fixed. Low severity, already documented.

## The observation

`pacgate-api` logs `tower_http::trace::on_failure: ... Status code: 500 Internal
Server Error` during normal E2E runs. Quantified: **15 responses in 6 hours**.
Every one traces to a single refusal path.

## Root cause

`sanitize.rs:125-130`:

```rust
if extracted.incomplete {
    // Fail closed: never sanitize against an incomplete extraction.
    return Err(ApiError::internal(
        "extraction incomplete; document stays pending",
    ));
}
```

`ApiError::internal` is a **500**. The *behaviour* is correct and must not
change: refusing to sanitize against an incomplete extraction is the fail-closed
decision that stops an unreadable document being marked sanitized and released.
The *status code* is what is wrong.

## Why 500 is the wrong code

`ApiError` already has the right vocabulary, and this condition is neither a
server fault nor an unknown one. It is deterministic, reproducible, and
client-actionable: the uploaded document could not be read, so the caller should
re-upload a readable one. A 500 says "we broke"; the truth is "we could not read
what you sent". Two concrete costs:

1. **Monitoring.** All three services sit behind nginx; an alert on 5xx (the
   standard signal) fires on the *expected* outcome of a blank-page upload. That
   is alert fatigue on a legal-matter system, and it also masks a genuine 500
   appearing in the same stream.
2. **The client contract.** An attorney integrating against this API would be
   told to retry a non-transient condition, because the retry semantics of 5xx
   imply the request could succeed later. It cannot; the same bytes produce the
   same refusal.

The honest codes available today: `unprocessable` (422) - well-formed but out of
scope, which is what `ApiError::unprocessable` is documented for - or
`bad_request` (400). Not `service_unavailable` (503), which would misattribute it
to capacity.

## Why it was not fixed here

- **It is already known.** `scripts/probe-ocr-suffix.py` states it in its own
  docstring: *"extract returns incomplete=true, 0 chars, and sanitize then
  refuses with 500"*. The probe exists to discriminate WHERE the failure happens,
  not to flag the status code. So this is a documented characteristic, not a new
  discovery, and there is no evidence anyone is relying on the 500 by mistake.
- **Changing a status code is a client-visible contract change.** It belongs in a
  release with its own note, not folded into a verification pass.
- **The security property is intact either way.** Verified all four directions:
  A1 blank page, A2 partial read, and A3 empty-text-with-complete-claiming-record
  are each REFUSED for both sanitize and download, with a readable-page CONTROL
  that is ALLOWED - so the gate opens when it should. `15 of 15 checks passed`.

## The test that currently hides it

`scripts/test-empty-extraction-gate.ps1` asserts:

```powershell
Check "$Label - sanitize is REFUSED (not 200)" ($sanitizeStatus -ne 200)
```

`-ne 200` is true for 500, 422, 403 and every other non-200, so the gate is
satisfied by exactly the wrong code and would stay green through the fix. It is
*deliberately* loose - the property under test is "refused", not "refused with
code X" - but it means this change has no failing test to drive it.

## If it is fixed later

1. Add the failing test FIRST: assert the refusal is a 4xx (`>= 400 -and < 500`)
   and that it is specifically 422, alongside the existing not-200 assertions.
2. Change `ApiError::internal` -> `ApiError::unprocessable` at `sanitize.rs:127`.
3. Re-run `test-empty-extraction-gate.ps1` (should stay 15/15) and
   `test-text-native-sanitize.ps1` (59 checks - it exercises the incomplete path
   and states in its header that PaddleOCR *"raises, and reports incomplete"*).
4. Update `probe-ocr-suffix.py`'s docstring, which currently records the 500.
5. Check the deer-flow frontend's error rendering against a 422 rather than a 500.
