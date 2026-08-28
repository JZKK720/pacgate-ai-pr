---
name: pacgate-workflow
description: Discover Pacgate workflows, bind the current QM scope to a Pacgate matter, read or write matter memory, and execute a workflow through the Pacgate API. Use when QM collaboration needs Pacgate legal workflows or Pacgate-backed matter memory.
---

Use `pacgate-qm workflows --search "<keywords>"` to discover candidate workflows.

Use `pacgate-qm workflow <workflow-id>` before execution when you need to inspect the workflow definition or steps.

Use `pacgate-qm ensure-matter --org-id <org> --channel-id <channel> [--channel-name "..."]` to create or reuse the Pacgate matter bound to the current QM scope.

Use `pacgate-qm memory-get ...` and `pacgate-qm memory-save ... --memory-json '{"key":"value"}'` to persist Pacgate matter memory for the same scope.

Use `pacgate-qm execute-workflow --workflow-id <id> --org-id <org> --channel-id <channel> [--channel-name "..."]` to run a Pacgate workflow inside the bound matter.

## Long-term memory (OpenViking)

Use `pacgate-qm ov-remember --content "<fact worth remembering>"` to store a durable memory (async extraction turns it into structured memories).

Use `pacgate-qm ov-search --query "<semantic query>"` to recall relevant memories, resources, and skills from past sessions.

Use `pacgate-qm ov-read --uri "viking://user/default/memories/<path>"` to read a specific memory document found via search.

Never store matter documents or confidential case files via ov-remember — those belong in Pacgate matter storage. OpenViking memory is for conversational context: decisions, preferences, and working knowledge.

Never fabricate workflow ids, matter ids, or Pacgate scope bindings. Query them first or provide the real QM scope identifiers.
