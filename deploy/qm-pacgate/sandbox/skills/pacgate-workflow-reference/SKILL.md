---
name: pacgate-workflow-reference
description: Reference directory of Pacgate workflow YAML templates. Browse these to understand available legal workflows, their steps, and tools before executing them via the pacgate-qm CLI.
---

The Pacgate API exposes 220+ legal workflow templates organized by category.
Use `pacgate-qm workflows --search "<keywords>"` to discover workflows, and
`pacgate-qm workflow <workflow-id>` to inspect a specific workflow's steps.

Workflow categories include: contract_review, due_diligence, litigation,
compliance, fund_lawyer, capital_markets, investment_financing, banking_general,
ma_due_diligence, compliance_specialized, and archive_collection.

Never fabricate workflow ids. Always discover them first with
`pacgate-qm workflows --search` or `pacgate-qm workflow-categories`.