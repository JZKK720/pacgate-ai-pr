# AIPC #1 — Sanitizer Lane Findings & 0.1.18 Update

> **Copy everything below into a fresh agent session on AIPC #1.**
> Written 2026-09-26 from the dev box. Evidence is measured, not assumed.

---

## Mission

1. Update AIPC #1 from **0.1.17 → 0.1.18**.
2. Provision the two deer-flow agents that **no install path creates**.
3. Confirm the sanitizer lane works, and report whether any document was
   **wrongly marked sanitized** under 0.1.17.

Read the whole document before running anything. Steps 1 and 2 have an ordering
constraint that matters.

## Why 0.1.18 is not optional here

AIPC #1 is on **0.1.17**, which predates Plan B. On 0.1.17, **every non-PDF
format fails to sanitize** and the document is pinned at `pending`:

```
.doc/.docx/.xlsx/.pptx/.txt/.md/.html -> ocr-service -> rasterisation fails
                                      -> OCR reports incomplete
                                      -> fail-closed guard keeps it pending
```

The mechanism: `pacgate-api` uploads to ocr-service with
`file_name("document")` and `mime application/octet-stream` (no extension), so
`_prepare_pages` defaults to `.pdf` and PaddleOCR gets raw bytes instead of an
image. Measured on 0.1.17; the exact error is
`ocr-service returned 500; extraction is incomplete, document stays pending`.

**0.1.18 fixes this.** Plan B routes text-native formats to `extract_text_native`
so they **never reach OCR**. Verified on the updated dev box: the `.txt` case
(upload → extract → sanitize, identifiers present) passes end to end, and the
whole text-native gate is 59/59.

So: on 0.1.17 the text lane is broken by design-defect. On 0.1.18 it works.
Do not spend time debugging the text lane until the box is on 0.1.18.

## STEP 1 — run the sanitization audit FIRST, before updating

This is the one irreplaceable step. `audit-false-sanitized.ps1` reports documents
that were marked `sanitized` while their text was never actually read. That is
the **only** red-line failure. Once you update, the state moves and the evidence
is harder to reconstruct.

Run it inside `deploy/client-bundle` (it reads the live API and the DB):

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
pwsh -NoProfile -File ..\..\scripts\audit-false-sanitized.ps1
```

Exit codes: **0** = no exposure, **1** = exposure found (STOP, report it),
**2** = could not check (say so, do not report a pass).

If it exits 1, **stop and report before updating anything.** A document that
contained client identifiers and was marked sanitized is a disclosure event, not
a bug ticket.

## STEP 2 — update the repo and the stack

```powershell
cd C:\pacgate-ai-pr
git status --porcelain --untracked-files=no   # must be EMPTY
git fetch origin
git log -1 --format="%h %s" origin/main      # expect: 06b1817 test(release): pre-flight gate...
git pull --ff-only origin main

cd deploy\client-bundle
pwsh -NoProfile -File .\install.ps1 -Update
```

`install.ps1 -Update` pulls the 0.1.18 images and restarts. All five are public
at `ghcr.io/jzkk720/*:0.1.18` — no `docker login` needed, and **no local build**.

Then verify the update actually took:

```powershell
docker inspect -f '{{.Config.Image}}' pacgate-api        # expect ...:0.1.18
(Invoke-WebRequest http://localhost:8089/version -UseBasicParsing).Content
# expect {"revision":"12b21fb...","version":"0.1.18"}
```

`install.ps1` prints its own version check; if it prints anything other than
0.1.18, stop and report.

## STEP 3 — provision the two missing agents

**This is very likely why "the sanitizer agent is not working": it does not
exist.** Verified: `install.ps1` contains no reference to `sanitizer`, and
**nothing in the repo calls either `provision.ps1`.** Agent creation is manual
and undocumented. `deploy/client-bundle/data/` is **gitignored**, so a fresh
machine gets no agents at all.

Two agents are needed, not one — both are part of the sanitizer/OCR workflow:

| Agent | Script | SOUL |
|---|---|---|
| `sanitizer` | `deploy/sanitizer-agent/provision.ps1` | `deploy/sanitizer-agent/SOUL.md` |
| `ocr-extractor` | `deploy/ocr-agent/provision.ps1` | `deploy/ocr-agent/SOUL.md` |

Both scripts are idempotent (create or update). Run from the repo root:

```powershell
$env:DEER_FLOW_EMAIL    = '<the deer-flow account email>'
$env:DEER_FLOW_PASSWORD = '<its password>'
pwsh -NoProfile -File deploy\sanitizer-agent\provision.ps1
pwsh -NoProfile -File deploy\ocr-agent\provision.ps1
```

Expected output: `OK: sanitizer agent created` (or `updated`), same for
`ocr-extractor`.

**If provisioning fails, the error text tells you which layer:**

| Symptom | Cause |
|---|---|
| `deer-flow credentials required` | env vars not set |
| `deer-flow login failed (HTTP 403)` + `CSRF` | the known 403 — the script already handles CSRF; a 403 here means the login route or CORS origin, not CSRF |
| `login failed (HTTP 404)` on both route shapes | wrong `-DeerFlowUrl`; use the host port `http://127.0.0.1:8089` |
| 400/409 on create | pre-existing agent with a conflicting name; the script falls back to PUT, so a 4xx here is worth reporting verbatim |

You do **not** need to pass `-Email`/`-Password` if the env vars are set.

**Why ordering matters:** do the audit (step 1) before the update (step 2), and
the provisioning (step 3) after both. Provisioning writes into
`data/deer-flow/...`, which the update recreates containers around; running it
after is the safe order.

## STEP 4 — prove the lane works (the acceptance test)

After provisioning, prove the lane end to end rather than trusting the UI. The
gate is the strongest evidence available and it is **format-agnostic**:

```powershell
pwsh -NoProfile -File scripts\test-text-native-sanitize.ps1
```

Expect **RESULT: 59 of 59 checks passed**, exit 0. This drives real uploads
(`.txt`, `.md`, `.docx`, `.xlsx`, `.pptx`, a `.pdf` control) and asserts the
sanitized output carries neither identifier.

The gate reads `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD` from
`deploy/client-bundle/.env`. It needs both present, or it exits 2 with
`credentials file not found` / `not present in .env` — report that rather than
working around it.

> **Do not `Get-Content` or `Select-String` that `.env` file.** A non-`-Quiet`
> grep on it has already leaked a password once in this work. To check presence
> without printing anything, use only:
> `[bool](Select-String -Path deploy/client-bundle/.env -Pattern 'PACGATE_API_PASSWORD=' -Quiet)`

Then the two live-stack gates:

```powershell
pwsh -NoProfile -File scripts\test-empty-extraction-gate.ps1   # expect 15/15
pwsh -NoProfile -File scripts\run-all-checks.ps1               # expect ALL 24 GATES PASSED
```

## Sanitizer coverage: measured, with the gaps named

Rules detect **7 of 15 `EntityType` classes** as of this build. The gaps are
named below rather than implied away.

| | Count |
|---|---|
| Classes defined | 15 |
| Detected by rules before this work | 5 |
| Added by this work | 2 (Landline, IpAddress) |
| **Detected by rules now** | **7** |
| Detectable only with the NER model, not yet enabled | 3 (PersonName, OrgName, Location) |
| **Detected once NER is enabled** | **10** |
| Undetected in either configuration | 5 |

Undetected: `CaseNumber`, `BankAccount`, `RegistrationNumber`, `PostalAddress`,
`Credential`.

> **Read the two totals as one deliverable and one roadmap figure. 7 is what this
> build does.** 10 requires enabling the NER model, which is separate work. Do
> not present 10 as shipped.

- `BankAccount` is the highest-value remaining follow-up.
- `CaseNumber` needs a context signal before it can be correct: the only
  available filter is a shape test that would exempt every candidate.
- `Credential` needs cross-chunk handling, because a key spans lines and
  chunk boundaries.

### Fixed in this work: four classes were missing the normal written form

Four classes that were reported as covered were **silently missing the common
form**. `手机13812345678` (no space) was not detected, because the pattern
required a word boundary that does not exist between a Chinese character and a
digit. Chinese text has no inter-word spaces, so this was the normal case, not an
edge case. Those four classes now match with or without a separator immediately
adjacent to a Chinese character:

```
手机13812345678            身份证11010519491231002X
代码91350100M000100Y43     卡号4111111111111111
```

Before the fix each of those returned **zero** matches while `verify()` replayed
the same detectors and returned `Pass` — so the document was marked `sanitized`
with the identifier intact.

### Also fixed in this work: grouped digits and full-width writing

Identifiers written with **grouped digits** and with **full-width characters** are
now detected, where before they were not:

```
卡号4111 1111 1111 1111                 卡号4111-1111-1111-1111
身份证110105 19491231 002X              手机138 1234 5678
卡号４１１１１１１１１１１１１１１１       身份证１１０１０５１９４９１２３１００２Ｘ
```

Grouping and full-width forms are how these numbers appear on cards, in contracts
and after a word processor has touched a document, so an ungrouped-only detector
missed a normal case. Detection now runs against a separator-stripped,
full-width-folded copy of the text and maps each match back to the original byte
range, so the redacted output replaces the whole value including its separators.

**A partial result must not be read as a general one.** These are the limits, and
they are deliberate:

- **A space-grouped landline** (`010 12345678`) is **not** detected. Removing the
  separator makes that string identical in shape to the valid
  `075512345678` (both 12 digits), and the two cannot be told apart by shape
  alone. A miss on a rare spacing is preferable to redacting an unrelated 12-digit
  number that happens to start with `0`.
- **A 12-digit number whose leading digits form a real area code** can still be
  read as a landline. `050123456789` is area code `501` plus an 8-digit
  subscriber, which is a valid shape. Only unallocated prefixes such as `020` and
  over-long forms are rejected structurally. This is honest precision/recall
  behaviour on an ambiguous format, not a defect.
- **Full-width detection covers digits and Latin letters** (which the resident-ID
  check character `Ｘ` needs). Other full-width punctuation is not folded.

**Pseudonymized, not anonymized.** Redaction is 去标识化 with a restorable
mapping, per the specification's section 10. It is not 匿名化.

**Recall is measured, not promised.** The research baseline for Chinese PII NER
is F1 ~0.76; 0.95-class recall is not claimed. The per-tier harness reports
rule-layer and model-layer recall separately, and the model layer skips loudly
when the weights are absent.

## What is EXPECTED and must not be reported as a fault

Four different states get conflated when people say "the sanitizer is broken".
Only the last is a real finding.

1. **The `sanitizer` agent does not exist on a fresh machine.** Expected —
   provisioning is manual (step 3). Not a defect in the sanitizer.
2. **Non-PDF documents fail to sanitize on 0.1.17.** Expected on that version,
   and fixed by 0.1.18. Not a sanitizer defect.
3. **`ocr-service returned 500; extraction is incomplete, document stays
   pending`.** This is the fail-closed guard **working**. A document that cannot
   be read must not reach a verdict. The 500 is deliberate
   (`sanitize.rs:125` → `ApiError::internal(...)`). It is a *user is blocked*
   problem, not a *redaction failed* problem.
4. **A `pass` verdict on a document that actually contained client
   identifiers.** **This is the only red line.** If you see it, stop and report
   with the document id, its format, and the verdict.

Also note: `.doc`, `.rtf`, `.wps`, `.eml` are **not supported** — the upload
allowlist accepts `.docx .xlsx .pptx .pdf .txt .md .html`. An unsupported format
is rejected at upload with its own message; that is a coverage gap, not a
sanitizer fault.

## STEP 5 — report back

Send all of the following, even if they look fine:

- `audit-false-sanitized.ps1` exit code and any document ids it named
- `install.ps1 -Update` version line, and `docker inspect` image tags for all
  five services
- The two `provision.ps1` outputs, verbatim (created vs updated, or the error)
- `test-text-native-sanitize.ps1` result count and exit code
- `run-all-checks.ps1` final line and exit code
- **If you hit a failure:** the exact command, its exact output, and whether the
  same command succeeded on the dev box. Do not summarise the error — paste it.

## Two traps worth knowing before you start

- **`docker compose run` leaves a stray container.** If you use it for a one-off,
  `docker rm -f` it afterwards. Seen on the dev box.
- **`test-staleness-probe.ps1` will fail between the repo pull and the container
  restart**, because the repo pins 0.1.18 while the containers are still 0.1.17.
  It self-resolves after the update. If it still fails **after** the update,
  that is a real signal.

## Reference — what 0.1.18 contains

| Change | Effect on this machine |
|---|---|
| Plan A — OCR fail-closed | A page with no text now reports `incomplete` instead of a false "complete" |
| Plan B — text-native coverage | `.txt/.md/.docx/.xlsx/.pptx/.html` sanitize instead of pinning at pending |
| Plan C — tier roster as config | `PACGATE_MODEL_MAIN/MID/LOW`; the API logs `LLM tiers:` at startup |
| OOXML fail-closed | An unopenable archive entry no longer reports the read as complete |
| Chat-lane egress | Auto-escalation target is LOCAL, not a cloud model |
| Migration 008 | Applies automatically at API startup |

All of these are already in the 0.1.18 images. There is nothing to build.
