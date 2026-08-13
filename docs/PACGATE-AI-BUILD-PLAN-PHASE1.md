# Pacgate AI - Phase 1 Build Plan
## Cubecloud.io Local Legal AI Pilot Proposal - Revised May 2026

> **Pre-Contract Document**
> This revision reflects Pacgate's current purchasing direction: start with a hands-on Phase 1 local deployment program, not a full SaaS build.
> Cubecloud's existing prototype work in this repository remains pre-sales architecture and research support.
> A full Pacgate SaaS quotation is explicitly deferred until Phase 1 trials, operating patterns, and learning outcomes are proven.

---

## Executive Summary

Pacgate's immediate buying decision is not whether to fund a full Pacgate SaaS build today. The immediate buying decision is whether to stand up a **private Phase 1 legal AI pilot** that gives the firm useful local AI capacity now, lets the team study two strong open-source legal agent models in practice, and begins building the internal knowledge structures that a later proprietary Pacgate platform would depend on.

This proposal therefore treats Phase 1 as a **commercial pilot package**, not as a full software-build contract. Cubecloud installs two local AI systems, adapts two legal-agent application references to Pacgate's needs, enables a starter knowledge and retrieval layer, and stays involved as Pacgate learns, operates, and decides what a future Pacgate product should actually become.

Under this revised Phase 1 proposal, Cubecloud supplies and deploys:

1. **Two AIPC-class local AI systems** with Cubecloud's standard AI layer and Agent OS surfaces, sized for Pacgate's pilot workflows and paired with external GPU docks.
2. **Two tailored legal agent application deployments** for Pacgate's hands-on use and learning program:
   - **Claude for Legal adaptation** for practice bundles, playbooks, connectors, and lawyer-reviewed workflow execution.
   - **Lavern adaptation** for local multi-agent orchestration, debate, verification loops, and deliverable-first legal work.
3. **Starter private knowledge infrastructure** so Pacgate can begin organizing authority materials, client precedents, matter folders, context-graph conventions, and local retrieval workflows.
4. **Long-term advisory support** billed separately for remote or on-site assistance, including workflow tuning, connector planning, MCP expansion, and future Phase 2 discovery.

This structure matches both the customer's counter-offer and Cubecloud's own services-first rollout model: deliver something useful and private first, learn from real use, and price the larger Pacgate SaaS system only after the operating model is proven.

### Commercial Snapshot

| Commercial view | Working quotation basis |
|-----------------|---------------------------|
| Fixed Phase 1 delivery subtotal | **USD 16,612 / CNY 119,600** |
| Includes 3 business days on-site installation and training | **Included in fixed delivery at no extra charge** |
| Optional 40-hour remote advisory reserve (1 year validity) | **USD 2,778 / CNY 20,000** (standalone service order — see Add-On Services Schedule) |
| Optional annual license renewal (Year 2 onwards) | **USD 611 / CNY 4,400 / year** (standalone service order, priced at 25% of initial license fee — see Add-On Services Schedule) |
| Optional 5-day on-site support package | **CNY 43,200 reference price** (standalone service order, travel extra — see Add-On Services Schedule) |
| Travel and accommodation | Separate, at cost or quoted per trip |
| Phase 2 SaaS build quotation | Deferred until after Phase 1 trial success |

> USD figures in this proposal are tax/VAT included. CNY figures are shown at a reference FX rate of **USD 1 = CNY 7.20** and do not yet include the additional 3.5% VAT reserve. Final invoice currency and FX/tax treatment are confirmed at contracting time.

### What Phase 1 is buying now

| Included in this proposal | Why it matters now |
|---------------------------|--------------------|
| Two local AI machines | Gives Pacgate private daily-use infrastructure immediately |
| Cubecloud standard AI layer and Agent OS surfaces | Gives one operating layer for chat, review, search, security, and automation |
| Two legal agent application adaptations | Lets Pacgate compare two open-source legal operating models on real work |
| Starter context graph and RAG setup | Begins the long-term internal knowledge asset, instead of waiting for a later platform |
| First-delivery on-site installation and training (3 business days) | Two-system racking, networking, baseline deployment verification, and key user training at no extra charge |
| 40 hours remote advisory support (1 year validity) | Post-deployment workflow tuning, connector planning, knowledge base guidance, Phase 2 assessment, and system-level remote troubleshooting |

### What Phase 1 is not buying yet

| Deferred to later phase | Reason for deferral |
|-------------------------|---------------------|
| Full Pacgate SaaS quotation | Customer does not want to buy the complete platform first |
| Final multi-tenant Pacgate web product | Needs real operating patterns from the local pilot |
| End-client SaaS pricing model | Should be based on proven legal workflows and support load |
| OEM/licensing economics for a broader product launch | Should follow successful pilot operation, not precede it |

---

## Scope Reference

| Reference | Role in this proposal |
|-----------|-----------------------|
| Customer counter-offer | Start with two local AI systems, two legal agents, and advisory support |
| Cubecloud operating layer | OpenSpace, Open WebUI, IronClaw, Hermes, Warp ADE, and OpenCode as the standard local surface stack |
| Phase 1 implementation anchors | Claude for Legal and Lavern |
| Market and business references | Harvey, Crosby, Moritz |
| Supporting implementation patterns | Mike and Suzie Law |
| Future platform blueprint | Existing `pacgate-ai/` Rust workspace in this repository |
| Research assets | `scope-assets/` legal AI research set and supporting build materials |

---

## Competitive Landscape & Differentiation

> Research basis: Harvey, Crosby, Moritz, Claude for Legal, Lavern, Mike, and Suzie Law, aligned to Cubecloud's local-first delivery model and Pacgate's current decision to start with hardware plus tailored legal agents.

### Market Map

| Company / System | Model | Delivery posture | Why it matters for Pacgate |
|------------------|-------|------------------|----------------------------|
| **Harvey** | Enterprise legal copilot | Cloud SaaS | Benchmark for legal AI quality, trust, and document workflows, but not the buying model Pacgate wants first |
| **Crosby** | Agentic law firm | Cloud service | Useful proof that narrow legal workflows and transparent packaging can sell before a broad platform is finished |
| **Moritz** | AI-enabled MSO platform | Cloud service + lawyer network | Useful proof that services-first rollout and clear scope can commercialize quickly |
| **Claude for Legal** | Open legal plugin and workflow system | Self-hosted / managed-agent friendly | Strong reference for practice bundles, playbooks, connectors, review guardrails, and legal workflow packaging |
| **Lavern** | Open multi-agent legal system | Local or hybrid | Strong reference for local delivery, specialist agents, debate, evidence checks, and verification loops |
| **Pacgate AI - Phase 1** | Sovereign local pilot owned by the law firm | Two local AI systems under Pacgate control | Pacgate learns, operates, and builds private legal knowledge before committing to a full SaaS build |

### Harvey - Quality benchmark, not the purchase path

Harvey remains the strongest reference point for production legal AI quality, especially around structured document workflows, verifiable citations, and durable agent orchestration. Pacgate should continue to borrow those quality lessons, but Phase 1 does **not** attempt to reproduce Harvey's entire cloud platform. The immediate lesson is narrower: high-quality legal AI requires strong workflow design, review gates, and evidence handling, not just model access.

### Crosby and Moritz - Business-model lessons for the rollout sequence

Crosby and Moritz matter less as technical blueprints than as commercial proof points. Both show that legal AI businesses can start with narrower scope, clearer packaging, and strong service components before broad platform expansion. That is directly relevant to Pacgate's revised direction:

1. Start with a constrained operating footprint.
2. Learn from real work instead of selling a wide platform too early.
3. Convert observed usage into later packaging, pricing, and product decisions.

### Claude for Legal - Reference model for practice bundles and legal connectors

Claude for Legal is a strong Phase 1 reference because it demonstrates a practical structure Pacgate can study and adapt immediately:

| Relevant capability | Why it fits Phase 1 |
|---------------------|---------------------|
| Practice-area plugin bundles | Lets Pacgate organize workflows by legal domain instead of by generic prompts |
| Cold-start interview and practice profile | Useful model for Pacgate-specific playbooks and operating rules |
| MCP connectors | Useful model for future document systems, research sources, and internal tool connections |
| Named workflow agents | Useful for repeatable legal review tasks and scheduled monitoring |
| Lawyer-review guardrails | Matches Pacgate's requirement that formal legal output remains lawyer-controlled |

The main adaptation value is not brand mimicry. It is structural: how legal workflows, playbooks, profiles, and connectors are packaged into something a team can actually run and refine.

### Lavern - Reference model for local multi-agent legal work

Lavern is a strong Phase 1 reference because it aligns closely with the local-first, learn-by-operating direction Pacgate now wants:

| Relevant capability | Why it fits Phase 1 |
|---------------------|---------------------|
| Local or hybrid run modes | Keeps sensitive work on Pacgate-controlled hardware |
| Multi-agent specialist team model | Gives Pacgate a tangible architecture to study and adapt |
| Evidence and counter-evidence debate | Useful for legal review quality and adversarial checking |
| Ten-pass verification loop | Useful model for producing reviewable deliverables instead of chat transcripts |
| Deliverable-first posture | Better fit for legal work product than generic chatbot interaction |

Lavern is especially useful because it makes the architecture legible. Pacgate's team can inspect how agents, evidence, verification, and deliverables fit together, then decide what should later become proprietary Pacgate product logic.

### Supporting patterns from Mike and Suzie Law

Mike and Suzie Law remain useful as implementation references, but they are **supporting** patterns in this proposal rather than the named Phase 1 deliverables.

| Supporting pattern | Source | Phase 1 relevance |
|--------------------|--------|-------------------|
| DOCX tracked changes and clean review surface | Mike | Useful for later Pacgate drafting and redlining workflows |
| Citation discipline and source grounding | Mike + Suzie Law | Useful for Pacgate's internal review and audit posture |
| Workflow libraries and persona packs | Suzie Law | Useful seed structure for Pacgate-specific workflow cataloguing |
| Local-first knowledge storage and retrieval | Suzie Law | Useful for starter RAG and knowledge indexing conventions |

### Why this Phase 1 structure is the right fit

1. It gives Pacgate useful private AI capability immediately instead of waiting for a full product build.
2. It lets Pacgate compare two strong open legal agent operating models side by side on its own machines.
3. It aligns with Cubecloud's existing hardware, operating-layer, and services-first delivery model.
4. It creates a practical foundation for Pacgate's own legal context graph and RAG assets.
5. It reduces product risk by deferring major SaaS scope until real usage data exists.
6. It preserves a credible path toward a later Pacgate SaaS system without forcing that commercial commitment now.

---

## Phase 1 Architecture Summary

```
┌────────────────────────────────────────────────────────────────────────────┐
│                   PACGATE AI - PHASE 1 LOCAL PILOT                        │
├────────────────────────────────────────────────────────────────────────────┤
│  Device A: Cubecloud local AI node                                        │
│  - AIPC standard unit + external GPU dock pairing                         │
│  - Cubecloud surfaces: Open WebUI, OpenSpace, IronClaw, Hermes            │
│  - Legal Agent App A: Claude for Legal adaptation                         │
│  - Primary use: playbooks, connectors, structured workflow execution      │
├────────────────────────────────────────────────────────────────────────────┤
│  Device B: Cubecloud local AI node                                        │
│  - AIPC standard unit + external GPU dock pairing                         │
│  - Cubecloud surfaces: Open WebUI, OpenSpace, IronClaw, Hermes            │
│  - Legal Agent App B: Lavern adaptation                                   │
│  - Primary use: multi-agent debate, verification loop, deliverables       │
├────────────────────────────────────────────────────────────────────────────┤
│  Shared private layer                                                     │
│  - Cubecloud Agent OS surface layer                                       │
│  - Local models via Ollama / approved providers                           │
│  - Starter authority registry and matter folders                          │
│  - Local context graph conventions and vector index                       │
│  - Private networking between devices and future nodes                    │
├────────────────────────────────────────────────────────────────────────────┤
│  Deferred future state                                                    │
│  - Full Pacgate SaaS platform                                             │
│  - Custom multi-tenant product stack                                      │
│  - Wider client-facing packaging and pricing                              │
└────────────────────────────────────────────────────────────────────────────┘
```

### Cubecloud surface layer in Phase 1

| Cubecloud surface | Phase 1 role |
|-------------------|--------------|
| **OpenSpace** | Team control surface for shared records, workflow visibility, and handover views |
| **Open WebUI** | Private AI workspace for local chat, search, retrieval, and assistant tasks |
| **IronClaw** | Security and policy surface for sensitive workflow boundaries and approved execution paths |
| **Hermes** | Memory, task follow-up, and scheduled workflow support |
| **Warp ADE** | Shared workspace for technical tuning, MCP work, and future workflow engineering |
| **OpenCode** | Local coding and iteration surface for adapting prompts, connectors, and supporting utilities |

### What stays deferred in architecture terms

The existing `pacgate-ai/` Rust workspace remains valuable, but it is now treated as the **future-state product blueprint**, not the quoted Phase 1 delivery scope. If Phase 1 succeeds, Pacgate can later decide which parts of that custom platform should be built into a proprietary SaaS or private multi-tenant system.

---

## Phase 0 - Pre-Sales Baseline *(Complete)*

**Owner:** Cubecloud R&D  
**Status:** Complete  
**Commercial treatment:** Included in pre-sales effort

### Existing baseline assets already prepared

| Asset | Current role |
|-------|--------------|
| `pacgate-ai/` Rust workspace scaffold | Future-state Pacgate platform blueprint |
| Architecture diagrams and concept pages | Discussion and alignment materials |
| Build-plan and research documents | Commercial and technical framing support |
| Open-source legal AI research set | Reference material for Phase 1 tailoring decisions |

Phase 0 remains useful because it gives Pacgate a clearer long-term destination, but it is no longer presented as the immediate paid build sequence.

---

## Workstream 1 - Two Local AI Systems & Cubecloud Standard Layer

**Owner:** Cubecloud deployment team  
**Commercial role:** Core Phase 1 package  
**Primary outcome:** Two ready-to-use Pacgate local AI systems for day-to-day work and experimentation

### Deliverables

| Deliverable | Scope |
|-------------|-------|
| Two AIPC-class systems | Final hardware bill of materials confirmed before order |
| External GPU dock pairing | Sized against selected local model and workload profile |
| Cubecloud standard AI layer | Local inference runtime, model access, surface integration, and deployment baseline |
| Agent OS surfaces enabled | OpenSpace, Open WebUI, IronClaw, Hermes, Warp ADE, OpenCode as agreed for Phase 1 |
| Private networking baseline | Node-to-node secure connection for future private expansion |
| Local storage and security baseline | Matter folders, authority materials, and review outputs kept under Pacgate control |

### Acceptance standard

1. Both machines boot into a usable Cubecloud operating layer.
2. Local models and approved workflows run on Pacgate-controlled hardware.
3. Pacgate can use the systems for internal legal review and knowledge work without depending on a public SaaS control plane.

---

## Workstream 2 - Legal Agent Application A: Claude for Legal Adaptation

**Owner:** Cubecloud legal-agent adaptation team  
**Commercial role:** Core Phase 1 package  
**Primary outcome:** A Pacgate-tailored legal workflow stack based on Claude for Legal patterns

### Adaptation focus

| Area | Phase 1 target |
|------|----------------|
| Practice bundles | Prioritize Pacgate's initial focus areas: data compliance, AI product compliance, Web3 / RWA compliance |
| Practice profile | Capture Pacgate review posture, escalation rules, preferred deliverable style, and lawyer approval boundaries |
| Workflow packaging | Prepare a small but usable starter set of legal review commands and routines |
| Connector planning | Define near-term MCP or integration priorities for future Pacgate document and research systems |
| Review guardrails | Ensure outputs remain draft material for lawyer review, not autonomous legal advice |

### Why this machine matters

This system becomes Pacgate's most practical reference for how a legal team can structure repeatable workflows, practice bundles, playbook rules, and connectors without immediately building a full proprietary platform.

---

## Workstream 3 - Legal Agent Application B: Lavern Adaptation

**Owner:** Cubecloud legal-agent adaptation team  
**Commercial role:** Core Phase 1 package  
**Primary outcome:** A Pacgate-tailored local multi-agent legal system based on Lavern patterns

### Adaptation focus

| Area | Phase 1 target |
|------|----------------|
| Specialist roles | Select a Pacgate-relevant subset of legal agent roles and review behaviors |
| Debate pattern | Use evidence and counter-evidence review where it improves legal quality |
| Verification loop | Preserve a multi-pass review loop so outputs are inspected before handoff |
| Local run mode | Keep document handling on Pacgate-controlled hardware whenever policy requires it |
| Deliverable packaging | Produce review outputs, memos, or redline-ready materials instead of generic chat transcripts |

### Why this machine matters

This system becomes Pacgate's practical reference for how a more agentic, locally operated legal system behaves when orchestration, challenge, and verification are treated as first-class design concerns.

---

## Workstream 4 - Starter Legal Context Graph, Knowledge Base & RAG

**Owner:** Cubecloud knowledge-workflow team  
**Commercial role:** Core Phase 1 package  
**Primary outcome:** Pacgate begins building its own private legal knowledge asset instead of only running standalone chat tools

### Deliverables

| Deliverable | Scope |
|-------------|-------|
| Starter authority registry | Organize laws, regulations, internal guidance, precedent notes, and working materials |
| Matter folder conventions | Establish repeatable storage structure for documents, outputs, and review traces |
| Context graph conventions | Define how authorities, clients, matters, templates, and outputs relate conceptually |
| Local RAG starter | Enable private indexing and retrieval for a first working corpus |
| Retrieval usage guidance | Define what sources are trusted, how lawyers review outputs, and what stays manual |

### Design principle

Phase 1 does not promise a finished enterprise knowledge platform. It delivers a usable **starter system** so Pacgate can begin building the habits, document structures, and source collections that a later proprietary platform would depend on.

---

## Workstream 5 - Onboarding, Operating Playbooks & Handover

**Owner:** Cubecloud delivery and enablement team  
**Commercial role:** Core Phase 1 package  
**Primary outcome:** Pacgate can operate the two systems confidently and understand what each one is for

### Deliverables

| Deliverable | Scope |
|-------------|-------|
| User onboarding sessions | Introductory training for daily legal use cases |
| Operating playbooks | Clear guidance on when to use each machine and how to review outputs |
| Workflow demonstrations | Sample Pacgate use cases for internal adoption |
| Safety and review guidance | Clear boundaries for lawyer approval and source verification |
| Handover materials | Practical notes for Pacgate's continuing internal experimentation |

---

## Workstream 6 - Ongoing Advisory, On-Site Support & Phase 2 Discovery

**Owner:** Cubecloud advisory team  
**Commercial role:** Time-and-materials service line (standalone service orders)  
**Primary outcome:** Pacgate receives continuing expert support while building internal capability

### On-site service included in fixed delivery

| Service | Duration | Cost |
|---------|----------|------|
| First-delivery on-site installation and training | 3 business days | Included in fixed delivery at no extra charge |

Covers: Two-system racking and networking, Cubecloud standard AI layer baseline deployment verification, Agent OS surface activation confirmation, key user operation training.

### Optional advisory and on-site support (standalone service orders)

| Service | Billing basis | Order document |
|---------|---------------|----------------|
| Remote advisory support | CNY 500 / hour | Remote Advisory Service Order |
| 20-hour remote advisory reserve | CNY 10,000 | Remote Advisory Service Order |
| 40-hour remote advisory reserve | CNY 20,000 (1 year validity) | Remote Advisory Service Order |
| On-site workshops or troubleshooting | Hourly or day rate plus travel | On-Site Service Order |
| 5-day on-site support package | CNY 43,200 reference price, plus travel | On-Site Service Order |
| Workflow and prompt refinement | Hourly rate or scoped task estimate | Remote Advisory Service Order |
| MCP / connector planning | Hourly rate or scoped task estimate | Remote Advisory Service Order |
| Phase 2 SaaS discovery | Separate advisory track before any full build quotation | To be agreed separately |

### Principle

Consultation is not an afterthought in this plan. It is a core part of how Pacgate converts a two-machine pilot into real internal knowledge, process design, and future product direction. Advisory and on-site support are signed via standalone service orders, not bundled with the HWOS / LegalAgent contracts, so the client can purchase them as needed.

---

## Deferred Phase 2 - Pacgate SaaS Agentic System

This proposal intentionally does **not** price or commit the full Phase 2 SaaS build. That later phase would only be quoted after Phase 1 proves the operating model and gives Pacgate enough evidence to answer the right product questions.

### Likely Phase 2 subjects after a successful pilot

1. Pacgate-branded multi-tenant legal AI product design.
2. Custom workflow engine and matter model based on real Pacgate usage.
3. Document-generation and redline tooling packaged for repeat client delivery.
4. Client-facing packaging, pricing, support, and governance model.
5. Decision on whether the existing Rust workspace becomes the main product core, a private deployment layer, or a hybrid architecture.

---

## Technology Stack Summary

| Layer | Phase 1 working position |
|-------|--------------------------|
| Local hardware | Two Cubecloud AIPC-class systems, with final GPU dock pairing confirmed before order |
| Operating layer | Cubecloud Agent OS surfaces: OpenSpace, Open WebUI, IronClaw, Hermes, Warp ADE, OpenCode |
| Local AI runtime | Ollama and approved local model stack, with optional approved external providers where policy allows |
| Legal agent reference A | Claude for Legal patterns for playbooks, practice profiles, bundles, and connectors |
| Legal agent reference B | Lavern patterns for local specialist agents, debate, verification, and deliverables |
| Knowledge layer | Starter authority registry, matter folders, context graph conventions, local retrieval workflow |
| Future custom platform reference | `pacgate-ai/` Rust workspace and surrounding architecture materials |

### Future-state custom platform note

The current repository's Rust architecture remains strategically relevant. It simply moves out of the immediate commercial scope and into a future product-planning role until the pilot establishes what Pacgate should actually build next.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hardware bill of materials is fixed too early or too late | Medium | Medium | Confirm the final AIPC + external GPU dock pairing before PO and before pricing is locked |
| Phase 1 gets overloaded with Phase 2 product expectations | High | High | Keep a strict boundary: pilot now, SaaS quotation later |
| Open-source legal stacks need more Pacgate tailoring than assumed | Medium | Medium | Treat legal-agent delivery as adaptation and enablement work, not as instant turnkey replacement |
| Retrieval sources are incomplete at the start | High | Medium | Start with a curated starter corpus and expand under advisory support |
| Users treat draft AI outputs as final legal advice | Medium | Critical | Preserve lawyer review gates and operating playbooks in every workflow |
| Private network and local knowledge practices drift without ownership | Medium | Medium | Build handover materials and maintain advisory support during the learning period |

---

## Appendix A - Phase 1 Quotation Structure

> The figures below present the current Phase 1 commercial basis for client review.
> Hardware model choices, advisory rate assumptions, travel, and optional extras can still be revised later without changing the package structure of the proposal.
> CNY figures below are shown at a reference FX rate of **USD 1 = CNY 7.20**. Final invoice currency and FX treatment are confirmed at contracting time.

### Pricing Summary

| Category | Working amount (USD / CNY) |
|----------|----------------|
| Package 1 - Hardware and local AI foundation | **USD 11,056 / CNY 79,600** |
| Package 2 - Two legal agent deliveries | **USD 4,167 / CNY 30,000** |
| Package 3 - Starter knowledge and RAG enablement | **USD 1,389 / CNY 10,000** |
| **Fixed Phase 1 delivery subtotal** | **USD 16,612 / CNY 119,600** |
| Includes 3 business days on-site installation and training | No extra charge |
| Optional 40-hour remote advisory reserve (1 year validity) | **USD 2,778 / CNY 20,000** (standalone service order) |
| Optional 5-day on-site support package | **CNY 43,200 reference price** (standalone service order, travel extra) |

### Package 1 - Two Local AI Systems & Cubecloud Standard Layer

| Item | Qty | Working amount (USD / CNY) | Notes |
|------|-----|----------------------------|-------|
| Cubecloud AIPC standard unit | 2 | USD 6,111 / CNY 44,000 | Two local AI nodes |
| External GPU dock + approved GPU kit | 2 | USD 972 / CNY 7,000 | External GPU dock pairings |
| Local memory / storage uplift | 2 | USD 694 / CNY 5,000 | Per-node memory and storage uplift |
| Cubecloud standard AI layer deployment | 2 packages | USD 1,389 / CNY 10,000 | One deployment pass per local node |
| Cubecloud Agent OS surface enablement | 2 packages | USD 1,056 / CNY 7,600 | One enablement pass per local node |
| Private networking baseline setup | 2 packages | USD 833 / CNY 6,000 | Baseline private networking across the two systems |
| **Package 1 total** | | **USD 11,056 / CNY 79,600** | |

### Package 2 - Legal Agent Application Delivery

| Item | Qty | Working amount (USD / CNY) | Notes |
|------|-----|----------------------------|-------|
| Claude for Legal adaptation for Pacgate | 1 | USD 1,389 / CNY 10,000 | Practice profile, starter workflows, playbook alignment |
| Lavern adaptation for Pacgate | 1 | USD 1,389 / CNY 10,000 | Local multi-agent setup, review behavior, verification loop |
| Pacgate playbook / workflow tailoring | 2 packages | USD 556 / CNY 4,000 | Tailoring pass aligned to the two local systems |
| Initial workflow demonstrations and review guardrails | 2 packages | USD 833 / CNY 6,000 | Demonstrations and lawyer-review operating boundaries |
| **Package 2 total** | | **USD 4,167 / CNY 30,000** | |

### Package 3 - Starter Context Graph, Knowledge & RAG Enablement

| Item | Qty | Working amount (USD / CNY) | Notes |
|------|-----|----------------------------|-------|
| Starter authority registry setup | 1 package | USD 208 / CNY 1,500 | Initial source structure, categories, and operating rules |
| Matter folder and context-graph conventions | 1 package | USD 417 / CNY 3,000 | Practical structure for matters, sources, and outputs |
| Local retrieval / RAG starter setup | 1 package | USD 556 / CNY 4,000 | Initial ingestion, retrieval pattern, and review workflow |
| Handover and working guidance | 1 package | USD 208 / CNY 1,500 | Operator guidance and internal continuity materials |
| **Package 3 total** | | **USD 1,389 / CNY 10,000** | |

### Package 4 - Advisory & Support Services

> Advisory and on-site support are not included in the two-contract fixed delivery amount. The client selects desired services via the Optional Services Selection Form, and the parties then sign the corresponding standalone Service Order.

#### On-site service included in fixed delivery

| Service line | Duration | Cost |
|-------------|----------|------|
| First-delivery on-site installation and training | 3 business days | Included in fixed delivery at no extra charge |

#### Optional services (standalone service orders)

| Service line | Billing basis | Working rate (USD / CNY) |
|--------------|---------------|---------------------------|
| Remote advisory support | Hourly | USD 70 / hour / CNY 500 / hour — via Remote Advisory Service Order |
| 20-hour remote advisory reserve | 20-hour package | USD 1,389 / CNY 10,000 — via Remote Advisory Service Order |
| 40-hour remote advisory reserve | 40-hour package | USD 2,778 / CNY 20,000 — via Remote Advisory Service Order; 1 year validity |
| On-site support | Day rate | To be confirmed — via On-Site Service Order; travel extra |
| On-site support | Hourly | To be confirmed — via On-Site Service Order; travel extra |
| 5-day on-site support package | 5-day package | CNY 43,200 reference price — via On-Site Service Order; travel extra |
| Travel and accommodation | At cost or quoted separately | Confirmed per trip |

### Optional Advisory & On-Site Reserve Reference

| Reserve option | Working amount (USD / CNY) | Order document |
|----------------|----------------------------|----------------|
| 20 hours remote advisory | USD 1,389 / CNY 10,000 | Remote Advisory Service Order |
| 40 hours remote advisory | USD 2,778 / CNY 20,000 | Remote Advisory Service Order |
| 5 on-site days | CNY 43,200 reference price plus travel | On-Site Service Order |

### Proposed Payment Structure

| Milestone | Trigger | Working amount (USD / CNY) |
|-----------|---------|----------------------------|
| Deposit | Hardware confirmation + Phase 1 kickoff / procurement | USD 9,967 / CNY 71,760 (60%) |
| Milestone 1 | Two local systems installed and operational | USD 4,984 / CNY 35,880 (30%) |
| Final handover | Starter knowledge / RAG handover complete | USD 1,661 / CNY 11,960 (10%) |
| Advisory billing | Monthly in arrears | Time and materials |

### Assumptions

1. Hardware pricing assumes two AIPC-class systems with external GPU dock pairings sized for this pilot, not a larger enterprise workstation cluster.
2. Adaptation fees assume targeted Pacgate pilot tailoring, not a fully new legal product built from zero.
3. USD figures are tax/VAT included. CNY figures are shown at the proposal reference FX rate of **USD 1 = CNY 7.20** and do not yet include the additional 3.5% VAT reserve. Final invoice currency and FX/tax treatment are confirmed at contracting time.
4. Travel, customer-owned research subscriptions, and third-party data-source licences are excluded from the fixed subtotal.
5. Any additional MCP connectors, workflow packs, or deployment expansion beyond the agreed pilot scope are quoted separately.

### Explicit exclusions from this quotation

1. No full Pacgate SaaS build quotation is included in this appendix.
2. No Phase 2 client-facing SaaS operations pricing is included.
3. No OEM licensing structure for later commercialization is included.
4. No broad end-client platform pricing is included.

### Phase 2 decision gate

Pacgate and Cubecloud should only open the next quotation after reviewing:

| Decision question | Phase 1 evidence needed |
|-------------------|-------------------------|
| Which workflows are used frequently enough to productize? | Real machine usage, lawyer feedback, workflow logs |
| Which legal-agent patterns should become proprietary Pacgate features? | Side-by-side learning from Claude for Legal and Lavern |
| What data model should a Pacgate SaaS platform actually use? | Matter folders, authority patterns, context-graph usage, RAG behavior |
| What business model should Pacgate sell downstream? | Pilot delivery effort, support load, workflow repeatability |

### Summary

| Category | Working commercial posture |
|----------|----------------------------|
| Hardware and local AI systems | USD 11,056 / CNY 79,600 |
| Two legal agent application deliveries | USD 4,167 / CNY 30,000 |
| Starter knowledge / RAG enablement | USD 1,389 / CNY 10,000 |
| Fixed Phase 1 delivery subtotal | **USD 16,612 / CNY 119,600** |
| Includes 3 business days on-site installation and training | No extra charge |
| Optional 40-hour advisory reserve | **USD 2,778 / CNY 20,000** (standalone service order, 1 year validity) |
| Optional 5-day on-site support package | **CNY 43,200 reference price** (standalone service order, travel extra) |
| Full Pacgate SaaS build | Deferred until after successful Phase 1 trial |

---

*Prepared by Cubecloud Limited for Pacgate Law*  
*Revised to reflect customer feedback and Phase 1 pilot direction - May 29, 2026*  
*Open-source reference systems remain under their own licenses. Pacgate-specific deployment, tailoring, and support deliverables are governed by the final service agreement.*