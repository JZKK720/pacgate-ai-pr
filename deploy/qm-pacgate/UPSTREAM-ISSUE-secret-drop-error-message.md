# Upstream issue (draft): `/drop/:id/form` reports every failure as "expired"

Intended for: https://github.com/yc-software/qm/issues
Component: `packages/core/src/api/routes/secret-drop.ts` (0.1.17-ish, current main)
Severity: minor / UX — makes real credential delivery fail opaquely.

## What happens

Every failure mode that reaches the `!peeked.ok` / token-verification branches
renders the same page:

```ts
return dropFormHtml(params.id!, null);   // "This link has expired"
```

Concretely, all of the following produce the identical `404` page carrying the
text `This link has expired`:

1. wrong / mistyped link signature;
2. a signature minted with a different `CAPABILITY_SECRET` than the one serving the request;
3. a link that was already redeemed (`usedAt` set);
4. a link whose record was pruned;
5. `aud` / `drop` / `scopeId` / `actorId` mismatch;
6. an actually-expired token.

`peeked.reason` already distinguishes `not_found` from `expired`, and
`dropGone()` already branches on it for the JSON path — but the HTML path drops
that distinction entirely.

## Why it matters

The one person who sees this page is the person trying to deliver a real secret
into the sandbox. The message sends them back to the agent asking for a new link
when the link they hold was rejected for an unrelated reason (classically: it was
mistranscribed — a single wrong character in a 43-char base64url signature).
That wastes a turn and, worse, trains users to expect "expired" and ignore it.

## Suggested change

Use the reason already available:

```ts
res.writeHead(404, ...);
return void res.end(dropFormHtml(params.id!, null, undefined, peeked.reason));
```

and give `dropFormHtml` three variants:

| reason | message |
|---|---|
| `expired` | "This link has expired — ask the agent for a fresh one." (unchanged) |
| `not_found` after a previously valid record | "This link was already used — ask the agent for a fresh one." |
| token verify failed but the record exists | "This link could not be verified. Check it was copied whole, or ask the agent for a fresh one." |

The third case is the valuable one: it tells the operator the problem is
transcription, not time. No new security surface — the page still reveals
nothing about which field failed or why beyond "invalid".

## Reproduction

Take a valid `/drop/.../form?t=<token>` link, flip one character of the signature
(the last path segment after the second `.`), reload while signed in as the drop
owner. Observed: `This link has expired`. Expected: an invalid-link message.

Reported against the pacgate-ai dry-run setup. Not a pacgate-specific defect.
