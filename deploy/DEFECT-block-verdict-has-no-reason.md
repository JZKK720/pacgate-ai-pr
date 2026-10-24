# DEFECT (HIGH): a `block` verdict records no reason, so nobody can clear it

**Found:** 2026-10-24, while ingesting the firm's own material into "Firm Knowledge Base".

**Status:** FIXED in `pacgate-redact/src/ledger.rs` and `pacgate-api/src/sanitize.rs`.
Gated by `a_block_ledger_records_why_it_blocked` in `ledger.rs`.

## The observation

Ingesting 13 firm documents produced:

| verdict | documents | chunks |
|---|---|---|
| pass | 8 | 76 searchable |
| **block** | **5** | **284 unsearchable** |

The five blocked documents included the single most relevant one for the
question that started this - `合规律师实用Prompts指南` (72 chunks), which is the
firm's own compliance-prompt methodology.

What the reviewer got back:

```json
{
  "verdict": "block",
  "reason": "T3 (project-specific) has residue after redaction, so it is held for review",
  "redaction_count": 188
}
```

And the ledger:

```json
{"job_id":"...","verdict":"block","redaction_count":188,"ruleset_version":"0.2.3"}
```

That is the entire record. It says a block happened. It does not say **what**
survived, **which entity** it was, or **where**. The only way to clear one was to
reset the row in Postgres by hand:

```sql
update kb_chunks set sanitization_state='pending' where document_id='...' and sanitization_state='blocked';
```

## Root cause

`verify_reduced` computes exactly the right evidence. `Verification` carries:

```rust
pub struct Verification {
    pub verdict: Verdict,
    /// What survived. Surfaced to the review panel, never auto-cleared.
    pub residue: Vec<Match>,
    /// Why the verdict was reached, for the audit record.
    pub notes: Vec<String>,
}
```

The doc comment says the residue is "Surfaced to the review panel". It was
surfaced **nowhere**. `RedactionLedger::seal` took `&Verification`, read
`verification.verdict`, and dropped the other two fields on the floor:

```rust
verdict: verification.verdict,
ruleset_version: env!("CARGO_PKG_VERSION").to_string(),
model_version: None,
// residue and notes: gone
```

`JobOutcome` then carried only `reason: outcome.decision.reason`, which is a
generic sentence chosen by `policy.rs` from the data level - it never mentions
the residue either.

So the pipeline computed the answer, used it to decide, and threw it away.

## Why this matters more than it looks

A block is a **refusal to release a document**. In a legal product that is a
high-consequence action, and an unexplained refusal is indistinguishable from a
bug. Three concrete costs:

1. **The reviewer cannot act.** "Residue after redaction" does not say whether
   the survivor is a client ID (a real leak, must fix) or a false positive on a
   place name (safe to clear). Both produce the same sentence.
2. **The block is terminal.** `MARK_BLOCKED_SQL` only promotes rows that are
   `pending`, so a blocked row can never be re-sanitized by a later run. Without
   the reason, the only recovery is manual SQL - which is what actually happened
   here.
3. **It hides a real defect.** While investigating, the redactor was observed
   redacting `非洲`, `韩国`, `上海` as `LOCATION` - over-matching on ordinary
   geography in a compliance document. That is worth knowing, and the ledger
   gave no way to see it.

## The fix

`RedactionLedger` now records the evidence it was already computing:

```rust
#[serde(default, skip_serializing_if = "Vec::is_empty")]
pub residue: Vec<ResidueEntry>,          // entity, text, start, end
#[serde(default, skip_serializing_if = "Vec::is_empty")]
pub verification_notes: Vec<String>,     // the verifier's own explanation
```

`JobOutcome` surfaces both, so the API response carries them too.

Both fields are `skip_serializing_if = "Vec::is_empty"`, so **a passing ledger is
byte-identical to before** - no consumer sees a new field on the happy path.

### On storing the surviving text

The ledger header says it stores "digests only ... without retaining the
pre-transformation content", so the ledger cannot become a second copy of client
data. A residue entry is the opposite case: it is text the redactor **failed** to
remove, so it is already present in the output the reviewer is holding. Not
recording it protects nothing and makes the block unactionable. The rule is
about not duplicating *removed* content; this is *surviving* content.

## Verification

- New test `a_block_ledger_records_why_it_blocked`: **fails** before the fix
  (ledger JSON contains no `residue`), **passes** after.
- `cargo test -p pacgate-redact`: 154 passed, 0 failed.
- `cargo test -p pacgate-api`: 120 passed, 0 failed.
- `cargo test --workspace`: **342 passed, 0 failed**.

## Residual risk

- **The fix is not live yet.** `pacgate-api` runs the published image
  `ghcr.io/jzkk720/pacgate-api:0.2.3`; this is a Rust change, so it needs a
  rebuild and republish before the running stack returns the new fields. The
  MCP-layer fix (`kb_search` empty signal) *is* live, because `server.py` is
  bind-mounted.
- The five blocked documents remain blocked. They can now be diagnosed, but
  clearing them still requires a decision about whether the residue is a real
  leak or a false positive - which is exactly the judgement the ledger now
  supports and previously did not.
- The `LOCATION` over-matching (`非洲`, `韩国`, `上海`) is a **separate** defect,
  now visible but not fixed. It is worth its own investigation: redacting
  ordinary geography in a compliance document destroys meaning without
  protecting anyone.
