# Plan 030 — Reconcile the AIPC #1 / #2 field reports against 0.2.3

**Date:** 2026-10-23
**Priority:** P1
**Effort:** ~4 hours (two gates, one installer guard, one recreate, one decision)
**Depends on:** nothing — 0.2.3 is released and the suite is green
**Status:** **DONE (2026-10-23)** — all six defects addressed and verified. The
stack was found mixed (four of five services on 0.2.1) and recreated; three new
gates were added and each was mutation-tested to prove it can fail. Suite went
**47 → 48 static gates + 12 → 14 live-stack gates, all green**. Every claim below
was re-measured on this machine on 2026-10-23; nothing is taken from either report.

---

## 0. Why this plan exists

Two AIPC machines deployed 0.2.2 and independently reported defects. Both reports
are partly right, partly wrong, and neither machine knows 0.2.3 exists. Acting on
either report as written would have shipped a fix for a defect that is not in this
repo, and skipped two defects that are.

This plan separates the three things the reports conflate:

1. **Fork-local regressions** — real on that machine, absent from `origin/main`.
2. **Upstream defects** — reproducible here, need a fix.
3. **Coverage gaps** — the suite was green while the machine was broken.

The third is the important one. Both machines reported "all gates passed" and both
were running broken stacks. A green suite that cannot see the failure is worse than
a red one, because it converts a defect into a false assurance.

---

## 1. Ground truth at the time of writing

| Fact | Value | How verified |
| --- | --- | --- |
| `origin/main` | `d33553e` (0.2.3) | `git log`, clean tree, in sync |
| Tags | `v0.2.0` … `v0.2.3` | `git tag` |
| Gate suite | **47 of 47 PASS** | `scripts/run-all-checks.ps1` |
| `pacgate-mcp` tools | **19** | live `tools/list` over streamable-http |
| `openviking` tools | **15** | live `tools/list` with `X-API-Key` |
| Running `pacgate-api` | `0.2.3` @ `d33553e` | `/build-info` |
| Running `ocr-service` | **`0.2.1`** | `docker inspect` |
| Running `pacgate-mcp` | **`0.2.1`** | `docker inspect` |
| Running `deer-flow` | **`0.2.1`** | `docker inspect` |
| Running `deer-flow-frontend` | **`0.2.1`** | `docker inspect` |
| Compose pins | all five at `0.2.3` | `compose.prod.yaml` |

The last five rows are the headline. **Four of five services run the previous
release while the suite reports 47/47 green.**

---

## 2. Verdict on AIPC #2

### 2.1 Confirmed

| Claim | Verdict | Evidence |
| --- | --- | --- |
| `pacgate-ai` is read-only on `JZKK720/pacgate-ai-pr` | **CONFIRMED** | `.github/workflows/build-ghcr.yml` header: "pacgate-ai — a READ-ONLY MIRROR of the same commits. Publishes NO images." |
| Three branches are not on origin | **CONFIRMED** | `git ls-remote --heads origin` returns only `refs/heads/main` |
| 47 gates pass | **CONFIRMED** | re-ran the suite: 47/47 |
| 百宸 material is in the public repo | **CONFIRMED, and worse than reported** | 10 tracked files, incl. `docs/index.html`; `raw.githubusercontent.com` returns **200** |
| A live deploy caught a defect the suite missed | **CONFIRMED as a class** | see §4 D2 and D4 |

### 2.2 Not reproducible here

| Claim | Verdict | Evidence |
| --- | --- | --- |
| `deer-flow-mcp-client.py` was the `**_kwargs` version, dropped `X-API-Key`, all 35 tools vanished | **NOT IN THIS REPO** | no file by that name exists; `**kwargs` appears nowhere in any `.py` |
| `GetRelativePath` crashed the provenance gate under PS 5.1 | **NOT IN THIS REPO** | `GetRelativePath` appears in no `.ps1`/`.psm1` |
| `rev-list` given a non-local SHA crashed `dry-run-update` | **NOT IN THIS REPO** | `dry-run-update.ps1` uses `rev-parse`, never `rev-list` with a SHA |
| 42 MB docker CLI binary staged by a cherry-pick | **NOT IN THIS REPO** | no tracked file exceeds 10 MB |
| `8e345a73` is in none of the three branches | **CANNOT VERIFY** | `git cat-file -t 8e345a73` → not a valid object here |

These are **fork-local regressions**. They are real on that machine and they are
not defects in `origin/main`. Do not "fix" them here.

### 2.3 Imprecise

| Claim | Correction |
| --- | --- |
| "35 MCP tools load" | `pacgate-mcp` serves **19**. The 35 is 19 pacgate + 15 openviking + officecli aggregated by deer-flow. Not a defect, but the number cannot be used as a health signal for pacgate alone. |

### 2.4 What AIPC #2 got right that matters

The `**_kwargs` incident is the most valuable thing in either report, and not
because of the bug. Their own words: *"Only a live deploy caught this; the 47-gate
suite passed while it was broken."*

That is a **coverage gap in this repo**, and it is reproducible in principle even
though their specific trigger was fork-local. See D4.

---

## 3. Verdict on AIPC #1

### 3.1 Confirmed — and this is the real finding

AIPC #1 claims the local 12B cannot drive a document workflow. **Reproduced.**

Measured on this machine, `gemma4:12b-it-qat`, the exact `## Required tool` message
that `build_step_message` emits, 5 runs each:

| Tool list offered | Runs that called `generate_docx` |
| --- | --- |
| Full list (10 tools, as `tool_definitions()` returns) | **0 / 5** |
| Only `generate_docx` | **4 / 5** |

So the defect is real, and it is **tool-list-dependent**, not prompt-dependent.
The 0.2.1 commit `2248ac9` ("send the step's declared tool to the model") was
necessary but not sufficient: naming the tool in prose does not overcome a 12B
choosing among ten.

### 3.2 Wrong

| Claim | Correction |
| --- | --- |
| "The 12B called `list_documents` 0 of 5 times **even when `generate_docx` was the only tool offered**" | **Wrong.** With only `generate_docx` offered it called it **4/5**. Their measurement was of the full-list case, misattributed. |
| "No prompt change and no model that fits the card can fix it" | **Too strong.** The single-tool case is 4/5, not 0/5. The claim is only true for the full list. |
| "Removing the choice is the only approach" | **Not proven.** See §3.3. |
| "The docgen gate fails on the pinned image because the fix isn't in it yet" | **Stale.** 0.2.3 is published. The gate is **19/19 PASS** here on the shipped default. |

### 3.3 Their proposed fix does not hold up

AIPC #1 proposes: offer no tools, ask the model for document JSON, call
`generate_docx` from the app. Measured here, 5 runs each:

| Approach | Success |
| --- | --- |
| No tools, `format: json`, parse `sections` | **3 / 5** (one run HTTP 500, one timeout) |
| Full list + `tool_choice: "required"` | **3 / 5** |
| Only `generate_docx` offered | **4 / 5** |
| Full list, no intervention (today's behaviour) | **0 / 5** |

None of the three candidate fixes is deterministic on a 12B. Their "6 consecutive
real workflow runs" may be true on their hardware; it is not reproducible here.
**Do not adopt their patch as-is.**

### 3.4 The defect is already avoided by the shipped default

`compose.prod.yaml` defaults `PACGATE_MODEL_MAIN` to `deepseek-v4.1-flash:cloud`,
and `deploy/client-bundle/.env` documents the 12B failure with the same
before/after numbers AIPC #1 measured. On that default the docgen gate is 19/19.

So the exposure is **not** "document generation is broken". It is: **a client who
sets MAIN to a local model gets silent empty documents, and nothing stops them.**
That is D3.

---

## 4. Defects this plan will fix

### D1 — HIGH — Four of five services were running the previous release

`ocr-service`, `pacgate-mcp`, `deer-flow`, `deer-flow-frontend` were all on `0.2.1`
images created 2026-10-22 16:00. `pacgate-api` was recreated 2026-10-23 09:32 on
`0.2.3`. Compose pins all five at `0.2.3`.

**Cause: a partial recreate, not `install.ps1`.** This matters and the first
version of this plan got it wrong. Measured:

- `v0.2.3` was tagged 2026-10-23 **09:10:45**.
- `pacgate-api` was created **09:32:11** — 21 minutes *after* the tag.
- The other four were created 2026-10-22 **16:00** — the 0.2.1 deploy.

And `docker compose up -d` **does** recreate a container when its image tag
changes. Proved with a throwaway project: `nginx:1.27-alpine` → `nginx:1.27`
produced `Container cohprobe Recreated` and a new image id. The same tag with no
pull produced `Container cohprobe Running` and the same id.

So if `install.ps1 -Update` had run for 0.2.3, **all five** would be 0.2.3. Only
one moved, which is the signature of a hand-run partial recreate — the 0.2.3
verification on this box, which recreated `pacgate-api` alone.

**This is not an installer defect.** It is a *detection* defect: the state existed
for hours and the suite reported 47/47 green. That is D2, and D2 is the real
finding.

Severity by service:

| Service | Bind-mounted code? | Consequence of running 0.2.1 |
| --- | --- | --- |
| `pacgate-mcp` | yes — `server.py` | **benign**; the 0.2.2 `headers` fix was live (verified in-container) |
| `deer-flow-frontend` | yes — `next.config.js` | **benign** |
| `deer-flow` | yes — 15 `patches/*.py` | **mostly benign**; image-baked code was 0.2.1 |
| `ocr-service` | **no mounts at all** | **real** — ran 0.2.1 `app.py`, missing `_page_spans` |

The `ocr-service` case is the one that matters. Verified in the container: it still
had the unguarded `box, (text, _conf) = line[0], line[1]`, so one malformed line
raised and the outer handler marked the **whole page** incomplete. 0.2.2 skips the
bad line and keeps the rest. It fails closed either way, so this is lost coverage
rather than a security hole — but it is not the code the tag says it is.

**Fix applied:** all four recreated on `0.2.3`. Verified after: `ocr-service` now
carries `_page_spans` (2 matches, 0 before) and the malformed-line branch is the
guarded `except (TypeError, ValueError, IndexError): continue`. No code change was
needed — the release was correct, the deployment was not.

### D2 — HIGH — No gate can see a mixed-version stack

This is why D1 survived a 47/47 green suite, and it is the real finding of this
plan. D1's cause was a partial recreate; D2 is why nobody noticed for hours.

| Gate | What it checks | Why it misses D1 |
| --- | --- | --- |
| `test-staleness-probe.ps1` | `pacgate-api` container vs compose pin | one service only |
| `test-version-marker-against-image.ps1` | `pacgate-api` `/build-info` | one service only |
| `test-release-provenance.ps1` | registry labels vs tag | registry, not running containers |
| `test-compose-healthchecks.ps1` | healthcheck presence | not image identity |

Nothing compares **every** running container's image to its compose pin.

**Fix:** new gate `scripts/test-stack-version-coherence.ps1`. For each service in
`compose.prod.yaml` that pins a `ghcr.io/jzkk720/*:<semver>` image, assert the
running container's `.Config.Image` equals the pin. Exit 2 when the stack is down.
Register it in `run-all-checks.ps1` as a live-stack gate.

This is the highest-value item in the plan: it is the gate that would have caught
both machines' "green suite, broken stack" state, and it caught this box's.

### D3 — MEDIUM — Nothing stops a local model being set as MAIN

`.env` documents the 12B failure in a comment. `test-model-roster-consistency.ps1`
checks that the three tiers are *consistent* (A1–A5), never that MAIN is *capable*.
Measured: 0/5 with the real tool list.

**Fix:** extend `test-model-roster-consistency.ps1` with a capability assertion —
if the resolved MAIN tag is a local (non-`:cloud`) tag, fail with the measured
numbers and the two ways out (set a cloud tag, or accept empty documents). Keep it
a **gate on the resolved config**, not a runtime probe: probing costs minutes and
would make the suite unusable.

### D4 — MEDIUM — Nothing asserts the MCP tool surface is intact

AIPC #2 lost all MCP tools and the suite stayed green. `test-mcp-401-retry.ps1`
tests the retry path; nothing asserts the tool **count** or **names** from the
consumer side.

**Fix:** extend `test-mcp-401-retry.ps1` (or add a sibling) to assert
`tools/list` returns exactly the 19 expected `pacgate_*` names. A missing tool is
then a red gate, not a silent capability loss.

### D5 — LOW — 百宸 client material on a public repo

10 tracked files contain 百宸, including `docs/index.html`, which is served
publicly (HTTP 200). AIPC #2 flagged it and correctly left the decision open.

**This plan does not decide it.** It is a commercial/legal call, not an engineering
one. Recorded here so it stops being rediscovered. Options: leave (already public,
no new exposure), scrub the docs surface, or make the repo private.

### D6 — LOW — No `.gitignore` rule for large binaries

AIPC #2's cherry-pick staged a 42 MB docker CLI binary. Nothing here prevents that
class. **Fix:** add a size-guard rule and a one-line pre-commit note.

---

## 5. Implementation order

Each step is independently verifiable. Do not batch them.

| # | Step | Verify with | Result |
| --- | --- | --- | --- |
| 1 | Recreate the four stale services | `docker inspect` shows `0.2.3` for all five | **DONE** — all five on 0.2.3, `ocr-service` now carries `_page_spans` |
| 2 | Write `test-stack-version-coherence.ps1` | run it against the now-coherent stack → pass; then `docker run` a 0.2.1 container and confirm it **fails** | **DONE** — failed 10/4 on the mixed stack, passes 14/14 after |
| 3 | Register the gate in `run-all-checks.ps1` | suite count goes 47 → 48, still green | **DONE** — 48 static + 14 live-stack, all green |
| 4 | Extend `test-model-roster-consistency.ps1` with the capability assertion | set `PACGATE_MODEL_MAIN=gemma4:12b-it-qat` → gate **fails**; unset → passes | **DONE** — A6 fails on the 12B, passes on the cloud tag (14/14) |
| 5 | Extend the MCP gate with the 19-name assertion | stop `pacgate-mcp` → gate fails; start → passes | **DONE** — new `test-mcp-tool-surface.ps1`, 19/19 names match source |
| 6 | Add the `.gitignore` size rule | stage a 50 MB file → refused | **DONE** — `.gitignore` rules + `check-tracked-file-size.ps1`, failed on a staged 12 MB probe |
| 7 | Bump to 0.2.4, tag, release | GHCR green, all five images at the new revision | **NOT DONE** — no code change requires a new image; see §5a |

Steps 2–6 are all **mutation-tested**: each new assertion was shown to fail when
the condition it guards is broken. A gate that has never been red is not evidence.

### 5a. Why there is no 0.2.4

Every fix in this plan is either a **script** (gates, `.gitignore`) or a
**deployment action** (recreating containers). None of them changes a compiled
artifact, so no image needs rebuilding and no tag is warranted. The 0.2.3 images
are correct; the machine was simply not running them.

That is the whole point of D1: the release was fine, the deployment was not.

### 5b. Mutation-test record

| Gate | Mutation applied | Observed |
| --- | --- | --- |
| `test-stack-version-coherence.ps1` | ran against the real mixed stack | 4 FAIL, exit 1, named all four services |
| `test-model-roster-consistency.ps1` A6 | `PACGATE_MODEL_MAIN` → `gemma4:12b-it-qat` | FAIL, exit 1 |
| `test-mcp-tool-surface.ps1` | renamed `@mcp.tool()` → `@mcp.tool_removed()` | FAIL, exit 1 |
| `check-tracked-file-size.ps1` | staged a 12 MB binary | FAIL, exit 1 |

The MCP mutation is worth recording because the **first version of the gate passed
it**. The decorator regex was `@mcp\.tool[^\r\n]*`, which also matches
`@mcp.tool_removed()` — so a renamed decorator still parsed as a declared tool and
the gate stayed green. Anchoring to `@mcp\.tool\(` is what made the assertion able
to fail. Without the mutation test that weakness would have shipped.

---

## 6. What this plan deliberately does not do

- **Does not adopt AIPC #1's docgen patch.** Measured 3/5 here. Their approach is
  not deterministic on a 12B, and the shipped default already avoids the defect.
- **Does not "fix" AIPC #2's fork-local regressions.** `GetRelativePath`,
  `rev-list`-with-SHA, `**_kwargs`, and the 42 MB binary are not in this repo.
  Fixing them here would be inventing work.
- **Does not change the MAIN tier default.** `deepseek-v4.1-flash:cloud` is the
  decided posture (2026-08-30) and the docgen gate passes on it.
- **Does not decide D5.** Commercial call, not engineering.
- **Does not add a runtime capability probe.** Too slow for a suite that runs on
  every change; the config-level assertion in D3 catches the same mistake.

---

## 7. Residual risks after this plan

| Risk | Why it remains |
| --- | --- |
| A fork can still diverge silently | `pacgate-ai` is read-only by design; nothing here can see fork-only commits |
| A 12B can still be used if the operator overrides the gate | D3 is a gate, not a runtime refusal |
| `deer-flow` image-baked code can lag its bind-mounted patches | the patches are the delta that matters, but the base image is not asserted |
| 百宸 remains public | D5 is undecided |

---

## 7a. AIPC #2's branches ARE reachable, and two of their gate fixes are real

The first version of this plan said their branches were "staged on fork, waiting
for a maintainer". That was wrong in a way worth correcting: the fork is public
and fetchable, and their branches are based on `d33553e` — **2 commits behind,
not 150**. The 150-behind figure is `aipc2/main`, which is a different thing.

```
git ls-remote --heads https://github.com/pacgate-ai/pacgate-ai-pr.git
  fix/gate-correctness              e30f7a58   base d33553e, +5
  fix/runtime-mcp                   621048ad   base d33553e, +3
  docs/audit-and-benchmark-records  4419dc15   base d33553e, +4
```

All five `fix/gate-correctness` commits cherry-pick **cleanly** onto `origin/main`.
Two of them fix defects that are real here, and both were verified by reproducing
the failure first:

### 5425573 — a bind-mounted file is not a tag/artifact mismatch

`test-release-provenance.ps1` treats any change under a build context as a
provenance defect. But `compose.prod.yaml` bind-mounts `deploy/pacgate-mcp/server.py`
over `/app/server.py`, so a local edit to it does **not** change what clients pull.

Reproduced: with a one-line edit to `server.py` and no fix, the gate reports
`FAIL 1 file(s) that CAN reach a built image changed` and exits 1. With their fix
it reports `1 file(s) changed but are BIND-MOUNTED over the image by compose` and
passes. Their fix derives the bind-mounted set from the compose files rather than
hardcoding it, so a new patch mount is covered automatically.

**This matters for this repo specifically**: the whole patch pipeline is
bind-mounts, so the gate is permanently red on any machine carrying a local patch —
which is how a gate stops being read.

### 547a926 — a pull is a no-op when local is AHEAD, not only when equal

`dry-run-update.ps1` asserted `HEAD == origin/main`. A dev box with a local commit
is ahead, and `git pull --ff-only` there fast-forwards nothing and exits 0 — so a
healthy tree reported FAIL.

Reproduced: on a branch 1 commit ahead, the gate reports
`[FAIL] local HEAD equals origin/main` and exits 1. With their fix it reports
`[PASS] a pull would be a no-op (local is not behind origin/main)`.

### What is NOT worth taking

- **`fix/runtime-mcp` (621048a)** — fixes `deer-flow-mcp-client.py`, which does not
  exist in `origin/main`. Verified: the upstream client at
  `deerflow/mcp/client.py` already does `if config.headers: params["headers"] = ...`.
  The bug is fork-local.
- **`aipc1/v0.2.2-sync` (5ad74b0)** — a **1853-file** sync, not a patch. Their
  docgen fix measured 3/5 here (§3.3), so it should not be adopted regardless.
- **`docs/audit-and-benchmark-records`** — 1003 lines of benchmark reports from
  0.1.25–0.1.31. Historical record, not a fix.

### Recommendation

Cherry-pick `5425573` and `547a926` (plus `1437301`, a docs correction, and
`09d5968`, a remediate-script fix) as a separate commit. They are small, they fix
real defects, and they were verified by reproducing the failure first — which is
the standard this repo holds its own gates to.

---

## 8. Evidence index

Every number in this plan was produced on 2026-10-23 on the HX370 dev box:

- `scripts/run-all-checks.ps1` → `ALL 48 GATES PASSED (14 live-stack gate(s) checked separately)`
- `scripts/test-document-generation-e2e.ps1` → `19 passed, 0 failed`
- `scripts/test-stack-version-coherence.ps1` → **4 FAIL before the recreate**, `14 passed` after
- `scripts/test-mcp-tool-surface.ps1` → `19` source tools == `19` advertised, 6 passed
- `scripts/check-tracked-file-size.ps1` → 759 tracked files, none over 10 MB
- `scripts/test-model-roster-consistency.ps1` → `14 of 14` (was 13; A6 added)
- live `tools/list` on `pacgate-mcp:8000/mcp` → 19 names
- live `tools/list` on `openviking:1933/mcp` with `X-API-Key` → 15 tools, HTTP 406
  on content negotiation (auth accepted); without the key → HTTP 401
- `docker inspect` on all five services → **all at `0.2.3`** after the recreate
  (four were at `0.2.1` before)
- `docker exec ocr-service grep _page_spans /app/app.py` → 2 matches after the
  recreate, 0 before
- `gemma4:12b-it-qat` tool-choice matrix → 0/5, 4/5, 3/5, 3/5 as tabulated
- `git ls-remote --heads origin` → `main` only
- `curl` on `raw.githubusercontent.com/.../docs/index.html` → 200
