# Pacgate-ai Persona Reference

## Practice-Area Personas (20)

These personas are assigned to users via the `persona_id` field in
pacgate-api's auth system. Each persona specializes in a specific legal
practice area.

| Persona | Practice Area | Description |
|---------|--------------|-------------|
| Corporate Counsel | Corporate | General corporate law, governance, compliance |
| M&A Lawyer | Mergers & Acquisitions | Transaction structuring, due diligence, deal negotiation |
| Contract Review Specialist | Contract Review | Contract drafting, risk review, clause analysis |
| Litigation Attorney | Litigation | Civil litigation strategy, evidence analysis, court filings |
| IP Lawyer | Intellectual Property | Patent, trademark, copyright prosecution and enforcement |
| Employment Lawyer | Employment & Labor | Employment contracts, labor disputes, workplace compliance |
| Tax Advisor | Tax Law | Tax planning, transfer pricing, tax dispute resolution |
| Real Estate Counsel | Real Estate | Property transactions, land use, construction law |
| Banking & Finance Lawyer | Banking & Finance | Loan agreements, regulatory compliance, fintech |
| Securities Lawyer | Capital Markets | IPO, disclosure, securities regulation |
| Antitrust Lawyer | Competition Law | Merger control, antitrust investigation, compliance |
| Data Privacy Counsel | Data Protection | GDPR/PIPL compliance, data governance, privacy impact |
| Compliance Officer | Regulatory Compliance | Internal compliance, regulatory filings, risk management |
| Fund Formation Lawyer | Investment Funds | Fund structuring, LP/GP relations, regulatory filings |
| Bankruptcy Lawyer | Insolvency | Restructuring, liquidation, creditor rights |
| Criminal Defense Attorney | Criminal Law | Criminal defense strategy, evidence, plea negotiation |
| Family Law Attorney | Family Law | Divorce, custody, inheritance, family disputes |
| Environmental Lawyer | Environmental Law | Environmental compliance, ESG, green finance |
| International Trade Lawyer | Trade & Customs | Trade agreements, customs, export controls, sanctions |
| General Practice Attorney | General | Cross-practice general legal assistance |

## SOUL Personas (10)

SOUL personas are identity overlays applied at the entry point (login). They
control the agent's role, boundary rules, output format, and escalation
targets. Each user gets one SOUL persona via the `soul_id` field in their JWT.

### Justin — Managing Partner Assistant
- **Roles**: Managing partner assistant / Senior partner assistant / Personal secretary
- **Identity modes**: Switches based on context (which workflow/matter)
- **Output format**: 3-part decision (recommendation + risk + next steps)
- **Red lines**: 7 boundary rules (no fabrication, escalate uncertain legal
  conclusions, no binding commitments without partner approval, etc.)
- **Escalation**: Escalates to managing partner for decisions beyond authority

### Sylvie — Partner + AI System Lead
- **Roles**: Independent lawyer / Team leader (AI system building)
- **Output format**: Legal opinion 3-part output (holding + reasoning + caveats)
- **Boundary rules**: System config rules, no unauthorized API changes
- **Escalation**: Escalates to senior partner for substantive legal opinions

### BigLaw Agent Roster (A1-A8)

| Agent | Role | Description |
|-------|------|-------------|
| A1 Matter Manager | Orchestration | Matter management, task decomposition, agent coordination |
| A2 Intake & Conflicts | Intake | Conflict checks, matter workspace setup, engagement letters |
| A3 Domain Experts | Due Diligence | Multi-domain: legal, finance, commercial, product/tech, cybersecurity, HR, tax |
| A4 Research Agent | Research | Legal database search with source grading, citation extraction |
| A5 Citation Verification | Validation | Hard-gate citation verification before report publication |
| A6 Drafting Agent | Drafting | Document drafting with style matching and template reuse |
| A7 Review Agent | Review | Senior-level document review with tracked changes |
| A8 Report Assembly | Output | Report assembly from verified sections, final formatting |

## How to assign a persona

1. Register the user: `POST /api/auth/register` with email + password
2. Assign a SOUL persona: update the user's `soul_id` via the admin endpoint
3. The SOUL persona wraps the agent system prompt with identity, boundary
   rules, and output format
4. Practice-area personas can be selected per-workflow via `persona_id` in
   the workflow execution request

## Source files

- `pacgate-ai/crates/pacgate-persona/src/lib.rs` — practice-area personas
- `pacgate-ai/crates/pacgate-persona/src/soul.rs` — SOUL personas (Justin, Sylvie, A1-A8)
- `pacgate-ai/crates/pacgate-auth/src/middleware.rs` — SOUL resolver middleware