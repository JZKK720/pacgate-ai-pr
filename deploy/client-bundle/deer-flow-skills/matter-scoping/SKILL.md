---
name: matter-scoping
description: Bind the conversation to the correct Pacgate matter before any document, search, memory or workflow call, and read/write the matter's working memory. Use at the start of substantive legal work, or whenever a tool fails with an invalid or missing matter id.
---

<!-- Pacgate 2026-10-30: no `allowed-tools` on purpose - see cn-nda-review for the
     measured reason (union semantics amputate the surface; a scalar is rejected
     by the loader outright). -->

# Matter scoping

Pacgate is **matter-scoped**. Every document, RAG search, memory read and workflow
run belongs to one matter. Using the wrong matter is not a cosmetic error - it
reads another client's corpus and can write into a record that belongs to them.

## Step 1 - find the matter

```
pacgate_pacgate_list_matters()
```

Returns `id`, `name`, `description`, `persona_id` and timestamps. Match on what
the user actually said - client name, counterparty, deal type.

If exactly one plausible match, state which one you are using before continuing:
"使用事项：<name> (<id>)". If more than one matches, **stop and ask**. Do not pick
the most recently updated one; that is how work lands in the wrong client's file.

## Step 2 - confirm the matter is populated

```
pacgate_pacgate_get_workspace(matter_id="<id>")
```

This returns `documents` (with `sanitization_state`) and `rag_documents` (with
`states`). Read it before searching, because it answers "is the corpus even
there?" - the question that otherwise gets misreported as "no results".

Key detail: **only sanitized chunks are searchable.** A document whose
`sanitization_state` is `pending` will not appear in `kb_search` results
(`pacgate-rag` filters to `sanitized` or `never`). If the workspace shows
pending documents, say so and offer to sanitize - do not report an empty search
as "the firm has nothing on this".

## Step 3 - read working memory

```
pacgate_pacgate_read_memory(matter_id="<id>")
```

Memory holds **process**, not facts: decisions taken, preferences, open
questions. It is small and revision-tracked on purpose - the server rejects
payloads too large to be a summary.

Write with `pacgate_pacgate_write_memory`. If the write is rejected as stale
(409), re-read and merge; do not retry the same payload. If it is rejected as
out-of-scope (422), the content belongs in the RAG lane, not memory - that means
it is a matter fact (a party name, a date, a clause) and should live in a
document, not in memory.

## Step 4 - then do the work

Only now call `pacgate_pacgate_kb_search`, `pacgate_pacgate_list_documents`,
`pacgate_pacgate_read_document`, or `pacgate_pacgate_execute_workflow` with the
confirmed `matter_id`.

## On the environment default

`PACGATE_MATTER_ID` is set in the container and some tools fall back to it when
`matter_id` is omitted. **Do not rely on it.** It is one fixed matter for the
whole deployment, so an omitted argument silently means "the default matter",
which may belong to a different client. Always pass `matter_id` explicitly for
substantive work. (The fallback also tolerates a model serializing `"None"` or
`"null"` as a literal string, which should never be necessary if you pass the id.)

## Failure modes and what they mean

| Symptom | Meaning | Fix |
|---|---|---|
| `invalid matter id` | malformed id, or the literal string `None` | pass the real UUID |
| `kb_search` returns `empty_reason: no_documents` | matter exists, nothing uploaded | upload, then sanitize |
| `kb_search` returns `empty_reason: nothing_sanitized` | documents exist but pending | run sanitize on them |
| `kb_search` returns `empty_reason: no_match` | corpus populated, query missed | broaden keywords - this one is a real no-match |
| 404 on the matter | wrong tenant or wrong deployment | check `pacgate_pacgate_list_matters()` |

The three `empty_reason` values are deliberately distinct. Reporting all three
as "no results" is the error this skill exists to prevent.

## Boundaries

- Never guess a matter id from a name that partially matches.
- Never write to a matter the user has not confirmed in this conversation.
- Never search across matters to "find" something - list matters and ask.
