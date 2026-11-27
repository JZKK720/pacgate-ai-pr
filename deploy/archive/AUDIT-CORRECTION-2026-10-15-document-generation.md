# Audit correction - document generation

docs(audit): correct the document-generation claim; it is a HOST difference

CORRECTION. My earlier report to the user called the document-generation gate
failure a "0.1.31 regression" and attributed it to "466 lines changed in the
generation path". Working it through with the systematic-debugging process, that
claim does not survive its own evidence.

WHAT I DID WRONG

I compared a gate PASS recorded on 2026-10-13 in
deploy/REGRESSION-REPORT-2026-10-14-v0.1.29.md - taken on host
`LAPTOP-HH9V75MK` - against a gate FAIL I measured on host `PACGATE-AI02`, and
read the difference as a code regression. Two measurements from two machines.

The report I was reading says this explicitly in its own section 2, about the
same box: "this lane cannot detect a 5x difference on this box, so it must not
be used to claim either an improvement or a regression".

WHY THE WINDOW WAS WRONG

- d86a2e84 (gate written, 18/18 PASS) sits BEFORE v0.1.29. Between it and the
  0.1.31 revision lie e0190c52 and 349f0ac5, but e0190c52 is inside v0.1.29 -
  which PASSED 19/19 with 14 of 14 direct drives returning 200. My 466-line
  window therefore swallowed a working release.
- The real window is v0.1.29 -> v0.1.31, and it contains exactly ONE commit
  touching this path: 349f0ac5, first shipped in v0.1.30.
- Even that commit cannot explain the symptom. Interleaving the diff against the
  file shows the first hunk (line 657) adds two loop-local variables
  (last_round_sig, identical_rounds); the first production change at or after
  the first llm.complete is line 677. So everything up to and including the call
  that CHOOSES tool_calls in round 0 - prompt, tools list, model - is
  byte-identical to v0.1.29.

WHAT IS ACTUALLY DIFFERENT

- host: LAPTOP-HH9V75MK (the PASS) vs PACGATE-AI02 (the FAIL)
- model: gemma4:12b-it-qat in BOTH v0.1.29 and v0.1.31, tier default unchanged
- code up to the round-0 LLM call: identical

So the honest statement is that this box, at 0.1.31, does not emit generate_docx
on this workflow - not that 0.1.31 broke it. The one upstream change worth
testing on THIS box is the forced final-answer pass added by 349f0ac5, which can
replace a turn that ran tools with model prose; it is post-loop, so it cannot
cause a round-0 tool choice, but it has not been measured here and I am not
going to claim it either way.

WHAT I DID NOT DO

I did not change any code for this item. There is nothing to fix until the same
host is measured on both sides, which means either tagging the pre-349f0ac5
revision and running the gate here, or running the gate on LAPTOP-HH9V75MK.

VERIFIED IN THIS SESSION (separate items, both fixed and measured):

- test-model-picker-e2e.ps1: CANNOT CHECK (exit 2) -> 13 passed, 0 failed.
  Two gate defects: a stale hardcoded password (the credentials file records a
  2026-10-09 rotation) and a JSON body posted to an OAuth2PasswordRequestForm
  endpoint, which yields 422 even with the right password.
- deer-flow skills: ROOT CAUSE FOUND AND FIX CONFIRMED. SkillsConfig.get_skills_path()
  resolves to /app/backend/skills and deer-flow's project layout expects a
  `public/` category level beneath it - get_skill_container_path() builds
  "<container_path>/<category>/<name>". Nothing creates that tree, so /api/skills
  served 0 of 22. Placing the 22 committed skills at
  /app/backend/skills/public took the endpoint from 0 to 22, verified live.
  NOTE FOR THE DURABLE FIX: the 22 skills live in
  deploy/client-bundle/deer-flow-src/, which is GITIGNORED with zero tracked
  files - a dev-only checkout that is not part of the shipped bundle. So the fix
  is not "add a bind mount"; the committed copy has to come from somewhere that
  ships to a client AIPC. That decision is why this one is left unfixed here.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
