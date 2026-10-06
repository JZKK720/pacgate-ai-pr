# Pacgate-ai Progress Memo — Since the OCR and Sanitizer Agent Stagings

> Period covered: 2026-09-19 → 2026-10-06 (OCR agent staged 2026-09-19; sanitizer agent staged 2026-09-19)
> Release at close of period: **v0.1.23**, all runtime images in `ghcr.io/jzkk720/*`, public, anonymously pullable.
> Commits in period: **242**. Chinese version: `PACGATE-AI-PROGRESS-MEMO-ZH.md`

---

## 1. Executive summary

Since the OCR extractor agent and the sanitizer agent were first provisioned on 2026-09-19, the project moved from "two staged agents inside a 0.1.17 stack" to a hardened, dual-workspace, multi-user v0.1.23 deployment with unified matter storage, verified end-to-end test lanes, and a complete client handover package. The work fell into four arcs: sanitizer/OCR reliability, security hardening, sandbox and auth integration for the collaboration lane (qm), and release + documentation.

## 2. Timetable

| Date | Milestone | What happened | Evidence (commit) |
|---|---|---|---|
| 09-19 | Staging point | sanitizer-agent and ocr-agent provisioned to deer-flow (agent cards, auth, CSRF, PS 5.1 fixes) | `ac94bc0`…`9ddf3e3` |
| 09-18 | ocr-service | PaddleOCR wrapper container with span output added | `1415f75` |
| 09-20 | 0.1.17 release | version pins bumped; large-scan body caps; LAN CORS fix so browser sign-in works | `2a51fbd`, `264a9d1`, `a0198d5` |
| 09-21 | Multi-user design | multi-user scope docs, assigned-user design, qm bring-up audit | `7467e2c`, `5d6b109`, `38ba418` |
| 09-21 | Auth hardening | deer-flow self-registration gated by config; setup token on `/initialize`; model tags reconciled with pre-pull list | `d7a0d82`, `41a76ac`, `e180fc8` |
| 09-22 | Workflow library fix | compose now serves the firm's 222-workflow library instead of 10 built-ins; defect recorded with evidence | `b7fc540`, `039afdc`, `88455dc` |
| 09-22 | Uploads security | refuse deletion through a symlink planted in uploads | `48f5a3b` |
| 09-23 | Clean-clone proof | runbook + judgement pass; memory adapter decision settled; legal-journey acceptance test (design item B) | `01c9b39`, `864f0b8`, `151d05b` |
| 09-24 | Extraction correctness | fail-closed OCR empty pages; cache keyed on completeness; empty-extraction gate in the suite | `9938df9`, `19b00ee`, `487f20a` |
| 09-25 | Text-native lane | direct reader for text-native documents incl. metadata; 4 DOCX text carriers read; formats .xlsx/.pptx/.html accepted; text never auto-escalated to a cloud model | `9179bbe`, `1cc6762`, `ddcfa02`, `8182c58` |
| 09-25 | 0.1.18 release | version pins; workflow tier roster becomes runtime config | `932ac8b`, `17bc59b` |
| 09-26 | Sanitizer step-1 detectors | ASCII boundary predicate, CJK-adjacent identifiers, landline + IPv4 detectors, grouped/full-width forms, windowed long-document NER, per-tier recall rows | `f744ac7`…`a74dec3` |
| 09-26 | Release engineering | read-only mirror namespace defect fixed; tag-push pre-flight gate | `294d597`, `06b1817` |
| 09-27 | 0.1.19 release - NER by default | NER weights baked into image, enabled via compose, gated at CI; memory cap 4 GiB; admission semaphore for sanitize jobs; If-Match revision on matter memory; memory scope enforced end to end; text lane never bypasses sanitization | `692bff8`, `03af009`, `745685f`, `e0882b9`, `4043267`, `74191af`, `a564a9a`, `f364741` |
| 09-27 | Gate suite | Python adapter suite wired; PDF-vs-source police gate; release bumper version loop closed | `0401b8a`, `fc441c9`, `df6b025` |
| 09-28 | Installer bootstrap | tenant + admin bootstrapped on install; clean-clone proof defects fixed; harness auto-recovery | `a8be956`, `b3eccfe`, `4848a94` |
| 09-28 → 09-29 | Benchmark | full-stack benchmark + E2E smoke report for 0.1.20 | `32cf190` |
| 09-29 → 10-01 | OpenViking + journey | qm and OpenViking lanes verified instead of skipped; 401 retry registered as gate | `eaf4e0e`, `161fd85` |
| 10-01 | 0.1.21 release | pins bumped; JWT 24h-expiry survival; PaddleOCR weights persisted | `eaf4e0e`, `b08bd0b` |
| 10-01 | Audit E2E 0.1.21 | full-audit recorded, three open items; lane-by-lane smoke gate added | `45e2364`, `ae2612c` |
| 10-02 | Security correction | open-registration finding re-rated: route leaks MATTER DATA, not just config | `743dcdc`, `7c812f6` |
| 10-03 | Registration closed | registration made FIRST-USER-ONLY so installs still bootstrap; admin provisioning route added with role-boundary tests; release 0.1.22; sanitizer E2E test fixes | `483ab19`, `ebac082`, `76311fe`, `95a6418`, `4da1e7e` |
| 10-03 | Runtime bring-up | Runtime 3 bring-up recorded; qm/gate-suite conflict retracted as false positive; qm image claim corrected to PUBLIC | `d223a79`, `e503200`, `041570c` |
| 10-03 | Defect recording | incomplete-extraction 500 recorded as known; two stale status headers corrected; pinned qm sandbox image unobtainable defect recorded | `3d3b9cc`, `a6a08f7`, `3e7e8e5` |
| 10-04 | Sandbox root cause | qm sandbox defect root cause corrected twice (registry, not digest); incident recorded with secret set printed; fix design corrected after measurement; sandbox image published and repinned | `2e81969`, `f6d3e5b`, `040d56e`, `46e31d7`, `ad36896` |
| 10-04 | Dev-box audit | what is safe to clear before destructive steps; code/automation/workflow library confirmed NOT machine-local; 222-workflow figure established exactly | `f86ea64`, `c5d4965`, `d4ca3dd`, `4397005` |
| 10-04 | Tooling lanes | plan 024 executed + post-re-sync re-audit; the four tooling lanes (markitdown/officecli/OCR/sanitizer) verified live, text-native 59/59 | `9699285`, `4441569` |
| 10-05 | Sandbox wiring | static docker CLI + socket into qm core; plan 025 with first-ever sandbox boot + live bridge E2E; CRLF-free launchers + bridge auto-provision; sandbox image rebuilt+published | `90ba1cb`, `222d381`, `1a720cc` |
| 10-05 | Unified workspace | matter-workspace rollup endpoint + present-file matter mirror; v0.1.23 released and repin committed; literal 'None' matter_id guard | `5fc63e1`, `acf5a17`, `d035103` |
| 10-05 | Handover docs | all user + operator handbooks refreshed for v0.1.23; handbook audit fixes; live browser verification of both login flows + Mailpit delivery | `b3a1352`, `0ad7496` |
| 10-06 | Installer gate fixes | PS 7-only operator removed; benchmark-exposed false-greens closed; sandbox auto-heal + install path staged; Join-Path fix | `307a048`, `52c7da7`, `ddfa54e`, `83b1d2a` |

## 3. Where each lane stands

- OCR lane: ocr-service (PaddleOCR) is first-class; batch OCR with a 200-page run cap, per-version caching, fail-closed empty pages, and persisted model weights. Verified live 07/07.
- Sanitizer lane: step-0 + step-1 detectors shipped (CaseNumber/Landline/IPv4 + CJK adjacency + full-width digits), long-document windowing, admission control, egress gate on pending documents. Text-native suite 59/59, E2E 15/15 after two test-script fixes.
- Collaboration (qm) lane: sandbox launch wired and verified (image repin 52e867fc), local-sandbox patch over the loopback dead-path + env forwarding, magic-link login proven in a real browser, sandbox image public.
- Research (deer-flow) lane: 222 workflows/46 categories served, matter workspace rollup, present-file auto-file into the matter, 19 MCP tools, artifacts panel with per-type preview.
- Auth: deer-flow email+password; qm one-time emailed links with Mailpit (pilot) / Resend (production); registration first-user-only; admin route POST /api/auth/users.

## 4. Open items

- Incomplete-extraction 500 is recorded as a known defect, not yet fixed (`deploy/DEFECT-incomplete-extraction-500.md`).
- QM local-model routing remains non-durable across core container rebuilds (documented workaround).
- The working tree at memo time still carried `setup-qm.ps1` and `local-sandbox.ts` functional edits awaiting commit for the next release train.

---

*Sources: git history (`git log --since=2026-09-19`), release tables verified against `deploy/client-bundle/compose.prod.yaml`, memory notes in session record `e2e-login-2026-10-05.md`.*