# Plan Corpus Audit — 2026-09-15

Deep-dive over the full implementation-plan corpus: 18 plan-like documents
(1,979 lines) across three locations.

Method: every status claim in these plans was cross-checked against verifiable
repo/registry state rather than read at face value. Claims that could not be
verified are marked as such.

---

## 1. Corpus map

| Location | Files | Purpose |
| --- | --- | --- |
| `plans/` | 15 | The main delivery plan set (001–011 + 5 sub-documents) |
| `docs/plans/` | 2 | Pre-dates `plans/`; session-level implementation plans |
| `docs/superpowers/` | 2 | Spec + plan for the OpenViking memory lane |

`plans/README.md` is the declared index. It says each executor should "read the
plan fully before starting, honor its STOP conditions, and update your row when
done."

---

## 2. CRITICAL — live credentials tracked in two public repositories

This is not a plan-integrity issue, but the plans surfaced it and it outranks
everything else here.

### What is exposed

Two tracked files hold real, working credentials:

| File | Contains |
| --- | --- |
| `pacgate-ai/pacgate-ai-assets/…/pacgate-ai-remote-handbook/OPERATOR.md` | The real email, GitHub ID, and **plaintext password** for the `pacgate-ai` GitHub account |
| `pacgate-ai/pacgate-ai-assets/…/MCP授权/法律数据库MCP.md` | A unified login name and password for legal-database portals (chineselaw / pkulaw / qcc) |

`OPERATOR.md`'s own header asserts *"This file is gitignored."* That is **false**.
The only `.gitignore` in that subtree lists `.env`, `__pycache__/`, `*.pyc`, and
`.venv/` — nothing excludes `OPERATOR.md`. None of the 59 files in
`pacgate-ai-assets/` are ignored.

### Verified scope

| Check | Result |
| --- | --- |
| Tracked at local HEAD | Yes (both) |
| Present on `origin/main` (`JZKK720`, **public**) | Yes |
| Present on fork `main` (`pacgate-ai`, **public**) | Yes |
| Introducing commit | `01a4644` (2026-08-13), in main history since |
| `pacgate-ai-assets` files gitignored | 0 of 59 |

### Why the 2026-09-01 "public-flip pre-audit" cleared this

That audit swept for secret *literals* (`sk-`, `ghp_`, `AKIA`, `xox`, `PEM`,
`Bearer`), found three false positives, and concluded "repo clean". Its blind
spot: it never matched **password-shaped content in prose or markdown tables**
(`密码：<value>`, `| **Password** | <value> |`). A generic scanner I wrote first
missed both files for the identical reason — only a targeted
`密码|password` + separator scan found them.

Any future publish-readiness audit must add:

- CJK credential keywords (`密码` / `密钥` / `账号` / `账户` / `统一登录`)
- markdown **table** credential rows, not just `key: value`
- filenames announcing secrets (`OPERATOR.md`, `*授权*`, `*credentials*`)

### Required owner action

The password has been public, so **rotation is mandatory** — a history rewrite
alone is insufficient. Sequence: rotate the `pacgate-ai` account password and
revoke OAuth grants (Tailscale and others were authorized through it); rotate the
legal-portal credentials; remove the files and purge history
(`git filter-repo`/BFG); force-push both repos.

Useful mitigating fact: the GHCR packages are pulled **anonymously**, so rotating
the account password does **not** break client installs.

Both AIPC #1 and #2 hold clones, so coordinate the history rewrite with whoever
owns those machines.

---

## 3. HIGH — the plan index has drifted and was abandoned

`plans/README.md` is the entry point, and it is stale:

| Defect | Detail |
| --- | --- |
| Wrong "next plan" | README says *"the next improve-plan is 008"* — 008 already exists, and the corpus now runs to 011 |
| Missing plans | `009`, `010`, `011` appear nowhere in the README; its table stops at 008 |
| Stale status | README lists 001–008 as DONE and omits that 007 spawned five sub-documents and that 009–010 were executed |

The README's own instruction ("update your row when done") was followed through
008 and then dropped. The consequence is concrete: a new executor reading the
index would not learn that 009 (AIPC2 sync), 010 (QM single-stack migration), or
011 (GHCR release) exist.

---

## 4. MEDIUM — documents that will fail when actually used

### 4a. A deployment-handbook check now returns a false failure

`deploy/AIPC-DEPLOYMENT-HANDBOOK.md:97` (and the ZH twin at `:101`) tell the
engineer to verify the image with:

```text
ghcr.io/v2/jzkk720/pacgate-api/manifests/0.1.3
```

Verified live — this **404s**:

```text
jzkk720/pacgate-api:0.1.3  => HTTP 404 NOT-FOUND
jzkk720/pacgate-api:0.1.2  => HTTP 200 PUBLIC
```

Images moved to `pacgate-ai/*` at `aa1af15`, but this check still targets the old
namespace at a tag that was never published there. An engineer following the
handbook sees a failure on a healthy system.

### 4b. Plan 007's model tiers never matched the deployed reality

`plans/007-aipc-full-installation-handoff.md` prescribes, as authoritative
Appendix A values:

```text
MAIN = gemma4:12b-it-qat   MID = qwen3.8:27b-mtp-q4_K_M   LOW = gemma4:12b-it-qat
```

`plans/007-delivery-log.md` records that this was **not** what shipped:

> Model tiers mapped to **on-board** models (`ornith-1.5:9b` / `ornith-1.5:35b`),
> NOT the plan's `gemma4:12b-it-qat` / `qwen3.8:27b-mtp-q4_K_M` — ollama.com
> download path is blocked on this machine.

The reason is legitimate and the deviation is documented. The problem is that
007 still presents the unachieved values as the specification, and its own
Appendix A is the SQL an operator would run. 007 carries an update banner for
other topics but not for this.

### 4c. The deprecated namespace is still referenced in ~26 places

Non-`README-BUILD.md` references to `ghcr.io/jzkk720/*` or the `jzkk720` owner:

| File | Nature |
| --- | --- |
| `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`, `-ZH.md` | Verify snippet + build/push commands |
| `deploy/AIPC2-HANDOFF-PROMPT.md`, `-v2.md` | Points AIPC #2 at the layer branch + old namespace |
| `deploy/DEPLOYMENT-GUIDE.md` | Instructions to authenticate `gh` to the `jzkk720` org; `qm-pacgate` images |
| `deploy/PLANS.md` | Image table |
| `deploy/build-frontend.ps1`, `deploy/deer-flow-frontend-pacgate/Dockerfile` | Comments/build targets |
| `deploy/handbooks/qm-openviking-pacgate-handbook.zh.md` | Client-facing table |
| `deploy/ARCHITECTURE-DIAGRAMS.md` | Repo URL label |
| `plans/001-client-bundle.md` | Historical reference |

`README-BUILD.md` is the one place that *correctly* documents the move, including
a "to switch back" note — but the switch has since been decided the other way and
the surrounding docs were never updated.

### 4d. Two stale status labels on shipped work

| Document | Claim | Reality |
| --- | --- | --- |
| `docs/superpowers/specs/2026-08-28-openviking-memory-lane-design.md` | `Status: DRAFT v2` | The lane shipped (OV-1 service, OV-2a deer-flow MCP, OV-3 qm bridge) |
| `plans/009-aipc2-sync-and-upgrade-0.1.7.md` | targets `0.1.7` | Compose now pins `0.1.9` / `0.1.10` / `0.1.11` — 009 is a completed record, now two releases behind |

### 4e. One manual is delivered in two versions

`deploy/USER-MANUAL.md` and `docs/PACGATE-LAW-STAFF-HANDBOOK.md` cover the same
ground for different audiences, and **both** ship as PDFs in
`deploy/client-delivery/docs/`. Checked against the privacy concern previously
raised: `USER-MANUAL.md` line 9 is *accurate* — it states plainly that documents
never leave the machine while conversation text is processed by the enabled model
service. That earlier "claims no cloud" worry is **resolved**; do not re-report
it. The open question is only which PDF is canonical for the client.

---

## 5. LOW — structural observations

- **Five documents share the `007-` prefix.** 007 is a parent with four
  sub-documents, but nothing marks that relationship structurally, so numbering
  reads as ambiguous and the README had to explain it.
- **Two plan corpora coexist** with no cross-reference: `plans/` (delivery) and
  `docs/plans/` (session-level, pre-dating it). Two more live under
  `docs/superpowers/`. Neither the README nor the docs index links the others.
- **`plans/README.md` has no "how to add a plan" note**, which is plausibly why
  009–011 were added without updating the index.
- **Plan hygiene is otherwise good.** Each executor-facing plan states STOP
  conditions and an evidence requirement; 010's COMPLETED claim verified
  (`compose.qm.yaml`, `patch/pi-models.ts`, `tasks/patch-pi-models.sh` all
  tracked); 009's `.deer-flow` persistence-mount claim verified present at
  `compose.prod.yaml:102`.

---

## 6. Verified as accurate

To be explicit about what holds up, since a defect list alone is misleading:

| Claim | Status |
| --- | --- |
| 010 QM single-stack migration COMPLETED | Verified — all three artifacts tracked |
| 009 deer-flow `.deer-flow` persistence mount | Verified at `compose.prod.yaml:102` |
| 005 workflow packaging | Verified — 15 workflow YAMLs present |
| 008 bilingual manuals + PDFs | Verified — sources and PDFs in `deploy/client-delivery/docs/` |
| 001 client bundle | Verified — `deploy/client-bundle/` fully tracked |
| Plan 011 blockers | Independently confirmed (see `deploy/GHCR-MASTER-BUILD-AUDIT.md`) |

---

## 7. Recommended actions, in priority order

1. **Rotate and purge the exposed credentials.** See §2. Nothing else on this
   list matters until this is done.
2. **Fix the false-failure check** in both deployment handbooks (§4a) — it is a
   two-line change that currently sends installers chasing a healthy system.
3. **Rebuild `plans/README.md`** as a true index: add 009/010/011, correct the
   "next plan" line, and add a short "how to add a plan" note (§3).
4. **Correct plan 007's Appendix A** to the models actually deployed, or mark
   the table as superseded and point at the delivery log (§4b).
5. **Sweep the deprecated namespace** out of the ~26 remaining references (§4c).
6. **Update the two stale status labels** (§4d) and decide which user manual PDF
   is canonical (§4e).

---

## Appendix — tooling added

- `scripts/audit-plan-drift.ps1` — cross-checks plan status claims against the tree.
- `scripts/find-credential-files.ps1` — locates credential-shaped assignments (keywords only).
- `scripts/find-literal-secrets.ps1` — isolates literal values from placeholders (values masked).
- `scripts/scan-credential-patterns.ps1` — token-pattern sweep (counts only).

These report locations and pattern names, never secret values.
