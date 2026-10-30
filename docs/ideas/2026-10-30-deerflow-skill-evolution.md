# Deer-Flow Legal Skill Evolution - Idea Refinement

**Date:** 2026-10-30
**Status:** Direction agreed. **Items 1-3 of the MVP scope are IMPLEMENTED and
live-verified** (see "Implementation status" below); external research repair is
deliberately out of scope.
**Evidence base:** live probes against the running `0.2.7` stack on this dev box,
plus `deploy/pacgate-mcp/server.py`, `deploy/client-bundle/**`,
`pacgate-ai/crates/pacgate-search/src/lib.rs`, and the in-image
`deerflow` harness source. Measurements are marked with how they were obtained.

---

## Implementation status (2026-10-30)

| Item | State | Where |
| --- | --- | --- |
| `skill_evolution.enabled: true` | **done, live** | `deploy/client-bundle/deer-flow-config.yaml` |
| `skills.path: .deer-flow/skills` (persistent) | **done, live** | same file |
| 3 seeded Chinese-law playbooks | **done, live** | `deploy/client-bundle/deer-flow-skills/` |
| Seed mount, both compose lanes | **done, live** | `compose.prod.yaml`, `compose.bundle.yaml` |
| Seeds shipped to clients | **done** | `scripts/package-bundle.ps1` |
| Gate for the above | **done, all 12 checks pass** | `scripts/test-skill-evolution.ps1` |
| Gate registered in the suite | **done** | `scripts/run-all-checks.ps1` |
| Gate is syntactically checked | **done** | `scripts/check-installer-syntax.ps1` |
| K5: seeds are loadable + mounted + packaged | **done, 11 checks pass** | `scripts/test-skills-and-templates.ps1` |
| External research repair | **out of scope, documented** | see "Research reality" |

**The previously-unverified assumption is now verified end to end.** Calling the
real `_skill_manage_impl` with `action=create` wrote
`/app/backend/.deer-flow/skills/custom/probe-e2e-skill/SKILL.md`, and
`get_skills_prompt_section()` - **without clearing its cache and without a
restart** - grew from 2940 to 3234 chars and contained the new skill. So an
agent-authored skill is visible on the very next turn. (The probe skill was
deleted afterwards; it is not part of the shipped corpus.)

**Live state after `docker compose up -d --force-recreate deer-flow`:**
deer-flow healthy, 45 tools bound, `skill_manage` present, 3 skills loaded,
allowed-tools union empty (surface unrestricted).

---

## Problem Statement

**How might we let a Pacgate lawyer grow the assistant's legal capability while
they work, without the firm shipping an unreviewable skill corpus and without
the model inventing legal authority?**

The gap is not a missing feature - it is a missing loop. Every ingredient for
agent-authored legal skills already exists on the box and is switched off or
unwired. Today the assistant is legally capable but statically so: the same 44
tools and zero skills on every turn, forever.

---

## What is actually true right now

Measured on the live stack (containers `deer-flow`, `pacgate-mcp`, `openviking`,
`pacgate-api`, all `0.2.7`):

| Fact | Evidence |
| --- | --- |
| deer-flow loads **zero** skills | `get_or_new_skill_storage().load_skills()` returned `count: 0`; skills root `/app/backend/skills` does not exist in the image |
| The skills prompt section is **empty** | `get_skills_prompt_section()` returned `len: 0` |
| Skill evolution is **disabled** | `config.skill_evolution = enabled=False moderation_model_name=None` |
| `skill_manage` is therefore **not bound** | `get_available_tools(app_config=cfg)` lists 44 tools, no `skill_manage`; `tools.py:92-96` gates it on `skill_evolution.enabled` |
| Enabling it **does** bind the tool | With a throwaway config (`skill_evolution.enabled: true`), `get_available_tools` returned `['skill_manage']` |
| The security scanner **works on the local model** | `scan_skill_content(...)` on a sample NDA skill under `gemma4-12b-local` returned `decision: allow` with a sensible reason |
| A written skill **is** discoverable | Writing `custom/nda-review-cn/SKILL.md` then calling `get_skills_prompt_section()` produced `len: 1366` and rendered the `<skill_system>` block |
| New custom skills default to **enabled** | `extensions_config.is_skill_enabled` returns `True` when a `custom` skill has no explicit entry |
| Skills can live on the **already-persistent** mount | Setting `DEER_FLOW_SKILLS_PATH=/app/backend/.deer-flow/skills` wrote, loaded and cleaned up a skill successfully; no new volume needed |
| MCP wiring is **healthy** | `scripts/test-mcp-tool-surface.ps1` -> 6/6 pass, 19/19 advertised tools match source, all have descriptions and schemas |
| The agent **cannot read or write skills through bash** | `validate_local_tool_path` allows `/mnt/skills/*` only when `read_only=True`; comment at `tools.py:524` already notes scripts under skills cannot execute |
| **No egress** from deer-flow | `urllib` to google.com / flk.npc.gov.cn / courtlistener.com all fail with `SSL: UNEXPECTED_EOF_WHILE_READING` |
| The egress failure is **host-level**, not Docker | `Invoke-WebRequest` to courtlistener / api.github.com / registry.npmjs.org fails identically from Windows, including through the local `127.0.0.1:7892` proxy. This is the same TLS condition recorded in commit `41987c9` and `scripts/diagnose-github-egress.ps1` |
| Connector fan-out returns **`[]` for this reason** | `docker logs pacgate-api` shows `WARN pacgate_search: connection error connector="courtlistener" ... error sending request for url(...)` and the same for `eur-lex`; `sec_edgar` and `gleif` reach the network and legitimately return 0 results |
| Only **4 of 10** live connectors are available | `pacgate_list_connectors`: courtlistener, sec_edgar, gleif, eur-lex true; yuandian, pkulaw, qcc, fyopen, vaquill, opencorporates false - the four Chinese ones are the firm's primary authorities and all need API keys |
| `npc_law_db` and `wenshu_court` are `implemented: false` | `pacgate-search/src/lib.rs` metadata: auth `free`, priority `FreeAvailable`, but no implementation |
| **Internal RAG works and redaction is live** | `pacgate_kb_search` on matter `8f963544-...` returned a real chunk with PII already replaced (`[PERSON_14BF81AB_1]`, `[CN_MOBILE_...]`, `[LOCATION_...]`) and `data_level: "T3"` |
| Workflows and matters **do** work | `pacgate_list_workflows` and `pacgate_get_workspace` returned real data (matter `8f963544-...`) |

The load-bearing conclusion: **the loop is blocked by config, not by
capability.** Two keys and one path turn it on.

---

## Directions considered

### A. Config-only self-evolution (turn on what exists)

Set `skill_evolution.enabled: true`, move the skills root onto the persistent
mount, and let the agent author skills with `skill_manage`. Zero new code.

- **User value:** high per unit of work. The lawyer's correction at turn 3
  becomes a durable skill at turn 4.
- **Feasibility:** highest. Every mechanism is already in the pinned image,
  already scanned by a security model, already validated (`SkillStorage.validate_skill_markdown_content`
  enforces hyphen-case + frontmatter name match).
- **Weakness:** no legal-quality gate. A skill can be well-formed, safe, and
  still encode a wrong legal position. Safety screening is prompt-injection
  screening, not legal review.

### B. Authored skill playbook library (curate, do not generate)

Hand-author a starter corpus from `corporate-legal_13skill改造优先级评估.md` and
`skill骨架_VCPE投融资协议套.md`, ship it read-only, and let the agent *patch*
rather than invent.

- **User value:** very high and immediate - the P0 items in the 13-skill
  assessment (cold-start-interview, matter-workspace, tabular-review) are the
  ones that make every other skill non-generic.
- **Feasibility:** high; those documents are already in the repo.
- **Weakness:** it is content work, not engineering work. It does not scale to
  each firm's house style, and it does not produce the self-evolution the brief
  asks for.

### C. Research-evidence-gated evolution (a skill may only cite what the system
can verify)

Require every skill that asserts legal authority to carry citations the system
can re-verify through `pacgate_connector_search` / `pacgate_kb_search`, and
degrade skills that cite unverifiable sources.

- **User value:** highest, because it is the actual Pacgate differentiator -
  source-level tagging (`authority_verified > auxiliary_db > internal_template
  > model_inference`) already exists in the search router, and `kb_search`
  already returns `data_level`.
- **Feasibility:** **partially available today.** It works for the *internal*
  channel (RAG returned real redacted content) and is **impossible for the
  external channel** (all four Chinese authorities are unreachable or
  unimplemented). So the gate is shippable as "a skill may cite internal
  authority and must label anything else as unverified" - which is exactly the
  rule `firecrawl-web/SKILL.md` already states in prose.

### D. OpenViking-as-skill-store (skills live in `viking://`, not on disk)

- **User value:** memory and skills unify; `remember`/`search`/`edit`/`grep`
  already exist as MCP tools, and the assistant already reads them.
- **Feasibility:** **rejected.** `SkillStorage` is file-path based by
  contract (`get_skills_root_path()` returns a `Path`, sandbox maps
  `/mnt/skills` to a host path). OpenViking cannot satisfy it without a new
  `SkillStorage` subclass, and the prompt injects skills from disk.

---

## Recommended Direction

**A now, B alongside it, C as the gate that unlocks once research works.**

Ship the config change first because it is small, reversible, and verified.
Then seed the corpus with a handful of hand-authored Chinese-law skills so the
agent starts from a competent baseline instead of generating from nothing.
Then, and only then, make legal-evidence verification a *requirement* for a
skill to claim authority - which first requires fixing research.

The reasoning is about ordering, not preference. A self-evolution loop seeded
from an empty corpus produces generic skills, and a lawyer's first experience
would be "the assistant wrote me a plausible-sounding NDA checklist with no
Chinese-law specifics." Seeding first means the agent's first act is to *patch
a competent skill*, which is the behaviour the prompt already prefers
("Prefer patch over edit").

### The three changes, in order

1. **Config (2 keys, 1 path).** `skill_evolution.enabled: true` and
   `DEER_FLOW_SKILLS_PATH=/app/backend/.deer-flow/skills` in
   `deploy/client-bundle/deer-flow-config.yaml` + `compose.prod.yaml`. Verified
   to bind `skill_manage` and to persist across recreation.
2. **Seed corpus (content).** Start with three, not thirteen: a Chinese-law
   contract-review skill, an NDA-review skill, and a matter-scoping skill.
   Each must declare `allowed-tools` correctly (see the footgun below).
3. **Research repair (engineering).** Connector fan-out returning `[]` is
   **not a `pacgate-search` defect**: `docker logs pacgate-api` shows
   `connection error connector="courtlistener"` / `"eur-lex"`, and the same URLs
   fail from the Windows host and through its proxy. `sec_edgar` and `gleif`
   reach the network fine and return 0 results, which is why the array is empty
   rather than absent. The real blocker is that **the two authoritative Chinese
   sources the firm needs - 北大法宝 (`pkulaw`) and 元典 (`yuandian`) - are
   `available: false` because their API keys are unset**, and
   `npc_law_db`/`wenshu_court` (`free`, `FreeAvailable`) are `implemented:
   false` in the registry. Fix egress *and* provision keys; either alone leaves
   the assistant citing whatever it can reach instead of Chinese authority.

**Important distinction the brief blurs.** "Research" has two channels, and
only one is broken:

- **Internal RAG is healthy.** `pacgate_kb_search` returned real, redacted,
  data-level-tagged content. A skill grounded in *the firm's own* documents is
  viable today.
- **External research is not.** Zero of the four Chinese authorities are
  reachable. A skill claiming to have checked 国家法律法规数据库 would be
  fabricating, and the prompt's own rule ("Never fabricate") would be violated
  by the tool surface, not the model.

---

## Key Assumptions to Validate

- [x] **A skill written mid-run is visible next turn, not next restart.**
      **VERIFIED 2026-10-30.** `_skill_manage_impl(action="create")` wrote the
      file, and `get_skills_prompt_section()` rendered it immediately (2940 ->
      3234 chars) with no cache clear and no restart.
- [x] **A non-list `allowed-tools` declaration.** **VERIFIED - and it is worse
      than assumed.** A scalar (`allowed-tools: pacgate`) does not fall back to
      allow-all: the loader rejects the skill outright with `allowed-tools ...
      must be a list of strings` and it never loads. This was hit live while
      authoring the seeds and is why they declare no `allowed-tools` at all.
- [ ] **The scanner is not a blocking bottleneck at realistic sizes.** One
      1 KB skill took one local-model call and allowed it. A 10 KB skill with
      `scripts/` is a different load; `_scan_or_raise` blocks executable content
      unless the decision is exactly `allow`. Note also that the scanner fails
      **closed**: if the moderation model call throws, the result is `block`.
- [ ] **The skills prompt section stays affordable.** Measured: 2940 chars for
      3 seeds (~735 tokens). Twenty seeded skills would add real prompt weight to
      a stack that already defers MCP schemas to save ~8k tokens per turn. This
      is a direct trade against the measurement in
      `DEERFLOW-LANE-OPTIMISATION-2026-10-21.md`. **Watch this as the corpus grows.**
- [ ] **Lawyers actually correct the assistant.** The whole loop is worthless
      if the correction channel (`ask_clarification`, review panels) goes
      unused. Needs observation on a real matter.

---

## The footgun that will bite

`allowed_tools` is a **union across all loaded skills**, and once *any* skill
declares the field, skills that omit it contribute nothing. Measured:

| Loaded skills | Resulting tool surface |
| --- | --- |
| two skills, neither declares | `None` (all 45 tools) |
| one declares `["bash"]` | `{'bash'}` |
| self-made skill (omits) + existing (declares `["bash"]`) | `{'bash'}` |
| one declares `["bash","read_file"]` | `['bash','read_file']` |
| **a SCALAR `allowed-tools: pacgate`** | **skill does not load at all** ("must be a list of strings") |

So a single agent-authored skill that declares `allowed-tools: [pacgate]`
collapses the entire surface to `pacgate_pacgate_kb_search` and the assistant
loses `bash`, `read_file`, `write_file`, `present_files`, and every OpenViking
memory tool. The agent has no way to know it just amputated itself, and the
symptom presents as "the assistant got worse", not as an error.

**How this is now contained.** The seeded skills declare **no** `allowed-tools`
at all, and `scripts/test-skill-evolution.ps1` E5 fails if any seed ever adds a
partial one. That gate earns its keep: a mutation adding
`allowed-tools: [bash, read_file]` to a seed correctly exited 1 with
"...omits write_file, present_files, ask_clarification, skill_manage,
openviking_search, pacgate_pacgate_kb_search - that union REMOVES those tools".

The residual risk is an **agent-authored** skill that declares a partial list.
The scanner screens for injection and unsafe code, not for tool-policy
consequences, so it will not catch this. Two options if it becomes a problem:
add the same union check to `skill_manage`'s validation, or drop `allowed-tools`
from the agent-facing tool schema so the agent cannot set it.

---

## MVP Scope

**In** (all shipped 2026-10-30):
- `skill_evolution.enabled: true` and a persistent skills path in the client
  bundle, both compose lanes.
- 3 hand-authored Chinese-law seed skills with no `allowed-tools` declaration.
- `scripts/test-skill-evolution.ps1` (E1-E6) and K5 in
  `scripts/test-skills-and-templates.ps1`, both registered in the suite.
- Seed corpus shipped by `scripts/package-bundle.ps1`.

**Still to do:**
- A short lawyer-facing note: what the assistant can now learn, and the fact
  that self-authored skills are **drafts pending lawyer sign-off**, not firm
  policy. The skills themselves say this; the user manual does not yet.
- Observation on a real matter to confirm the correction loop is actually used.

**Out:**
- Skills in `viking://` (rejected above).
- Any auto-promotion of a learned skill into the shared corpus.
- Legal-evidence gating as a hard requirement (blocked on research).
- A skills editor UI. Upstream already ships `/api/skills` + `/api/skills/custom`
  routers and a frontend `core/skills` client; the gap is a page, not an API.

---

## Not Doing (and why)

- **Enabling evolution without seeding.** Produces generic legal skills and
  spends the lawyer's first impression on them. Seed first.
- **Storing skills in OpenViking.** `SkillStorage` is path-based by contract;
  unifying these would need a new storage backend and a prompt rewrite.
- **Letting the agent write executable `scripts/` into skills.** The scanner
  blocks executable content unless the decision is exactly `allow`, and the
  sandbox forbids write access to `/mnt/skills`. Do not fight both.
- **Treating research as solved.** It is not, and the split matters: internal
  RAG works, external authority does not. `[]` from the connector fan-out and
  zero egress are what make "the assistant researched the law" a false claim
  today.
- **Re-flagging cloud chat models.** The 2026-08-30 decision stands; this work
  does not touch it.

---

## Where deer-flow connects to MCP today, and what is genuinely missing

The brief asks for "deerflow to MCP wiring". That is **already done and
gate-covered** - the useful question is what the wiring does not yet expose.

```
deer-flow (lead agent)
  |-- MCP: pacgate-mcp:8000/mcp   -> 19 tools, all pacgate_*        [VERIFIED 19/19]
  |     kb_search, connector_search, list_connectors, list_matters,
  |     read/write_memory, list_documents, get_workspace, read_document,
  |     upload_document, list/get/execute_workflow, convert_document,
  |     ocr_document, ocr_batch, sanitize_document, verify_sanitized,
  |     sanitize_text
  |-- MCP: openviking:1933/mcp    -> 15 tools (find/search/read/list/
  |     tree/remember/write/edit/add_resource/watches/grep/glob/
  |     forget/health)                                             [VERIFIED 15]
  |-- MCP: officecli (stdio)      -> 1 tool (officecli)            [VERIFIED]
  |-- sandbox tools               -> bash, ls, read_file, write_file,
  |     str_replace, glob, grep, present_files, ask_clarification  [VERIFIED]
  `-- skill_manage                -> NOT BOUND (skill_evolution disabled)
```

Bound surface: **44 tools**, verified by calling `get_available_tools()` in the
live container. The wiring gate `scripts/test-mcp-tool-surface.ps1` passes 6/6
and re-derives the expected list from `deploy/pacgate-mcp/server.py`, so source
and deployed surface cannot drift.

Three genuine connectivity gaps, in severity order:

1. **`skill_manage` is not in that list.** This is the whole of item 2 in the
   brief - not a wiring problem, a config gate (`tools.py:92-96`).
2. **The 44-tool surface is the *deferred* surface.** `tool_search.enabled:
   true` means MCP schemas bind lazily; the agent sees names in
   `<available-deferred-tools>` and the middleware promotes on first call. So
   an agent-authored skill that tells the model to call `pacgate_kb_search` is
   consistent with how the stack already works, but a skill that assumes the
   schema is bound is not.
3. **A skill cannot reach its own `scripts/`.**
   `validate_local_tool_path` permits `/mnt/skills/*` only for `read_only=True`,
   so a skill carrying `scripts/` can be *read* but not *written or executed*
   through the sandbox. Skills are therefore **prose playbooks**, not code
   packages - which is the right constraint for legal work, and worth stating
   explicitly so nobody builds a script-carrying skill and discovers this in
   production.

### On "skill.md skeleton vs. real skill with playbook"

The brief frames this as a choice. The evidence says it is a **sequence**, and
the ordering is forced by the mechanics:

- A bare `SKILL.md` skeleton is what `skill_manage` already produces, and its
  frontmatter is machine-validated (`validate_skill_markdown_content` enforces
  hyphen-case names and that the frontmatter `name` matches the directory).
  That is the *envelope*.
- A playbook is the *body*: the actual Chinese-law procedure. Nothing in the
  stack validates it, because nothing in the stack can - it is domain content.

So: the skeleton is a format, the playbook is the product. Building the format
without playbooks yields an empty envelope; writing playbooks without the
format means they never load. Ship both, and the repo already contains the
playbook material (`corporate-legal_13skill改造优先级评估.md`,
`skill骨架_VCPE投融资协议套.md`) - it has simply never been converted into loadable
`SKILL.md` files.

---

## Open Questions

- Should self-authored skills be scoped **per matter** or firm-wide? The memory
  lane is matter-scoped (`PACGATE_MATTER_ID`); the skills root is global. A
  skill learned in one client matter leaking into another is a confidentiality
  question, not a UX one.
- Who signs off? A skill is a durable behaviour change; the review panels exist
  for documents, not for agent behaviour.
- Is `skill_evolution` an operator switch or a per-user entitlement? Turning it
  on globally means every user's corrections shape one shared corpus.

---

## Immediate next actions

1. ~~**Land the config change + seed skills + gate**~~ **DONE 2026-10-30** -
   config, 3 seeds, both compose lanes, packaging, gate E1-E6, and K5.
2. ~~**Run a real chat turn that creates a skill**~~ **DONE** - verified at the
   implementation level (write -> next prompt render, no restart). A manual chat
   run is still worth doing once for confidence, but the mechanism is proven.
3. **Add the lawyer-facing note** to the user manual: what the assistant can now
   learn, that skills are drafts pending sign-off, and that `skill_manage` writes
   are security-scanned but not legally reviewed.
4. **Fix the external research lane separately**, because it is not a
   skill-system problem: (a) the host's TLS egress, (b) the four Chinese
   connector API keys, (c) `npc_law_db` / `wenshu_court` implementation. Do not
   gate skill evolution on this - the internal RAG channel already works.
