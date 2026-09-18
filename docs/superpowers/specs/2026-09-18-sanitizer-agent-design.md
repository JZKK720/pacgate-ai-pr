# Sanitizer Agent + OCR Pipeline - Design

> **Status:** DRAFT - awaiting approval
> **Date:** 2026-09-18
> **Author:** Copilot (autonomous research + design; user reviewed each decision)
> **Spec source:** `pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/自动化线条/自动化线条/法律材料脱敏范围与实现要求_技术交接版.md` (v1.0, client-authored)

## 1. Problem and goals

Pacgate must let a firm process client legal material through cloud LLM analysis
**without the client's identity leaving the machine**. The client supplied a
14-section requirements document. It is a strong *policy* document - it already
specifies things most comparable tools miss, including combination-identification
risk, metadata coverage, and a prohibition on scaling amounts or shifting dates.
It is thin on *mechanism*.

This design supplies the mechanism, and records seven capabilities the client
spec does not cover, derived from external research (see §10).

**Goals**
- Default-hide party and project identity while preserving every business fact
  the analysis needs.
- Keep the reversible mapping under the firm's control and out of any model's reach.
- Fail closed: if the system cannot verify, nothing leaves.
- Produce evidence sufficient to defend the redaction later.
- Reuse the existing metadata spine rather than building a parallel one.

**Non-goals (v1)**
- Legal advice, or a claim that pseudonymized output is "anonymized" (§10 of the
  client spec already forbids this claim, and this design preserves that).
- Pixel-level image redaction (v2 - the BBox data is captured in v1 so v2 is additive).
- Multi-matter mapping reuse (explicitly forbidden by §6.2).

## 2. The central architectural decision: two separate capabilities

OCR and sanitization are **separate capabilities**, not one pipeline. This was
confirmed by the user against real operating conditions:

| | OCR pipeline | Sanitizer agent |
|---|---|---|
| Job | Perception: file → text + structure + coordinates | Policy: text → safe text + verdict |
| Scale | hundreds-thousands of documents | one job, a few documents |
| Trigger | every document ingested | explicit, per egress need |
| Caches | **yes** - extraction stored and reused | **no** - deliberately disposable |
| Domain knowledge | layout, tables, seals, scans | client identity, T1-T4, egress policy |
| Useful alone | yes (contract review, DD, research) | yes (any text needing egress control) |
| Changes when | OCR models improve | redaction rules change |

**Test applied:** each is useful without the other. Both pass.

**Consequence:** the sanitizer must NOT call OCR inline. At bulk scale that would
re-OCR already-extracted documents on every sanitize job. The sanitizer consumes
**stored extraction output**.

```
INGEST (bulk, once per document version)
  document → ocr-service → text + DocTags + BBox
                         → persist extraction (cached, version-bound)
                         → kb_chunks + embedding (RAG, already exists)

SANITIZE (per job, on demand)
  reads cached extraction
  → detect → decide → replace → verify
  → produces job-scoped sanitized artifact + mapping + evidence
```

The two meet at ONE interface: **text plus spans with coordinates**. The
sanitizer never learns what a scan is; OCR never learns what 敏感 means.

## 3. Components

```
┌─ CLIENT AIPC (local, air-gapped capable) ──────────────────────────┐
│  deer-flow frontend ── WORKSPACE UI ONLY                           │
│    ├ general chat        app/workspace/chats/                      │
│    └ Sanitizer agent     app/workspace/agents/sanitizer/  (SEPARATE)│
│         left panel = REVIEW surface; holds NO vault, runs NO OCR    │
│                          │ HTTP                                     │
│  pacgate-api (Rust) ─────┴── authoritative gate + metadata spine    │
│    ├ pacgate-redact  (NEW) rules, vault, verify, T1–T4, audit       │
│    ├ pacgate-docx    (existing) Office handling                     │
│    └ Postgres: placeholder_map (NEW) + documents + audit_log (REUSE)│
│                          │ HTTP                                     │
│  ocr-service (NEW container, GPU) ── parsing + BBox                 │
│    └ PaddleOCR PP-StructureV3 primary [+ Docling adapter, v2]       │
│  qm-pacgate ── consumes via /pacgate MCP (own network, unchanged)   │
└────────────────────────────────────────────────────────────────────┘
```

### 3.1 `ocr-service` (new container, GPU)

General document-ingestion infrastructure, reusable by ANY agent - not
sanitizer-specific. Stateless per call; caches to the extraction store.

| Property | Value |
|---|---|
| Engine | PaddleOCR **PP-StructureV3** (Apache-2.0) |
| Why | Chinese-first; layout, tables, reading order; **seal/印章 recognition** (a §7 requirement with no other found solution); emits BBox |
| Output | Markdown + DocTags + per-span BBox + confidence |
| Deployment | Separate container, GPU. NOT in-process (Python ML, several GB) |
| Adapter seam | A parser trait so **IBM Docling** (MIT) can be added in v2 for born-digital Office fidelity |

Verified 2026-09-18: PaddleOCR 89,746★, Apache-2.0, active. Also evaluated and
recorded in §10: `baidu/Unlimited-OCR` (MIT, long-document model, ~40-page real
horizon, no table schema) - deferred to v3; `Tencent/WeKnora` - **not an OCR
tool**, it is a RAG/agent platform overlapping deer-flow + openviking + qm, so
deliberately NOT adopted.

### 3.2 `pacgate-redact` (new Rust workspace crate)

| Property | Value |
|---|---|
| Responsibility | detect → decide → replace → verify. Rule engine, placeholder map, T1-T4 enforcement, audit |
| Why a new crate | Independently testable at the rule level, which the client spec §9 requires (rule layer, local-model layer, full chain and cloud boundary must be testable SEPARATELY and not substitute for one another) |
| Depends on | `pacgate-core`, `presidio-rs` |
| Reuses | `presidio-rs` (MIT) - analyzer + anonymizer + **de-anonymizer** (the §6.3 restore path) + pluggable `NlpEngine` trait |
| Our value-add | The **China rules layer**, which no evaluated crate provides |

China identifiers requiring our own implementation:

| Identifier | Note |
|---|---|
| 身份证号 | 18-digit, checksum validation |
| 统一社会信用代码 | 18-char, structure + checksum |
| 手机号 | 11-digit, operator prefix, boundary checks |
| 案号 | year + court + case-type + sequence (最高人民法院代字标准) |
| 产权证号 / 商标注册号 | domain formats |
| 印章/seal | from OCR BBox, not text |

Segmentation `jieba-rs`; Chinese NER via `bert-base-chinese-ner` over Candle.

### 3.3 MCP tools (extend `pacgate-mcp`)

Two pure primitives plus one composed convenience tool. The primitives stay
reusable by any agent; the composition lives in the API, not in the agent.

| Tool | Purpose |
|---|---|
| `pacgate_extract_document` | file → text + DocTags + BBox (calls ocr-service; caches) |
| `pacgate_sanitize_text` | text + spans → sanitized text + mapping + verdict |
| `pacgate_sanitize_document` | composed: extract (if uncached) → sanitize |
| `pacgate_verify_sanitized` | re-scan with the same matcher; returns BLOCK/PASS |
| `pacgate_restore` | local-only restore, bound to the job's mapping version |

Precedent: `pacgate_convert_document` already performs local document work in the
MCP server. This follows that established pattern rather than inventing one.

**Where the separation actually lives - the boundary that matters.**
The rule in section 2 ("the sanitizer must not call OCR inline") applies to the
`pacgate-redact` crate, which only ever consumes text + spans and has no
concept of a file, a scan, or an OCR engine. It does not apply to the MCP layer:
`pacgate_sanitize_document` is an **orchestrator** that may trigger extraction
when the cache is cold. Concretely:

    pacgate-redact crate     -> consumes text + spans ONLY. Never calls OCR. (hard rule)
    pacgate-mcp orchestrator -> may call extract-then-sanitize as a convenience.
                                It reads the CACHE first; on a warm cache it never
                                touches ocr-service at all.

So a per-job sanitize on already-ingested documents costs ZERO OCR calls, which
is the property the bulk-scale operating condition requires. The composed tool is
an ergonomic wrapper, not a coupling of the two capabilities.

### 3.4 Sanitizer agent (deer-flow)

Lives in its own workspace - verified separate from general chat:

```
app/workspace/chats/                                  ← general chat
app/workspace/agents/[agent_name]/chats/[thread_id]/  ← agent (AgentThread types)
```

| Agent field | Value |
|---|---|
| `name` | `sanitizer` |
| `soul` | The client's spec, as the agent's operating instruction |
| `tool_groups` | the MCP tools above |

**The left panel is a REVIEW surface**, not an enforcement point: it shows
detections, the placeholder mapping, the egress verdict, and the restore control.
It never holds the vault and never performs the redaction.

## 4. Pipeline - six stages, fail-closed

```
1 INGEST     ocr-service → text + DocTags + BBox   (cached, version-bound)
2 DETECT     DETERMINISTIC FIRST: regex + checksum, then local NER.
             Each match carries type, span, offset, rule_version, method.
3 DECIDE     context rules → T1–T4 → replace / keep / escalate (HITL)
4 REPLACE    apply spans deterministically. NO LLM in this stage.
5 VERIFY     re-scan with THE SAME MATCHER that drove redaction.
             any residual, or any error → BLOCK
6 RESTORE    local only, bound to the job's mapping version.
             unknown/mismatched placeholder → error or HITL, NEVER guess
```

**Stage 5's mechanism** is taken from `microsoft/agent-governance-toolkit`:
*"the residual check uses the same matcher that drove redaction, so a detected
credential cannot pass."* Verification is **exact and deterministic**, never
model-based.

**Fail-closed rule:** unparseable input, a sanitizer error, an unassessable
span, or an invalid encoding all resolve to BLOCK - never PASS. This is the
pattern found independently in three projects (see §10).

## 5. Data model

**Reuse the existing spine - do not build a parallel one.** Verified present:

| Existing | Role in this design |
|---|---|
| `documents` (versioned, storage_path, matter_id) | source of truth; `version` binds the extraction cache |
| `kb_chunks` (document_id, chunk_index, content, page, embedding) | **already persists extracted text** - the extraction cache's text half |
| `audit_log` (action, resource, scope, metadata JSONB) | evidence trail |
| `004_data_level.sql` T1-T4 | **already the sensitivity taxonomy this design needs** |

T1-T4 as found:

| Code | Meaning | Sanitizer behaviour |
|---|---|---|
| T1 | 全所共享模板 - no client identity | already sanitized; identity work is redundant |
| T2 | 所内受限种子 - restricted, no cross-project search | standard sanitization |
| T3 | 项目专属资料 - matter-scoped only | matter binding enforced |
| T4 | 特别敏感资料 - special sensitive, strict isolation | elevated checks, HITL, no auto-pass |

**New, minimal:**

| Object | Purpose |
|---|---|
| extraction BBox storage | companion to `kb_chunks` (has `page`, lacks spatial data). Enables §7 pixel redaction in v2 and span-level review in v1 |
| `placeholder_map` | **job-scoped, ephemeral + audited**. Never reused across matters (§6.2 enforced structurally) |
| `redaction_ledger` | pre/post artifact SHA-256 + redaction record (adopted from Philter's ledger pattern) |

## 6. Error handling

| Condition | Behaviour |
|---|---|
| Document cannot be parsed or recognised | mark INCOMPLETE; block auto-send (§7, §8.6) |
| Extraction cache stale vs `documents.version` | re-extract; never sanitize against a stale extraction |
| Residue found in verify | BLOCK; surface spans to review panel |
| Placeholder unknown / malformed / ambiguous | error or HITL; never guess (§6.3) |
| Mapping version mismatch | refuse the job |
| OCR-service unavailable | fail closed - do not fall back to unsanitized text |
| Low confidence, no rule match | escalate to HITL, not auto-pass |

## 7. Testing

Per client spec §9, results must be reported **per layer**, and layers must not
substitute for one another.

| Layer | What is tested |
|---|---|
| Rule layer | regex + checksum units, per identifier, CI-gated, versioned |
| Local NER layer | model accuracy on a held-out synthetic set |
| Full chain | end-to-end pipeline on synthetic corpora |
| Cloud boundary | **separate** - asserts the actual egress payload |

**Benchmark:** `ai4privacy` PII-Masking-300k as the public harness. Report
precision, recall and F-beta with relaxed ±5-character span matching (the
Presidio evaluation convention).

**Recall is reported PER TIER, never blended** - Tier 1 (身份证/信用代码/手机号),
Tier 2 (person/org/contact), Tier 3 (locations/dates), Tier 4 (accounts).

**The failure mode this design guards against:** measured comparators show a
redactor can exhibit precision 0.600 with recall 0.153 - it looks accurate while
missing most sensitive data. Low recall is treated as the primary risk; the
system is tuned to prefer over-redaction surfaced for review over silent misses.

**Realistic Chinese expectation:** a measured Chinese PII model reports F1 0.7589
/ recall 0.7517. Do not promise 0.95-class recall for Chinese NER.

**Re-identification red-team suite:** attacks *combinations* (rare-value +
date + geography), not single fields. The client spec's acceptance table
requires the *combination-risk detector* (§9); it does not require an adversarial
*test suite*, which is what this adds.

## 8. Phasing

| Phase | Scope |
|---|---|
| **v1** | `ocr-service` (PaddleOCR) + `pacgate-redact` + deterministic+NER text pipeline + egress gate + verifier + audit + sanitizer agent + review panel. Text/DOCX first. Scan-only PDFs fail closed. |
| **v2** | Docling adapter (born-digital Office fidelity); **pixel-level image redaction** using v1's BBox data; combination-risk detector; re-identification red-team suite |
| **v3** | `Unlimited-OCR` long-contract assist - ONLY if a benchmark shows PP-StructureV3 struggling past ~40 pages |

## 9. Open questions

1. GPU capacity on the target AIPC for concurrent PaddleOCR + Ollama inference -
   needs measurement, not assumption.
2. Whether extraction BBox merits its own table or columns on `kb_chunks`.
3. Restore authorisation model: role-gated, per-job token, or both.

## 10. Client-spec requirements vs. genuine gaps

An earlier draft of this document claimed "seven gaps not covered by the client
spec". Self-review against the source spec
(`法律材料脱敏范围与实现要求_技术交接版.md`, v1.0, 14 039 bytes) showed that claim was
**overstated**: several items were already required there and two were mis-cited.
Corrected and classified below. The distinction matters because the two categories
have different owners.

| # | Item | Client-spec status | Resolution |
|---|---|---|---|
| 1 | Response-side, log and vector-store egress gate | §7 and §8.1 govern the **outbound request**. Downstream leak paths are unnamed | **true gap** - gate on responses, logs, traces **and** pgvector writes |
| 2 | Cryptographic provenance manifest | §6.3 and §8.8 require version traceability; no digest scheme is specified | **true gap** - pre/post SHA-256 + redaction ledger |
| 3 | Image-layer mechanism | §7 **already requires** stamp, signature, face and QR coverage | **not a gap - a build obligation.** The spec demands it; this design supplies the mechanism (OCR → BBox → pixel redaction in v2) |
| 4 | Identifier taxonomy checklist | §2 **already is** a nine-category taxonomy with per-category retention rules | **narrower than stated** - the gap is only the mapping to external standards (HIPAA Safe Harbor 18 + Piiranha/PII-Bench) as a versioned checklist |
| 5 | Re-identification red-team | §5.1 requires **detecting** combination risk | **true gap** - an adversarial combination-attack *test suite*, which §5.1 does not ask for |
| 6 | Format-preserving vs opaque placeholder policy | §6.1 requires consistency; it does not decide representation | **true gap** - per-identifier policy: opaque for LLM-facing, format-preserving where downstream parses |

### Withdrawn claim (recorded, not deleted)

A prior "Gap 7" asserted the spec had *"no rule/model/mapping version binding per
job"*. **This was wrong.** The source spec requires version binding in four
separate places:

- §6.3 (L136): 任务应绑定材料版本、映射版本及脱敏规则版本，禁止在历史任务中静默切换。
- §6.3 (L143): 模型原稿、本地还原稿、人工修订稿应分别保存，能够追溯版本及修改来源。
- §8.8 (L167): 规则变更可追溯 … 避免覆盖既有证据链。
- §9 acceptance (L188): 修改规则、模型或映射版本 → 记录变化，历史结果不被静默覆盖。

Version binding is therefore a **client requirement this design must satisfy**, not a
differentiator it contributes. It remains implemented (§5 `redaction_ledger`, §6
"mapping version mismatch → refuse the job") - the claim about its **origin** is
what is withdrawn.

### What the client spec requires that the design must not drop

§9 (L190) makes the technical team deliver six artifacts. These are contractual
obligations, not optional documentation, and are assigned to §7 phases:

1. 规则及上下文决策说明 - rule and context-decision documentation
2. 已覆盖与未覆盖格式清单 - covered / uncovered format inventory
3. 合成测试用例 - synthetic test cases (all §9 testing uses fictitious material)
4. 漏报与误报记录 - false-negative and false-positive records
5. 本地映射与还原说明 - local mapping and restore documentation
6. 出站边界验证结果 - outbound-boundary verification results

§9 (L171) additionally requires test results to be reported **separately** for the
rule layer, the local-model layer, the full chain, and the actual cloud boundary -
"不能相互替代". A single end-to-end pass figure does not satisfy this. §9 (L192)
forbids claiming safety from "已启用某实体类型" alone.

§10 (L198) is a positioning constraint on all marketing copy: a workflow that keeps
a restorable local mapping is **de-identification (去标识化), not anonymisation
(匿名化)**. The two must not be conflated in client-facing materials.

## 11. External evidence base

| Source | What it contributed |
|---|---|
| `presidio-rs` (MIT) | Rust analyzer + anonymizer + **de-anonymizer** + `NlpEngine` trait - the implementation base |
| PaddleOCR (Apache-2.0) | OCR engine; seal recognition; Markdown/JSON/BBox |
| IBM Docling (MIT) | candidate v2 Office adapter; DocTags carries span locations |
| Philter "Important to Know" | precedent for **documenting limits**; redaction **ledger**; REDACT vs CRYPTO_REPLACE/FPE reversibility distinction |
| `leak-inspect-v1` | fail-closed doctrine; named defect class `SANITIZATION_RESIDUE` |
| `agent-governance-toolkit` | verify with the **same matcher** that drove redaction |
| asupersync log gates | PII gates must cover **log streams**, hard-fail, non-overridable |
| Presidio evaluation guide | precision / recall / F-beta with relaxed span matching |
| ai4privacy 300k/500k | the public benchmark harness |
| Piiranha / OpenMed Chinese | the measured precision-vs-recall failure profile and realistic Chinese bar |
| `Tencent/WeKnora` | evaluated and **rejected** - wrong category (RAG/agent platform, overlaps existing stack) |
| `baidu/Unlimited-OCR` | evaluated, **deferred** - long-document model, ~40-page horizon, no table schema |

## 12. Decisions taken (with rationale)

1. **Two separate capabilities**, not one pipeline - confirmed against the user's
   real operating conditions (bulk OCR vs per-job sanitize).
2. **OCR as a service container**, not in-app - Python + GPU + GB of models has
   no place in a Next.js image; and it keeps the layer swappable.
3. **Vault in pacgate-api only** - neither deer-flow nor qm may hold it.
4. **Deterministic-first ordering** - the LLM proposes candidates only after
   rules run; it never performs final replacement.
5. **Recall over precision** - prefer over-redaction surfaced for review.
6. **New crate, new service; reuse the metadata spine** - do not duplicate
   `documents`, `kb_chunks`, `audit_log`, or the T1-T4 taxonomy.
7. **Fail closed everywhere** - unparseable, erroring, or unverifiable ⇒ BLOCK.
